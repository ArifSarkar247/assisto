from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
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


class ReminderSerializer(serializers.ModelSerializer):
    class Meta:
        model = Reminder
        fields = ["id", "title", "notes", "due_at", "recurrence",
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

    class Meta:
        model = Document
        fields = ["id", "title", "doc_type", "file", "file_url", "expiry_date",
                  "note", "created_at", "updated_at"]
        read_only_fields = ["id", "file_url", "created_at", "updated_at"]
        extra_kwargs = {"file": {"write_only": True, "required": False}}

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
                  "note", "date", "source", "created_at"]
        read_only_fields = ["id", "created_at"]


class BudgetSerializer(serializers.ModelSerializer):
    class Meta:
        model = Budget
        fields = ["id", "category", "monthly_limit"]
        read_only_fields = ["id"]


class LoanSerializer(serializers.ModelSerializer):
    class Meta:
        model = Loan
        fields = ["id", "kind", "person", "amount", "date", "due_date",
                  "settled", "note"]
        read_only_fields = ["id"]


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
from .models import FamilyMember, Medicine, MedicineLog, SchoolItem  # noqa: E402


class FamilyMemberSerializer(serializers.ModelSerializer):
    class Meta:
        model = FamilyMember
        fields = ["id", "name", "relation", "phone", "notes"]
        read_only_fields = ["id"]


class MedicineSerializer(serializers.ModelSerializer):
    class Meta:
        model = Medicine
        fields = ["id", "member", "name", "dosage", "times", "start_date",
                  "end_date", "refill_date", "notes", "followup_repeat_min",
                  "followup_retries", "caregiver_alert_min", "quiet_start",
                  "quiet_end", "updated_at"]
        read_only_fields = ["id", "updated_at"]


class SchoolItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = SchoolItem
        fields = ["id", "child_name", "kind", "title", "date", "amount", "done"]
        read_only_fields = ["id"]
