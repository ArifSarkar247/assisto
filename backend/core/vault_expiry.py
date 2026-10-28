"""vault100 — document-expiry pushes (passport, NID, trade licence, insurance,
vehicle papers ...), run by `manage.py vault_expiry_alerts` (hourly, flock).

What a push may contain (owner rule + MASVS privacy): ONLY the document TYPE
("Passport", "Trade licence") and the days left. Never the user's title, the
numbers in `details`, the note or the file — the lock screen shows nothing a
stranger could use.

Schedule per document (expiry_alerts=True, expiry_date set):
  * stages 60 / 30 / 7 / 1 days before expiry_date (day 0 counts as stage 1);
    only the MOST urgent stage reached is sent — a document added 20 days
    before expiry gets its 30-day push once, then 7, then 1;
  * already expired documents get nothing (the in-app badge says "expired");
  * a changed expiry date starts a fresh cycle (the date is in the claim key).
Limits:
  * quiet hours 21:00-09:00 Asia/Dhaka (core/logic/msg_guard): nothing goes
    out; the next run after 09:00 sends it;
  * at most MAX_PUSHES_PER_DAY (1) expiry push per user per Dhaka day — when
    several documents are due the same day they share ONE push ("3 documents
    expire soon"), at most MAX_DOCS_PER_PUSH named by type;
  * per-document opt-out (Document.expiry_alerts) and the user's account
    being inactive both stop it.
Idempotent: each (document, stage, expiry_date) is CLAIMED by inserting a
DocExpiryPush row under a UNIQUE constraint BEFORE the push is sent, so two
overlapping runs or a retry can never send the same stage twice
(at-most-once: a crash after the claim loses that one push, never doubles).
"""
import logging
from collections import defaultdict
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.utils import timezone

log = logging.getLogger(__name__)

STAGES = (60, 30, 7, 1)
MAX_PUSHES_PER_DAY = 1
MAX_DOCS_PER_PUSH = 3
BATCH = 2000

# doc_type -> (bn, en). Mirrors app/lib/widgets/vault_doc_types.dart labels.
TYPE_LABELS = {
    "passport": ("পাসপোর্ট", "Passport"),
    "nid": ("জাতীয় পরিচয়পত্র (NID)", "National ID (NID)"),
    "licence": ("ড্রাইভিং লাইসেন্স", "Driving licence"),
    "trade_licence": ("ট্রেড লাইসেন্স", "Trade licence"),
    "vehicle": ("গাড়ির কাগজ", "Vehicle papers"),
    "insurance": ("বিমা", "Insurance"),
    "warranty": ("ওয়ারেন্টি", "Warranty"),
    "certificate": ("সার্টিফিকেট", "Certificate"),
    "device": ("ফোন/ডিভাইসের কাগজ", "Phone/device record"),
}
OTHER_LABEL = ("একটি কাগজ", "A document")

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(v):
    return str(v).translate(_BN)


def type_label(doc_type, lang):
    bn, en = TYPE_LABELS.get(doc_type or "", OTHER_LABEL)
    return en if lang == "en" else bn


def due_stage(days_left):
    """The most urgent stage `days_left` has reached, or None (expired or
    more than 60 days away)."""
    if days_left is None or days_left < 0:
        return None
    for s in sorted(STAGES):
        if days_left <= s:
            return s
    return None


def _when(days, lang):
    if lang == "en":
        if days == 0:
            return "today"
        if days == 1:
            return "tomorrow"
        return "in %d days" % days
    if days == 0:
        return "আজ"
    if days == 1:
        return "আগামীকাল"
    return "%s দিনে" % bn_digits(days)


def build_message(items):
    """items: [(doc_type, days_left)] most urgent first -> {title:{bn,en},
    body:{bn,en}}. Pure. Type + days only."""
    out = {"title": {}, "body": {}}
    if len(items) == 1:
        dt, days = items[0]
        for lang in ("bn", "en"):
            label = type_label(dt, lang)
            if lang == "en":
                out["title"]["en"] = "%s expires %s" % (label, _when(days, "en"))
            else:
                out["title"]["bn"] = "%s-এর মেয়াদ %s শেষ" % (label, _when(days, "bn"))
        if dt == "passport":
            out["body"]["bn"] = ("অনেক দেশ ৬ মাসের কম মেয়াদের পাসপোর্টে ঢুকতে দেয় না — "
                                 "আগেই নবায়ন করুন। ভল্টে নবায়নের ধাপ আছে।")
            out["body"]["en"] = ("Many countries refuse passports with under 6 months left — "
                                 "renew early. Renewal steps are in your vault.")
        else:
            out["body"]["bn"] = "ভল্ট খুলে দেখুন — নবায়নের ধাপও সেখানে।"
            out["body"]["en"] = "Open your vault to check — renewal steps are there too."
        return out
    n = len(items)
    shown = items[:MAX_DOCS_PER_PUSH]
    out["title"]["bn"] = "%sটি কাগজের মেয়াদ শিগগির শেষ" % bn_digits(n)
    out["title"]["en"] = "%d documents expire soon" % n
    for lang in ("bn", "en"):
        parts = ["%s (%s)" % (type_label(dt, lang), _when(d, lang)) for dt, d in shown]
        more = n - len(shown)
        if more > 0:
            parts.append(("আরও %sটি" % bn_digits(more)) if lang == "bn" else ("%d more" % more))
        out["body"][lang] = ", ".join(parts)
    return out


def _dhaka_today(now):
    from .logic import msg_guard as MG
    return MG.local(now).date()


def plan(now=None):
    """{user_id: [(doc, stage, days_left)]} that should go out now, BEFORE
    caps/claims. Empty during quiet hours. Read-only."""
    from .logic import msg_guard as MG
    from .models import DocExpiryPush, Document
    now = now or timezone.now()
    if MG.in_quiet_hours(now):
        return {}
    today = _dhaka_today(now)
    qs = (Document.objects
          .filter(expiry_alerts=True, expiry_date__isnull=False,
                  expiry_date__gte=today,
                  expiry_date__lte=today + timedelta(days=max(STAGES)),
                  user__is_active=True)
          .select_related("user").order_by("expiry_date", "id")[:BATCH])
    docs = list(qs)
    if not docs:
        return {}
    sent = defaultdict(set)   # doc_id -> {(stage, expiry_date)}
    for row in DocExpiryPush.objects.filter(document_id__in=[d.id for d in docs]) \
            .values("document_id", "stage", "expiry_date"):
        sent[row["document_id"]].add((row["stage"], row["expiry_date"]))
    out = defaultdict(list)
    for d in docs:
        days = (d.expiry_date - today).days
        st = due_stage(days)
        if st is None:
            continue
        done = sent.get(d.id, set())
        # this stage, or a MORE urgent one, already went for this date
        if any(s <= st and e == d.expiry_date for s, e in done):
            continue
        out[d.user_id].append((d, st, days))
    return dict(out)


def _claim(doc, stage):
    from .models import DocExpiryPush
    try:
        with transaction.atomic():
            return DocExpiryPush.objects.create(document=doc, user_id=doc.user_id,
                                                stage=stage, expiry_date=doc.expiry_date)
    except IntegrityError:
        return None


def sweep(now=None, push_fn=None):
    """Send due expiry pushes. Returns stats dict. `push_fn` (tests) defaults
    to core.push.push_to_user."""
    from .logic import msg_guard as MG
    from .models import DocExpiryPush
    from . import push as push_mod
    push_fn = push_fn or push_mod.push_to_user
    now = now or timezone.now()
    stats = defaultdict(int)
    if MG.in_quiet_hours(now):
        stats["quiet_hours"] = 1
        return dict(stats)
    day0 = MG.day_start(now)
    for uid, rows in plan(now).items():
        stats["users_due"] += 1
        pushed_today = (DocExpiryPush.objects.filter(user_id=uid, sent_at__gte=day0)
                        .values("sent_at").distinct().count())
        if pushed_today >= MAX_PUSHES_PER_DAY:
            stats["capped"] += 1
            continue
        rows.sort(key=lambda r: (r[2], r[0].id))
        claimed = []
        for doc, stage, days in rows:
            c = _claim(doc, stage)
            if c is None:
                stats["already_claimed"] += 1
                continue
            claimed.append((c, doc, days))
        if not claimed:
            continue
        # one shared sent_at so the daily cap counts this as ONE push
        DocExpiryPush.objects.filter(pk__in=[c.pk for c, _, _ in claimed]).update(
            sent_at=claimed[0][0].sent_at)
        msg = build_message([(doc.doc_type, days) for _, doc, days in claimed])
        user = claimed[0][1].user
        n = 0
        try:
            n = push_fn(user, "doc_expiry", msg["title"]["bn"], msg["title"]["en"],
                        msg["body"]["bn"], msg["body"]["en"],
                        data={"route": "vault",
                              "doc_ids": ",".join(str(d.id) for _, d, _ in claimed)[:200],
                              "days_left": str(min(d for _, _, d in claimed))})
        except Exception:  # noqa: BLE001 - never crash the sweep
            log.exception("vault_expiry: push failed")
        if n:
            DocExpiryPush.objects.filter(pk__in=[c.pk for c, _, _ in claimed]).update(
                delivered=min(int(n), 32767))
        stats["pushes"] += 1
        stats["docs"] += len(claimed)
        stats["delivered"] += 1 if n else 0
    return dict(stats)
