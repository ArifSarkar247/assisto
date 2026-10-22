from django.db import models
from django.contrib.auth.models import (
    AbstractBaseUser, PermissionsMixin, BaseUserManager,
)
from django.utils import timezone


class UserManager(BaseUserManager):
    def _normalize(self, phone, email):
        phone = (phone or "").strip() or None
        if phone:  # c1-contacts: canonical form when parseable
            from .phone import canonical_phone
            phone = canonical_phone(phone) or phone
        email = self.normalize_email(email).strip().lower() if email else None
        return phone, email

    def create_user(self, name="", phone=None, email=None, password=None, **extra):
        phone, email = self._normalize(phone, email)
        if not phone and not email:
            raise ValueError("A phone number or email is required.")
        user = self.model(name=name or "", phone=phone, email=email, **extra)
        user.username = phone or email
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, name="", phone=None, email=None, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        return self.create_user(name, phone, email, password, **extra)


class User(AbstractBaseUser, PermissionsMixin):
    """Login by phone OR email + password. OTP is designed (see OTPCode) but
    stays off until an SMS provider is configured (settings.SMS_ENABLED)."""

    # Autonomy dial (spec design principle #1): how much the AI may do on its own.
    AUTONOMY_ASK = 1          # only remind / ask
    AUTONOMY_SUGGEST = 2      # suggest actions, user taps to run (default)
    AUTONOMY_APPROVE = 3      # prepare action, run after one approval
    AUTONOMY_AUTO = 4         # auto for this exact case (never money/external without prior opt-in)
    AUTONOMY_CHOICES = [
        (AUTONOMY_ASK, "ask"),
        (AUTONOMY_SUGGEST, "suggest"),
        (AUTONOMY_APPROVE, "approve"),
        (AUTONOMY_AUTO, "auto"),
    ]

    username = models.CharField(max_length=190, unique=True)  # = phone or email at signup
    name = models.CharField(max_length=120, blank=True)
    phone = models.CharField(max_length=24, unique=True, null=True, blank=True)
    email = models.EmailField(unique=True, null=True, blank=True)

    autonomy_level = models.PositiveSmallIntegerField(
        choices=AUTONOMY_CHOICES, default=AUTONOMY_SUGGEST)
    language = models.CharField(max_length=8, default="bn")
    referral_code = models.CharField(max_length=12, blank=True)   # feature 19 invite
    referred_by = models.CharField(max_length=12, blank=True)

    # --- monetization (P3) ---
    plan = models.CharField(max_length=16, default="free")        # see plans.PLANS
    plan_until = models.DateTimeField(null=True, blank=True)      # paid plan expiry
    trial_until = models.DateTimeField(null=True, blank=True)     # 7-day full trial
    is_founder = models.BooleanField(default=False)
    ai_credits = models.IntegerField(default=0)                  # consumable AI credits
    elderly_mode = models.BooleanField(default=False)            # feature 29 simple mode
    # accident/fall detection (owner-configurable; OFF by default)
    fall_detect = models.BooleanField(default=False)
    fall_countdown_sec = models.PositiveIntegerField(default=120)  # 30–600s, default 2 min

    is_active = models.BooleanField(default=True)
    is_staff = models.BooleanField(default=False)
    date_joined = models.DateTimeField(default=timezone.now)

    # --- avatar (Step 3 Messenger). Needed by circle cards + messenger profile +
    # community member cards + the admin user projection (public field only).
    # Either an uploaded image OR an external URL (photo_link); photo_url picks
    # whichever is set so the existing circle _resolve_peer keeps working. ---
    photo = models.ImageField(upload_to="avatars/", null=True, blank=True)
    photo_link = models.URLField(blank=True, default="")   # external avatar URL

    # --- Messenger communities privacy/consent settings (msg_community). ---
    # show_phone: opt-in to reveal my number on community member cards (default OFF).
    # communities_who_can_msg: who may start a chat with me across communities.
    show_phone = models.BooleanField(default=False)
    communities_who_can_msg = models.CharField(max_length=10, default="everyone")  # everyone|nobody

    # --- Moderation / owner-admin PUBLIC fields (msg_moderation). These are the
    # ONLY account-status fields the admin user projection exposes; message
    # contents + contacts are NEVER surfaced (admin_user_projection allow-list). ---
    account_status = models.CharField(max_length=10, default="active")  # active|suspended|banned
    report_count = models.PositiveIntegerField(default=0)
    app_version = models.CharField(max_length=24, blank=True, default="")
    last_active = models.DateTimeField(null=True, blank=True)

    # --- Owner switch for PUBLIC surfaces (channels/communities). Spec line 22
    # deferred these "owner decision later"; they ship behind this flag, which
    # only the platform owner (superuser) may flip ON for approved test accounts.
    # Default OFF — a normal account cannot create public channels/communities. ---
    public_surfaces_enabled = models.BooleanField(default=False)

    objects = UserManager()

    USERNAME_FIELD = "username"
    REQUIRED_FIELDS = []

    @property
    def photo_url(self):
        """Resolve a display URL for this user's avatar (uploaded file first,
        else the external link). Safe to read even with no request context."""
        if self.photo:
            try:
                return self.photo.url
            except Exception:
                return ""
        return self.photo_link or ""

    def __str__(self):
        return self.name or self.username


class OTPCode(models.Model):
    """Designed for later SMS/email OTP. Not sent while SMS_ENABLED is False."""
    PURPOSE_CHOICES = [("signup", "signup"), ("login", "login"), ("reset", "reset")]
    identifier = models.CharField(max_length=190)  # phone or email the code is for
    code = models.CharField(max_length=8)
    purpose = models.CharField(max_length=12, choices=PURPOSE_CHOICES)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    used = models.BooleanField(default=False)

    class Meta:
        indexes = [models.Index(fields=["identifier", "purpose", "used"])]


class MemoryItem(models.Model):
    """'AI কী জানে' page. Every item is editable and deletable by the user.
    source marks whether the AI captured it or the user wrote it (design #1)."""
    SOURCE_AI = "ai"
    SOURCE_MANUAL = "manual"
    SOURCE_CHOICES = [(SOURCE_AI, "AI ধরেছে"), (SOURCE_MANUAL, "নিজে লিখেছেন")]

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="memories")
    category = models.CharField(max_length=60, blank=True)   # e.g. পরিবার, কাজ, স্বাস্থ্য
    title = models.CharField(max_length=200)
    detail = models.TextField(blank=True)
    source = models.CharField(max_length=8, choices=SOURCE_CHOICES, default=SOURCE_MANUAL)
    confidence = models.FloatField(null=True, blank=True)    # for AI-captured items
    needs_review = models.BooleanField(default=False)        # low-confidence → review queue
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]


class AuditLog(models.Model):
    """'এজেন্ট কী করেছে' — every action/notification/change the AI or app took.
    Nothing external happens without the user; this makes it visible (design #2)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="audit")
    action = models.CharField(max_length=80)                 # e.g. memory.create, account.export
    detail = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class PendingAction(models.Model):
    """Action Center (SPEC v2.1 §21, feature #9) — an action the AI has PREPARED
    and is holding for the user's approval under autonomy level 3 ("do it with
    approval"). It is NEVER executed until approved; rejecting discards it, and
    approving it writes an AuditLog row exactly as a direct action would.

    AUTONOMY SEAM (where the queue gets populated — the AI itself is NOT built
    here; this only models the hand-off): anywhere the agent is about to take a
    non-trivial action it branches on `user.autonomy_level` —
      1 remind-only  -> don't act, just remind.
      2 suggest      -> surface a tappable suggestion (current behaviour).
      3 approve      -> create a PendingAction(kind=<audit action key>,
                        payload=<how to run it>) instead of running; it appears
                        in the Action Center WAITING tab.
      4 auto         -> run now + log(...) (never money/external without a prior
                        per-case opt-in).
    Approving merges any user edit into `payload`, marks the row done, and logs
    the matching AuditLog action so the DONE tab / audit trail stays truthful."""
    PENDING, APPROVED, REJECTED, DONE = "pending", "approved", "rejected", "done"
    STATUS_CHOICES = [(PENDING, "pending"), (APPROVED, "approved"),
                      (REJECTED, "rejected"), (DONE, "done")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="pending_actions")
    # Dotted action key, SAME vocabulary as AuditLog.action (e.g. agent.reminder,
    # message.send). The app parses module/icon/label from it; serialised as
    # `action` to the client.
    kind = models.CharField(max_length=80)
    module = models.CharField(max_length=24, blank=True)
    title = models.CharField(max_length=200)
    summary = models.TextField(blank=True)            # e.g. drafted message body
    autonomy_level = models.PositiveSmallIntegerField(default=3)
    payload = models.JSONField(default=dict, blank=True)   # how to run it
    status = models.CharField(max_length=9, choices=STATUS_CHOICES,
                              default=PENDING)
    created_at = models.DateTimeField(auto_now_add=True)
    acted_at = models.DateTimeField(null=True, blank=True)  # approved/rejected at

    class Meta:
        ordering = ["-created_at"]


class Reminder(models.Model):
    """Feature 3 — reminders / alarms / calendar, incl. recurring."""
    REC_NONE, REC_DAILY, REC_WEEKLY, REC_MONTHLY, REC_YEARLY = (
        "none", "daily", "weekly", "monthly", "yearly")
    REC_CHOICES = [(REC_NONE, "একবার"), (REC_DAILY, "প্রতিদিন"), (REC_WEEKLY, "সাপ্তাহিক"),
                   (REC_MONTHLY, "মাসিক"), (REC_YEARLY, "বার্ষিক")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="reminders")
    title = models.CharField(max_length=200)
    notes = models.TextField(blank=True)
    due_at = models.DateTimeField(null=True, blank=True)
    recurrence = models.CharField(max_length=10, choices=REC_CHOICES, default=REC_NONE)
    # Rich recurrence rule from the NL parser (interval/weekday/day-of-month/anchor).
    # Coexists with the simple `recurrence` enum above for back-compat.
    recurrence_rule = models.JSONField(default=dict, blank=True)
    date_only = models.BooleanField(default=False)   # all-day (no specific time)
    link = models.JSONField(default=dict, blank=True)  # linked entity {type,id,label}
    remind_before_min = models.IntegerField(default=0)
    done = models.BooleanField(default=False)
    source = models.CharField(max_length=8, default="manual")   # manual | ai
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["due_at", "-updated_at"]


class Note(models.Model):
    """Feature 3 — notes."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="notes")
    title = models.CharField(max_length=200, blank=True)
    body = models.TextField(blank=True)
    pinned = models.BooleanField(default=False)
    source = models.CharField(max_length=8, default="manual")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-pinned", "-updated_at"]


class Todo(models.Model):
    """Feature 3 — to-do list."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="todos")
    title = models.CharField(max_length=200)
    done = models.BooleanField(default=False)
    due_at = models.DateTimeField(null=True, blank=True)
    source = models.CharField(max_length=8, default="manual")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["done", "-updated_at"]


class FamilyMember(models.Model):
    """Feature 12 — family members (for medicine schedules, sharing)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="family")
    name = models.CharField(max_length=80)
    relation = models.CharField(max_length=40, blank=True)
    phone = models.CharField(max_length=24, blank=True)
    notes = models.CharField(max_length=200, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]


class Doctor(models.Model):
    """A prescribing doctor — lets us group prescriptions into a timeline."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="doctors")
    name = models.CharField(max_length=120)
    specialty = models.CharField(max_length=120, blank=True, default="")
    hospital = models.CharField(max_length=160, blank=True, default="")
    phone = models.CharField(max_length=40, blank=True, default="")
    notes = models.CharField(max_length=300, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]


class Prescription(models.Model):
    """A visit's prescription (feature 12) — doctor + date + the medicines
    advised. Builds a per-doctor history timeline and feeds the doctor-visit
    PDF summary. Medicines created from it can back-link via Medicine.prescription."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="prescriptions")
    member = models.ForeignKey("FamilyMember", on_delete=models.CASCADE, null=True,
                               blank=True, related_name="prescriptions")
    doctor = models.ForeignKey(Doctor, on_delete=models.SET_NULL, null=True, blank=True,
                               related_name="prescriptions")
    doctor_name = models.CharField(max_length=120, blank=True, default="")  # free-text fallback
    date = models.DateField(null=True, blank=True)
    diagnosis = models.CharField(max_length=300, blank=True, default="")
    # meds advised: [{name, dosage, times:[..], days}]
    meds = models.JSONField(default=list, blank=True)
    notes = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-date", "-created_at"]


class Medicine(models.Model):
    """Feature 12 — medicine schedule (self or a family member)."""
    # Dose relative to food (খাওয়ার আগে/পরে) — Bangladeshi caregivers rely on this.
    FOOD_ANY, FOOD_BEFORE, FOOD_AFTER, FOOD_WITH = "any", "before", "after", "with"
    FOOD_CHOICES = [(FOOD_ANY, "any"), (FOOD_BEFORE, "before food"),
                    (FOOD_AFTER, "after food"), (FOOD_WITH, "with food")]

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="medicines")
    member = models.ForeignKey(FamilyMember, on_delete=models.CASCADE, null=True, blank=True,
                               related_name="medicines")
    prescription = models.ForeignKey(Prescription, on_delete=models.SET_NULL, null=True,
                                     blank=True, related_name="medicines")
    name = models.CharField(max_length=120)
    dosage = models.CharField(max_length=80, blank=True)
    times = models.JSONField(default=list, blank=True)   # ["08:00","20:00"]
    start_date = models.DateField(null=True, blank=True)
    end_date = models.DateField(null=True, blank=True)
    refill_date = models.DateField(null=True, blank=True)
    notes = models.CharField(max_length=200, blank=True)

    # --- dose semantics (advanced) ---
    food_relation = models.CharField(max_length=8, choices=FOOD_CHOICES, default=FOOD_ANY)
    dose_qty = models.DecimalField(max_digits=6, decimal_places=2, default=1)  # units per dose
    as_needed = models.BooleanField(default=False)   # PRN — never counts against adherence
    # Typical PRN doses/day — only used to estimate PRN burn for refill prediction
    # (PRN never affects adherence). 0 → no stock prediction for a PRN med.
    prn_per_day = models.PositiveIntegerField(default=0)
    duration_days = models.PositiveIntegerField(null=True, blank=True)  # "for 7 days"
    taper = models.JSONField(default=list, blank=True)  # [{from, to, dose_qty}] tapering plan

    # --- inventory ---
    # DecimalField (not Integer) so fractional doses (0.5 pill) decrement stock
    # correctly — see logic.medicine.apply_dose_to_stock (P6).
    stock_count = models.DecimalField(max_digits=8, decimal_places=2,
                                      null=True, blank=True)  # units on hand (pills)
    refill_warn_days = models.PositiveIntegerField(default=5)  # warn when <= N days left

    # configurable follow-up (per medicine / per member) — applies to app
    # notifications now, and to IVR calls when that integration exists.
    followup_repeat_min = models.PositiveIntegerField(default=15)  # re-remind after N min
    followup_retries = models.PositiveIntegerField(default=2)      # how many re-reminds
    caregiver_alert_min = models.PositiveIntegerField(default=30)  # alert child after M min
    quiet_start = models.CharField(max_length=5, blank=True, default="")  # "22:00"
    quiet_end = models.CharField(max_length=5, blank=True, default="")    # "07:00"
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]


class MedicineLog(models.Model):
    """Per-dose outcome. `taken=False` + a row means an explicitly-skipped dose;
    absence of a row for a scheduled slot means 'missed' (not yet acted on)."""
    medicine = models.ForeignKey(Medicine, on_delete=models.CASCADE, related_name="logs")
    date = models.DateField()
    # "08:00" for a scheduled slot; for an as-needed (PRN) med each event is
    # logged as "prn-HH:MM:SS" so a painkiller can be logged many times/day
    # (unique_together stays per-slot, but each PRN event has its own slot). (P4)
    slot = models.CharField(max_length=12)
    taken = models.BooleanField(default=True)
    skipped = models.BooleanField(default=False)   # user chose to skip (not a miss)
    at = models.DateTimeField(null=True, blank=True)  # when actually taken
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("medicine", "date", "slot")]


class SchoolItem(models.Model):
    """Feature 15 — child's school fees / exams / meetings."""
    KIND = [("fee", "ফি"), ("exam", "পরীক্ষা"), ("meeting", "মিটিং")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="school_items")
    child_name = models.CharField(max_length=80, blank=True)
    kind = models.CharField(max_length=8, choices=KIND, default="fee")
    title = models.CharField(max_length=160)
    date = models.DateField(null=True, blank=True)
    amount = models.DecimalField(max_digits=12, decimal_places=2, null=True, blank=True)
    done = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["done", "date"]


class Account(models.Model):
    """Feature 7 — money accounts. Never store any bank/bKash PIN or password."""
    TYPES = [("cash", "ক্যাশ"), ("bkash", "বিকাশ"), ("nagad", "নগদ"), ("rocket", "রকেট"),
             ("bank", "ব্যাংক"), ("card", "কার্ড")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="accounts")
    name = models.CharField(max_length=80)
    acc_type = models.CharField(max_length=10, choices=TYPES, default="cash")
    opening_balance = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]


class Transaction(models.Model):
    """Feature 7/8 — income / expense / transfer."""
    INCOME, EXPENSE, TRANSFER = "income", "expense", "transfer"
    KIND = [(INCOME, "আয়"), (EXPENSE, "খরচ"), (TRANSFER, "ট্রান্সফার")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="txns")
    account = models.ForeignKey(Account, on_delete=models.CASCADE, related_name="txns")
    to_account = models.ForeignKey(Account, on_delete=models.SET_NULL, null=True, blank=True,
                                   related_name="txns_in")
    kind = models.CharField(max_length=10, choices=KIND, default=EXPENSE)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    category = models.CharField(max_length=60, blank=True)
    note = models.CharField(max_length=200, blank=True)
    date = models.DateField()
    source = models.CharField(max_length=12, default="manual")  # manual|ai|notification
    ref = models.CharField(max_length=40, blank=True)       # wallet TrxID (dedupe)
    split_with = models.JSONField(default=list, blank=True)
    split_mode = models.CharField(max_length=10, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-date", "-created_at"]


class Budget(models.Model):
    """Feature 8 — monthly budget per category, 80%/100% warnings."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="budgets")
    category = models.CharField(max_length=60)
    monthly_limit = models.DecimalField(max_digits=14, decimal_places=2)
    rollover = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "category")]


class Loan(models.Model):
    """Feature 9 — loans given / taken."""
    GIVEN, TAKEN = "given", "taken"
    KIND = [(GIVEN, "আমি দিয়েছি"), (TAKEN, "আমি নিয়েছি")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="loans")
    kind = models.CharField(max_length=6, choices=KIND, default=GIVEN)
    person = models.CharField(max_length=80)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    date = models.DateField(null=True, blank=True)
    due_date = models.DateField(null=True, blank=True)
    settled = models.BooleanField(default=False)
    note = models.CharField(max_length=200, blank=True)
    repayments = models.JSONField(default=list, blank=True)  # [{"amount","date"}]
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["settled", "-updated_at"]


class SavingsGoal(models.Model):
    """Feature 10 — savings goals."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="goals")
    title = models.CharField(max_length=120)
    target_amount = models.DecimalField(max_digits=14, decimal_places=2)
    saved_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    due_date = models.DateField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]


class Subscription(models.Model):
    """Feature 10 — recurring subscriptions.

    `cycle` widened to 16 chars so the advanced UI's full words
    (weekly|monthly|quarterly|yearly|custom) round-trip without truncation.
    `details` is a JSON map for the richer fields the advanced sheet collects
    (category, payment_method, trial_end, auto_renew, notes, icon, colour,
    status pause/cancel, custom_days, last_used …). Kept nullable/default so
    existing rows stay valid with no data migration — see the pure engine
    core.logic.subscriptions and .phaseB/up_subs_integration.md."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="subscriptions")
    name = models.CharField(max_length=80)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    cycle = models.CharField(max_length=16, default="monthly")  # weekly|monthly|quarterly|yearly|custom
    next_due = models.DateField(null=True, blank=True)
    # Richer advanced-UI fields, kept as a real JSON map so values survive intact.
    details = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["next_due"]


class Document(models.Model):
    """Feature 6 — document vault. Files are owner-only (served via an
    auth-checked view, never public). PIN/biometric gate is client-side."""
    TYPES = [("passport", "পাসপোর্ট"), ("nid", "NID"), ("licence", "ড্রাইভিং লাইসেন্স"),
             ("certificate", "সার্টিফিকেট"), ("other", "অন্যান্য")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="documents")
    title = models.CharField(max_length=200)
    doc_type = models.CharField(max_length=16, choices=TYPES, default="other")
    file = models.FileField(upload_to="vault/", null=True, blank=True)
    expiry_date = models.DateField(null=True, blank=True)
    note = models.CharField(max_length=300, blank=True)
    # Type-specific structured fields (e.g. passport number, policy no.) kept as a
    # real JSON map so values with ; | = are never corrupted (vault P1 fix).
    details = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["expiry_date", "-updated_at"]


class EmergencyCard(models.Model):
    """Feature 14 — emergency card (blood group, meds, allergies, contacts)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="emergency")
    blood_group = models.CharField(max_length=8, blank=True)
    allergies = models.TextField(blank=True)
    medicines = models.TextField(blank=True)
    conditions = models.TextField(blank=True)
    notes = models.TextField(blank=True)
    contacts = models.JSONField(default=list, blank=True)  # [{name, phone, relation}]
    # Advanced emergency-card extras the printable card collects: name, doctor,
    # insurance, nid_ref (reference string only — treat as sensitive, never
    # index/log), organ_donor (bool). Nullable/default so existing rows are safe.
    card = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class SourcePermission(models.Model):
    """Feature 20 — per-source capture permission (each source switchable)."""
    SOURCES = [("photo", "ছবি"), ("share", "শেয়ার/ফরোয়ার্ড"), ("voice", "বাংলা ভয়েস"),
               ("notification", "নোটিফিকেশন (bKash/ব্যাংক)")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="source_perms")
    source = models.CharField(max_length=16)
    enabled = models.BooleanField(default=True)

    class Meta:
        unique_together = [("user", "source")]


class SupportTicket(models.Model):
    """Feature 21 — in-app support chat + bug report (with optional screenshot)."""
    KIND = [("support", "সাহায্য"), ("bug", "সমস্যা রিপোর্ট")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="tickets")
    kind = models.CharField(max_length=10, choices=KIND, default="support")
    message = models.TextField()
    screenshot = models.ImageField(upload_to="support/", null=True, blank=True)
    app_version = models.CharField(max_length=24, blank=True)
    resolved = models.BooleanField(default=False)
    reply = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class AIUsage(models.Model):
    """Every AI call logged for cost tracking + daily budget kill-switch."""
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="ai_usage")
    feature = models.CharField(max_length=40)
    model = models.CharField(max_length=40)
    input_tokens = models.IntegerField(default=0)
    output_tokens = models.IntegerField(default=0)
    cost_usd = models.FloatField(default=0.0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["created_at"])]


class ToolUsage(models.Model):
    """Step A viral web tools — per-tool usage + cost (per hashed IP)."""
    tool = models.CharField(max_length=8)        # w1..w4
    ip_hash = models.CharField(max_length=64, blank=True)
    used_ai = models.BooleanField(default=False)
    cost_usd = models.FloatField(default=0.0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["tool", "created_at"]),
                   models.Index(fields=["ip_hash", "created_at"])]


class Device(models.Model):
    """For later push notifications (FCM). Stored per user."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="devices")
    push_token = models.CharField(max_length=255, blank=True)
    platform = models.CharField(max_length=16, default="android")
    app_version = models.CharField(max_length=24, blank=True)
    last_seen = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "push_token")]


class Integration(models.Model):
    """Owner-configured external integration (AI/Maps/Billing/WhatsApp/...).

    Credentials are stored ENCRYPTED (Fernet) in `enc_blob`; raw values are
    never returned to the client. A feature switches on automatically once its
    integration's status is 'working'.
    """
    STATUS = [("not_set", "not_set"), ("working", "working"), ("failing", "failing")]
    slug = models.CharField(max_length=40, unique=True)
    enc_blob = models.TextField(blank=True, default="")   # Fernet(JSON) of fields
    status = models.CharField(max_length=10, choices=STATUS, default="not_set")
    detail = models.CharField(max_length=300, blank=True, default="")  # last test msg
    last_tested = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"{self.slug} [{self.status}]"


class BillTemplate(models.Model):
    """Cached parse of a biller's bill layout so the SECOND scan of the same
    biller needs no AI. Keyed per user + biller."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="bill_templates")
    biller = models.CharField(max_length=80)                 # e.g. 'DPDC', 'WASA'
    fields = models.JSONField(default=dict, blank=True)      # company/account/meter/where/last_date...
    uses = models.PositiveIntegerField(default=1)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "biller")]


class NightBriefing(models.Model):
    """Batch-generated-at-night briefing so the morning open is instant + cheap
    (no live AI call at peak)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="night_briefings")
    for_date = models.DateField()
    text = models.TextField(blank=True, default="")
    ai_used = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "for_date")]
        ordering = ["-for_date"]


class Nominee(models.Model):
    """Nominee / family access (feature 36). A trusted person who can access
    specified data if the owner is inactive for N days or declares an emergency.
    Access is explicit, scoped, and audit-logged — never silent."""
    SCOPES = [("emergency", "emergency card"), ("vault", "document vault"),
              ("money", "money overview"), ("all", "all")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="nominees")
    name = models.CharField(max_length=120)
    contact = models.CharField(max_length=120)        # phone/email of nominee
    scope = models.CharField(max_length=12, choices=SCOPES, default="emergency")
    inactivity_days = models.PositiveIntegerField(default=30)
    activated = models.BooleanField(default=False)    # access currently open
    activated_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    # --- advanced flow (feature 36 upgrade). Enum values live in
    #     core.logic.nominee (SCOPES/RELATIONSHIPS/TRIGGERS/STATE_*) — never
    #     duplicated here. All additive + defaulted so existing rows stay valid.
    #
    # `scopes` is the multi-category replacement for single `scope` (kept as a
    # back-compat mirror = 'all' or the first category).
    scopes = models.JSONField(default=list, blank=True)        # subset of nominee.SCOPES
    relationship = models.CharField(max_length=16, default="family")  # RELATIONSHIPS
    priority = models.PositiveIntegerField(default=1)                 # fallback order
    trigger = models.CharField(max_length=16, default="owner_grant")  # TRIGGERS

    # grace-window release lifecycle — SERVER-AUTHORITATIVE, read-only to clients.
    release_state = models.CharField(max_length=10, default="armed")  # armed|pending|open
    release_pending = models.BooleanField(default=False)              # UI convenience mirror
    release_requested_at = models.DateTimeField(null=True, blank=True)
    grace_hours = models.PositiveIntegerField(default=48)
    # multi_verify quorum
    multi_verify_ids = models.JSONField(default=list, blank=True)       # user/circle ids
    multi_verify_quorum = models.PositiveIntegerField(default=2)
    release_confirmations = models.JSONField(default=list, blank=True)  # ids who confirmed

    class Meta:
        indexes = [models.Index(fields=["user", "priority"])]


class JobApplication(models.Model):
    """Job hunter agent (feature 37). Tracks matched jobs, tailored docs, and
    follow-ups. NEVER auto-applies (esp. Bdjobs/LinkedIn) — the user approves
    and sends from their own Gmail."""
    STATUS = [("matched", "matched"), ("drafted", "drafted"), ("applied", "applied"),
              ("followup", "follow-up due"), ("replied", "replied"), ("closed", "closed")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="job_apps")
    title = models.CharField(max_length=160)
    company = models.CharField(max_length=160, blank=True, default="")
    source = models.CharField(max_length=40, blank=True, default="")
    jd = models.TextField(blank=True, default="")              # job description (input)
    match_score = models.PositiveSmallIntegerField(default=0)  # 0-100, computed
    match_reason = models.CharField(max_length=300, blank=True, default="")
    cv_text = models.TextField(blank=True, default="")
    cover_letter = models.TextField(blank=True, default="")
    status = models.CharField(max_length=12, choices=STATUS, default="matched")
    applied_at = models.DateTimeField(null=True, blank=True)
    followup_at = models.DateField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-match_score", "-created_at"]


class CreditLedger(models.Model):
    """Every AI-credit change (monthly grant, consume, rewarded-ad, top-up).
    User.ai_credits is the running balance; this is the audit trail."""
    REASONS = [("grant", "monthly grant"), ("consume", "consume"),
               ("rewarded", "rewarded ad"), ("topup", "top-up"),
               ("trial", "trial"), ("adjust", "adjust"),
               # Business Model Build 2 — unified audit trail for ad wallet +
               # expiry; purchased/pack credits land as "topup".
               ("ad_appopen", "ad: app open"),
               ("ad_interstitial", "ad: interstitial"),
               ("ad_spend", "spent ad-wallet credits"),
               ("expire", "credits expired")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="credit_ledger")
    delta = models.IntegerField()               # +grant / -consume
    reason = models.CharField(max_length=20, choices=REASONS)
    note = models.CharField(max_length=120, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class WaitlistEntry(models.Model):
    """Viral-spike invite/waitlist gate. Approved entries may register."""
    contact = models.CharField(max_length=120, unique=True)   # phone or email
    invite_code = models.CharField(max_length=12, blank=True, default="")
    approved = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)


class Watcher(models.Model):
    """A server-side watch on a public source (RSS/API/page). Plain-code change
    detection first; AI summary only when something actually changes."""
    KINDS = [("rss", "RSS/news"), ("page", "web page"), ("usd_bdt", "USD/BDT rate"),
             ("price", "price drop"), ("job", "govt job circular"),
             ("exam", "exam result"), ("visa", "visa slot"), ("weather", "weather"),
             ("flight", "flight price"), ("offer", "card offer")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="watchers")
    kind = models.CharField(max_length=12, choices=KINDS, default="rss")
    label = models.CharField(max_length=120)
    config = models.JSONField(default=dict, blank=True)   # {url, selector, query, district...}
    enabled = models.BooleanField(default=True)
    interval_min = models.PositiveIntegerField(default=360)  # min minutes between checks
    last_checked = models.DateTimeField(null=True, blank=True)
    last_hash = models.CharField(max_length=64, blank=True, default="")
    last_value = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class WatchHit(models.Model):
    """A detected change — short ORIGINAL summary only, never source content."""
    watcher = models.ForeignKey(Watcher, on_delete=models.CASCADE, related_name="hits")
    summary = models.CharField(max_length=300)
    old_value = models.CharField(max_length=200, blank=True, default="")
    new_value = models.CharField(max_length=200, blank=True, default="")
    severity = models.CharField(max_length=8, default="info")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class Contact(models.Model):
    """Personal CRM (feature 24) — people the user meets, notes, follow-ups."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="contacts")
    name = models.CharField(max_length=120)
    phone = models.CharField(max_length=40, blank=True, default="")
    org = models.CharField(max_length=120, blank=True, default="")
    note = models.TextField(blank=True, default="")
    tags = models.JSONField(default=list, blank=True)
    next_followup = models.DateField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]


class Meeting(models.Model):
    """A meeting/interaction — feeds the personal CRM + class/meeting alerts."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="meetings")
    contact = models.ForeignKey(Contact, null=True, blank=True,
                                on_delete=models.SET_NULL, related_name="meetings")
    title = models.CharField(max_length=160)
    when = models.DateTimeField(null=True, blank=True)
    summary = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-when", "-created_at"]


class BusinessProfile(models.Model):
    """Business mode (feature 33) — one per user who runs a shop. Replies use
    the REAL catalog/stock/price only; the AI never claims to be human."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="business")
    shop_name = models.CharField(max_length=120, blank=True, default="")
    hours = models.CharField(max_length=120, blank=True, default="")
    style_sample = models.TextField(blank=True, default="")   # learns owner's tone
    auto_reply = models.BooleanField(default=False)           # off by default
    handoff_note = models.CharField(max_length=200, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)


class Product(models.Model):
    """Catalog item — source of truth for price/stock (never invented).

    Business v2 selling (§3): `price` is the SELLING price; `min_price` is the
    bargaining floor (sales below it are impossible — enforced in the pure layer
    `business_selling`); `cost_price` is owner-only (staff-redacted)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="products")
    # Business v2: a user may own several businesses (plan §1). Nullable so
    # existing single-shop rows are safe.
    business = models.ForeignKey("BusinessProfile", null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="products")
    name = models.CharField(max_length=160)
    category = models.CharField(max_length=80, blank=True, default="")
    price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    min_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)   # bargaining floor
    cost_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)  # owner-only
    stock = models.IntegerField(default=0)
    low_stock_at = models.IntegerField(default=3)
    sku = models.CharField(max_length=40, blank=True, default="")
    barcode = models.CharField(max_length=64, blank=True, default="", db_index=True)
    description = models.TextField(blank=True, default="")
    photo = models.ImageField(upload_to="catalog/", null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]
        indexes = [
            models.Index(fields=["user", "category"]),
            models.Index(fields=["user", "barcode"]),
            models.Index(fields=["user", "sku"]),
        ]


class Order(models.Model):
    """Order capture → confirmation → courier (feature 33 + Business v2 AI §4).

    State machine (business_ai.advance_order): new→confirmed→packed→shipped→
    delivered/returned/cancelled. `courier_live` is False for a MOCK booking
    (no courier key configured yet)."""
    STATUS = [("new", "new"), ("confirmed", "confirmed"), ("packed", "packed"),
              ("shipped", "shipped"), ("delivered", "delivered"),
              ("returned", "returned"), ("cancelled", "cancelled")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="orders")
    customer_name = models.CharField(max_length=120, blank=True, default="")
    customer_phone = models.CharField(max_length=40, blank=True, default="")
    address = models.TextField(blank=True, default="")
    items = models.JSONField(default=list, blank=True)     # [{name, qty, price}]
    total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    status = models.CharField(max_length=12, choices=STATUS, default="new")
    payment = models.CharField(max_length=12, default="cod")     # feeds cod_amount()
    courier = models.CharField(max_length=40, blank=True, default="")
    tracking = models.CharField(max_length=80, blank=True, default="")
    courier_live = models.BooleanField(default=False)            # False = mock booking
    channel = models.CharField(max_length=20, default="manual")  # whatsapp/messenger/manual
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class AutoPayRule(models.Model):
    """Approval-based auto-pay ladder (feature 27). Three steps, per-bill cap,
    and a global stop-all. Execution needs a payment integration (🔑); without
    it, rules are saved and show 'Available when a payment method is added'."""
    STEPS = [("notify", "just notify"), ("prepare", "prepare + 1-tap approve"),
             ("auto_capped", "auto within cap")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="autopay_rules")
    biller = models.CharField(max_length=80)
    step = models.CharField(max_length=12, choices=STEPS, default="notify")
    max_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    enabled = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "biller")]


class SafetyCheckin(models.Model):
    """Safe-arrival check-in (feature — family safety). The owner says where
    they're going and by when; if they don't mark 'arrived' before the ETA +
    grace, the family poll surfaces an overdue alert. One active check-in per
    user at a time (we mark older ones arrived/closed when a new one starts)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="checkins")
    place = models.CharField(max_length=160, blank=True, default="")
    eta = models.DateTimeField(null=True, blank=True)
    arrived = models.BooleanField(default=False)
    arrived_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class FamilyAlert(models.Model):
    """A persisted family-facing alert (scam report a member sent, an overdue
    safe-arrival check-in, etc.). Surfaced by the foreground /alerts poll — the
    Realme-safe replacement for background push (see MEMORY)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="family_alerts")
    kind = models.CharField(max_length=24, default="scam_report")  # scam_report|checkin_overdue
    title = models.CharField(max_length=160, blank=True, default="")
    body = models.TextField(blank=True, default="")
    severity = models.CharField(max_length=8, default="high")      # high|med|info
    payload = models.JSONField(default=dict, blank=True)
    dismissed = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CategoryCorrection(models.Model):
    """Per-user learned category for a parsed counterparty (improves the guesser)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="category_corrections")
    key = models.CharField(max_length=120)
    category = models.CharField(max_length=60)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "key")]


# ===========================================================================
# Module 5 (P13+) — Health / Life / Launch-gaps / Connected Circle
# ===========================================================================

class Birthday(models.Model):
    """Birthdays & memorable days (Health module). Year<=1900 is a sentinel for
    'unknown year' (we only remind on month/day then). Drafts are never auto-sent."""
    KINDS = [("birthday", "birthday"), ("anniversary", "anniversary"),
             ("death_anniversary", "death_anniversary"), ("memorable", "memorable")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="birthdays")
    name = models.CharField(max_length=120)
    date = models.DateField()                       # year<=1900 => unknown year
    kind = models.CharField(max_length=20, choices=KINDS, default="birthday")
    lead_days = models.PositiveSmallIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["date"]


class Appointment(models.Model):
    """Meetings / appointments (Life module). Not the CRM Meeting model — this
    is the user's own calendar with reminders + 'leave now' travel estimates."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="appointments")
    title = models.CharField(max_length=160)
    start = models.DateTimeField()
    duration_min = models.PositiveIntegerField(default=60)
    place = models.CharField(max_length=200, blank=True, default="")
    place_lat = models.FloatField(null=True, blank=True)
    place_lng = models.FloatField(null=True, blank=True)
    note = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["start"]


class ExamWatcher(models.Model):
    """Exam-result watcher (Life module). Polls a PUBLIC url the user pasted —
    never behind auth. result_ready stays a heads-up; we never fake a result."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="exam_watchers")
    label = models.CharField(max_length=120, blank=True, default="")
    url = models.URLField(blank=True, default="")
    expected_date = models.DateField(null=True, blank=True)
    roll = models.CharField(max_length=40, blank=True, default="")
    board = models.CharField(max_length=40, blank=True, default="")
    exam = models.CharField(max_length=40, blank=True, default="")
    year = models.CharField(max_length=8, blank=True, default="")
    last_snapshot = models.CharField(max_length=128, blank=True, default="")
    consecutive_failures = models.PositiveIntegerField(default=0)
    result_ready = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class PasswordResetToken(models.Model):
    """Launch-gap A — password reset. We store only the sha256 HASH of the raw
    token; single-use (`used`), short expiry; compare_digest on confirm."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="reset_tokens")
    token_hash = models.CharField(max_length=64, db_index=True)
    channel = models.CharField(max_length=10, default="email")
    expires_at = models.DateTimeField()
    used = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class AnalyticsEvent(models.Model):
    """Launch-gap — privacy-first product analytics. NO user FK by design: only
    a salted HMAC uid_hash, an allow-listed event name, a day bucket and tiny
    sanitised props. Consent-gated at ingest."""
    uid_hash = models.CharField(max_length=32, db_index=True)
    name = models.CharField(max_length=40)
    day = models.DateField(db_index=True)
    props = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CircleMember(models.Model):
    """Connected Circle — one relationship edge. public_key is the peer's
    PUBLIC X25519 key (the private key never leaves the owner's device)."""
    STATES = [("pending", "pending"), ("accepted", "accepted"),
              ("declined", "declined"), ("blocked", "blocked")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="circle_members")
    name = models.CharField(max_length=120, blank=True, default="")
    relation = models.CharField(max_length=20, default="friend")
    custom_label = models.CharField(max_length=60, blank=True, default="")
    phone = models.CharField(max_length=40, blank=True, default="")
    # --- request direction + optional pre-acceptance note (relationship-request fix) ---
    # direction: this row, relative to `user`. "outgoing" = user SENT the request
    # (may only cancel); "incoming" = someone sent it TO user (may accept/decline).
    # Every historical row was created by its owner, so "outgoing" is the safe
    # default/backfill. peer_user links the OTHER party's account so the card can
    # show their real display name + photo instead of "?".
    direction = models.CharField(max_length=10, default="outgoing")
    note = models.TextField(blank=True, default="")  # one optional pre-accept note
    peer_user = models.ForeignKey(User, null=True, blank=True,
                                  on_delete=models.SET_NULL,
                                  related_name="circle_incoming_edges")
    public_key = models.TextField(blank=True, default="")
    key_id = models.CharField(max_length=64, blank=True, default="")
    scheme = models.CharField(max_length=64, blank=True, default="")
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    sharing = models.JSONField(default=dict, blank=True)
    # --- M1 calls/privacy member controls (server-enforced) ---
    blocked = models.BooleanField(default=False)
    restricted = models.BooleanField(default=False)
    muted_until = models.DateTimeField(null=True, blank=True)
    pinned = models.BooleanField(default=False)
    chat_lock = models.JSONField(default=dict, blank=True)
    archived = models.BooleanField(default=False)
    video_unlocked = models.BooleanField(default=False)  # referral-points unlock
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CircleMessage(models.Model):
    """Connected Circle — a relayed message. The server stores the CIPHERTEXT
    verbatim and NEVER a key; it cannot read this (nor can the server AI)."""
    member = models.ForeignKey(CircleMember, null=True, blank=True,
                               on_delete=models.CASCADE, related_name="messages")
    sender = models.ForeignKey(User, on_delete=models.CASCADE, related_name="circle_sent")
    recipient_ids = models.JSONField(default=list, blank=True)
    content_type = models.CharField(max_length=16, default="text")
    ciphertext = models.TextField(blank=True, default="")
    nonce = models.CharField(max_length=128, blank=True, default="")
    blob_ref = models.CharField(max_length=256, blank=True, default="")
    sender_key_id = models.CharField(max_length=64, blank=True, default="")
    scheme = models.CharField(max_length=64, blank=True, default="")
    delivered_to = models.JSONField(default=list, blank=True)
    read_by = models.JSONField(default=list, blank=True)
    # --- M1 chat-core additions ---
    reply_to = models.ForeignKey("self", null=True, blank=True,
                                 on_delete=models.SET_NULL, related_name="replies")
    reactions = models.JSONField(default=dict, blank=True)   # {member_id: emoji}
    edited_at = models.DateTimeField(null=True, blank=True)
    deleted = models.CharField(max_length=10, blank=True, default="")  # ''|'me'|'everyone'
    hidden_for = models.JSONField(default=list, blank=True)  # member ids (delete-for-me)
    starred_by = models.JSONField(default=list, blank=True)  # member ids
    pinned = models.BooleanField(default=False)
    forwarded = models.BooleanField(default=False)
    forward_hops = models.IntegerField(default=0)
    client_msg_id = models.CharField(max_length=64, blank=True, default="",
                                     db_index=True)  # dedupe
    link_preview = models.JSONField(null=True, blank=True)  # opaque {ciphertext,nonce}
    # --- M2 groups additions (1:1 messages keep group null; never breaks 1:1) ---
    group = models.ForeignKey("CircleGroup", null=True, blank=True,
                              on_delete=models.CASCADE, related_name="messages")
    per_recipient = models.JSONField(null=True, blank=True)  # opaque fan-out map
    mentions = models.JSONField(null=True, blank=True)       # list[int] member ids
    announcement = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at"]


class CircleInvite(models.Model):
    """Connected Circle — a single-use signed invite (phone/QR). `used` is the
    DB enforcement of single-use (the token signature alone doesn't enforce it)."""
    inviter = models.ForeignKey(User, on_delete=models.CASCADE, related_name="circle_invites")
    relation = models.CharField(max_length=20, default="friend")
    relation_code = models.CharField(max_length=20, blank=True, default="")
    family_sub = models.CharField(max_length=20, blank=True, default="")  # optional family role
    token = models.CharField(max_length=256, db_index=True)
    used = models.BooleanField(default=False)
    expires_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CircleReport(models.Model):
    """Connected Circle — a safety report on a member (+optional auto-block)."""
    reporter = models.ForeignKey(User, on_delete=models.CASCADE, related_name="circle_reports")
    target = models.ForeignKey(CircleMember, on_delete=models.CASCADE, related_name="reports")
    reason = models.CharField(max_length=20, default="other")
    note = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


# ===========================================================================
# Messenger M1 — calls, privacy, referral
# ===========================================================================
class CallRecord(models.Model):
    """A voice/video call between two circle peers. Server stores metadata only
    (no media). The video entitlement is gated server-side (circle_calls)."""
    KINDS = [("voice", "voice"), ("video", "video")]
    caller = models.ForeignKey(User, on_delete=models.CASCADE, related_name="calls_made")
    callee = models.ForeignKey(User, on_delete=models.CASCADE, related_name="calls_received")
    circle = models.ForeignKey(CircleMember, null=True, blank=True,
                               on_delete=models.SET_NULL, related_name="calls")
    kind = models.CharField(max_length=8, choices=KINDS, default="voice")
    state = models.CharField(max_length=16, default="ringing")
    started_at = models.DateTimeField(auto_now_add=True)
    answered_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    duration_sec = models.IntegerField(default=0)
    low_data = models.BooleanField(default=False)

    class Meta:
        ordering = ["-started_at"]


class CirclePrivacy(models.Model):
    """One privacy/controls row per user. Server-enforced (circle_privacy)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="circle_privacy")
    visibility = models.JSONField(default=dict, blank=True)  # {field: policy}
    read_receipts = models.BooleanField(default=True)
    typing = models.BooleanField(default=True)
    call_policy = models.CharField(max_length=12, default="everyone")
    call_allow_ids = models.JSONField(default=list, blank=True)
    call_allow_relations = models.JSONField(default=list, blank=True)
    dnd_enabled = models.BooleanField(default=False)
    dnd_start = models.CharField(max_length=5, default="22:00")
    dnd_end = models.CharField(max_length=5, default="07:00")
    dnd_family_exception = models.BooleanField(default=True)
    # #95/#96 message-level privacy (conservative defaults). who_can_message
    # gates strangers (my_circle = strangers routed to a no-notify requests
    # inbox); phone_hidden keeps the number private by default.
    who_can_message = models.CharField(max_length=12, default="my_circle")
    phone_hidden = models.BooleanField(default=True)


class ReferralGrant(models.Model):
    """Append-only referral points ledger. Balance = max(0, sum(points))."""
    KINDS = [("grant", "grant"), ("clawback", "clawback"),
             ("redeem", "redeem"), ("bonus", "bonus")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="referral_grants")
    invitee = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL,
                                related_name="referral_as_invitee")
    device_id = models.CharField(max_length=64, blank=True, default="")
    kind = models.CharField(max_length=10, choices=KINDS, default="grant")
    points = models.IntegerField(default=0)  # signed
    reason = models.CharField(max_length=40, blank=True, default="")
    reverses = models.IntegerField(null=True, blank=True)  # row id this clawback reverses
    month = models.CharField(max_length=7, blank=True, default="")  # YYYY-MM
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["user", "invitee"],
                condition=models.Q(kind="grant"),
                name="uniq_referral_grant_per_invitee"),
        ]


# ===========================================================================
# Safe Journey & Personal Safety
# ===========================================================================
class Journey(models.Model):
    """A Safe Journey. Location history auto-deletes after retention; NO server
    location remains past expires_at (privacy item 18)."""
    traveller = models.ForeignKey(User, on_delete=models.CASCADE, related_name="journeys")
    origin = models.JSONField(null=True, blank=True)
    destination = models.JSONField(default=dict, blank=True)
    eta = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=16, default="active")
    mode = models.CharField(max_length=16, blank=True, default="")
    vehicle = models.JSONField(null=True, blank=True)
    arrival_radius_m = models.IntegerField(default=120)
    route_radius_m = models.IntegerField(default=500)
    overdue_grace_min = models.IntegerField(default=10)
    response_window_min = models.IntegerField(default=10)
    route_deviation = models.BooleanField(default=False)
    planned_route = models.JSONField(null=True, blank=True)
    location_retention_hours = models.IntegerField(default=24)
    expires_at = models.DateTimeField(null=True, blank=True)  # HARD CAP
    last_location = models.JSONField(null=True, blank=True)
    last_activity_at = models.DateTimeField(null=True, blank=True)
    sos_active = models.BooleanField(default=False)
    silent = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class JourneyWatcher(models.Model):
    journey = models.ForeignKey(Journey, on_delete=models.CASCADE, related_name="watchers")
    member = models.ForeignKey(CircleMember, on_delete=models.CASCADE, related_name="watching")

    class Meta:
        unique_together = [("journey", "member")]


class SavedPlace(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="saved_places")
    label = models.CharField(max_length=40, blank=True, default="")
    name = models.CharField(max_length=160, blank=True, default="")
    lat = models.FloatField(null=True, blank=True)
    lng = models.FloatField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class WellnessWatch(models.Model):
    """Parents-living-alone wellness check. Opt-in by parent (GATE)."""
    parent = models.OneToOneField(User, on_delete=models.CASCADE, related_name="wellness_watch")
    enabled = models.BooleanField(default=False)
    parent_opt_in = models.BooleanField(default=False)  # arming GATE
    period_hours = models.IntegerField(default=12)
    response_window = models.IntegerField(default=120)  # minutes
    quiet_start = models.CharField(max_length=5, default="22:00")
    quiet_end = models.CharField(max_length=5, default="07:00")
    watcher_ids = models.JSONField(default=list, blank=True)
    last_activity_at = models.DateTimeField(null=True, blank=True)
    prompt_sent_at = models.DateTimeField(null=True, blank=True)


class DuressPin(models.Model):
    """Hashed normal + duress PINs. Raw PIN is NEVER stored (safety_journey.hash_pin)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="duress_pin")
    normal_hash = models.CharField(max_length=128, blank=True, default="")
    duress_hash = models.CharField(max_length=128, blank=True, default="")
    salt = models.CharField(max_length=64, blank=True, default="")


# ===========================================================================
# Messenger M2 — Groups (item 7). Server authority is core/logic/circle_groups.
# Members are a SUBSET of the creator's/admins' circle (circle-only, enforced in
# the views). The server stores CIPHERTEXT ONLY — same E2E contract as 1:1.
# ===========================================================================
class CircleGroup(models.Model):
    """A group chat. The creator is seeded as the first admin. `size_limit` is
    configurable per group (clamped by circle_groups.clamp_size_limit)."""
    creator = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="circle_groups")
    name = models.CharField(max_length=100, default="")
    description = models.TextField(blank=True, default="")
    photo_ref = models.CharField(max_length=256, blank=True, default="")  # enc blob ref
    size_limit = models.IntegerField(default=256)
    announcements_only = models.BooleanField(default=False)
    pinned_ids = models.JSONField(default=list, blank=True)  # group-scoped pins (cap 5)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CircleGroupMember(models.Model):
    """Membership edge. `member` is the actual peer User so the roster can expose
    a stable id + per-viewer public key. role admin|member; status FSM
    active|left|removed (circle_groups.apply_membership_event)."""
    ROLES = [("admin", "admin"), ("member", "member")]
    STATES = [("active", "active"), ("left", "left"), ("removed", "removed")]
    group = models.ForeignKey(CircleGroup, on_delete=models.CASCADE,
                              related_name="members")
    member = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="group_memberships")
    role = models.CharField(max_length=8, choices=ROLES, default="member")
    status = models.CharField(max_length=8, choices=STATES, default="active")
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("group", "member")]
        ordering = ["joined_at"]


class GroupPoll(models.Model):
    """A poll. question_ct / options_ct are OPAQUE ciphertext (server never reads
    labels); votes reference options by INDEX only (circle_groups.tally_poll)."""
    group = models.ForeignKey(CircleGroup, on_delete=models.CASCADE,
                              related_name="polls")
    author = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="group_polls")
    option_count = models.IntegerField(default=2)
    multi = models.BooleanField(default=False)
    closed = models.BooleanField(default=False)
    question_ct = models.JSONField(default=dict, blank=True)   # opaque
    options_ct = models.JSONField(default=list, blank=True)    # opaque [ct, ...]
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class PollVote(models.Model):
    """One voter's choice set on a poll. A re-vote REPLACES the row's choices."""
    poll = models.ForeignKey(GroupPoll, on_delete=models.CASCADE,
                             related_name="votes")
    voter = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="poll_votes")
    choices = models.JSONField(default=list, blank=True)  # list[int] option indices
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("poll", "voter")]


# ===========================================================================
# Messenger M2 — Status / Stories (item 8). Server authority is
# core/logic/circle_status. CIPHERTEXT ONLY; auto-expires after 24h.
# ===========================================================================
class CircleStatus(models.Model):
    """A 24-hour status/story. TEXT is inline ciphertext; PHOTO/VIDEO carry a
    blob_ref + ciphertext metadata (key-gated like M1 media). expires_at is
    indexed (= created + 24h via circle_status.expiry_for) for cheap cleanup."""
    KINDS = [("text", "text"), ("photo", "photo"), ("video", "video")]
    author = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="circle_statuses")
    kind = models.CharField(max_length=8, choices=KINDS, default="text")
    # text status: inline ciphertext
    ciphertext = models.TextField(blank=True, default="")
    nonce = models.CharField(max_length=128, blank=True, default="")
    scheme = models.CharField(max_length=64, blank=True, default="")
    sender_key_id = models.CharField(max_length=64, blank=True, default="")
    # photo/video status: opaque blob + ciphertext metadata
    blob_ref = models.CharField(max_length=256, blank=True, default="")
    meta = models.JSONField(default=dict, blank=True)  # full validated status meta
    visibility = models.JSONField(default=dict, blank=True)  # {mode,allow_ids,except_ids}
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-created_at"]


class StatusView(models.Model):
    """Who saw a status. A viewer with read-receipts OFF is counted but marked
    anonymous so the author can never name them (circle_status.record_view)."""
    status = models.ForeignKey(CircleStatus, on_delete=models.CASCADE,
                               related_name="views")
    viewer = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="status_views")
    anonymous = models.BooleanField(default=False)
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("status", "viewer")]


class StatusMute(models.Model):
    """Muter hides an author's status from their tray (no unfriend/notify)."""
    muter = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="status_mutes")
    author = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="status_muted_by")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("muter", "author")]


# ===========================================================================
# Messenger M2 — Extras (items 9 + 10). Server authority is
# core/logic/circle_extras. All ciphertext/meta fields are OPAQUE.
# ===========================================================================
class ChatSettings(models.Model):
    """Per-chat settings. Only `disappearing_sec` is server-enforced (purge /
    hide timer); wallpaper/theme are presentation prefs the client may sync."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="chat_settings")
    peer = models.ForeignKey(CircleMember, on_delete=models.CASCADE,
                             related_name="chat_settings")
    disappearing_sec = models.IntegerField(default=0)  # 0/86400/604800/7776000
    wallpaper = models.CharField(max_length=40, blank=True, default="default")
    wallpaper_blob_ref = models.CharField(max_length=256, blank=True, default="")
    theme = models.CharField(max_length=16, blank=True, default="system")
    bubble_scheme = models.CharField(max_length=64, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "peer")]


class ScheduledMessage(models.Model):
    """A client-composed, ALREADY-ENCRYPTED envelope stored opaque until send_at.
    The server never holds future plaintext (validate_backup/forbidden-keys)."""
    STATES = [("pending", "pending"), ("sent", "sent"),
              ("cancelled", "cancelled"), ("failed", "failed")]
    sender = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="scheduled_messages")
    peer = models.ForeignKey(CircleMember, on_delete=models.CASCADE,
                             related_name="scheduled_messages")
    client_msg_id = models.CharField(max_length=64, db_index=True)
    send_at = models.DateTimeField(db_index=True)
    status = models.CharField(max_length=10, choices=STATES, default="pending")
    attempt = models.IntegerField(default=0)
    envelope = models.JSONField(default=dict, blank=True)  # opaque ciphertext envelope
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("sender", "client_msg_id")]
        ordering = ["send_at"]


class BroadcastList(models.Model):
    """A convenience grouping ON THE SENDER's side only. Sends fan out to N
    INDIVIDUAL 1:1 messages — recipients are NEVER linked server-side."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="broadcast_lists")
    name = models.CharField(max_length=120, blank=True, default="")
    member_ids = models.JSONField(default=list, blank=True)  # CircleMember ids
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class UserSticker(models.Model):
    """A user-made sticker from the user's OWN photo — stored as an encrypted
    media blob ref only (key-gated). Built-in packs live in code (STICKER_PACKS)."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="user_stickers")
    blob_ref = models.CharField(max_length=256, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class ChatBackup(models.Model):
    """An encrypted chat backup envelope. The recovery code / key is NEVER stored
    (validate_backup_envelope rejects secrets) — only the sealed blob + KDF meta."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="chat_backups")
    v = models.IntegerField(default=1)
    scheme = models.CharField(max_length=64, blank=True, default="")
    ciphertext = models.TextField(blank=True, default="")
    nonce = models.CharField(max_length=256, blank=True, default="")
    salt = models.CharField(max_length=256, blank=True, default="")
    iters = models.IntegerField(default=0)
    message_count = models.IntegerField(default=0)
    recovery_hint = models.CharField(max_length=200, blank=True, default="")
    size_bytes = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class LinkedDevice(models.Model):
    """A companion device registry row. The server stores ONLY a public key id +
    non-secret meta — never a private key (item 10; design in linked_devices.md)."""
    PLATFORMS = [("android", "android"), ("ios", "ios"), ("web", "web")]
    ROLES = [("primary", "primary"), ("linked", "linked")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="linked_devices")
    device_id = models.CharField(max_length=128, unique=True)
    platform = models.CharField(max_length=10, choices=PLATFORMS, default="android")
    role = models.CharField(max_length=8, choices=ROLES, default="linked")
    public_key_id = models.CharField(max_length=64, blank=True, default="")
    name = models.CharField(max_length=120, blank=True, default="")
    linked_at = models.DateTimeField(auto_now_add=True)
    last_active = models.DateTimeField(null=True, blank=True)
    revoked = models.BooleanField(default=False)

    class Meta:
        ordering = ["-linked_at"]


# ===========================================================================
# Messenger FULL-UI backend (MESSENGER_UI_FULL §2-4). Pure logic lives in
# core/logic/msg_messenger_ui.py. All rows are ownership-scoped by `user`.
# ===========================================================================

class DeviceLinkToken(models.Model):
    """A SINGLE-USE, short-TTL pairing token minted by the mobile primary so a
    web/desktop client can link (mint_link_token). The token is a random handle
    (secrets.token_urlsafe) — NEVER a key, NEVER plaintext. `used` enforces
    single-use; `expires_at` enforces the short TTL (LINK_TOKEN_TTL_SEC)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="device_link_tokens")
    token = models.CharField(max_length=64, unique=True, db_index=True)
    platform = models.CharField(max_length=10, default="web")  # web/desktop later
    used = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-created_at"]


class StarredMessage(models.Model):
    """A per-user bookmark on one message in one chat. Stores ONLY opaque refs
    (the chat it lives in + the message id) so the client can JUMP to it — never
    the message body. Idempotent per (user, chat_kind, chat_id, message_id)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="starred_messages")
    chat_kind = models.CharField(max_length=12, default="member")  # member/group/community/channel
    chat_id = models.CharField(max_length=64)
    message_id = models.CharField(max_length=64)
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "chat_kind", "chat_id", "message_id")]
        ordering = ["-at"]
        indexes = [models.Index(fields=["user", "chat_kind", "chat_id"])]


class ChatList(models.Model):
    """A user-defined chat list ("Family", "Work") that feeds the hub filter
    chips. member_refs are CircleMember ids. Reserved chip names are rejected by
    msg_messenger_ui.validate_list_name."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="chat_lists")
    name = models.CharField(max_length=40)
    member_refs = models.JSONField(default=list, blank=True)  # CircleMember ids
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "name")]
        ordering = ["-created_at"]


class CallLink(models.Model):
    """An EXPIRING tokenized call-join link (send-call-link). The token is a
    random handle, not a room secret. VIDEO links are Premium creator-gated at
    mint time (circle_calls.can_place_call)."""
    KINDS = [("voice", "voice"), ("video", "video")]
    creator = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="call_links")
    token = models.CharField(max_length=64, unique=True, db_index=True)
    kind = models.CharField(max_length=8, choices=KINDS, default="voice")
    revoked = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-created_at"]


class ScheduledCall(models.Model):
    """A scheduled 1:1 or group call (time + a reminder fanned out to every
    invitee). VIDEO is Premium organiser-gated. Reminders themselves are enqueued
    by the view via the reminders engine."""
    KINDS = [("voice", "voice"), ("video", "video")]
    STATES = [("scheduled", "scheduled"), ("started", "started"),
              ("cancelled", "cancelled")]
    organiser = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="scheduled_calls")
    invitee_ids = models.JSONField(default=list, blank=True)  # CircleMember/User ids
    call_kind = models.CharField(max_length=8, choices=KINDS, default="voice")
    title = models.CharField(max_length=120, blank=True, default="")
    scheduled_at = models.DateTimeField(db_index=True)
    remind_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=10, choices=STATES, default="scheduled")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["scheduled_at"]


# ===========================================================================
# Business v2 — SELLING (§3). Pure logic: core/logic/business_selling.py.
# ALL money as integer POISHA (1 taka = 100 poisha). No floats.
# ===========================================================================

class BusinessStaff(models.Model):
    """A staff membership edge: a User who may operate ONE business they do not
    own. role=staff can sell/ring up sales + see customer receivables + cashbox,
    but NEVER cost/profit/min-price nor the supplier-payables book (enforced by
    business_selling.redact_for_role + owner-only gates in business_views).
    The business owner is always implicitly role=owner (no row needed)."""
    ROLES = [("owner", "owner"), ("staff", "staff")]
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="staff")
    member = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="business_memberships")
    role = models.CharField(max_length=8, choices=ROLES, default="staff")
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("business", "member")]
        indexes = [models.Index(fields=["member", "active"])]


class ProductVariant(models.Model):
    """Size/colour combo of a Product. vkey from business_selling.variant_key()."""
    product = models.ForeignKey(Product, on_delete=models.CASCADE,
                                related_name="variants")
    vkey = models.CharField(max_length=120)         # '__base__' when no size/colour
    size = models.CharField(max_length=80, blank=True, default="")
    colour = models.CharField(max_length=80, blank=True, default="")
    sell_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    cost_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    min_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    stock = models.IntegerField(default=0)
    barcode = models.CharField(max_length=64, blank=True, default="", db_index=True)
    low_stock_at = models.IntegerField(default=3)

    class Meta:
        unique_together = [("product", "vkey")]
        indexes = [models.Index(fields=["product", "vkey"])]


class Category(models.Model):
    """Convenience grouping for the catalog (per business)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="product_categories")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="categories")
    name = models.CharField(max_length=80)

    class Meta:
        unique_together = [("user", "business", "name")]


class Customer(models.Model):
    """A sales customer (distinct from KhataParty — this one buys at the till).
    phone_key is the normalised dedupe key (business_selling.normalize_phone)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="sale_customers")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="customers")
    name = models.CharField(max_length=120, blank=True, default="")
    phone = models.CharField(max_length=40, blank=True, default="")
    phone_key = models.CharField(max_length=40, blank=True, default="", db_index=True)
    address = models.TextField(blank=True, default="")
    area = models.CharField(max_length=80, blank=True, default="")
    notes = models.TextField(blank=True, default="")
    vip = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        # blank phone_key allowed for many rows; a real phone_key is unique/biz.
        unique_together = [("user", "business", "phone_key")]


class Sale(models.Model):
    """A completed checkout (business_selling.checkout). Money in POISHA."""
    PAY = [("cash", "cash"), ("bkash", "bkash"), ("nagad", "nagad"), ("due", "due")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="sales")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="sales")
    customer = models.ForeignKey(Customer, null=True, blank=True,
                                 on_delete=models.SET_NULL, related_name="sales")
    staff = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL,
                              related_name="rung_sales")  # who rang it up (role audit)
    subtotal = models.BigIntegerField(default=0)      # poisha
    discount = models.BigIntegerField(default=0)
    total = models.BigIntegerField(default=0)
    paid = models.BigIntegerField(default=0)
    change = models.BigIntegerField(default=0)
    due = models.BigIntegerField(default=0)
    profit = models.BigIntegerField(default=0)        # owner-only (redacted for staff)
    payment_method = models.CharField(max_length=10, choices=PAY, default="cash")
    discount_clamped = models.BooleanField(default=False)  # a discount hit the min floor
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    # ---- a2-cctv: POS VOID (business/sales/<id>/void). A voided sale stays
    # in history (shown as VOID) but is excluded from every report/total.
    voided_at = models.DateTimeField(null=True, blank=True)
    voided_by = models.ForeignKey(User, null=True, blank=True,
                                  on_delete=models.SET_NULL,
                                  related_name="voided_sales")
    void_reason = models.CharField(max_length=200, blank=True, default="")

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["user", "created_at"]),
            models.Index(fields=["business", "created_at"]),
            models.Index(fields=["customer", "created_at"]),
        ]


class SaleLine(models.Model):
    """One line of a Sale. Money in POISHA."""
    sale = models.ForeignKey(Sale, on_delete=models.CASCADE, related_name="lines")
    product = models.ForeignKey(Product, null=True, blank=True,
                                on_delete=models.SET_NULL, related_name="sale_lines")
    variant = models.ForeignKey(ProductVariant, null=True, blank=True,
                                on_delete=models.SET_NULL, related_name="sale_lines")
    product_name = models.CharField(max_length=160)
    size = models.CharField(max_length=80, blank=True, default="")
    colour = models.CharField(max_length=80, blank=True, default="")
    qty = models.IntegerField(default=1)
    unit_price = models.BigIntegerField(default=0)    # poisha, charged
    min_price = models.BigIntegerField(default=0)     # owner-only
    cost_price = models.BigIntegerField(default=0)    # owner-only
    sell_price = models.BigIntegerField(default=0)    # list
    # a2-cctv: the cart variant key, set at checkout so a VOID can restore
    # stock. Blank on sales made before this field existed (restore skipped).
    variant_key = models.CharField(max_length=120, blank=True, default="")


class Expense(models.Model):
    """A business expense — feeds net-profit-after-expenses. Money in POISHA."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="business_expenses")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="expenses")
    amount = models.BigIntegerField(default=0)        # poisha
    category = models.CharField(max_length=80, blank=True, default="")
    note = models.CharField(max_length=200, blank=True, default="")
    date = models.DateField(db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-date", "-created_at"]


# ===========================================================================
# Business v2 — DIGITAL KHATA + CASHBOX. Pure: core/logic/business_khata.py.
# All money as integer POISHA.
# ===========================================================================

class KhataParty(models.Model):
    """A customer or supplier in one business's books. The supplier book exposes
    cost → it is OWNER-ONLY (staff blocked in business_views)."""
    BOOK = [("customer", "customer"), ("supplier", "supplier")]
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="khata_parties")
    book = models.CharField(max_length=10, choices=BOOK)
    name = models.CharField(max_length=120)
    phone = models.CharField(max_length=40, blank=True, default="")
    area = models.CharField(max_length=80, blank=True, default="")
    note = models.TextField(blank=True, default="")
    vip = models.BooleanField(default=False)
    archived = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["business", "book"]),
                   models.Index(fields=["business", "phone"])]


class KhataEntry(models.Model):
    """One ledger line. direction is owner-POV ('gave'|'got'). amount_poisha>0."""
    DIRECTION = [("gave", "gave"), ("got", "got")]
    party = models.ForeignKey(KhataParty, on_delete=models.CASCADE,
                              related_name="entries")
    direction = models.CharField(max_length=4, choices=DIRECTION)
    amount_poisha = models.BigIntegerField()          # always > 0
    note = models.CharField(max_length=200, blank=True, default="")
    bill_photo = models.ImageField(upload_to="khata_bills/", null=True, blank=True)
    at = models.DateTimeField()                        # owner-supplied event time
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at", "id"]
        indexes = [models.Index(fields=["party", "at"])]


class CashboxDay(models.Model):
    """One business day's drawer. Reconciliation writes counted_poisha."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="cashbox_days")
    day = models.DateField()
    opening_poisha = models.BigIntegerField(default=0)
    counted_poisha = models.BigIntegerField(null=True, blank=True)  # set at reconcile
    reconciled_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("business", "day")]
        indexes = [models.Index(fields=["business", "day"])]


class CashEntry(models.Model):
    KIND = [("in", "in"), ("out", "out")]
    day = models.ForeignKey(CashboxDay, on_delete=models.CASCADE,
                            related_name="entries")
    kind = models.CharField(max_length=3, choices=KIND)
    amount_poisha = models.BigIntegerField()          # > 0
    note = models.CharField(max_length=200, blank=True, default="")
    ref = models.CharField(max_length=60, blank=True, default="")   # e.g. order id
    at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at", "id"]


class TagadaSchedule(models.Model):
    """A recurring reminder for one party. The pure layer only compares next_at
    to `now`; the view advances next_at after firing."""
    party = models.ForeignKey(KhataParty, on_delete=models.CASCADE,
                              related_name="tagada_schedules")
    preset = models.CharField(max_length=16, default="reminder")  # polite/reminder/firm/thanks
    channel = models.CharField(max_length=20, default="whatsapp_share")  # or 'sms'
    next_at = models.DateTimeField()
    interval_days = models.IntegerField(default=7)
    enabled = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)


# ===========================================================================
# Business v2 — AI SALES ASSISTANT (§4). Pure: core/logic/business_ai.py.
# ===========================================================================

class ChatThread(models.Model):
    """One customer conversation on an OFFICIAL channel (Cloud API / Messenger).
    last_inbound_at → epoch for business_ai.within_service_window()."""
    CHANNELS = [("whatsapp_cloud", "whatsapp_cloud"), ("messenger", "messenger")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="chat_threads")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="chat_threads")
    customer_phone = models.CharField(max_length=40, blank=True, default="")
    channel = models.CharField(max_length=20, choices=CHANNELS, default="whatsapp_cloud")
    last_inbound_at = models.DateTimeField(null=True, blank=True)
    owner_takeover = models.BooleanField(default=False)
    lang = models.CharField(max_length=2, default="bn")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["user", "customer_phone"])]


class Message(models.Model):
    """One message in a ChatThread. is_ai=True never claims humanity."""
    DIRECTION = [("in", "in"), ("out", "out")]
    thread = models.ForeignKey(ChatThread, on_delete=models.CASCADE,
                               related_name="messages")
    direction = models.CharField(max_length=3, choices=DIRECTION)
    text = models.TextField(blank=True, default="")
    is_ai = models.BooleanField(default=False)
    confidence = models.FloatField(default=0.0)
    needs_human = models.BooleanField(default=False)
    handoff_reason = models.CharField(max_length=40, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]


class CourierShipment(models.Model):
    """Filled by business_ai.book_courier_mock(). live=False until a courier key
    exists (we NEVER fabricate a real booking)."""
    COURIERS = [("pathao", "pathao"), ("steadfast", "steadfast"), ("redx", "redx")]
    order = models.ForeignKey(Order, on_delete=models.CASCADE,
                              related_name="shipments")
    courier = models.CharField(max_length=20, choices=COURIERS)
    tracking = models.CharField(max_length=80, blank=True, default="")
    live = models.BooleanField(default=False)
    cod_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class OwnerPolicy(models.Model):
    """Shop delivery/returns/hours policy → business_ai.build_context()."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="owner_policies")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="policies")
    delivery_inside = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    delivery_outside = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    free_delivery_over = models.DecimalField(max_digits=12, decimal_places=2, null=True, blank=True)
    returns = models.TextField(blank=True, default="")
    hours = models.CharField(max_length=160, blank=True, default="")
    payment_note = models.TextField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)


class BargainRule(models.Model):
    """Per-product bargaining ladder. min_price lives on Product (the enforced
    floor); here we store the allowed discount ladder + bundle rules that feed
    business_ai.negotiate()."""
    product = models.ForeignKey(Product, on_delete=models.CASCADE,
                                related_name="bargain_rules")
    discount_steps = models.JSONField(default=list, blank=True)  # [pct|amount, ...]
    free_delivery_over = models.DecimalField(max_digits=12, decimal_places=2, null=True, blank=True)
    bundle_min_qty = models.IntegerField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class OwnerWallet(models.Model):
    """A POINTER to the owner's OWN bKash/Nagad merchant. NEVER a balance — we
    never hold funds (business_ai.merchant_qr_descriptor holds_funds=False)."""
    PROVIDERS = [("bkash", "bkash"), ("nagad", "nagad")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="owner_wallets")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="wallets")
    provider = models.CharField(max_length=10, choices=PROVIDERS)
    merchant_number = models.CharField(max_length=40, blank=True, default="")
    merchant_name = models.CharField(max_length=120, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)


# ===========================================================================
# Messenger STEP 3 — CONTACTS & INVITES + personal CONNECTION REQUEST.
# Server authority: core/logic/msg_contacts.py (builds on core.logic.circle).
# ===========================================================================
class UserPhoneHash(models.Model):
    """The ONLY place a phone hash is stored, and ONLY for verified real users.
    Computed once at phone-verify with msg_contacts.hash_phone over the server-
    wide match salt. Non-users' hashes are NEVER written anywhere (match_contacts
    is a pure, zero-storage set intersection)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="phone_hash")
    phone_hash = models.CharField(max_length=32, unique=True, db_index=True)
    salt_version = models.CharField(max_length=8, default="v1")
    created_at = models.DateTimeField(auto_now_add=True)


class ConnectionRequest(models.Model):
    """A personal connection request (messenger). Reuses the circle request state
    machine + the 2b fix via msg_contacts.act_on_connection_request. `note` is the
    ONE optional pre-accept note; `note_used` is the one-note budget flag enforced
    by can_send_before_accept. Unique (requester,target) while pending."""
    STATES = [("pending", "pending"), ("accepted", "accepted"),
              ("declined", "declined"), ("blocked", "blocked")]
    requester = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="connection_requests_sent")
    target = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="connection_requests_recv")
    relation = models.CharField(max_length=20, default="friend")
    custom_label = models.CharField(max_length=60, blank=True, default="")
    note = models.CharField(max_length=280, blank=True, default="")
    note_used = models.BooleanField(default=False)
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["requester", "target"],
                condition=models.Q(state="pending"),
                name="uniq_pending_connection_request"),
        ]


class InviteOutbound(models.Model):
    """Audit of an invite the user created (never auto-sent by the server).
    channel: in_app | share_link | sms_own_sim. `token` reuses
    circle.make_invite_token for share-link / SMS deep links."""
    CHANNELS = [("in_app", "in_app"), ("share_link", "share_link"),
                ("sms_own_sim", "sms_own_sim")]
    inviter = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="invites_outbound")
    channel = models.CharField(max_length=16, choices=CHANNELS, default="in_app")
    token = models.CharField(max_length=256, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


# ===========================================================================
# Messenger STEP 3 — COMMUNITIES.  Server authority: core/logic/msg_community.py
# (reuses circle_groups roles/announcements/size + circle REQ_* states).
# ===========================================================================
class Community(models.Model):
    """An umbrella of groups. Seeded with exactly one announcements group that is
    never deletable (new_community). Public communities require the creator's
    owner-switch User.public_surfaces_enabled."""
    creator = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="communities")
    name = models.CharField(max_length=100)
    description = models.TextField(blank=True, default="")
    photo_ref = models.CharField(max_length=256, blank=True, default="")
    is_public = models.BooleanField(default=False)   # gated by owner switch
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CommunityGroup(models.Model):
    """A group under a community. Exactly one kind=announcements per community
    (seeded, announcements_only forever, never deleted). join_mode open|request."""
    KINDS = [("announcements", "announcements"), ("topic", "topic")]
    JOIN = [("open", "open"), ("request", "request")]
    community = models.ForeignKey(Community, on_delete=models.CASCADE,
                                  related_name="groups")
    creator = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="community_groups")
    kind = models.CharField(max_length=14, choices=KINDS, default="topic")
    name = models.CharField(max_length=100)
    description = models.TextField(blank=True, default="")
    photo_ref = models.CharField(max_length=256, blank=True, default="")
    join_mode = models.CharField(max_length=8, choices=JOIN, default="request")
    size_limit = models.IntegerField(default=256)
    announcements_only = models.BooleanField(default=False)
    rules = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at"]


class CommunityMember(models.Model):
    """Membership edge (role admin|member, status active|left|removed)."""
    ROLES = [("admin", "admin"), ("member", "member")]
    STATES = [("active", "active"), ("left", "left"), ("removed", "removed")]
    community = models.ForeignKey(Community, on_delete=models.CASCADE,
                                  related_name="members")
    group = models.ForeignKey(CommunityGroup, on_delete=models.CASCADE,
                              related_name="members")
    member = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="community_memberships")
    role = models.CharField(max_length=8, choices=ROLES, default="member")
    status = models.CharField(max_length=8, choices=STATES, default="active")
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("group", "member")]
        ordering = ["joined_at"]


class CommunityJoinRequest(models.Model):
    """A request-join FSM row (apply_join_event): pending->approved|rejected|
    cancelled. Admin approves via can_approve_join."""
    STATES = [("pending", "pending"), ("approved", "approved"),
              ("rejected", "rejected"), ("cancelled", "cancelled")]
    group = models.ForeignKey(CommunityGroup, on_delete=models.CASCADE,
                              related_name="join_requests")
    requester = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="community_join_requests")
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class CommunityMessageRequest(models.Model):
    """A first message from someone OUTSIDE the recipient's circle (can_direct_
    message route=message_request). Stores CIPHERTEXT ONLY — server never reads
    the body. FSM via apply_msgreq_event. Rate-limited per sender (check_msgreq_
    rate) before creation."""
    STATES = [("pending", "pending"), ("accepted", "accepted"),
              ("declined", "declined"), ("blocked", "blocked")]
    sender = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="community_msgreqs_sent")
    recipient = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="community_msgreqs_recv")
    community = models.ForeignKey(Community, null=True, blank=True,
                                  on_delete=models.SET_NULL,
                                  related_name="message_requests")
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    first_ciphertext = models.TextField(blank=True, default="")   # opaque
    first_nonce = models.CharField(max_length=256, blank=True, default="")
    sender_key_id = models.CharField(max_length=64, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


# ===========================================================================
# Messenger STEP 3 — CHANNELS (one-to-many broadcast, NOT E2E / plaintext).
# Server authority: core/logic/msg_channel.py.
# ===========================================================================
class Channel(models.Model):
    """A broadcast channel. Content is PLAINTEXT + moderatable (NOT E2E). Public
    channels require the owner's public_surfaces_enabled switch. verified /
    verified_by / follower_count are SERVER-ONLY (never writable via profile edit;
    sanitize_profile_edit strips them)."""
    LIST = [("public", "public"), ("private", "private")]
    VERIF = [("none", "none"), ("pending", "pending"), ("verified", "verified")]
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="channels")
    name = models.CharField(max_length=80)
    handle = models.CharField(max_length=32, unique=True)
    description = models.CharField(max_length=500, blank=True, default="")
    photo_ref = models.CharField(max_length=256, blank=True, default="")
    category = models.CharField(max_length=20, default="other")
    language = models.CharField(max_length=8, default="other")   # bn|en|other
    list_visibility = models.CharField(max_length=8, choices=LIST, default="private")
    verified = models.BooleanField(default=False)                # SERVER-ONLY
    verified_by = models.ForeignKey(User, null=True, blank=True,
                                    on_delete=models.SET_NULL,
                                    related_name="channels_verified")  # operator
    verification_state = models.CharField(max_length=10, choices=VERIF, default="none")
    follower_count = models.IntegerField(default=0)              # == COUNT(followers)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class ChannelAdmin(models.Model):
    """A channel admin (mirrors admin_ids; cap MAX_ADMINS=20). OWNER appoints."""
    channel = models.ForeignKey(Channel, on_delete=models.CASCADE,
                                related_name="admins")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="channel_admin_of")
    added_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("channel", "user")]


class ChannelFollower(models.Model):
    """A follower. visibility DEFAULTS to count_only — a count_only follower is
    NEVER returned in any listing (serialize_follower_list) but ALWAYS counted.
    follower_count == COUNT(followers) incl. count_only."""
    VIS = [("show", "show"), ("count_only", "count_only")]
    channel = models.ForeignKey(Channel, on_delete=models.CASCADE,
                                related_name="followers")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="channel_follows")
    visibility = models.CharField(max_length=10, choices=VIS, default="count_only")
    muted = models.BooleanField(default=False)
    followed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("channel", "user")]


class ChannelPost(models.Model):
    """A channel post. PLAINTEXT, moderatable, NOT E2E — e2e is forced False with
    a DB CHECK so a post can NEVER be routed through the ciphertext relay.
    reactions is an AGGREGATE {emoji:count} only (never per-reactor rows)."""
    KINDS = [("text", "text"), ("photo", "photo"), ("video", "video"),
             ("link", "link"), ("poll", "poll")]
    channel = models.ForeignKey(Channel, on_delete=models.CASCADE,
                                related_name="posts")
    author = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="channel_posts")
    kind = models.CharField(max_length=8, choices=KINDS, default="text")
    e2e = models.BooleanField(default=False)   # CHECK forces False (not E2E)
    content_scheme = models.CharField(max_length=40, default="plaintext-moderatable-v1")
    text = models.TextField(blank=True, default="")
    media_refs = models.JSONField(default=list, blank=True)
    link_url = models.CharField(max_length=2048, blank=True, default="")
    poll = models.ForeignKey("ChannelPoll", null=True, blank=True,
                             on_delete=models.SET_NULL, related_name="posts")
    reactions = models.JSONField(default=dict, blank=True)   # {emoji: count}
    views = models.IntegerField(default=0)
    pinned = models.BooleanField(default=False)
    deleted = models.BooleanField(default=False)
    content_status = models.CharField(max_length=10, default="visible")  # moderation
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.CheckConstraint(check=models.Q(e2e=False),
                                   name="channel_post_not_e2e"),
        ]


class ChannelPoll(models.Model):
    """A channel poll. PLAINTEXT labels (channels are public). Tally BY INDEX."""
    channel = models.ForeignKey(Channel, on_delete=models.CASCADE,
                                related_name="polls")
    question = models.CharField(max_length=300, blank=True, default="")
    options = models.JSONField(default=list, blank=True)   # plaintext labels
    option_count = models.IntegerField(default=2)
    multi = models.BooleanField(default=False)
    closed = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)


class ChannelPollVote(models.Model):
    """One voter's choice set (indices). Re-vote replaces (apply_vote)."""
    poll = models.ForeignKey(ChannelPoll, on_delete=models.CASCADE,
                             related_name="votes")
    voter = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="channel_poll_votes")
    choices = models.JSONField(default=list, blank=True)   # list[int]
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("poll", "voter")]


class ChannelVerificationRequest(models.Model):
    """Audit of a verification request (request_verification: owner->pending)."""
    STATES = [("none", "none"), ("pending", "pending"), ("verified", "verified")]
    channel = models.ForeignKey(Channel, on_delete=models.CASCADE,
                                related_name="verification_requests")
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    requested_at = models.DateTimeField(auto_now_add=True)


# ===========================================================================
# Messenger STEP 3 — MODERATION + OWNER-ADMIN (public surfaces only).
# Server authority: core/logic/msg_moderation.py. Admin NEVER sees message
# contents or contacts (admin_user_projection allow-list).
# ===========================================================================
class ModerationReport(models.Model):
    """A member's report on a public target. `valid` comes from build_report."""
    reporter = models.ForeignKey(User, null=True, blank=True,
                                 on_delete=models.SET_NULL,
                                 related_name="moderation_reports")
    target_kind = models.CharField(max_length=12)   # channel/post/community/group/person
    target_id = models.CharField(max_length=64)
    categories = models.JSONField(default=list, blank=True)
    note = models.TextField(blank=True, default="")
    valid = models.BooleanField(default=False)
    # Report-last-5: the LAST <=5 DECRYPTED messages the REPORTER's device chose
    # to attach as context. The server NEVER decrypts — it only stores the
    # reporter-supplied plaintext snapshot (sanitize_report_snapshot). Empty for
    # public-surface reports (channel/community/group).
    snapshot = models.JSONField(default=list, blank=True)
    snapshot_source = models.CharField(max_length=20, blank=True, default="")  # 'reporter_device'
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["target_kind", "target_id"])]


class ModerationItem(models.Model):
    """The review-queue item for a moderated target (evaluate_report +
    apply_admin_action). legal_retention flags records kept for legally-required
    reporting of illegal content."""
    target_kind = models.CharField(max_length=12)
    target_id = models.CharField(max_length=64)
    categories = models.JSONField(default=list, blank=True)
    severe = models.BooleanField(default=False)
    content_status = models.CharField(max_length=10, default="visible")  # visible/hidden/removed/restored
    queue_state = models.CharField(max_length=14, default="queued")      # queued/under_appeal/resolved
    legal_retention = models.BooleanField(default=False)
    report_count = models.IntegerField(default=1)
    decision = models.CharField(max_length=16, blank=True, default="")
    opened_at = models.DateTimeField(auto_now_add=True)
    resolved_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-opened_at"]
        indexes = [models.Index(fields=["target_kind", "target_id"]),
                   models.Index(fields=["queue_state"])]


class ModerationAudit(models.Model):
    """APPEND-ONLY audit of every admin/appeal action (build_audit_entry). Never
    edited or deleted. Retained for legally-required reporting where flagged."""
    actor = models.ForeignKey(User, null=True, blank=True,
                              on_delete=models.SET_NULL,
                              related_name="moderation_audit")
    action = models.CharField(max_length=20)
    target_kind = models.CharField(max_length=12, blank=True, default="")
    target_id = models.CharField(max_length=64, blank=True, default="")
    reason = models.TextField(blank=True, default="")
    extra = models.JSONField(default=dict, blank=True)   # new_status/reset_sessions/queue_item/legal_retention
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-at"]


# ===========================================================================
# HOME NOTIFICATION CENTRE + DYNAMIC SUGGESTION ENGINE
#   Pure logic lives in core.logic.notif_centre + core.logic.suggestions.
#   These models are the persistence/sync layer the endpoints read/write.
#   (NO migration authored here — the integrator runs makemigrations.)
# ===========================================================================

class NotifEvent(models.Model):
    """A persisted notification-centre event ("something happened") — circle /
    community / channel requests + activity, family alerts, scam/watch alerts,
    business/CRM events, security logins, plan/points, app updates.

    CHAT MESSAGES ARE NEVER STORED HERE — they drive the My Circle unread count
    (CircleMessage.read_by), not the notification centre. The feed builder also
    drops any chat-typed row defensively.

    Reuses existing alert data where present (FamilyAlert, WatchHit, …) — the
    view merges those live rows with these persisted events into one feed, so
    this table only needs to hold events that have no other home."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="notif_events")
    type = models.CharField(max_length=24, default="app_update")  # notif_centre.NOTIF_TYPES
    title_bn = models.CharField(max_length=200, blank=True, default="")
    title_en = models.CharField(max_length=200, blank=True, default="")
    body_bn = models.TextField(blank=True, default="")
    body_en = models.TextField(blank=True, default="")
    route = models.CharField(max_length=40, blank=True, default="")
    seen = models.BooleanField(default=False)
    meta = models.JSONField(default=dict, blank=True)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-at"]
        indexes = [models.Index(fields=["user", "seen"]),
                   models.Index(fields=["user", "type"])]


class NotifSettings(models.Model):
    """Per-user, per-type notification toggles. `enabled` is a {type: bool} map;
    a missing type defaults to ON (opt-out). The feed + unseen count both
    respect this (notif_centre.type_enabled)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="notif_settings")
    enabled = models.JSONField(default=dict, blank=True)   # {type: bool}
    read_all_at = models.DateTimeField(null=True, blank=True)  # bulk mark-read watermark
    updated_at = models.DateTimeField(auto_now=True)


class SuggestionState(models.Model):
    """Per-user learn-from-use state for the home suggestion cards.

    taps/ignores  — {prompt_key_or_kind: count} tallies that raise/drop prompts.
    suppressed    — keys the user long-pressed "don't show".
    served_today  — the 4 keys last served + the date (so we know yesterday's set
                    for the no-repeat-two-days rule).
    All pure-engine inputs; no AI involved."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="suggestion_state")
    taps = models.JSONField(default=dict, blank=True)
    ignores = models.JSONField(default=dict, blank=True)
    suppressed = models.JSONField(default=list, blank=True)
    served_keys = models.JSONField(default=list, blank=True)   # last served 4
    served_date = models.DateField(null=True, blank=True)
    served_prev_keys = models.JSONField(default=list, blank=True)  # the day before
    updated_at = models.DateTimeField(auto_now=True)


class PaymentDebt(models.Model):
    """Payment / auto-pay LADDER debt row (SPEC v2.1 §21). A single table backs
    both tabs of the ladder UI; `kind` is fixed per collection (the two viewsets
    filter it). Money is INTEGER POISHA throughout (never float, never a stored
    balance — the engine custodies no money).

    The escalation `ladder` (ordered steps, each with offset_days / action /
    channel + stop_on_payment + has_payment_key) is stored as JSON so it matches
    the deterministic shape `core.logic.payment_ladder` validates and keeps the
    migration light. HARD RULES (enforced structurally, see the serializer):
      • Never hold money (no balance field).
      • Never auto-charge (serializer rejects any auto_charge/auto_pay step).
      • Paying a payable is KEY-GATED — the engine downgrades pay_key→pay_manual
        without the owner's own licensed payment key.
    """
    KINDS = [("receivable", "owed to me"), ("payable", "I owe")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="payment_debts")
    kind = models.CharField(max_length=10, choices=KINDS, default="receivable")
    party = models.CharField(max_length=120)
    amount_poisha = models.BigIntegerField(default=0)   # integer poisha (no float)
    paid_poisha = models.BigIntegerField(default=0)
    due_date = models.DateField(null=True, blank=True)
    recurring_days = models.PositiveIntegerField(default=0)  # >0 ⇒ repeating bill
    paused = models.BooleanField(default=False)
    # Ladder config as emitted by the builder; the engine reads
    # ladder["has_payment_key"] / ladder["steps"] / ladder["stop_on_payment"].
    ladder = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["due_date", "id"]


class FamilySharing(models.Model):
    """#67 SELECTIVE SHARING (SPEC v2.1 §21) — per-user, server-enforced consent
    store for which of the owner's info each family member may see. The pure
    decision/state logic lives in core.logic.family_sharing; this row only
    persists the owner's choices + an audit trail so the server can enforce
    default-deny before serializing any shared field.

    grants — {str(member_id): [item, ...]} (JSON can't key on int; the logic
             layer normalizes to int). Default is SHARE NOTHING.
    audit  — newest-first list of build_audit_entry(...) rows (capped)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="family_sharing")
    grants = models.JSONField(default=dict, blank=True)   # {member_id: [items]}
    audit = models.JSONField(default=list, blank=True)     # [{action, at, ...}]
    updated_at = models.DateTimeField(auto_now=True)


class AdminFlagState(models.Model):
    """#178 COST KILL-SWITCH & FEATURE FLAGS (SPEC v2.1 §21) — platform-wide,
    owner-only. A single row (key='global') persists the current flag state +
    an append-only audit trail. All validation / confirm-gate / audit-entry
    construction lives in core.logic.admin_flags (pure); this row only stores
    what that engine returns, so the owner's flips survive restarts.

    state — {flag_id: bool}; normalized by the logic layer against the CATALOG.
    audit — newest-first list of make_audit_entry(...) rows (capped)."""
    key = models.CharField(max_length=32, unique=True, default="global")
    state = models.JSONField(default=dict, blank=True)     # {flag_id: bool}
    audit = models.JSONField(default=list, blank=True)     # [{flag, old, new, ...}]
    updated_at = models.DateTimeField(auto_now=True)


class PricingConfig(models.Model):
    """Business Model (Build 1 of N) — SERVER-SIDE PRICING config, owner-only.

    A single row (key='global') holds every NUMBER the business runs on: plan
    prices + included credits, annual discount %, the credit-cost-per-action map,
    the margin target and the currency basis. Mirrors the AdminFlagState
    single-row pattern, but it HOLDS MONEY MATH — which AdminFlagState/admin_flags
    is contractually barred from ("NEVER SERVER-SIDE PRICING"). All defaults,
    normalization, validation and the auto-reprice math live in the pure
    core.logic.pricing engine; this row only persists what it returns so the
    owner's price edits survive restarts and are served to the app via /plans.

    data  — the pricing dict; shape + defaults owned by core.logic.pricing.
    audit — newest-first list of pricing.make_audit_entry(...) rows (capped)."""
    key = models.CharField(max_length=32, unique=True, default="global")
    data = models.JSONField(default=dict, blank=True)
    audit = models.JSONField(default=list, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


# ===========================================================================
# Business Model — Build 2 of N  (credit packs + ad wallet + daily profit guard)
# ===========================================================================
class CreditPurchase(models.Model):
    """A credit-pack top-up. ONE row per confirmed purchase. Credits are granted
    atomically only on a confirmed payment (status='confirmed'); a 'pending' row
    exists while awaiting a payment provider and NEVER grants credits. `expires_at`
    is 12 months after the grant — surfaced as expiry buckets in /credits/history.

    HONESTY: a pending purchase with no configured provider grants NOTHING; we
    never fake money or grant credits without a real payment when one is required."""
    STATUS = [("pending", "pending"), ("confirmed", "confirmed"),
              ("failed", "failed")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="credit_purchases")
    pack_id = models.CharField(max_length=16)
    price_bdt = models.IntegerField(default=0)
    credits = models.IntegerField(default=0)
    provider = models.CharField(max_length=20, blank=True, default="")  # bkash|play_billing|...
    status = models.CharField(max_length=10, choices=STATUS, default="pending")
    txn_ref = models.CharField(max_length=120, blank=True, default="")
    granted = models.BooleanField(default=False)
    expires_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    confirmed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["user", "status"]),
                   models.Index(fields=["user", "expires_at"])]


class AdWallet(models.Model):
    """Ad-funded wallet for FREE users. Balance is in *paisa* (1 credit == ৳1 ==
    100 paisa) so sub-credit ad rewards accumulate honestly before a whole credit
    is spendable. `spendable_credits()` = balance_paisa // 100. Rewarded/app-open/
    interstitial impressions credit this at <=70% of a configurable eCPM floor."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="ad_wallet")
    balance_paisa = models.BigIntegerField(default=0)   # 100 paisa == 1 credit
    updated_at = models.DateTimeField(auto_now=True)

    def spendable_credits(self):
        return int(self.balance_paisa // 100)


class AdEvent(models.Model):
    """One ad impression. Append-only; used for server-side cap + fraud math
    (per-user / per-device frequency). `credited_paisa` is what we paid into the
    wallet for it (0 if rejected / fraud / caps hit)."""
    KINDS = [("app_open", "app open"), ("rewarded", "rewarded"),
             ("native", "native"), ("interstitial", "interstitial")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="ad_events")
    kind = models.CharField(max_length=14, choices=KINDS)
    device_id = models.CharField(max_length=64, blank=True, default="")
    ad_id = models.CharField(max_length=80, blank=True, default="")
    credited_paisa = models.IntegerField(default=0)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-at"]
        indexes = [models.Index(fields=["user", "kind", "at"]),
                   models.Index(fields=["device_id", "kind", "at"])]


class DailyLedger(models.Model):
    """Append-only DAILY P&L row (one per local date). The profit guard compares
    trailing-7-day variable cost against <=60% of trailing-7-day NET revenue.

    revenue_by_source — {ads, subs, packs, commissions} in ৳.
    variable_cost_by_type — {ai, sms, ivr, video, storage} in ৳ (AI USD converted
    via cfg.usd_bdt at record time)."""
    date = models.DateField(unique=True)
    revenue_by_source = models.JSONField(default=dict, blank=True)
    variable_cost_by_type = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-date"]


class StorageUsage(models.Model):
    """Business Model (Build 3) — per-user cloud STORAGE meter + quota basis.

    One row per user. `used_bytes` is the running total of RETAINED server-side
    media that counts toward the plan quota: vault documents, the profile avatar,
    messenger/circle status media blobs, and encrypted chat backups. The quota
    itself is NOT stored here — it comes from the user's EFFECTIVE plan via
    PricingConfig (Free 1GB / Premium 5GB / Business 15GB), so an owner price edit
    changes every user's quota with no migration.

    WhatsApp model: cloud backups + retained media count here; delivered-and-
    expired media is pruned elsewhere (the status-expiry / purge sweep decrements
    used_bytes via billing.add_storage with a negative delta). Recompute from the
    live rows with `manage.py storage_recompute` so the meter never drifts.

    SAFETY NOTE: text messages, voice/video calls and ALL safety features (SOS,
    safe-journey, anti-theft captured photos, health reminders) are NEVER counted
    or blocked by this meter — only bulk media/file/backup uploads are gated."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="storage_usage")
    used_bytes = models.BigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)


class ChatOrganiseState(models.Model):
    """#87 CHAT ORGANISE (SPEC v2.1 §21) — PER-USER per-chat pin/archive/mute.
    The viewer's own organisation; it never leaks to or affects the peer and
    carries NO message content (E2E ciphertext-only preserved). All enforcement
    (pin cap, archive-clears-pin, mute expiry) runs via core.logic.msg_organise;
    this row just persists the result so organise survives a reload / new device.
    """
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="chat_organise")
    chat_kind = models.CharField(max_length=16, default="member")  # member|group|community|channel
    chat_id = models.CharField(max_length=64)                      # opaque chat ref
    pinned = models.BooleanField(default=False)
    pin_at = models.DateTimeField(null=True, blank=True)
    archived = models.BooleanField(default=False)
    mute_until = models.DateTimeField(null=True, blank=True)       # null + muted marker == "always"
    muted_duration = models.CharField(max_length=8, null=True, blank=True)  # 8h|1w|always
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ("user", "chat_kind", "chat_id")


class PaCollectionItem(models.Model):
    """PA Secretary Mode (SPEC v2.1 §14) generic per-user collection row. One
    flexible store backs the PA REST collections (visitors #105, followups #108,
    schedule #103) — each row is {id, ...data}. The pure decision logic lives in
    core.logic.pa_* ; this only persists the owner's entries. (Delegate scopes
    #111 and personal tasks #115 are device-local in the client; their server
    enforcement seam is documented, not yet stored here.)"""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="pa_items")
    collection = models.CharField(max_length=24)   # visitors|followups|schedule
    data = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["user", "collection"])]


# ===========================================================================
# Stolen-While-Unlocked Protection (Apple Stolen-Device-Protection style)
#
#   SERVER IS THE SOURCE OF TRUTH. A system/factory reset on the device can
#   never change ownership or clear the armed/frozen/status state — those live
#   here and only change through the core.views_security endpoints (which gate
#   every sensitive action behind PIN + trusted-location + delay/approval).
#   The native anti-theft engine only *reports signals*; it cannot grant
#   itself any capability the server has not agreed to.
# ===========================================================================

class ProtectedPhone(models.Model):
    """One protected handset, keyed to its owner. There is one *primary* row
    per owner (treat the earliest-created as primary); kept as a ForeignKey
    (not OneToOne) so a future multi-device story is a non-breaking change."""
    STATUS = [("owned", "owned"),
              ("reported_stolen", "reported_stolen"),
              ("transfer_pending", "transfer_pending"),
              ("transferred", "transferred")]
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="protected_phones")
    imei1 = models.CharField(max_length=32, blank=True, default="")
    imei2 = models.CharField(max_length=32, blank=True, default="")
    model_name = models.CharField(max_length=80, blank=True, default="")
    # Server-side Security-PIN hash (Django make_password). The raw PIN is
    # NEVER stored or logged — see views_security.
    security_pin_hash = models.CharField(max_length=256, blank=True, default="")
    armed = models.BooleanField(default=False)
    frozen_until = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=20, choices=STATUS, default="owned")
    gd_number = models.CharField(max_length=60, blank=True, default="")  # police General Diary
    wrong_pin_count = models.IntegerField(default=0)
    family_approver = models.ForeignKey("CircleMember", null=True, blank=True,
                                        on_delete=models.SET_NULL,
                                        related_name="approver_for_phones")
    signals = models.JSONField(default=list, blank=True)  # [{kind, at}]
    # --- Batch 5: lost/stolen server-side (lost-mode + went-dark heartbeat) ---
    # Lost mode is PROTECTIVE: the owner (or a helping family member) can turn it
    # ON with no delay. Turning it OFF is the 'turn_off_lost' sensitive action and
    # MUST go through POST security/action (the Section-8 gate) — never directly.
    lost_mode = models.BooleanField(default=False)
    lost_message = models.TextField(blank=True, default="")   # shown on the lost device
    lost_contact = models.CharField(max_length=120, blank=True, default="")  # how to reach owner
    lost_reward = models.CharField(max_length=160, blank=True, default="")
    lost_since = models.DateTimeField(null=True, blank=True)
    # Heartbeat: the native engine phones home every heartbeat_interval_min; we
    # keep only the last location on the row (full trail lives in PhoneHeartbeat,
    # pruned to the retention cap). went_dark = no heartbeat for a long time.
    last_heartbeat_at = models.DateTimeField(null=True, blank=True)
    last_lat = models.FloatField(null=True, blank=True)
    last_lng = models.FloatField(null=True, blank=True)
    went_dark_alerted = models.BooleanField(default=False)
    heartbeat_interval_min = models.IntegerField(default=10)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["created_at"]


# Keep server-side location history bounded (privacy — mirror Journey's cap).
HEARTBEAT_RETENTION_HOURS = 24


class PhoneHeartbeat(models.Model):
    """One "I'm alive, here's where" ping from the native engine. We retain only
    the recent window (HEARTBEAT_RETENTION_HOURS) — old pings are hard-deleted so
    we never hoard a location history (same discipline as Journey retention)."""
    phone = models.ForeignKey(ProtectedPhone, on_delete=models.CASCADE,
                              related_name="heartbeats")
    lat = models.FloatField(null=True, blank=True)
    lng = models.FloatField(null=True, blank=True)
    battery = models.IntegerField(null=True, blank=True)
    network = models.CharField(max_length=16, blank=True, default="")  # wifi|mobile|none
    at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-at"]

    @classmethod
    def prune(cls, phone, hours=HEARTBEAT_RETENTION_HOURS):
        """Hard-delete this phone's heartbeats older than the retention cap."""
        from django.utils import timezone as _tz
        from datetime import timedelta as _td
        cutoff = _tz.now() - _td(hours=hours)
        cls.objects.filter(phone=phone, at__lt=cutoff).delete()


class CapturedEvent(models.Model):
    """Store-and-forward evidence the device captured while lost/stolen (intruder
    photo, SIM change, failed unlock, etc.). Owner-only retrieval via an
    auth-checked view — the photo is NEVER served publicly (vault-file pattern)."""
    KINDS = [("intruder_photo", "intruder_photo"), ("sim_change", "sim_change"),
             ("failed_unlock", "failed_unlock"), ("low_battery_loc", "low_battery_loc"),
             ("airplane_guard", "airplane_guard")]
    phone = models.ForeignKey(ProtectedPhone, on_delete=models.CASCADE,
                              related_name="captured_events")
    kind = models.CharField(max_length=20, choices=KINDS)
    data = models.JSONField(default=dict, blank=True)  # {new_sim, operator, lat, lng, ...}
    photo = models.FileField(upload_to="theft/", null=True, blank=True)
    at = models.DateTimeField(null=True, blank=True)  # when the device captured it
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class PendingSensitiveAction(models.Model):
    """A sensitive action that could not run immediately (untrusted location /
    approver required). It sits here delayed or awaiting approval so the real
    owner has a window to cancel it ("This wasn't me")."""
    ACTIONS = [("sell_transfer", "sell_transfer"), ("disarm", "disarm"),
               ("remove_admin", "remove_admin"), ("change_contacts", "change_contacts"),
               ("turn_off_lost", "turn_off_lost"), ("change_pin", "change_pin"),
               ("export_data", "export_data")]
    STATES = [("pending", "pending"), ("awaiting_approval", "awaiting_approval"),
              ("cancelled", "cancelled"), ("applied", "applied"), ("rejected", "rejected")]
    phone = models.ForeignKey(ProtectedPhone, on_delete=models.CASCADE,
                              related_name="pending_actions")
    action = models.CharField(max_length=20, choices=ACTIONS)
    requested_at = models.DateTimeField(auto_now_add=True)
    effective_at = models.DateTimeField(null=True, blank=True)
    state = models.CharField(max_length=20, choices=STATES, default="pending")
    cancel_token = models.CharField(max_length=64, blank=True, default="", db_index=True)
    approver = models.ForeignKey("CircleMember", null=True, blank=True,
                                 on_delete=models.SET_NULL,
                                 related_name="pending_action_approvals")
    payload = models.JSONField(default=dict, blank=True)
    note = models.TextField(blank=True, default="")

    class Meta:
        ordering = ["-requested_at"]


class AccountDeletionRequest(models.Model):
    """A scheduled "delete my profile & all data" request (Play-Store compliant).

    Deleting the whole account is a SENSITIVE ACTION (Section 8): it is gated by
    password + OTP + the Assisto Security PIN, blocked while a theft signal is
    active, and delayed. The account is NOT touched when this row is created —
    it stays fully RECOVERABLE until effective_at. Only the purge_deletions
    management command (cron), running after effective_at on a still-pending
    request, performs the real, complete, cascading hard delete. A thief can
    never silently wipe the owner's data: the owner (and every trusted contact)
    gets an instant notice with a one-tap cancel token, and 7 days to undo it.

    effective_at = max(now + 7-day grace, Section-8 24h delay when untrusted) so
    the grace period never shortens the anti-theft delay.
    """
    STATE_PENDING = "pending"
    STATE_CANCELLED = "cancelled"
    STATE_COMPLETED = "completed"
    STATES = [(STATE_PENDING, "pending"),
              (STATE_CANCELLED, "cancelled"),
              (STATE_COMPLETED, "completed")]

    # OneToOne -> at most one active request per user; re-requesting reuses/
    # refreshes the same row.
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="deletion_request")
    requested_at = models.DateTimeField(auto_now_add=True)
    effective_at = models.DateTimeField()
    state = models.CharField(max_length=12, choices=STATES, default=STATE_PENDING)
    # Random, URL-safe token for the "Cancel — this wasn't me" one-tap link.
    cancel_token = models.CharField(max_length=64, blank=True, default="",
                                    db_index=True)
    export_downloaded = models.BooleanField(default=False)
    reason = models.TextField(blank=True, default="")

    class Meta:
        ordering = ["-requested_at"]


# ===========================================================================
# Anti-theft Batch 4 — stolen-IMEI registry + used-phone check + sell transfer
#
# SERVER IS THE SOURCE OF TRUTH. A factory reset on the handset can NEVER move
# ownership or clear a stolen report; ownership only moves through sale/accept
# (SaleReceipt -> accepted). A phone with an active StolenReport or a recent
# theft signal can never be transfer-accepted.
# ===========================================================================

def _normalize_imei(raw):
    """Digits-only normalization so '35-980123 / 456' matches '35980123456'."""
    return "".join(ch for ch in str(raw or "") if ch.isdigit())


class StolenReport(models.Model):
    """An owner (or anyone authed) flags an IMEI as stolen, backed by a police
    General Diary number. A check against this IMEI then warns the buyer. The
    reporter's identity is NEVER revealed on a check — only coarse area/time."""
    STATUS = [("active", "active"), ("recovered", "recovered")]
    imei = models.CharField(max_length=32, db_index=True)  # normalized digits
    reporter = models.ForeignKey(User, on_delete=models.CASCADE,
                                 related_name="stolen_reports")
    gd_number = models.CharField(max_length=60)  # required, non-blank (enforced in view)
    model_name = models.CharField(max_length=80, blank=True, default="")
    # COARSE text only, e.g. "Dhaka, Mirpur" — never a precise location.
    area = models.CharField(max_length=120, blank=True, default="")
    status = models.CharField(max_length=12, choices=STATUS, default="active")
    created_at = models.DateTimeField(auto_now_add=True)
    recovered_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["imei"])]


class ImeiCheckLog(models.Model):
    """One row per used-phone check. Audit trail + the source for the per-user
    abuse rate-limit (count in the last hour)."""
    imei = models.CharField(max_length=32, db_index=True)
    checker = models.ForeignKey(User, null=True, blank=True,
                                on_delete=models.SET_NULL,
                                related_name="imei_checks")
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-at"]


class SaleReceipt(models.Model):
    """A sell-my-phone transfer. The QR encodes `token`. Ownership moves only
    when the BUYER accepts (state -> accepted). authorize is the sensitive step
    and re-checks the theft signal as the authoritative server-side guard."""
    STATES = [("draft", "draft"), ("authorized", "authorized"),
              ("accepted", "accepted"), ("cancelled", "cancelled")]
    seller = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="sales_as_seller")
    imei = models.CharField(max_length=32, db_index=True)  # normalized digits
    model_name = models.CharField(max_length=80, blank=True, default="")
    price = models.IntegerField(default=0)  # taka
    buyer_name = models.CharField(max_length=120, blank=True, default="")
    buyer_nid = models.CharField(max_length=40, blank=True, default="")
    token = models.CharField(max_length=64, unique=True)  # random; QR payload
    state = models.CharField(max_length=12, choices=STATES, default="draft")
    buyer_user = models.ForeignKey(User, null=True, blank=True,
                                   on_delete=models.SET_NULL,
                                   related_name="sales_as_buyer")
    created_at = models.DateTimeField(auto_now_add=True)
    accepted_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]


# ===========================================================================
# AI CHAT (Part 3) — ChatGPT-like multi-turn chat with history.
#
#   A ChatSession is one conversation thread; ChatMessage rows are its turns.
#   The reply is produced by core/ai.py (keyed, charged, full-context) or, with
#   NO key / kill-switch active, by the deterministic no-key Brain (free, honest,
#   over the user's OWN data + help KB). Nothing here ever fabricates a fact.
# ===========================================================================

class ChatSession(models.Model):
    """One ChatGPT-style conversation thread owned by a user. The title is
    auto-derived from the first user message (trimmed) unless the user renames
    it (`title_custom` then stays True so the derive never clobbers it)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="chat_sessions")
    title = models.CharField(max_length=120, blank=True, default="")
    title_custom = models.BooleanField(default=False)
    pinned = models.BooleanField(default=False)
    archived = models.BooleanField(default=False)
    # "home" = the home agent chat (actions + cards); "ai" = Assisto AI chat.
    # Both show in the sidebar history; tapping reopens it in the right place.
    SOURCES = [("ai", "ai"), ("home", "home")]
    source = models.CharField(max_length=8, choices=SOURCES, default="ai")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-pinned", "-updated_at"]
        indexes = [models.Index(fields=["user", "-pinned", "-updated_at"])]

    def derive_title(self, first_user_text):
        """Set the title from the first user message (~40 chars) unless the user
        has renamed it. No-op once `title_custom` is True."""
        if self.title_custom:
            return
        t = (first_user_text or "").strip().replace("\n", " ")
        if not t:
            return
        self.title = (t[:40].rstrip() + "…") if len(t) > 40 else t


class ChatMessage(models.Model):
    """One turn in a ChatSession. `meta` carries non-content extras (tokens,
    model, cards, credits charged, level/handler for Brain answers)."""
    ROLES = [("user", "user"), ("assistant", "assistant"), ("system", "system")]
    session = models.ForeignKey(ChatSession, on_delete=models.CASCADE,
                                related_name="messages")
    role = models.CharField(max_length=10, choices=ROLES)
    text = models.TextField(blank=True, default="")
    meta = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]
        indexes = [models.Index(fields=["session", "created_at"])]


# ===========================================================================
# CCTV / SHOP LOSS-PREVENTION (Business, Part 4) — INGEST + ALERT backend.
#
# HARD SAFETY RULES baked into the schema:
#   * NO VIDEO is ever stored on our server. ShopEvent has a SINGLE small
#     ImageField (`snapshot`) and nothing else — no clip, no stream, no frames.
#   * The snapshot is auto-deleted after the site's retention window
#     (shop_prune_snapshots management command).
#   * The edge device / Shop Box does the vision detection; we only receive
#     SIGNALS (what fired) + at most one snapshot. No heavy AI runs here.
#   * Alerts are produced by shop_guard.combine() using COMBINED signals only;
#     the human-facing wording is always "please check", never "theft".
#
# AUTH: devices authenticate with a per-SHOP ENROLLMENT TOKEN (ShopSite /
# ShopCamera tokens), not a user login. Owner endpoints use normal Token auth +
# the owner/business gate.
# ===========================================================================

def _gen_token(nbytes=24):
    """A URL-safe random enrollment/camera token."""
    import secrets
    return secrets.token_urlsafe(nbytes)


class ShopSite(models.Model):
    """One physical shop/site an owner is protecting. Devices enrol against its
    `enrollment_token` (per-shop, not a user login). Retention is owner-settable
    0–30 days; snapshots older than that are pruned."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="shop_sites")
    name = models.CharField(max_length=120, blank=True, default="")
    enrollment_token = models.CharField(max_length=64, unique=True,
                                        default=_gen_token, db_index=True)
    # 0 = keep no snapshot bytes at all; 30 = max. Default 7 days.
    snapshot_retention_days = models.PositiveSmallIntegerField(default=7)
    created = models.DateTimeField(auto_now_add=True)
    # ---- a2-cctv ----
    # shop opening hours {"open": "HH:MM", "close": "HH:MM"} (local); a camera
    # without its own hours falls back to these. {} = no hours configured.
    hours = models.JSONField(default=dict, blank=True)
    # mirror Assisto POS sales/voids/discounts into this site's ShopPosEvent
    pos_link = models.BooleanField(default=True)
    last_seen = models.DateTimeField(null=True, blank=True)  # any device heartbeat

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["owner", "-created"])]


class ShopCamera(models.Model):
    """A camera at a site. `kind` is how it reaches us: an edge device posting to
    the webhook, or the Shop Box. `zone_config` holds polygons like the cash_zone
    the edge uses for detection. The 'Business includes 4 edge cameras; more =
    credits' cap is enforced at CREATE time in the view (not in the schema)."""
    KINDS = [("edge_webhook", "edge webhook"), ("shopbox", "Shop Box")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="cameras")
    name = models.CharField(max_length=120, blank=True, default="")
    kind = models.CharField(max_length=16, choices=KINDS, default="edge_webhook")
    camera_token = models.CharField(max_length=64, unique=True,
                                    default=_gen_token, db_index=True)
    zone_config = models.JSONField(default=dict, blank=True)  # e.g. {"cash_zone": [...]}
    enabled = models.BooleanField(default=True)
    created = models.DateTimeField(auto_now_add=True)
    # ---- a2-cctv ----
    last_seen = models.DateTimeField(null=True, blank=True)    # heartbeat / webhook
    # an EXTRA (beyond-included) camera is paid through this time; the daily
    # shop_camera_billing command renews it for 30 days or disables it.
    billed_until = models.DateTimeField(null=True, blank=True)
    # what the device reported on heartbeat: {"caps": ["live"], "platform", "version"}
    device_info = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["created", "id"]
        indexes = [models.Index(fields=["site", "enabled"])]


class ShopEvent(models.Model):
    """ONE loss-prevention event the guard decided to surface. Carries the
    combined `signals` that fired, a shown `confidence`, and AT MOST ONE small
    snapshot (auto-deleted after retention). NEVER a video. `pos_matched` records
    whether a correlating POS row was found. The owner marks checked/false_alarm."""
    TYPES = [
        ("hand_in_cash_zone", "hand in cash zone"),
        ("drawer_open", "drawer open"),
        ("void_spike", "void spike"),
        ("refund_spike", "refund spike"),
        ("discount_spike", "discount spike"),
        ("eod_mismatch", "end-of-day mismatch"),
        ("motion", "motion"),
        ("after_hours", "after hours"),
        ("pose_possible", "pose (possible)"),
    ]
    STATUS = [("open", "open"), ("checked", "checked"),
              ("false_alarm", "false alarm")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="events")
    camera = models.ForeignKey(ShopCamera, on_delete=models.CASCADE,
                               related_name="events", null=True, blank=True)
    type = models.CharField(max_length=20, choices=TYPES)
    signals = models.JSONField(default=dict, blank=True)  # the combined inputs that fired
    confidence = models.FloatField(default=0.0)           # 0..1, always shown
    # the ONE small image we may keep. NO video field exists, ever.
    snapshot = models.ImageField(upload_to="shop/", null=True, blank=True)
    pos_matched = models.BooleanField(default=False)
    possible = models.BooleanField(default=False)   # low-confidence "possible" (lone pose)
    status = models.CharField(max_length=12, choices=STATUS, default="open")
    created = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["site", "-created"]),
                   models.Index(fields=["site", "status"]),
                   models.Index(fields=["site", "type"])]


class ShopPosEvent(models.Model):
    """A point-of-sale signal (from the shop's POS or the Shop Box) used to
    CORRELATE with camera events — e.g. a hand in the cash zone with NO matching
    `sale` within ±N seconds is suspicious. Camera-only sites simply have none
    of these, and the guard falls back to zone/motion/after-hours logic."""
    KINDS = [("sale", "sale"), ("void", "void"), ("refund", "refund"),
             ("discount", "discount"), ("drawer_open", "drawer open")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="pos_events")
    kind = models.CharField(max_length=12, choices=KINDS)
    amount = models.BigIntegerField(default=0)   # poisha (or 0 for drawer_open)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-at"]
        indexes = [models.Index(fields=["site", "kind", "at"]),
                   models.Index(fields=["site", "at"])]


# ===========================================================================
# ---- a2-cctv ---- CCTV Part 4: live-view SIGNALING + end-of-day cash check.
#
# ShopLiveSession carries ONLY WebRTC signaling (SDP offer/answer + ICE
# candidates) between the owner's phone and the shop device. The media flows
# peer-to-peer (or through TURN when P2P fails); it NEVER touches this server
# and is NEVER recorded anywhere. Sessions are hard-capped (10 min default).
# ===========================================================================

class ShopLiveSession(models.Model):
    STATUS = [("pending", "pending"), ("active", "active"),
              ("ended", "ended"), ("expired", "expired")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="live_sessions")
    camera = models.ForeignKey(ShopCamera, on_delete=models.CASCADE,
                               related_name="live_sessions")
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="shop_live_sessions")
    status = models.CharField(max_length=8, choices=STATUS, default="pending")
    # [{seq, side: owner|device, kind: offer|answer|candidate|bye, payload}]
    messages = models.JSONField(default=list, blank=True)
    seq = models.PositiveIntegerField(default=0)
    created = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    answered_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    end_reason = models.CharField(max_length=24, blank=True, default="")
    relayed = models.BooleanField(default=False)     # client-reported: TURN pair used
    seconds = models.PositiveIntegerField(default=0)
    charged_credits = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["camera", "status"]),
                   models.Index(fields=["owner", "-created"])]


class ShopEodCheck(models.Model):
    """One end-of-day cash count vs Assisto POS cash sales. Money in POISHA."""
    STATUS = [("ok", "ok"), ("short", "short"), ("over", "over")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="eod_checks")
    day = models.DateField()
    counted = models.BigIntegerField(default=0)
    expected = models.BigIntegerField(default=0)
    opening_float = models.BigIntegerField(default=0)
    cash_sales = models.BigIntegerField(default=0)
    tolerance = models.BigIntegerField(default=0)
    status = models.CharField(max_length=6, choices=STATUS, default="ok")
    note = models.CharField(max_length=200, blank=True, default="")
    event = models.ForeignKey(ShopEvent, null=True, blank=True,
                              on_delete=models.SET_NULL, related_name="+")
    created_by = models.ForeignKey(User, null=True, blank=True,
                                   on_delete=models.SET_NULL, related_name="+")
    created = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["site", "-created"])]


# ====================================================================
# ---- m1-messenger ---- per-user chat prefs, group timers, account settings,
# server-built exports. Message BODIES stay E2E ciphertext; nothing here holds
# plaintext (two-step PIN + OTP are Django password hashes).
# ===========================================================================
class MsgChatPref(models.Model):
    """The VIEWER's own per-chat prefs (never shared with the peer):
    favourite, theme/wallpaper, the clear-chat marker (messages created at or
    before `cleared_at` are hidden from this user only) and, for 1:1 chats,
    when the disappearing timer was switched on (only later messages expire)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="msg_chat_prefs")
    chat_kind = models.CharField(max_length=10, default="member")  # member|group
    chat_id = models.CharField(max_length=64)
    favourite = models.BooleanField(default=False)
    theme = models.CharField(max_length=24, blank=True, default="")
    wallpaper = models.CharField(max_length=40, blank=True, default="")
    cleared_at = models.DateTimeField(null=True, blank=True)
    disappearing_since = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "chat_kind", "chat_id")]


class MsgGroupTimer(models.Model):
    """Group-wide disappearing-messages timer (applies to every member's
    messages sent at/after `since`). Enforced by `manage.py purge_disappearing`
    and by the group message read, which never returns an expired row."""
    group = models.OneToOneField("CircleGroup", on_delete=models.CASCADE,
                                 related_name="m1_timer")
    disappearing_sec = models.IntegerField(default=0)
    since = models.DateTimeField(null=True, blank=True)
    set_by = models.ForeignKey(User, null=True, blank=True,
                               on_delete=models.SET_NULL, related_name="+")
    updated_at = models.DateTimeField(auto_now=True)


class MsgUserSettings(models.Model):
    """Messenger account settings, one row per user. Notification / call /
    auto-download prefs are enforced server-side where they apply (push hooks,
    call placement). The two-step PIN and a pending change-number code are
    stored ONLY as Django password hashes."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="msg_settings")
    notifications = models.JSONField(default=dict, blank=True)
    calls = models.JSONField(default=dict, blank=True)
    auto_download = models.JSONField(default=dict, blank=True)
    two_step_enabled = models.BooleanField(default=False)
    two_step_hash = models.CharField(max_length=128, blank=True, default="")
    recovery_email = models.EmailField(blank=True, default="")
    two_step_failures = models.IntegerField(default=0)
    two_step_locked_until = models.DateTimeField(null=True, blank=True)
    pending_phone = models.CharField(max_length=24, blank=True, default="")
    pending_code_hash = models.CharField(max_length=128, blank=True, default="")
    pending_expires = models.DateTimeField(null=True, blank=True)
    pending_attempts = models.IntegerField(default=0)
    pending_sent_at = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class MsgExport(models.Model):
    """A server-built group export file (what the server legitimately holds:
    metadata + the requester's OWN ciphertext envelopes). Served only through
    a signed, expiring media link; purged after `expires_at`."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="msg_exports")
    group = models.ForeignKey("CircleGroup", null=True, blank=True,
                              on_delete=models.SET_NULL, related_name="+")
    file = models.FileField(upload_to="msg_exports/")
    message_count = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()

class FamExpense(models.Model):
    """Family accounting (#61): one shared expense in the OWNER's household
    ledger. Members are 'self' (the owner) or the owner's FamilyMember ids,
    stored as strings. All money is INTEGER POISHA. A recorded settle-up is a
    row with kind='settlement' (payer=from, one share to=amount)."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="fam_expenses")
    kind = models.CharField(max_length=12, default="expense")  # expense|settlement
    payer = models.CharField(max_length=24)
    total_poisha = models.BigIntegerField(default=0)
    category = models.CharField(max_length=20, default="other")
    mode = models.CharField(max_length=8, default="equal")
    note = models.CharField(max_length=200, blank=True, default="")
    date = models.DateField()
    shares = models.JSONField(default=list, blank=True)  # [{member, share}]
    shared = models.BooleanField(default=True)
    ai_captured = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-date", "-id"]


class FamPool(models.Model):
    """Monthly family budget pool target (poisha) + contributions."""
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="fam_pools")
    month = models.CharField(max_length=7)  # YYYY-MM
    target_poisha = models.BigIntegerField(default=0)
    contributions = models.JSONField(default=list, blank=True)  # [{member, amount, at}]

    class Meta:
        unique_together = [("owner", "month")]


class NotifDismissal(models.Model):
    """'Done' on a notification-centre item that has no done flag of its own
    (meeting / appointment / birthday occurrence): hides that occurrence."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="notif_dismissals")
    item_id = models.CharField(max_length=80)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("user", "item_id")]


class JourneyPoint(models.Model):
    """A Safe-Journey location fix for the watcher timeline. Deleted with the
    journey's privacy expiry (never kept past Journey.expires_at)."""
    journey = models.ForeignKey("Journey", on_delete=models.CASCADE,
                                related_name="points")
    lat = models.FloatField()
    lng = models.FloatField()
    battery = models.IntegerField(null=True, blank=True)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["at"]
# ---- /m1-messenger ----
# ---- o1-otp ---- OTP (SMS one-time codes), purpose-bound proofs, and the
# phone-verified marker. Codes are NEVER stored in plaintext: only an
# HMAC-SHA256(SECRET_KEY, salt|phone|purpose|code). See core/otp.py.
class OtpChallenge(models.Model):
    phone = models.CharField(max_length=24, db_index=True)     # +8801XXXXXXXXX
    purpose = models.CharField(max_length=20)
    code_hash = models.CharField(max_length=64)
    salt = models.CharField(max_length=32)
    created_at = models.DateTimeField(default=timezone.now, db_index=True)
    expires_at = models.DateTimeField()
    attempts = models.PositiveSmallIntegerField(default=0)
    consumed_at = models.DateTimeField(null=True, blank=True)
    locked_until = models.DateTimeField(null=True, blank=True)
    ip = models.CharField(max_length=64, blank=True, default="", db_index=True)
    device_id = models.CharField(max_length=128, blank=True, default="", db_index=True)
    sent = models.BooleanField(default=False)
    detail = models.CharField(max_length=200, blank=True, default="")

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["phone", "purpose", "-created_at"])]


class OtpProof(models.Model):
    """Short-lived, single-use proof that `phone` passed an OTP for `purpose`.
    Only the SHA-256 of the raw token is stored."""
    token_hash = models.CharField(max_length=64, unique=True)
    phone = models.CharField(max_length=24)
    purpose = models.CharField(max_length=20)
    created_at = models.DateTimeField(default=timezone.now)
    expires_at = models.DateTimeField()
    used_at = models.DateTimeField(null=True, blank=True)


class PhoneVerification(models.Model):
    """A user's phone number was proven by OTP (append-only marker; the User
    model itself is untouched)."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="phone_verification")
    phone = models.CharField(max_length=24)
    verified_at = models.DateTimeField(default=timezone.now)
# ---- /o1-otp ----

# ===========================================================================
# ---- v1-vehicle ---- Vehicle tracking (extends anti-theft Batch 7)
#
# A VehicleTracker is a hardware GPS tracker (Concox GT06 / Teltonika FMxxx)
# paired by IMEI to ONE owner, optionally linked to the owner's existing
# "My Vehicles" record (PaCollectionItem collection='vehicle/records'). The
# standalone asyncio service in backend/tracker/ writes positions here via the
# ORM. Only the owner, or users the owner explicitly granted (family / fleet
# admin), can read location or send commands (core.views_vehicle.access_for).
# ===========================================================================

class VehicleTracker(models.Model):
    STATES = [("pending", "pending"),       # waiting for the device to connect
              ("paired", "paired"),
              ("expired", "expired"),       # pairing window passed, never connected
              ("disabled", "disabled")]     # unpaid / owner turned off
    PROTOCOLS = [("auto", "auto"), ("gt06", "gt06"), ("teltonika", "teltonika")]
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="vehicle_trackers")
    vehicle_record = models.ForeignKey("PaCollectionItem", null=True, blank=True,
                                       on_delete=models.SET_NULL,
                                       related_name="trackers")
    name = models.CharField(max_length=80, blank=True, default="")
    imei = models.CharField(max_length=20, unique=True)        # digits only
    protocol = models.CharField(max_length=10, choices=PROTOCOLS, default="auto")
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    disabled_reason = models.CharField(max_length=24, blank=True, default="")
    pair_expires_at = models.DateTimeField(null=True, blank=True)
    paired_at = models.DateTimeField(null=True, blank=True)
    billed_until = models.DateTimeField(null=True, blank=True)
    # live state (written by the tracker service; the ONLY live store)
    last_seen_at = models.DateTimeField(null=True, blank=True)
    last_fix_at = models.DateTimeField(null=True, blank=True)
    last_lat = models.FloatField(null=True, blank=True)
    last_lng = models.FloatField(null=True, blank=True)
    last_speed_kmh = models.FloatField(null=True, blank=True)
    last_course = models.IntegerField(null=True, blank=True)
    ignition = models.BooleanField(null=True, blank=True)
    relay_cut = models.BooleanField(null=True, blank=True)    # as REPORTED by device
    ext_voltage_v = models.FloatField(null=True, blank=True)
    battery_v = models.FloatField(null=True, blank=True)
    obd = models.JSONField(default=dict, blank=True)           # latest OBD IO snapshot
    # owner settings
    moving_interval_s = models.IntegerField(default=5)
    parked_interval_s = models.IntegerField(default=180)
    speed_limit_kmh = models.IntegerField(default=0)           # 0 = off
    night_ignition_alert = models.BooleanField(default=True)
    night_start = models.CharField(max_length=5, default="23:00")
    night_end = models.CharField(max_length=5, default="05:00")
    geofences = models.JSONField(default=list, blank=True)     # [{id,name,lat,lng,radius_m}]
    cutoff_requires_approval = models.BooleanField(default=False)
    approver = models.ForeignKey("CircleMember", null=True, blank=True,
                                 on_delete=models.SET_NULL,
                                 related_name="approver_for_vehicles")
    alert_state = models.JSONField(default=dict, blank=True)   # evaluate_alerts state
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["created_at"]


class VehiclePosition(models.Model):
    """One GPS fix. Pruned to PricingConfig vehicle.retention_days."""
    tracker = models.ForeignKey(VehicleTracker, on_delete=models.CASCADE,
                                related_name="positions")
    at = models.DateTimeField()                     # device fix time (UTC)
    lat = models.FloatField()
    lng = models.FloatField()
    speed_kmh = models.FloatField(default=0)
    course = models.IntegerField(default=0)
    sats = models.IntegerField(default=0)
    valid = models.BooleanField(default=True)
    ignition = models.BooleanField(null=True, blank=True)
    io = models.JSONField(default=dict, blank=True)  # small raw IO subset
    received_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at"]
        indexes = [models.Index(fields=["tracker", "at"])]


class VehicleCommand(models.Model):
    """A remote command with an HONEST lifecycle:
    awaiting_approval -> queued -> sent -> acked | failed
    (or cancelled / rejected / expired). 'acked' means the DEVICE replied OK;
    it is never set from our side alone."""
    KINDS = [("engine_cut", "engine_cut"), ("engine_restore", "engine_restore"),
             ("set_interval", "set_interval")]
    STATES = [("awaiting_approval", "awaiting_approval"), ("queued", "queued"),
              ("sent", "sent"), ("acked", "acked"), ("failed", "failed"),
              ("cancelled", "cancelled"), ("rejected", "rejected"),
              ("expired", "expired")]
    tracker = models.ForeignKey(VehicleTracker, on_delete=models.CASCADE,
                                related_name="commands")
    kind = models.CharField(max_length=16, choices=KINDS)
    state = models.CharField(max_length=20, choices=STATES, default="queued")
    requested_by = models.ForeignKey(User, null=True, blank=True,
                                     on_delete=models.SET_NULL,
                                     related_name="vehicle_commands")
    approved_by = models.ForeignKey(User, null=True, blank=True,
                                    on_delete=models.SET_NULL,
                                    related_name="vehicle_command_approvals")
    payload = models.JSONField(default=dict, blank=True)
    text = models.CharField(max_length=120, blank=True, default="")  # wire text sent
    server_flag = models.BigIntegerField(default=0)   # GT06 reply matching
    response = models.TextField(blank=True, default="")
    fail_reason = models.CharField(max_length=24, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    done_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["tracker", "state"])]


class VehicleAccessGrant(models.Model):
    """Owner-granted access. kind=family -> grantee must be an accepted circle
    peer; kind=fleet -> grantee must be active staff of the owner's business."""
    KINDS = [("family", "family"), ("fleet", "fleet")]
    tracker = models.ForeignKey(VehicleTracker, on_delete=models.CASCADE,
                                related_name="grants")
    grantee = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="vehicle_grants")
    kind = models.CharField(max_length=8, choices=KINDS, default="family")
    can_command = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("tracker", "grantee")]


class VehicleAuditLog(models.Model):
    """Every pairing, rejected IMEI, command request/denial/state change and
    grant change. tracker is null for unknown-IMEI connection attempts."""
    tracker = models.ForeignKey(VehicleTracker, null=True, blank=True,
                                on_delete=models.CASCADE, related_name="audit")
    actor = models.ForeignKey(User, null=True, blank=True,
                              on_delete=models.SET_NULL,
                              related_name="vehicle_audit")
    action = models.CharField(max_length=32)
    imei = models.CharField(max_length=20, blank=True, default="")
    detail = models.JSONField(default=dict, blank=True)
    at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-at"]
# ---- /v1-vehicle ----


# ---- d1-discover ----
class DiscoverCard(models.Model):
    """One HOME "Discover" spotlight card, managed from the owner admin
    (Settings -> Discover manager). Visibility rules live in
    core/logic/discover.py and are enforced server-side."""
    TYPES = [("FEATURE", "Feature"), ("OUR_PRODUCT", "Our product"),
             ("SPONSORED", "Sponsored"), ("ADMOB", "AdMob slot")]
    AUDIENCES = [("all", "all"), ("free", "free"), ("premium", "premium"),
                 ("business", "business")]
    key = models.SlugField(max_length=60, unique=True)
    type = models.CharField(max_length=12, choices=TYPES, default="FEATURE")
    title_bn = models.CharField(max_length=80, blank=True, default="")
    title_en = models.CharField(max_length=80, blank=True, default="")
    desc_bn = models.CharField(max_length=200, blank=True, default="")
    desc_en = models.CharField(max_length=200, blank=True, default="")
    image = models.ImageField(upload_to="discover/", null=True, blank=True)
    icon = models.CharField(max_length=40, blank=True, default="")
    route = models.CharField(max_length=40, blank=True, default="")
    url = models.URLField(max_length=300, blank=True, default="")
    order = models.IntegerField(default=0)
    enabled = models.BooleanField(default=True)
    start_at = models.DateTimeField(null=True, blank=True)
    end_at = models.DateTimeField(null=True, blank=True)
    audience = models.CharField(max_length=10, choices=AUDIENCES, default="all")
    min_build = models.PositiveIntegerField(null=True, blank=True)
    sponsor_name = models.CharField(max_length=80, blank=True, default="")
    sponsor_revenue = models.DecimalField(max_digits=12, decimal_places=2,
                                          default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["order", "id"]


class DiscoverSeen(models.Model):
    """Dedupe ledger: at most ONE impression and ONE click per user per card
    per local day is counted into DiscoverDailyStat."""
    KINDS = [("imp", "impression"), ("click", "click")]
    card = models.ForeignKey(DiscoverCard, on_delete=models.CASCADE,
                             related_name="seen")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="discover_seen")
    date = models.DateField()
    kind = models.CharField(max_length=5, choices=KINDS)

    class Meta:
        unique_together = [("card", "user", "date", "kind")]


class DiscoverDailyStat(models.Model):
    """Daily aggregate per card (the sponsor report)."""
    card = models.ForeignKey(DiscoverCard, on_delete=models.CASCADE,
                             related_name="daily")
    date = models.DateField()
    impressions = models.PositiveIntegerField(default=0)
    clicks = models.PositiveIntegerField(default=0)

    class Meta:
        unique_together = [("card", "date")]
        ordering = ["date"]
# ---- /d1-discover ----


# ---- ps1-photo ---- Photo Studio: jobs, rewarded-ad tickets, export unlocks.
class PhotoStudioJob(models.Model):
    """One Photo Studio job. Funding is decided and TAKEN before any cost is
    incurred (core/logic/photo_studio.funding_options): Premium/Business pay from
    their monthly pool, free users either watch N SSV-verified rewarded ads or
    spend credits. `status` only reaches 'funded' when that is done; cloud work
    and full-quality export both require 'funded' (or 'done')."""
    STATUSES = [("awaiting_funds", "awaiting funds"), ("funded", "funded"),
                ("running", "running"), ("done", "done"), ("failed", "failed"),
                ("refused", "refused"), ("expired", "expired")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="photo_jobs")
    feature = models.CharField(max_length=16)
    options = models.JSONField(default=dict, blank=True)
    prompt = models.CharField(max_length=500, blank=True, default="")
    status = models.CharField(max_length=16, choices=STATUSES,
                              default="awaiting_funds")
    funding = models.CharField(max_length=10, blank=True, default="")
    trial = models.BooleanField(default=False)
    ads_required = models.IntegerField(default=0)
    credits_charged = models.IntegerField(default=0)
    provider = models.CharField(max_length=24, blank=True, default="")
    cost_bdt = models.FloatField(default=0.0)        # booked provider cost
    revenue_bdt = models.FloatField(default=0.0)     # ads/credits value taken
    result_name = models.CharField(max_length=200, blank=True, default="")
    preview_name = models.CharField(max_length=200, blank=True, default="")
    error = models.CharField(max_length=200, blank=True, default="")
    runs = models.IntegerField(default=0)
    flags = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    funded_at = models.DateTimeField(null=True, blank=True)
    done_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["user", "feature", "created_at"])]


class PhotoAdTicket(models.Model):
    """A rewarded-ad (or entry-interstitial) ticket. The app passes `nonce` as
    the AdMob SSV custom_data; ONLY Google's signed server-side-verification
    callback (GET /ads/ssv) can flip a rewarded ticket to 'verified'. A no-fill,
    a dismissed ad or a client claim never verifies anything — no free bypass.
    transaction_id is unique so a replayed callback cannot count twice."""
    KINDS = [("rewarded", "rewarded"), ("interstitial", "interstitial")]
    STATUSES = [("pending", "pending"), ("verified", "verified"),
                ("expired", "expired"), ("rejected", "rejected")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="photo_ad_tickets")
    job = models.ForeignKey(PhotoStudioJob, null=True, blank=True,
                            on_delete=models.CASCADE, related_name="tickets")
    kind = models.CharField(max_length=14, choices=KINDS, default="rewarded")
    placement = models.CharField(max_length=10, default="job")   # job | entry
    nonce = models.CharField(max_length=48, unique=True)
    status = models.CharField(max_length=10, choices=STATUSES, default="pending")
    transaction_id = models.CharField(max_length=128, null=True, blank=True,
                                      unique=True)
    ad_unit = models.CharField(max_length=80, blank=True, default="")
    value_bdt = models.FloatField(default=0.0)
    source = models.CharField(max_length=8, blank=True, default="")  # ssv | client
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    verified_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["user", "placement", "created_at"])]


class PhotoExport(models.Model):
    """Every unlock of an image leaving the studio (save / share / wallpaper /
    copy / open-in). Free users get one only for a funded job; the row records
    whether the corner mark was required."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="photo_exports")
    job = models.ForeignKey(PhotoStudioJob, on_delete=models.CASCADE,
                            related_name="exports")
    kind = models.CharField(max_length=10)
    token = models.CharField(max_length=48, unique=True)
    corner_mark = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
# ---- /ps1-photo ----


# ---- w1-webphoto ----
class WebPhotoDrop(models.Model):
    """A passport/visa photo made on lifeassisto.com/photo, parked for the
    "Get it in the Assisto app" deep link. The clean JPEG lives ONLY here (DB,
    never /media) and is never served by a web route; the app claims it once,
    after login, into a Photo Studio job (normal export gate). Expires within
    1 hour (web/logic/webphoto.TTL_MIN); purged on access + by cron."""
    token = models.CharField(max_length=64, unique=True)
    preset = models.CharField(max_length=24)
    image = models.BinaryField()
    ip_hash = models.CharField(max_length=64, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(db_index=True)
# ---- /w1-webphoto ----
# ---- o2-admin: web owner admin panel (/owner/) ----
class OwnerTOTP(models.Model):
    """The owner's TOTP 2FA enrolment for the web owner panel. The secret is
    stored ENCRYPTED (Fernet key derived from SECRET_KEY) and is never shown
    again after enrolment; recovery codes are stored only as hashes."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="owner_totp")
    secret_enc = models.TextField(blank=True, default="")
    confirmed_at = models.DateTimeField(null=True, blank=True)
    last_counter = models.BigIntegerField(default=0)    # anti-replay
    recovery_hashes = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class OwnerSession(models.Model):
    """A web owner-panel session (cookie `assisto_owner`, path /owner/). Only a
    SHA-256 of the cookie value is stored. stage: 'mfa' (password OK, TOTP
    pending) | 'enrol' (password OK, first-time 2FA enrolment) | 'full'."""
    key_hash = models.CharField(max_length=64, unique=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="owner_sessions")
    stage = models.CharField(max_length=8, default="mfa")
    csrf = models.CharField(max_length=64)
    lang = models.CharField(max_length=2, default="bn")
    pending_secret_enc = models.TextField(blank=True, default="")
    ip = models.CharField(max_length=64, blank=True, default="")
    ua = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen = models.DateTimeField()


class OwnerThrottle(models.Model):
    """Login / 2FA failure counter with exponential lockout (per IP and per
    account). DB-backed so every gunicorn worker sees the same count."""
    key = models.CharField(max_length=120, unique=True)
    fails = models.IntegerField(default=0)
    locked_until = models.DateTimeField(null=True, blank=True)
    last_fail_at = models.DateTimeField(null=True, blank=True)


class OwnerAudit(models.Model):
    """Append-only audit of the web owner panel: every login (success/fail)
    and every change — who, what, before/after, IP, time. Secrets are never
    written here (key changes log only field names + last 4)."""
    actor = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="owner_audit")
    action = models.CharField(max_length=60)
    target = models.CharField(max_length=160, blank=True, default="")
    before = models.JSONField(null=True, blank=True)
    after = models.JSONField(null=True, blank=True)
    ok = models.BooleanField(default=True)
    ip = models.CharField(max_length=64, blank=True, default="")
    ua = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at", "-id"]
# ---- /o2-admin ----


# ===========================================================================
# ---- b6-antitheft ---- Batch 6: native always-on Lost/Stolen engine.
#
# The user turns protection ON from the Lost/Stolen screen (Security PIN);
# turning it OFF needs the Security PIN again (Section 8). While ON, an opt-in
# foreground service on the phone reports heartbeats + events here through a
# SCOPED engine token (it can only post evidence for this one phone — never
# read anything, never act as the user). Alerts go ONLY to the owner and the
# family members the owner approved (family_approver + alert_member_ids).
# ===========================================================================

class AntiTheftEngine(models.Model):
    """Per-phone settings + state of the native protection engine."""
    phone = models.OneToOneField(ProtectedPhone, on_delete=models.CASCADE,
                                 related_name="engine")
    enabled = models.BooleanField(default=False)
    enabled_at = models.DateTimeField(null=True, blank=True)
    disabled_at = models.DateTimeField(null=True, blank=True)
    # sha256 of the engine token (the raw token is returned ONCE on enable).
    token_hash = models.CharField(max_length=64, blank=True, default="",
                                  db_index=True)
    snatch_lock = models.BooleanField(default=False)     # lock screen on snatch
    intruder_photo = models.BooleanField(default=True)   # front photo on N fails
    failed_unlock_threshold = models.PositiveSmallIntegerField(default=3)
    # Extra approved family: ids of the owner's ACCEPTED CircleMember rows.
    alert_member_ids = models.JSONField(default=list, blank=True)
    # What the phone says it can actually do (honest UI): {camera, phone_state,
    # location_bg, sdk, brand, ...}. Reported by the engine, display-only.
    capabilities = models.JSONField(default=dict, blank=True)
    # Time of the newest location fix we accepted: an older store-and-forward
    # fix arriving late never overwrites a newer last location.
    last_fix_at = models.DateTimeField(null=True, blank=True)
    last_sim = models.JSONField(default=dict, blank=True)
    recent_ids = models.JSONField(default=list, blank=True)  # heartbeat dedupe ring
    last_ingest_at = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class AntiTheftEvent(models.Model):
    """One event the engine captured (store-and-forward). `at` is WHEN it
    happened on the phone (clock-corrected), `received_at` when it reached us
    — a late delivery is shown honestly as late, never as live."""
    KINDS = [("snatch", "snatch"), ("snatch_cleared", "snatch_cleared"),
             ("sim_change", "sim_change"), ("offline", "offline"),
             ("online", "online"), ("low_battery", "low_battery"),
             ("shutdown", "shutdown"), ("boot", "boot"),
             ("failed_unlock", "failed_unlock"),
             ("intruder_photo", "intruder_photo"), ("test", "test"),
             ("went_dark", "went_dark")]  # went_dark: written by the server cron
    phone = models.ForeignKey(ProtectedPhone, on_delete=models.CASCADE,
                              related_name="engine_events")
    client_id = models.CharField(max_length=64)
    kind = models.CharField(max_length=20, choices=KINDS)
    at = models.DateTimeField(db_index=True)
    received_at = models.DateTimeField(auto_now_add=True)
    late = models.BooleanField(default=False)
    data = models.JSONField(default=dict, blank=True)
    lat = models.FloatField(null=True, blank=True)
    lng = models.FloatField(null=True, blank=True)
    accuracy_m = models.FloatField(null=True, blank=True)
    battery = models.SmallIntegerField(null=True, blank=True)
    # Intruder photo: Fernet-ENCRYPTED bytes at rest (never a public URL; read
    # only through a short-lived signed link minted for the owner / approved
    # family, decrypted per request).
    photo = models.FileField(upload_to="theft/engine/", null=True, blank=True)
    alerted = models.BooleanField(default=False)

    class Meta:
        ordering = ["-at", "-id"]
        unique_together = [("phone", "client_id")]
# ---- /b6-antitheft ----
