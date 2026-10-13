from django.db import models
from django.contrib.auth.models import (
    AbstractBaseUser, PermissionsMixin, BaseUserManager,
)
from django.utils import timezone


class UserManager(BaseUserManager):
    def _normalize(self, phone, email):
        phone = (phone or "").strip() or None
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

    objects = UserManager()

    USERNAME_FIELD = "username"
    REQUIRED_FIELDS = []

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
    """Feature 10 — recurring subscriptions."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="subscriptions")
    name = models.CharField(max_length=80)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    cycle = models.CharField(max_length=8, default="monthly")  # monthly|yearly
    next_due = models.DateField(null=True, blank=True)
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
               ("trial", "trial"), ("adjust", "adjust")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="credit_ledger")
    delta = models.IntegerField()               # +grant / -consume
    reason = models.CharField(max_length=12, choices=REASONS)
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
    """Catalog item — source of truth for price/stock (never invented)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="products")
    name = models.CharField(max_length=160)
    price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    stock = models.IntegerField(default=0)
    sku = models.CharField(max_length=40, blank=True, default="")
    description = models.TextField(blank=True, default="")
    photo = models.ImageField(upload_to="catalog/", null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]


class Order(models.Model):
    """Order capture → confirmation → courier (feature 33)."""
    STATUS = [("new", "new"), ("confirmed", "confirmed"), ("packed", "packed"),
              ("shipped", "shipped"), ("delivered", "delivered"), ("cancelled", "cancelled")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="orders")
    customer_name = models.CharField(max_length=120, blank=True, default="")
    customer_phone = models.CharField(max_length=40, blank=True, default="")
    address = models.TextField(blank=True, default="")
    items = models.JSONField(default=list, blank=True)     # [{name, qty, price}]
    total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    status = models.CharField(max_length=12, choices=STATUS, default="new")
    courier = models.CharField(max_length=40, blank=True, default="")
    tracking = models.CharField(max_length=80, blank=True, default="")
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


class CategoryCorrection(models.Model):
    """Per-user learned category for a parsed counterparty (improves the guesser)."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="category_corrections")
    key = models.CharField(max_length=120)
    category = models.CharField(max_length=60)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = [("user", "key")]
