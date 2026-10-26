"""
remittance_service.py — Budget & Remittance (flag `budget_remittance`,
default OFF): storage, encryption at rest, validation and limits.

ENCRYPTION AT REST (honest): every financial value — amount, currency, rate,
taka, sender name / My Circle member, channel, note, bills, expected amount —
is sealed with Fernet (AES-128-CBC + HMAC-SHA256) before it reaches the DB
(`enc` columns). Only what queries need stays in clear: user id, client id,
date, month, and the plan/expense category keys of the EXISTING Budget and
Transaction tables (this feature reuses them — they are the Money module's
data, stored as before). The key comes from the server environment
(FINANCE_FERNET_KEY, else INTEGRATIONS_FERNET_KEY, else one derived from
SECRET_KEY): it is on the SAME server, so this protects database dumps and
backups, not a server that is taken over completely. Older keys stay readable
(MultiFernet), so adding FINANCE_FERNET_KEY later never loses data.

This data is NEVER used for ads, analytics, AI or shared with anyone; the
user can export it (CSV / text / PDF) and delete all of it.
"""
import base64
import hashlib
import json
import logging
import os
import re
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation

from django.conf import settings
from django.utils import timezone

from .logic import remittance as L
from .logic.budget import to_poisha

log = logging.getLogger("assisto.remittance")

FLAG = "budget_remittance"

KNOBS = {   # Owner Admin → Pricing → shop (bounded in core.logic.pricing)
    "remit_entries_per_day": 40,     # new remittance / spending entries per user per day
    "remit_entries_max": 5000,       # remittance entries kept per user
    "remit_bills_max": 30,           # bills paid from remittance per user
    "remit_exports_per_day": 10,     # CSV / PDF / text exports per user per day
}

CLIENT_ID = re.compile(r"^[A-Za-z0-9_-]{8,36}$")
MAX_AMOUNT_P = to_poisha("100000000")      # 10 crore — anything above is a typo
MAX_RATE = Decimal("1000")


class RemitError(Exception):
    def __init__(self, code, status=400, **extra):
        super().__init__(code)
        self.code = code
        self.status = status
        self.extra = extra


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def knob(key):
    from . import billing
    try:
        return int((billing.cfg().get("shop") or {}).get(key, KNOBS[key]))
    except Exception:
        return KNOBS[key]


# ------------------------------------------------------------------ crypto
_FERNET = None


def _keys():
    out = []
    for name in ("FINANCE_FERNET_KEY", "INTEGRATIONS_FERNET_KEY"):
        v = (os.getenv(name) or "").strip()
        if v and v not in out:
            out.append(v)
    derived = base64.urlsafe_b64encode(
        hashlib.sha256(("assisto-finance:" + settings.SECRET_KEY).encode()).digest()).decode()
    out.append(derived)
    return out


def fernet():
    global _FERNET
    if _FERNET is None:
        from cryptography.fernet import Fernet, MultiFernet
        fs = []
        for k in _keys():
            try:
                fs.append(Fernet(k.encode()))
            except Exception:
                log.warning("remittance: an encryption key in the environment is not a valid Fernet key")
        _FERNET = MultiFernet(fs)
    return _FERNET


def reset_crypto():
    global _FERNET
    _FERNET = None


def seal(data):
    return fernet().encrypt(json.dumps(data, ensure_ascii=False, default=str).encode()).decode()


def unseal(blob):
    if not blob:
        return {}
    try:
        return json.loads(fernet().decrypt(blob.encode()).decode())
    except Exception:
        log.warning("remittance: a row could not be decrypted (key changed?)")
        return {}


# ------------------------------------------------------------------ helpers
def today():
    return timezone.localdate()


def _dec(v, field):
    if v is None or v == "":
        return None
    try:
        d = Decimal(str(v).replace(",", "").strip())
    except (InvalidOperation, ValueError):
        raise RemitError("bad_number", field=field)
    if not d.is_finite():
        raise RemitError("bad_number", field=field)
    return d


def _money(v, field, required=True, allow_zero=False):
    d = _dec(v, field)
    if d is None:
        if required:
            raise RemitError("bad_amount", field=field)
        return None
    if d < 0 or (d == 0 and not allow_zero) or to_poisha(d) > MAX_AMOUNT_P:
        raise RemitError("bad_amount", field=field)
    return d.quantize(Decimal("0.01"))


def _date(v):
    if v in (None, ""):
        return today()
    try:
        d = date.fromisoformat(str(v)[:10])
    except ValueError:
        raise RemitError("bad_date")
    if d > today() + timedelta(days=1) or d.year < 2000:
        raise RemitError("bad_date")
    return d


def _text(v, n):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


def _member(user, member_id):
    """(id, name) of an accepted My Circle member of THIS user, else (None, '')."""
    if member_id in (None, "", 0):
        return None, ""
    try:
        mid = int(member_id)
    except (TypeError, ValueError):
        raise RemitError("bad_sender")
    from .models import CircleMember
    m = CircleMember.objects.filter(user=user, pk=mid, state="accepted").first()
    if not m:
        raise RemitError("bad_sender")
    name = m.name
    if not name and m.peer_user_id:
        name = (getattr(m.peer_user, "first_name", "") or getattr(m.peer_user, "username", "")) or ""
    return m.pk, name


def clean_entry(user, body, partial=None):
    """Validate an entry body -> the dict that is sealed. `partial` = the
    current decrypted entry (PATCH)."""
    cur = dict(partial or {})
    b = body or {}

    def has(k):
        return k in b

    amount = _money(b.get("amount"), "amount") if (has("amount") or partial is None) \
        else _dec(cur.get("amount"), "amount")
    currency = (str(b.get("currency") or "").strip().upper() if has("currency")
                else str(cur.get("currency") or "BDT")) or "BDT"
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise RemitError("bad_currency")
    rate = _dec(b.get("rate"), "rate") if has("rate") else _dec(cur.get("rate"), "rate")
    tk = _money(b.get("taka"), "taka", required=False) if has("taka") \
        else (None if (has("amount") or has("rate") or has("currency")) else _dec(cur.get("taka"), "taka"))
    if currency == "BDT":
        rate = Decimal("1")
        tk = tk or amount
    else:
        if rate is not None and (rate <= 0 or rate > MAX_RATE):
            raise RemitError("bad_rate")
        if tk is None and rate is None:
            raise RemitError("need_rate")
        if tk is None:
            tk = (amount * rate).quantize(Decimal("0.01"))
        if rate is None:
            rate = (tk / amount).quantize(Decimal("0.0001"))
    if to_poisha(tk) > MAX_AMOUNT_P or tk <= 0:
        raise RemitError("bad_amount", field="taka")
    channel = str(b.get("channel") if has("channel") else cur.get("channel") or "other")
    if channel not in L.CHANNELS:
        raise RemitError("bad_channel")
    if has("sender_member_id"):
        mid, mname = _member(user, b.get("sender_member_id"))
    else:
        mid, mname = cur.get("sender_member_id"), ""
    name = _text(b.get("sender_name"), 80) if has("sender_name") else cur.get("sender_name", "")
    if mid and not name:
        name = mname
    received = _date(b.get("received_on")) if has("received_on") or partial is None \
        else _date(cur.get("received_on"))
    note = _text(b.get("note"), 200) if has("note") else cur.get("note", "")
    return {
        "amount": str(amount), "currency": currency, "rate": str(rate),
        "taka": str(tk), "channel": channel, "sender_member_id": mid,
        "sender_name": name, "note": note, "received_on": received.isoformat(),
    }


def entry_dict(row, data=None):
    d = data if data is not None else unseal(row.enc)
    return {"id": row.id, "client_id": row.client_id,
            "received_on": row.received_on.isoformat(), "month": row.month,
            "amount": d.get("amount", "0"), "currency": d.get("currency", "BDT"),
            "rate": d.get("rate", "1"), "taka": d.get("taka", "0"),
            "channel": d.get("channel", "other"),
            "sender_member_id": d.get("sender_member_id"),
            "sender_name": d.get("sender_name", ""), "note": d.get("note", ""),
            "source": row.source}


def decrypted_entries(user, **filters):
    from .models import RemittanceEntry
    return [entry_dict(r) for r in RemittanceEntry.objects.filter(user=user, **filters)]


def _day_count(user):
    """New entries (remittance + spending made here) since local midnight."""
    from .models import RemittanceEntry, Transaction
    t0 = timezone.make_aware(datetime.combine(today(), time(0, 0)))
    return (RemittanceEntry.objects.filter(user=user, created_at__gte=t0).count()
            + Transaction.objects.filter(user=user, ref__startswith="rm:",
                                         created_at__gte=t0).count())


def check_daily(user):
    if _day_count(user) >= knob("remit_entries_per_day"):
        raise RemitError("daily_cap", 429)


def create_entry(user, body):
    """Idempotent on client_id: the offline queue may send the same entry
    twice — the second time returns the first row (created=False)."""
    from .models import RemittanceEntry
    cid = str((body or {}).get("client_id") or "")
    if not CLIENT_ID.match(cid):
        raise RemitError("bad_client_id")
    old = RemittanceEntry.objects.filter(user=user, client_id=cid).first()
    if old:
        return old, False
    check_daily(user)
    if RemittanceEntry.objects.filter(user=user).count() >= knob("remit_entries_max"):
        raise RemitError("too_many", 429)
    data = clean_entry(user, body)
    src = str(body.get("source") or "manual")
    d = date.fromisoformat(data["received_on"])
    from django.db import IntegrityError, transaction
    try:
        with transaction.atomic():
            row = RemittanceEntry.objects.create(
                user=user, client_id=cid, received_on=d, month=L.month_key(d),
                enc=seal(data), source=src if src in ("manual", "voice", "text") else "manual")
    except IntegrityError:   # a parallel retry won the race
        return RemittanceEntry.objects.get(user=user, client_id=cid), False
    return row, True


def update_entry(row, body):
    data = clean_entry(row.user, body, partial=unseal(row.enc))
    d = date.fromisoformat(data["received_on"])
    row.enc = seal(data)
    row.received_on = d
    row.month = L.month_key(d)
    row.save(update_fields=["enc", "received_on", "month", "updated_at"])
    return row


# ------------------------------------------------------------------ profile
def profile(user):
    from .models import RemittanceProfile
    p, _ = RemittanceProfile.objects.get_or_create(user=user)
    return p


def profile_data(p):
    d = unseal(p.enc)
    d.setdefault("expected_taka", "0")
    d.setdefault("expected_day", 0)
    d.setdefault("expected_sender", "")
    d.setdefault("bills", [])
    return d


def save_profile(p, data):
    p.enc = seal(data)
    p.save()


def clean_settings(body, cur):
    b = body or {}
    out = dict(cur)
    if "expected_taka" in b:
        v = _money(b.get("expected_taka"), "expected_taka", required=False, allow_zero=True)
        out["expected_taka"] = str(v or Decimal("0"))
    if "expected_day" in b:
        try:
            day = int(b.get("expected_day") or 0)
        except (TypeError, ValueError):
            raise RemitError("bad_day")
        if not 0 <= day <= 31:
            raise RemitError("bad_day")
        out["expected_day"] = day
    if "expected_sender" in b:
        out["expected_sender"] = _text(b.get("expected_sender"), 80)
    return out


def clean_bill(body, cur=None):
    b = body or {}
    out = dict(cur or {})
    if "name" in b or cur is None:
        name = _text(b.get("name"), 60)
        if not name:
            raise RemitError("bad_bill")
        out["name"] = name
    if "amount" in b or cur is None:
        out["amount"] = str(_money(b.get("amount"), "amount"))
    if "due_day" in b or cur is None:
        try:
            dd = int(b.get("due_day") or 0)
        except (TypeError, ValueError):
            raise RemitError("bad_day")
        if not 1 <= dd <= 31:
            raise RemitError("bad_day")
        out["due_day"] = dd
    if "category" in b or cur is None:
        c = str(b.get("category") or "other")
        out["category"] = c if c in L.CATEGORIES else "other"
    if "reminder_local_id" in b:
        out["reminder_local_id"] = _text(b.get("reminder_local_id"), 64)
    out.setdefault("paid_months", [])
    return out


# ------------------------------------------------------------------ spending
def family_account(user, lang):
    """The Money-module account this feature writes spending to (created once,
    named in the user's language; the user may rename it in Money)."""
    from .models import Account
    p = profile(user)
    d = profile_data(p)
    aid = d.get("account_id")
    acc = Account.objects.filter(user=user, pk=aid).first() if aid else None
    if acc is None:
        acc = Account.objects.create(
            user=user, acc_type="cash",
            name="পরিবারের বাজেট" if lang == "bn" else "Family budget")
        d["account_id"] = acc.pk
        save_profile(p, d)
    return acc


def add_spending(user, lang, body):
    """One expense in the EXISTING Money module (Transaction), tagged with
    ref 'rm:<client id>' so a retry never doubles it."""
    from .models import Transaction
    b = body or {}
    cid = str(b.get("client_id") or "")
    if not CLIENT_ID.match(cid):
        raise RemitError("bad_client_id")
    old = Transaction.objects.filter(user=user, ref="rm:" + cid).first()
    if old:
        return old, False
    check_daily(user)
    cat = str(b.get("category") or "")
    if cat not in L.CATEGORIES:
        raise RemitError("bad_category")
    amt = _money(b.get("amount"), "amount")
    d = _date(b.get("date"))
    t = Transaction.objects.create(
        user=user, account=family_account(user, lang), kind="expense", amount=amt,
        category=cat, note=_text(b.get("note"), 200), date=d, source="manual",
        ref="rm:" + cid)
    return t, True


def money_txns(user):
    return [{"kind": t.kind, "amount": t.amount, "category": t.category, "date": t.date}
            for t in user.txns.all().only("kind", "amount", "category", "date")]


def plan(user):
    return {b.category: b.monthly_limit for b in user.budgets.filter(category__in=L.CATEGORIES)}


def savings_by_month(user, year=None):
    """Money moved to savings per month: this feature's savings-category
    spending + the user's own 'savings' expenses in Money."""
    out = {}
    qs = user.txns.filter(kind="expense")
    if year:
        qs = qs.filter(date__year=year)
    for t in qs.only("amount", "category", "date"):
        if L.category_of(t.category) != "savings":
            continue
        k = L.month_key(t.date)
        out[k] = out.get(k, 0) + to_poisha(t.amount)
    return out


def goal_dict(goal):
    if not goal:
        return None
    t, s = to_poisha(goal.target_amount), to_poisha(goal.saved_amount)
    return {"id": goal.id, "title": goal.title, "target": L.p2s(t), "saved": L.p2s(s),
            "pct": min(100, int(s * 100 // t)) if t else 0}


# ------------------------------------------------------------------ delete
def delete_all(user):
    """Everything this feature holds for the user: remittance entries,
    settings + bills, the spending entries made here (ref rm:), the family
    budget plan rows (the 7 category keys) and the linked savings goal."""
    from .models import RemittanceEntry, RemittanceProfile, Transaction
    p = RemittanceProfile.objects.filter(user=user).first()
    n = RemittanceEntry.objects.filter(user=user).delete()[0]
    n += Transaction.objects.filter(user=user, ref__startswith="rm:").delete()[0]
    n += user.budgets.filter(category__in=L.CATEGORIES).delete()[0]
    if p is not None:
        if p.goal_id:
            n += user.goals.filter(pk=p.goal_id).delete()[0]
        d = profile_data(p)
        aid = d.get("account_id")
        if aid:
            from .models import Account
            acc = Account.objects.filter(user=user, pk=aid).first()
            if acc is not None and not acc.txns.exists() and not acc.txns_in.exists():
                acc.delete()
        p.delete()
    return n
