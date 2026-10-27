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

from .models import (User, MemoryItem, AuditLog, PendingAction, Reminder, Note,
                     Todo, SourcePermission, SupportTicket, Document, EmergencyCard,
                     Account, Transaction, Budget, Loan, SavingsGoal, Subscription,
                     NightBriefing, WaitlistEntry, SafetyCheckin, FamilyAlert)
from .serializers import (
    UserSerializer, RegisterSerializer, LoginSerializer,
    MemoryItemSerializer, AuditLogSerializer, ReminderSerializer,
    NoteSerializer, TodoSerializer, SourcePermissionSerializer,
    SupportTicketSerializer, DocumentSerializer, EmergencyCardSerializer,
    AccountSerializer, TransactionSerializer, BudgetSerializer, LoanSerializer,
    SavingsGoalSerializer, SubscriptionSerializer,
)
from . import ai
from .i18n import req_lang, pick

API_VERSION = "v1"
BUILD_PART = 1  # which V1 part this backend serves


def log(user, action, **detail):
    AuditLog.objects.create(user=user, action=action, detail=detail)


def _photo_bytes(user):
    """Current avatar file size in bytes (0 when none / external link)."""
    try:
        return int(user.photo.size) if getattr(user, "photo", None) else 0
    except Exception:
        return 0


def storage_full_response(user):
    """Business Model (Build 3) — the shared 413 'storage_full' response for a
    media/file/backup upload a user has no quota left for. Callers MUST check
    billing.storage_state(user)['full'] BEFORE saving and return this (without
    saving) when full. SAFETY (SOS/anti-theft photos), text and calls NEVER call
    this — they are never gated by storage."""
    from . import billing
    return Response({"error": "storage_full", "state": billing.storage_state(user)},
                    status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)


def _mark_export_downloaded(user):
    """If the user has a PENDING deletion request, record that they downloaded
    their data (the delete preview surfaces this so "Download my data first" can
    be confirmed). Never raises."""
    try:
        from .models import AccountDeletionRequest
        AccountDeletionRequest.objects.filter(
            user=user, state=AccountDeletionRequest.STATE_PENDING
        ).update(export_downloaded=True)
    except Exception:
        pass


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
    # t1-ticks 1c: My Circle minimum build (admin: limits.my_circle_min_version)
    from .views_t1_ticks import min_version
    data["my_circle_min_version"] = min_version()
    return Response(data)


def _sms_otp_on():
    from . import otp
    return otp.sms_available()


@api_view(["GET"])
@permission_classes([AllowAny])
def version(request):
    return Response({
        "app": "Assisto",
        "api": API_VERSION,
        "part": BUILD_PART,
        "base_url": settings.ASSISTO_BASE_URL,
        "features": {
            "sms_otp": _sms_otp_on(),
            "ai": settings.AI_ENABLED,
        },
    })


# ---------- auth ----------

class RegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        # o1-otp launch gate: with admin flag auth_password_only_signup OFF,
        # sign-up REQUIRES an otp_proof (purpose=signup) for the given phone.
        from . import otp
        from .views_otp import signup_gate_response
        lang = req_lang(request)
        proof = str((request.data or {}).get("otp_proof") or "").strip()
        if not proof and not otp.password_only_signup_allowed():
            return signup_gate_response(lang)
        ser = RegisterSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        canon = None
        if proof:
            canon = otp.normalize_bd_phone(ser.validated_data.get("phone"))
            if not canon:
                return Response({"ok": False, "reason": "bad_phone",
                                 "detail": otp.message("bad_phone", lang)},
                                status=status.HTTP_400_BAD_REQUEST)
            if otp.find_user_by_phone(canon) is not None:
                return Response({"ok": False, "reason": "already_registered",
                                 "detail": otp.message("already_registered", lang)},
                                status=status.HTTP_400_BAD_REQUEST)
            if otp.consume_proof(proof, "signup", canon) is None:
                return Response({"ok": False, "reason": "bad_otp",
                                 "detail": otp.message("bad_otp", lang)},
                                status=status.HTTP_403_FORBIDDEN)
            ser.validated_data["phone"] = canon  # c1: one canonical form
        user = ser.save()
        if canon:
            otp.mark_verified(user, canon)
        token, _ = Token.objects.get_or_create(user=user)
        from . import plans
        if plans.trial_on_signup():   # p2-money: default OFF — trial button
            plans.start_trial(user)
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
        # c1-contacts: a phone typed in ANY format (01…, +880…, spaces,
        # Bangla digits) finds the account, including legacy spellings.
        from .phone import find_user as _find_by_phone
        user = (_find_by_phone(ident)
                or User.objects.filter(phone=ident).first()
                or User.objects.filter(email=ident.lower()).first()
                or User.objects.filter(username=ident).first())
        if not user or not user.check_password(password) or not user.is_active:
            lang = req_lang(request)
            return Response({"detail": pick(lang, "ভুল তথ্য। আবার চেষ্টা করুন।",
                                            "Those details didn't match. Please try again.")},
                            status=status.HTTP_401_UNAUTHORIZED)
        from .account_block import is_blocked, blocked_message
        if is_blocked(user):   # o2-admin: blocked accounts cannot sign in
            return Response({"reason": "account_blocked",
                             "detail": blocked_message(req_lang(request))},
                            status=status.HTTP_403_FORBIDDEN)
        token, _ = Token.objects.get_or_create(user=user)
        log(user, "account.login")
        return Response({"token": token.key, "user": UserSerializer(user).data})


class LogoutView(APIView):
    def post(self, request):
        Token.objects.filter(user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


# o1-otp: the real OTP flow lives in views_otp (key-gated; honest 503 when the
# SMS gateway isn't connected — never 501). Kept under the old name so the
# existing auth/otp/request route is unchanged.
from .views_otp import OtpRequestView as OTPRequestView  # noqa: E402


# ---------- profile ----------

class MeView(APIView):
    def get(self, request):
        return Response(UserSerializer(request.user,
                                       context={"request": request}).data)

    def patch(self, request):
        from . import billing
        # Build 3 STORAGE GATE: setting a NEW avatar is a media upload. Gate it
        # (and only it) — the rest of the profile PATCH (name, elderly_mode, …)
        # is never storage-bound. If full AND a new photo is incoming, refuse the
        # whole PATCH with 413 so nothing (incl. the photo) is saved.
        setting_photo = ("photo" in request.data and request.data.get("photo"))
        if setting_photo and billing.storage_state(request.user)["full"]:
            return storage_full_response(request.user)
        before = _photo_bytes(request.user)
        ser = UserSerializer(request.user, data=request.data, partial=True,
                             context={"request": request})
        ser.is_valid(raise_exception=True)
        ser.save()
        if "photo" in request.data:
            request.user.refresh_from_db(fields=["photo"])
            after = _photo_bytes(request.user)
            if after != before:
                try:
                    billing.add_storage(request.user, after - before)
                except Exception:
                    pass
        log(request.user, "profile.update", fields=list(request.data.keys()))
        return Response(ser.data)


class MeAvatarView(APIView):
    """Authed avatar stream — mirrors the vault DocumentFileView / lost-phone
    CapturedPhotoView pattern: the uploaded profile photo is served through an
    auth-checked view (never a public MEDIA URL). The `?v=` cache-buster in the
    URL changes whenever the photo changes, so clients refetch immediately."""
    def get(self, request):
        from django.http import FileResponse, Http404
        user = request.user
        if not user.photo:
            raise Http404()
        return FileResponse(user.photo.open("rb"))


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
        lang = req_lang(request)
        since = timezone.now() - timedelta(seconds=180)
        candidates = (AuditLog.objects.filter(user=request.user, action__endswith=".delete",
                                              created_at__gte=since).order_by("-created_at")[:10])
        entry = next((e for e in candidates if not e.detail.get("undone")), None)
        if not entry:
            return Response({"detail": pick(lang, "ফিরিয়ে আনার মতো কিছু নেই।",
                                            "Nothing to undo.")},
                            status=status.HTTP_404_NOT_FOUND)
        kind = entry.detail.get("kind")
        data = entry.detail.get("undo") or {}
        model, ser = _UNDO_MAP.get(kind, (None, None))
        if not model:
            return Response({"detail": pick(lang, "সম্ভব নয়।", "Can't undo this.")},
                            status=status.HTTP_400_BAD_REQUEST)
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


# ---------- Action Center: pending-approval queue (SPEC v2.1 §21, feature #9) ----------

def _pending_json(p):
    """Serialise a PendingAction to the shape the app's PendingAction.fromJson
    expects: kind -> action, payload -> detail. Owner-scoped by the caller."""
    return {
        "id": p.id,
        "action": p.kind,
        "module": p.module,
        "title": p.title,
        "summary": p.summary,
        "autonomy_level": p.autonomy_level,
        "created_at": p.created_at.isoformat(),
        "detail": p.payload or {},
    }


class PendingActionsView(APIView):
    """GET /actions/pending -> {pending:[...]} — only the current user's rows
    still waiting for approval. Owner-scoped; never leaks another user's queue.
    The app degrades to an empty 'nothing waiting' list if this is absent."""
    def get(self, request):
        qs = PendingAction.objects.filter(user=request.user,
                                          status=PendingAction.PENDING)
        return Response({"pending": [_pending_json(p) for p in qs]})


class PendingActionApproveView(APIView):
    """POST /actions/<id>/approve {edit?} -> {ok, done:{...}}.

    Merges the user's edit (a tweak to a draftable field) into the prepared
    payload, marks the row done, and writes the matching AuditLog row so the
    DONE tab / audit trail reflects it. The ACTUAL execution of side-effecting
    kinds (sending a message, etc.) is the AI/module executor's job — this view
    owns the approval + audit seam only, which is what makes the action truthful
    and undoable. Returns the merged payload as `done` so the UI can confirm."""
    def post(self, request, pk):
        lang = req_lang(request)
        p = PendingAction.objects.filter(user=request.user, pk=pk).first()
        if not p or p.status != PendingAction.PENDING:
            return Response({"detail": pick(lang, "অপেক্ষমাণ কিছু নেই।",
                                            "Nothing pending here.")}, status=404)
        edit = request.data.get("edit") or {}
        if isinstance(edit, dict) and edit:
            payload = dict(p.payload or {})
            payload.update(edit)
            p.payload = payload
        p.status = PendingAction.DONE
        p.acted_at = timezone.now()
        p.save(update_fields=["payload", "status", "acted_at"])
        # Audit trail uses the SAME dotted key the direct action would.
        log(request.user, p.kind, pending_id=p.id, title=p.title,
            payload=p.payload or {})
        return Response({"ok": True, "done": {"id": p.id, "action": p.kind,
                                              "payload": p.payload or {}}})


class PendingActionRejectView(APIView):
    """POST /actions/<id>/reject {reason?} -> {ok}. Discards a prepared action;
    the rejection itself is audit-logged (action=`<kind>.reject`)."""
    def post(self, request, pk):
        lang = req_lang(request)
        p = PendingAction.objects.filter(user=request.user, pk=pk).first()
        if not p or p.status != PendingAction.PENDING:
            return Response({"detail": pick(lang, "অপেক্ষমাণ কিছু নেই।",
                                            "Nothing pending here.")}, status=404)
        reason = (request.data.get("reason") or "").strip()
        p.status = PendingAction.REJECTED
        p.acted_at = timezone.now()
        p.save(update_fields=["status", "acted_at"])
        log(request.user, f"{p.kind}.reject", pending_id=p.id, reason=reason)
        return Response({"ok": True})


class ActionLogView(APIView):
    """GET /actions/log -> the DONE / audit list. Alias of the existing audit
    log (AuditLog is the single source of truth for 'what happened'), kept so the
    Action Center has a cohesive /actions/* surface. Owner-scoped, newest-first."""
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
            lang = req_lang(request)
            return Response({"detail": pick(lang, "অবৈধ সোর্স।", "Invalid source.")}, status=400)
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

    def create(self, request, *args, **kwargs):
        # Build 3 STORAGE GATE: a vault document upload is bulk media. If the
        # user's quota is already full, refuse the NEW file with 413 and save
        # nothing. (Metadata-only PATCHes go through update(), never gated.)
        from . import billing
        up = request.FILES.get("file")
        if up is not None and billing.storage_state(request.user)["full"]:
            return storage_full_response(request.user)
        return super().create(request, *args, **kwargs)

    def perform_create(self, serializer):
        from . import billing
        obj = serializer.save(user=self.request.user)
        if obj.file:
            try:
                billing.add_storage(self.request.user, obj.file.size)
            except Exception:
                pass
        log(self.request.user, "document.create", id=obj.id, title=obj.title)

    def perform_destroy(self, instance):
        from . import billing
        log(self.request.user, "document.delete", title=instance.title)
        freed = 0
        try:
            if instance.file:
                freed = instance.file.size
        except Exception:
            freed = 0
        instance.file.delete(save=False)
        instance.delete()
        if freed:
            try:
                billing.add_storage(self.request.user, -freed)
            except Exception:
                pass


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
from .models import (FamilyMember, Medicine, MedicineLog, SchoolItem,  # noqa: E402
                     Doctor, Prescription)
from .serializers import (FamilyMemberSerializer, MedicineSerializer,  # noqa: E402
                          SchoolItemSerializer, DoctorSerializer,
                          PrescriptionSerializer)
from .logic import medicine as mlogic  # noqa: E402


class FamilyMemberViewSet(viewsets.ModelViewSet):
    serializer_class = FamilyMemberSerializer

    def get_queryset(self):
        return FamilyMember.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class DoctorViewSet(viewsets.ModelViewSet):
    serializer_class = DoctorSerializer

    def get_queryset(self):
        return Doctor.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class PrescriptionViewSet(viewsets.ModelViewSet):
    serializer_class = PrescriptionSerializer

    def get_queryset(self):
        qs = Prescription.objects.filter(user=self.request.user)
        doctor = self.request.query_params.get("doctor")
        member = self.request.query_params.get("member")
        if doctor:
            qs = qs.filter(doctor_id=doctor)
        if member:
            qs = qs.filter(member_id=member)
        return qs

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "prescription.create", id=obj.id)


class MedicineViewSet(viewsets.ModelViewSet):
    serializer_class = MedicineSerializer

    def get_queryset(self):
        qs = Medicine.objects.filter(user=self.request.user)
        member = self.request.query_params.get("member")
        if member == "self":
            qs = qs.filter(member__isnull=True)
        elif member:
            qs = qs.filter(member_id=member)
        return qs

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "medicine.create", id=obj.id, name=obj.name)


class MedicineTakenView(APIView):
    """Record a dose outcome: taken (default), skipped, or undo.
    Taken decrements inventory; undo restores it. Idempotent per (date, slot)
    for scheduled doses.

    PRN (as-needed) meds (P4): the client posts slot 'prn' for a NEW event and
    we stamp it 'prn-HH:MM:SS' so each painkiller can be logged many times/day,
    each with its own time. To undo a specific PRN event the client posts that
    exact 'prn-HH:MM:SS' slot with taken=false."""
    def post(self, request, pk):
        from decimal import Decimal
        med = Medicine.objects.filter(user=request.user, pk=pk).first()
        if not med:
            return Response(status=status.HTTP_404_NOT_FOUND)
        the_date = request.data.get("date") or timezone.localdate().isoformat()
        slot = request.data.get("slot", "")
        skipped = bool(request.data.get("skipped", False))
        taken = False if skipped else bool(request.data.get("taken", True))

        # A fresh PRN 'take' gets a unique timestamped slot so it never collides
        # with an earlier event on the same day (unique_together stays valid).
        if med.as_needed and slot == "prn" and taken:
            slot = "prn-%d" % (MedicineLog.objects.filter(medicine=med, date=the_date, slot__startswith="prn").count() + 1)

        prev = MedicineLog.objects.filter(medicine=med, date=the_date, slot=slot).first()
        was_taken = bool(prev and prev.taken)

        obj, _ = MedicineLog.objects.update_or_create(
            medicine=med, date=the_date, slot=slot,
            defaults={"taken": taken, "skipped": skipped,
                      "at": timezone.now() if taken else None})

        # inventory: decrement on a fresh 'taken', restore on undo of a 'taken'.
        # Decimal-safe so fractional doses (0.5 pill) work (P6).
        if med.stock_count is not None:
            if taken and not was_taken:
                med.stock_count = Decimal(str(
                    mlogic.apply_dose_to_stock(med.stock_count, med.dose_qty)))
                med.save(update_fields=["stock_count"])
            elif (not taken) and was_taken:
                med.stock_count = Decimal(str(
                    mlogic.restore_dose_to_stock(med.stock_count, med.dose_qty)))
                med.save(update_fields=["stock_count"])

        log(request.user, "medicine.taken" if taken else "medicine.skip",
            id=med.id, slot=slot)
        return Response({"ok": True, "taken": obj.taken, "skipped": obj.skipped,
                         "slot": slot,
                         "stock_count": float(med.stock_count)
                         if med.stock_count is not None else None})


def _taken_set(med):
    return {(log.date.isoformat(), log.slot) for log in med.logs.filter(taken=True)}


class MedicineTodayView(APIView):
    """Today's medicine doses with taken-status + dose semantics (self + family)."""
    def get(self, request):
        today = timezone.localdate()
        out = []
        for med in Medicine.objects.filter(user=request.user).select_related("member"):
            slots = mlogic.scheduled_slots_for_day(
                med.times, med.start_date, med.end_date, today, prn=med.as_needed)
            today_logs = list(med.logs.filter(date=today))
            logs = {log.slot: log for log in today_logs}
            dl = mlogic.days_left(med.stock_count, med.times, med.dose_qty,
                                  prn=med.as_needed, prn_per_day=med.prn_per_day)
            base = {
                "medicine_id": med.id, "name": med.name,
                "dosage": med.dosage, "member": med.member_id,
                "member_name": med.member.name if med.member else None,
                "food_relation": med.food_relation, "days_left": dl,
                "refill_date": med.refill_date.isoformat() if med.refill_date else None}
            if med.as_needed:
                # Each already-logged PRN event is its own (undoable) row...
                prn_logs = sorted(
                    (l for l in today_logs if l.slot.startswith("prn") and l.taken),
                    key=lambda l: l.slot)
                for lg in prn_logs:
                    at = lg.slot[4:] if lg.slot.startswith("prn-") else ""
                    row = dict(base)
                    row.update({"slot": lg.slot, "prn": True, "taken": True,
                                "skipped": False, "prn_at": at,
                                "prn_count_today": len(prn_logs)})
                    out.append(row)
                # ...plus one 'log another' row so PRN can be taken again today.
                row = dict(base)
                row.update({"slot": "prn", "prn": True, "taken": False,
                            "skipped": False, "prn_at": "",
                            "prn_count_today": len(prn_logs)})
                out.append(row)
                continue
            for slot in slots:
                lg = logs.get(slot)
                row = dict(base)
                row.update({
                    "slot": slot, "prn": False,
                    "taken": bool(lg and lg.taken),
                    "skipped": bool(lg and lg.skipped)})
                out.append(row)
        out.sort(key=lambda x: x["slot"])
        return Response(out)


class MedicineHistoryView(APIView):
    """Adherence history: overall + per-medicine, weekly buckets + 30-day %.
    ?member=<id|self> optional filter."""
    def get(self, request):
        from datetime import timedelta
        today = timezone.localdate()
        win_start = today - timedelta(days=29)
        meds = Medicine.objects.filter(user=request.user)
        member = request.query_params.get("member")
        if member == "self":
            meds = meds.filter(member__isnull=True)
        elif member:
            meds = meds.filter(member_id=member)

        per_med = []
        tot_taken = tot_sched = 0
        for med in meds:
            ts = _taken_set(med)
            pct, taken, sched = mlogic.adherence_for_med(
                med.times, med.start_date, med.end_date, ts,
                win_start, today, prn=med.as_needed)
            if not med.as_needed:
                tot_taken += taken
                tot_sched += sched
            # 4 weekly buckets
            weeks = []
            for w in range(4):
                ws = today - timedelta(days=7 * (w + 1) - 1)
                we = today - timedelta(days=7 * w)
                wp, _, _ = mlogic.adherence_for_med(
                    med.times, med.start_date, med.end_date, ts, ws, we,
                    prn=med.as_needed)
                weeks.append({"start": ws.isoformat(), "end": we.isoformat(),
                              "pct": wp})
            per_med.append({
                "id": med.id, "name": med.name,
                "member": med.member_id, "prn": med.as_needed,
                "adherence_30d": pct, "taken": taken, "scheduled": sched,
                "streak": mlogic.streak_days(med.times, med.start_date,
                                             med.end_date, ts, today,
                                             prn=med.as_needed),
                "weeks": list(reversed(weeks))})
        overall, _, _ = mlogic.adherence(tot_sched, tot_taken)
        return Response({"overall": overall, "taken": tot_taken,
                         "scheduled": tot_sched, "medicines": per_med})


class CaregiverDashboardView(APIView):
    """One-glance status per cared-for person (self + each family member):
    today's dose status, 30-day adherence, and low-stock medicines."""
    def get(self, request):
        from datetime import timedelta
        today = timezone.localdate()
        win_start = today - timedelta(days=29)

        now_hhmm = timezone.localtime().strftime("%H:%M")

        def person_block(member, label, relation):
            meds = Medicine.objects.filter(user=request.user)
            meds = meds.filter(member=member) if member else meds.filter(member__isnull=True)
            due = taken = 0
            low_stock = []
            tot_taken = tot_sched = 0
            next_due = None          # next pending slot still AFTER now
            next_due_any = None      # earliest pending slot today (fallback if all past)
            for med in meds:
                slots = mlogic.scheduled_slots_for_day(
                    med.times, med.start_date, med.end_date, today, prn=med.as_needed)
                logs = {l.slot: l for l in med.logs.filter(date=today)}
                for slot in slots:
                    due += 1
                    if logs.get(slot) and logs[slot].taken:
                        taken += 1
                        continue
                    # pending dose: prefer the next slot strictly after 'now'...
                    if slot >= now_hhmm and (next_due is None or slot < next_due):
                        next_due = slot
                    # ...but still track the earliest pending slot as a fallback
                    # when every remaining dose today is already in the past.
                    if next_due_any is None or slot < next_due_any:
                        next_due_any = slot
                st, dl = mlogic.refill_warning(
                    med.stock_count, med.times, med.dose_qty,
                    warn_days=med.refill_warn_days, prn=med.as_needed,
                    prn_per_day=med.prn_per_day)
                if st in ("soon", "out"):
                    low_stock.append({"name": med.name, "days_left": dl, "status": st})
                ts = _taken_set(med)
                _, t, s = mlogic.adherence_for_med(
                    med.times, med.start_date, med.end_date, ts,
                    win_start, today, prn=med.as_needed)
                if not med.as_needed:
                    tot_taken += t
                    tot_sched += s
            adh, _, _ = mlogic.adherence(tot_sched, tot_taken)
            return {
                "member": member.id if member else None,
                "name": label, "relation": relation,
                "doses_today": due, "taken_today": taken,
                "pending_today": due - taken,
                "next_due": next_due or next_due_any,
                "adherence_30d": adh, "low_stock": low_stock,
                "has_meds": meds.exists()}

        u = request.user
        blocks = [person_block(None, u.name or u.username, "self")]
        for m in FamilyMember.objects.filter(user=u):
            blocks.append(person_block(m, m.name, m.relation))
        blocks = [b for b in blocks if b["has_meds"]]
        # push-gate: cross-device caregiver alerts need Firebase.
        from . import integrations as _ig
        push_ready = False
        try:
            push_ready = _ig.is_enabled("firebase")
        except Exception:
            push_ready = False
        return Response({"people": blocks, "push_ready": push_ready})


class MedicineEscalationView(APIView):
    """Preview the missed-dose escalation ladder for a medicine's dose, so the
    caregiver can see exactly when each reminder/alert would fire (and which
    land in quiet hours). Cross-device delivery is key-gated (push_ready)."""
    def get(self, request, pk):
        med = Medicine.objects.filter(user=request.user, pk=pk).first()
        if not med:
            return Response(status=status.HTTP_404_NOT_FOUND)
        slot = request.query_params.get("slot") or (med.times[0] if med.times else "08:00")
        plan = mlogic.escalation_plan(
            slot, med.followup_repeat_min, med.followup_retries,
            med.caregiver_alert_min, med.quiet_start, med.quiet_end,
            base_day=timezone.localdate())
        events = [{"kind": e["kind"], "at": e["at"].strftime("%H:%M"),
                   "suppressed": e["suppressed"]} for e in plan]
        from . import push as _push
        push_ready = _push.is_available()
        return Response({"slot": slot, "events": events, "push_ready": push_ready})


class DoctorVisitPdfView(APIView):
    """Doctor-visit summary PDF: current meds + schedule, 30-day adherence,
    recent prescription changes. ?member=<id|self> scopes to one person."""
    def get(self, request):
        import io
        from datetime import timedelta
        from reportlab.lib.pagesizes import A4
        from reportlab.pdfgen import canvas
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
        FONT = "Helvetica"
        try:
            if "Noto" not in pdfmetrics.getRegisteredFontNames():
                pdfmetrics.registerFont(TTFont(
                    "Noto", "/home/ubuntu/assisto/app/assets/fonts/NotoSansBengali.ttf"))
            FONT = "Noto"
        except Exception:
            FONT = "Helvetica"

        u = request.user
        lang = req_lang(request)
        member = request.query_params.get("member")
        meds = Medicine.objects.filter(user=u)
        person = u.name or u.username
        if member and member != "self":
            fm = FamilyMember.objects.filter(user=u, pk=member).first()
            meds = meds.filter(member=fm)
            if fm:
                person = fm.name
        elif member == "self":
            meds = meds.filter(member__isnull=True)

        today = timezone.localdate()
        buf = io.BytesIO()
        c = canvas.Canvas(buf, pagesize=A4)
        w, h = A4
        y = h - 50
        c.setFont(FONT, 16)
        c.drawString(40, y, pick(lang, "Assisto — ডাক্তার ভিজিট সারাংশ",
                                 "Assisto — Doctor Visit Summary")); y -= 20
        c.setFont(FONT, 9)
        c.drawString(40, y, pick(lang, "রোগী: ", "Patient: ") + person); y -= 12
        c.drawString(40, y, pick(lang, "তারিখ: ", "Date: ") + today.isoformat()); y -= 22

        def line(txt, indent=48, size=9):
            nonlocal y
            if y < 60:
                c.showPage(); y = h - 50; c.setFont(FONT, size)
            c.setFont(FONT, size); c.drawString(indent, y, txt[:120]); y -= 13

        def heading(txt):
            nonlocal y
            if y < 80:
                c.showPage(); y = h - 50
            y -= 4; c.setFont(FONT, 12); c.drawString(40, y, txt); y -= 16

        heading(pick(lang, "বর্তমান ওষুধ ও সময়সূচি", "Current Medicines & Schedule"))
        food_map = {"before": pick(lang, "খাওয়ার আগে", "before food"),
                    "after": pick(lang, "খাওয়ার পরে", "after food"),
                    "with": pick(lang, "খাওয়ার সাথে", "with food"),
                    "any": ""}
        if not meds.exists():
            line(pick(lang, "(কোনো ওষুধ নেই)", "(none)"))
        for med in meds:
            ts = _taken_set(med)
            adh, _, _ = mlogic.adherence_for_med(
                med.times, med.start_date, med.end_date, ts,
                today - timedelta(days=29), today, prn=med.as_needed)
            sched = pick(lang, "প্রয়োজনে", "as needed") if med.as_needed \
                else ", ".join(med.times or [])
            food = food_map.get(med.food_relation, "")
            bits = [b for b in [med.dosage, sched, food] if b]
            line(f"- {med.name}: " + " | ".join(bits))
            line(pick(lang, f"  মেনে চলা (৩০ দিন): {adh}%",
                      f"  Adherence (30d): {adh}%"), indent=56)
            if med.end_date:
                line(pick(lang, f"  কোর্স শেষ: {med.end_date.isoformat()}",
                          f"  Course ends: {med.end_date.isoformat()}"), indent=56)

        heading(pick(lang, "সাম্প্রতিক প্রেসক্রিপশন", "Recent Prescriptions"))
        pres = Prescription.objects.filter(user=u)
        if member and member != "self":
            pres = pres.filter(member_id=member)
        pres = pres[:8]
        if not pres:
            line(pick(lang, "(কোনো প্রেসক্রিপশন নেই)", "(none)"))
        for p in pres:
            doc = p.doctor.name if p.doctor_id and p.doctor else p.doctor_name
            d = p.date.isoformat() if p.date else "?"
            line(f"- {d} · {doc or '-'}: {p.diagnosis or ''}")
            for m in (p.meds or [])[:6]:
                nm = m.get("name", "") if isinstance(m, dict) else str(m)
                line(f"    · {nm}", indent=60)

        c.showPage(); c.save()
        log(u, "export.doctor_pdf", member=member or "self")
        resp = HttpResponse(buf.getvalue(), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="assisto-doctor-visit.pdf"'
        return resp


class SchoolItemViewSet(viewsets.ModelViewSet):
    serializer_class = SchoolItemSerializer

    def get_queryset(self):
        return SchoolItem.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class ScamCheckView(APIView):
    """Feature 13 — in-app scam checker. Uses the richer core.logic.scam
    contract (score/verdict/level/label/emoji/patterns[]/advice/summary). We
    also project patterns[].name into a flat `reasons` list so the legacy
    family-screen checker (which reads r['reasons']) stays working."""
    def post(self, request):
        from .logic import scam as scamlogic
        lang = req_lang(request)
        msg = request.data.get("message", "")
        if not (msg or "").strip():
            return Response({"detail": pick(lang, "মেসেজ দিন।", "Please enter a message.")}, status=400)
        result = scamlogic.check_message(msg, lang)
        # back-compat flat fields for the old family-screen UI
        result.setdefault("reasons", [p.get("name", "") for p in result.get("patterns", [])])
        log(request.user, "scam.check", verdict=result["verdict"])
        return Response(result)


class ScamLibraryView(APIView):
    """GET /scam/library — the curated, localised 'learn the scams' catalogue."""
    def get(self, request):
        from .logic import scam as scamlogic
        return Response({"patterns": scamlogic.library(req_lang(request))})


class ScamReportView(APIView):
    """POST /scam/report {message} — a family member reports a scam they got;
    build a family alert and persist it so the family's /alerts poll shows it."""
    def post(self, request):
        from .logic import scam as scamlogic
        lang = req_lang(request)
        msg = (request.data.get("message") or "").strip()
        if not msg:
            return Response({"detail": pick(lang, "মেসেজ দিন।", "Please enter a message.")}, status=400)
        u = request.user
        result = scamlogic.check_message(msg, lang)
        payload = scamlogic.family_alert_payload(u.name or u.username, result, lang)
        FamilyAlert.objects.create(
            user=u, kind=payload.get("kind", "scam_report"),
            title=payload.get("title", ""), body=payload.get("body", ""),
            severity="high", payload=payload)
        try:  # FCM to the reporter's family (key-gated, never raises)
            from . import push
            push.hook_family_alert(
                u, payload.get("title", ""), payload.get("title", ""),
                payload.get("body", ""), payload.get("body", ""),
                data={"alert_kind": payload.get("kind", "scam_report")})
        except Exception:
            pass
        log(u, "scam.report", verdict=result["verdict"])
        return Response({"ok": True, "alert": payload})


class SafetyCheckinView(APIView):
    """POST /safety/checkin {place, eta} — start a safe-arrival check-in.
    Supersedes any still-open check-in for this user (one active at a time)."""
    def post(self, request):
        from .logic import safety as safetylogic
        lang = req_lang(request)
        u = request.user
        place = (request.data.get("place") or "").strip()
        eta = safetylogic.parse_dt(request.data.get("eta"))
        if eta is None:
            return Response({"detail": pick(lang, "পৌঁছানোর সময় দিন।",
                                            "Please provide an arrival time.")}, status=400)
        u.checkins.filter(arrived=False).update(arrived=True,
                                                arrived_at=timezone.now())
        try:   # journey100: night safety -> a shorter wait before family hears
            grace = max(0, min(60, int(request.data.get("grace_min", 15))))
        except (TypeError, ValueError):
            grace = 15
        c = SafetyCheckin.objects.create(user=u, place=place, eta=eta, arrived=False,
                                         grace_min=grace)
        log(u, "safety.checkin.start", id=c.id)
        return Response({"ok": True, "id": c.id})


class SafetyCheckinArrivedView(APIView):
    """POST /safety/checkin/arrived — mark the active check-in arrived (clears
    the pending overdue alert)."""
    def post(self, request):
        u = request.user
        now = timezone.now()
        n = u.checkins.filter(arrived=False).update(arrived=True, arrived_at=now)
        # any overdue-checkin family alerts become stale -> dismiss them
        u.family_alerts.filter(kind="checkin_overdue", dismissed=False).update(dismissed=True)
        log(u, "safety.checkin.arrived", count=n)
        return Response({"ok": True})


class ReminderParseView(APIView):
    """POST /reminders/parse {text} — server-of-truth NL parse (the app also
    parses offline via the Dart mirror). Returns the structured fields the
    quick-add sheet pre-fills."""
    def post(self, request):
        from .logic import nlp_datetime
        lang = req_lang(request)
        text = (request.data.get("text") or "").strip()
        if not text:
            return Response({"detail": pick(lang, "কিছু লিখুন।", "Type something.")}, status=400)
        result = nlp_datetime.parse(text, lang=lang)
        return Response({
            "title": result.get("clean_title") or text,
            "datetime": result.get("datetime"),   # ISO-8601 string or None
            "date_only": bool(result.get("date_only", False)),
            "recurrence_rule": result.get("recurrence_rule") or {},
            "confidence": result.get("confidence", 0.0),
        })


class MemorySearchView(APIView):
    """GET /memory/search?q= — keyword/fuzzy search over the user's MemoryItems
    using the shared reminders_engine.search_memory ranker."""
    def get(self, request):
        from .logic import reminders_engine
        q = (request.query_params.get("q") or "").strip()
        items = [{"id": m.id, "title": m.title, "detail": m.detail,
                  "category": m.category, "source": m.source}
                 for m in request.user.memories.all()]
        if not q:
            return Response({"results": items[:10]})
        ranked = reminders_engine.search_memory(q, items, limit=10)
        return Response({"results": ranked})


class PlansPublicView(APIView):
    """GET /plans — the public plan catalogue (localised). No auth-specific
    data; safe to show pre-upgrade."""
    permission_classes = [AllowAny]

    def get(self, request):
        from . import plans
        from .calls_free import calls_free
        rows = plans.plans_public(req_lang(request))
        # pricing-40: an EXISTING subscriber keeps the price Google charges
        # them (Play legacy price cohort) — mark their plan with what they
        # actually last paid, so the app never shows them a different price.
        try:
            if request.user and request.user.is_authenticated:
                rows = plans.mark_your_price(request.user, rows)
        except Exception:  # noqa: BLE001
            pass
        # dl1: while "Free calls (testing)" is ON the comparison table shows
        # calls as free on every plan (the server stays the authority).
        if calls_free() and isinstance(rows, list):
            rows = [dict(r, calls_free=True) if isinstance(r, dict) else r
                    for r in rows]
        return Response(rows)


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
                            "spent": str(spent), "pct": pct, "rollover": b.rollover,
                            "state": "over" if pct >= 100 else ("near" if pct >= 80 else "ok")})

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


# ---------- briefing / proactive alerts (feature 4, 5 — non-AI works now) ----------

def _build_alerts(user, lang="bn"):
    from datetime import timedelta
    from django.db.models import Sum
    from decimal import Decimal
    today = timezone.localdate()
    alerts = []
    # family alerts (scam a member reported; surfaced via the foreground poll)
    for fa in user.family_alerts.filter(dismissed=False)[:10]:
        # owner 24 Oct: legacy anti-theft rows about the user's OWN phone never
        # reach his own urgent card / briefing
        if fa.kind == "antitheft" and (fa.payload or {}).get("owner_id") == user.id:
            continue
        row = {"type": fa.kind, "text": fa.body or fa.title,
               "title": fa.title, "severity": fa.severity or "high"}
        if fa.kind == "antitheft":  # own-device: app urgent-card guard
            row["owner_id"] = (fa.payload or {}).get("owner_id")
        alerts.append(row)
    # at-heartbeat: anti-theft alerts are ONE NotifEvent per person now (no
    # FamilyAlert twin); the foreground poll still surfaces the unseen ones.
    try:
        from .views_antitheft import alert_rows_for
        alerts.extend(alert_rows_for(user, lang))
    except Exception:
        pass
    # overdue safe-arrival check-ins — auto-build a family alert on poll
    from .logic import safety as _safety
    now_dt = timezone.now()
    for c in user.checkins.filter(arrived=False, eta__isnull=False):
        state, mins = _safety.checkin_status(c.eta, now=now_dt)
        if state == "overdue":
            pl = _safety.checkin_overdue_payload(
                user.name or user.username, c.place, mins, lang)
            alerts.append({"type": "checkin_overdue", "text": pl["body"],
                           "title": pl["title"], "severity": "high"})
    # document expiry
    for d in user.documents.filter(expiry_date__isnull=False):
        days = (d.expiry_date - today).days
        if days < 0:
            alerts.append({"type": "doc_expired",
                           "text": pick(lang, f"{d.title}-এর মেয়াদ শেষ হয়ে গেছে।",
                                        f"{d.title} has expired."),
                           "severity": "high"})
        elif days <= 30:
            alerts.append({"type": "doc_expiry",
                           "text": pick(lang, f"{d.title}-এর মেয়াদ {days} দিনে শেষ।",
                                        f"{d.title} expires in {days} days."),
                           "severity": "high" if days <= 7 else "med"})
    # medicine refill — fires from a manual refill_date OR, for stock-only
    # users, a predicted run-out date derived from current stock + burn (P1).
    for m in user.medicines.all():
        days = None
        if m.refill_date is not None:
            days = (m.refill_date - today).days
        else:
            dl = mlogic.days_left(m.stock_count, m.times, m.dose_qty,
                                  prn=m.as_needed, prn_per_day=m.prn_per_day)
            if dl is not None:
                days = dl
        if days is not None and 0 <= days <= (m.refill_warn_days or 5):
            alerts.append({"type": "refill",
                           "text": pick(lang, f"{m.name} রিফিল করতে হবে ({days} দিনে)।",
                                        f"Time to refill {m.name} (in {days} days)."),
                           "severity": "med"})
    # loans past due
    for ln in user.loans.filter(settled=False, due_date__isnull=False, due_date__lt=today):
        alerts.append({"type": "loan_due",
                       "text": pick(lang, f"{ln.person} এর ধার ফেরতের তারিখ পার হয়েছে।",
                                    f"The repayment date for {ln.person}'s loan has passed."),
                       "severity": "med"})
    # budget over
    month_exp = {}
    for t in user.txns.filter(date__year=today.year, date__month=today.month, kind="expense"):
        month_exp[t.category or ""] = month_exp.get(t.category or "", Decimal("0")) + t.amount
    for b in user.budgets.all():
        spent = month_exp.get(b.category, Decimal("0"))
        if b.monthly_limit and spent >= b.monthly_limit:
            pct = int(spent / b.monthly_limit * 100)
            alerts.append({"type": "budget",
                           "text": pick(lang, f"'{b.category}' বাজেট শেষ ({pct}%)।",
                                        f"'{b.category}' budget is used up ({pct}%)."),
                           "severity": "med"})
    return alerts


@api_view(["GET"])
def alerts(request):
    return Response(_build_alerts(request.user, req_lang(request)))


@api_view(["GET"])
def briefing(request):
    return Response(_briefing_payload(request.user, req_lang(request)))


def _briefing_payload(u, lang):
    """The briefing dict — callable without the HTTP layer (used by AgentView's
    'today' query so it isn't double-wrapping a DRF Request)."""
    today = timezone.localdate()
    doses = []
    for med in u.medicines.all():
        for slot in (med.times or []):
            doses.append(f"{med.name} ({slot})")
    reminders_today = list(u.reminders.filter(done=False, due_at__date=today)
                           .values_list("title", flat=True))
    al = _build_alerts(u, lang)
    lines = [pick(lang, f"🗓️ আজ: {today.strftime('%d %b %Y')}",
                  f"🗓️ Today: {today.strftime('%d %b %Y')}")]
    if reminders_today:
        lines.append(pick(lang, "⏰ রিমাইন্ডার: ", "⏰ Reminders: ") + ", ".join(reminders_today))
    if doses:
        lines.append(pick(lang, "💊 ওষুধ: ", "💊 Medicines: ") + ", ".join(doses[:6]))
    for a in al[:5]:
        lines.append(("⚠️ " if a["severity"] == "high" else "🔸 ") + a["text"])
    if len(lines) == 1:
        lines.append(pick(lang, "আজ বিশেষ কিছু নেই — ভালো থাকুন! 🌼",
                          "Nothing special today — take care! 🌼"))
    text = "\n".join(lines)

    # Prefer the batch-generated night briefing (instant, no peak-time AI cost).
    ai_text = None
    cached = NightBriefing.objects.filter(user=u, for_date=today).first()
    if cached and cached.text:
        ai_text = cached.text
    elif ai.available():
        try:
            ai_text, _ = ai.generate(
                task=pick(lang,
                          "নিচের তথ্য দিয়ে ব্যবহারকারীর জন্য ছোট, উষ্ণ বাংলা সকালের ব্রিফিং লেখো (৩-৪ লাইন)। বাংলায় লেখো।",
                          "Using the information below, write a short, warm morning briefing for the user (3-4 lines). Write in English."),
                data=text, tier="cheap", feature="briefing", max_tokens=300, user=u)
        except ai.AIUnavailable:
            ai_text = None
    return {"text": text, "lines": lines, "ai_text": ai_text,
            "alerts": al, "ai_enabled": ai.key_present()}


class LifeScanView(APIView):
    """Feature 1 — Life Scanner. Needs an AI key; clear Bangla needs-key state."""
    def post(self, request):
        lang = req_lang(request)
        if not ai.available():
            return Response({
                "needs_key": True,
                "message": pick(lang,
                                "Life Scanner চালু হবে যখন AI key যোগ করা হবে। "
                                "ততক্ষণ তথ্য নিজে লিখে যোগ করুন।",
                                "Life Scanner turns on once an AI key is added. "
                                "Until then, add your details manually."),
            }, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        # With a key: image → AI extraction would run here (built when key arrives).
        return Response({"needs_key": False, "detail": "AI extraction pipeline ready."},
                        status=status.HTTP_501_NOT_IMPLEMENTED)


# ---------- Wrapped + invite (feature 19) ----------

def _wrapped_badges(user, lang="bn"):
    today = timezone.localdate()
    badges = []
    # medicine adherence this month
    from core.models import MedicineLog
    taken = MedicineLog.objects.filter(medicine__user=user, taken=True,
                                       date__year=today.year, date__month=today.month).count()
    if taken > 0:
        badges.append(pick(lang, f"💊 এ মাসে {taken} বার ওষুধ ঠিকমতো",
                           f"💊 Took medicines on time {taken} times this month"))
    # tasks done
    done = user.todos.filter(done=True).count()
    if done > 0:
        badges.append(pick(lang, f"✅ {done} টি কাজ শেষ", f"✅ {done} tasks done"))
    # budgets kept
    kept = 0
    over = 0
    from decimal import Decimal
    month_exp = {}
    for t in user.txns.filter(date__year=today.year, date__month=today.month, kind="expense"):
        month_exp[t.category or ""] = month_exp.get(t.category or "", Decimal("0")) + t.amount
    for b in user.budgets.all():
        if b.monthly_limit and month_exp.get(b.category, Decimal("0")) <= b.monthly_limit:
            kept += 1
        else:
            over += 1
    if kept > 0 and over == 0:
        badges.append(pick(lang, "🎯 বাজেটে ছিলেন", "🎯 Stayed within budget"))
    # savings progress
    if user.goals.filter(saved_amount__gt=0).exists():
        badges.append(pick(lang, "🏦 সঞ্চয় চলছে", "🏦 Savings on track"))
    # memories
    mem = user.memories.count()
    if mem > 0:
        badges.append(pick(lang, f"🧠 {mem} টি তথ্য মনে রাখা",
                           f"🧠 Remembered {mem} things for you"))
    if not badges:
        badges.append(pick(lang, "🌱 Assisto-তে যাত্রা শুরু", "🌱 Your Assisto journey begins"))
    return badges


@api_view(["GET"])
def wrapped(request):
    lang = req_lang(request)
    today = timezone.localdate()
    badges = _wrapped_badges(request.user, lang)
    from urllib.parse import urlencode
    q = urlencode([("b", b) for b in badges])
    return Response({
        "title": pick(lang, f"{today.strftime('%B')} — আমার Assisto",
                      f"{today.strftime('%B')} — My Assisto"),
        "badges": badges,
        "card_url": f"{settings.ASSISTO_BASE_URL}/wrapped/card.png?{q}",
        "note": pick(lang, "শেয়ার কার্ডে টাকার অঙ্ক থাকে না — শুধু ব্যাজ/শতাংশ।",
                     "The share card never shows amounts — only badges and percentages."),
    })


class InviteView(APIView):
    def get(self, request):
        # p5-growth: one code system (core.growth) — same code, the real
        # lifeassisto.com/i/<code> link (the old text pointed at a retired host).
        from . import growth as _g
        lang = req_lang(request)
        u = request.user
        code = _g.ensure_code(u)
        invited = User.objects.filter(referred_by=code).count()
        return Response({"code": code, "invited": invited,
                         "link": _g.invite_link(code),
                         "share_text": _g.share_text(code, lang)})


# ---------- agent thread (conversation-first, rule-based; AI-optional) ----------

class AgentView(APIView):
    """Turns a Bangla/English message into an action + a thread card.
    Only creates the user's OWN data; nothing external without a future
    approval card. Works with no AI key."""
    def post(self, request):
        from . import agent as agent_brain
        from decimal import Decimal
        lang = req_lang(request)
        u = request.user
        text = (request.data.get("text") or "").strip()
        if not text:
            return Response({"reply": pick(lang, "কিছু লিখুন বা বলুন।",
                                           "Type or say something."), "cards": []})
        p = agent_brain.parse(text, req_lang(request))
        from .i18n import is_play_flavour
        if is_play_flavour(request):
            # play-nomed: no medicine schedules in the Play build — the same
            # words become a plain reminder the user wrote themselves.
            p = agent_brain.play_safe(p, text, req_lang(request))
        intent = p.get("intent")
        cards = []
        reply = ""
        ai_used = False
        brain_route = None

        def ensure_account():
            acc = u.accounts.first()
            if not acc:
                acc = Account.objects.create(user=u, name="ক্যাশ", acc_type="cash")
            return acc

        if intent == "reminder":
            r = Reminder.objects.create(user=u, title=p["title"], source="ai",
                due_at=p["due"], remind_before_min=0)
            log(u, "agent.reminder", id=r.id)
            reply = pick(lang, "রিমাইন্ডার সেট করেছি।", "Reminder set.")
            cards.append({"type": "reminder", "title": p["title"],
                          "subtitle": p.get("due") or pick(lang, "সময় ছাড়া", "No time set"),
                          "model": "reminder", "id": r.id, "undo": True})
        elif intent in ("expense", "income"):
            acc = ensure_account()
            # "কাল ৫০০ টাকা খরচ করেছি" is YESTERDAY's spend: past-biased date,
            # never later than today (nlp_datetime.expense_date).
            from .logic.nlp_datetime import expense_date
            t = Transaction.objects.create(user=u, account=acc, kind=intent,
                amount=Decimal(p["amount"]), category=p.get("category", ""),
                date=expense_date(text, now=timezone.localtime().replace(tzinfo=None)),
                source="ai")
            log(u, f"agent.{intent}", id=t.id)
            reply = pick(lang,
                         ("খরচ" if intent == "expense" else "আয়") + " লিখে রেখেছি।",
                         ("Logged your expense." if intent == "expense" else "Logged your income."))
            cards.append({"type": intent, "title": f"৳{p['amount']} {p.get('category','')}".strip(),
                          "subtitle": acc.name, "model": "txn", "id": t.id, "undo": True})
        elif intent == "loan":
            ln = Loan.objects.create(user=u, kind=p["kind"], person=p.get("person", ""),
                amount=Decimal(p["amount"]))
            log(u, "agent.loan", id=ln.id)
            reply = pick(lang, "ধারের হিসাব রেখেছি।", "Loan recorded.")
            cards.append({"type": "loan", "title": f"{p.get('person','')} · ৳{p['amount']}",
                          "subtitle": pick(lang, "দিয়েছি", "Lent") if p["kind"] == "given"
                          else pick(lang, "নিয়েছি", "Borrowed"),
                          "model": "loan", "id": ln.id, "undo": True})
        elif intent == "medicine":
            med = Medicine.objects.create(user=u, name=p["name"],
                times=[p["due"][11:16]] if p.get("due") else [])
            log(u, "agent.medicine", id=med.id)
            reply = pick(lang, "ওষুধ যোগ করেছি।", "Medicine added.")
            cards.append({"type": "medicine", "title": p["name"],
                          "subtitle": ", ".join(med.times) or pick(lang, "সময় দিন", "Add a time"),
                          "model": "medicine", "id": med.id, "undo": True})
        elif intent == "memory":
            m = MemoryItem.objects.create(user=u, title=p["title"], source="ai",
                                          needs_review=True)
            log(u, "agent.memory", id=m.id)
            reply = pick(lang, "মনে রাখলাম।", "Noted and remembered.")
            cards.append({"type": "memory", "title": p["title"],
                          "subtitle": pick(lang, "AI ধরেছে · রিভিউ করুন",
                                           "Caught by AI · please review"),
                          "model": "memory", "id": m.id, "undo": True})
        elif intent == "music":
            import urllib.parse as _up
            q = (p.get("query") or "").strip()
            yt = "https://www.youtube.com/results?search_query=" + _up.quote(q)
            card = {"type": "music", "title": q or pick(lang, "গান", "Music"),
                    "subtitle": pick(lang, "চালাতে ট্যাপ করুন", "Tap to play"),
                    "youtube": yt, "app_action": "open_url"}
            from . import integrations as _ig
            if _ig.is_enabled("spotify"):
                card["spotify"] = "https://open.spotify.com/search/" + _up.quote(q)
            reply = pick(lang, f"'{q}' খুঁজে দিলাম — চালাতে ট্যাপ করুন।",
                         f"Found '{q}' — tap to play.")
            cards.append(card)
        elif intent == "navigate":
            import urllib.parse as _up
            place = (p.get("place") or "").strip()
            cards.append({"type": "navigate", "title": place,
                          "subtitle": pick(lang, "ম্যাপে খুলতে ট্যাপ", "Tap to open in Maps"),
                          "maps": "https://www.google.com/maps/search/?api=1&query=" + _up.quote(place),
                          "app_action": "open_url"})
            reply = pick(lang, f"'{place}' ম্যাপে খুলতে ট্যাপ করুন।",
                         f"Tap to open '{place}' in Maps.")
        elif intent == "call":
            name = (p.get("name") or "").strip()
            phone = ""
            card = (u.emergency_card.contacts if hasattr(u, "emergency_card") else [])
            for c in (card or []):
                if name and name in (c.get("name") or ""):
                    phone = c.get("phone", "")
            cards.append({"type": "call", "title": name or pick(lang, "কল", "Call"),
                          "phone": phone,
                          "subtitle": pick(lang, "কল করতে ট্যাপ করুন (আপনি চাপলেই)",
                                           "Tap to call (only when you do)"),
                          "app_action": "dial"})
            reply = (pick(lang, f"{name}-কে কল করতে ট্যাপ করুন।", f"Tap to call {name}.") if phone
                     else pick(lang, f"{name}-এর নম্বর পেলাম না; কন্টাক্ট থেকে বেছে নিন।",
                               f"Couldn't find a number for {name}; pick one from your contacts."))
        elif intent == "nearby":
            cards.append({"type": "nearby", "place_type": p.get("place_type", "restaurant"),
                          "title": pick(lang, "আশেপাশে খুঁজছি…", "Searching nearby…"),
                          "app_action": "nearby"})
            reply = pick(lang, "আপনার লোকেশন নিয়ে আশেপাশে খুঁজছি…",
                         "Using your location to search nearby…")
        elif intent == "query_money":
            s = MoneySummaryView().get(request).data
            reply = pick(lang,
                         f"মোট ব্যালেন্স ৳{s['total_balance']}। এ মাসে খরচ ৳{s['month_expense']}, "
                         f"আয় ৳{s['month_income']}।",
                         f"Total balance ৳{s['total_balance']}. This month: spent ৳{s['month_expense']}, "
                         f"earned ৳{s['month_income']}.")
            cards.append({"type": "summary",
                          "title": pick(lang, f"ব্যালেন্স ৳{s['total_balance']}",
                                        f"Balance ৳{s['total_balance']}"),
                          "subtitle": pick(lang,
                                           f"খরচ ৳{s['month_expense']} · আয় ৳{s['month_income']}",
                                           f"Spent ৳{s['month_expense']} · Earned ৳{s['month_income']}")})
        elif intent == "query_today":
            reply = _briefing_payload(u, lang)["text"]
        elif intent in ("question", "ambiguous"):
            # A QUESTION (or ambiguous free text) is ANSWERED, never saved.
            from .logic import brain
            ai_answered = False
            # Cloud-AI path: a real question + a key present → let AI answer with
            # the user's data context. Brain is the no-key fallback (and the
            # honest L4 message is itself returned by Brain when AI is off).
            if intent == "question" and ai.available():
                try:
                    ctx = brain.answer(u, text, lang)  # user-data context
                    ai_reply, _ = ai.generate(
                        task=pick(lang,
                                  "ব্যবহারকারীর প্রশ্নের উত্তর দাও বাংলায়, সংক্ষেপে ও সত্যভাবে। "
                                  "নিচের DATA-তে তার নিজের তথ্যের সারাংশ আছে — শুধু এটাই সত্য।",
                                  "Answer the user's question briefly and truthfully in English. "
                                  "The DATA below summarises their own data — treat only it as true."),
                        data=f"Question: {text}\n\n{ctx['reply']}",
                        tier="cheap", feature="agent_qa", max_tokens=400, user=u)
                    reply = ai_reply
                    cards = ctx.get("cards", [])
                    ai_used = ai_answered = True
                except ai.AIUnavailable as e:
                    from . import credits_out
                    if e.reason == "credits" and credits_out.supported(request):
                        # credout: never a silent downgrade — 402 + nothing
                        # saved, so the app keeps the text, opens the
                        # buy-credits sheet and re-sends it once.
                        from . import credits_out
                        return credits_out.response(
                            u, lang, credits_out.need_for_tier(u, "cheap"))
                    ai_answered = False
            if not ai_answered:
                res = brain.answer(u, text, lang)
                reply = res["reply"]
                cards = res.get("cards", [])
                brain_route = res.get("route")
            # ambiguous free text → offer a "Save as note" chip (never auto-saved)
            if intent == "ambiguous":
                cards = list(cards) + [brain.save_note_card(text, lang)]
        else:
            reply = pick(lang,
                         "বুঝতে পারিনি। যেমন বলুন: 'কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও' বা '৫০০ টাকা খরচ খাবার'।",
                         "I didn't catch that. Try: 'remind me to take my medicine at 8am tomorrow' or '500 taka spent on food'.")

        # open-from-chat: resolve a screen route from the raw phrase (bn+en
        # synonyms). For a QUESTION/ambiguous text we keep route null so the app
        # SHOWS the answer in chat instead of navigating away — the answer's
        # cards already carry a per-card route the user can tap. For commands we
        # fall back to the synonym resolver as before.
        from . import screen_synonyms
        if intent in ("question", "ambiguous"):
            # m3-circle: a whole-message My Circle command ("circle",
            # "my circle", "add someone", bn too) still opens My Circle add.
            route = screen_synonyms.resolve_command(text)
        else:
            route = brain_route or screen_synonyms.resolve(text)
        session_id, message_id = _persist_home_turn(
            u, request.data.get("session_id"), text, reply, cards, intent, route)
        return Response({"reply": reply, "cards": cards, "intent": intent,
                         "route": route, "session_id": session_id,
                         "message_id": message_id,  # ai-report: report this answer
                         "ai_used": ai_used, "ai_enabled": ai.key_present()})


def _persist_home_turn(user, session_id, text, reply, cards, intent, route):
    """Save one home-chat turn (user text + agent reply/cards) so the home
    conversation survives restarts and shows in the sidebar history. Reuses an
    existing home session of THIS user, else starts one. Never breaks the
    reply: returns (session id, assistant message id), or (None, None) if
    saving failed."""
    from .models import ChatSession, ChatMessage
    try:
        s = None
        if session_id:
            s = ChatSession.objects.filter(pk=session_id, user=user,
                                          source="home").first()
        if s is None:
            s = ChatSession(user=user, source="home")
            s.derive_title(text)
            s.save()
        ChatMessage.objects.create(session=s, role="user", text=text)
        am = ChatMessage.objects.create(
            session=s, role="assistant", text=reply or "",
            meta={"source": "agent", "cards": cards,
                  "intent": intent, "route": route})
        s.save(update_fields=["updated_at"])
        return s.id, am.id
    except Exception:
        return None, None


# ---------- AI status (needs-key state surfaced to the app) ----------

@api_view(["GET"])
@permission_classes([AllowAny])
def ai_status(request):
    return Response(ai.status())


# ---------- export: Excel / PDF (feature 21) ----------

class ExportExcelView(APIView):
    def get(self, request):
        import io
        try:
            from openpyxl import Workbook
        except ImportError:
            # openpyxl is not in requirements.txt / the server venv: answer
            # honestly instead of a 500 (see m1 report: add openpyxl).
            lang = req_lang(request)
            return Response({"detail": pick(
                lang, "এক্সেল এক্সপোর্ট এখনো সার্ভারে চালু হয়নি।",
                "Excel export isn't available on the server yet."),
                "code": "xlsx_unavailable"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE)
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
        _mark_export_downloaded(u)
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
        _mark_export_downloaded(u)
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
        # budget-remittance: the user's own (decrypted) remittance entries.
        from .models import RemittanceEntry
        if RemittanceEntry.objects.filter(user=u).exists():
            from . import remittance_service as _rs
            data["remittance"] = _rs.decrypted_entries(u)
        log(u, "account.export")
        _mark_export_downloaded(u)
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


# ---------- Integrations admin (owner-only; keystone for adding keys later) ----
class _OwnerOnly(APIView):
    """Base: only the superuser (owner) may touch integrations. Audit-logged."""
    def _deny(self, request):
        if not (request.user and request.user.is_authenticated and request.user.is_superuser):
            return Response({"detail": "owner only"}, status=status.HTTP_403_FORBIDDEN)
        return None


class IntegrationsListView(_OwnerOnly):
    def get(self, request):
        d = self._deny(request)
        if d:
            return d
        from . import integrations
        lang = request.query_params.get("lang", "bn")
        return Response({"integrations": integrations.list_all(lang)})


class IntegrationSaveView(_OwnerOnly):
    def post(self, request, slug):
        d = self._deny(request)
        if d:
            return d
        from . import integrations
        try:
            integrations.save(slug, request.data or {})
        except ValueError:
            return Response({"detail": "unknown"}, status=status.HTTP_404_NOT_FOUND)
        log(request.user, "integration.save", slug=slug)  # never log secret values
        return Response({"ok": True})


class IntegrationTestView(_OwnerOnly):
    def post(self, request, slug):
        d = self._deny(request)
        if d:
            return d
        from . import integrations
        status_, detail = integrations.test(slug)
        log(request.user, "integration.test", slug=slug, result=status_)
        return Response({"status": status_, "detail": detail})


# ---------- Monetization (P3) ----------
class PlanView(APIView):
    def get(self, request):
        from . import plans
        from .i18n import req_lang
        return Response(plans.entitlements(request.user, req_lang(request)))


class RewardedAdView(APIView):
    """App calls this after a rewarded ad finishes → +1 AI credit (daily cap)."""
    def post(self, request):
        from . import plans, integrations
        if not integrations.is_enabled("admob"):
            lang = req_lang(request)
            return Response({"ok": False, "reason": "ads_not_configured",
                             "msg": pick(lang, "চালু হবে যখন AdMob যোগ হবে",
                                         "Available when AdMob is added")})
        # p2-money: a client claim never earns a credit — rewarded ads are
        # credited only from Google's signed SSV callback
        # (POST /credits/rewarded/ticket -> AdMob -> GET /ads/ssv).
        lang = req_lang(request)
        return Response({"ok": False, "reason": "ssv_required",
                         "msg": pick(lang, "অ্যাপ আপডেট করুন — যাচাই করা বিজ্ঞাপনেই ক্রেডিট মেলে",
                                     "Update the app — credits come only from verified ads")})


class WaitlistView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        contact = (request.data.get("contact") or "").strip()
        if not contact:
            return Response({"detail": "contact required"}, status=400)
        obj, created = WaitlistEntry.objects.get_or_create(contact=contact)
        return Response({"ok": True, "approved": obj.approved, "new": created})


# ---------- Watcher engine (P4) ----------
class WatcherViewSet(OwnedViewSet):
    from .models import Watcher as _M
    from .serializers import WatcherSerializer as _S
    model = _M
    kind = "watcher"
    serializer_class = _S

    def perform_create(self, serializer):
        from . import watcher as wmod
        n = self.model.objects.filter(user=self.request.user).count()
        if n >= wmod.max_watchers(self.request.user):
            from rest_framework.exceptions import ValidationError
            lang = req_lang(self.request)
            raise ValidationError({"detail": "watcher_limit",
                                   "msg": pick(lang, "প্ল্যানের ওয়াচার সীমা শেষ",
                                               "You've reached your plan's watcher limit")})
        obj = serializer.save(user=self.request.user)
        log(self.request.user, "watcher.create", id=obj.id)


@api_view(["GET"])
def watch_feed(request):
    """Recent change hits for the user's watchers (newest first)."""
    from .models import WatchHit
    hits = (WatchHit.objects.filter(watcher__user=request.user)
            .select_related("watcher")[:50])
    return Response({"hits": [
        {"id": h.id, "label": h.watcher.label, "kind": h.watcher.kind,
         "summary": h.summary, "severity": h.severity,
         "at": h.created_at.isoformat()} for h in hits]})


# ---------- Nearby (extra C) + favourite artist (extra B) ----------
@api_view(["GET"])
def nearby(request):
    from . import nearby as nb
    try:
        lat = float(request.query_params.get("lat"))
        lon = float(request.query_params.get("lon"))
    except (TypeError, ValueError):
        lang = req_lang(request)
        return Response({"detail": pick(lang, "লোকেশন (lat/lon) দরকার।",
                                        "Location (lat/lon) is required.")}, status=400)
    ptype = request.query_params.get("type", "restaurant")
    results, source = nb.search(lat, lon, ptype, lang=req_lang(request))
    log(request.user, "nearby", type=ptype, source=source, n=len(results))
    return Response({"type": ptype, "source": source, "places": results})


class FavouriteArtistView(APIView):
    """Add a favourite artist. With a YouTube channel RSS URL we watch it (no
    key); otherwise we store the name and surface a search deep-link until the
    owner adds YouTube/Spotify."""
    def post(self, request):
        from .models import Watcher
        from . import integrations
        lang = req_lang(request)
        name = (request.data.get("name") or "").strip()
        channel_rss = (request.data.get("channel_rss") or "").strip()
        if not name:
            return Response({"detail": pick(lang, "নাম দিন।", "Please enter a name.")}, status=400)
        if channel_rss:
            w, _ = Watcher.objects.get_or_create(
                user=request.user, kind="rss", label=f"🎵 {name}",
                defaults={"config": {"url": channel_rss}, "interval_min": 720})
            return Response({"ok": True, "watching": True, "watcher_id": w.id})
        import urllib.parse as up
        return Response({
            "ok": True, "watching": False,
            "youtube_search": "https://www.youtube.com/results?search_query=" + up.quote(name),
            "spotify_enabled": integrations.is_enabled("spotify"),
            "msg": pick(lang,
                        "চ্যানেল RSS দিলে নতুন গান ওয়াচ করব; নাহলে সার্চ লিংক দিচ্ছি।",
                        "Add a channel RSS and I'll watch for new releases; otherwise here's a search link."),
        })


# ---------- Finance toolkit (feature 26) ----------
class FinanceView(APIView):
    def post(self, request):
        from . import finance
        tool = request.data.get("tool")
        d = request.data
        if tool == "net_worth":
            return Response(finance.net_worth(request.user))
        if tool == "zakat":
            return Response(finance.zakat(d.get("cash"), d.get("gold_value"),
                            d.get("silver_value"), d.get("investments"),
                            d.get("debts"), d.get("nisab")))
        if tool == "emi":
            return Response(finance.emi(d.get("principal"), d.get("rate"), d.get("months")))
        if tool == "invest":
            return Response(finance.invest_projection(d.get("principal"), d.get("rate"),
                            d.get("years"), d.get("monthly_add", 0)))
        # ---- Tax & Zakat (feature #60, SPEC v2.1 §21) — server parity over
        # core.logic.tax_zakat. Pure, read-only; every rate/threshold is a
        # source-noted NBR figure, never invented. Estimate only, not tax advice.
        if tool in ("tax_estimate", "zakat_nisab", "zakat_full"):
            from .logic import tax_zakat as tz
            if tool == "tax_estimate":
                return Response(tz.estimate_income_tax(
                    d.get("taxable_income", 0),
                    year=d.get("year", tz.DEFAULT_TAX_YEAR),
                    category=d.get("category", "general"),
                    eligible_investment=d.get("eligible_investment", 0),
                    tds_paid=d.get("tds_paid", 0),
                    location=d.get("location", "dhaka_ctg"),
                    extra_disabled_dependent=bool(
                        d.get("extra_disabled_dependent"))))
            if tool == "zakat_nisab":
                return Response(tz.zakat_nisab(
                    gold_price_per_gram=d.get("gold_price_per_gram", 0),
                    silver_price_per_gram=d.get("silver_price_per_gram", 0)))
            # zakat_full
            return Response(tz.zakat(
                cash=d.get("cash", 0), bank=d.get("bank", 0),
                gold_value=d.get("gold_value", 0),
                silver_value=d.get("silver_value", 0),
                investments=d.get("investments", 0),
                business_goods=d.get("business_goods", 0),
                money_lent=d.get("money_lent", 0),
                debts=d.get("debts", 0), nisab=d.get("nisab", 0)))
        return Response({"detail": "unknown tool"}, status=400)


# ---------- Govt service + religious guide (feature 30) ----------
@api_view(["GET"])
@permission_classes([AllowAny])
def govt_guide(request):
    from .logic import guides
    return Response(guides.localized(req_lang(request)))


class ElderlyModeView(APIView):
    def post(self, request):
        request.user.elderly_mode = bool(request.data.get("enabled"))
        request.user.save(update_fields=["elderly_mode"])
        return Response({"elderly_mode": request.user.elderly_mode})


# ---------- Personal CRM (feature 24) + auto-pay ladder (feature 27) ----------
class ContactViewSet(OwnedViewSet):
    from .models import Contact as _M
    from .serializers import ContactSerializer as _S
    model = _M; kind = "contact"; serializer_class = _S


class MeetingViewSet(OwnedViewSet):
    from .models import Meeting as _M
    from .serializers import MeetingSerializer as _S
    model = _M; kind = "meeting"; serializer_class = _S


class PaCollectionViewSet(OwnedViewSet):
    """PA Secretary Mode (§14) generic per-user collection. One flexible model
    (PaCollectionItem) + a flatten serializer back the visitors/followups/
    schedule REST collections; each subclass pins its `collection` so rows never
    leak across collections. User-scoped + audit-logged via OwnedViewSet."""
    from .models import PaCollectionItem as _M
    from .serializers import PaItemSerializer as _S
    model = _M; serializer_class = _S
    collection = ""

    def get_queryset(self):
        return self.model.objects.filter(
            user=self.request.user, collection=self.collection)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user, collection=self.collection)
        log(self.request.user, f"pa.{self.collection}.create", id=obj.id)


class PaVisitorsViewSet(PaCollectionViewSet):
    collection = "visitors"; kind = "pa_visitors"


class PaFollowupsViewSet(PaCollectionViewSet):
    collection = "followups"; kind = "pa_followups"


class PaScheduleViewSet(PaCollectionViewSet):
    collection = "schedule"; kind = "pa_schedule"


# Wave E generic per-user JSON collections (task manager #21 + Section-20 money
# modules #182/#183/#184/#185). All reuse the PaCollectionItem flexible store +
# flatten serializer — one ViewSet class per collection, user-scoped by the
# PaCollectionViewSet base. Built via type() to avoid 15 identical class blocks.
GENERIC_COLLECTIONS = [
    # #21 Task manager
    "tasks_projects", "tasks_items",
    # #182 Mess accounting
    "mess/members", "mess/meals", "mess/bazar", "mess/deposits", "mess/charges",
    # #183 Expense splitting
    "split/people", "split/expenses",
    # #184 Samity / committee
    "samity_groups", "samity_members", "samity_contributions", "samity_payouts",
    # #185 Landlord-tenant
    "rent_units", "rent_payments",
    # #188 Blood-donor network
    "blood/donors",
    # #193 Prepaid meter
    "meter/meters", "meter/recharges",
    # #190 Qurbani & Eid
    "qurbani/plans", "qurbani/participants",
    # #191 Probashi corner
    "probashi/remittances", "probashi/docs",
    # #192 Student corner
    "student/routine", "student/assignments", "student/courses", "student/goals",
    # #189 Wedding & events
    "wedding/event", "wedding/guests", "wedding/budget", "wedding/tasks",
    # #198 Security check-up
    "security/checklist",
    # #199 Farmer / village mode
    "farmer/records", "farmer/livestock",
    # #186 Domestic staff + #171 Savings challenge
    "staff/people", "staff/payments", "savechal/plans", "savechal/deposits",
    # #69 Health timeline + #71 Wellness tracker
    "health/timeline", "wellness/logs",
    # #173 Daily challenges + #18 Saved/bookmarks
    "challenges/progress", "saved/items",
    # #27 Kid's school corner + #72 Fitness partner
    "kid/children", "kid/notices",
    "fitness/goals", "fitness/workouts", "fitness/weighins",
    # #30 Contract analyzer + #36 Cost/time estimator (§8, advanced)
    "contract/analyses", "estimate/projects",
    # #51 AI spending advice + #34 Market price radar (key-gated mock)
    "spending/notes", "price/logs",
    # #131 Mock interview + #132 Language-learning partner (key-gated mock)
    "interview/sessions", "langlearn/progress",
    # #92 Call & voice-note transcription (key-gated STT) + #35 Travel planner
    # (key-gated AI itinerary / booking) — deterministic organisers, key-free.
    "transcribe/notes",
    "travel/trips", "travel/days", "travel/budget", "travel/packing",
    # #130 Blog writer + #29 Doc scanner (key-gated AI/OCR mock)
    "blog/drafts", "docscan/items",
    # #17 Quick tools + #7 Daily brief (key-gated AI mock)
    "quicktools/saved", "brief/prefs",
    # PA Secretary key-gated layer (§14 #106/107/109/110/112/113/114) — mock
    "pa/callemail", "pa/letters",
    "pa/filing", "pa/minutes", "pa/actionitems",
    "pa/travel", "pa/vouchers", "pa/research",
    # PA CORPORATE tier (§14 #119 business travel & events + #120 projects) —
    # deterministic, key-free; honest booking/AI seams.
    #   pa/bizevents     — event header + agenda/budget/task child rows, each
    #                      tagged {kind:'event'|'agenda'|'budget'|'task'};
    #                      children carry {event_id}.
    #   pa/bizattendees  — attendee + per-person travel rows {event_id}.
    #   pa/projects      — project header + risk child rows, tagged
    #                      {kind:'project'|'risk'}; risks carry {project_id}.
    #   pa/milestones    — milestone rows {project_id}.
    "pa/bizevents", "pa/bizattendees",
    "pa/projects", "pa/milestones",
    # PA Secretary — CORPORATE tier A (§14 #116/#117/#118) — mock, deterministic.
    "pa/board", "pa/deptupdates", "pa/vip",
    # PA Secretary — CELEBRITY/STAR tier (§14 #121/#122/#123/#124/#125) — mock,
    # deterministic; holds no money; conservative privacy; honest key-gated seams.
    #   star/deals       — brand-deal pipeline rows (brand, value ৳, stage,
    #                      deliverables[], deadline, note). Tracks only.
    #   star/press       — coverage + interview rows, tagged
    #                      {kind:'coverage'|'interview'|'talkingpoint'}.
    #   star/socialinbox — manual DM/mention triage rows (platform, from_handle,
    #                      message, priority, status, at). LIVE fetch is a
    #                      key-gated seam (instagram + messenger/FB-Page keys).
    #   star/callsheets  — call-sheet header + child rows, tagged
    #                      {kind:'sheet'|'block'|'contact'|'check'}; children
    #                      carry {sheet_id}.
    #   star/lifestyle   — appointment/preference/routine rows, tagged
    #                      {kind:'appt'|'pref'|'routine'}. On-device only.
    "star/deals", "star/press", "star/socialinbox",
    "star/callsheets", "star/lifestyle",
    # Business #144 Supplier & wholesale market + #145 Demand map (§21) —
    # deterministic, key-free; the user's OWN data only (no scraping/fabrication).
    #   supplier/vendors — one supplier row per entry:
    #       {name, category (slug), products ("a, b" or [..]), location,
    #        contact, price_note, rating (0-5 int), note, reorder (bool)}.
    #       Filter/compare/reorder is pure (core.logic.supplier_market); a real
    #       partner/wholesale directory is a key-gated seam (supplier_directory,
    #       not in REGISTRY yet).
    #   demand/signals  — one demand signal per entry:
    #       {product, area, period, level ('low'|'medium'|'high'|'surge'),
    #        note}. Heat aggregation is pure (core.logic.demand_map); LIVE
    #       trade/market demand is a key-gated seam (trade_data, not in REGISTRY
    #       yet) — NEVER fabricated.
    "supplier/vendors", "demand/signals",
    # #6 Proactive AI dismissals + #194 Area community + #187 Doctor appointments
    "proactive/dismissed", "area/posts", "doctor/appointments",
    # CV / resume builder — single per-user CV record (no migration; generic)
    "cv",
    # Anti-theft "My Vehicles" — vehicle profile rows (type, reg/chassis/engine,
    # tax-token/fitness/insurance expiry). No migration; reuses PaCollectionItem.
    "vehicle/records",
    # v1-vehicle: Car Mode trips (head-unit GPS, summary computed server-side)
    "vehicle/trips",
]
GENERIC_COLLECTION_VIEWSETS = {
    name: type(
        "GenCol_" + name.replace("/", "_") + "ViewSet",
        (PaCollectionViewSet,),
        {"collection": name, "kind": name.replace("/", "_")},
    )
    for name in GENERIC_COLLECTIONS
}


class AutoPayRuleViewSet(OwnedViewSet):
    from .models import AutoPayRule as _M
    from .serializers import AutoPayRuleSerializer as _S
    model = _M; kind = "autopay"; serializer_class = _S

    def list(self, request, *args, **kwargs):
        from . import integrations
        lang = req_lang(request)
        resp = super().list(request, *args, **kwargs)
        # auto-pay EXECUTION needs a payment integration; be honest about it
        resp.data = {"rules": resp.data,
                     "can_execute": any(integrations.is_enabled(s) for s in
                                        ("bkash", "nagad", "sslcommerz", "ekpay")),
                     "note": pick(lang, "পেমেন্ট মেথড যোগ করলে অটো-পে চালু হবে।",
                                  "Auto-pay runs once a payment method is added.")}
        return resp


@api_view(["POST"])
def autopay_stop_all(request):
    from .models import AutoPayRule
    n = AutoPayRule.objects.filter(user=request.user).update(enabled=False)
    log(request.user, "autopay.stop_all", n=n)
    return Response({"stopped": n})


# ---------- payment / auto-pay LADDER (SPEC v2.1 §21) ----------
# Two owner-scoped collections backing the ladder screen's two tabs. A single
# PaymentDebt table backs both; `kind` is fixed per viewset (filtered on read,
# forced on create — the client never picks the collection's kind). The nested
# `ladder` is validated by the serializer via core.logic.payment_ladder, which
# rejects any auto_charge/auto_pay step. The engine holds no money and never
# auto-charges; a real payment is key-gated and happens outside the app.

class _LadderViewSet(OwnedViewSet):
    from .models import PaymentDebt as _M
    from .serializers import PaymentDebtSerializer as _S
    model = _M; serializer_class = _S
    kind_value = "receivable"   # overridden per subclass

    def get_queryset(self):
        return self.model.objects.filter(
            user=self.request.user, kind=self.kind_value)

    def perform_create(self, serializer):
        obj = serializer.save(user=self.request.user, kind=self.kind_value)
        log(self.request.user, f"{self.kind}.create", id=obj.id)

    def perform_update(self, serializer):
        # kind is fixed per collection — never let an update move a row across tabs.
        serializer.save(kind=self.kind_value)


class LadderReceivableViewSet(_LadderViewSet):
    kind = "ladder_receivable"; kind_value = "receivable"


class LadderPayableViewSet(_LadderViewSet):
    kind = "ladder_payable"; kind_value = "payable"


@api_view(["POST"])
def ladder_stop_all(request):
    """Global snooze: pause every one of the user's ladder debts (both tabs).
    Mirrors autopay/stop-all. Pausing silences escalation; it moves no money."""
    from .models import PaymentDebt
    n = PaymentDebt.objects.filter(user=request.user).update(paused=True)
    log(request.user, "ladder.stop_all", n=n)
    return Response({"stopped": n})


# ---------- Agent Studio (feature 32) ----------
_STUDIO_TASKS = {
    "letter": ("ব্যবহারকারীর অনুরোধ অনুযায়ী একটি পেশাদার চিঠি লেখো। বাংলায় লেখো।",
               "Write a professional letter based on the user's request. Write in English."),
    "cv": ("ব্যবহারকারীর তথ্য দিয়ে একটি পরিষ্কার CV বুলেট-পয়েন্টে লেখো। বাংলায় লেখো।",
           "Write a clean, bullet-point CV from the user's details. Write in English."),
    "caption": ("ব্যবহারকারীর বিষয় অনুযায়ী ছোট আকর্ষণীয় সোশ্যাল ক্যাপশন (৩টি অপশন) লেখো। বাংলায় লেখো।",
                "Write short, catchy social captions (3 options) for the user's topic. Write in English."),
    "excel": ("ব্যবহারকারীর বর্ণনা অনুযায়ী সঠিক Excel/Google Sheets ফর্মুলা দাও, সংক্ষেপে বুঝিয়ে। বাংলায় লেখো।",
              "Give the correct Excel/Google Sheets formula for the user's description, with a brief explanation. Write in English."),
    "email": ("ব্যবহারকারীর অনুরোধ অনুযায়ী একটি সংক্ষিপ্ত, ভদ্র ইমেইল খসড়া লেখো। বাংলায় লেখো।",
              "Draft a short, polite email based on the user's request. Write in English."),
}


class AgentStudioView(APIView):
    """Generate an original document (letter/CV/caption/Excel formula/email).
    Needs an AI key → clean needs-key state otherwise."""
    def post(self, request):
        lang = req_lang(request)
        kind = request.data.get("kind", "letter")
        prompt = (request.data.get("prompt") or "").strip()
        if not prompt:
            return Response({"detail": pick(lang, "প্রম্পট দিন।", "A prompt is required.")}, status=400)
        if not ai.available():
            return Response({"needs_key": True,
                             "msg": pick(lang, "চালু হবে যখন AI key যোগ হবে।",
                                         "Available when an AI key is added.")})
        task = pick(lang, *_STUDIO_TASKS.get(kind, _STUDIO_TASKS["letter"]))
        try:
            text, _ = ai.generate(task=task, data=prompt, tier="medium",
                                   feature=f"studio.{kind}", max_tokens=900, user=request.user)
            return Response({"kind": kind, "text": text, "ai_used": True})
        except ai.AIUnavailable as e:
            return Response({"needs_key": e.reason == "no_key", "reason": e.reason,
                             "msg": pick(lang, "এখন পারলাম না — একটু পরে চেষ্টা করুন।",
                                         "Couldn't do that right now — try again shortly.")})


# ---------- AI Inbox (feature 22) — classify red/yellow/green ----------
def classify_inbox_item(subject, snippet):
    """Rule-based triage (works without AI); red=urgent/action, yellow=reply
    soon, green=fyi. AI can refine when a key + Gmail are connected."""
    s = f"{subject} {snippet}".lower()
    red = ["urgent", "asap", "overdue", "due today", "payment failed", "suspended",
           "action required", "জরুরি", "আজকের মধ্যে", "বকেয়া", "বন্ধ"]
    yellow = ["reply", "response needed", "waiting", "reminder", "follow up",
              "invoice", "meeting", "উত্তর", "মিটিং", "রিমাইন্ডার"]
    if any(w in s for w in red):
        return "red"
    if any(w in s for w in yellow):
        return "yellow"
    return "green"


class InboxView(APIView):
    """AI Inbox. Fetching email needs Gmail OAuth (🔑); this returns the clean
    'Available when ___' state until connected, plus the classifier for items
    the app passes in."""
    def get(self, request):
        from . import integrations
        lang = req_lang(request)
        connected = integrations.is_enabled("google_oauth")
        return Response({
            "connected": connected,
            "msg": None if connected else
            pick(lang, "চালু হবে যখন Gmail যোগ হবে।",
                 "Available when Gmail is connected."),
            "legend": {"red": pick(lang, "জরুরি/অ্যাকশন", "Urgent / action"),
                       "yellow": pick(lang, "শীঘ্রই উত্তর", "Reply soon"),
                       "green": pick(lang, "তথ্য", "FYI")},
        })

    def post(self, request):
        items = request.data.get("items", []) or []
        out = [{**it, "triage": classify_inbox_item(it.get("subject", ""),
                                                     it.get("snippet", ""))}
               for it in items[:100]]
        return Response({"items": out})


# ---------- Business mode (feature 33) ----------
class ProductViewSet(OwnedViewSet):
    from .models import Product as _M
    from .serializers import ProductSerializer as _S
    model = _M; kind = "product"; serializer_class = _S


class OrderViewSet(OwnedViewSet):
    from .models import Order as _M
    from .serializers import OrderSerializer as _S
    model = _M; kind = "order"; serializer_class = _S


class BusinessReplyView(APIView):
    """Draft a reply to a customer message from the REAL catalog. Never sends
    automatically here; the app/webhook decides. Honest handoff when unsure."""
    def post(self, request):
        from . import business
        text = (request.data.get("text") or "").strip()
        if not text:
            return Response({"detail": "text required"}, status=400)
        reply, handoff, used_ai = business.reply_for(request.user, text, lang=req_lang(request))
        return Response({"reply": reply, "needs_handoff": handoff, "ai_used": used_ai})


class BusinessOrderCaptureView(APIView):
    def post(self, request):
        from . import business
        text = (request.data.get("text") or "").strip()
        order, draft = business.capture_order(
            request.user, text, request.data.get("phone", ""),
            request.data.get("channel", "manual"), lang=req_lang(request))
        return Response({"order_id": order.id if order else None, "draft": draft})


class WhatsAppWebhookView(APIView):
    """Meta WhatsApp Cloud webhook. Verification + inbound messages. Auto-reply
    only runs if the owner enabled it AND WhatsApp is connected; otherwise we
    just record. Sending back needs the integration (🔑)."""
    permission_classes = [AllowAny]

    def get(self, request):   # Meta webhook verification handshake
        from . import integrations
        cfg = integrations.get("whatsapp")
        if (request.query_params.get("hub.mode") == "subscribe"
                and request.query_params.get("hub.verify_token") == cfg.get("verify_token")):
            return HttpResponse(request.query_params.get("hub.challenge", ""))
        return HttpResponse("forbidden", status=403)

    def post(self, request):
        from . import integrations
        if not integrations.is_enabled("whatsapp"):
            return Response({"ok": True, "note": "whatsapp not connected"})
        # Inbound handling (store + optional draft) would go here; sending a
        # reply uses the Graph API with the stored token. Kept minimal + honest.
        log(None if not request.user.is_authenticated else request.user,
            "whatsapp.inbound")
        return Response({"ok": True})


# ---------- Nominee / family access (feature 36 — advanced) ----------
#
# SERVER-AUTHORITATIVE SAFETY GATE. The pure state-machine core.logic.nominee is
# the single source of truth for every release transition; the view NEVER trusts
# a client-sent release_state. All lifecycle fields are read_only in the
# serializer, and the two helpers below are the ONLY paths that write them —
# each through the validated logic functions. This is what stops a client from
# forging an `open` state or skipping the grace window.

def _nominee_build_input(request):
    d = request.data or {}
    scopes = d.get("scopes")
    if scopes is None and d.get("scope"):
        scopes = [d.get("scope")]
    return dict(
        name=d.get("name", ""),
        contact=d.get("contact", ""),
        relationship=d.get("relationship", "family"),
        scopes=scopes,
        priority=d.get("priority", 1),
        trigger=d.get("trigger", "owner_grant"),
        inactivity_days=d.get("inactivity_days", 30),
        grace_hours=d.get("grace_hours", 48),
        multi_verify_ids=d.get("multi_verify_ids"),
        multi_verify_quorum=d.get("multi_verify_quorum", 2),
    )


def _apply_nominee_row(obj, row):
    """Persist the normalized dict a core.logic.nominee fn returned back onto the
    model. Only ever called with a dict the logic layer produced."""
    from django.utils.dateparse import parse_datetime
    obj.name = row["name"]
    obj.contact = row["contact"]
    obj.relationship = row["relationship"]
    obj.scopes = row["scopes"]
    obj.scope = row["scope"]
    obj.priority = row["priority"]
    obj.trigger = row["trigger"]
    obj.inactivity_days = row["inactivity_days"]
    obj.grace_hours = row["grace_hours"]
    obj.multi_verify_ids = row["multi_verify_ids"]
    obj.multi_verify_quorum = row["multi_verify_quorum"]
    obj.release_state = row["release_state"]
    obj.release_pending = row.get("release_pending", row["release_state"] == "pending")
    obj.release_requested_at = (parse_datetime(row["release_requested_at"])
                                if row.get("release_requested_at") else None)
    obj.release_confirmations = row.get("release_confirmations") or []
    obj.activated = row["activated"]
    obj.activated_at = (parse_datetime(row["activated_at"])
                        if row.get("activated_at") else None)


class NomineeViewSet(OwnedViewSet):
    """list/create/update/delete nominees. create + update feed owner input
    through nominee.build_nominee (validates → 400 on an unusable plan) so a bad
    definition can never silently become a live grant. A client PATCH can never
    change release_state: build_nominee always returns a fresh dormant lifecycle
    on edit, and the lifecycle fields are serializer read-only regardless."""
    from .models import Nominee as _M
    from .serializers import NomineeSerializer as _S
    model = _M; kind = "nominee"; serializer_class = _S

    def create(self, request, *args, **kwargs):
        from .logic import nominee as nlogic
        lang = req_lang(request)
        try:
            row = nlogic.build_nominee(**_nominee_build_input(request))
        except ValueError:
            return Response({"detail": pick(lang,
                "নাম ও অন্তত একটি অ্যাক্সেস ক্যাটেগরি দিন।",
                "Provide a name and at least one access category.")}, status=400)
        from .models import Nominee
        obj = Nominee(user=request.user)
        _apply_nominee_row(obj, row)
        obj.save()
        log(request.user, "nominee.create", id=obj.id, trigger=obj.trigger,
            scopes=obj.scopes)
        return Response(self.get_serializer(obj).data, status=201)

    def update(self, request, *args, **kwargs):
        from .logic import nominee as nlogic
        lang = req_lang(request)
        obj = self.get_object()
        try:
            row = nlogic.build_nominee(**_nominee_build_input(request))
        except ValueError:
            return Response({"detail": pick(lang,
                "নাম ও অন্তত একটি অ্যাক্সেস ক্যাটেগরি দিন।",
                "Provide a name and at least one access category.")}, status=400)
        # Editing a plan returns it to a dormant/armed lifecycle — never lets a
        # client-sent release_state survive. Any live release must be re-driven
        # through request-release / confirm-open below.
        _apply_nominee_row(obj, row)
        obj.save()
        log(request.user, "nominee.update", id=obj.id)
        return Response(self.get_serializer(obj).data)


def _wellness_state_for(user):
    """Compute the current Safe-Journey wellness state for a user from their
    WellnessWatch row (item 16). Only 'alert' is accepted as the inactivity
    trigger's precondition in request_release."""
    from .logic import safety_journey as SJ
    w = getattr(user, "wellness_watch", None)
    if w is None:
        return "off"
    cfg = {"enabled": w.enabled, "parent_opt_in": w.parent_opt_in,
           "period_hours": w.period_hours,
           "response_window_min": w.response_window,
           "quiet_start": w.quiet_start, "quiet_end": w.quiet_end}
    state, _ = SJ.wellness_state(cfg, w.last_activity_at,
                                 prompt_sent_at=w.prompt_sent_at)
    return state


@api_view(["POST"])
def nominee_request_release(request, pk):
    """POST /nominees/<pk>/request-release — armed → pending (start the
    cancellable grace window) via nominee.request_release. Preconditions per
    trigger are enforced in the pure layer; nothing is shared yet."""
    from .models import Nominee
    from .logic import nominee as nlogic
    from .serializers import _nominee_row, NomineeSerializer
    lang = req_lang(request)
    n = Nominee.objects.filter(user=request.user, pk=pk).first()
    if not n:
        return Response({"detail": pick(lang, "পাওয়া যায়নি।", "Not found.")}, status=404)

    trigger = n.trigger
    owner_confirmed = bool(request.data.get("owner_confirmed", False))
    confirmations = request.data.get("confirmations") or []
    # inactivity: the wellness_state is computed SERVER-SIDE from the existing
    # Safe-Journey engine — the client cannot supply it.
    wellness_state = _wellness_state_for(request.user) if trigger == "inactivity" else None

    ok, bn, en, row = nlogic.request_release(
        _nominee_row(n), owner_confirmed=owner_confirmed,
        now=timezone.now(), wellness_state=wellness_state,
        confirmations=confirmations)
    if not ok:
        return Response({"detail": pick(lang, bn, en)}, status=409)
    _apply_nominee_row(n, row)
    n.save()
    log(request.user, "nominee.request_release", id=n.id, trigger=trigger,
        state=n.release_state)
    return Response(NomineeSerializer(n).data)


@api_view(["POST"])
def nominee_cancel_release(request, pk):
    """POST /nominees/<pk>/cancel-release — the owner's always-on kill switch.
    Returns any state to `armed`, closing/revoking any access. Always allowed."""
    from .models import Nominee
    from .logic import nominee as nlogic
    from .serializers import _nominee_row, NomineeSerializer
    lang = req_lang(request)
    n = Nominee.objects.filter(user=request.user, pk=pk).first()
    if not n:
        return Response({"detail": pick(lang, "পাওয়া যায়নি।", "Not found.")}, status=404)
    row = nlogic.cancel_release(_nominee_row(n))
    _apply_nominee_row(n, row)
    n.save()
    log(request.user, "nominee.cancel_release", id=n.id)
    return Response(NomineeSerializer(n).data)


@api_view(["POST"])
def nominee_confirm_open(request, pk):
    """POST /nominees/<pk>/confirm-open — the FINAL open step: pending → open via
    nominee.open_access, which REFUSES unless the grace window has fully elapsed
    (can_open_now) AND the owner confirms once more. Rejects with 409 if the
    window has not elapsed — this is what stops skipping the grace period."""
    from .models import Nominee
    from .logic import nominee as nlogic
    from .serializers import _nominee_row, NomineeSerializer
    lang = req_lang(request)
    n = Nominee.objects.filter(user=request.user, pk=pk).first()
    if not n:
        return Response({"detail": pick(lang, "পাওয়া যায়নি।", "Not found.")}, status=404)
    owner_confirmed = bool(request.data.get("owner_confirmed", False))
    now = timezone.now()
    if not nlogic.can_open_now(_nominee_row(n), now=now):
        return Response({"detail": pick(lang, "গ্রেস সময় এখনও শেষ হয়নি।",
                                        "The grace window has not elapsed yet.")},
                        status=409)
    ok, bn, en, row = nlogic.open_access(_nominee_row(n),
                                         owner_confirmed=owner_confirmed, now=now)
    if not ok:
        return Response({"detail": pick(lang, bn, en)}, status=409)
    _apply_nominee_row(n, row)
    n.save()
    log(request.user, "nominee.confirm_open", id=n.id, scopes=n.scopes)
    return Response(NomineeSerializer(n).data)


@api_view(["POST"])
def nominee_activate(request, pk):
    """Legacy POST /nominees/<pk>/activate kept for back-compat and now the FINAL
    open step: it gates on nominee.can_open_now (grace fully elapsed) and a final
    owner confirmation, mirroring confirm-open. activated=False delegates to
    cancel_release (the always-safe revoke)."""
    from .models import Nominee
    from .logic import nominee as nlogic
    from .serializers import _nominee_row, NomineeSerializer
    lang = req_lang(request)
    n = Nominee.objects.filter(user=request.user, pk=pk).first()
    if not n:
        return Response({"detail": pick(lang, "পাওয়া যায়নি।", "Not found.")}, status=404)
    want = bool(request.data.get("activated", True))
    now = timezone.now()
    if not want:
        row = nlogic.cancel_release(_nominee_row(n))
        _apply_nominee_row(n, row)
        n.save()
        log(request.user, "nominee.activate", id=n.id, on=False)
        return Response({"id": n.id, "activated": n.activated})
    if not nlogic.can_open_now(_nominee_row(n), now=now):
        return Response({"detail": pick(lang, "গ্রেস সময় এখনও শেষ হয়নি।",
                                        "The grace window has not elapsed yet.")},
                        status=409)
    ok, bn, en, row = nlogic.open_access(
        _nominee_row(n), owner_confirmed=bool(request.data.get("owner_confirmed", True)),
        now=now)
    if not ok:
        return Response({"detail": pick(lang, bn, en)}, status=409)
    _apply_nominee_row(n, row)
    n.save()
    log(request.user, "nominee.activate", id=n.id, on=n.activated)
    return Response({"id": n.id, "activated": n.activated})


# ---------- Job hunter agent (feature 37) ----------
class JobViewSet(OwnedViewSet):
    from .models import JobApplication as _M
    from .serializers import JobApplicationSerializer as _S
    model = _M; kind = "job"; serializer_class = _S

    def perform_create(self, serializer):
        from . import jobs
        skills = jobs.user_skills(self.request.user)
        jd = serializer.validated_data.get("jd", "")
        score, reason = jobs.match(jd, skills, lang=req_lang(self.request))
        obj = serializer.save(user=self.request.user, match_score=score,
                              match_reason=reason)
        log(self.request.user, "job.match", id=obj.id, score=score)


class JobTailorView(APIView):
    """Generate a tailored CV + cover letter for a job (AI; needs-key state).
    Never auto-applies — returns drafts for the user to approve + send."""
    def post(self, request, pk):
        from .models import JobApplication
        from . import jobs, integrations
        lang = req_lang(request)
        j = JobApplication.objects.filter(user=request.user, pk=pk).first()
        if not j:
            return Response({"detail": pick(lang, "খুঁজে পাওয়া যায়নি।", "Not found.")}, status=404)
        res = jobs.tailor_documents(request.user, j.jd,
                                    extra=request.data.get("extra", ""), lang=req_lang(request))
        if res.get("cv_text"):
            j.cv_text = res["cv_text"]
            j.cover_letter = res.get("cover_letter", "")
            j.status = "drafted"
            j.save(update_fields=["cv_text", "cover_letter", "status"])
        res["can_send"] = integrations.is_enabled("google_oauth")
        res["send_note"] = (pick(lang,
                                 "নিজের Gmail থেকে পাঠাতে Gmail যোগ করুন; অটো-অ্যাপ্লাই কখনো নয়।",
                                 "Connect Gmail to send from your own account; never auto-apply.")
                            if not res["can_send"] else
                            pick(lang,
                                 "আপনি অনুমোদন করলে নিজের Gmail থেকে পাঠানো যাবে (অটো-অ্যাপ্লাই নয়)।",
                                 "With your approval, this can be sent from your own Gmail (never auto-apply)."))
        return Response(res)


def _json_decimals(obj):
    from decimal import Decimal
    if isinstance(obj, Decimal):
        return str(obj)
    if isinstance(obj, dict):
        return {k: _json_decimals(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_json_decimals(v) for v in obj]
    return obj


# ---------- My Account (money) advanced endpoints (Phase B) ----------
def _money_txns(user):
    return [{"kind": t.kind, "amount": t.amount, "category": t.category,
             "date": t.date, "account": t.account_id, "to_account": t.to_account_id}
            for t in user.txns.all()]


def _money_accounts(user):
    from django.db.models import Sum
    from decimal import Decimal
    def dec(x): return x or Decimal("0")
    out = []
    for a in user.accounts.all():
        inc = dec(a.txns.filter(kind="income").aggregate(s=Sum("amount"))["s"])
        exp = dec(a.txns.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
        tout = dec(a.txns.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
        tin = dec(a.txns_in.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
        out.append({"balance": a.opening_balance + inc - exp - tout + tin})
    return out


def _money_loans(user):
    return [{"amount": ln.amount, "kind": ln.kind, "repayments": ln.repayments or [],
             "settled": ln.settled, "date": str(ln.date or "")}
            for ln in user.loans.all()]


class MoneyTrendsView(APIView):
    def get(self, request):
        from .logic import money_engine as me
        txns = _money_txns(request.user)
        cur = me.month_key(timezone.localdate())
        return Response({
            "months": [{k: (str(v) if k != "month" else v) for k, v in row.items()}
                       for row in me.month_over_month(txns, 6)],
            "categories": [{**r, "current": str(r["current"]), "previous": str(r["previous"]),
                            "delta": str(r["delta"])}
                           for r in me.category_trends(txns, cur)["categories"]],
        })


class MoneyNetWorthView(APIView):
    def get(self, request):
        from .logic import money_engine as me
        from decimal import Decimal
        accounts = _money_accounts(request.user)
        loans = _money_loans(request.user)
        nw = me.net_worth(accounts, loans)
        # net-worth trajectory: back-cast from current net worth using monthly net flows
        txns = _money_txns(request.user)
        mom = me.month_over_month(txns, 6)
        total_flow = sum((Decimal(str(r["net"])) for r in mom), Decimal("0"))
        start = Decimal(str(nw["net_worth"])) - total_flow
        running = start
        snaps = []
        for r in mom:
            running = running + Decimal(str(r["net"]))
            snaps.append({"month": r["month"], "net_worth": running})
        series = [{"month": x["month"], "net_worth": str(x["net_worth"]), "delta": str(x["delta"])}
                  for x in me.net_worth_series(snaps)]
        return Response({k: str(v) for k, v in nw.items()} | {"series": series})


class MoneyBudgetDetailView(APIView):
    def get(self, request):
        from .logic import money_engine as me
        cat = request.query_params.get("category", "")
        b = request.user.budgets.filter(category=cat).first()
        if not b:
            return Response({"detail": pick(req_lang(request), "বাজেট নেই", "No such budget")},
                            status=status.HTTP_404_NOT_FOUND)
        txns = _money_txns(request.user)
        cur = me.month_key(timezone.localdate())
        months = [me.month_key(me.add_months(me._as_date(cur + "-01"), -i)) for i in range(5, -1, -1)]
        spend = {mk: me.category_spend(txns, mk).get(cat, me.ZERO) for mk in months}
        rows = me.budget_with_rollover(cat, b.monthly_limit, spend, months, rollover=b.rollover)
        out = [{k: (str(v) if k not in ("month", "state", "pct") else v) for k, v in r.items()}
               for r in rows]
        carry = out[-1].get("carry_forward", "0") if out else "0"
        return Response({"category": cat, "rollover": b.rollover,
                         "carry_forward": carry, "months": out})


class MoneyWrappedView(APIView):
    """Monthly Money Wrapped (feature #63, SPEC v2.1 §21) — a Spotify-Wrapped
    style recap of ONE month, computed ONLY from the user's real transaction
    rows (read-only) by money_engine.monthly_wrapped. Never fabricates numbers;
    for users with too little history it returns enough_data=False so the client
    shows an honest empty state. Parallels MoneyTrendsView. Owner-scoped (txns
    come from request.user). Optional ?month=YYYY-MM; defaults to current month.
    Bilingual category slugs localise client-side via Accept-Language."""

    def get(self, request):
        from .logic import money_engine as me
        txns = _money_txns(request.user)
        month = request.query_params.get("month") or me.month_key(
            timezone.localdate())
        rec = me.monthly_wrapped(txns, month)
        return Response(_json_decimals(rec))


class MoneyBudgetView(APIView):
    """Advanced Budget module (feature #50, SPEC v2.1 §21). Reads the user's REAL
    transactions read-only through core.logic.budget (integer-poisha, no float
    drift); budgets are stored in the existing Budget model. Owner-scoped.

    GET  /money/budget/month[?month=YYYY-MM]  -> month_budget + insights
    GET  /money/budget/history?category=&months=6 -> rollover_series
    GET  /money/budget/plan?months=3&buffer=10 -> next_month_plan
    GET  /money/budget/template?income=       -> template_50_30_20
    POST /money/budget {category,monthly_limit,rollover}
    PATCH/money/budget/<id> {monthly_limit?,rollover?}
    POST /money/budget/<id>/delete
    POST /money/budget/goal-link              -> goal_contribution (+persist)
    """

    def _budget_rows(self, user):
        return [{"category": b.category, "monthly_limit": b.monthly_limit,
                 "rollover": b.rollover} for b in user.budgets.all()]

    def _recent_months(self, me, n):
        cur = me.month_key(timezone.localdate())
        return [me.month_key(me.add_months(me._as_date(cur + "-01"), -i))
                for i in range(n - 1, -1, -1)]

    def get(self, request, pk=None, action=""):
        if pk is not None:
            # money/budget/<pk>[/delete] are POST/PATCH-only; a GET used to 500.
            return Response({"detail": "method not allowed"},
                            status=status.HTTP_405_METHOD_NOT_ALLOWED)
        from .logic import budget as bg
        from .logic import money_engine as me
        txns = _money_txns(request.user)
        if action == "month":
            month = request.query_params.get("month") or me.month_key(
                timezone.localdate())
            result = bg.month_budget(self._budget_rows(request.user), txns, month)
            result["insights"] = bg.insights(result)
            return Response(_json_decimals(result))
        if action == "history":
            cat = request.query_params.get("category", "")
            try:
                n = max(1, min(24, int(request.query_params.get("months", 6))))
            except (TypeError, ValueError):
                n = 6
            b = request.user.budgets.filter(category=cat).first()
            if not b:
                return Response(
                    {"detail": pick(req_lang(request), "বাজেট নেই",
                                    "No such budget")},
                    status=status.HTTP_404_NOT_FOUND)
            months = self._recent_months(me, n)
            spend = {mk: bg.from_poisha(
                bg.spent_by_category(txns, mk).get(cat, 0)) for mk in months}
            return Response(_json_decimals(bg.rollover_series(
                cat, b.monthly_limit, spend, months, rollover=b.rollover)))
        if action == "plan":
            try:
                n = max(1, min(24, int(request.query_params.get("months", 3))))
                buf = max(0, min(100, int(request.query_params.get("buffer", 10))))
            except (TypeError, ValueError):
                n, buf = 3, 10
            months = self._recent_months(me, n)
            return Response(_json_decimals(
                bg.next_month_plan(txns, months, buffer_pct=buf)))
        if action == "template":
            income = request.query_params.get("income", "0")
            return Response(_json_decimals(bg.template_50_30_20(income)))
        return Response({"detail": "unknown action"},
                        status=status.HTTP_404_NOT_FOUND)

    def post(self, request, pk=None, action=""):
        from .logic import budget as bg
        from .logic import money_engine as me
        from .models import Budget
        from decimal import Decimal
        if action == "goal-link":
            month = request.data.get("month") or me.month_key(
                timezone.localdate())
            result = bg.month_budget(self._budget_rows(request.user),
                                     _money_txns(request.user), month)
            goal = request.user.goals.order_by("-updated_at").first()
            if not goal:
                return Response(
                    {"detail": pick(req_lang(request), "কোনো লক্ষ্য নেই",
                                    "No savings goal")},
                    status=status.HTTP_404_NOT_FOUND)
            card = bg.goal_contribution(
                result, {"target_amount": goal.target_amount,
                         "saved_amount": goal.saved_amount})
            goal.saved_amount = Decimal(str(card["new_saved"]))
            goal.save(update_fields=["saved_amount", "updated_at"])
            return Response(_json_decimals(card))
        if pk is not None and action == "delete":
            request.user.budgets.filter(pk=pk).delete()
            return Response({"ok": True})
        # create
        cat = (request.data.get("category") or "").strip()
        if not cat:
            return Response(
                {"detail": pick(req_lang(request), "খাত দিন",
                                "Category required")},
                status=status.HTTP_400_BAD_REQUEST)
        b, _ = Budget.objects.update_or_create(
            user=request.user, category=cat,
            defaults={"monthly_limit": Decimal(str(
                request.data.get("monthly_limit") or "0")),
                "rollover": bool(request.data.get("rollover"))})
        return Response({"id": b.id, "category": b.category,
                         "monthly_limit": str(b.monthly_limit),
                         "rollover": b.rollover},
                        status=status.HTTP_201_CREATED)

    def patch(self, request, pk=None, action=""):
        from .models import Budget
        from decimal import Decimal
        b = request.user.budgets.filter(pk=pk).first()
        if not b:
            return Response(
                {"detail": pick(req_lang(request), "বাজেট নেই",
                                "No such budget")},
                status=status.HTTP_404_NOT_FOUND)
        if "monthly_limit" in request.data:
            b.monthly_limit = Decimal(str(request.data.get("monthly_limit") or "0"))
        if "rollover" in request.data:
            b.rollover = bool(request.data.get("rollover"))
        b.save()
        return Response({"id": b.id, "category": b.category,
                         "monthly_limit": str(b.monthly_limit),
                         "rollover": b.rollover})


class MoneyReportView(APIView):
    def get(self, request):
        from .logic import money_engine as me
        txns = _money_txns(request.user)
        cur = me.month_key(timezone.localdate())
        budgets = [{"category": b.category, "monthly_limit": b.monthly_limit}
                   for b in request.user.budgets.all()]
        rep = me.monthly_report(txns, cur, budgets=budgets)
        return Response(_json_decimals(rep))


class MoneyReportExportView(APIView):
    def get(self, request, fmt="pdf"):
        from .logic import money_engine as me
        from django.http import HttpResponse
        txns = _money_txns(request.user)
        cur = me.month_key(timezone.localdate())
        budgets = [{"category": b.category, "monthly_limit": b.monthly_limit}
                   for b in request.user.budgets.all()]
        rep = me.monthly_report(txns, cur, budgets=budgets)
        lines = [f"Monthly report — {rep['month']}",
                 f"Income: {rep['income']}  Expense: {rep['expense']}  Net: {rep['net']}",
                 f"Savings rate: {rep['savings_rate']}%", "", "By category:"]
        for r in rep["by_category"]:
            lines.append(f"  {r['category']}: {r['amount']}")
        if fmt == "xlsx":
            try:
                import io, openpyxl
                wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Report"
                ws.append(["Month", rep["month"]]); ws.append(["Income", str(rep["income"])])
                ws.append(["Expense", str(rep["expense"])]); ws.append(["Net", str(rep["net"])])
                ws.append([]); ws.append(["Category", "Amount"])
                for r in rep["by_category"]:
                    ws.append([str(r["category"]), str(r["amount"])])
                buf = io.BytesIO(); wb.save(buf)
                return HttpResponse(buf.getvalue(),
                    content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            except Exception:
                return HttpResponse("\n".join(lines), content_type="text/csv")
        try:
            import io
            from reportlab.pdfgen import canvas
            buf = io.BytesIO(); c = canvas.Canvas(buf); y = 800
            for ln in lines:
                c.drawString(50, y, ln); y -= 18
            c.showPage(); c.save()
            return HttpResponse(buf.getvalue(), content_type="application/pdf")
        except Exception:
            return HttpResponse("\n".join(lines), content_type="text/plain")


class MoneyParseView(APIView):
    def post(self, request):
        from .logic import money_parse as mp
        text = request.data.get("text", "") or ""
        msgs = [m for m in text.splitlines() if m.strip()] or [text]
        parsed = mp.parse_batch(msgs)
        seen = set(request.user.txns.exclude(ref="").values_list("ref", flat=True))
        parsed = mp.dedupe(parsed, seen_fingerprints=None)
        for p in parsed:
            if p.get("ref") and p["ref"] in seen:
                p["duplicate"] = True
            p["amount"] = str(p["amount"]) if p.get("amount") is not None else None
        return Response({"transactions": parsed})


class MoneyLearnCategoryView(APIView):
    def post(self, request):
        from .logic import money_parse as mp
        mp.learn_correction(request.data.get("counterparty", ""),
                            request.data.get("category", ""), user=request.user)
        return Response({"ok": True})


# ===========================================================================
# HOME NOTIFICATION CENTRE + DYNAMIC SUGGESTIONS
#   Pure engines: core.logic.notif_centre + core.logic.suggestions.
#   The views here only COLLECT the user's live rows and hand them to the
#   engines — all classification/ranking/snooze math stays pure & tested.
# ===========================================================================
from datetime import datetime, time as _time
from .logic import notif_centre as _nc
from .logic import suggestions as _sg


def _dt(d):
    """date -> aware-naive datetime at midnight; pass datetimes through. The
    engines work in naive local time (we feed them timezone.localtime())."""
    if d is None:
        return None
    if isinstance(d, datetime):
        return timezone.localtime(d).replace(tzinfo=None) if timezone.is_aware(d) else d
    return datetime(d.year, d.month, d.day)


def _collect_reminders(user, now, lang="bn"):
    """Aggregate every TIME-BOUND row the user owns into the raw shape
    notif_centre.build_reminders expects. Pure data gathering only."""
    from .logic import medicine as _mlogic
    today = now.date()
    items = []

    # 1) reminders / alarms / calendar
    for r in user.reminders.filter(done=False):
        items.append({
            "id": f"reminder:{r.id}", "source_module": "reminder",
            "title": {"bn": r.title, "en": r.title},
            "when": _dt(r.due_at), "done": r.done,
            "meta": {"recurrence": r.recurrence},
        })

    # 2) to-dos (with a due date)
    for t in user.todos.filter(done=False, due_at__isnull=False):
        items.append({
            "id": f"todo:{t.id}", "source_module": "todo",
            "title": {"bn": t.title, "en": t.title}, "when": _dt(t.due_at),
        })

    # 3) medicine doses — today's slots as concrete datetimes
    for m in user.medicines.all():
        if m.as_needed:
            continue
        if m.start_date and today < m.start_date:
            continue
        if m.end_date and today > m.end_date:
            continue
        for slot in (m.times or []):
            try:
                h, mn = str(slot).split(":")
                when = datetime(today.year, today.month, today.day, int(h), int(mn))
            except Exception:
                continue
            items.append({
                "id": f"medicine:{m.id}:{slot}", "source_module": "medicine",
                "title": {"bn": f"{m.name} ({slot})", "en": f"{m.name} ({slot})"},
                "when": when, "meta": {"dosage": m.dosage, "member_id": m.member_id},
            })

    # 4) bills / subscriptions due
    for s in user.subscriptions.filter(next_due__isnull=False):
        items.append({
            "id": f"subscription:{s.id}", "source_module": "subscription",
            "title": {"bn": f"{s.name} বিল", "en": f"{s.name} bill"},
            "when": _dt(s.next_due), "meta": {"amount": str(s.amount)},
        })

    # 5) meetings / appointments
    for mt in user.meetings.filter(when__isnull=False):
        items.append({
            "id": f"meeting:{mt.id}", "source_module": "meeting",
            "title": {"bn": mt.title, "en": mt.title}, "when": _dt(mt.when),
        })
    for ap in user.appointments.all():
        items.append({
            "id": f"appointment:{ap.id}", "source_module": "appointment",
            "title": {"bn": ap.title, "en": ap.title}, "when": _dt(ap.start),
            "meta": {"place": ap.place},
        })

    # 6) birthdays / memorable days — next occurrence this/next year
    for b in user.birthdays.all():
        try:
            occ = b.date.replace(year=today.year)
            if occ < today:
                occ = b.date.replace(year=today.year + 1)
        except ValueError:
            continue
        items.append({
            "id": f"birthday:{b.id}", "source_module": "birthday",
            "title": {"bn": f"{b.name} — {b.get_kind_display()}",
                      "en": f"{b.name} — {b.kind}"},
            "when": _dt(occ),
        })

    # 7) document expiry
    for d in user.documents.filter(expiry_date__isnull=False):
        items.append({
            "id": f"document:{d.id}", "source_module": "document",
            "title": {"bn": f"{d.title} মেয়াদ", "en": f"{d.title} expiry"},
            "when": _dt(d.expiry_date),
        })

    # 8) loan / EMI returns (unsettled, with a due date)
    for ln in user.loans.filter(settled=False, due_date__isnull=False):
        items.append({
            "id": f"loan:{ln.id}", "source_module": "loan",
            "title": {"bn": f"{ln.person} — ধার ফেরত", "en": f"{ln.person} — loan return"},
            "when": _dt(ln.due_date), "meta": {"amount": str(ln.amount)},
        })

    return items


def _notif_settings(user):
    """The user's per-type enabled map (empty = all on)."""
    from .models import NotifSettings
    ns = NotifSettings.objects.filter(user=user).first()
    return (ns.enabled if ns else {}) or {}


def _collect_events(user, lang="bn"):
    """Gather notification-centre events: persisted NotifEvent rows PLUS live
    rows reused from existing alert sources (FamilyAlert). CHAT is never here."""
    events = []
    # persisted events
    for e in user.notif_events.all()[:200]:
        events.append({
            "id": f"notif:{e.id}", "type": e.type,
            "title": {"bn": e.title_bn, "en": e.title_en},
            "body": {"bn": e.body_bn, "en": e.body_en},
            "at": _dt(e.at), "seen": e.seen, "route": e.route or None,
            "meta": e.meta,
        })
    # reuse existing family alerts (missed medicine / safe-journey / scam relays)
    for fa in user.family_alerts.filter(dismissed=False)[:50]:
        etype = _nc.TYPE_FAMILY_ALERT
        k = (fa.kind or "")
        if "scam" in k:
            etype = _nc.TYPE_SCAM
        elif "checkin" in k or "journey" in k or "arrived" in k:
            etype = _nc.TYPE_SAFE_JOURNEY
        elif "sos" in k:
            etype = _nc.TYPE_SOS
        events.append({
            "id": f"familyalert:{fa.id}", "type": etype,
            "title": {"bn": fa.title, "en": fa.title},
            "body": {"bn": fa.body, "en": fa.body},
            "at": _dt(fa.created_at), "seen": False,
            "meta": {"severity": fa.severity, "source": "family_alert"},
        })
    return events


def _chat_unread(user):
    """My Circle unread CHAT count for the home badge. b2-badges: delegated to
    the ONE shared function the chat list uses (core/b2_badges.py), so the
    badge always equals the sum the chat list shows and never counts messages
    the user cannot open. Chat never enters the notif centre feed."""
    from . import b2_badges as B2
    return B2.badge_total(user)


@api_view(["GET"])
def notif_reminders(request):
    """GET notif/reminders — the Today / Upcoming / Missed reminders feed."""
    lang = req_lang(request)
    now = timezone.localtime().replace(tzinfo=None)
    raw = _collect_reminders(request.user, now, lang)
    # m1: occurrences the user marked Done (meeting/appointment/birthday).
    from .views_m1_routes import dismissed_ids
    gone = dismissed_ids(request.user)
    raw = [r for r in raw if r.get("id") not in gone]
    feed = _nc.build_reminders(raw, now)
    counts = {s: len(feed[s]) for s in _nc.SECTIONS}
    from . import b2_badges as B2
    marks = B2.watermarks(request.user)
    return Response({
        "now": now.isoformat(),
        "sections": feed,
        "counts": counts,
        # b2-badges: Reminders-tab badge (due items newer than the tab's
        # last opening; POST notif/opened {scope: reminders} clears it)
        "badge": _nc.reminders_badge(feed, now, _dt(marks["reminders"])),
        "snooze_options": list(_nc.SNOOZE_PRESETS),
    })


@api_view(["POST"])
def notif_reminder_snooze(request, item_id):
    """POST notif/reminders/<id>/snooze {option: 15m|1h|tomorrow|custom, custom}
    → returns the new fire time. If the id is a real Reminder (reminder:<pk>)
    its due_at is persisted; other sources just echo the computed time (the
    client reschedules its own local notification)."""
    now = timezone.localtime().replace(tzinfo=None)
    # The app sends {preset} | {until}; {option, custom} still accepted.
    option = request.data.get("option") or request.data.get("preset") or ""
    custom = request.data.get("custom") or request.data.get("until")
    if not option and custom:
        option = "custom"
    new_dt = _nc.snooze_until(option, now, custom=custom)
    if new_dt is None:
        return Response({"ok": False, "error": "bad_option"},
                        status=status.HTTP_400_BAD_REQUEST)
    persisted = False
    if str(item_id).startswith("reminder:"):
        try:
            pk = int(str(item_id).split(":", 1)[1])
            r = request.user.reminders.filter(pk=pk).first()
            if r:
                r.due_at = timezone.make_aware(new_dt) if timezone.is_naive(new_dt) else new_dt
                r.done = False
                r.save(update_fields=["due_at", "done", "updated_at"])
                persisted = True
        except (ValueError, IndexError):
            pass
    return Response({"ok": True, "id": item_id, "when": new_dt.isoformat(),
                     "persisted": persisted})


@api_view(["GET"])
def notif_feed(request):
    """GET notif/feed[?type=] — notifications (events that happened). Chat
    excluded; disabled types filtered; newest first."""
    lang = req_lang(request)
    type_filter = request.GET.get("type") or None
    settings_enabled = _notif_settings(request.user)
    events = _collect_events(request.user, lang)
    feed = _nc.build_feed(events, settings_enabled=settings_enabled,
                          type_filter=type_filter)
    from . import b2_badges as B2
    marks = B2.watermarks(request.user)
    return Response({
        "items": feed,
        "unseen": _nc.unseen_count(events, settings_enabled=settings_enabled),
        # b2-badges: Notifications-tab badge + the home bell badge. Items stay
        # unseen (bold) until tapped; SOS / family alerts always count.
        "badge": _nc.badge_count(events, _dt(marks["feed"]),
                                 settings_enabled=settings_enabled),
        "bell_badge": _nc.badge_count(events, _dt(marks["bell"]),
                                      settings_enabled=settings_enabled),
        "types": list(_nc.NOTIF_TYPES),
    })


@api_view(["POST"])
def notif_seen(request, item_id):
    """POST notif/<id>/seen — mark one notification seen. Persists for stored
    NotifEvent rows; family-alert rows are dismissed (their natural 'seen')."""
    sid = str(item_id)
    if sid.startswith("notif:"):
        pk = sid.split(":", 1)[1]
        n = request.user.notif_events.filter(pk=pk).first()
        if n and not n.seen:
            n.seen = True
            n.save(update_fields=["seen"])
        return Response({"ok": True, "id": sid})
    if sid.startswith("familyalert:"):
        pk = sid.split(":", 1)[1]
        request.user.family_alerts.filter(pk=pk).update(dismissed=True)
        return Response({"ok": True, "id": sid})
    return Response({"ok": True, "id": sid})


@api_view(["POST"])
def notif_read_all(request):
    """POST notif/read-all — mark every notification seen. Idempotent."""
    from .models import NotifSettings
    marked = request.user.notif_events.filter(seen=False).update(seen=True)
    request.user.family_alerts.filter(dismissed=False).update(dismissed=True)
    ns, _ = NotifSettings.objects.get_or_create(user=request.user)
    ns.read_all_at = timezone.now()
    ns.save(update_fields=["read_all_at", "updated_at"])
    return Response({"ok": True, "marked": marked})


# ---------------------------------------------------------------- suggestions

def _suggestion_context(user, now):
    """Build the rule-based context dict the suggestion engine scores against.
    Pure gathering — all the judgement lives in the engine."""
    from .logic import medicine as _mlogic
    from decimal import Decimal
    today = now.date()

    # new user: no reminders, no money, no medicine, no circle yet
    has_data = (user.reminders.exists() or user.medicines.exists()
                or user.txns.exists() or user.subscriptions.exists())
    new_user = not has_data

    # missed medicine: a scheduled slot earlier today with no log for it
    missed_medicine = False
    for m in user.medicines.all():
        if m.as_needed:
            continue
        for slot in (m.times or []):
            try:
                h, mn = str(slot).split(":")
            except Exception:
                continue
            slot_t = _time(int(h), int(mn))
            if slot_t <= now.time():
                taken = m.logs.filter(taken_at__date=today).exists() \
                    if hasattr(m, "logs") else False
                if not taken:
                    missed_medicine = True
                    break
        if missed_medicine:
            break

    due_bills = (user.subscriptions.filter(next_due__lte=today).exists()
                 or user.subscriptions.filter(next_due=today).exists())
    recent_spending = user.txns.filter(date__gte=today - timedelta(days=7),
                                       kind="expense").exists()
    unfinished_tasks = user.todos.filter(done=False).exists()

    upcoming_birthday = False
    for b in user.birthdays.all():
        try:
            occ = b.date.replace(year=today.year)
            if occ < today:
                occ = b.date.replace(year=today.year + 1)
            if 0 <= (occ - today).days <= 7:
                upcoming_birthday = True
                break
        except ValueError:
            continue

    active_modules = []
    if hasattr(user, "business"):
        try:
            if user.business:
                active_modules.append("business")
        except Exception:
            pass
    # CRM activity: any meetings/contacts
    if user.meetings.exists() or user.orders.exists():
        if "business" not in active_modules:
            active_modules.append("business")

    season = None  # integrator can wire ramadan/eid calendar; None = off for now

    return {
        "new_user": new_user,
        "missed_medicine": missed_medicine,
        "due_bills": due_bills,
        "recent_spending": recent_spending,
        "unfinished_tasks": unfinished_tasks,
        "upcoming_birthday": upcoming_birthday,
        "active_modules": active_modules,
        "season": season,
    }


def _suggestion_history(user, today):
    from .models import SuggestionState
    st = SuggestionState.objects.filter(user=user).first()
    if not st:
        return {}, None
    served_yesterday = []
    if st.served_date and st.served_date != today:
        served_yesterday = st.served_keys or []
    return {
        "taps": st.taps or {},
        "ignores": st.ignores or {},
        "suppressed": st.suppressed or [],
        "served_yesterday": served_yesterday,
        "current": st.served_keys or [] if st.served_date == today else [],
    }, st


@api_view(["GET"])
def home_suggestions(request):
    """GET home/suggestions?lang=bn|en — the 4 dynamic home prompt cards.
    STRICT language: returns prompts in the requested language only."""
    from .models import SuggestionState
    lang = request.GET.get("lang") or req_lang(request)
    lang = "en" if lang == "en" else "bn"
    now = timezone.localtime().replace(tzinfo=None)
    today = now.date()
    ctx = _suggestion_context(request.user, now)
    hist, st = _suggestion_history(request.user, today)
    from .i18n import is_play_flavour, MEDICAL_SUGGESTION_KEYS
    if is_play_flavour(request):
        # play-nomed: the Play build has no medicine screens — never suggest them.
        hist = dict(hist)
        hist["suppressed"] = list(hist.get("suppressed") or []) + list(MEDICAL_SUGGESTION_KEYS)
    refresh = request.GET.get("refresh") in ("1", "true", "yes")
    prompts = _sg.suggest(lang, now, context=ctx, history=hist, refresh=refresh)

    # record what we served today (for no-repeat-two-days next time)
    keys = [p["key"] for p in prompts]
    if st is None:
        st = SuggestionState.objects.create(user=request.user)
    if st.served_date != today:
        st.served_prev_keys = st.served_keys or []
    st.served_keys = keys
    st.served_date = today
    st.save(update_fields=["served_keys", "served_prev_keys", "served_date", "updated_at"])

    return Response({"lang": lang, "prompts": prompts})


@api_view(["POST"])
def home_suggestions_dismiss(request):
    """POST home/suggestions/dismiss {key} — long-press 'don't show this again'.
    Suppresses the key permanently + records an ignore for learn-from-use."""
    from .models import SuggestionState
    key = request.data.get("key", "")
    if not key:
        return Response({"ok": False, "error": "key_required"},
                        status=status.HTTP_400_BAD_REQUEST)
    st, _ = SuggestionState.objects.get_or_create(user=request.user)
    sup = list(st.suppressed or [])
    if key not in sup:
        sup.append(key)
    st.suppressed = sup
    ign = dict(st.ignores or {})
    ign[key] = ign.get(key, 0) + 1
    st.ignores = ign
    st.save(update_fields=["suppressed", "ignores", "updated_at"])
    return Response({"ok": True, "suppressed": sup})


@api_view(["POST"])
def home_suggestions_tap(request):
    """POST home/suggestions/tap {key} — record a tap so learn-from-use raises
    this prompt type. (Optional companion to dismiss; wired for completeness.)"""
    from .models import SuggestionState
    key = request.data.get("key", "")
    if not key:
        return Response({"ok": False, "error": "key_required"},
                        status=status.HTTP_400_BAD_REQUEST)
    st, _ = SuggestionState.objects.get_or_create(user=request.user)
    taps = dict(st.taps or {})
    taps[key] = taps.get(key, 0) + 1
    st.taps = taps
    st.save(update_fields=["taps", "updated_at"])
    return Response({"ok": True})


@api_view(["GET"])
def home_badges(request):
    """GET home/badges — the two home badge counts:
       my_circle_unread (chat messages) + notif_unseen (notification centre)."""
    settings_enabled = _notif_settings(request.user)
    events = _collect_events(request.user, req_lang(request))
    chat_unread = _chat_unread(request.user)
    out = _nc.badges(chat_unread, events, settings_enabled=settings_enabled)
    # b2-badges: the bell counts only items newer than the last time the
    # centre was opened (POST notif/opened) + every unhandled SOS/family alert.
    from . import b2_badges as B2
    marks = B2.watermarks(request.user)
    out["notif_unseen"] = _nc.badge_count(
        events, _dt(marks["bell"]), settings_enabled=settings_enabled)
    return Response(out)


@api_view(["POST"])
def notif_opened(request):
    """POST notif/opened {scope: bell|feed|reminders | scopes: [...]} — the
    notification centre (default: bell) or one of its tabs was opened: that
    badge clears (watermark = now). Nothing is marked seen; SOS / family
    alerts keep counting until handled."""
    from . import b2_badges as B2
    d = request.data or {}
    scopes = d.get("scopes") or [d.get("scope") or "bell"]
    if isinstance(scopes, str):
        scopes = [scopes]
    scopes = [s for s in scopes if s in B2.SCOPES]
    if not scopes:
        return Response({"ok": False, "error": "bad_scope"},
                        status=status.HTTP_400_BAD_REQUEST)
    at = B2.mark_opened(request.user, scopes)
    return Response({"ok": True, "scopes": scopes, "at": at.isoformat()})


# ---------- #67 Selective sharing (SPEC v2.1 §21) — server-enforced consent ----
# Owner-scoped. Default-deny: nothing is shared until the owner grants it. The
# pure decision/state logic lives in core.logic.family_sharing; these views only
# persist the owner's choices (FamilySharing row) and enforce can_share_item()
# before serializing any shared field. Bilingual via req_lang/pick.
from .models import FamilySharing  # noqa: E402
from .logic import family_sharing as fsh  # noqa: E402

_FAM_AUDIT_CAP = 200


def _fam_sharing_row(user):
    row, _ = FamilySharing.objects.get_or_create(user=user)
    return row


def _fam_members(user):
    """[{id, name, relation, phone}] for the owner's family members."""
    return [
        {"id": m.id, "name": m.name, "relation": m.relation, "phone": m.phone}
        for m in FamilyMember.objects.filter(user=user)
    ]


def _fam_consent_payload(row, user, lang):
    members = _fam_members(user)
    summary = fsh.consent_summary(row.grants, members)
    summary["item_labels"] = {
        i: fsh.item_label(i, lang) for i in fsh.SHAREABLE_ITEMS
    }
    return summary


class FamilySharingConsentView(APIView):
    """GET family/sharing/consent — the consent screen model (per-member,
    per-item grid) built from the owner's grants + family members."""
    def get(self, request):
        row = _fam_sharing_row(request.user)
        return Response(_fam_consent_payload(row, request.user, req_lang(request)))


class FamilySharingGrantView(APIView):
    """POST family/sharing/grant {member_id, item, on} — grant/revoke one item
    for one member, append an audit entry, return the fresh consent model."""
    def post(self, request):
        data = request.data or {}
        member_id = data.get("member_id")
        item = data.get("item")
        on = bool(data.get("on", True))
        if not fsh.is_shareable_item(item):
            return Response({"detail": "unknown item"},
                            status=status.HTTP_400_BAD_REQUEST)
        row = _fam_sharing_row(request.user)
        row.grants = fsh.set_grant(row.grants, member_id, item, on=on)
        # JSON can't store sets/int keys — serialize to {str: [sorted items]}.
        row.grants = {str(k): sorted(v) for k, v in
                      fsh.normalize_grants(row.grants).items()}
        name = ""
        for m in _fam_members(request.user):
            if str(m["id"]) == str(member_id):
                name = m["name"]
                break
        entry = fsh.build_audit_entry(
            fsh.AUDIT_GRANT if on else fsh.AUDIT_REVOKE,
            member_id=member_id, item=item, member_name=name,
            actor_id=request.user.id)
        row.audit = ([entry] + list(row.audit or []))[:_FAM_AUDIT_CAP]
        row.save()
        log(request.user, "family.sharing.grant",
            member_id=member_id, item=item, on=on)
        return Response(_fam_consent_payload(row, request.user, req_lang(request)))


class FamilySharingRevokeMemberView(APIView):
    """POST family/sharing/revoke-member {member_id} — revoke all for a member."""
    def post(self, request):
        member_id = (request.data or {}).get("member_id")
        row = _fam_sharing_row(request.user)
        row.grants = {str(k): sorted(v) for k, v in
                      fsh.normalize_grants(
                          fsh.revoke_member(row.grants, member_id)).items()}
        name = ""
        for m in _fam_members(request.user):
            if str(m["id"]) == str(member_id):
                name = m["name"]
                break
        entry = fsh.build_audit_entry(
            fsh.AUDIT_REVOKE_MEMBER, member_id=member_id, member_name=name,
            actor_id=request.user.id)
        row.audit = ([entry] + list(row.audit or []))[:_FAM_AUDIT_CAP]
        row.save()
        log(request.user, "family.sharing.revoke_member", member_id=member_id)
        return Response(_fam_consent_payload(row, request.user, req_lang(request)))


class FamilySharingRevokeAllView(APIView):
    """POST family/sharing/revoke-all — revoke everything from everyone."""
    def post(self, request):
        row = _fam_sharing_row(request.user)
        row.grants = {}
        entry = fsh.build_audit_entry(fsh.AUDIT_REVOKE_ALL,
                                      actor_id=request.user.id)
        row.audit = ([entry] + list(row.audit or []))[:_FAM_AUDIT_CAP]
        row.save()
        log(request.user, "family.sharing.revoke_all")
        return Response(_fam_consent_payload(row, request.user, req_lang(request)))


class FamilySharingAuditView(APIView):
    """GET family/sharing/audit — the persisted audit log (newest first)."""
    def get(self, request):
        row = _fam_sharing_row(request.user)
        return Response({"entries": list(row.audit or [])})


class FamilySharedItemView(APIView):
    """GET family/shared/<member_id>/<item> — server-enforced read. MUST call
    can_share_item() BEFORE loading/returning the field; default-deny on false."""
    def get(self, request, member_id, item):
        row = _fam_sharing_row(request.user)
        if not fsh.can_share_item(row.grants, member_id, item):
            return Response({"detail": "not shared", "shared": False},
                            status=status.HTTP_403_FORBIDDEN)
        # The owner has granted this item to this member; a real integration
        # resolves the concrete field here. We confirm the grant (default-deny
        # already enforced) without fabricating data.
        return Response({"shared": True, "member_id": int(member_id),
                         "item": item})
