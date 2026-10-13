from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from .i18n import pick, req_lang
from .models import (User, MemoryItem, AuditLog, Reminder, Note, Todo,
                     SourcePermission, SupportTicket, Document, EmergencyCard,
                     Account, Transaction, Budget, Loan, SavingsGoal, Subscription)


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "name", "phone", "email", "autonomy_level", "language",
                  "date_joined", "elderly_mode", "fall_detect", "fall_countdown_sec"]
        read_only_fields = ["id", "date_joined"]


class RegisterSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=120, required=False, allow_blank=True)
    phone = serializers.CharField(max_length=24, required=False, allow_blank=True)
    email = serializers.EmailField(required=False, allow_blank=True)
    password = serializers.CharField(write_only=True, min_length=6)

    def validate(self, data):
        request = self.context.get("request")
        lang = req_lang(request) if request is not None else "bn"
        phone = (data.get("phone") or "").strip()
        email = (data.get("email") or "").strip().lower()
        if not phone and not email:
            raise serializers.ValidationError(pick(lang,
                "ফোন নম্বর বা ইমেইল — অন্তত একটা দিন।",
                "Enter at least one — a phone number or an email."))
        if phone and User.objects.filter(phone=phone).exists():
            raise serializers.ValidationError(pick(lang,
                "এই ফোন নম্বর আগে থেকেই আছে।",
                "This phone number is already registered."))
        if email and User.objects.filter(email=email).exists():
            raise serializers.ValidationError(pick(lang,
                "এই ইমেইল আগে থেকেই আছে।",
                "This email is already registered."))
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


class ReminderSerializer(serializers.ModelSerializer):
    class Meta:
        model = Reminder
        fields = ["id", "title", "notes", "due_at", "recurrence",
                  "recurrence_rule", "date_only", "link",
                  "remind_before_min", "done", "source", "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]


class NoteSerializer(serializers.ModelSerializer):
    class Meta:
        model = Note
        fields = ["id", "title", "body", "pinned", "source", "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]


class TodoSerializer(serializers.ModelSerializer):
    class Meta:
        model = Todo
        fields = ["id", "title", "done", "due_at", "source", "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]


class SourcePermissionSerializer(serializers.ModelSerializer):
    class Meta:
        model = SourcePermission
        fields = ["id", "source", "enabled"]
        read_only_fields = ["id"]


class SupportTicketSerializer(serializers.ModelSerializer):
    class Meta:
        model = SupportTicket
        fields = ["id", "kind", "message", "screenshot", "app_version",
                  "resolved", "reply", "created_at"]
        read_only_fields = ["id", "resolved", "reply", "created_at"]


class DocumentSerializer(serializers.ModelSerializer):
    file_url = serializers.SerializerMethodField()
    # Accept `details` as a JSON object (JSON body) OR a JSON-encoded string
    # (multipart upload can't nest objects). JSONField handles the object path;
    # to_internal_value below json.loads()es the string path. Values with
    # ; | = stay intact (vault P1 fix).
    details = serializers.JSONField(required=False)

    class Meta:
        model = Document
        fields = ["id", "title", "doc_type", "file", "file_url", "expiry_date",
                  "note", "details", "created_at", "updated_at"]
        read_only_fields = ["id", "file_url", "created_at", "updated_at"]
        extra_kwargs = {"file": {"write_only": True, "required": False}}

    def to_internal_value(self, data):
        # Multipart form fields arrive as strings; decode a JSON-encoded `details`.
        raw = data.get("details") if hasattr(data, "get") else None
        if isinstance(raw, str) and raw.strip():
            import json as _json
            try:
                decoded = _json.loads(raw)
                data = data.copy() if hasattr(data, "copy") else dict(data)
                data["details"] = decoded
            except (ValueError, TypeError):
                pass
        return super().to_internal_value(data)

    def get_file_url(self, obj):
        return f"/api/v1/documents/{obj.id}/file" if obj.file else None


class EmergencyCardSerializer(serializers.ModelSerializer):
    class Meta:
        model = EmergencyCard
        fields = ["blood_group", "allergies", "medicines", "conditions",
                  "notes", "contacts", "updated_at"]
        read_only_fields = ["updated_at"]


# ---------------- money (feature 7-11) ----------------
class AccountSerializer(serializers.ModelSerializer):
    class Meta:
        model = Account
        fields = ["id", "name", "acc_type", "opening_balance", "created_at"]
        read_only_fields = ["id", "created_at"]


class TransactionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Transaction
        fields = ["id", "account", "to_account", "kind", "amount", "category",
                  "note", "date", "source", "ref", "split_with", "split_mode", "created_at"]
        read_only_fields = ["id", "created_at"]


class BudgetSerializer(serializers.ModelSerializer):
    class Meta:
        model = Budget
        fields = ["id", "category", "monthly_limit", "rollover"]
        read_only_fields = ["id"]


class LoanSerializer(serializers.ModelSerializer):
    balance = serializers.SerializerMethodField()
    paid = serializers.SerializerMethodField()
    progress_pct = serializers.SerializerMethodField()
    ledger = serializers.SerializerMethodField()

    class Meta:
        model = Loan
        fields = ["id", "kind", "person", "amount", "date", "due_date",
                  "settled", "note", "repayments", "balance", "paid",
                  "progress_pct", "ledger"]
        read_only_fields = ["id", "balance", "paid", "progress_pct", "ledger"]

    def _calc(self, obj):
        from .logic import money_engine as me
        return me.loan_balance({"amount": obj.amount, "kind": obj.kind,
                                "repayments": obj.repayments or [],
                                "settled": obj.settled, "date": str(obj.date or "")})

    def get_balance(self, o): return str(self._calc(o)["balance"])
    def get_paid(self, o): return str(self._calc(o)["paid"])
    def get_progress_pct(self, o): return self._calc(o)["progress_pct"]
    def get_ledger(self, o):
        return [{**e, "amount": str(e["amount"]), "balance": str(e["balance"])}
                for e in self._calc(o)["ledger"]]


class SavingsGoalSerializer(serializers.ModelSerializer):
    class Meta:
        model = SavingsGoal
        fields = ["id", "title", "target_amount", "saved_amount", "due_date"]
        read_only_fields = ["id"]


class SubscriptionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Subscription
        fields = ["id", "name", "amount", "cycle", "next_due"]
        read_only_fields = ["id"]


class WatcherSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Watcher
        model = Watcher
        fields = ["id", "kind", "label", "config", "enabled", "interval_min",
                  "last_checked", "last_value"]
        read_only_fields = ["id", "last_checked", "last_value"]


class ContactSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Contact
        model = Contact
        fields = ["id", "name", "phone", "org", "note", "tags", "next_followup"]
        read_only_fields = ["id"]


class MeetingSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Meeting
        model = Meeting
        fields = ["id", "contact", "title", "when", "summary"]
        read_only_fields = ["id"]


class AutoPayRuleSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import AutoPayRule
        model = AutoPayRule
        fields = ["id", "biller", "step", "max_amount", "enabled"]
        read_only_fields = ["id"]


class ProductSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Product
        model = Product
        fields = ["id", "name", "price", "stock", "sku", "description", "updated_at"]
        read_only_fields = ["id", "updated_at"]


class OrderSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Order
        model = Order
        fields = ["id", "customer_name", "customer_phone", "address", "items",
                  "total", "status", "courier", "tracking", "channel", "created_at"]
        read_only_fields = ["id", "created_at"]


class NomineeSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import Nominee
        model = Nominee
        fields = ["id", "name", "contact", "scope", "inactivity_days",
                  "activated", "activated_at"]
        read_only_fields = ["id", "activated", "activated_at"]


class JobApplicationSerializer(serializers.ModelSerializer):
    class Meta:
        from .models import JobApplication
        model = JobApplication
        fields = ["id", "title", "company", "source", "jd", "match_score",
                  "match_reason", "cv_text", "cover_letter", "status",
                  "applied_at", "followup_at", "created_at"]
        read_only_fields = ["id", "match_score", "match_reason", "created_at"]


# ---------------- family (feature 12/15) ----------------
from .models import (FamilyMember, Medicine, MedicineLog, SchoolItem,  # noqa: E402
                     Doctor, Prescription)


class FamilyMemberSerializer(serializers.ModelSerializer):
    class Meta:
        model = FamilyMember
        fields = ["id", "name", "relation", "phone", "notes"]
        read_only_fields = ["id"]


class DoctorSerializer(serializers.ModelSerializer):
    class Meta:
        model = Doctor
        fields = ["id", "name", "specialty", "hospital", "phone", "notes", "updated_at"]
        read_only_fields = ["id", "updated_at"]


class PrescriptionSerializer(serializers.ModelSerializer):
    doctor_display = serializers.SerializerMethodField()

    class Meta:
        model = Prescription
        fields = ["id", "member", "doctor", "doctor_name", "doctor_display",
                  "date", "diagnosis", "meds", "notes", "created_at"]
        read_only_fields = ["id", "doctor_display", "created_at"]

    def get_doctor_display(self, obj):
        if obj.doctor_id and obj.doctor:
            return obj.doctor.name
        return obj.doctor_name or ""


class MedicineSerializer(serializers.ModelSerializer):
    # derived, read-only insight fields (computed in to_representation)
    stock_count = serializers.FloatField(allow_null=True, required=False)
    days_left = serializers.SerializerMethodField()
    refill_status = serializers.SerializerMethodField()
    predicted_refill = serializers.SerializerMethodField()
    adherence_30d = serializers.SerializerMethodField()

    class Meta:
        model = Medicine
        fields = ["id", "member", "prescription", "name", "dosage", "times",
                  "start_date", "end_date", "refill_date", "notes",
                  "food_relation", "dose_qty", "as_needed", "duration_days",
                  "taper", "stock_count", "refill_warn_days",
                  "prn_per_day",
                  "followup_repeat_min", "followup_retries", "caregiver_alert_min",
                  "quiet_start", "quiet_end", "days_left", "refill_status",
                  "predicted_refill", "adherence_30d", "updated_at"]
        read_only_fields = ["id", "days_left", "refill_status",
                            "predicted_refill", "adherence_30d", "updated_at"]

    def get_days_left(self, obj):
        from .logic import medicine as mlogic
        return mlogic.days_left(obj.stock_count, obj.times, obj.dose_qty,
                                prn=obj.as_needed, prn_per_day=obj.prn_per_day)

    def get_refill_status(self, obj):
        from .logic import medicine as mlogic
        status, _ = mlogic.refill_warning(
            obj.stock_count, obj.times, obj.dose_qty,
            warn_days=obj.refill_warn_days, prn=obj.as_needed,
            prn_per_day=obj.prn_per_day)
        return status

    def get_predicted_refill(self, obj):
        """The run-out date predicted from current stock + burn rate (P1).
        Falls back to the manually-set refill_date when stock isn't tracked."""
        from .logic import medicine as mlogic
        from django.utils import timezone
        d = mlogic.predicted_refill_date(
            obj.stock_count, obj.times, obj.dose_qty,
            today=timezone.localdate(), prn=obj.as_needed,
            prn_per_day=obj.prn_per_day)
        if d is None:
            return obj.refill_date.isoformat() if obj.refill_date else None
        return d.isoformat()

    def get_adherence_30d(self, obj):
        from datetime import timedelta
        from django.utils import timezone
        from .logic import medicine as mlogic
        today = timezone.localdate()
        taken_set = {(log.date.isoformat(), log.slot) for log in
                     obj.logs.filter(taken=True)}
        pct, _, _ = mlogic.adherence_for_med(
            obj.times, obj.start_date, obj.end_date, taken_set,
            today - timedelta(days=29), today, prn=obj.as_needed)
        return pct


class SchoolItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = SchoolItem
        fields = ["id", "child_name", "kind", "title", "date", "amount", "done"]
        read_only_fields = ["id"]


# ---------------- module 5 (P13+) ----------------
from .models import Birthday, Appointment  # noqa: E402


class BirthdaySerializer(serializers.ModelSerializer):
    class Meta:
        model = Birthday
        fields = ["id", "name", "date", "kind", "lead_days", "created_at"]
        read_only_fields = ["id", "created_at"]


class AppointmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Appointment
        fields = ["id", "title", "start", "duration_min", "place",
                  "place_lat", "place_lng", "note", "created_at"]
        read_only_fields = ["id", "created_at"]
