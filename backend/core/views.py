from django.conf import settings
from django.db import transaction
from django.utils import timezone

from rest_framework import viewsets, status
from rest_framework.authtoken.models import Token
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import User, MemoryItem, AuditLog
from .serializers import (
    UserSerializer, RegisterSerializer, LoginSerializer,
    MemoryItemSerializer, AuditLogSerializer,
)

API_VERSION = "v1"
BUILD_PART = 1  # which V1 part this backend serves


def log(user, action, **detail):
    AuditLog.objects.create(user=user, action=action, detail=detail)


# ---------- public / health ----------

@api_view(["GET"])
@permission_classes([AllowAny])
def health(request):
    return Response({"status": "ok", "time": timezone.now().isoformat()})


@api_view(["GET"])
@permission_classes([AllowAny])
def version(request):
    return Response({
        "app": "Assisto",
        "api": API_VERSION,
        "part": BUILD_PART,
        "base_url": settings.ASSISTO_BASE_URL,
        "features": {
            "sms_otp": settings.SMS_ENABLED,
            "ai": settings.AI_ENABLED,
        },
    })


# ---------- auth ----------

class RegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        ser = RegisterSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        user = ser.save()
        token, _ = Token.objects.get_or_create(user=user)
        log(user, "account.register")
        return Response(
            {"token": token.key, "user": UserSerializer(user).data},
            status=status.HTTP_201_CREATED,
        )


class LoginView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        ser = LoginSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        ident = ser.validated_data["identifier"].strip()
        password = ser.validated_data["password"]
        user = (User.objects.filter(phone=ident).first()
                or User.objects.filter(email=ident.lower()).first()
                or User.objects.filter(username=ident).first())
        if not user or not user.check_password(password) or not user.is_active:
            return Response({"detail": "ভুল তথ্য। আবার চেষ্টা করুন।"},
                            status=status.HTTP_401_UNAUTHORIZED)
        token, _ = Token.objects.get_or_create(user=user)
        log(user, "account.login")
        return Response({"token": token.key, "user": UserSerializer(user).data})


class LogoutView(APIView):
    def post(self, request):
        Token.objects.filter(user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class OTPRequestView(APIView):
    """Designed, but off until an SMS provider is configured. No fake SMS."""
    permission_classes = [AllowAny]

    def post(self, request):
        if not settings.SMS_ENABLED:
            return Response(
                {"detail": "OTP এখন বন্ধ — SMS প্রোভাইডার যুক্ত করা হয়নি। "
                           "ফোন/ইমেইল ও পাসওয়ার্ড দিয়ে লগইন করুন।",
                 "sms_enabled": False},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response({"detail": "not implemented"}, status=status.HTTP_501_NOT_IMPLEMENTED)


# ---------- profile ----------

class MeView(APIView):
    def get(self, request):
        return Response(UserSerializer(request.user).data)

    def patch(self, request):
        ser = UserSerializer(request.user, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        ser.save()
        log(request.user, "profile.update", fields=list(request.data.keys()))
        return Response(ser.data)


# ---------- memory ("AI কী জানে") ----------

class MemoryViewSet(viewsets.ModelViewSet):
    serializer_class = MemoryItemSerializer

    def get_queryset(self):
        return MemoryItem.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user, source=MemoryItem.SOURCE_MANUAL)
        log(self.request.user, "memory.create", id=obj.id, title=obj.title)

    def perform_update(self, serializer):
        obj = serializer.save()
        log(self.request.user, "memory.update", id=obj.id)

    def perform_destroy(self, instance):
        log(self.request.user, "memory.delete", id=instance.id, title=instance.title)
        instance.delete()


# ---------- audit log ----------

class AuditListView(APIView):
    def get(self, request):
        qs = AuditLog.objects.filter(user=request.user)[:200]
        return Response(AuditLogSerializer(qs, many=True).data)


# ---------- data export / delete (design: your data, exportable & deletable) ----------

class ExportView(APIView):
    def get(self, request):
        u = request.user
        data = {
            "exported_at": timezone.now().isoformat(),
            "user": UserSerializer(u).data,
            "memories": MemoryItemSerializer(u.memories.all(), many=True).data,
            "audit": AuditLogSerializer(u.audit.all()[:1000], many=True).data,
        }
        log(u, "account.export")
        resp = Response(data)
        resp["Content-Disposition"] = 'attachment; filename="assisto-export.json"'
        return resp


class DeleteAccountView(APIView):
    def delete(self, request):
        u = request.user
        with transaction.atomic():
            Token.objects.filter(user=u).delete()
            u.delete()  # cascades memories, audit, devices
        return Response(status=status.HTTP_204_NO_CONTENT)
