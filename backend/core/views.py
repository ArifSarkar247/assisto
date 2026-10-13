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
                     Account, Transaction, Budget, Loan, SavingsGoal, Subscription,
                     NightBriefing, WaitlistEntry)
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
        from . import plans
        plans.start_trial(user)   # 7-day full trial for new users
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
            lang = req_lang(request)
            return Response({"detail": pick(lang, "ভুল তথ্য। আবার চেষ্টা করুন।",
                                            "Those details didn't match. Please try again.")},
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
            lang = req_lang(request)
            return Response(
                {"detail": pick(lang,
                                "OTP এখন বন্ধ — SMS প্রোভাইডার যুক্ত করা হয়নি। "
                                "ফোন/ইমেইল ও পাসওয়ার্ড দিয়ে লগইন করুন।",
                                "OTP is off for now — no SMS provider is set up yet. "
                                "Sign in with your phone/email and password."),
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
            slot = "prn-" + timezone.localtime().strftime("%H:%M:%S")

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
                         "stock_count": str(med.stock_count)
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
        from . import integrations as _ig
        try:
            push_ready = _ig.is_enabled("firebase")
        except Exception:
            push_ready = False
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
    """Feature 13 — in-app scam checker (rule-based; reuses the web logic)."""
    def post(self, request):
        from web.logic import scam as scamlogic
        msg = request.data.get("message", "")
        if not msg.strip():
            lang = req_lang(request)
            return Response({"detail": pick(lang, "মেসেজ দিন।", "Please enter a message.")}, status=400)
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


# ---------- briefing / proactive alerts (feature 4, 5 — non-AI works now) ----------

def _build_alerts(user, lang="bn"):
    from datetime import timedelta
    from django.db.models import Sum
    from decimal import Decimal
    today = timezone.localdate()
    alerts = []
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
    lang = req_lang(request)
    u = request.user
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
    return Response({"text": text, "lines": lines, "ai_text": ai_text,
                     "alerts": al, "ai_enabled": ai.key_present()})


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
        import secrets as _s
        lang = req_lang(request)
        u = request.user
        if not u.referral_code:
            u.referral_code = _s.token_urlsafe(5).replace("_", "").replace("-", "")[:8].upper()
            u.save(update_fields=["referral_code"])
        invited = User.objects.filter(referred_by=u.referral_code).count()
        return Response({"code": u.referral_code, "invited": invited,
                         "share_text": pick(lang,
                                            f"Assisto অ্যাপে আমার রেফারেল কোড: {u.referral_code} — "
                                            "assisto.asalify.com/get",
                                            f"My Assisto referral code: {u.referral_code} — "
                                            "assisto.asalify.com/get")})


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
        intent = p.get("intent")
        cards = []
        reply = ""

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
            t = Transaction.objects.create(user=u, account=acc, kind=intent,
                amount=Decimal(p["amount"]), category=p.get("category", ""),
                date=timezone.localdate(), source="ai")
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
            b = briefing(request).data
            reply = b["text"]
        else:
            reply = pick(lang,
                         "বুঝতে পারিনি। যেমন বলুন: 'কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও' বা '৫০০ টাকা খরচ খাবার'।",
                         "I didn't catch that. Try: 'remind me to take my medicine at 8am tomorrow' or '500 taka spent on food'.")

        # Optional AI enrichment (never required)
        ai_used = False
        return Response({"reply": reply, "cards": cards, "intent": intent,
                         "ai_used": ai_used, "ai_enabled": ai.key_present()})


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
        ok, remaining = plans.reward_ad(request.user)
        log(request.user, "credit.rewarded", granted=ok)
        return Response({"ok": ok, "remaining_today": remaining,
                         "credits": request.user.ai_credits})


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


# ---------- Nominee / family access (feature 36) ----------
class NomineeViewSet(OwnedViewSet):
    from .models import Nominee as _M
    from .serializers import NomineeSerializer as _S
    model = _M; kind = "nominee"; serializer_class = _S


@api_view(["POST"])
def nominee_activate(request, pk):
    """Owner explicitly opens nominee access (e.g. during an emergency). Scoped,
    audit-logged, reversible — never silent."""
    from .models import Nominee
    n = Nominee.objects.filter(user=request.user, pk=pk).first()
    if not n:
        return Response({"detail": "not found"}, status=404)
    n.activated = bool(request.data.get("activated", True))
    n.activated_at = timezone.now() if n.activated else None
    n.save(update_fields=["activated", "activated_at"])
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
