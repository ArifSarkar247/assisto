"""
AI CRM (Axon Dynamics) — feature 34.

A self-contained, multi-tenant sales CRM. Several sales orgs can use one
install; everything is scoped to a CrmOrg (tenant) and access is gated through
CrmMember. No Asalify models are touched here — this app owns its own tables.

Bangla-first choice labels with English alongside, matching core/ style.
"""
from django.conf import settings
from django.db import models


class CrmOrg(models.Model):
    """A sales organization / tenant. Everything else hangs off an org so the
    CRM is multi-tenant: one install can serve many independent sales teams."""
    name = models.CharField(max_length=120)
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                              related_name="crm_orgs")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name


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
    name = models.CharField(max_length=160)
    title = models.CharField(max_length=120, blank=True)   # job title
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
