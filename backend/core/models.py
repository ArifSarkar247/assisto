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
    referral_code = models.CharField(max_length=12, blank=True,   # feature 19 invite
                                     db_index=True)               # p5: /i/<code> lookup
    referred_by = models.CharField(max_length=12, blank=True)

    # --- monetization (P3) ---
    plan = models.CharField(max_length=16, default="free")        # see plans.PLANS
    plan_until = models.DateTimeField(null=True, blank=True)      # paid plan expiry
    trial_until = models.DateTimeField(null=True, blank=True)     # 7-day full trial
    is_founder = models.BooleanField(default=False)
    #   founder_since None + is_founder  -> legacy LIFETIME founder (plan "founder")
    #   founder_since set  + is_founder  -> Founding Member: badge + free Premium
    #                                       via plan/plan_until (until founder_until)
    founder_since = models.DateTimeField(null=True, blank=True)
    founder_until = models.DateTimeField(null=True, blank=True)
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
    # ai-router: which provider answered (owner-only; never shown in the app),
    # the job class, latency, success and the failover path.
    provider = models.CharField(max_length=20, blank=True, default="")
    tier = models.CharField(max_length=10, blank=True, default="")
    task_class = models.CharField(max_length=10, blank=True, default="")
    latency_ms = models.IntegerField(default=0)
    ok = models.BooleanField(default=True)
    hops = models.IntegerField(default=0)            # failovers before the answer
    attempts = models.CharField(max_length=240, blank=True, default="")
    cache_read_tokens = models.IntegerField(default=0)
    cache_write_tokens = models.IntegerField(default=0)
    error_kind = models.CharField(max_length=30, blank=True, default="")

    class Meta:
        indexes = [models.Index(fields=["created_at"]),
                   models.Index(fields=["provider", "created_at"])]


class AIProviderState(models.Model):
    """ai-router: per-provider circuit breaker + health, shared by every
    gunicorn worker (DB row; no cache infrastructure). slug 'total' holds only
    the total-cap alert days."""
    STATES = [("closed", "closed"), ("open", "open"), ("half_open", "half_open")]
    slug = models.CharField(max_length=20, unique=True)
    state = models.CharField(max_length=10, choices=STATES, default="closed")
    consecutive_failures = models.IntegerField(default=0)
    window_start = models.DateTimeField(null=True, blank=True)
    window_calls = models.IntegerField(default=0)
    window_failures = models.IntegerField(default=0)
    opened_at = models.DateTimeField(null=True, blank=True)
    probe_until = models.DateTimeField(null=True, blank=True)
    last_success_at = models.DateTimeField(null=True, blank=True)
    last_failure_at = models.DateTimeField(null=True, blank=True)
    last_error = models.CharField(max_length=120, blank=True, default="")
    last_health_at = models.DateTimeField(null=True, blank=True)
    last_health_ok = models.BooleanField(null=True, blank=True)
    alert_warn_day = models.DateField(null=True, blank=True)     # 80% alert sent
    alert_full_day = models.DateField(null=True, blank=True)     # 100% alert sent
    updated_at = models.DateTimeField(auto_now=True)


class AIQualityProbe(models.Model):
    """ai-router: one answer of the owner-run offline Bangla quality probe
    (manage.py ai_quality_probe) for side-by-side review in Owner Admin."""
    run_id = models.CharField(max_length=20, db_index=True)
    provider = models.CharField(max_length=20)
    model = models.CharField(max_length=60)
    prompt_no = models.IntegerField(default=0)
    prompt = models.TextField()
    answer = models.TextField(blank=True, default="")
    ok = models.BooleanField(default=False)
    error = models.CharField(max_length=120, blank=True, default="")
    latency_ms = models.IntegerField(default=0)
    cost_usd = models.FloatField(default=0.0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at", "prompt_no", "provider"]


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
               ("expire", "credits expired"),
               # billing v2 (owner order 27 Oct, rule A)
               ("unlock", "staged unlock"),
               ("revoke", "revoked (refund / void)"),
               ("refund", "owner-approved refund"),
               ("return", "failed call returned")]
    BUCKETS = [("plan", "plan allowance"), ("pack", "pack"), ("free", "free"),
               ("rewarded", "rewarded ad"), ("referral", "referral"),
               ("legacy", "legacy (pre-buckets)"), ("debt", "refund debt")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="credit_ledger")
    delta = models.IntegerField()               # +grant / -consume
    reason = models.CharField(max_length=20, choices=REASONS)
    note = models.CharField(max_length=120, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    # billing v2 — APPEND-ONLY: bucket + source of every change, the cached
    # balance right after it, and a unique key that makes a grant idempotent.
    bucket = models.CharField(max_length=10, blank=True, default="")
    source_type = models.CharField(max_length=24, blank=True, default="")
    source_id = models.CharField(max_length=120, blank=True, default="", db_index=True)
    grant_key = models.CharField(max_length=160, null=True, blank=True, unique=True)
    balance_after = models.IntegerField(null=True, blank=True)
    lot = models.ForeignKey("CreditLot", on_delete=models.SET_NULL, null=True,
                            blank=True, related_name="ledger_rows")

    class Meta:
        ordering = ["-created_at"]

    def save(self, *args, **kwargs):
        # append-only (rule A): a row is written once and never edited
        if self.pk is not None and not getattr(self, "_allow_edit", False):
            raise ValueError("CreditLedger is append-only")
        return super().save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        raise ValueError("CreditLedger is append-only")


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
    # ---- p1-bizagent ----
    business = models.ForeignKey("BusinessProfile", null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="online_orders")
    thread = models.ForeignKey("ChatThread", null=True, blank=True,
                               on_delete=models.SET_NULL, related_name="orders")
    sale = models.ForeignKey("Sale", null=True, blank=True, on_delete=models.SET_NULL,
                             related_name="online_orders")
    area = models.CharField(max_length=10, blank=True, default="")   # inside|outside
    delivery_charge = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    consignment_id = models.CharField(max_length=80, blank=True, default="")
    courier_status = models.CharField(max_length=60, blank=True, default="")
    courier_error = models.CharField(max_length=200, blank=True, default="")
    courier_checked_at = models.DateTimeField(null=True, blank=True)
    invoice_sent_at = models.DateTimeField(null=True, blank=True)
    # ---- g1-bizagent ---- '' | pending_verification (customer sent a payment
    # screenshot — NEVER treated as paid) | verified | rejected (owner decides)
    payment_status = models.CharField(max_length=24, blank=True, default="")
    via_agent = models.BooleanField(default=False)    # taken by the AI agent in chat

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
    # connect-flow: when this pair became connected (request accepted /
    # invite joined) -> the "You are now connected" line + chat-list order.
    connected_at = models.DateTimeField(null=True, blank=True)
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
    # md1: indexed — media access checks + retention look messages up by it.
    blob_ref = models.CharField(max_length=256, blank=True, default="",
                                db_index=True)
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
    # e-gaps: VIEW-ONCE media (1:1). The flag is routing metadata only; the
    # file key stays inside the E2E descriptor. Once the recipient opens it,
    # the server blanks the ciphertext + deletes the encrypted blob.
    view_once = models.BooleanField(default=False)
    view_once_opened_at = models.DateTimeField(null=True, blank=True)
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
    # dl1: placed while the owner's "Free calls (testing)" switch was ON — the
    # caller was charged nothing; P&L shows its relay cost as free (testing).
    free_testing = models.BooleanField(default=False)

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
    # p3: E2E per viewer — {str(user_id): {ciphertext, nonce}} (text body or the
    # photo's md1 media descriptor), each sealed on the author's phone to that
    # viewer's key. The server returns a viewer ONLY their own entry.
    per_recipient = models.JSONField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-created_at"]


class CircleNote(models.Model):
    """p3: a profile Note (Instagram-style) — <= 60 chars, lives 24 h, shown on
    the author's profile / contact row to the audience they chose. E2E like a
    story: per_recipient ciphertext only; the server never sees the text."""
    author = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="circle_notes")
    per_recipient = models.JSONField(default=dict, blank=True)
    scheme = models.CharField(max_length=64, blank=True, default="")
    sender_key_id = models.CharField(max_length=64, blank=True, default="")
    visibility = models.JSONField(default=dict, blank=True)
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
    # retention1: only when the CUSTOMER gave it (birthday wish automation)
    birthday = models.DateField(null=True, blank=True)

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
    CHANNELS = [("whatsapp_cloud", "whatsapp_cloud"), ("messenger", "messenger"),
                ("instagram", "instagram"),   # p1: Instagram DM
                ("website", "website")]       # g1: website chat widget
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="chat_threads")
    business = models.ForeignKey(BusinessProfile, null=True, blank=True,
                                 on_delete=models.CASCADE, related_name="chat_threads")
    customer_phone = models.CharField(max_length=40, blank=True, default="")
    channel = models.CharField(max_length=20, choices=CHANNELS, default="whatsapp_cloud")
    last_inbound_at = models.DateTimeField(null=True, blank=True)
    owner_takeover = models.BooleanField(default=False)   # p1: HUMAN HANDOVER (AI paused)
    lang = models.CharField(max_length=2, default="bn")
    created_at = models.DateTimeField(auto_now_add=True)
    # ---- p1-bizagent ----
    seller_channel = models.ForeignKey("SellerChannel", null=True, blank=True,
                                       on_delete=models.SET_NULL, related_name="threads")
    external_user_id = models.CharField(max_length=80, blank=True, default="",
                                        db_index=True)   # PSID / IGSID / wa_id
    customer_name = models.CharField(max_length=120, blank=True, default="")
    order_draft = models.JSONField(default=dict, blank=True)
    ai_disclosed = models.BooleanField(default=False)
    oor_notice_at = models.DateTimeField(null=True, blank=True)  # out-of-replies line sent
    last_message_at = models.DateTimeField(null=True, blank=True)
    # ---- g1-bizagent ---- human takeover per chat + single-flight
    ai_paused_until = models.DateTimeField(null=True, blank=True)   # human replied → pause
    paused_by = models.CharField(max_length=12, blank=True, default="")  # echo|app
    reply_lock_until = models.DateTimeField(null=True, blank=True)  # one reply at a time
    followups_sent = models.IntegerField(default=0)
    last_followup_at = models.DateTimeField(null=True, blank=True)
    opted_out = models.BooleanField(default=False)
    upsell_done = models.BooleanField(default=False)
    # ---- biz-v2 ---- Business inbox read marker + owner takeover idle clock
    owner_read_at = models.DateTimeField(null=True, blank=True)    # owner opened the chat
    takeover_at = models.DateTimeField(null=True, blank=True)      # last owner activity in takeover

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
    # ---- p1-bizagent ----
    # status: '' (legacy) | received | pending_approval | rejected | queued |
    #         sent | delivered | read | failed | blocked
    external_id = models.CharField(max_length=128, blank=True, default="", db_index=True)
    status = models.CharField(max_length=20, blank=True, default="")
    kind = models.CharField(max_length=20, blank=True, default="text")  # text|comment|holding|invoice|template|order
    risk_reason = models.CharField(max_length=40, blank=True, default="")
    send_error = models.CharField(max_length=200, blank=True, default="")
    meta = models.JSONField(default=dict, blank=True)
    # ---- g1-bizagent ---- rule | ai | fallback | human | system ('' = legacy)
    reply_source = models.CharField(max_length=12, blank=True, default="", db_index=True)
    credits = models.IntegerField(default=0)        # credits charged for this reply
    cost_bdt = models.FloatField(default=0.0)       # our provider cost (Profit Guard)

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
        constraints = [models.UniqueConstraint(
            fields=["provider", "txn_ref"], condition=~models.Q(txn_ref=""),
            name="bill2_creditpurchase_txn_once")]


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


class AdPlacementStat(models.Model):
    """admob: one DAILY counter row per (placement, format, currency) for
    tuning — impressions / clicks from the app, and the per-impression value
    Google reports in onPaidEvent (micros, account currency). No user id, no
    device id: an aggregate, not a tracking log. Impression/click rows have
    currency ''; paid rows carry the currency."""
    date = models.DateField()
    placement = models.CharField(max_length=40)
    fmt = models.CharField(max_length=14)
    currency = models.CharField(max_length=3, blank=True, default="")
    impressions = models.PositiveIntegerField(default=0)
    clicks = models.PositiveIntegerField(default=0)
    paid_events = models.PositiveIntegerField(default=0)
    precise_events = models.PositiveIntegerField(default=0)
    revenue_micros = models.BigIntegerField(default=0)

    class Meta:
        unique_together = [("date", "placement", "fmt", "currency")]
        indexes = [models.Index(fields=["date", "placement"])]


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
    # ---- cctv1 (Home & shop watchman) ----
    # what the owner protects (a home is a personal-plan use; a shop is Business)
    KINDS = [("shop", "shop"), ("home", "home")]
    GATEWAYS = [("", "not chosen"), ("phone", "old Android phone"),
                ("shopbox", "Shop Box PC"), ("pc", "existing PC")]
    kind = models.CharField(max_length=8, choices=KINDS, default="shop")
    gateway = models.CharField(max_length=8, choices=GATEWAYS, default="",
                               blank=True)
    # {"day": "YYYY-MM-DD", "suppressed": n} — alerts held back by the daily cap
    stats = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["owner", "-created"])]


class ShopSiteViewer(models.Model):
    """cctv1: a family member the site owner lets SEE alerts + snapshots
    (read-only: no marking, no settings, no live view in phase 1)."""
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="viewers")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="shop_site_views")
    created = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created", "id"]
        constraints = [models.UniqueConstraint(fields=["site", "user"],
                                               name="uniq_shop_site_viewer")]


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
    # ---- cctv1 ----
    VENDORS = [("", "unknown"), ("imou", "Imou"), ("hikvision", "Hikvision"),
               ("dahua", "Dahua"), ("tapo", "TP-Link Tapo"), ("ezviz", "EZVIZ"),
               ("onvif", "ONVIF"), ("rtsp", "RTSP URL"), ("phone", "this phone")]
    vendor = models.CharField(max_length=12, choices=VENDORS, default="",
                              blank=True)
    # where the gateway reaches it on the LAN — NEVER the password/safety code
    # (that stays on the gateway): {"host", "port", "channel", "stream", ...}
    source = models.JSONField(default=dict, blank=True)
    # vendor cloud id (Imou: "<deviceId>:<channelId>") for camera-native alarms
    vendor_ref = models.CharField(max_length=80, blank=True, default="",
                                  db_index=True)
    # last compatibility check result the gateway reported (no secrets)
    compat = models.JSONField(default=dict, blank=True)
    # one small still from the compatibility check (zone-drawing background);
    # dropped when the site keeps no snapshots (retention 0). NEVER video.
    preview = models.ImageField(upload_to="shop/preview/", null=True, blank=True)
    # owner Correct/Wrong feedback -> bounded per-camera thresholds
    # {"person_conf", "motion_mult", "cooldown_s", "correct", "wrong"}
    tuning = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["created", "id"]
        indexes = [models.Index(fields=["site", "enabled"])]


class ShopGatewayTask(models.Model):
    """cctv1: work for the site's gateway (LAN discovery, camera compatibility
    check). The phone can't reach LAN cameras from the internet, so the gateway
    runs it and posts the result. A camera secret rides in `request` ONLY until
    the gateway picks the task up — it is wiped at hand-out (and on expiry)."""
    ACTIONS = [("discover", "discover"), ("check", "check")]
    STATUS = [("pending", "pending"), ("running", "running"), ("done", "done"),
              ("expired", "expired")]
    site = models.ForeignKey(ShopSite, on_delete=models.CASCADE,
                             related_name="gateway_tasks")
    camera = models.ForeignKey(ShopCamera, on_delete=models.CASCADE,
                               related_name="gateway_tasks", null=True,
                               blank=True)
    action = models.CharField(max_length=10, choices=ACTIONS)
    status = models.CharField(max_length=8, choices=STATUS, default="pending")
    request = models.JSONField(default=dict, blank=True)
    result = models.JSONField(default=dict, blank=True)
    created = models.DateTimeField(auto_now_add=True)
    picked_at = models.DateTimeField(null=True, blank=True)
    done_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created"]
        indexes = [models.Index(fields=["site", "status"])]


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
        # ---- cctv1 ----
        ("person_detected", "person seen while armed"),
        ("zone_intrusion", "restricted zone entered"),
        ("line_crossing", "entry line crossed"),
        ("camera_alarm", "camera's own alarm"),
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
    # ---- cctv1 ---- grouping: repeats of the same camera+type inside the
    # group window bump `count` / `last_at` instead of a new alert + push.
    count = models.PositiveIntegerField(default=1)
    last_at = models.DateTimeField(null=True, blank=True)

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
    # chat-actions: "Clear chat" may keep this user's starred messages, and
    # "Delete chat" hides the whole row from MY list until a newer message
    # arrives (the membership is never touched).
    cleared_keep_starred = models.BooleanField(default=False)
    deleted_at = models.DateTimeField(null=True, blank=True)
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
    # chat-actions: Settings > Privacy "Default message timer" for NEW chats
    # (0 / 86400 / 604800 / 7776000).
    default_disappearing_sec = models.IntegerField(default=0)
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
                ("queued", "queued"),   # d1-photo v2: waiting for the photo worker
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
    # photo-final: sha256 of the phone's stable device key (ANDROID_ID hash,
    # survives a reinstall) — free-enhance counters are taken per account AND
    # per device, so neither a reinstall nor a second account resets them.
    device_key = models.CharField(max_length=64, blank=True, default="", db_index=True)

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


# ---- d1-photo v2 ----
class PhotoWorkItem(models.Model):
    """The photo worker's DB queue (one row per funded heavy job). The API
    only ENQUEUES (the input image is parked in private media); the separate
    `assisto-photo-worker` service claims rows (SELECT … FOR UPDATE SKIP
    LOCKED, priority first, then oldest), runs the pipeline and the FACE LOCK,
    and finishes the PhotoStudioJob. The main API never runs heavy work."""
    STATES = [("queued", "queued"), ("running", "running"), ("done", "done"),
              ("failed", "failed")]
    job = models.OneToOneField(PhotoStudioJob, on_delete=models.CASCADE,
                               related_name="work")
    state = models.CharField(max_length=8, choices=STATES, default="queued")
    priority = models.IntegerField(default=0)          # paid 10, free 0
    input_name = models.CharField(max_length=200, blank=True, default="")
    face_boxes = models.JSONField(default=list, blank=True)
    params = models.JSONField(default=dict, blank=True)
    attempts = models.IntegerField(default=0)
    claimed_by = models.CharField(max_length=40, blank=True, default="")
    claimed_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    ms = models.IntegerField(default=0)
    error = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    # photo-final: the global daily spend cap was reached -> the item waits
    # (honest "in queue") until this time; claim() skips it before then.
    not_before = models.DateTimeField(null=True, blank=True)

    class Meta:
        indexes = [models.Index(fields=["state", "-priority", "created_at"])]


class PhotoProviderRun(models.Model):
    """photo-final: one row per provider call for one image (Owner Admin →
    Photo Studio → provider log): which provider/model version ran, real cost
    in USD, seconds, cache hit, fallback. Also THE result cache: a later job
    with the same `cache_key` (photo hash + preset + provider + version)
    reuses `result_name` and costs nothing. Today's spend for the global cap
    is the sum of `cost_usd` of today's rows."""
    job = models.ForeignKey(PhotoStudioJob, null=True, blank=True, on_delete=models.SET_NULL,
                            related_name="provider_runs")
    user = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL,
                             related_name="photo_provider_runs")
    feature = models.CharField(max_length=16, blank=True, default="")
    provider = models.CharField(max_length=24)
    model_version = models.CharField(max_length=120, blank=True, default="")
    preset = models.CharField(max_length=12, blank=True, default="")
    ok = models.BooleanField(default=False)
    cache_hit = models.BooleanField(default=False)
    fallback_from = models.CharField(max_length=24, blank=True, default="")
    cost_usd = models.FloatField(default=0.0)
    seconds = models.FloatField(default=0.0)
    cache_key = models.CharField(max_length=64, blank=True, default="", db_index=True)
    result_name = models.CharField(max_length=200, blank=True, default="")
    error = models.CharField(max_length=120, blank=True, default="")
    steps = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]


class PhotoABPair(models.Model):
    """Blind A/B test pair (Owner Admin → Photo Studio): the same damaged
    input through Assisto and through Remini (outputs supplied by the owner).
    Which side is shown left is random per vote; the labels stay hidden until
    the vote is cast."""
    name = models.CharField(max_length=80, unique=True)
    category = models.CharField(max_length=20, blank=True, default="")
    input_name = models.CharField(max_length=200)
    assisto_name = models.CharField(max_length=200)
    remini_name = models.CharField(max_length=200)
    metrics = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)


class PhotoABVote(models.Model):
    CHOICES = [("assisto", "assisto"), ("remini", "remini"), ("same", "same")]
    pair = models.ForeignKey(PhotoABPair, on_delete=models.CASCADE, related_name="votes")
    voter = models.ForeignKey(User, on_delete=models.CASCADE, related_name="photo_ab_votes")
    choice = models.CharField(max_length=8, choices=CHOICES)
    left_was = models.CharField(max_length=8, default="assisto")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("pair", "voter")]


class PhotoAIReport(models.Model):
    """Google Play AI-generated-content policy: "Report this AI image" from
    the app. Reviewed in Owner Admin → Photo Studio."""
    REASONS = [("offensive", "offensive"), ("sexual", "sexual"), ("fake_person", "fake_person"),
               ("face_changed", "face_changed"), ("child", "child"), ("other", "other")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="photo_ai_reports")
    job = models.ForeignKey(PhotoStudioJob, null=True, blank=True, on_delete=models.SET_NULL,
                            related_name="ai_reports")
    reason = models.CharField(max_length=14, choices=REASONS, default="other")
    note = models.CharField(max_length=300, blank=True, default="")
    status = models.CharField(max_length=8, default="open")     # open | closed
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
# ---- /d1-photo v2 ----
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


# ---- c3-msg ----
class CircleReceipt(models.Model):
    """c3-msg: per-recipient DELIVERY + SEEN receipt for one CircleMessage
    (1:1 and group). delivered_at = the recipient's DEVICE fetched it (push
    handler pull / app sync); seen_at = the chat was opened. Metadata only —
    never message content. Exposure to the sender follows the reciprocal
    read-receipt rule (circle_privacy.can_see_read_receipt)."""
    message = models.ForeignKey(CircleMessage, on_delete=models.CASCADE,
                                related_name="receipts")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="circle_receipts")
    delivered_at = models.DateTimeField(null=True, blank=True)
    seen_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = [("message", "user")]


class CirclePresence(models.Model):
    """c3-msg: one row per user — online heartbeat, last seen, and the live
    "typing… / recording audio…" activity (who/which group it targets, with a
    short expiry). DB-backed so every gunicorn worker sees the same state."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="c3_presence")
    last_seen = models.DateTimeField(null=True, blank=True)
    online_until = models.DateTimeField(null=True, blank=True)
    activity = models.CharField(max_length=10, blank=True, default="")
    activity_to_user = models.IntegerField(null=True, blank=True)
    activity_group = models.IntegerField(null=True, blank=True)
    activity_until = models.DateTimeField(null=True, blank=True)


class CircleChatFlag(models.Model):
    """c3-msg: the user's manual "Mark as unread" on a chat (WhatsApp style —
    the messages stay read; the row shows an unread dot until opened)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="c3_chat_flags")
    chat_kind = models.CharField(max_length=8, default="member")
    chat_id = models.CharField(max_length=32)
    marked_unread = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "chat_kind", "chat_id")]
# ---- /c3-msg ----


# ---- c2-calls ----
class CallSession(models.Model):
    """Live-call bookkeeping for one CallRecord (c2-calls): the callee phone's
    ring acknowledgement, ICE-connected time, the honest end reason and each
    side's last poll (so a phone that vanished ends the call). Media never
    touches the server; only SDP/ICE text passes through CallSignal."""
    call = models.OneToOneField(CallRecord, on_delete=models.CASCADE,
                                related_name="session")
    ringing_at = models.DateTimeField(null=True, blank=True)
    connected_at = models.DateTimeField(null=True, blank=True)
    end_reason = models.CharField(max_length=16, blank=True, default="")
    ended_by = models.CharField(max_length=8, blank=True, default="")
    caller_seen_at = models.DateTimeField(null=True, blank=True)
    callee_seen_at = models.DateTimeField(null=True, blank=True)
    missed_notified = models.BooleanField(default=False)
    relayed = models.BooleanField(default=False)


class RtEvent(models.Model):
    """One real-time event for ONE recipient (c2-calls transport, shared with
    presence/typing). The row id is the sequence number the phone polls after
    (GET rt/events?after=<seq>). Topics: call.* (signal/state), presence.*,
    typing.*. Short-lived: pruned after ~10 minutes."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="rt_events")
    topic = models.CharField(max_length=40)
    payload = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["id"]
        indexes = [models.Index(fields=["user", "id"], name="c2_rtev_user_id")]


class RtPresence(models.Model):
    """When this user's phone last polled the real-time channel (= app open
    and reachable). Calls use it to ring a phone without FCM; presence
    ("online") can read the same row."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="rt_presence")
    seen_at = models.DateTimeField()
# ---- /c2-calls ----


# ---- b2-badges ----
class NotifBadgeState(models.Model):
    """b2-badges: per-user badge watermarks (Facebook / WhatsApp style).
    Opening the notification centre moves `badge_cleared_at` (home bell);
    showing a tab moves its own watermark. A badge counts only items NEWER
    than its watermark — except SOS / family alerts, which keep counting
    until handled. Items stay unread (bold) until tapped individually."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="b2_badge_state")
    badge_cleared_at = models.DateTimeField(null=True, blank=True)
    feed_tab_cleared_at = models.DateTimeField(null=True, blank=True)
    reminders_cleared_at = models.DateTimeField(null=True, blank=True)
# ---- /b2-badges ----


# ---- l1-launch ----
class WebDeletionRequest(models.Model):
    """A "delete my account" request made on lifeassisto.com/delete-account by
    someone who may not have the app any more (Google Play data-deletion
    requirement: a web path, not only the in-app one).

    This row is a TICKET for the owner, nothing more. Creating it never
    deletes, schedules or changes any account. The owner first VERIFIES the
    requester really owns the account (e.g. calls/SMSes the registered number),
    then uses the Django admin action, which hands over to the normal
    AccountDeletionRequest flow (7-day grace, cancel token, purge_deletions).

    `matched_user` is filled server-side when the contact matches an account;
    it is NEVER shown to the requester (the public page answers the same way
    whether or not an account exists, so the form can't probe who is a user)."""
    STATUS_NEW = "new"
    STATUS_VERIFIED = "verified"
    STATUS_SCHEDULED = "scheduled"
    STATUS_REJECTED = "rejected"
    STATUS_NO_ACCOUNT = "no_account"
    STATUSES = [(STATUS_NEW, "new — verify the requester"),
                (STATUS_VERIFIED, "verified"),
                (STATUS_SCHEDULED, "deletion scheduled (7-day grace)"),
                (STATUS_REJECTED, "rejected / could not verify"),
                (STATUS_NO_ACCOUNT, "no matching account")]

    contact = models.CharField(max_length=190)          # canonical phone or email
    contact_kind = models.CharField(max_length=8, default="phone")  # phone|email
    name = models.CharField(max_length=120, blank=True, default="")
    reason = models.TextField(blank=True, default="")
    lang = models.CharField(max_length=4, default="bn")
    matched_user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                     blank=True, related_name="web_deletion_requests")
    status = models.CharField(max_length=12, choices=STATUSES, default=STATUS_NEW)
    owner_note = models.TextField(blank=True, default="")
    ip_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"web-deletion #{self.pk} {self.contact_kind} [{self.status}]"
# ---- /l1-launch ----


# ---- f1-founders ----
class FounderGrant(models.Model):
    """One Founding Member grant (owner panel). Keeps what the user's plan was
    BEFORE so a revoke can restore it exactly — but only when nothing changed
    the plan since (a payment or another owner edit always wins)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="founder_grants")
    months = models.PositiveSmallIntegerField()
    granted_at = models.DateTimeField()
    granted_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="+")
    reason = models.CharField(max_length=200, blank=True, default="")
    prev_plan = models.CharField(max_length=16, blank=True, default="")
    prev_plan_until = models.DateTimeField(null=True, blank=True)
    new_plan_until = models.DateTimeField(null=True, blank=True)
    plan_changed = models.BooleanField(default=False)
    revoked_at = models.DateTimeField(null=True, blank=True)
    revoked_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="+")
    revoke_reason = models.CharField(max_length=200, blank=True, default="")

    class Meta:
        ordering = ["-granted_at", "-id"]


def _feedback_upload(instance, filename):
    import uuid
    return "feedback/%s.%s" % (uuid.uuid4().hex, (filename.rsplit(".", 1)[-1] or "png")[:4])


class FeedbackReport(models.Model):
    """In-app "Send feedback / report a problem". The optional screenshot is a
    private upload (signed, expiring link via core.media_sign — never /media);
    only the reporter (API) and the owner (panel) can see a report."""
    CATEGORIES = ("bug", "idea", "other")
    STATUSES = ("new", "triaged", "fixed", "closed")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="feedback_reports")
    category = models.CharField(max_length=8, default="bug")
    note = models.TextField()
    screenshot = models.FileField(upload_to=_feedback_upload, null=True, blank=True)
    screenshot_bytes = models.PositiveIntegerField(default=0)
    app_version = models.CharField(max_length=32, blank=True, default="")
    app_build = models.CharField(max_length=16, blank=True, default="")
    device_model = models.CharField(max_length=80, blank=True, default="")
    os_version = models.CharField(max_length=40, blank=True, default="")
    language = models.CharField(max_length=8, blank=True, default="")
    route = models.CharField(max_length=80, blank=True, default="")
    status = models.CharField(max_length=8, default="new", db_index=True)
    owner_note = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at", "-id"]
# ---- /f1-founders ----
# ---- x1-calls ----
# Idempotent call placement (owner order A1): the phone sends one random
# client_call_id per user tap; a repeated POST with the same key (double tap,
# retry, the old chat-screen gate pre-check) returns the SAME call instead of
# creating a second record that the server then ends as "busy".
CallSession.add_to_class(
    "client_call_id",
    models.CharField(max_length=64, blank=True, default="", db_index=True))
# ---- /x1-calls ----


# ---- e2-keys ---- per-USER public key directory (owner order 22 Oct, item 1).
# A user's PUBLIC X25519 key lives here, once per user (never on a circle edge
# again); every payload that carries a peer key reads it LIVE from this table.
class UserPublicKey(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="e2_public_key")
    public_key = models.TextField(blank=True, default="")
    key_id = models.CharField(max_length=64, blank=True, default="")
    scheme = models.CharField(max_length=64, blank=True, default="")
    # When a DIFFERENT key replaced the previous one (reinstall / new phone):
    # drives the WhatsApp-style "security code changed" note on peers' chats.
    changed_at = models.DateTimeField(null=True, blank=True)
    previous_key_id = models.CharField(max_length=64, blank=True, default="")
    # a1-circle: the user's EARLIER public keys (newest first, capped) so a
    # contact's phone can still decrypt history / the chat-list preview that
    # was sent under a replaced key (reinstall / new phone). Public keys only.
    history = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class E2KeyRequest(models.Model):
    """`requester` wants to encrypt to `target`, who has no published key yet.
    The server sends `target` a silent FCM data push (kind=key_request) so
    their app publishes in the background; when it does, the requester gets
    a key.published real-time event + a silent key_ready push so its outbox
    encrypts + sends. One row per pair; throttles the push."""
    requester = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="e2_key_requests_made")
    target = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="e2_key_requests_got")
    requested_at = models.DateTimeField()
    pushed_at = models.DateTimeField(null=True, blank=True)
    push_count = models.IntegerField(default=0)
    fulfilled_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = [("requester", "target")]
# ---- /e2-keys ----
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
    intruder_photo = models.BooleanField(default=False)  # opt-in: front photo on N fails
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
    # own-device: sha256 of the app's X-Device-Id on the phone that runs this
    # engine (from enable + every ingest). An authenticated request carrying
    # the same id proves the phone is alive -> a went-dark latch is resolved.
    device_hash = models.CharField(max_length=64, blank=True, default="",
                                   db_index=True)
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


# ---- pay1 ----
# Payments: ONE entitlement service (core/payments/entitlement.py) fed by two
# channels — Google Play Billing (Play build) and a payment gateway (EPS; the
# direct APK + lifeassisto.com/premium). Every channel writes PlanPeriod /
# credit rows through that service; User.plan / plan_until stay the single
# field everything else reads.
class PaymentOrder(models.Model):
    """One checkout attempt through a hosted payment gateway (EPS today).

    The AMOUNT is copied from the server price table when the order is made;
    a callback/IPN can never change it. `merchant_tx_id` is our id sent to the
    gateway (unique); `provider_tx_id` is the gateway's id, unique when set, so
    one real payment can never be counted twice."""
    STATUS = [("created", "created"), ("pending", "pending"), ("paid", "paid"),
              ("failed", "failed"), ("cancelled", "cancelled"),
              ("refunded", "refunded"), ("expired", "expired")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="payment_orders")
    channel = models.CharField(max_length=12, default="gateway")   # gateway
    provider = models.CharField(max_length=16, default="eps")
    source = models.CharField(max_length=8, default="app")          # app|web
    sku = models.CharField(max_length=32)
    kind = models.CharField(max_length=8)                           # sub|pack
    plan = models.CharField(max_length=16, blank=True, default="")
    months = models.PositiveSmallIntegerField(default=0)
    credits = models.IntegerField(default=0)
    amount_bdt = models.DecimalField(max_digits=10, decimal_places=2)
    currency = models.CharField(max_length=3, default="BDT")
    fee_pct = models.DecimalField(max_digits=5, decimal_places=4, default=0)
    merchant_tx_id = models.CharField(max_length=32, unique=True)
    provider_tx_id = models.CharField(max_length=64, null=True, blank=True,
                                      unique=True)
    idempotency_key = models.CharField(max_length=64, blank=True, default="")
    status = models.CharField(max_length=10, choices=STATUS, default="created")
    detail = models.CharField(max_length=200, blank=True, default="")
    raw = models.JSONField(default=dict, blank=True)
    renew_of = models.ForeignKey("self", on_delete=models.SET_NULL, null=True,
                                 blank=True, related_name="+")
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    paid_at = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["user", "status"]),
                   models.Index(fields=["status", "created_at"])]
        constraints = [models.UniqueConstraint(
            fields=["user", "idempotency_key"],
            condition=~models.Q(idempotency_key=""),
            name="pay1_order_idem_per_user")]


class PlayPurchase(models.Model):
    """One Google Play purchase token (subscription or one-time pack). The
    token is bound to the FIRST account that verified it (unique token hash),
    so a token can never unlock a second account."""
    # billing v2 (rule F): never cascade — a deleted account leaves a
    # tombstone (user NULL, owner_ref kept) so a later refund still matches
    # and the token can never be claimed by another account.
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="play_purchases")
    owner_ref = models.CharField(max_length=40, blank=True, default="")
    is_test = models.BooleanField(default=False)          # rule S
    token_hash = models.CharField(max_length=64, unique=True)
    purchase_token = models.TextField()
    kind = models.CharField(max_length=8)                 # sub|pack
    product_id = models.CharField(max_length=64)
    base_plan_id = models.CharField(max_length=64, blank=True, default="")
    sku = models.CharField(max_length=32, blank=True, default="")
    order_id = models.CharField(max_length=64, blank=True, default="", db_index=True)
    state = models.CharField(max_length=48, blank=True, default="")
    expires_at = models.DateTimeField(null=True, blank=True)
    auto_renewing = models.BooleanField(default=False)
    acknowledged = models.BooleanField(default=False)
    consumed = models.BooleanField(default=False)
    granted = models.BooleanField(default=False)          # pack credits granted
    revoked = models.BooleanField(default=False)
    linked_token_hash = models.CharField(max_length=64, blank=True, default="")
    price_bdt = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    raw = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at", "-id"]


class PlanPeriod(models.Model):
    """A paid stretch of a plan from ONE channel. The entitlement service
    derives User.plan / plan_until from these (+ the non-payment base kept in
    PaymentAccount). (source, ref) is unique: the same purchase can never
    create two periods (no double grant)."""
    STATUS = [("active", "active"), ("revoked", "revoked"),
              ("converted", "converted"), ("replaced", "replaced")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="plan_periods")
    source = models.CharField(max_length=10)               # play|gateway
    ref = models.CharField(max_length=80)
    plan = models.CharField(max_length=16)
    starts_at = models.DateTimeField()
    ends_at = models.DateTimeField()
    status = models.CharField(max_length=10, choices=STATUS, default="active")
    auto_renew = models.BooleanField(default=False)
    order = models.ForeignKey(PaymentOrder, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="periods")
    note = models.CharField(max_length=160, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["starts_at", "id"]
        constraints = [models.UniqueConstraint(fields=["source", "ref"],
                                               name="pay1_period_source_ref")]
        indexes = [models.Index(fields=["user", "status", "ends_at"])]


class PaymentAccount(models.Model):
    """Per-user bookkeeping of the entitlement service: the plan state that
    did NOT come from a payment (Founding Member, referral days, owner edit)
    — `base_*` — and what the service last wrote — `written_*` — so a
    payment never wipes a free grant and a free grant never wipes a payment."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="payment_account")
    base_plan = models.CharField(max_length=16, blank=True, default="free")
    base_until = models.DateTimeField(null=True, blank=True)
    written_plan = models.CharField(max_length=16, blank=True, default="")
    written_until = models.DateTimeField(null=True, blank=True)
    has_written = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)


class PaymentEvent(models.Model):
    """APPEND-ONLY audit of every payment fact and every entitlement change
    (grant, extend, convert, revoke, refund, expiry, webhook received).
    Never holds secrets or full purchase tokens."""
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="payment_events")
    kind = models.CharField(max_length=40, db_index=True)
    channel = models.CharField(max_length=10, blank=True, default="")
    ref = models.CharField(max_length=80, blank=True, default="")
    amount_bdt = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    net_bdt = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    detail = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        constraints = [models.UniqueConstraint(
            fields=["kind", "ref"],
            condition=models.Q(kind__in=("play.charge", "play.refund")),
            name="bill2_play_revenue_once")]


class WebhookReceipt(models.Model):
    """Replay protection for push webhooks: one row per (source, message id).
    A second delivery of the same Pub/Sub message / gateway IPN is a no-op."""
    source = models.CharField(max_length=10)            # rtdn|eps_ipn
    message_id = models.CharField(max_length=128)
    received_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["source", "message_id"],
                                               name="pay1_webhook_once")]


class PaymentReminder(models.Model):
    """One expiry reminder sent for a prepaid gateway period (dedupe)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="+")
    period = models.ForeignKey(PlanPeriod, on_delete=models.CASCADE,
                               related_name="reminders")
    days_before = models.PositiveSmallIntegerField()
    channels = models.CharField(max_length=20, blank=True, default="")  # push,sms
    sent_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["period", "days_before"],
                                               name="pay1_reminder_once")]


class WebCheckoutSession(models.Model):
    """lifeassisto.com/premium sign-in by phone OTP: a short-lived, random,
    hashed session (cookie holds the raw value only)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="+")
    token_hash = models.CharField(max_length=64, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
# ---- /pay1 ----


# ====================================================================
# ---- t9-turnscale ---- TURN server list (owner-editable), coturn capacity
# samples, and per-TURN-session relay usage (Profit Guard cost per minute).
# No secrets live here: a server entry only names the env var of its secret.
# ====================================================================

class TurnConfig(models.Model):
    """Singleton (pk=1). `servers_text` is the owner-edited list (same format as
    env TURN_SERVERS; empty = use the env / single TURN_HOST). `thresholds`
    overrides the alert defaults; `health` + `alert_state` are written by the
    turn_monitor command (per-host STUN probe; alert de-duplication)."""
    servers_text = models.TextField(blank=True, default="")
    thresholds = models.JSONField(default=dict, blank=True)
    health = models.JSONField(default=dict, blank=True)
    alert_state = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def load(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


class TurnSample(models.Model):
    """One per-minute coturn sample (kept TURN_SAMPLE_KEEP_DAYS, ~20k rows).
    Nullable fields = that source was not available (never a made-up 0)."""
    at = models.DateTimeField(db_index=True)
    allocations = models.IntegerField(null=True, blank=True)     # live relay sockets
    cli_sessions = models.IntegerField(null=True, blank=True)    # coturn CLI 'ps'
    relay_in_bps = models.BigIntegerField(null=True, blank=True)   # bytes/s (CLI)
    relay_out_bps = models.BigIntegerField(null=True, blank=True)  # bytes/s (CLI)
    nic_in_bps = models.BigIntegerField(null=True, blank=True)     # bytes/s, whole box
    nic_out_bps = models.BigIntegerField(null=True, blank=True)    # bytes/s, whole box
    turn_cpu_pct = models.FloatField(null=True, blank=True)      # % of ONE vCPU
    steal_pct = models.FloatField(null=True, blank=True)
    quota_errors = models.IntegerField(default=0)                # 486 allocation quota
    bw_quota_errors = models.IntegerField(default=0)             # 486 bandwidth quota
    alloc_errors = models.IntegerField(default=0)                # cannot complete allocation
    auth_errors = models.IntegerField(default=0)                 # 401 / unknown user
    relay_bytes_out = models.BigIntegerField(default=0)          # closed sessions this minute
    healthy_servers = models.IntegerField(null=True, blank=True)
    sources = models.CharField(max_length=60, blank=True, default="")

    class Meta:
        ordering = ["-at"]


class TurnRelayUsage(models.Model):
    """Bytes of ONE closed coturn session (log 'usage' line), matched to the
    relayed call it most likely carried. Feeds the measured cost per minute."""
    at = models.DateTimeField(db_index=True)
    user_id = models.IntegerField(null=True, blank=True)
    bytes_in = models.BigIntegerField(default=0)
    bytes_out = models.BigIntegerField(default=0)                # egress = AWS-billed
    call_kind = models.CharField(max_length=8, blank=True, default="")  # voice|video
    call_id = models.IntegerField(null=True, blank=True)

    class Meta:
        ordering = ["-at"]
# ---- /t9-turnscale ----


# ---- sc1 ---- app crash / error reports (Owner Admin → Reports → App errors)
class ClientErrorReport(models.Model):
    """One scrubbed app error, deduplicated by (fingerprint, user, model, day):
    a repeat on the same phone the same day only bumps ``count``/``last_at``.

    PRIVACY: ``message``/``frames`` are scrubbed twice (on the phone, then by
    core.logic.crash_scrub) — no message text, phone numbers, e-mails, URLs,
    file names or tokens. ``user`` is shown only on the owner-only panel;
    ``user_hash`` is the opaque tag. Purged 30 days after ``last_at``
    (purge_l1_retention, hourly)."""
    fingerprint = models.CharField(max_length=24, db_index=True)
    day = models.DateField(db_index=True)
    user = models.ForeignKey(User, null=True, blank=True,
                             on_delete=models.SET_NULL, related_name="+")
    user_hash = models.CharField(max_length=16, blank=True, default="")
    source = models.CharField(max_length=12, default="app")   # app | startup
    fatal = models.BooleanField(default=False)
    error_type = models.CharField(max_length=80, blank=True, default="")
    message = models.CharField(max_length=320, blank=True, default="")
    frames = models.JSONField(default=list, blank=True)
    where = models.CharField(max_length=40, blank=True, default="")
    version = models.CharField(max_length=32, blank=True, default="")
    build = models.CharField(max_length=16, blank=True, default="", db_index=True)
    brand = models.CharField(max_length=40, blank=True, default="", db_index=True)
    manufacturer = models.CharField(max_length=40, blank=True, default="")
    model = models.CharField(max_length=60, blank=True, default="")
    android = models.CharField(max_length=16, blank=True, default="")
    sdk = models.IntegerField(default=0)
    rom = models.CharField(max_length=24, blank=True, default="")
    display = models.CharField(max_length=64, blank=True, default="")
    count = models.IntegerField(default=1)
    first_at = models.DateTimeField(db_index=True)
    last_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-last_at"]
        constraints = [models.UniqueConstraint(
            fields=["fingerprint", "user", "model", "day"], name="sc1_err_dedupe")]
# ---- /sc1 ----


# ---- md1 ---- My Circle E2E media blobs (ciphertext only)
class CircleMediaBlob(models.Model):
    """One encrypted file of a My Circle chat (photo / voice note / document).

    PRIVACY: the phone encrypts the file with a random per-file key BEFORE
    upload; only that ciphertext is stored (core.circle_blobs keeps it in a
    private directory OUTSIDE MEDIA_ROOT and serves it only through a
    short-lived signed link to chat participants). The key, nonce, file name,
    mime type and thumbnail travel inside the per-recipient E2E message, never
    in this row — ``kind`` is only the routing class used for the size cap.

    Retention (purge_l1_retention, hourly; owner-editable limits): deleted
    ``circle_media_keep_days`` after every recipient downloaded it, at most
    ``circle_media_max_days`` after upload, at once on delete-for-everyone,
    and 24 h after an unfinished / never-sent upload."""
    ref = models.CharField(max_length=40, unique=True)
    owner = models.ForeignKey(User, on_delete=models.CASCADE,
                              related_name="circle_media_blobs")
    kind = models.CharField(max_length=12, default="document")
    size = models.BigIntegerField(default=0)          # declared ciphertext bytes
    received = models.BigIntegerField(default=0)      # bytes stored so far
    sha256 = models.CharField(max_length=64, default="")  # of the ciphertext
    complete = models.BooleanField(default=False)
    recipients = models.JSONField(default=list, blank=True)     # user ids
    downloaded_by = models.JSONField(default=list, blank=True)  # user ids
    all_downloaded_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["owner", "created_at"],
                                name="md1_blob_owner_day")]
# ---- /md1 ----


# ---- p1-bizagent ---- Business AI Agent for F-commerce sellers
# Pure logic: core/logic/bizagent.py; service: core/bizagent_service.py.
class SellerAgent(models.Model):
    """One per BusinessProfile: the seller's AI-agent settings + plan state.
    Plans are admin-editable (PricingConfig['seller_agent']); nothing is
    unlimited: plan replies first, then purchased credits (billing ai_sales)."""
    PLANS = [("none", "none"), ("trial", "trial"), ("starter", "starter"), ("pro", "pro")]
    business = models.OneToOneField("BusinessProfile", on_delete=models.CASCADE,
                                    related_name="seller_agent")
    ai_enabled = models.BooleanField(default=False)
    tone = models.CharField(max_length=12, default="friendly")   # friendly|formal|short
    hours = models.JSONField(default=dict, blank=True)          # {"start","end"} or {}
    approve_all = models.BooleanField(default=False)            # seller approves every reply
    cod_enabled = models.BooleanField(default=True)
    payment_link_enabled = models.BooleanField(default=False)   # licensed partner only
    low_stock_alert = models.BooleanField(default=True)
    daily_report = models.BooleanField(default=True)
    default_courier = models.CharField(max_length=12, blank=True, default="")
    courier_enc = models.TextField(blank=True, default="")      # Fernet {courier: {keys}}
    plan = models.CharField(max_length=10, choices=PLANS, default="none")
    period_start = models.DateTimeField(null=True, blank=True)
    period_end = models.DateTimeField(null=True, blank=True)
    replies_used = models.IntegerField(default=0)               # this period
    trial_started_at = models.DateTimeField(null=True, blank=True)  # once per business
    last_report_day = models.DateField(null=True, blank=True)
    last_low_stock_at = models.DateTimeField(null=True, blank=True)
    # ---- g1-bizagent ----
    # who replies: always (24/7, default) | outside_hours (AI only outside the
    # business hours) | off. A human reply pauses the AI in THAT chat for
    # resume_minutes (then the AI answers a customer who is still waiting).
    ai_mode = models.CharField(max_length=16, default="always")
    resume_minutes = models.IntegerField(default=15)
    rules_enabled = models.BooleanField(default=True)          # rule-first layer
    quiet_hours = models.JSONField(default=dict, blank=True)   # {"start","end"}: no follow-ups/pushes
    morning_summary = models.BooleanField(default=True)
    morning_hour = models.IntegerField(default=8)
    last_morning_day = models.DateField(null=True, blank=True)
    followups_enabled = models.BooleanField(default=False)
    followup_after_hours = models.IntegerField(default=3)
    followup_max = models.IntegerField(default=1)
    upsell_enabled = models.BooleanField(default=True)
    bundle_rules = models.JSONField(default=list, blank=True)  # [{"min_qty", "off_pct"}]
    auto_courier = models.BooleanField(default=False)          # book default courier on confirm
    vision_enabled = models.BooleanField(default=True)
    voice_enabled = models.BooleanField(default=True)
    comment_dm = models.BooleanField(default=True)
    widget_enabled = models.BooleanField(default=False)
    widget_key = models.CharField(max_length=48, blank=True, default="", db_index=True)
    widget_origins = models.TextField(blank=True, default="")
    # ---- /g1-bizagent ----
    # ---- biz-v2 ---- owner takeover idle hand-back + Asalify-proven caps
    takeover_idle_minutes = models.IntegerField(default=60)   # 0 = until handed back
    daily_ai_cap = models.IntegerField(default=300)           # paid AI calls / business / day
    thread_daily_cap = models.IntegerField(default=50)        # agent replies / chat / day
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class SellerChannel(models.Model):
    """A seller's connected OFFICIAL channel: a Facebook Page (Messenger +
    comments), an Instagram professional account, or a WhatsApp Cloud API
    number. token_enc = Fernet-encrypted Page/WA access token (never returned
    to a client). test_mode rows are for the self-test only: their own
    test_secret_enc signs webhooks and nothing is ever sent to Graph."""
    KINDS = [("messenger", "messenger"), ("instagram", "instagram"),
             ("whatsapp_cloud", "whatsapp_cloud"),
             ("website", "website")]   # g1: website chat widget
    business = models.ForeignKey("BusinessProfile", on_delete=models.CASCADE,
                                 related_name="seller_channels")
    kind = models.CharField(max_length=16, choices=KINDS)
    external_id = models.CharField(max_length=64)   # page id / IG id / phone_number_id
    display_name = models.CharField(max_length=120, blank=True, default="")
    token_enc = models.TextField(blank=True, default="")
    status = models.CharField(max_length=12, default="pending")  # pending|connected|error|disabled
    status_detail = models.CharField(max_length=200, blank=True, default="")
    enabled = models.BooleanField(default=True)
    test_mode = models.BooleanField(default=False)
    test_secret_enc = models.TextField(blank=True, default="")
    connected_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["kind", "external_id"],
                                               name="p1_channel_once")]


class BizWebhookEvent(models.Model):
    """Idempotency + work queue for Meta webhooks: ONE row per (source,
    event_id) — a redelivered message id is a no-op. Processed right after the
    fast 200 (worker thread) and swept by `manage.py bizagent_process`."""
    source = models.CharField(max_length=12)        # meta|whatsapp
    event_id = models.CharField(max_length=160)
    kind = models.CharField(max_length=12, default="message")
    payload = models.JSONField(default=dict, blank=True)
    status = models.CharField(max_length=10, default="pending")  # pending|done|error|skipped
    error = models.CharField(max_length=300, blank=True, default="")
    attempts = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    processed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["source", "event_id"],
                                               name="p1_webhook_once")]
        indexes = [models.Index(fields=["status", "created_at"], name="p1_evt_status")]


class BizAgentReport(models.Model):
    """The seller's daily sales/orders summary (in-app history; push too)."""
    business = models.ForeignKey("BusinessProfile", on_delete=models.CASCADE,
                                 related_name="agent_reports")
    day = models.DateField()
    data = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-day"]
        constraints = [models.UniqueConstraint(fields=["business", "day"],
                                               name="p1_report_once")]
# ---- g1-bizagent ---- rule-first FAQ, comment→product links, photo signatures
class BizFaq(models.Model):
    """A seller FAQ the RULE-FIRST layer answers without any AI (cost 0).
    status: approved (used) | suggested (learned from the owner's past replies,
    waiting for the seller) | rejected. Learned entries are NEVER used until
    the seller approves them; has_price flags an answer that states a price."""
    business = models.ForeignKey("BusinessProfile", on_delete=models.CASCADE,
                                 related_name="biz_faqs")
    question = models.TextField()
    answer = models.TextField()
    status = models.CharField(max_length=12, default="approved")
    source = models.CharField(max_length=10, default="manual")     # manual|learned
    has_price = models.BooleanField(default=False)
    hits = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-hits", "id"]
        indexes = [models.Index(fields=["business", "status"], name="g1_faq_status")]


class BizPostLink(models.Model):
    """Which product a Facebook/Instagram post shows — so a "price?" comment
    under that post gets that product's real price in the inbox."""
    business = models.ForeignKey("BusinessProfile", on_delete=models.CASCADE,
                                 related_name="biz_post_links")
    post_id = models.CharField(max_length=80)
    product = models.ForeignKey(Product, on_delete=models.CASCADE, related_name="post_links")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["business", "post_id"],
                                               name="g1_post_once")]


class BizProductSig(models.Model):
    """Perceptual signature of a catalog photo (average hash + difference hash
    + colour histogram; computed on our CPU with Pillow, no model weights) so
    a customer's photo/screenshot of the product matches at cost 0."""
    product = models.OneToOneField(Product, on_delete=models.CASCADE, related_name="visual_sig")
    photo_name = models.CharField(max_length=255, blank=True, default="")
    ahash = models.CharField(max_length=16, blank=True, default="")
    dhash = models.CharField(max_length=16, blank=True, default="")
    hist = models.JSONField(default=list, blank=True)
    updated_at = models.DateTimeField(auto_now=True)
# ---- /g1-bizagent ----
# ---- biz-v2 ---- Business AI Agent audit log (who did what, when)
class BizAuditLog(models.Model):
    """One row per agent/owner action worth reviewing: takeover, hand-back
    (manual or idle), owner reply, channel connect/disconnect, caps hit,
    image draft orders. Never stores tokens or message bodies."""
    business = models.ForeignKey("BusinessProfile", on_delete=models.CASCADE,
                                 related_name="biz_audit")
    actor = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL,
                              related_name="+")
    action = models.CharField(max_length=32)
    thread = models.ForeignKey("ChatThread", null=True, blank=True, on_delete=models.SET_NULL,
                               related_name="+")
    detail = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["business", "created_at"], name="bizv2_audit_day")]
# ---- /biz-v2 ----
# ---- /p1-bizagent ----
# ---- p2-money ---- direct sponsors, brand offers, ad exposure (monetization)
class Sponsor(models.Model):
    """A brand that buys direct placements from the owner (Owner Admin ->
    Sponsors). Contact details are owner-only and never sent to the app."""
    name = models.CharField(max_length=80)
    category = models.CharField(max_length=24, blank=True, default="")
    website = models.URLField(max_length=300, blank=True, default="")
    contact_name = models.CharField(max_length=80, blank=True, default="")
    contact_phone = models.CharField(max_length=24, blank=True, default="")
    contact_email = models.CharField(max_length=120, blank=True, default="")
    notes = models.TextField(blank=True, default="")
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name", "id"]


class SponsorCampaign(models.Model):
    """One sold campaign: ONE placement, a price (flat for the run, or CPM),
    a run window, an audience (always Free users only, optional interest
    categories + divisions), one creative (image + bn/en copy + link) and the
    owner's content-safety checklist. Only status=approved inside its window
    is ever served (core.logic.sponsor)."""
    PLACEMENTS = [("app_open", "app open"), ("hero", "home hero"),
                  ("discover", "discover card"),
                  ("community_post", "community / channel post"),
                  ("brand_offer", "brand offer")]
    STATUSES = [("draft", "draft"), ("approved", "approved"),
                ("paused", "paused"), ("rejected", "rejected"),
                ("ended", "ended")]
    PRICING = [("flat", "flat"), ("cpm", "cpm")]
    sponsor = models.ForeignKey(Sponsor, on_delete=models.CASCADE,
                                related_name="campaigns")
    name = models.CharField(max_length=80)
    placement = models.CharField(max_length=16, choices=PLACEMENTS)
    status = models.CharField(max_length=10, choices=STATUSES, default="draft")
    pricing = models.CharField(max_length=4, choices=PRICING, default="flat")
    price_bdt = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    budget_bdt = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    start_at = models.DateTimeField(null=True, blank=True)
    end_at = models.DateTimeField(null=True, blank=True)
    categories = models.JSONField(default=list, blank=True)
    divisions = models.JSONField(default=list, blank=True)
    daily_imp_cap = models.PositiveIntegerField(default=0)    # 0 = no cap
    priority = models.IntegerField(default=0)
    title_bn = models.CharField(max_length=80, blank=True, default="")
    title_en = models.CharField(max_length=80, blank=True, default="")
    body_bn = models.CharField(max_length=240, blank=True, default="")
    body_en = models.CharField(max_length=240, blank=True, default="")
    cta_bn = models.CharField(max_length=30, blank=True, default="")
    cta_en = models.CharField(max_length=30, blank=True, default="")
    link_url = models.URLField(max_length=300, blank=True, default="")
    image = models.ImageField(upload_to="sponsors/creative/", null=True,
                              blank=True)
    checklist = models.JSONField(default=dict, blank=True)
    safety_issues = models.JSONField(default=list, blank=True)
    approved_by = models.ForeignKey(User, null=True, blank=True,
                                    on_delete=models.SET_NULL,
                                    related_name="approved_campaigns")
    approved_at = models.DateTimeField(null=True, blank=True)
    discover_card = models.OneToOneField("DiscoverCard", null=True, blank=True,
                                         on_delete=models.SET_NULL,
                                         related_name="campaign")
    notes = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["placement", "status"],
                                name="p2_camp_place_status")]


class SponsorDailyStat(models.Model):
    """Per campaign per local day: what the sponsor report + P&L read."""
    campaign = models.ForeignKey(SponsorCampaign, on_delete=models.CASCADE,
                                 related_name="daily")
    date = models.DateField()
    impressions = models.PositiveIntegerField(default=0)
    clicks = models.PositiveIntegerField(default=0)
    hides = models.PositiveIntegerField(default=0)
    notifs = models.PositiveIntegerField(default=0)

    class Meta:
        unique_together = [("campaign", "date")]
        ordering = ["date"]


class SponsorSeen(models.Model):
    """Dedupe/fraud ledger: per user per campaign per day, how many
    impressions / clicks were counted (counted impressions are capped)."""
    campaign = models.ForeignKey(SponsorCampaign, on_delete=models.CASCADE,
                                 related_name="seen")
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="sponsor_seen")
    date = models.DateField()
    impressions = models.PositiveIntegerField(default=0)
    clicks = models.PositiveIntegerField(default=0)

    class Meta:
        unique_together = [("campaign", "user", "date")]


class AdExposure(models.Model):
    """Per user per local day per placement + source (direct | admob): how
    many ads this user really saw. Drives the server-side app-open cap and
    the retention-impact buckets in Owner Admin. Counts only — no content."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="ad_exposure")
    date = models.DateField()
    placement = models.CharField(max_length=16)
    source = models.CharField(max_length=6, default="direct")
    count = models.PositiveIntegerField(default=0)
    last_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = [("user", "date", "placement", "source")]
        indexes = [models.Index(fields=["date", "placement"],
                                name="p2_exposure_day_place")]


class OfferPrefs(models.Model):
    """Brand offers by interest (Settings -> Offers & brands): favourite
    categories + brands, muted brands, hidden campaigns, and the master
    "offer notifications" switch."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="offer_prefs")
    categories = models.JSONField(default=list, blank=True)
    brands = models.JSONField(default=list, blank=True)        # sponsor ids
    muted_brands = models.JSONField(default=list, blank=True)  # sponsor ids
    hidden_campaigns = models.JSONField(default=list, blank=True)
    notifs_on = models.BooleanField(default=True)
    division = models.CharField(max_length=16, blank=True, default="")
    onboarding_done = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)


class OfferNotifLog(models.Model):
    """One offer notification sent to one user (the daily cap counts these)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="offer_notifs")
    campaign = models.ForeignKey(SponsorCampaign, on_delete=models.CASCADE,
                                 related_name="notif_log")
    sent_at = models.DateTimeField(default=timezone.now, db_index=True)

    class Meta:
        unique_together = [("user", "campaign")]
# ---- /p2-money ----
# ---- p4-world ---- Unseen World: shared feed cache, owner-entered values,
# per-user Today prefs, MCQ score history, web-answer cache/log.
class WorldFeed(models.Model):
    """One external data source (RSS feed, weather city, currency, sports).
    The server fetches it on a schedule (world_refresh) and every user reads
    this cached copy, so a feed is fetched once for everyone. Holds the
    owner-facing status: last refresh, last error, calls + cost today."""
    slug = models.CharField(max_length=60, unique=True)
    kind = models.CharField(max_length=20, default="news")   # news|weather|fx|sports
    enabled = models.BooleanField(default=True)
    payload = models.JSONField(default=dict, blank=True)
    fetched_at = models.DateTimeField(null=True, blank=True)
    last_ok_at = models.DateTimeField(null=True, blank=True)
    last_error = models.CharField(max_length=300, blank=True, default="")
    last_error_at = models.DateTimeField(null=True, blank=True)
    ok_count = models.PositiveIntegerField(default=0)
    error_count = models.PositiveIntegerField(default=0)
    calls_day = models.DateField(null=True, blank=True)
    calls_today = models.PositiveIntegerField(default=0)
    cost_usd_today = models.FloatField(default=0.0)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["kind", "slug"]


class WorldAdminValue(models.Model):
    """A value the OWNER types in Owner Admin because the official source has
    no API (BAJUS gold, BPC fuel). Shown to users with "updated by Assisto on
    <date>" and the official link. Every edit is written to OwnerAudit."""
    key = models.CharField(max_length=40, unique=True)
    value = models.DecimalField(max_digits=12, decimal_places=2, null=True, blank=True)
    effective_date = models.DateField(null=True, blank=True)
    note = models.CharField(max_length=200, blank=True, default="")
    updated_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="+")
    updated_at = models.DateTimeField(auto_now=True)


class WorldPrefs(models.Model):
    """Per-user Unseen World settings, synced across the user's phones:
    which Today cards are on, the city for prayer/weather, job-alert types."""
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="world_prefs")
    cards = models.JSONField(default=dict, blank=True)       # {card_id: bool}
    city = models.CharField(max_length=40, blank=True, default="dhaka")
    job_types = models.JSONField(default=list, blank=True)   # ["govt", "bank", ...]
    job_alerts = models.BooleanField(default=False)
    last_job_alert_at = models.DateTimeField(null=True, blank=True)
    seen_job_ids = models.JSONField(default=list, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class WorldMcqAttempt(models.Model):
    """One finished BCS-practice round (scored on the server)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="world_mcq_attempts")
    topic = models.CharField(max_length=20, default="mixed")
    total = models.PositiveIntegerField(default=0)
    correct = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]


class WorldAnswer(models.Model):
    """A web-search AI answer (question hash + language), kept for a short
    cache window and for the owner's cost view. Holds no personal data
    beyond the asking user."""
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="+")
    qhash = models.CharField(max_length=64, db_index=True)
    lang = models.CharField(max_length=2, default="bn")
    question = models.CharField(max_length=300, blank=True, default="")
    answer = models.TextField(blank=True, default="")
    sources = models.JSONField(default=list, blank=True)
    provider = models.CharField(max_length=20, blank=True, default="")
    cached = models.BooleanField(default=False)
    credits = models.PositiveIntegerField(default=0)
    cost_usd = models.FloatField(default=0.0)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at"]
# ---- /p4-world ----


# ---- cde-chat ---- order 6 D + E: shared per-chat theme + nicknames.
class ChatDecor(models.Model):
    """ONE row per chat, shared by every side of it: a 1:1 pair
    (kind="member", key="<low uid>:<high uid>") or a group (kind="group",
    key="<group id>"). Holds only a theme id and the nicknames — never a key,
    never a photo: a custom photo theme is an E2E media message (the server
    only knows `theme == "custom"`). The phones learn changes through E2E
    control messages; this row lets a reinstall / second phone catch up."""
    kind = models.CharField(max_length=8)                 # member | group
    key = models.CharField(max_length=40)
    theme = models.CharField(max_length=24, blank=True, default="")
    theme_by = models.IntegerField(null=True, blank=True)  # user id
    theme_at = models.DateTimeField(null=True, blank=True)
    # {"<user id>": {"n": nickname, "by": user id, "at": iso}}
    nicknames = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("kind", "key")]
# ---- /cde-chat ----

# ---- p5-growth ----
class ActiveDay(models.Model):
    """One row per user per local (Asia/Dhaka) day the user used the API with
    their token. Written at most once a day per user (core.growth.touch).
    `cohort_day` (signup date) + `since_signup` (days after signup) are
    denormalised so D1/D7/D30 retention and activation are single indexed
    counts. Holds no content — only that the account was used that day."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="active_days")
    day = models.DateField()
    cohort_day = models.DateField()
    since_signup = models.PositiveIntegerField(default=0)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "day"],
                                               name="p5_active_day_once")]
        indexes = [models.Index(fields=["cohort_day", "since_signup"],
                                name="p5_active_cohort_idx"),
                   models.Index(fields=["day"], name="p5_active_day_idx")]


class InstallPing(models.Model):
    """Anonymous first-app-open marker. The app makes a random install id on
    first open and sends it once; we keep only its SHA-256. A reinstall (new
    id) counts again. `user` is linked later when the same install signs in."""
    id_hash = models.CharField(max_length=64, unique=True)
    platform = models.CharField(max_length=12, blank=True, default="android")
    app_version = models.CharField(max_length=24, blank=True, default="")
    ref_code = models.CharField(max_length=12, blank=True, default="")
    device_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="install_pings")
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)


class ReferralClaim(models.Model):
    """Invite-code referral: the invitee typed the inviter's code. Credits for
    BOTH are granted only when the invitee is ACTIVATED (core.growth). One
    claim per invitee; anti-abuse fields (device / phone hash) survive an
    account deletion so a re-registered phone cannot earn again."""
    STATES = [("pending", "pending"), ("rewarded", "rewarded"),
              ("rejected", "rejected")]
    inviter = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                related_name="referral_claims_made")
    invitee = models.OneToOneField(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="referral_claim")
    code = models.CharField(max_length=12)
    device_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    phone_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    state = models.CharField(max_length=10, choices=STATES, default="pending")
    reason = models.CharField(max_length=32, blank=True, default="")
    inviter_credits = models.PositiveIntegerField(default=0)
    invitee_credits = models.PositiveIntegerField(default=0)
    cost_bdt = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    claimed_at = models.DateTimeField(auto_now_add=True, db_index=True)
    decided_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-claimed_at"]
        indexes = [models.Index(fields=["inviter", "state", "decided_at"],
                                name="p5_claim_inviter_idx"),
                   models.Index(fields=["state", "decided_at"],
                                name="p5_claim_state_idx")]


class FoundingSeat(models.Model):
    """Automatic Founding Member seat: the first N ACTIVATED accounts (N =
    Pricing → referral.founding_auto_seats) get a numbered badge and a
    one-time credit perk. Separate from the owner's manual /owner/founders
    grant (free Premium months), which is unchanged."""
    user = models.OneToOneField(User, on_delete=models.SET_NULL, null=True,
                                related_name="founding_seat")
    number = models.PositiveIntegerField(unique=True)
    credits = models.PositiveIntegerField(default=0)
    cost_bdt = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    granted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["number"]
# ---- /p5-growth ----


# ====================================================================
# ---- e2e-recover ---- (owner launch-blocker 24 Oct: after a reinstall every
# older 1:1 message showed "cannot be decrypted"). Three pieces, all
# ciphertext-only — the server never sees a private key, a PIN or plaintext:
#   * E2KeyBackup       — the user's KEY RING sealed on the phone with a key
#                         derived from the Security PIN (scrypt + HKDF). The
#                         server stores only a HASH of a separate auth key and
#                         releases the sealed blob after a correct proof, with
#                         wrong-PIN counting + lockout.
#   * CircleMessageCopy — a per-recipient REPLACEMENT copy of a 1:1 message,
#                         re-encrypted by the OTHER party's phone to the
#                         recipient's NEW key. The original row's ciphertext
#                         is never touched.
#   * E2ResendRequest   — "please re-share this chat to my current key"
#                         (Signal-style retry receipt / key change).
class E2KeyBackup(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE,
                                related_name="e2_key_backup")
    salt = models.CharField(max_length=64, default="")
    kdf = models.JSONField(default=dict, blank=True)
    auth_hash = models.CharField(max_length=128, default="")
    blob = models.TextField(default="")          # sealed key ring (base64)
    nonce = models.CharField(max_length=64, default="")
    key_ids = models.JSONField(default=list, blank=True)
    current_key_id = models.CharField(max_length=64, blank=True, default="")
    # Up to 3 earlier backups sealed under a DIFFERENT PIN/salt (a reinstall
    # that skipped restore and later set a PIN never destroys the old ring).
    archive = models.JSONField(default=list, blank=True)
    wrong_count = models.IntegerField(default=0)       # in the current hour
    window_start = models.DateTimeField(null=True, blank=True)
    wrong_total = models.IntegerField(default=0)       # consecutive
    locked_until = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class CircleMessageCopy(models.Model):
    message = models.ForeignKey(CircleMessage, on_delete=models.CASCADE,
                                related_name="e2_copies")
    for_user = models.ForeignKey(User, on_delete=models.CASCADE,
                                 related_name="e2_copies_for")
    by_user = models.ForeignKey(User, on_delete=models.CASCADE,
                                related_name="e2_copies_by")
    ciphertext = models.TextField(default="")
    nonce = models.CharField(max_length=128, default="")
    sender_key_id = models.CharField(max_length=64, blank=True, default="")
    scheme = models.CharField(max_length=64, blank=True, default="")
    key_id = models.CharField(max_length=64, blank=True, default="")  # for_user's key
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("message", "for_user")]


class E2ResendRequest(models.Model):
    requester = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="e2_resend_made")
    target = models.ForeignKey(User, on_delete=models.CASCADE,
                               related_name="e2_resend_got")
    key_id = models.CharField(max_length=64, default="")
    whole = models.BooleanField(default=False)
    message_ids = models.JSONField(default=list, blank=True)
    reason = models.CharField(max_length=16, default="decrypt")
    asks = models.IntegerField(default=0)
    notified_at = models.DateTimeField(null=True, blank=True)
    fulfilled_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("requester", "target", "key_id")]
# ---- /e2e-recover ----

# ---- e2e-groups ---- (peer-assisted re-share for GROUP chats). A group
# message is sealed per member (per_recipient); after a member's key changes
# any OTHER member whose own copy opens re-encrypts it to the new key and
# uploads a CircleMessageCopy (for_user = that member). One request per
# (requester, group, key) — every member's phone can answer it; the server
# keeps the FIRST copy per (message, for_user) (the original sender's copy
# may replace another member's).
class E2GroupResendRequest(models.Model):
    requester = models.ForeignKey(User, on_delete=models.CASCADE,
                                  related_name="e2_group_resend_made")
    group = models.ForeignKey(CircleGroup, on_delete=models.CASCADE,
                              related_name="e2_resend_requests")
    key_id = models.CharField(max_length=64, default="")
    whole = models.BooleanField(default=False)
    message_ids = models.JSONField(default=list, blank=True)
    reason = models.CharField(max_length=16, default="decrypt")
    asks = models.IntegerField(default=0)
    # helpers (user ids) that answered this round — not listed to them again
    # until the requester asks for more.
    served_by = models.JSONField(default=list, blank=True)
    notified_at = models.DateTimeField(null=True, blank=True)
    fulfilled_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("requester", "group", "key_id")]
# ---- /e2e-groups ----

# ---- calls-health ---- (owner 24 Oct: "Call server busy", "rang then dropped")
# CallSession.push_sent: an FCM ring was handed to at least one registered
# device of the callee -> the ring-ack window is the full ring time (see
# call_signal.OFFLINE_ACK_PUSHED_S), never the 20 s "offline" cut.
CallSession.add_to_class("push_sent", models.BooleanField(default=False))


class CallHealthEvent(models.Model):
    """One call-SETUP failure (lightweight; Owner Admin -> Calls health card).
    Successful steps are read from CallRecord/CallSession; only what those
    rows cannot show is logged here: a throttled GET rtc/turn (server) and a
    setup step the PHONE gave up on after its silent retries (client report,
    POST rtc/health). Pruned after 30 days by call_health.log_event."""
    STEPS = ("rtc_config", "place", "accept", "push", "ring_ack", "ice")
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="+")
    step = models.CharField(max_length=16)
    code = models.CharField(max_length=24, blank=True, default="")
    source = models.CharField(max_length=8, default="server")  # server|client
    call_id = models.IntegerField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-id"]
# ---- /calls-health ----


# ---- ring-everywhere ---- (owner 24 Oct: "CALLS MUST RING LIKE WHATSAPP ON
# EVERY PHONE"). Per call: when the FCM ring was handed to Google (and its
# message id), when the callee phone's NATIVE FCM service confirmed it got the
# push (delivered — works without Flutter), how many bounded resends went out,
# the callee phone's brand / model / Android SDK (no PII: for the Owner Admin
# delivery-rate table) and whether a never-delivered missed call is still
# waiting to be shown when that phone next comes online. Device rows carry the
# same brand / model / sdk from token registration.
CallSession.add_to_class("fcm_sent_at", models.DateTimeField(null=True, blank=True))
CallSession.add_to_class("fcm_msg_id", models.CharField(max_length=160, blank=True, default=""))
CallSession.add_to_class("delivered_at", models.DateTimeField(null=True, blank=True))
CallSession.add_to_class("push_resends", models.PositiveSmallIntegerField(default=0))
CallSession.add_to_class("last_push_at", models.DateTimeField(null=True, blank=True))
CallSession.add_to_class("callee_brand", models.CharField(max_length=32, blank=True, default=""))
CallSession.add_to_class("callee_model", models.CharField(max_length=48, blank=True, default=""))
CallSession.add_to_class("callee_sdk", models.PositiveSmallIntegerField(default=0))
CallSession.add_to_class("missed_pending", models.BooleanField(default=False))
Device.add_to_class("brand", models.CharField(max_length=32, blank=True, default=""))
Device.add_to_class("model", models.CharField(max_length=48, blank=True, default=""))
Device.add_to_class("sdk_int", models.PositiveSmallIntegerField(default=0))
# ---- /ring-everywhere ----


# ---- calls95 ---- ring delivery >= 95 %: the callee's app version at call
# time (stamped at placement from the newest Device, overwritten by the
# native ack) and one Owner Admin trend row per day (call_ack.snapshot_days;
# survives account purges that cascade-delete CallRecords). No PII: counts
# per brand / Android / app version only.
CallSession.add_to_class("callee_app", models.CharField(max_length=24, blank=True, default=""))


class CallDeliveryDaily(models.Model):
    date = models.DateField(unique=True)
    attempts = models.IntegerField(default=0)       # judged ring pushes
    delivered = models.IntegerField(default=0)
    early_cancels = models.IntegerField(default=0)  # caller hung up < 4 s (excluded)
    by_brand = models.JSONField(default=dict, blank=True)    # {brand: [attempts, delivered]}
    by_android = models.JSONField(default=dict, blank=True)  # {sdk: [a, d]}
    by_app = models.JSONField(default=dict, blank=True)      # {version: [a, d]}
    causes = models.JSONField(default=dict, blank=True)      # {miss cause: n}
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-date"]
# ---- /calls95 ----


# ---- play-vitals ---- Google Play Vitals (Play Developer Reporting API),
# pulled daily by manage.py play_vitals_pull (core.play_vitals). Read-only
# mirror of Google's numbers for Owner Admin → Play Vitals. No user data:
# rates and distinct-user counts per day, and Google's error-issue clusters.
class PlayVitalDaily(models.Model):
    METRICS = ("crash", "anr", "user_perceived_crash", "user_perceived_anr")
    DIMS = ("overall", "device", "api", "version")
    date = models.DateField(db_index=True)
    metric = models.CharField(max_length=24)
    dim_kind = models.CharField(max_length=12, default="overall")
    dim_value = models.CharField(max_length=120, blank=True, default="")
    label = models.CharField(max_length=120, blank=True, default="")   # Google's valueLabel
    rate = models.FloatField(null=True, blank=True)       # fraction (0.0123 = 1.23 %)
    users = models.IntegerField(null=True, blank=True)    # distinct users that day
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = (("date", "metric", "dim_kind", "dim_value"),)
        indexes = [models.Index(fields=["metric", "dim_kind", "date"])]


class PlayErrorIssue(models.Model):
    issue_id = models.CharField(max_length=64, unique=True)
    type = models.CharField(max_length=24, blank=True, default="")   # CRASH | ANR | NON_FATAL
    cause = models.CharField(max_length=400, blank=True, default="")
    location = models.CharField(max_length=400, blank=True, default="")
    first_version = models.CharField(max_length=24, blank=True, default="")
    last_version = models.CharField(max_length=24, blank=True, default="")
    first_api = models.IntegerField(null=True, blank=True)
    last_api = models.IntegerField(null=True, blank=True)
    users = models.IntegerField(default=0)
    reports = models.IntegerField(default=0)
    issue_uri = models.CharField(max_length=400, blank=True, default="")
    sample_stack = models.TextField(blank=True, default="")    # trimmed to ~4 KB
    sample_device = models.CharField(max_length=120, blank=True, default="")
    sample_os = models.CharField(max_length=24, blank=True, default="")
    sample_version = models.CharField(max_length=24, blank=True, default="")
    last_seen = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=8, default="new")      # new | known
    notified = models.BooleanField(default=False)
    first_seen_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-users", "-reports"]
# ---- /play-vitals ----


# ---- feature-flags ---- per-feature visibility switch (owner rule 26 Oct:
# a feature is visible ONLY when all 9 Definition-of-Done checks pass; until
# then it sits behind its flag). Registry + resolution: core.feature_flags.
# Owner Admin → Features edits these rows; every change is written to
# OwnerAudit (action "feature_flag"). A missing row = the registry default.
class FeatureFlag(models.Model):
    STATUSES = ("done", "in_progress", "hidden")
    key = models.CharField(max_length=48, unique=True)
    enabled_all = models.BooleanField(default=True)       # on for everyone
    enabled_play = models.BooleanField(default=True)      # also on in the Play build
    rollout_pct = models.PositiveSmallIntegerField(default=100)   # 0-100
    allow_user_ids = models.JSONField(default=list, blank=True)   # testers who always see it
    note = models.TextField(blank=True, default="")       # English note
    note_bn = models.TextField(blank=True, default="")    # Bangla note
    dod_status = models.CharField(max_length=12, default="in_progress")
    dod_checks = models.JSONField(default=list, blank=True)       # 9 bools (DoD order)
    updated_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="+")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["key"]
# ---- /feature-flags ----


# ---- booking-bot ---- (big-week item I) appointment / service booking for a
# Business: services, weekly hours, days off, optional staff, capacity; a
# public link lifeassisto.com/b/<slug>; the business AI agent offers REAL free
# slots only. Double booking is impossible at the DB level: every booking
# holds one BookingSlotLock row per 5-minute granule per seat, and
# (business, resource, seat, at) is UNIQUE. Pure rules: core.logic.booking;
# DB layer: core.booking_service; API: core.booking_views; flag `booking_bot`.
class BookingPage(models.Model):
    business = models.OneToOneField(BusinessProfile, on_delete=models.CASCADE,
                                    related_name="booking_page")
    slug = models.SlugField(max_length=40, unique=True)
    enabled = models.BooleanField(default=False)          # taking bookings
    title = models.CharField(max_length=120, blank=True, default="")
    about = models.CharField(max_length=300, blank=True, default="")
    address = models.CharField(max_length=200, blank=True, default="")
    weekly_hours = models.JSONField(default=dict, blank=True)  # {"0": [["10:00","18:00"]], ...} Mon=0
    days_off = models.JSONField(default=list, blank=True)      # ["2026-11-01", ...]
    capacity = models.PositiveSmallIntegerField(default=1)     # parallel bookings (no staff)
    step_min = models.PositiveSmallIntegerField(default=30)    # slot grid
    min_notice_min = models.PositiveIntegerField(default=60)
    max_days_ahead = models.PositiveSmallIntegerField(default=30)
    auto_confirm = models.BooleanField(default=False)
    cancel_hours = models.PositiveSmallIntegerField(default=2)   # customer may cancel/reschedule until N h before
    max_pending_per_phone = models.PositiveSmallIntegerField(default=2)
    chat_bot = models.BooleanField(default=True)          # AI agent offers slots in chats
    sms_reminders = models.BooleanField(default=False)    # paid from the owner's credits
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class BookingStaff(models.Model):
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="booking_staff")
    name = models.CharField(max_length=80)
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name", "id"]


class BookingService(models.Model):
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="booking_services")
    name = models.CharField(max_length=80)
    duration_min = models.PositiveSmallIntegerField(default=30)
    buffer_min = models.PositiveSmallIntegerField(default=0)
    price_bdt = models.PositiveIntegerField(default=0)    # shown only; 0 = not shown
    staff_ids = models.JSONField(default=list, blank=True)  # [] = any staff / no staff
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name", "id"]


class Booking(models.Model):
    STATUSES = ("requested", "confirmed", "done", "no_show", "cancelled")
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="bookings")
    service = models.ForeignKey(BookingService, null=True, on_delete=models.SET_NULL,
                                related_name="bookings")
    service_name = models.CharField(max_length=80, blank=True, default="")
    staff = models.ForeignKey(BookingStaff, null=True, blank=True,
                              on_delete=models.SET_NULL, related_name="bookings")
    customer_user = models.ForeignKey(User, null=True, blank=True,
                                      on_delete=models.SET_NULL, related_name="bookings_made")
    customer_name = models.CharField(max_length=80, blank=True, default="")
    customer_phone = models.CharField(max_length=24, blank=True, default="", db_index=True)
    start = models.DateTimeField(db_index=True)
    end = models.DateTimeField()                  # service end (buffer excluded)
    block_end = models.DateTimeField()            # end + buffer (what the locks cover)
    status = models.CharField(max_length=12, default="requested")
    cancelled_by = models.CharField(max_length=12, blank=True, default="")  # customer|business|system
    channel = models.CharField(max_length=20, default="web")   # web|app|manual|whatsapp_cloud|messenger|instagram|website
    thread = models.ForeignKey("ChatThread", null=True, blank=True,
                               on_delete=models.SET_NULL, related_name="bookings")
    note = models.CharField(max_length=300, blank=True, default="")
    ip_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    manage_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    reminders_sent = models.PositiveSmallIntegerField(default=0)
    reminded = models.JSONField(default=list, blank=True)     # ["24h","2h"]
    reschedules = models.PositiveSmallIntegerField(default=0)
    history = models.JSONField(default=list, blank=True)      # [{at, by, what}]
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["start", "id"]
        indexes = [models.Index(fields=["business", "start"]),
                   models.Index(fields=["business", "customer_phone", "status"]),
                   models.Index(fields=["status", "start"])]


class BookingSlotLock(models.Model):
    """One 5-minute granule of one seat of one resource (staff id, or 0 for
    the business' shared capacity). UNIQUE → a second booking for the same
    seat + time fails inside the INSERT, whatever the race."""
    booking = models.ForeignKey(Booking, on_delete=models.CASCADE, related_name="locks")
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="+")
    resource = models.PositiveIntegerField(default=0)
    seat = models.PositiveSmallIntegerField(default=0)
    at = models.DateTimeField()

    class Meta:
        constraints = [models.UniqueConstraint(
            fields=["business", "resource", "seat", "at"], name="booking_slot_unique")]


class BookingContact(models.Model):
    """Per business + customer phone: blocked by the business, or the customer
    said STOP (no reminders)."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="booking_contacts")
    phone = models.CharField(max_length=24)
    blocked = models.BooleanField(default=False)
    stop = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["business", "phone"],
                                               name="booking_contact_unique")]
# ---- /booking-bot ----

# ---- retention1 ---- RETENTION AUTOMATION (big-week H). Pure logic:
# core/logic/retention.py; shared customer-messaging guard (caps, quiet hours,
# STOP, Meta 24 h): core/logic/msg_guard.py. Audience = the business's OWN
# customers only (sales / khata / asked) — there is no import of any list.
class RetentionSettings(models.Model):
    """The owner's caps for ONE business (may only LOWER the server max)."""
    business = models.OneToOneField(BusinessProfile, on_delete=models.CASCADE,
                                    related_name="retention_settings")
    per_customer_day = models.IntegerField(default=1)
    per_customer_week = models.IntegerField(default=2)
    business_daily = models.IntegerField(default=100)
    updated_at = models.DateTimeField(auto_now=True)


class RetentionAutomation(models.Model):
    """One owner-set automation: trigger (kind + params), message template
    (bn/en, variables), channel, send hour, on/off."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="retention_automations")
    kind = models.CharField(max_length=20)            # retention.KINDS
    name = models.CharField(max_length=80, blank=True, default="")
    enabled = models.BooleanField(default=False)
    params = models.JSONField(default=dict, blank=True)
    template_bn = models.TextField(blank=True, default="")
    template_en = models.TextField(blank=True, default="")
    channel = models.CharField(max_length=12, default="in_app")   # retention.CHANNELS
    # WhatsApp outside the 24 h window: {name, lang, category, approved, has_stop}
    wa_template = models.JSONField(default=dict, blank=True)
    send_hour = models.IntegerField(default=11)       # Dhaka hour 9..20
    last_run_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["created_at", "id"]
        indexes = [models.Index(fields=["business", "enabled"])]


class RetentionSend(models.Model):
    """One automated message to one customer for one trigger event (ref_key
    makes it once-only). status: sent | delivered | read | failed | blocked |
    skipped. Only sent/delivered/read count toward the caps."""
    automation = models.ForeignKey(RetentionAutomation, on_delete=models.CASCADE,
                                   related_name="sends")
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="retention_sends")
    audience_key = models.CharField(max_length=80)    # normalised phone / psid:<id>
    ref_key = models.CharField(max_length=80)
    customer = models.ForeignKey(Customer, null=True, blank=True,
                                 on_delete=models.SET_NULL, related_name="retention_sends")
    party = models.ForeignKey(KhataParty, null=True, blank=True,
                              on_delete=models.SET_NULL, related_name="retention_sends")
    recipient = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL,
                                  related_name="retention_received")
    customer_name = models.CharField(max_length=120, blank=True, default="")
    channel = models.CharField(max_length=12, default="in_app")
    lang = models.CharField(max_length=2, default="bn")
    status = models.CharField(max_length=12, default="sent", db_index=True)
    reason = models.CharField(max_length=60, blank=True, default="")
    text = models.TextField(blank=True, default="")
    credits = models.IntegerField(default=0)
    chat_message = models.ForeignKey("Message", null=True, blank=True,
                                     on_delete=models.SET_NULL, related_name="+")
    thread = models.ForeignKey(ChatThread, null=True, blank=True,
                               on_delete=models.SET_NULL, related_name="retention_sends")
    created_at = models.DateTimeField(default=timezone.now, db_index=True)
    delivered_at = models.DateTimeField(null=True, blank=True)
    read_at = models.DateTimeField(null=True, blank=True)
    replied_at = models.DateTimeField(null=True, blank=True)
    reply_text = models.CharField(max_length=500, blank=True, default="")
    opted_out_at = models.DateTimeField(null=True, blank=True)
    purchase_sale = models.ForeignKey(Sale, null=True, blank=True,
                                      on_delete=models.SET_NULL, related_name="+")
    purchase_poisha = models.BigIntegerField(default=0)

    class Meta:
        ordering = ["-created_at", "-id"]
        constraints = [models.UniqueConstraint(
            fields=["automation", "audience_key", "ref_key"], name="ret_send_once")]
        indexes = [models.Index(fields=["business", "audience_key", "created_at"]),
                   models.Index(fields=["business", "created_at"]),
                   models.Index(fields=["recipient", "created_at"])]


class BizOptOut(models.Model):
    """A customer said STOP to ONE business — honoured at once by every
    automation of that business on every channel (core/logic/msg_guard)."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="opt_outs")
    key = models.CharField(max_length=80)
    source = models.CharField(max_length=16, default="in_app")  # in_app|sms_link|chat|owner
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["business", "key"],
                                               name="biz_optout_once")]


class RetentionStockAsk(models.Model):
    """The owner noted that THIS customer asked for THIS product (no stock
    now). When stock is back the back_in_stock automation tells them once."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="stock_asks")
    product = models.ForeignKey(Product, on_delete=models.CASCADE, related_name="stock_asks")
    customer = models.ForeignKey(Customer, on_delete=models.CASCADE, related_name="stock_asks")
    created_at = models.DateTimeField(auto_now_add=True)
    notified_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["product", "customer"],
                                               name="stock_ask_once")]
# ---- /retention1 ----


# ---- budget-remittance ---- (flag budget_remittance, default OFF)
# The RECEIVER side of remittance: money a family in Bangladesh gets from a
# relative abroad, and the family budget made from it. Financial values
# (amounts, rate, taka, sender, channel, notes, bills, expected amount) are
# ENCRYPTED at the application level (Fernet; core.remittance_service) in
# `enc`. In clear only what queries need: user, client id, date, month.
# Honest: the key lives on the same server — this protects DB dumps and
# backups, not a fully taken-over server.
class RemittanceEntry(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="remittances")
    client_id = models.CharField(max_length=36)     # idempotent offline sync
    received_on = models.DateField()
    month = models.CharField(max_length=7)          # YYYY-MM (Asia/Dhaka)
    enc = models.TextField(blank=True, default="")  # Fernet(JSON)
    source = models.CharField(max_length=8, default="manual")  # manual|voice|text
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-received_on", "-id"]
        constraints = [models.UniqueConstraint(fields=["user", "client_id"],
                                               name="remit_client_once")]
        indexes = [models.Index(fields=["user", "month"])]


class RemittanceProfile(models.Model):
    """One per user: expected monthly remittance, bills paid from it (all in
    `enc`), the linked savings goal (the existing SavingsGoal) and the
    once-per-month 'not arrived yet' bookkeeping."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="remit_profile")
    enc = models.TextField(blank=True, default="")
    goal = models.ForeignKey(SavingsGoal, null=True, blank=True, on_delete=models.SET_NULL,
                             related_name="+")
    guide_done = models.BooleanField(default=False)
    missing_alert_month = models.CharField(max_length=7, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)
# ---- /budget-remittance ----



# ====================================================================
# ---- billing-v2 ---- (owner order 27 Oct: BILLING, CREDIT AND REFUND
# HARDENING, rules A-V; core/credits.py is the engine)
class PaidOrder(models.Model):
    """ONE row per real payment order (a Play orderId — every renewal has its
    own — or an EPS merchant tx). Grants, refunds and the payment audit all key
    off it. The user link survives account deletion as a tombstone."""
    STATUS = [("paid", "paid"), ("refunded", "refunded"),
              ("partial", "partially refunded"), ("voided", "voided by Google")]
    channel = models.CharField(max_length=10)                 # play|gateway
    order_id = models.CharField(max_length=80)
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="paid_orders")
    owner_ref = models.CharField(max_length=40, blank=True, default="")
    token_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    sku = models.CharField(max_length=32, blank=True, default="")
    kind = models.CharField(max_length=8)                     # sub|pack|seller
    plan = models.CharField(max_length=16, blank=True, default="")
    months = models.PositiveSmallIntegerField(default=0)
    price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    currency = models.CharField(max_length=3, default="BDT")
    price_source = models.CharField(max_length=16, blank=True, default="")
    is_test = models.BooleanField(default=False)
    purchased_at = models.DateTimeField()
    period_start = models.DateTimeField(null=True, blank=True)
    period_end = models.DateTimeField(null=True, blank=True)
    credits_planned = models.IntegerField(default=0)
    status = models.CharField(max_length=10, choices=STATUS, default="paid")
    refunded_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    refund_source = models.CharField(max_length=10, blank=True, default="")  # owner|google
    refunded_at = models.DateTimeField(null=True, blank=True)
    raw = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-purchased_at", "-id"]
        constraints = [models.UniqueConstraint(fields=["channel", "order_id"],
                                               name="bill2_paid_order_once")]
        indexes = [models.Index(fields=["user", "purchased_at"])]


class CreditLot(models.Model):
    """One grant of credits into ONE bucket. `remaining` is usable now (it is
    part of User.ai_credits); `locked` is the staged-unlock part (not yet in
    the balance). scheduled = a future annual month, not granted yet.
    Invariant: sum(active remaining) == User.ai_credits == sum(ledger)."""
    STATUS = [("scheduled", "scheduled"), ("active", "active"), ("closed", "closed")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="credit_lots")
    bucket = models.CharField(max_length=10)
    granted = models.IntegerField(default=0)
    remaining = models.IntegerField(default=0)
    locked = models.IntegerField(default=0)
    unlocks_at = models.DateTimeField(null=True, blank=True)
    spent = models.IntegerField(default=0)
    starts_at = models.DateTimeField(default=timezone.now)
    expires_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=10, choices=STATUS, default="active")
    close_reason = models.CharField(max_length=40, blank=True, default="")
    source_type = models.CharField(max_length=24, blank=True, default="")
    source_id = models.CharField(max_length=120, blank=True, default="", db_index=True)
    order = models.ForeignKey(PaidOrder, on_delete=models.SET_NULL, null=True, blank=True,
                              related_name="lots")
    grant_key = models.CharField(max_length=160, null=True, blank=True, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["id"]
        indexes = [models.Index(fields=["user", "status", "bucket"]),
                   models.Index(fields=["status", "expires_at"]),
                   models.Index(fields=["status", "unlocks_at"])]


class CreditAccount(models.Model):
    """Per-user refund / abuse state (rule L): Google refunds counted, a
    second one blocks new purchases until the owner unblocks."""
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="credit_account")
    refund_count = models.PositiveIntegerField(default=0)
    flagged = models.BooleanField(default=False)
    flag_reason = models.CharField(max_length=120, blank=True, default="")
    purchase_blocked = models.BooleanField(default=False)
    blocked_at = models.DateTimeField(null=True, blank=True)
    unblocked_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                     blank=True, related_name="+")
    unblocked_at = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)


class RefundRequest(models.Model):
    """A user's refund request (rule K). It never refunds by itself; the owner
    decides in Owner Admin -> Payments -> Refund requests."""
    STATUS = [("pending", "pending"), ("approved", "approved"),
              ("manual", "approved - manual step left"), ("rejected", "rejected")]
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="refund_requests")
    order = models.ForeignKey(PaidOrder, on_delete=models.SET_NULL, null=True,
                              related_name="refund_requests")
    reason = models.TextField(blank=True, default="")
    status = models.CharField(max_length=10, choices=STATUS, default="pending")
    requested_at = models.DateTimeField(default=timezone.now)
    snapshot = models.JSONField(default=dict, blank=True)   # numbers at request time
    decided_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="+")
    decided_at = models.DateTimeField(null=True, blank=True)
    decision_note = models.CharField(max_length=300, blank=True, default="")
    approved_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    action = models.CharField(max_length=16, blank=True, default="")
    result = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-requested_at", "-id"]


class FreeGrantClaim(models.Model):
    """Anti-farming tombstone (rule P): one row per (kind, hashed phone /
    device) that ever received a free grant. No user link, never deleted, so
    delete + re-signup on the same phone or device cannot claim again."""
    kind = models.CharField(max_length=16)          # founding|trial|referral
    key_hash = models.CharField(max_length=64)       # sha256 of ph:/dev:
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["kind", "key_hash"],
                                               name="bill2_free_claim_once")]


class EntitlementGrant(models.Model):
    """A plan / credit grant that is NOT a verified payment: owner edit, Play
    reviewer seed, founding, trial, referral. Recorded with actor + reason and
    never counted as revenue (owner order 27 Oct, add-on)."""
    SOURCES = [("owner_grant", "owner grant"), ("play_reviewer", "Play reviewer"),
               ("founding", "founding"), ("trial", "trial"), ("referral", "referral"),
               ("system", "system"), ("migration", "migration")]
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="entitlement_grants")
    source = models.CharField(max_length=16, choices=SOURCES)
    plan = models.CharField(max_length=16, blank=True, default="")
    starts_at = models.DateTimeField(default=timezone.now)
    ends_at = models.DateTimeField(null=True, blank=True)
    credits = models.IntegerField(default=0)
    actor = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                              related_name="+")
    reason = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["user", "ends_at"])]


class BillingReport(models.Model):
    """Saved output of a daily billing job (reconcile, voided poll, credits
    verify, profit guard, entitlements audit) for Owner Admin."""
    kind = models.CharField(max_length=24, db_index=True)
    ok = models.BooleanField(default=True)
    summary = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ["-created_at", "-id"]
# ---- /billing-v2 ----
