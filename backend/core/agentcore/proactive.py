"""Agent Core — PROACTIVE engine (WP-PROACTIVE; flag `agent_core`, default OFF).

Owner order 27 Oct, PART 2: "proactive triggers (bill due, remittance missing,
child not home, stock low, unpaid order, meter low, camera alert) with a daily
cap and quiet hours; morning brief and evening recap in Bangla voice and text".

TEMPLATE-ONLY: nothing here calls an AI model, so nudges and briefs cost the
user nothing (no credits). Every line is built from the user's OWN rows in the
existing modules; an empty source adds nothing (no invented data).

TRIGGERS (each: condition, dedupe key, cooldown, priority, opt-out, "why")

  bill_due        Budget & Remittance bills (due_day, not paid this month) and
                  loans the user TOOK with a due date — due within 2 days or
                  overdue (<= 5 / 7 days). A bill that already has a phone
                  reminder (reminder_local_id) is brief-only: the alarm owns it.
  remit_missing   remittance expected amount + day set, the day has passed and
                  nothing arrived (logic.remittance.expected_status "missing");
                  skipped when the in-app "not arrived" card already showed it
                  this month (RemittanceProfile.missing_alert_month).
  child_not_home  Safe Journey ROUTINE ("home by 21:00") the traveller set with
                  this user as a watcher (= the traveller's consent): the home-by
                  time + 20 min passed, no active journey (journey_sweep owns the
                  active-journey overdue chain) and no journey ended/arrived
                  today. Never an SOS; never duplicates journey_watch alerts.
  stock_low       business Product.stock <= low_stock_at. Out of stock (0) is
                  pushed; merely low is batched into the brief.
  order_unpaid    online orders: payment screenshot waiting for the owner's
                  check > 2 h, "new" not confirmed > 6 h, COD shipped > 4 days.
                  The real-time "new order" push (bizagent) is not repeated.
  meter_low       prepaid meter estimate (logic.prepaid_meter). BRIEF-ONLY: the
                  remmeter `meter_low_alerts` command owns the push.
  camera_alert    watchman ShopEvent rows still "open" from the last 24 h.
                  BRIEF-ONLY summary: the real-time camera alert is never repeated.

CAPS
  * daily cap per user (prefs.daily_cap, default 3) counts only pushed nudges;
    safety (child_not_home) is never counted and never blocked by the cap;
    briefs are not counted.
  * quiet hours: the user's call DND (CirclePrivacy.dnd_*) when it is on, else
    prefs.quiet_start/quiet_end (default 22:00-07:00). Inside quiet hours only a
    family-safety nudge is pushed, and only when the user keeps "family may
    still reach me" (dnd_family_exception, default ON; when OFF the family
    nudge is held for the morning brief). Other urgent/normal nudges are not
    stored during quiet hours and are re-checked on the first run after them;
    low-priority ones go to the next brief as usual.
  * cooldown per trigger: a second push of the same trigger inside the window
    is batched instead.
  * not urgent (priority 3) -> batched into the next brief, never pushed alone.

DELIVERY: one notification push of kind `agent_nudge` (core.push; the tray
draws it on every build) + the in-app card list (GET agent-core/nudges). The
brief/recap carry `voice` text for the device TTS the app already has
(VaNative.speak); when the phone has no Bangla voice the app shows text only.
"""
import hashlib
import logging
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from django.db import IntegrityError, transaction
from django.db.models import Q, Sum
from django.utils import timezone

from ..ai_prompt import to_bn_digits
from . import FLAG

log = logging.getLogger("assisto.agentcore.proactive")

PUSH_KIND = "agent_nudge"
DEFAULT_CAP = 3
MAX_CAP = 10
CHILD_GRACE_MIN = 20          # after the routine's "home by" time
CHILD_WINDOW_H = 3            # ... and only for this long (then it is stale)
MORNING_END_H = 11            # the morning brief is not sent after 11:00
EVENING_END = (23, 30)

# key: (label_bn, label_en, cooldown hours, counted toward cap, module flag, route)
TRIGGERS = {
    "bill_due": ("বিল/দেনার তারিখ", "Bills due", 20, True, "", "money"),
    "remit_missing": ("রেমিট্যান্স আসেনি", "Remittance not arrived", 72, True,
                      "budget_remittance", "remittance"),
    "child_not_home": ("পরিবারের কেউ বাসায় ফেরেননি", "Family member not home", 0, False,
                       "safe_journey", "journey"),
    "stock_low": ("স্টক কম", "Low stock", 72, True, "business", "business"),
    "order_unpaid": ("অপেক্ষমাণ অর্ডার/পেমেন্ট", "Orders waiting", 20, True, "business", "orders"),
    "meter_low": ("মিটারের ব্যালান্স কম", "Meter balance low", 0, True, "prepaid_meter",
                  "prepaid_meter"),
    "camera_alert": ("ক্যামেরা সতর্কতা (সারাংশ)", "Camera alerts (summary)", 0, True,
                     "home_watchman", "watchman"),
}
BRIEF_ONLY = ("meter_low", "camera_alert")
BRIEFS = ("brief_morning", "brief_evening")
SAFETY = ("child_not_home",)
# triggers whose data the brief re-derives itself (a batched one is covered)
BRIEF_DERIVED = ("bill_due", "remit_missing", "stock_low", "order_unpaid",
                 "meter_low", "camera_alert")


# ------------------------------------------------------------------ helpers
def _pick(lang, bn, en):
    return bn if lang == "bn" else en


def _d(v, lang):
    """Digits in the user's language (Bangla digits for bn)."""
    return to_bn_digits(str(v)) if lang == "bn" else str(v)


def _money(v, lang):
    v = float(v or 0)
    s = ("{:,.0f}" if v == int(v) else "{:,.2f}").format(v)
    return "৳" + (to_bn_digits(s) if lang == "bn" else s)


def _hhmm_ok(s):
    try:
        h, m = (int(x) for x in str(s).split(":"))
        return 0 <= h < 24 and 0 <= m < 60
    except (TypeError, ValueError):
        return False


def _mins(s, default=0):
    try:
        h, m = (int(x) for x in str(s).split(":"))
        return h * 60 + m
    except (TypeError, ValueError):
        return default


def _in_window(now_min, start_min, end_min):
    if start_min == end_min:
        return False
    if start_min < end_min:
        return start_min <= now_min < end_min
    return now_min >= start_min or now_min < end_min


def _flag(key, user):
    """Module flag for a trigger, checked STRICTLY (as the Play build would
    see it): a cron job cannot know the user's flavour, so a feature hidden in
    Play never nudges a Play user."""
    if not key:
        return True
    try:
        from .. import feature_flags as FF
        return FF.is_on(key, user, True)
    except Exception:
        return False


def flag_on(user):
    return _flag(FLAG, user)


def _hash(*parts):
    return hashlib.sha1("|".join(str(p) for p in parts).encode()).hexdigest()[:12]


def _lang(user):
    la = getattr(user, "language", "bn")
    return la if la in ("bn", "en") else "bn"


@dataclass
class Candidate:
    trigger: str
    key: str
    priority: int
    title_bn: str
    title_en: str
    body_bn: str
    body_en: str
    why_bn: str
    why_en: str
    route: str = ""
    data: dict = field(default_factory=dict)
    family: bool = False      # family-safety: may pass quiet hours (family exception)


# ------------------------------------------------------------------ prefs / quiet
class _Defaults:
    off = ()
    daily_cap = DEFAULT_CAP
    morning_brief = True
    evening_recap = True
    morning_at = "07:30"
    evening_at = "21:00"
    quiet_start = "22:00"
    quiet_end = "07:00"
    pk = None


def prefs_for(user):
    from ..models import AgentNudgePrefs
    return AgentNudgePrefs.objects.filter(user=user).first() or _Defaults()


def prefs_out(p, lang="bn"):
    off = set(p.off or ())
    return {"daily_cap": int(p.daily_cap), "morning_brief": bool(p.morning_brief),
            "evening_recap": bool(p.evening_recap), "morning_at": p.morning_at,
            "evening_at": p.evening_at, "quiet_start": p.quiet_start, "quiet_end": p.quiet_end,
            "triggers": [{"key": k, "label": _pick(lang, v[0], v[1]), "on": k not in off}
                         for k, v in TRIGGERS.items()]}


class PrefsError(ValueError):
    pass


def save_prefs(user, body):
    """Validate + store (partial update). Raises PrefsError(field)."""
    from ..models import AgentNudgePrefs
    b = body or {}
    p, _ = AgentNudgePrefs.objects.get_or_create(user=user)
    if "daily_cap" in b:
        try:
            cap = int(b["daily_cap"])
        except (TypeError, ValueError):
            raise PrefsError("daily_cap")
        if not 0 <= cap <= MAX_CAP:
            raise PrefsError("daily_cap")
        p.daily_cap = cap
    for k in ("morning_brief", "evening_recap"):
        if k in b:
            if not isinstance(b[k], bool):
                raise PrefsError(k)
            setattr(p, k, b[k])
    for k in ("morning_at", "evening_at", "quiet_start", "quiet_end"):
        if k in b:
            if not _hhmm_ok(b[k]):
                raise PrefsError(k)
            h, m = (int(x) for x in str(b[k]).split(":"))
            setattr(p, k, "%02d:%02d" % (h, m))
    if "off" in b:
        if not isinstance(b["off"], list):
            raise PrefsError("off")
        p.off = sorted({str(x) for x in b["off"] if str(x) in TRIGGERS})
    if isinstance(b.get("triggers"), dict):          # {"stock_low": false, ...}
        off = set(p.off or ())
        for k, v in b["triggers"].items():
            if k in TRIGGERS and isinstance(v, bool):
                (off.discard if v else off.add)(k)
        p.off = sorted(off)
    p.save()
    return p


def mute_trigger(user, trigger):
    from ..models import AgentNudgePrefs
    if trigger not in TRIGGERS:
        return None
    p, _ = AgentNudgePrefs.objects.get_or_create(user=user)
    p.off = sorted(set(p.off or ()) | {trigger})
    p.save(update_fields=["off", "updated_at"])
    return p


def quiet_state(user, prefs, local):
    """(in_quiet, family_may_reach). The call DND schedule wins when it is on
    (one quiet-hours setting for the whole app); else the agent's own window."""
    from ..models import CirclePrivacy
    cp = CirclePrivacy.objects.filter(user=user).first()
    now_m = local.hour * 60 + local.minute
    if cp is not None and cp.dnd_enabled:
        q = _in_window(now_m, _mins(cp.dnd_start, 1320), _mins(cp.dnd_end, 420))
        return q, bool(cp.dnd_family_exception)
    q = _in_window(now_m, _mins(prefs.quiet_start, 1320), _mins(prefs.quiet_end, 420))
    fam = True if cp is None else bool(cp.dnd_family_exception)
    return q, fam


# ------------------------------------------------------------------ triggers
def _bill_rows(user, today, lang):
    """[(kind, id, name, amount, due_date, has_phone_reminder)] — real rows only."""
    out = []
    if _flag("budget_remittance", user):
        from ..models import RemittanceProfile
        from .. import remittance_service as S
        from ..logic import remittance as RL
        p = RemittanceProfile.objects.filter(user=user).first()
        if p is not None:
            month = RL.month_key(today)
            for b in (S.profile_data(p).get("bills") or []):
                try:
                    dd = int(b.get("due_day") or 0)
                except (TypeError, ValueError):
                    continue
                if not dd or month in (b.get("paid_months") or []):
                    continue
                due = RL.due_date(month, dd)
                out.append(("remit", b.get("name") or "", b.get("name") or "",
                            float(b.get("amount") or 0), due, bool(b.get("reminder_local_id"))))
    from ..models import Loan
    for ln in Loan.objects.filter(user=user, kind="taken", settled=False,
                                  due_date__isnull=False,
                                  due_date__gte=today - timedelta(days=7),
                                  due_date__lte=today + timedelta(days=2)):
        paid = sum(float(r.get("amount") or 0) for r in (ln.repayments or []) if isinstance(r, dict))
        left = round(max(0.0, float(ln.amount) - paid), 2)
        if left > 0:
            out.append(("loan", ln.id, ln.person, left, ln.due_date, False))
    return out


def eval_bill_due(user, now, lang):
    today = timezone.localdate(now)
    out = []
    for kind, rid, name, amount, due, has_rem in _bill_rows(user, today, lang):
        days = (due - today).days
        if days > 2 or days < (-5 if kind == "remit" else -7):
            continue
        if has_rem or days == 2:
            prio = 3                      # the phone alarm / a brief is enough
        elif days < 0:
            prio = 2
        else:
            prio = 1 if days == 0 else 2
        amt_bn, amt_en = _money(amount, "bn"), _money(amount, "en")
        if days < 0:
            when_bn = "%s দিন আগে পেরিয়েছে" % _d(-days, "bn")
            when_en = "%d day(s) overdue" % -days
        elif days == 0:
            when_bn, when_en = "আজ শেষ দিন", "due today"
        else:
            when_bn = "আর %s দিন বাকি" % _d(days, "bn")
            when_en = "due in %d day(s)" % days
        if kind == "loan":
            t_bn, t_en = "ধার শোধের তারিখ: %s" % name, "Loan repayment due: %s" % name
            why_bn = "আপনি টাকা-পয়সায় লিখেছেন %s-এর কাছে ধার আছে, শেষ তারিখ %s।" % (
                name, _d(due.isoformat(), "bn"))
            why_en = "You recorded a loan from %s in Money, due %s." % (name, due.isoformat())
            route = "money"
        else:
            t_bn, t_en = "বিল দেওয়ার সময়: %s" % name, "Bill due: %s" % name
            why_bn = "বাজেট ও রেমিট্যান্সে এই বিলের তারিখ মাসের %s তারিখ, এ মাসে পরিশোধিত চিহ্ন নেই।" % _d(due.day, "bn")
            why_en = "In Budget & Remittance this bill is due on day %d and is not marked paid this month." % due.day
            route = "remittance"
        stage = "overdue" if days < 0 else ("today", "tomorrow", "soon")[days]
        out.append(Candidate(
            "bill_due", "%s:%s:%s:%s" % (kind, _hash(rid), due.isoformat(), stage), prio,
            t_bn, t_en, "%s — %s" % (amt_bn, when_bn), "%s — %s" % (amt_en, when_en),
            why_bn, why_en, route, {"kind": kind, "due": due.isoformat(), "days": days}))
    return out


def eval_remit_missing(user, now, lang):
    if not _flag("budget_remittance", user):
        return []
    from ..models import RemittanceEntry, RemittanceProfile
    from .. import remittance_service as S
    from ..logic import remittance as RL
    from ..logic.budget import to_poisha
    p = RemittanceProfile.objects.filter(user=user).first()
    if p is None:
        return []
    today = timezone.localdate(now)
    month = RL.month_key(today)
    if p.missing_alert_month == month:
        return []                       # the in-app card already told the user
    pd = S.profile_data(p)
    exp_p = to_poisha(pd.get("expected_taka"))
    exp_day = int(pd.get("expected_day") or 0)
    entries = [S.entry_dict(r) for r in RemittanceEntry.objects.filter(user=user, month=month)]
    received = RL.entries_total(entries)
    if RL.expected_status(today, month, exp_p, exp_day, received) != "missing":
        return []
    sender = (pd.get("expected_sender") or "").strip()
    due = RL.due_date(month, exp_day)
    amt = _money(RL.p2s(exp_p), "bn"), _money(RL.p2s(exp_p), "en")
    return [Candidate(
        "remit_missing", "remit:%s" % month, 2,
        "এ মাসের রেমিট্যান্স এখনো আসেনি", "This month's remittance has not arrived",
        "প্রত্যাশিত %s%s — %s তারিখ পেরিয়ে গেছে।" % (amt[0], (" (%s)" % sender) if sender else "",
                                                 _d(due.day, "bn")),
        "Expected %s%s — day %d has passed." % (amt[1], (" (%s)" % sender) if sender else "", due.day),
        "আপনি প্রতি মাসের %s তারিখে রেমিট্যান্স আশা করেন বলে সেট করেছেন; এ মাসে কোনো এন্ট্রি নেই।" % _d(exp_day, "bn"),
        "You set remittance as expected on day %d each month; nothing is recorded this month." % exp_day,
        "remittance", {"month": month})]


def _routine_watchers(routine):
    """Users who watch this routine: the traveller's own chosen circle members,
    accepted and not blocked (the traveller's consent), never the traveller."""
    from ..models import CircleMember
    from ..push import member_peer_user
    ids = [int(i) for i in (routine.watcher_ids or []) if str(i).isdigit()]
    out = []
    for m in CircleMember.objects.filter(pk__in=ids, user=routine.user, state="accepted",
                                         blocked=False):
        u = member_peer_user(m)
        if u is not None and u.pk != routine.user_id and u not in out:
            out.append(u)
    return out


def child_not_home_routines(now):
    """[(routine, home_by_local_dt)] where the traveller is not recorded home."""
    from ..models import Journey, JourneyRoutine
    from ..logic import safety_journey as SJ
    local = timezone.localtime(now)
    wd = local.weekday()
    out = []
    for r in JourneyRoutine.objects.filter(enabled=True).select_related("user"):
        days = {str(x).lower()[:3] for x in (r.days or [])}
        if not any(SJ._WEEKDAYS.get(d) == wd for d in days):
            continue
        hb = _mins(r.time, -1)
        if hb < 0:
            continue
        home_by = local.replace(hour=hb // 60, minute=hb % 60, second=0, microsecond=0)
        if not (home_by + timedelta(minutes=CHILD_GRACE_MIN) <= local
                <= home_by + timedelta(hours=CHILD_WINDOW_H)):
            continue
        since = home_by - timedelta(minutes=int(r.minutes or 30) + 120)
        js = Journey.objects.filter(traveller=r.user, created_at__gte=since)
        if Journey.objects.filter(traveller=r.user, status="active").exists():
            continue          # journey_sweep owns an active journey's overdue chain
        if js.filter(status__in=("arrived", "stopped")).exists():
            continue          # recorded home / ended by the traveller
        out.append((r, home_by))
    return out


def eval_child_not_home(user, now, lang, routines=None):
    if not _flag("safe_journey", user):
        return []
    routines = child_not_home_routines(now) if routines is None else routines
    from ..push import seen_name
    out = []
    for r, home_by in routines:
        if not any(u.pk == user.pk for u in _routine_watchers(r)):
            continue
        name = seen_name(user, r.user)
        dest = (r.destination or {}).get("name") or ""
        t = r.time
        out.append(Candidate(
            "child_not_home", "child:%d:%s" % (r.id, home_by.date().isoformat()), 1,
            "%s এখনো বাসায় পৌঁছানোর খবর নেই" % name, "No arrival yet from %s" % name,
            "%s-এর রুটিন: %s%s-এর মধ্যে পৌঁছানো। নিরাপদ যাত্রায় আজ পৌঁছানো দেখা যায়নি — একবার ফোন করে দেখুন।" % (
                name, ("%s, " % dest) if dest else "", _d(t, "bn")),
            "%s's routine: %sby %s. Safe Journey shows no arrival today — maybe give a call." % (
                name, ("%s " % dest) if dest else "", t),
            "%s আপনাকে তাঁর রুটিন যাত্রার পরিচিত হিসেবে বেছে নিয়েছেন। এটি অনুমান নয় — শুধু নিরাপদ যাত্রার রেকর্ড; অবস্থান জানা নেই।" % name,
            "%s chose you as a watcher for this routine. This only reflects Safe Journey records — not their location." % name,
            "journey", {"routine_id": r.id, "traveller_id": r.user_id}, family=True))
    return out


def low_products(user):
    from django.db.models import F
    from ..models import Product
    return list(Product.objects.filter(user=user, stock__lte=F("low_stock_at"))
                .order_by("stock", "name")[:50])


def eval_stock_low(user, now, lang):
    if not _flag("business", user):
        return []
    rows = low_products(user)
    if not rows:
        return []
    today = timezone.localdate(now)
    out_of = [p for p in rows if p.stock <= 0]
    names = ", ".join(p.name for p in rows[:4])
    return [Candidate(
        "stock_low", "stock:%s:%s" % (today.isoformat(), _hash(*sorted(p.id for p in rows))),
        2 if out_of else 3,
        ("%sটি পণ্য শেষ" % _d(len(out_of), "bn")) if out_of else ("%sটি পণ্যের স্টক কম" % _d(len(rows), "bn")),
        ("%d product(s) out of stock" % len(out_of)) if out_of else ("%d product(s) low on stock" % len(rows)),
        names, names,
        "আপনার পণ্যের তালিকায় এগুলোর স্টক আপনার দেওয়া সর্বনিম্ন সীমার সমান বা নিচে।",
        "In your catalog these are at or below the low-stock level you set.",
        "business", {"count": len(rows), "out": len(out_of)})]


def order_buckets(user, now):
    from ..models import Order
    qs = Order.objects.filter(user=user, created_at__gte=now - timedelta(days=14)) \
        .exclude(status__in=("cancelled", "returned", "delivered"))
    verify = list(qs.filter(payment_status="pending_verification",
                            created_at__lte=now - timedelta(hours=2)).values_list("id", flat=True))
    new = list(qs.filter(status="new", created_at__lte=now - timedelta(hours=6))
               .exclude(payment_status="pending_verification").values_list("id", flat=True))
    cod = list(qs.filter(status="shipped", payment__in=("cod", "cash"),
                         created_at__lte=now - timedelta(days=4)).values_list("id", flat=True))
    return {"verify": verify, "new": new, "cod": cod}


def eval_order_unpaid(user, now, lang):
    if not _flag("business", user):
        return []
    b = order_buckets(user, now)
    n = sum(len(v) for v in b.values())
    if not n:
        return []
    today = timezone.localdate(now)
    parts_bn, parts_en = [], []
    if b["verify"]:
        parts_bn.append("%sটির পেমেন্ট যাচাই বাকি" % _d(len(b["verify"]), "bn"))
        parts_en.append("%d payment(s) to verify" % len(b["verify"]))
    if b["new"]:
        parts_bn.append("%sটি নিশ্চিত করা হয়নি" % _d(len(b["new"]), "bn"))
        parts_en.append("%d not confirmed" % len(b["new"]))
    if b["cod"]:
        parts_bn.append("%sটি COD ৪ দিনের বেশি পথে" % _d(len(b["cod"]), "bn"))
        parts_en.append("%d COD parcel(s) out for over 4 days" % len(b["cod"]))
    ids = sorted(i for v in b.values() for i in v)
    return [Candidate(
        "order_unpaid", "orders:%s:%s" % (today.isoformat(), _hash(*ids)), 2,
        "%sটি অর্ডার আপনার অপেক্ষায়" % _d(n, "bn"), "%d order(s) waiting for you" % n,
        "; ".join(parts_bn) + "।", "; ".join(parts_en) + ".",
        "এগুলো আপনার অর্ডার তালিকা থেকে — নতুন অর্ডারের সাথে সাথে যে নোটিফিকেশন যায় তার পরেও এখনো খোলা।",
        "From your orders list — still open after the instant new-order alert.",
        "orders", {k: len(v) for k, v in b.items()})]


def meter_lows(user, today):
    """[(name, alert dict)] from the prepaid-meter estimate (never a remote read)."""
    from ..models import PaCollectionItem
    from ..logic import prepaid_meter as PM
    meters = list(PaCollectionItem.objects.filter(user=user, collection="meter/meters"))
    if not meters:
        return []
    rech = {}
    for r in PaCollectionItem.objects.filter(user=user, collection="meter/recharges"):
        rech.setdefault(str((r.data or {}).get("meter")), []).append(r.data or {})
    out = []
    for m in meters:
        data = dict(m.data or {})
        rr = rech.get(str(m.id), [])
        try:
            if hasattr(PM, "low_alert"):              # remmeter's guard (reused)
                a = PM.low_alert(data, rr, as_of=today)
            else:
                p = PM.project_runout(data, rr, as_of=today)
                a = None
                if p.get("state") in ("low", "empty") and p.get("basis") != "none" \
                        and data.get("alerts") is not False:
                    a = {"level": p["state"], "days_left": p.get("days_left"),
                         "runout_date": p.get("runout_date")}
        except Exception:
            a = None
        if a:
            out.append(((data.get("name") or "").strip() or "Meter", m.id, a))
    return out


def eval_meter_low(user, now, lang):
    if not _flag("prepaid_meter", user):
        return []
    today = timezone.localdate(now)
    out = []
    for name, mid, a in meter_lows(user, today):
        dl = a.get("days_left")
        if a.get("level") == "empty":
            b_bn, b_en = "আনুমানিক হিসাবে ব্যালান্স শেষ", "by our estimate the balance is used up"
        else:
            b_bn = "আনুমানিক %s দিন চলবে" % _d(dl if dl is not None else "?", "bn")
            b_en = "about %s day(s) left (estimate)" % (dl if dl is not None else "?")
        out.append(Candidate(
            "meter_low", "meter:%s:%s:%s" % (mid, a.get("level"), a.get("runout_date") or ""), 3,
            "মিটার: %s" % name, "Meter: %s" % name, b_bn, b_en,
            "আপনার রিচার্জ ও খরচের হিসাব থেকে অনুমান — মিটার দূর থেকে পড়া হয় না।",
            "Estimated from your own recharges and usage — the meter is never read remotely.",
            "prepaid_meter", {"meter_id": mid, "level": a.get("level")}))
    return out


def camera_open_events(user, since):
    from ..models import ShopEvent
    return ShopEvent.objects.filter(site__owner=user, status="open", pending=False,
                                    created__gte=since)


def eval_camera_alert(user, now, lang):
    if not _flag("home_watchman", user):
        return []
    qs = camera_open_events(user, now - timedelta(hours=24))
    n = qs.count()
    if not n:
        return []
    today = timezone.localdate(now)
    return [Candidate(
        "camera_alert", "camera:%s:%s" % (today.isoformat(), n), 3,
        "%sটি ক্যামেরা সতর্কতা দেখা বাকি" % _d(n, "bn"), "%d camera alert(s) not checked yet" % n,
        "গত ২৪ ঘণ্টায় — খুলে দেখে 'দেখেছি' বা 'ভুল সতর্কতা' চিহ্ন দিন।",
        "From the last 24 hours — open and mark them checked or false alarm.",
        "প্রতিটি সতর্কতা তখনই আলাদা নোটিফিকেশনে গেছে; এটি শুধু না-দেখা সতর্কতার সারাংশ।",
        "Each alert was sent the moment it happened; this is only a summary of unchecked ones.",
        "watchman", {"count": n})]


EVALUATORS = {
    "bill_due": eval_bill_due,
    "remit_missing": eval_remit_missing,
    "child_not_home": eval_child_not_home,
    "stock_low": eval_stock_low,
    "order_unpaid": eval_order_unpaid,
    "meter_low": eval_meter_low,
    "camera_alert": eval_camera_alert,
}


def candidates(user, now, routines=None):
    lang = _lang(user)
    off = set(prefs_for(user).off or ())
    out = []
    for k, fn in EVALUATORS.items():
        if k in off:
            continue
        try:
            if k == "child_not_home":
                out.extend(fn(user, now, lang, routines=routines))
            else:
                out.extend(fn(user, now, lang))
        except Exception as e:           # one broken module never stops the rest
            log.warning("proactive: %s failed for user %s: %s", k, user.pk, type(e).__name__)
    return out


# ------------------------------------------------------------------ delivery
def _push(user, nudge):
    """One notification push (kind agent_nudge). Returns devices reached."""
    from .. import push as PUSH
    return PUSH.push_to_user(user, PUSH_KIND, nudge.title_bn, nudge.title_en,
                             nudge.body_bn, nudge.body_en,
                             data={"nudge_id": nudge.id, "trigger": nudge.trigger,
                                   "route": nudge.route or "agent"},
                             high_priority=nudge.priority == 1)


def pushed_today(user, today):
    from ..models import AgentNudge
    return AgentNudge.objects.filter(user=user, for_date=today, counted=True,
                                     pushed_at__isnull=False).count()


def decide(user, prefs, c, now, quiet=None):
    """(delivery, reason) for a candidate. Pure over the DB counters."""
    from ..models import AgentNudge
    local = timezone.localtime(now)
    if c.trigger in BRIEF_ONLY or c.priority >= 3:
        return "brief", "batch"
    q, fam = quiet if quiet is not None else quiet_state(user, prefs, local)
    if q and c.family and not fam:
        return "brief", "quiet"         # the user's DND keeps even family out
    if q and not c.family:
        return "defer", "quiet"         # not stored: re-checked after quiet hours
    if c.trigger in SAFETY:
        return "push", ""
    cd = TRIGGERS[c.trigger][2]
    if cd and AgentNudge.objects.filter(user=user, trigger=c.trigger, pushed_at__isnull=False,
                                        pushed_at__gte=now - timedelta(hours=cd)).exists():
        return "brief", "cooldown"
    if pushed_today(user, local.date()) >= int(prefs.daily_cap):
        return "brief", "cap"
    return "push", ""


def deliver(user, prefs, c, now, stats, quiet=None):
    """Create the nudge once (unique per user+trigger+key) and push it when the
    rules allow. A repeated tick finds the row and does nothing."""
    from ..models import AgentNudge
    if AgentNudge.objects.filter(user=user, trigger=c.trigger, dedupe_key=c.key[:120]).exists():
        stats["dedupe"] += 1
        return None
    delivery, reason = decide(user, prefs, c, now, quiet)
    if delivery == "defer":
        stats["deferred"] += 1
        return None
    try:
        with transaction.atomic():
            n = AgentNudge.objects.create(
                user=user, trigger=c.trigger, dedupe_key=c.key[:120], priority=c.priority,
                delivery=delivery, reason=reason,
                counted=TRIGGERS[c.trigger][3] and c.trigger not in SAFETY,
                title_bn=c.title_bn[:200], title_en=c.title_en[:200], body_bn=c.body_bn,
                body_en=c.body_en, why_bn=c.why_bn[:300], why_en=c.why_en[:300],
                route=c.route or TRIGGERS[c.trigger][5], data=c.data,
                for_date=timezone.localdate(now))
    except IntegrityError:
        stats["dedupe"] += 1
        return None
    if delivery == "push":
        sent = _push(user, n)
        if sent:
            n.pushed_at = now
            n.save(update_fields=["pushed_at"])
            stats["pushed"] += 1
        else:
            n.delivery, n.reason = "card", "no_device"
            n.save(update_fields=["delivery", "reason"])
            stats["card"] += 1
    else:
        stats["batched"] += 1
    return n


# ------------------------------------------------------------------ brief / recap
def _sec(key, bn, en, lines):
    return {"key": key, "title_bn": bn, "title_en": en, "lines": lines}


def _line(bn, en):
    return {"bn": bn, "en": en}


def build_brief(user, kind, now):
    """Morning brief / evening recap from the user's own data (no AI).
    Returns {kind, date, sections:[{key,title_bn,title_en,lines:[{bn,en}]}], empty}."""
    from ..models import Reminder, Transaction
    from .runner import Ctx
    from . import tools as TL
    local = timezone.localtime(now)
    today = local.date()
    ctx = Ctx(user=user, now=now, lang=_lang(user), play=True)
    secs = []
    evening = kind == "brief_evening"
    off = set(prefs_for(user).off or ())

    # reminders
    day0 = local.replace(hour=0, minute=0, second=0, microsecond=0)
    if evening:
        t0, t1 = day0 + timedelta(days=1), day0 + timedelta(days=2)
    else:
        t0, t1 = day0, day0 + timedelta(days=1)
    rems = list(Reminder.objects.filter(user=user, done=False, due_at__gte=t0, due_at__lt=t1)
                .order_by("due_at")[:20])
    lines = []
    if rems:
        titles = ", ".join(r.title for r in rems[:3])
        more = len(rems) - 3
        lines.append(_line(
            "%s %sটি: %s%s" % ("কাল" if evening else "আজ", _d(len(rems), "bn"), titles,
                               (" এবং আরও %sটি" % _d(more, "bn")) if more > 0 else ""),
            "%s %d: %s%s" % ("Tomorrow" if evening else "Today", len(rems), titles,
                             (" and %d more" % more) if more > 0 else "")))
    if evening:
        done_today = Reminder.objects.filter(user=user, done=True, due_at__gte=day0,
                                             due_at__lt=day0 + timedelta(days=1)).count()
        open_today = Reminder.objects.filter(user=user, done=False, due_at__gte=day0,
                                             due_at__lt=local).count()
        if done_today or open_today:
            lines.append(_line("আজ শেষ হয়েছে %sটি, বাকি %sটি।" % (_d(done_today, "bn"), _d(open_today, "bn")),
                               "Done today: %d, still open: %d." % (done_today, open_today)))
    if lines:
        secs.append(_sec("reminders", "রিমাইন্ডার", "Reminders", lines))

    # bills
    lines = []
    if "bill_due" not in off:
        for kind_, rid, name, amount, due, _has in _bill_rows(user, today, "bn"):
            days = (due - today).days
            if days > (2 if not evening else 1) or days < -7:
                continue
            if days < 0:
                w = ("%s দিন পেরিয়েছে" % _d(-days, "bn"), "%d day(s) overdue" % -days)
            elif days == 0:
                w = ("আজ", "today")
            else:
                w = ("%s দিন পরে" % _d(days, "bn"), "in %d day(s)" % days)
            lines.append(_line("%s — %s (%s)" % (name, _money(amount, "bn"), w[0]),
                               "%s — %s (%s)" % (name, _money(amount, "en"), w[1])))
    if lines:
        secs.append(_sec("bills", "বিল ও দেনা", "Bills & dues", lines[:6]))

    # money
    lines = []
    if evening:
        spent = Transaction.objects.filter(user=user, kind="expense", date=today) \
            .aggregate(s=Sum("amount"))["s"]
        if spent:
            lines.append(_line("আজ খরচ %s।" % _money(spent, "bn"), "Spent today: %s." % _money(spent, "en")))
    m = TL._money_month(ctx, {})
    if m["count"]:
        lines.append(_line("এ মাসে আয় %s, খরচ %s।" % (_money(m["income"], "bn"), _money(m["expense"], "bn")),
                           "This month: income %s, spent %s." % (_money(m["income"], "en"),
                                                                 _money(m["expense"], "en"))))
    bs = TL._budget_status(ctx, {})
    bad = [i for i in bs["items"] if i["state"] != "ok"]
    if bad:
        lines.append(_line("বাজেটের কাছে/পেরিয়েছে: %s।" % ", ".join(
            "%s %s%%" % (i["category"], _d(i["pct"], "bn")) for i in bad[:3]),
            "Near/over budget: %s." % ", ".join("%s %d%%" % (i["category"], i["pct"]) for i in bad[:3])))
    for c in (eval_remit_missing(user, now, "bn") if "remit_missing" not in off else []):
        lines.append(_line("%s — %s" % (c.title_bn, c.body_bn), "%s — %s" % (c.title_en, c.body_en)))
    if lines:
        secs.append(_sec("money", "টাকা-পয়সা", "Money", lines))

    # family (consent-based: only journeys / routines where this user is a chosen watcher)
    lines = []
    if _flag("safe_journey", user):
        fs = TL._family_status(ctx, {})
        for i in fs["items"][:4]:
            if i["sos"]:
                continue                        # SOS has its own screen; never repeated here
            if i["overdue_state"] in ("grace", "ask", "alert"):
                lines.append(_line("%s — %s মিনিট দেরি" % (i["name"], _d(i["overdue_minutes"], "bn")),
                                   "%s — %d min late" % (i["name"], i["overdue_minutes"])))
            elif i["status"] == "active":
                lines.append(_line("%s এখন যাত্রায় (%s)" % (i["name"], i["destination"] or "—"),
                                   "%s is on a journey (%s)" % (i["name"], i["destination"] or "—")))
            elif i["status"] == "arrived":
                lines.append(_line("%s নিরাপদে পৌঁছেছেন" % i["name"], "%s arrived safely" % i["name"]))
    from ..models import AgentNudge
    for n in AgentNudge.objects.filter(user=user, trigger="child_not_home", for_date=today) \
            .exclude(delivery="brief"):
        lines.append(_line(n.title_bn, n.title_en))
    if lines:
        secs.append(_sec("family", "পরিবার", "Family", lines[:5]))

    # business
    lines = []
    if _flag("business", user):
        if evening:
            from ..models import Sale
            agg = Sale.objects.filter(user=user, voided_at__isnull=True, created_at__gte=day0) \
                .aggregate(s=Sum("total"))
            cnt = Sale.objects.filter(user=user, voided_at__isnull=True, created_at__gte=day0).count()
            if cnt:
                lines.append(_line("আজ বিক্রি %sটি, মোট %s।" % (_d(cnt, "bn"), _money((agg["s"] or 0) / 100, "bn")),
                                   "Sales today: %d, total %s." % (cnt, _money((agg["s"] or 0) / 100, "en"))))
        kd = TL._khata_dues(ctx, {"limit": 1})
        if kd["count"]:
            lines.append(_line("খাতায় %sজনের কাছে বাকি %s।" % (_d(kd["count"], "bn"), _money(kd["total_due"], "bn")),
                               "%d customer(s) owe you %s." % (kd["count"], _money(kd["total_due"], "en"))))
        if "order_unpaid" not in off:
            for c in eval_order_unpaid(user, now, "bn"):
                lines.append(_line("%s: %s" % (c.title_bn, c.body_bn), "%s: %s" % (c.title_en, c.body_en)))
        if "stock_low" not in off:
            for c in eval_stock_low(user, now, "bn"):
                lines.append(_line("%s: %s" % (c.title_bn, c.body_bn), "%s: %s" % (c.title_en, c.body_en)))
    if lines:
        secs.append(_sec("business", "ব্যবসা", "Business", lines))

    # home: meter + camera (summaries; the real-time alerts stay with their owners)
    lines = []
    if "meter_low" not in off:
        for c in eval_meter_low(user, now, "bn"):
            lines.append(_line("%s — %s" % (c.title_bn, c.body_bn), "%s — %s" % (c.title_en, c.body_en)))
    if "camera_alert" not in off:
        for c in eval_camera_alert(user, now, "bn"):
            lines.append(_line(c.title_bn, c.title_en))
    if lines:
        secs.append(_sec("home", "বাসা ও দোকান", "Home & shop", lines))

    # cctvx: the NIGHTLY GUARD REPORT (owner order 28 Oct) — drawer opens
    # with / without a sale, away-mode alerts, offline minutes, alerts passed
    # on. From the server's own counts: no AI, 0 credits.
    lines = []
    if evening and "camera_alert" not in off and _flag("home_watchman", user):
        try:
            from .. import cctvx_views as CXV
            for ln in CXV.brief_lines(user, now):
                lines.append(_line(ln["bn"], ln["en"]))
        except Exception:
            lines = []
    if lines:
        secs.append(_sec("guard", "পাহারার রিপোর্ট", "Guard report", lines))

    # prayer / weather — only the real sources the app already has
    lines = []
    if not evening and _flag("unseen_world", user):
        lines.extend(_world_lines(user, local))
    if lines:
        secs.append(_sec("today", "আজকের দিন", "Today", lines))

    return {"kind": kind, "date": today.isoformat(), "sections": secs, "empty": not secs,
            "ai_used": False}


def _world_lines(user, local):
    """Prayer times (local astronomical calc, the Unseen World card) and the
    cached MET Norway weather (CC BY 4.0) — only for users who set up Unseen
    World (a WorldPrefs row). Never fetches anything from the network here."""
    from ..models import WorldFeed, WorldPrefs
    from ..logic import ramadan
    from ..logic import world_feeds as WF
    p = WorldPrefs.objects.filter(user=user).first()
    if p is None:
        return []
    on = WF.merge_cards(p.cards)
    c = WF.city(p.city)
    out = []
    if on.get("prayer"):
        try:
            t = ramadan.prayer_times(local.date(), c[3], c[4], tz_offset_hours=6.0,
                                     asr=ramadan.ASR_HANAFI)
            keys = (("fajr", "ফজর", "Fajr"), ("dhuhr", "যোহর", "Dhuhr"), ("asr", "আসর", "Asr"),
                    ("maghrib", "মাগরিব", "Maghrib"), ("isha", "এশা", "Isha"))
            bn = ", ".join("%s %s" % (b, _d(t[k], "bn")) for k, b, _ in keys if t.get(k))
            en = ", ".join("%s %s" % (e, t[k]) for k, _, e in keys if t.get(k))
            if bn:
                out.append(_line("নামাজ (%s, স্থানীয় হিসাব): %s" % (c[1], bn),
                                 "Prayer (%s, local calculation): %s" % (c[2], en)))
        except Exception:
            pass
    if on.get("weather"):
        row = WorldFeed.objects.filter(slug="weather_" + c[0], enabled=True).first()
        fresh = row is not None and row.fetched_at and \
            row.fetched_at >= timezone.now() - timedelta(hours=6)
        w = WF.weather_public(row.payload, "bn") if fresh else None
        if w:
            we = WF.weather_public(row.payload, "en")
            out.append(_line("আবহাওয়া (%s): %s°, %s" % (c[1], _d(w["temp"], "bn"), w["label"]),
                             "Weather (%s): %s°, %s" % (c[2], we["temp"], we["label"])))
    return out


def brief_text(brief, lang):
    """Screen text: heading + "• line" per item."""
    head = _brief_head(brief, lang)
    if brief["empty"]:
        return head + "\n" + _pick(lang, "আজ বিশেষ কিছু নেই।", "Nothing special today.")
    rows = [head]
    for s in brief["sections"]:
        rows.append(s["title_bn"] if lang == "bn" else s["title_en"])
        rows.extend("• " + ln[lang] for ln in s["lines"])
    return "\n".join(rows)


def _brief_head(brief, lang):
    d = date.fromisoformat(brief["date"])
    if brief["kind"] == "brief_morning":
        return _pick(lang, "সুপ্রভাত! আজকের সংক্ষেপ (%s)" % _d(d.strftime("%d/%m"), "bn"),
                     "Good morning! Your day (%s)" % d.strftime("%d/%m"))
    return _pick(lang, "আজকের দিনের হিসাব (%s)" % _d(d.strftime("%d/%m"), "bn"),
                 "Your day in review (%s)" % d.strftime("%d/%m"))


def voice_text(brief, lang):
    """Text for the device TTS: no bullets/symbols, "৳500" -> "500 টাকা"."""
    import re
    parts = [_brief_head(brief, lang)]
    if brief["empty"]:
        parts.append(_pick(lang, "আজ বিশেষ কিছু নেই", "Nothing special today"))
    for s in brief["sections"]:
        parts.append(s["title_bn"] if lang == "bn" else s["title_en"])
        parts.extend(ln[lang] for ln in s["lines"])
    t = "। ".join(p.rstrip("।.") for p in parts) if lang == "bn" else \
        ". ".join(p.rstrip("।.") for p in parts)
    t = re.sub(r"৳([0-9০-৯][0-9০-৯,\.]*)", lambda m: m.group(1) + (" টাকা" if lang == "bn" else " taka"), t)
    t = t.replace("—", ",").replace("•", "").replace("%", " শতাংশ" if lang == "bn" else " percent")
    return re.sub(r"\s+", " ", t).strip() + ("।" if lang == "bn" else ".")


def brief_out(brief, lang):
    return {"kind": brief["kind"], "date": brief["date"], "empty": brief["empty"],
            "sections": [{"key": s["key"], "title": s["title_bn"] if lang == "bn" else s["title_en"],
                          "lines": [ln[lang] for ln in s["lines"]]} for s in brief["sections"]],
            "text": brief_text(brief, lang),
            "voice": {"text": voice_text(brief, lang), "lang": lang, "engine": "device_tts",
                      "fallback": "text_only"},
            "ai_used": False, "credits": 0}


def _brief_due(prefs, kind, local):
    now_m = local.hour * 60 + local.minute
    if kind == "brief_morning":
        return bool(prefs.morning_brief) and _mins(prefs.morning_at, 450) <= now_m < MORNING_END_H * 60
    return bool(prefs.evening_recap) and \
        _mins(prefs.evening_at, 1260) <= now_m < EVENING_END[0] * 60 + EVENING_END[1]


def deliver_brief(user, prefs, kind, now, stats, quiet=None):
    """At most one morning brief and one evening recap per user per day."""
    from ..models import AgentNudge
    local = timezone.localtime(now)
    if not _brief_due(prefs, kind, local):
        return None
    today = local.date()
    key = today.isoformat()
    if AgentNudge.objects.filter(user=user, trigger=kind, dedupe_key=key).exists():
        return None
    q, _fam = quiet if quiet is not None else quiet_state(user, prefs, local)
    if q and kind == "brief_morning":
        return None                     # wait for the quiet window to end (before 11:00)
    brief = build_brief(user, kind, now)
    lang = _lang(user)
    held = list(AgentNudge.objects.filter(user=user, delivery="brief", in_brief__isnull=True,
                                          for_date__gte=today - timedelta(days=1))
                .exclude(trigger__in=BRIEFS))
    extra = [h for h in held if h.trigger not in BRIEF_DERIVED]
    if extra:
        brief["sections"].append(_sec("held", "অপেক্ষায় ছিল", "Held for you",
                                      [_line(h.title_bn, h.title_en) for h in extra]))
        brief["empty"] = False
    out_bn, out_en = brief_out(brief, "bn"), brief_out(brief, "en")
    n_items = sum(len(s["lines"]) for s in brief["sections"])
    if kind == "brief_morning":
        t_bn, t_en = "সকালের সংক্ষেপ", "Morning brief"
    else:
        t_bn, t_en = "সন্ধ্যার হিসাব", "Evening recap"
    sb = "%sটি বিষয়" % _d(n_items, "bn") if n_items else "আজ বিশেষ কিছু নেই"
    se = "%d item(s)" % n_items if n_items else "Nothing special today"
    if not brief["empty"]:
        first = brief["sections"][0]["lines"][0]
        sb, se = "%s — %s" % (sb, first["bn"]), "%s — %s" % (se, first["en"])
    try:
        with transaction.atomic():
            n = AgentNudge.objects.create(
                user=user, trigger=kind, dedupe_key=key, priority=3,
                delivery="push" if (not brief["empty"] and not q) else "card",
                reason="" if not brief["empty"] and not q else ("quiet" if q else "empty"),
                counted=False, title_bn=t_bn, title_en=t_en, body_bn=sb[:900], body_en=se[:900],
                why_bn="আপনি %s চালু রেখেছেন (সেটিংসে সময় বদলানো বা বন্ধ করা যায়)। AI ছাড়া, আপনার নিজের তথ্য থেকে — কোনো ক্রেডিট লাগে না।" % (
                    "সকালের সংক্ষেপ" if kind == "brief_morning" else "সন্ধ্যার হিসাব"),
                why_en="You have the %s on (change the time or turn it off in settings). Built from your own data without AI — no credits." % (
                    "morning brief" if kind == "brief_morning" else "evening recap"),
                route="agent", data={"bn": out_bn, "en": out_en}, for_date=today)
    except IntegrityError:
        return None
    AgentNudge.objects.filter(pk__in=[h.pk for h in held]).update(in_brief=n)
    if n.delivery == "push":
        if _push(user, n):
            n.pushed_at = now
            n.save(update_fields=["pushed_at"])
            stats["briefs_pushed"] += 1
        else:
            n.delivery, n.reason = "card", "no_device"
            n.save(update_fields=["delivery", "reason"])
    stats["briefs"] += 1
    return n


# ------------------------------------------------------------------ scheduler
def candidate_users(now):
    """Users the flag can be on for: everyone active in 30 days when the flag
    is rolled out, else only the allow-list + staff (the owner/testers)."""
    from ..models import User
    try:
        from .. import feature_flags as FF
        row = FF.rows().get(FLAG) or {}
    except Exception:
        return User.objects.none()
    if row.get("enabled_all") and row.get("enabled_play"):
        since = now - timedelta(days=30)
        return User.objects.filter(is_active=True).filter(
            Q(last_login__gte=since) | Q(devices__last_seen__gte=since)).distinct()
    ids = list(row.get("allow_user_ids") or [])
    return User.objects.filter(is_active=True).filter(
        Q(pk__in=ids) | Q(is_staff=True) | Q(is_superuser=True))


def _stats():
    from collections import Counter
    return Counter(users=0, pushed=0, batched=0, card=0, dedupe=0, deferred=0, briefs=0,
                   briefs_pushed=0, skipped_flag=0)


def tick(now=None, users=None):
    """One scheduler pass (cron every 15 min). Idempotent: run it as often as
    you like — every nudge/brief is unique per (user, trigger, key)."""
    now = now or timezone.now()
    stats = _stats()
    users = list(candidate_users(now) if users is None else users)
    routines = None
    for u in users:
        if not flag_on(u):
            stats["skipped_flag"] += 1
            continue
        if routines is None:
            routines = child_not_home_routines(now)
        stats["users"] += 1
        prefs = prefs_for(u)
        local = timezone.localtime(now)
        quiet = quiet_state(u, prefs, local)
        cands = candidates(u, now, routines=routines)
        cands.sort(key=lambda c: (c.priority, c.trigger))   # urgent first under the cap
        for c in cands:
            deliver(u, prefs, c, now, stats, quiet)
        for kind in BRIEFS:
            deliver_brief(u, prefs, kind, now, stats, quiet)
    return dict(stats)


# ------------------------------------------------------------------ API helpers
def nudge_out(n, lang):
    d = {"id": n.id, "trigger": n.trigger, "priority": n.priority,
         "title": n.title_bn if lang == "bn" else n.title_en,
         "body": n.body_bn if lang == "bn" else n.body_en,
         "why": n.why_bn if lang == "bn" else n.why_en,
         "route": n.route, "delivery": n.delivery, "date": n.for_date.isoformat(),
         "created_at": n.created_at.isoformat(), "opened": bool(n.opened_at),
         "label": _pick(lang, *TRIGGERS[n.trigger][:2]) if n.trigger in TRIGGERS else
         _pick(lang, "সংক্ষেপ", "Brief")}
    if n.trigger in BRIEFS:
        d["brief"] = (n.data or {}).get(lang)
    return d


def stats_by_trigger(since):
    """Owner Admin: sent / batched / opened / dismissed per trigger + opted-out."""
    from django.db.models import Count
    from ..models import AgentNudge, AgentNudgePrefs
    rows = {r["trigger"]: r for r in AgentNudge.objects.filter(created_at__gte=since)
            .values("trigger").annotate(
                n=Count("id"), sent=Count("id", filter=Q(pushed_at__isnull=False)),
                batched=Count("id", filter=Q(delivery="brief")),
                opened=Count("id", filter=Q(opened_at__isnull=False)),
                dismissed=Count("id", filter=Q(dismissed_at__isnull=False)))}
    opted = {}
    for off in AgentNudgePrefs.objects.values_list("off", flat=True):
        for k in off or ():
            opted[k] = opted.get(k, 0) + 1
    out = []
    for k in list(TRIGGERS) + list(BRIEFS):
        r = rows.get(k, {})
        out.append({"trigger": k, "n": r.get("n", 0), "sent": r.get("sent", 0),
                    "batched": r.get("batched", 0), "opened": r.get("opened", 0),
                    "dismissed": r.get("dismissed", 0), "opted_out": opted.get(k, 0)})
    return out
