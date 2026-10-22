import base64
import binascii
import uuid

from django.core.files.base import ContentFile
from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from .i18n import pick, req_lang
from .models import (User, MemoryItem, AuditLog, Reminder, Note, Todo,
                     SourcePermission, SupportTicket, Document, EmergencyCard,
                     Account, Transaction, Budget, Loan, SavingsGoal, Subscription)


class Base64OrFileImageField(serializers.ImageField):
    """Accepts an avatar as EITHER a real multipart upload (the normal
    ImageField path) OR a base64 string (optionally a ``data:`` URL), which is
    how the Flutter profile editor sends the cropped square. An empty string
    means "remove the photo". This is the real fix for the profile-picture save
    bug: the app PATCHes JSON with ``photo`` as a base64 string, and a plain
    ImageField rejected it ("submitted data was not a file") → the whole
    PATCH 400'd and nothing saved."""

    def to_internal_value(self, data):
        if isinstance(data, str):
            s = data.strip()
            if s == "":
                return ""  # explicit remove — handled in update()
            # Strip an optional data: URL header (data:image/png;base64,....).
            if s.startswith("data:") and "," in s:
                s = s.split(",", 1)[1]
            try:
                decoded = base64.b64decode(s, validate=True)
            except (binascii.Error, ValueError):
                self.fail("invalid")
            data = ContentFile(decoded, name=f"{uuid.uuid4().hex}.png")
        return super().to_internal_value(data)


class VisibilityBooleanField(serializers.BooleanField):
    """The profile editor sends a visibility TOKEN (circle/family/nobody, or
    everyone/none) for ``show_phone`` rather than a raw bool — a plain
    BooleanField 400'd on "circle" and blocked the whole profile save. Map it:
    anything that is not an explicit "hide" means the phone may be shown."""

    def to_internal_value(self, data):
        if isinstance(data, str):
            v = data.strip().lower()
            if v in ("nobody", "none", "0", "off", "no"):
                return False
            if v in ("circle", "family", "everyone", "all", "yes", "on"):
                return True
        return super().to_internal_value(data)


class UserSerializer(serializers.ModelSerializer):
    # Resolved avatar URL (uploaded file or external link); read-only +
    # absolute (built against the request so the app can load it directly).
    photo_url = serializers.SerializerMethodField()
    # Accept base64 (app) or a multipart file; "" removes.
    photo = Base64OrFileImageField(required=False, allow_null=True)
    # Accept the app's visibility token (circle/family/nobody) OR a bool.
    show_phone = VisibilityBooleanField(required=False)
    # f1-founders: Founding Member badge (read-only; owner-granted only).
    founding_member = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = ["id", "name", "phone", "email", "autonomy_level", "language",
                  "date_joined", "elderly_mode", "fall_detect", "fall_countdown_sec",
                  # Step 3 Messenger profile fields
                  "photo", "photo_link", "photo_url",
                  "show_phone", "communities_who_can_msg",
                  "public_surfaces_enabled", "is_founder", "founding_member"]
        read_only_fields = ["id", "date_joined", "photo_url",
                            "is_founder", "founding_member",
                            # owner-only switch: never self-set via profile PUT
                            "public_surfaces_enabled"]

    def get_founding_member(self, obj):
        from . import plans
        return plans.founding_member(obj)

    def get_photo_url(self, obj):
        """Absolute avatar URL served through the authed avatar view (uploaded
        file) or the external link. Empty string when there is no photo."""
        request = self.context.get("request")
        if obj.photo:
            try:
                # Cache-buster keyed off the stored file NAME (a fresh uuid per
                # upload) so replacing the photo yields a new URL and clients
                # refetch immediately instead of showing the old cached image.
                import hashlib
                tag = hashlib.md5(
                    str(obj.photo.name).encode()).hexdigest()[:8]
                path = f"/api/v1/me/avatar?v={tag}"
                return request.build_absolute_uri(path) if request else path
            except Exception:
                return ""
        return obj.photo_link or ""

    def validate_phone(self, value):
        """c1-contacts: a profile phone change is stored canonical; invalid
        numbers and numbers already used by another account (in ANY format)
        are refused honestly."""
        raw = (value or "").strip()
        if not raw:
            return None
        from .phone import canonical_phone, variants
        request = self.context.get("request")
        lang = req_lang(request) if request is not None else "bn"
        canon = canonical_phone(raw)
        if not canon:
            raise serializers.ValidationError(pick(lang,
                "ফোন নম্বরটি সঠিক নয়। যেমন: ০১৭১২৩৪৫৬৭৮",
                "That phone number doesn't look right. Example: 01712345678"))
        qs = User.objects.filter(phone__in=variants(canon))
        if self.instance is not None:
            qs = qs.exclude(pk=self.instance.pk)
        if qs.exists():
            raise serializers.ValidationError(pick(lang,
                "এই ফোন নম্বর আগে থেকেই আছে।",
                "This phone number is already registered."))
        return canon

    def update(self, instance, validated_data):
        # An explicit empty-string photo means "remove it" (delete the file).
        if "photo" in validated_data and validated_data["photo"] == "":
            if instance.photo:
                instance.photo.delete(save=False)
            instance.photo = None
            validated_data.pop("photo")
        return super().update(instance, validated_data)


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
        if phone:
            # c1-contacts: ONE canonical form (+8801XXXXXXXXX); any input
            # format accepted, invalid numbers rejected honestly, and the
            # duplicate check covers every legacy spelling.
            from .phone import canonical_phone, variants
            canon = canonical_phone(phone)
            if not canon:
                raise serializers.ValidationError(pick(lang,
                    "ফোন নম্বরটি সঠিক নয়। যেমন: ০১৭১২৩৪৫৬৭৮",
                    "That phone number doesn't look right. Example: 01712345678"))
            if User.objects.filter(phone__in=variants(canon)).exists():
                raise serializers.ValidationError(pick(lang,
                    "এই ফোন নম্বর আগে থেকেই আছে।",
                    "This phone number is already registered."))
            phone = canon
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
    # doc_type is a CLIENT-SIDE category and the app's vault type list grows
    # (device/insurance/warranty, ...). The model keeps `choices` only for the
    # Django admin dropdown; the auto-generated ChoiceField must NOT 400 a type
    # the app legitimately uses. Accept any short string (fixes a pre-existing
    # bug where insurance/warranty docs were rejected).
    doc_type = serializers.CharField(required=False, max_length=16, default="other")

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
    # `card` carries the advanced-card extras: name, doctor, insurance,
    # nid_ref (reference string only), organ_donor (bool).
    card = serializers.JSONField(required=False)

    class Meta:
        model = EmergencyCard
        fields = ["blood_group", "allergies", "medicines", "conditions",
                  "notes", "contacts", "card", "updated_at"]
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
    # `details` round-trips the advanced-UI fields (category, payment_method,
    # trial_end, auto_renew, notes, icon, colour, status, custom_days, …).
    # Accept a JSON object or a JSON-encoded string (multipart can't nest).
    details = serializers.JSONField(required=False)

    class Meta:
        model = Subscription
        fields = ["id", "name", "amount", "cycle", "next_due", "details"]
        read_only_fields = ["id"]

    def to_internal_value(self, data):
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


class PaymentDebtSerializer(serializers.ModelSerializer):
    """Payment-ladder debt row (SPEC v2.1 §21). Exposes the debt fields + nested
    `ladder`. On save it validates the ladder with the pure engine and maps the
    returned codes to localised messages. HARD RULE: any auto_charge/auto_pay step
    is rejected (`no_auto_charge`) — there is no auto-charge action in the
    vocabulary; the engine never holds or moves money on its own."""
    class Meta:
        from .models import PaymentDebt
        model = PaymentDebt
        fields = ["id", "kind", "party", "amount_poisha", "paid_poisha",
                  "due_date", "recurring_days", "paused", "ladder",
                  "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]

    def validate_ladder(self, value):
        from .logic import payment_ladder as PL
        ladder = dict(value or {})
        # The viewset fixes `kind` per collection; mirror it onto the ladder so
        # the engine's bad_kind check passes for a valid ladder.
        view = self.context.get("view")
        if view is not None and getattr(view, "kind_value", None):
            ladder.setdefault("kind", view.kind_value)
        request = self.context.get("request")
        lang = req_lang(request) if request is not None else "bn"
        msgs = {
            "bad_kind": ("ল্যাডারের ধরন ভুল।", "Invalid ladder kind."),
            "no_steps": ("অন্তত একটি ধাপ দিন।", "Add at least one step."),
            "bad_step": ("একটি ধাপের তথ্য ভুল।", "A step is malformed."),
            "bad_channel": ("অজানা চ্যানেল।", "Unknown channel."),
            "duplicate_offset": ("দুটি ধাপের সময় একই।",
                                 "Two steps share the same timing."),
            # Never-auto-charge invariant — rejected server-side, always.
            "no_auto_charge": ("অটো-চার্জ অনুমোদিত নয়।",
                               "Auto-charge is not allowed."),
        }
        problems = PL.validate_ladder(ladder)
        if problems:
            raise serializers.ValidationError(
                [pick(lang, *msgs.get(p, (p, p))) for p in problems])
        return value


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


def _nominee_row(obj):
    """Plain dict of a Nominee model instance in the shape core.logic.nominee
    expects (ISO strings for datetimes). Used by both the serializer and views
    so the pure state-machine stays the single source of truth."""
    return {
        "name": obj.name,
        "contact": obj.contact,
        "relationship": obj.relationship,
        "scopes": obj.scopes or [],
        "scope": obj.scope,
        "priority": obj.priority,
        "trigger": obj.trigger,
        "inactivity_days": obj.inactivity_days,
        "grace_hours": obj.grace_hours,
        "multi_verify_ids": obj.multi_verify_ids or [],
        "multi_verify_quorum": obj.multi_verify_quorum,
        "release_state": obj.release_state,
        "release_pending": obj.release_pending,
        "release_requested_at": obj.release_requested_at.isoformat()
        if obj.release_requested_at else None,
        "release_confirmations": obj.release_confirmations or [],
        "activated": obj.activated,
        "activated_at": obj.activated_at.isoformat() if obj.activated_at else None,
    }


class NomineeSerializer(serializers.ModelSerializer):
    # grace-window release lifecycle. release_* + activated* are
    # SERVER-AUTHORITATIVE: they are set ONLY by the validated transitions in
    # core.logic.nominee, never by a raw client PATCH, so a client can never
    # forge an `open` state. `release_pending` is writeable intent only — the
    # view translates it through the logic layer; the stored value remains the
    # server's mirror.
    scopes = serializers.JSONField(required=False)
    grace_remaining_seconds = serializers.SerializerMethodField()

    class Meta:
        from .models import Nominee
        model = Nominee
        fields = ["id", "name", "contact", "scope", "scopes", "relationship",
                  "priority", "trigger", "inactivity_days", "grace_hours",
                  "multi_verify_ids", "multi_verify_quorum",
                  "release_state", "release_pending", "release_requested_at",
                  "release_confirmations", "grace_remaining_seconds",
                  "activated", "activated_at", "created_at"]
        read_only_fields = ["id", "release_state", "release_requested_at",
                            "release_confirmations", "grace_remaining_seconds",
                            "activated", "activated_at", "created_at"]

    def get_grace_remaining_seconds(self, obj):
        from .logic import nominee as nlogic
        return nlogic.grace_remaining_seconds(_nominee_row(obj))


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


class PaItemSerializer(serializers.ModelSerializer):
    """Flatten the PaCollectionItem into {id, ...data} on read, and fold every
    client field (except id) into `data` on write — so the PA screens round-trip
    arbitrary row shapes through one model without a schema per collection."""
    class Meta:
        from .models import PaCollectionItem
        model = PaCollectionItem
        fields = ["id", "data"]
        read_only_fields = ["id"]

    def to_representation(self, instance):
        out = dict(instance.data or {})
        out["id"] = instance.id
        return out

    def to_internal_value(self, data):
        d = {k: v for k, v in (data or {}).items() if k != "id"}
        return {"data": d}
