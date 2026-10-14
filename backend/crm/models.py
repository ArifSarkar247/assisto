"""
AI CRM (Axon Dynamics) — feature 34.

A self-contained, multi-tenant sales CRM. Several sales orgs can use one
install; everything is scoped to a CrmOrg (tenant) and access is gated through
CrmMember. No Asalify models are touched here — this app owns its own tables.

Bangla-first choice labels with English alongside, matching core/ style.
"""
from django.conf import settings
from django.db import models


def _new_invite_code():
    """A short, human-friendly, unambiguous join code (no 0/O/1/I/L). Used by a
    teammate to join an existing org. Uniqueness is enforced at generation time
    (see CrmOrg.rotate_invite_code / save)."""
    import secrets
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(8))


class CrmOrg(models.Model):
    """A sales organization / tenant. Everything else hangs off an org so the
    CRM is multi-tenant: one install can serve many independent sales teams."""
    # Industry / team-size options for the first-run "Start your CRM" flow.
    INDUSTRIES = [
        ("rmg", "গার্মেন্টস / RMG"), ("pharma", "ফার্মা / Pharma"),
        ("retail", "রিটেইল / Retail"), ("it", "আইটি / IT & Software"),
        ("manufacturing", "ম্যানুফ্যাকচারিং / Manufacturing"),
        ("services", "সার্ভিস / Services"), ("other", "অন্যান্য / Other"),
    ]
    TEAM_SIZES = [
        ("solo", "১ জন / Just me"), ("small", "২–৫ জন / 2–5"),
        ("medium", "৬–২০ জন / 6–20"), ("large", "২০+ / 20+"),
    ]
    name = models.CharField(max_length=120)
    industry = models.CharField(max_length=20, choices=INDUSTRIES, default="other",
                                blank=True)
    team_size = models.CharField(max_length=10, choices=TEAM_SIZES, default="small",
                                 blank=True)
    # Persisted fair round-robin cursor for lead auto-assignment. The view passes
    # it to logic_team.round_robin_pick(member_ids, cursor) and saves the returned
    # cursor so assignment stays fair + deterministic across requests (no RNG).
    round_robin_cursor = models.IntegerField(default=0)
    # Single-tenant join code a teammate enters to join as a member. Unique so a
    # code resolves to exactly one org. Owner can rotate it.
    invite_code = models.CharField(max_length=12, unique=True, blank=True,
                                   default=_new_invite_code)
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                              related_name="crm_orgs")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name

    def save(self, *args, **kwargs):
        # Guarantee a unique invite code on first save (default may rarely clash).
        if not self.invite_code:
            self.invite_code = _new_invite_code()
        if self._state.adding:
            for _ in range(8):
                if not CrmOrg.objects.filter(invite_code=self.invite_code).exists():
                    break
                self.invite_code = _new_invite_code()
        super().save(*args, **kwargs)

    def rotate_invite_code(self):
        """Issue a fresh, unique join code (invalidates the old one)."""
        code = _new_invite_code()
        while CrmOrg.objects.filter(invite_code=code).exclude(pk=self.pk).exists():
            code = _new_invite_code()
        self.invite_code = code
        self.save(update_fields=["invite_code"])
        return code


class CrmMember(models.Model):
    """Who can see/act inside an org, and at what level. The org owner is also
    seeded as an 'owner' member so all access checks go through one table."""
    OWNER, MANAGER, SALES = "owner", "manager", "sales"
    ROLES = [(OWNER, "মালিক / Owner"), (MANAGER, "ম্যানেজার / Manager"),
             (SALES, "সেলস / Sales")]
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="members")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                             related_name="crm_memberships")
    role = models.CharField(max_length=10, choices=ROLES, default=SALES)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("org", "user")]
        ordering = ["role", "id"]

    def __str__(self):
        return f"{self.user_id}@{self.org_id} ({self.role})"


class Lead(models.Model):
    """A prospect, auto-profiled from an inbound conversation or added manually.
    `score` and `priority` are computed deterministically in scoring.py from
    real signals — never fabricated."""
    INDUSTRIES = [("rmg", "RMG / গার্মেন্টস"), ("pharma", "Pharma / ফার্মা"),
                  ("retail", "Retail / রিটেইল"), ("other", "অন্যান্য / Other")]
    SOURCES = [("whatsapp", "WhatsApp"), ("messenger", "Messenger"),
               ("linkedin", "LinkedIn"), ("email", "Email"),
               ("manual", "ম্যানুয়াল / Manual")]
    HIGH, NORMAL = "high", "normal"
    PRIORITIES = [(HIGH, "হাই-প্রায়োরিটি / High"), (NORMAL, "সাধারণ / Normal")]
    STATUSES = [("new", "নতুন / New"), ("contacted", "যোগাযোগ হয়েছে / Contacted"),
                ("demo", "ডেমো / Demo"), ("proposal", "প্রপোজাল / Proposal"),
                ("won", "জিতেছি / Won"), ("lost", "হারিয়েছি / Lost")]

    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="leads")
    name = models.CharField(max_length=120, blank=True)
    company = models.CharField(max_length=160, blank=True)
    industry = models.CharField(max_length=10, choices=INDUSTRIES, default="other")
    company_size = models.PositiveIntegerField(default=0)  # headcount, 0 = unknown
    source = models.CharField(max_length=10, choices=SOURCES, default="manual")
    phone = models.CharField(max_length=32, blank=True)
    email = models.EmailField(blank=True)

    # ----- rich manual-entry fields (CRM_SPEC: works WITHOUT AI) -----
    # `phones` holds any extra phone numbers beyond `phone` (multi-phone entry);
    # `phone` stays the primary for scoring/dupes. All optional, no AI needed.
    phones = models.JSONField(default=list, blank=True)      # extra numbers
    whatsapp = models.CharField(max_length=32, blank=True)
    designation = models.CharField(max_length=120, blank=True)   # job title
    required_modules = models.JSONField(default=list, blank=True)  # ["hrm","vat"...]
    budget_range = models.CharField(max_length=80, blank=True)
    timeline = models.CharField(max_length=80, blank=True)        # buying timeline
    decision_maker = models.CharField(max_length=160, blank=True)
    notes = models.TextField(blank=True)
    next_follow_up = models.DateField(null=True, blank=True)

    score = models.PositiveSmallIntegerField(default=0)   # 0–100, deterministic
    priority = models.CharField(max_length=6, choices=PRIORITIES, default=NORMAL)
    status = models.CharField(max_length=10, choices=STATUSES, default="new")
    assigned_to = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                    null=True, blank=True, related_name="leads")

    # Last AI/rule-based scoring explanation, so the number is always auditable.
    score_reason = models.TextField(blank=True)

    # SLA / first-response timers (spec §5). `first_response_at` is set when the
    # first OUTBOUND reply is logged; `sla_due` is capture_time + the org SLA.
    first_response_at = models.DateTimeField(null=True, blank=True)
    sla_due = models.DateTimeField(null=True, blank=True)
    # Link to the richer company/contact records once qualified (optional).
    company_rec = models.ForeignKey("Company", on_delete=models.SET_NULL, null=True,
                                    blank=True, related_name="leads")
    contact_rec = models.ForeignKey("Contact", on_delete=models.SET_NULL, null=True,
                                    blank=True, related_name="leads")

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-score", "-updated_at"]
        indexes = [models.Index(fields=["org", "priority", "status"])]

    def __str__(self):
        return f"{self.name or self.company or 'Lead'} ({self.score})"


class Conversation(models.Model):
    """A thread with a lead on one channel. Holds a rolling AI/rule summary so
    the sales person never has to write meeting notes by hand."""
    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, related_name="conversations")
    channel = models.CharField(max_length=10, choices=Lead.SOURCES, default="manual")
    insight = models.TextField(blank=True)  # running summary of the thread
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"Conversation #{self.pk} ({self.channel})"


class Message(models.Model):
    """One message in a conversation. `text` is UNTRUSTED user content — it must
    only ever reach AI through ai.generate(data=...), never a task string."""
    IN, OUT = "in", "out"
    DIRECTIONS = [(IN, "ইনবাউন্ড / Inbound"), (OUT, "আউটবাউন্ড / Outbound")]
    POS, NEU, NEG = "pos", "neu", "neg"
    SENTIMENTS = [(POS, "পজিটিভ / Positive"), (NEU, "নিউট্রাল / Neutral"),
                  (NEG, "নেগেটিভ / Negative")]

    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE,
                                     related_name="messages")
    direction = models.CharField(max_length=3, choices=DIRECTIONS, default=IN)
    text = models.TextField(blank=True)
    sentiment = models.CharField(max_length=3, choices=SENTIMENTS, default=NEU)
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at"]

    def __str__(self):
        return f"{self.direction}: {self.text[:40]}"


class Proposal(models.Model):
    """A generated proposal/quotation for a lead. `body` is AI-generated (original
    text) when a key is present; otherwise the CRM returns a clean needs-key state
    and never stores a fabricated proposal. Line items + totals are computed from
    the configurable PriceBook only — prices are NEVER invented."""
    DRAFT, PENDING, APPROVED, SENT, VIEWED, ACCEPTED, DECLINED = (
        "draft", "pending", "approved", "sent", "viewed", "accepted", "declined")
    STATUSES = [
        (DRAFT, "খসড়া / Draft"),
        (PENDING, "অনুমোদনের অপেক্ষায় / Pending approval"),
        (APPROVED, "অনুমোদিত / Approved"),
        (SENT, "পাঠানো হয়েছে / Sent"),
        (VIEWED, "দেখা হয়েছে / Viewed"),
        (ACCEPTED, "গৃহীত / Accepted"),
        (DECLINED, "প্রত্যাখ্যাত / Declined"),
    ]
    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, related_name="proposals")
    deal = models.ForeignKey("Deal", on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="proposals")
    version = models.PositiveSmallIntegerField(default=1)
    title = models.CharField(max_length=200, blank=True)
    body = models.TextField(blank=True)
    requirements = models.TextField(blank=True)   # requirement sheet (buyer need)

    # Money — all derived from PriceBook line items (see line_items JSON). The
    # totals here are a cache for display/PDF; prices themselves come from the
    # price book, tax rate is configurable per-org, nothing is invented.
    line_items = models.JSONField(default=list, blank=True)  # [{sku,label,qty,unit,amount}]
    subtotal = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    discount_pct = models.DecimalField(max_digits=5, decimal_places=2, default=0)
    discount_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    tax_pct = models.DecimalField(max_digits=5, decimal_places=2, default=0)   # TO REVIEW BY OWNER
    tax_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    prices_reviewed = models.BooleanField(default=False)  # owner confirmed price book

    status = models.CharField(max_length=10, choices=STATUSES, default=DRAFT)
    discount_needs_approval = models.BooleanField(default=False)
    # Advanced quotes (§6): owner-set validity window + manager discount approval
    # gate + one-way convert-to-order marker. Drives logic_quote.is_expired /
    # days_left (issued = created_at.date().toordinal()).
    valid_days = models.PositiveSmallIntegerField(null=True, blank=True)
    discount_approved = models.BooleanField(default=False)
    discount_approved_by = models.ForeignKey(
        CrmMember, on_delete=models.SET_NULL, null=True, blank=True,
        related_name="discount_approved_proposals")
    discount_approved_at = models.DateTimeField(null=True, blank=True)
    converted_order_id = models.IntegerField(null=True, blank=True)  # one-way
    approved_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                                    blank=True, related_name="approved_proposals")
    approved_at = models.DateTimeField(null=True, blank=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    viewed_at = models.DateTimeField(null=True, blank=True)
    accepted_at = models.DateTimeField(null=True, blank=True)
    pdf_path = models.CharField(max_length=255, blank=True)
    created_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                                   blank=True, related_name="created_proposals")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"Proposal #{self.pk} v{self.version} for lead {self.lead_id}"


# =====================================================================
# ADVANCED CRM — companies/contacts, pipelines/deals, activities,
# team/territory/targets, custom fields, tags, price book, cadences,
# audit log. All additive (new tables); existing models untouched above.
# =====================================================================


class Company(models.Model):
    """A B2B account. Supports a parent/child hierarchy (HQ → subsidiaries)."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="companies")
    name = models.CharField(max_length=200)
    parent = models.ForeignKey("self", on_delete=models.SET_NULL, null=True,
                               blank=True, related_name="children")
    industry = models.CharField(max_length=16, choices=Lead.INDUSTRIES, default="other")
    size = models.PositiveIntegerField(default=0)   # headcount, 0 = unknown
    website = models.CharField(max_length=200, blank=True)
    phone = models.CharField(max_length=32, blank=True)
    address = models.CharField(max_length=300, blank=True)
    territory = models.ForeignKey("Territory", on_delete=models.SET_NULL, null=True,
                                  blank=True, related_name="companies")
    owner = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="owned_companies")
    custom = models.JSONField(default=dict, blank=True)   # custom field values
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]
        indexes = [models.Index(fields=["org", "name"])]

    def __str__(self):
        return self.name


class Contact(models.Model):
    """A person at a company. A lead may be linked to a contact once qualified."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="contacts")
    company = models.ForeignKey(Company, on_delete=models.SET_NULL, null=True,
                                blank=True, related_name="contacts")
    # Buying role in the account (Company 360). `title` is free text; `role` is
    # the explicit, persisted decision-role the UI chips read (no inference).
    DECISION_MAKER, INFLUENCER, FINANCE, CHAMPION, USER_ROLE, OTHER_ROLE = (
        "decision_maker", "influencer", "finance", "champion", "user", "other")
    ROLES = [
        (DECISION_MAKER, "সিদ্ধান্তদাতা / Decision maker"),
        (INFLUENCER, "প্রভাবক / Influencer"),
        (FINANCE, "ফাইন্যান্স / Finance"),
        (CHAMPION, "চ্যাম্পিয়ন / Champion"),
        (USER_ROLE, "ব্যবহারকারী / User"),
        (OTHER_ROLE, "অন্যান্য / Other"),
    ]
    name = models.CharField(max_length=160)
    title = models.CharField(max_length=120, blank=True)   # job title
    role = models.CharField(max_length=16, choices=ROLES, default=OTHER_ROLE)
    phone = models.CharField(max_length=32, blank=True)
    email = models.EmailField(blank=True)
    whatsapp = models.CharField(max_length=32, blank=True)
    is_primary = models.BooleanField(default=False)
    owner = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="owned_contacts")
    custom = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]
        indexes = [models.Index(fields=["org", "email"]),
                   models.Index(fields=["org", "phone"])]

    def __str__(self):
        return self.name


class Pipeline(models.Model):
    """A sales pipeline. An org can have several (e.g. New Business, Renewals)."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="pipelines")
    name = models.CharField(max_length=120)
    is_default = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-is_default", "name"]

    def __str__(self):
        return self.name


class Stage(models.Model):
    """A custom stage inside a pipeline, with a default win probability (%)."""
    pipeline = models.ForeignKey(Pipeline, on_delete=models.CASCADE, related_name="stages")
    name = models.CharField(max_length=120)
    order = models.PositiveSmallIntegerField(default=0)
    probability = models.PositiveSmallIntegerField(default=10)   # 0–100, for weighted forecast
    is_won = models.BooleanField(default=False)
    is_lost = models.BooleanField(default=False)
    # "Stuck" warning threshold: alert if a deal sits here longer than N days.
    stuck_after_days = models.PositiveSmallIntegerField(default=14)

    class Meta:
        ordering = ["pipeline", "order"]

    def __str__(self):
        return f"{self.pipeline_id}:{self.name}"


class Deal(models.Model):
    """An opportunity moving through a pipeline. Value in BDT; probability drives
    the weighted forecast. `next_step` is REQUIRED on every open deal (spec §4)."""
    OPEN, WON, LOST = "open", "won", "lost"
    STATES = [(OPEN, "চলমান / Open"), (WON, "জিতেছি / Won"), (LOST, "হারিয়েছি / Lost")]

    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="deals")
    title = models.CharField(max_length=200)
    company = models.ForeignKey(Company, on_delete=models.SET_NULL, null=True,
                                blank=True, related_name="deals")
    contact = models.ForeignKey(Contact, on_delete=models.SET_NULL, null=True,
                                blank=True, related_name="deals")
    lead = models.ForeignKey(Lead, on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="deals")
    pipeline = models.ForeignKey(Pipeline, on_delete=models.CASCADE, related_name="deals")
    stage = models.ForeignKey(Stage, on_delete=models.PROTECT, related_name="deals")
    owner = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="owned_deals")

    value = models.DecimalField(max_digits=14, decimal_places=2, default=0)  # BDT
    probability = models.PositiveSmallIntegerField(default=10)   # overrides stage default
    expected_close = models.DateField(null=True, blank=True)
    state = models.CharField(max_length=5, choices=STATES, default=OPEN)

    # Follow-up engine (spec §4): a next step is mandatory on every open deal.
    next_step = models.CharField(max_length=240, blank=True)
    next_step_due = models.DateField(null=True, blank=True)

    # Loss handling (spec §6): a loss reason is mandatory when a deal is lost.
    LOSS_REASONS = [
        ("price", "দাম বেশি / Price too high"),
        ("competitor", "প্রতিযোগীর কাছে / Lost to competitor"),
        ("timing", "সময় ঠিক নয় / Bad timing"),
        ("no_budget", "বাজেট নেই / No budget"),
        ("no_need", "প্রয়োজন নেই / No need"),
        ("no_response", "সাড়া নেই / Went silent"),
        ("other", "অন্যান্য / Other"),
    ]
    loss_reason = models.CharField(max_length=16, choices=LOSS_REASONS, blank=True)
    loss_note = models.TextField(blank=True)
    competitor = models.CharField(max_length=120, blank=True)

    source = models.CharField(max_length=10, choices=Lead.SOURCES, default="manual")
    custom = models.JSONField(default=dict, blank=True)

    stage_entered_at = models.DateTimeField(auto_now_add=True)  # for "stuck N days"
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    closed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["stage__order", "-value"]
        indexes = [models.Index(fields=["org", "state"]),
                   models.Index(fields=["pipeline", "stage"])]

    def __str__(self):
        return f"{self.title} (৳{self.value})"

    @property
    def weighted_value(self):
        from decimal import Decimal
        return (self.value * Decimal(self.probability)) / Decimal(100)


class Activity(models.Model):
    """Calls, meetings, tasks, notes — the timeline per lead/deal/contact. Notes
    support @mentions (parsed into Mention rows) and attachments."""
    CALL, MEETING, TASK, NOTE, EMAIL, WHATSAPP, STAGE, SYSTEM = (
        "call", "meeting", "task", "note", "email", "whatsapp", "stage", "system")
    KINDS = [
        (CALL, "কল / Call"), (MEETING, "মিটিং / Meeting"), (TASK, "টাস্ক / Task"),
        (NOTE, "নোট / Note"), (EMAIL, "ইমেইল / Email"), (WHATSAPP, "WhatsApp"),
        (STAGE, "স্টেজ পরিবর্তন / Stage change"), (SYSTEM, "সিস্টেম / System"),
    ]
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="activities")
    kind = models.CharField(max_length=10, choices=KINDS, default=NOTE)
    subject = models.CharField(max_length=240, blank=True)
    body = models.TextField(blank=True)

    deal = models.ForeignKey(Deal, on_delete=models.CASCADE, null=True, blank=True,
                             related_name="activities")
    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, null=True, blank=True,
                             related_name="activities")
    contact = models.ForeignKey(Contact, on_delete=models.CASCADE, null=True,
                                blank=True, related_name="activities")
    company = models.ForeignKey(Company, on_delete=models.CASCADE, null=True,
                                blank=True, related_name="activities")

    # Tasks: due date + done flag; calls/meetings: scheduled time + done.
    due_at = models.DateTimeField(null=True, blank=True)
    done = models.BooleanField(default=False)
    done_at = models.DateTimeField(null=True, blank=True)
    attachment = models.FileField(upload_to="crm/activities/", null=True, blank=True)

    actor = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="activities")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["org", "kind", "done"]),
                   models.Index(fields=["deal", "-created_at"]),
                   models.Index(fields=["lead", "-created_at"])]

    def __str__(self):
        return f"{self.kind}: {self.subject or self.body[:30]}"


class Mention(models.Model):
    """An @mention of a member inside an activity note — drives notifications."""
    activity = models.ForeignKey(Activity, on_delete=models.CASCADE, related_name="mentions")
    member = models.ForeignKey(CrmMember, on_delete=models.CASCADE, related_name="mentions")
    seen = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]


class Tag(models.Model):
    """A free-form tag / segment label, scoped to an org."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="tags")
    name = models.CharField(max_length=60)
    color = models.CharField(max_length=7, default="#3b6ef6")

    class Meta:
        unique_together = [("org", "name")]
        ordering = ["name"]

    def __str__(self):
        return self.name


class TaggedItem(models.Model):
    """Generic-ish tag link to a lead, company, contact or deal (nullable FKs)."""
    tag = models.ForeignKey(Tag, on_delete=models.CASCADE, related_name="items")
    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, null=True, blank=True)
    company = models.ForeignKey(Company, on_delete=models.CASCADE, null=True, blank=True)
    contact = models.ForeignKey(Contact, on_delete=models.CASCADE, null=True, blank=True)
    deal = models.ForeignKey(Deal, on_delete=models.CASCADE, null=True, blank=True)


class CustomFieldDef(models.Model):
    """Admin-defined custom field on leads/companies/contacts/deals."""
    TEXT, NUMBER, DATE, SELECT, BOOL = "text", "number", "date", "select", "bool"
    TYPES = [(TEXT, "টেক্সট / Text"), (NUMBER, "সংখ্যা / Number"),
             (DATE, "তারিখ / Date"), (SELECT, "ড্রপডাউন / Select"),
             (BOOL, "হ্যাঁ-না / Yes-No")]
    ENTITIES = [("lead", "Lead"), ("company", "Company"),
                ("contact", "Contact"), ("deal", "Deal")]
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="custom_fields")
    entity = models.CharField(max_length=10, choices=ENTITIES, default="deal")
    key = models.SlugField(max_length=40)
    label = models.CharField(max_length=120)
    field_type = models.CharField(max_length=8, choices=TYPES, default=TEXT)
    options = models.JSONField(default=list, blank=True)   # for SELECT
    order = models.PositiveSmallIntegerField(default=0)

    class Meta:
        unique_together = [("org", "entity", "key")]
        ordering = ["entity", "order"]

    def __str__(self):
        return f"{self.entity}.{self.key}"


class Territory(models.Model):
    """A sales territory (region/vertical) for routing + ownership."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="territories")
    name = models.CharField(max_length=120)
    region = models.CharField(max_length=120, blank=True)
    industries = models.JSONField(default=list, blank=True)  # list of industry codes
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name


class RoutingRule(models.Model):
    """Assign new leads/deals to a member or territory by industry/size/source.
    Evaluated in `order`; first match wins (deterministic)."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="routing_rules")
    order = models.PositiveSmallIntegerField(default=0)
    match_industry = models.CharField(max_length=16, blank=True)
    match_source = models.CharField(max_length=10, blank=True)
    # Region match for logic_team.route_by_rules(region=...); blank = any region.
    match_region = models.CharField(max_length=120, blank=True, default="")
    min_company_size = models.PositiveIntegerField(default=0)
    assign_to = models.ForeignKey(CrmMember, on_delete=models.CASCADE, null=True,
                                  blank=True, related_name="routing_rules")
    territory = models.ForeignKey(Territory, on_delete=models.SET_NULL, null=True,
                                  blank=True, related_name="routing_rules")
    active = models.BooleanField(default=True)

    class Meta:
        ordering = ["order", "id"]


class Target(models.Model):
    """A sales target/quota for a member (or whole org) in a period."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="targets")
    member = models.ForeignKey(CrmMember, on_delete=models.CASCADE, null=True,
                               blank=True, related_name="targets")
    period = models.CharField(max_length=7)   # "2026-10" (month) or "2026-Q4"
    amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)  # BDT won target
    deals_target = models.PositiveSmallIntegerField(default=0)
    # Snapshot written when the owner finalises a period — computed by the
    # config-driven commission engine (logic_team.commission), never invented.
    commission_paid = models.DecimalField(max_digits=14, decimal_places=2,
                                          default=0)

    class Meta:
        unique_together = [("org", "member", "period")]
        ordering = ["-period"]


class Product(models.Model):
    """A configurable price-book item (Axon ERP module / service). Prices are set
    by the OWNER — the CRM NEVER invents a price. `price_reviewed` must be True
    before a quote using it is considered final; otherwise it is flagged
    'TO REVIEW BY OWNER'."""
    ONE_TIME, MONTHLY, YEARLY, PER_USER = "one_time", "monthly", "yearly", "per_user"
    BILLING = [(ONE_TIME, "এককালীন / One-time"), (MONTHLY, "মাসিক / Monthly"),
               (YEARLY, "বার্ষিক / Yearly"), (PER_USER, "প্রতি ইউজার / Per user")]
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="products")
    sku = models.CharField(max_length=40)
    name = models.CharField(max_length=160)
    description = models.TextField(blank=True)
    unit_price = models.DecimalField(max_digits=14, decimal_places=2, default=0)  # BDT
    billing = models.CharField(max_length=10, choices=BILLING, default=ONE_TIME)
    price_reviewed = models.BooleanField(default=False)  # owner confirmed the number
    active = models.BooleanField(default=True)

    class Meta:
        unique_together = [("org", "sku")]
        ordering = ["name"]

    def __str__(self):
        return f"{self.name} (৳{self.unit_price})"


class Cadence(models.Model):
    """A follow-up sequence template (spec §4). Steps are DRAFTS only — a human
    always approves each outbound message; nothing auto-sends."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="cadences")
    name = models.CharField(max_length=120)
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name


class CadenceStep(models.Model):
    """One step of a cadence: after N days, draft a message on a channel."""
    cadence = models.ForeignKey(Cadence, on_delete=models.CASCADE, related_name="steps")
    order = models.PositiveSmallIntegerField(default=0)
    day_offset = models.PositiveSmallIntegerField(default=0)   # days after enrolment
    channel = models.CharField(max_length=10, choices=Lead.SOURCES, default="email")
    template = models.TextField(blank=True)   # draft text (human approves before send)

    class Meta:
        ordering = ["cadence", "order"]


class AuditEntry(models.Model):
    """Append-only audit log for the CRM (spec: audit log). Who did what, when."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="audit")
    member = models.ForeignKey(CrmMember, on_delete=models.SET_NULL, null=True,
                               blank=True, related_name="audit")
    action = models.CharField(max_length=60)       # e.g. "deal.stage_change"
    entity = models.CharField(max_length=40, blank=True)   # e.g. "deal#12"
    detail = models.TextField(blank=True)
    at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-at"]
        indexes = [models.Index(fields=["org", "-at"])]


# =====================================================================
# WHATSAPP (official Business Cloud API ONLY) — templates + per-lead
# opt-in / service-window state. Sending is MOCKED + key-gated in
# whatsapp.py / views; every send & receive is auto-logged as an Activity
# (kind="whatsapp"), so no new "message log" table is needed — the Activity
# timeline IS the comms log (the key value of the integration).
# =====================================================================


class WhatsAppTemplate(models.Model):
    """An OWNER-DEFINED WhatsApp message template, scoped to an org.

    `body` is text the owner wrote themselves; the CRM never invents template
    copy. {{1}}, {{2}}… placeholders are filled from caller-supplied params at
    send time (whatsapp.render_template). `meta_name` is the name the template
    is registered under in the Meta Business Manager — required for a PAID
    template send OUTSIDE the 24h window (Cloud API rule)."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE,
                            related_name="wa_templates")
    name = models.CharField(max_length=120)             # human label in-app
    meta_name = models.CharField(max_length=120, blank=True)  # Meta-registered name
    language = models.CharField(max_length=8, default="bn")   # bn / en
    body = models.TextField()                           # owner-written copy
    # Whether this template was APPROVED in Meta Business Manager. Only an
    # approved template may be sent outside the 24h service window.
    approved = models.BooleanField(default=False)
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]
        unique_together = [("org", "name")]

    def __str__(self):
        return self.name


class WhatsAppOptIn(models.Model):
    """Per-lead WhatsApp consent + service-window tracking.

    `opted_in` gates ALL sends (bulk and 1:1) — a lead that hasn't opted in is
    never messaged. `last_inbound_at` is stamped every time the lead sends us a
    message (webhook/receive); it drives the 24h free-form window. One row per
    lead (OneToOne) keeps the lead table clean and additive."""
    lead = models.OneToOneField(Lead, on_delete=models.CASCADE,
                                related_name="wa_optin")
    opted_in = models.BooleanField(default=False)
    opted_in_at = models.DateTimeField(null=True, blank=True)
    # Stamp of the lead's most recent INBOUND WhatsApp message (drives the 24h
    # customer-service window for free-form replies).
    last_inbound_at = models.DateTimeField(null=True, blank=True)

    def __str__(self):
        return f"wa-optin lead#{self.lead_id} ({'in' if self.opted_in else 'out'})"


# =====================================================================
# ADVANCED QUOTES / AFTER-SALE (§6/§7) — all money in INTEGER POISHA
# (1 BDT = 100 poisha) to match logic_quote / logic_aftersale. Dates are
# real DateFields; the views pass date.toordinal() to the pure logic.
# All org-scoped; prices/tax/commission are NEVER invented (owner inputs).
# =====================================================================


class QuoteAcceptance(models.Model):
    """Tokenized, session-less customer acceptance link for a Proposal version.

    One row per quote version. State advances ONLY via
    logic_quote.acceptance_transition (issued→viewed→accepted/declined, or
    revoked/expired). The token is from logic_quote.make_acceptance_token (the
    integrator swaps in django.core.signing.Signer for production)."""
    ISSUED, VIEWED, ACCEPTED, DECLINED, REVOKED, EXPIRED = (
        "issued", "viewed", "accepted", "declined", "revoked", "expired")
    proposal = models.OneToOneField(Proposal, on_delete=models.CASCADE,
                                    related_name="acceptance")
    token = models.CharField(max_length=64, unique=True)
    state = models.CharField(max_length=12, default=ISSUED)
    viewed_at = models.DateTimeField(null=True, blank=True)
    decided_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"acceptance q{self.proposal_id} ({self.state})"


class Order(models.Model):
    """An order converted FROM an accepted quote. The order carries the quote's
    total verbatim (integer poisha) — it is NEVER re-priced here."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="orders")
    lead = models.ForeignKey(Lead, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="orders")
    deal = models.ForeignKey(Deal, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name="orders")
    source_proposal = models.ForeignKey(Proposal, on_delete=models.SET_NULL,
                                        null=True, blank=True, related_name="orders")
    total_poisha = models.BigIntegerField(default=0)   # carried, not re-priced
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["org", "-created_at"])]

    def __str__(self):
        return f"Order #{self.pk} (৳{self.total_poisha/100:.2f})"


class Installment(models.Model):
    """One scheduled installment of an order's total. Built by
    logic_aftersale.build_installment_schedule (exact split; remainder on the
    last seq). `collected_poisha` is the running tally via apply_collection."""
    SCHEDULED, PARTIAL, COLLECTED, OVERPAID = (
        "scheduled", "partial", "collected", "overpaid")
    order = models.ForeignKey(Order, on_delete=models.CASCADE,
                              related_name="installments")
    seq = models.PositiveSmallIntegerField()                 # 1-based
    amount_poisha = models.BigIntegerField()                 # booked amount
    due_date = models.DateField()
    collected_poisha = models.BigIntegerField(default=0)
    status = models.CharField(max_length=10, default=SCHEDULED)

    class Meta:
        ordering = ["order", "seq"]
        unique_together = [("order", "seq")]


class Collection(models.Model):
    """One payment recorded against an installment (ledger/audit row). Method is
    cash/cheque/bank only — logic_aftersale.apply_collection rejects others."""
    CASH, CHEQUE, BANK = "cash", "cheque", "bank"
    METHODS = [(CASH, "নগদ / Cash"), (CHEQUE, "চেক / Cheque"),
               (BANK, "ব্যাংক / Bank")]
    installment = models.ForeignKey(Installment, on_delete=models.CASCADE,
                                    related_name="collections")
    amount_poisha = models.BigIntegerField()                 # >= 0, never faked
    method = models.CharField(max_length=6, choices=METHODS)
    reference = models.CharField(max_length=64, blank=True)  # cheque/txn no.
    collected_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-collected_at"]


class AMC(models.Model):
    """Annual maintenance / renewal contract. Renewal day =
    logic_aftersale.amc_renewal_ordinal(start, term_days); state from
    renewal_status. Reminders surface foreground on app open/resume (WorkManager
    is banned per memory)."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE, related_name="amcs")
    company = models.ForeignKey(Company, on_delete=models.SET_NULL, null=True,
                                blank=True, related_name="amcs")
    order = models.ForeignKey(Order, on_delete=models.SET_NULL, null=True,
                              blank=True, related_name="amcs")
    title = models.CharField(max_length=200)
    start_date = models.DateField()
    term_days = models.PositiveIntegerField(default=365)
    reminder_lead_days = models.PositiveSmallIntegerField(default=30)
    last_renewed_at = models.DateField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["start_date"]
        indexes = [models.Index(fields=["org", "start_date"])]

    def __str__(self):
        return self.title


class Complaint(models.Model):
    """Support complaint log + state machine + SLA. State advances ONLY via
    logic_aftersale.complaint_transition; SLA from complaint_sla(priority,
    opened_ord, today_ord, state)."""
    OPEN, ACKNOWLEDGED, IN_PROGRESS, RESOLVED, CLOSED, CANCELLED = (
        "open", "acknowledged", "in_progress", "resolved", "closed", "cancelled")
    URGENT, HIGH, NORMAL, LOW = "urgent", "high", "normal", "low"
    PRIORITIES = [(URGENT, "জরুরি / Urgent"), (HIGH, "উচ্চ / High"),
                  (NORMAL, "সাধারণ / Normal"), (LOW, "নিম্ন / Low")]
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE,
                            related_name="complaints")
    company = models.ForeignKey(Company, on_delete=models.SET_NULL, null=True,
                                blank=True, related_name="complaints")
    lead = models.ForeignKey(Lead, on_delete=models.SET_NULL, null=True,
                             blank=True, related_name="complaints")
    subject = models.CharField(max_length=200)
    details = models.TextField(blank=True)
    priority = models.CharField(max_length=8, choices=PRIORITIES, default=NORMAL)
    state = models.CharField(max_length=14, default=OPEN)
    opened_at = models.DateTimeField(auto_now_add=True)       # SLA clock start
    resolved_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-opened_at"]
        indexes = [models.Index(fields=["org", "state"])]

    def __str__(self):
        return self.subject


class ErpHandoff(models.Model):
    """Axon ERP implementation hand-off record (DESIGN / LINK ONLY — never posts
    to Asalify/ERP). State advances ONLY via logic_aftersale.handoff_transition;
    with no ERP link connected the state is reported as needs_erp_link."""
    NOT_STARTED, PREPARING, SUBMITTED, ACCEPTED, REJECTED, COMPLETED = (
        "not_started", "preparing", "submitted", "accepted", "rejected",
        "completed")
    deal = models.OneToOneField(Deal, on_delete=models.CASCADE,
                                related_name="erp_handoff")
    company_name = models.CharField(max_length=200)
    module_codes = models.JSONField(default=list, blank=True)
    order_total_poisha = models.BigIntegerField(default=0)
    state = models.CharField(max_length=12, default=NOT_STARTED)
    erp_link_connected = models.BooleanField(default=False)   # gate
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"erp-handoff deal#{self.deal_id} ({self.state})"


# =====================================================================
# TEAM / AUTOMATION (#8/#11) — commission config, owner automation rules
# + idempotency markers. Commission is CONFIG-DRIVEN (no baked numbers).
# =====================================================================


class CommissionRule(models.Model):
    """Owner-defined commission config, one per org. The JSON shape maps 1:1 to
    logic_team.commission(won, config). NO rate is baked in — kind='none' or a
    zero rate yields config_set=False ("owner must set")."""
    NONE, FLAT, TIERED = "none", "flat", "tiered"
    org = models.OneToOneField(CrmOrg, on_delete=models.CASCADE,
                               related_name="commission_rule")
    kind = models.CharField(max_length=10, default=NONE)
    flat_pct = models.DecimalField(max_digits=6, decimal_places=3, default=0)
    tiers = models.JSONField(default=list, blank=True)   # [{"upto":amt|null,"pct":n}]
    per_deal_bonus = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    updated_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                   null=True, blank=True,
                                   related_name="commission_rules")
    updated_at = models.DateTimeField(auto_now=True)

    def as_config(self):
        """The dict logic_team.commission consumes."""
        return {
            "kind": self.kind,
            "flat_pct": self.flat_pct,
            "tiers": self.tiers or [],
            "per_deal_bonus": self.per_deal_bonus,
        }

    def __str__(self):
        return f"commission[{self.org_id}] {self.kind}"


class AutomationRule(models.Model):
    """Owner trigger→condition→delay→action rule (#11). Validated by
    logic_automation.validate_rule; evaluated by due_actions. Actions are
    create-task / draft / notify only — nothing auto-sends to a customer."""
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE,
                            related_name="automation_rules")
    name = models.CharField(max_length=120, blank=True)
    trigger = models.CharField(max_length=24)            # logic_automation.KNOWN_TRIGGERS
    condition = models.JSONField(default=dict, blank=True)
    delay_days = models.PositiveSmallIntegerField(default=0)
    action = models.JSONField(default=dict)              # {"kind":..., "subject":...}
    active = models.BooleanField(default=True)
    created_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                   null=True, blank=True,
                                   related_name="automation_rules")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["id"]
        indexes = [models.Index(fields=["org", "active"])]

    def __str__(self):
        return self.name or f"rule#{self.pk} ({self.trigger})"


class AutomationFire(models.Model):
    """Idempotency marker: one row per (rule, entity, due_at) the evaluator has
    acted on, so re-running due_actions() never double-creates a task.
    logic_automation is intentionally memoryless; this table is the memory."""
    rule = models.ForeignKey(AutomationRule, on_delete=models.CASCADE,
                             related_name="fires")
    entity_kind = models.CharField(max_length=8)         # "deal" | "lead"
    entity_id = models.PositiveIntegerField()
    due_at = models.DateTimeField()
    created_activity = models.ForeignKey(Activity, on_delete=models.SET_NULL,
                                         null=True, blank=True,
                                         related_name="automation_fires")
    fired_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("rule", "entity_kind", "entity_id", "due_at")]
