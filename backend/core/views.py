from django.conf import settings
from django.db import transaction
from django.http import HttpResponse
from django.utils import timezone

from rest_framework import viewsets, status
from rest_framework.authtoken.models import Token
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from datetime import timedelta

from .models import (User, MemoryItem, AuditLog, Reminder, Note, Todo,
                     SourcePermission, SupportTicket, Document, EmergencyCard,
                     Account, Transaction, Budget, Loan, SavingsGoal, Subscription)
from .serializers import (
    UserSerializer, RegisterSerializer, LoginSerializer,
    MemoryItemSerializer, AuditLogSerializer, ReminderSerializer,
    NoteSerializer, TodoSerializer, SourcePermissionSerializer,
    SupportTicketSerializer, DocumentSerializer, EmergencyCardSerializer,
    AccountSerializer, TransactionSerializer, BudgetSerializer, LoanSerializer,
    SavingsGoalSerializer, SubscriptionSerializer,
)
from . import ai

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
def app_latest(request):
    """Latest installable APK info for the in-app updater. Fed by publish-apk.sh."""
    import json
    data = {"version_code": 0, "version_name": "", "apk_url": "", "notes": ""}
    try:
        with open(settings.APP_LATEST_FILE) as f:
            data.update(json.load(f))
    except Exception:
        pass
    return Response(data)


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


# ---------- synced collections (reminders / notes / todos) ----------

class SyncedViewSet(viewsets.ModelViewSet):
    """Per-user CRUD with audit logging and recoverable (undoable) deletes."""
    kind = ""   # 'reminder' | 'note' | 'todo'

    def get_queryset(self):
        return self.model.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user, source=MemoryItem.SOURCE_MANUAL)
        log(self.request.user, f"{self.kind}.create", id=obj.id)

    def perform_update(self, serializer):
        obj = serializer.save()
        log(self.request.user, f"{self.kind}.update", id=obj.id)

    def perform_destroy(self, instance):
        data = self.get_serializer(instance).data
        log(self.request.user, f"{self.kind}.delete", undo=data, kind=self.kind)
        instance.delete()


class ReminderViewSet(SyncedViewSet):
    model = Reminder
    kind = "reminder"
    serializer_class = ReminderSerializer


class NoteViewSet(SyncedViewSet):
    model = Note
    kind = "note"
    serializer_class = NoteSerializer


class TodoViewSet(SyncedViewSet):
    model = Todo
    kind = "todo"
    serializer_class = TodoSerializer


_UNDO_MAP = {
    "reminder": (Reminder, ReminderSerializer),
    "note": (Note, NoteSerializer),
    "todo": (Todo, TodoSerializer),
    "memory": (MemoryItem, MemoryItemSerializer),
}


class UndoView(APIView):
    """Feature 20 — short undo: recreate the most recently deleted item."""
    def post(self, request):
        since = timezone.now() - timedelta(seconds=180)
        candidates = (AuditLog.objects.filter(user=request.user, action__endswith=".delete",
                                              created_at__gte=since).order_by("-created_at")[:10])
        entry = next((e for e in candidates if not e.detail.get("undone")), None)
        if not entry:
            return Response({"detail": "ফিরিয়ে আনার মতো কিছু নেই।"},
                            status=status.HTTP_404_NOT_FOUND)
        kind = entry.detail.get("kind")
        data = entry.detail.get("undo") or {}
        model, ser = _UNDO_MAP.get(kind, (None, None))
        if not model:
            return Response({"detail": "সম্ভব নয়।"}, status=status.HTTP_400_BAD_REQUEST)
        data.pop("id", None)
        data.pop("created_at", None)
        data.pop("updated_at", None)
        obj = model.objects.create(user=request.user,
                                   **{k: v for k, v in data.items()
                                      if k in [f.name for f in model._meta.fields]})
        entry.detail["undone"] = True
        entry.save(update_fields=["detail"])
        log(request.user, f"{kind}.undo", id=obj.id)
        return Response({"restored": kind, "id": obj.id})


# ---------- audit log / action center ----------

class AuditListView(APIView):
    def get(self, request):
        qs = AuditLog.objects.filter(user=request.user)[:200]
        return Response(AuditLogSerializer(qs, many=True).data)


# ---------- per-source permissions (feature 20) ----------

class SourcePermissionView(APIView):
    DEFAULTS = ["photo", "share", "voice", "notification"]

    def get(self, request):
        existing = {p.source: p.enabled for p in request.user.source_perms.all()}
        out = [{"source": s, "enabled": existing.get(s, True)} for s in self.DEFAULTS]
        return Response(out)

    def post(self, request):
        source = request.data.get("source")
        enabled = bool(request.data.get("enabled", True))
        if source not in self.DEFAULTS:
            return Response({"detail": "invalid source"}, status=400)
        obj, _ = SourcePermission.objects.update_or_create(
            user=request.user, source=source, defaults={"enabled": enabled})
        log(request.user, "source.toggle", source=source, enabled=enabled)
        return Response(SourcePermissionSerializer(obj).data)


# ---------- support / bug report (feature 21) ----------

class SupportViewSet(viewsets.ModelViewSet):
    serializer_class = SupportTicketSerializer

    def get_queryset(self):
        return SupportTicket.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "support.create", kind=obj.kind)


# ---------- document vault (feature 6) ----------

class DocumentViewSet(viewsets.ModelViewSet):
    serializer_class = DocumentSerializer
    http_method_names = ["get", "post", "patch", "delete"]

    def get_queryset(self):
        return Document.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "document.create", id=obj.id, title=obj.title)

    def perform_destroy(self, instance):
        log(self.request.user, "document.delete", title=instance.title)
        instance.file.delete(save=False)
        instance.delete()


class DocumentFileView(APIView):
    """Owner-only file stream — vault files are never publicly served."""
    def get(self, request, pk):
        from django.http import FileResponse, Http404
        doc = Document.objects.filter(user=request.user, pk=pk).first()
        if not doc or not doc.file:
            raise Http404()
        return FileResponse(doc.file.open("rb"))


class EmergencyCardView(APIView):
    """Feature 14 — one emergency card per user."""
    def get(self, request):
        card, _ = EmergencyCard.objects.get_or_create(user=request.user)
        return Response(EmergencyCardSerializer(card).data)

    def put(self, request):
        card, _ = EmergencyCard.objects.get_or_create(user=request.user)
        ser = EmergencyCardSerializer(card, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        ser.save()
        log(request.user, "emergency.update")
        return Response(ser.data)


# ---------- family (features 12, 13, 15) ----------
from .models import FamilyMember, Medicine, MedicineLog, SchoolItem  # noqa: E402
from .serializers import (FamilyMemberSerializer, MedicineSerializer,  # noqa: E402
                          SchoolItemSerializer)


class FamilyMemberViewSet(viewsets.ModelViewSet):
    serializer_class = FamilyMemberSerializer

    def get_queryset(self):
        return FamilyMember.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class MedicineViewSet(viewsets.ModelViewSet):
    serializer_class = MedicineSerializer

    def get_queryset(self):
        return Medicine.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "medicine.create", id=obj.id, name=obj.name)


class MedicineTakenView(APIView):
    """'খেয়েছি' confirmation for a dose."""
    def post(self, request, pk):
        med = Medicine.objects.filter(user=request.user, pk=pk).first()
        if not med:
            return Response(status=status.HTTP_404_NOT_FOUND)
        date = request.data.get("date") or timezone.localdate().isoformat()
        slot = request.data.get("slot", "")
        taken = bool(request.data.get("taken", True))
        obj, _ = MedicineLog.objects.update_or_create(
            medicine=med, date=date, slot=slot, defaults={"taken": taken})
        log(request.user, "medicine.taken", id=med.id, slot=slot)
        return Response({"ok": True, "taken": obj.taken})


class MedicineTodayView(APIView):
    """Today's medicine doses with taken-status (for self + family)."""
    def get(self, request):
        today = timezone.localdate()
        out = []
        for med in Medicine.objects.filter(user=request.user):
            if med.start_date and med.start_date > today:
                continue
            if med.end_date and med.end_date < today:
                continue
            taken_slots = set(MedicineLog.objects.filter(
                medicine=med, date=today, taken=True).values_list("slot", flat=True))
            for slot in (med.times or []):
                out.append({"medicine_id": med.id, "name": med.name,
                            "dosage": med.dosage, "member": med.member_id,
                            "slot": slot, "taken": slot in taken_slots,
                            "refill_date": med.refill_date.isoformat() if med.refill_date else None})
        out.sort(key=lambda x: x["slot"])
        return Response(out)


class SchoolItemViewSet(viewsets.ModelViewSet):
    serializer_class = SchoolItemSerializer

    def get_queryset(self):
        return SchoolItem.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class ScamCheckView(APIView):
    """Feature 13 — in-app scam checker (rule-based; reuses the web logic)."""
    def post(self, request):
        from web.logic import scam as scamlogic
        msg = request.data.get("message", "")
        if not msg.strip():
            return Response({"detail": "মেসেজ দিন।"}, status=400)
        result = scamlogic.check_message(msg)
        log(request.user, "scam.check", verdict=result["verdict"])
        return Response(result)


# ---------- money (features 7-11) ----------

class OwnedViewSet(viewsets.ModelViewSet):
    model = None
    kind = ""

    def get_queryset(self):
        return self.model.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, f"{self.kind}.create", id=obj.id)

    def perform_update(self, serializer):
        serializer.save()

    def perform_destroy(self, instance):
        log(self.request.user, f"{self.kind}.delete", id=instance.id)
        instance.delete()


class AccountViewSet(OwnedViewSet):
    model = Account; kind = "account"; serializer_class = AccountSerializer


class TransactionViewSet(OwnedViewSet):
    model = Transaction; kind = "txn"; serializer_class = TransactionSerializer

    def get_queryset(self):
        qs = Transaction.objects.filter(user=self.request.user)
        month = self.request.query_params.get("month")  # YYYY-MM
        if month:
            try:
                y, m = month.split("-")
                qs = qs.filter(date__year=int(y), date__month=int(m))
            except Exception:
                pass
        return qs


class BudgetViewSet(OwnedViewSet):
    model = Budget; kind = "budget"; serializer_class = BudgetSerializer


class LoanViewSet(OwnedViewSet):
    model = Loan; kind = "loan"; serializer_class = LoanSerializer


class SavingsGoalViewSet(OwnedViewSet):
    model = SavingsGoal; kind = "goal"; serializer_class = SavingsGoalSerializer


class SubscriptionViewSet(OwnedViewSet):
    model = Subscription; kind = "subscription"; serializer_class = SubscriptionSerializer


class MoneySummaryView(APIView):
    """Balances, current-month income/expense/net, budget 80%/100% warnings."""
    def get(self, request):
        from django.db.models import Sum
        from decimal import Decimal
        u = request.user
        now = timezone.localtime()
        y, m = now.year, now.month

        def dec(x):
            return x or Decimal("0")

        accounts = []
        total_balance = Decimal("0")
        for a in u.accounts.all():
            inc = dec(a.txns.filter(kind="income").aggregate(s=Sum("amount"))["s"])
            exp = dec(a.txns.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
            tout = dec(a.txns.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
            tin = dec(a.txns_in.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
            bal = a.opening_balance + inc - exp - tout + tin
            total_balance += bal
            accounts.append({"id": a.id, "name": a.name, "acc_type": a.acc_type,
                             "balance": str(bal)})

        month_txns = u.txns.filter(date__year=y, date__month=m)
        m_income = dec(month_txns.filter(kind="income").aggregate(s=Sum("amount"))["s"])
        m_expense = dec(month_txns.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
        by_cat = {}
        for t in month_txns.filter(kind="expense"):
            by_cat[t.category or "অন্যান্য"] = by_cat.get(t.category or "অন্যান্য", Decimal("0")) + t.amount

        budgets = []
        for b in u.budgets.all():
            spent = by_cat.get(b.category, Decimal("0"))
            pct = int(spent / b.monthly_limit * 100) if b.monthly_limit else 0
            budgets.append({"category": b.category, "limit": str(b.monthly_limit),
                            "spent": str(spent), "pct": pct,
                            "warn": "over" if pct >= 100 else ("near" if pct >= 80 else "ok")})

        loans_given = dec(u.loans.filter(kind="given", settled=False)
                          .aggregate(s=Sum("amount"))["s"])
        loans_taken = dec(u.loans.filter(kind="taken", settled=False)
                          .aggregate(s=Sum("amount"))["s"])

        return Response({
            "month": f"{y}-{m:02d}",
            "total_balance": str(total_balance),
            "accounts": accounts,
            "month_income": str(m_income),
            "month_expense": str(m_expense),
            "month_net": str(m_income - m_expense),
            "expense_by_category": {k: str(v) for k, v in by_cat.items()},
            "budgets": budgets,
            "loans_given_outstanding": str(loans_given),
            "loans_taken_outstanding": str(loans_taken),
        })


# ---------- AI status (needs-key state surfaced to the app) ----------

@api_view(["GET"])
@permission_classes([AllowAny])
def ai_status(request):
    return Response(ai.status())


# ---------- export: Excel / PDF (feature 21) ----------

class ExportExcelView(APIView):
    def get(self, request):
        import io
        from openpyxl import Workbook
        u = request.user
        wb = Workbook()
        def sheet(title, headers, rows):
            ws = wb.create_sheet(title)
            ws.append(headers)
            for r in rows:
                ws.append(r)
        wb.remove(wb.active)
        sheet("Memory", ["Category", "Title", "Detail", "Source"],
              [[m.category, m.title, m.detail, m.source] for m in u.memories.all()])
        sheet("Reminders", ["Title", "Due", "Recurrence", "Done"],
              [[r.title, str(r.due_at or ""), r.recurrence, r.done] for r in u.reminders.all()])
        sheet("Notes", ["Title", "Body", "Pinned"],
              [[n.title, n.body, n.pinned] for n in u.notes.all()])
        sheet("Todos", ["Title", "Done", "Due"],
              [[t.title, t.done, str(t.due_at or "")] for t in u.todos.all()])
        buf = io.BytesIO()
        wb.save(buf)
        log(u, "export.excel")
        resp = HttpResponse(buf.getvalue(),
                            content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        resp["Content-Disposition"] = 'attachment; filename="assisto-export.xlsx"'
        return resp


class ExportPdfView(APIView):
    def get(self, request):
        import io
        from reportlab.lib.pagesizes import A4
        from reportlab.pdfgen import canvas
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
        FONT = "Helvetica"
        try:
            if "Noto" not in pdfmetrics.getRegisteredFontNames():
                pdfmetrics.registerFont(TTFont(
                    "Noto", "/home/ubuntu/assisto/app/assets/fonts/NotoSansBengali.ttf"))
            FONT = "Noto"   # note: reportlab lacks complex shaping; conjuncts imperfect
        except Exception:
            FONT = "Helvetica"
        u = request.user
        buf = io.BytesIO()
        c = canvas.Canvas(buf, pagesize=A4)
        w, h = A4
        y = h - 50
        c.setFont(FONT, 16)
        c.drawString(40, y, "Assisto — My Data Export")
        y -= 20
        c.setFont(FONT, 9)
        c.drawString(40, y, f"User: {u.name or u.username}")
        y -= 25

        def section(title, lines):
            nonlocal y
            if y < 80:
                c.showPage(); y = h - 50
            c.setFont(FONT, 12); c.drawString(40, y, title); y -= 16
            c.setFont(FONT, 9)
            for ln in lines:
                if y < 60:
                    c.showPage(); y = h - 50; c.setFont(FONT, 9)
                c.drawString(48, y, ln[:110]); y -= 13
            y -= 8

        section("Reminders", [f"- {r.title} ({r.due_at or 'no date'})" for r in u.reminders.all()] or ["(none)"])
        section("Notes", [f"- {n.title or n.body[:40]}" for n in u.notes.all()] or ["(none)"])
        section("To-Do", [f"- [{'x' if t.done else ' '}] {t.title}" for t in u.todos.all()] or ["(none)"])
        section("Memory", [f"- {m.title}" for m in u.memories.all()] or ["(none)"])
        c.showPage(); c.save()
        log(u, "export.pdf")
        resp = HttpResponse(buf.getvalue(), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="assisto-export.pdf"'
        return resp


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
