from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from .models import User, MemoryItem, AuditLog


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "name", "phone", "email", "autonomy_level", "language", "date_joined"]
        read_only_fields = ["id", "date_joined"]


class RegisterSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=120, required=False, allow_blank=True)
    phone = serializers.CharField(max_length=24, required=False, allow_blank=True)
    email = serializers.EmailField(required=False, allow_blank=True)
    password = serializers.CharField(write_only=True, min_length=6)

    def validate(self, data):
        phone = (data.get("phone") or "").strip()
        email = (data.get("email") or "").strip().lower()
        if not phone and not email:
            raise serializers.ValidationError("ফোন নম্বর বা ইমেইল — অন্তত একটা দিন।")
        if phone and User.objects.filter(phone=phone).exists():
            raise serializers.ValidationError("এই ফোন নম্বর আগে থেকেই আছে।")
        if email and User.objects.filter(email=email).exists():
            raise serializers.ValidationError("এই ইমেইল আগে থেকেই আছে।")
        validate_password(data["password"])
        data["phone"] = phone or None
        data["email"] = email or None
        return data

    def create(self, data):
        return User.objects.create_user(
            name=data.get("name", ""),
            phone=data.get("phone"),
            email=data.get("email"),
            password=data["password"],
        )


class LoginSerializer(serializers.Serializer):
    identifier = serializers.CharField()   # phone or email
    password = serializers.CharField(write_only=True)


class MemoryItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = MemoryItem
        fields = ["id", "category", "title", "detail", "source",
                  "confidence", "needs_review", "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]

    def validate_source(self, value):
        # Users create manual items; AI-sourced items come from the AI pipeline only.
        return MemoryItem.SOURCE_MANUAL


class AuditLogSerializer(serializers.ModelSerializer):
    class Meta:
        model = AuditLog
        fields = ["id", "action", "detail", "created_at"]
