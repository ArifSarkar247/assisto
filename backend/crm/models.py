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

    score = models.PositiveSmallIntegerField(default=0)   # 0–100, deterministic
    priority = models.CharField(max_length=6, choices=PRIORITIES, default=NORMAL)
    status = models.CharField(max_length=10, choices=STATUSES, default="new")
    assigned_to = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                    null=True, blank=True, related_name="leads")

    # Last AI/rule-based scoring explanation, so the number is always auditable.
    score_reason = models.TextField(blank=True)

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
    """A generated proposal for a lead. `body` is produced by AI (original text)
    when a key is present; otherwise the CRM returns a clean needs-key state and
    never stores a fabricated proposal."""
    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, related_name="proposals")
    body = models.TextField(blank=True)
    pdf_path = models.CharField(max_length=255, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"Proposal #{self.pk} for lead {self.lead_id}"
