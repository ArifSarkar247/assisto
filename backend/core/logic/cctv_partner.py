"""cctvroles (CCTV Guard V3 J) — installer partners: pure rules (no DB, no I/O).

A local CCTV technician applies in the app; the Assisto owner approves in
Owner Admin. A SITE OWNER makes a one-time invite (QR + 8-letter code, 48 h);
an APPROVED partner types / scans it and from then on sees ONLY the setup
status of that site (cameras added / online, box connected, hours, zones) —
never video, never photos, never alerts. The site owner ends it any time.

COMMISSION: a PROPOSAL only (needs owner approval). Nothing is paid, queued
or promised automatically; Owner Admin shows what the proposal WOULD give.
"""
import hashlib
import secrets

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O, 1/I
CODE_LEN = 8
INVITE_HOURS = 48
MAX_OPEN_INVITES = 3            # per site at once
MAX_ACTIVE_INSTALLERS = 2       # per site
NAME_MAX = 80
AREA_MAX = 80
QR_PREFIX = "https://lifeassisto.com/install/"
GATEWAY_FRESH_MIN = 15          # a box / phone heartbeat this recent = connected

# The proposal the owner decides on (owner_actions/CCTV_PRICING_V3_BN.md).
COMMISSION_PROPOSAL = {
    "approved": False,          # ONLY the owner flips this (never code)
    "pct_of_net": 5,            # of the site's NET monthly Premium AI price
    "months": 12,               # for the first 12 paid months of a site
    # ONLY Premium AI sites: the base plan has 40.9 % worst case — no room
    # for a recurring commission (a 10 % one drops it to 33.5 %); with the
    # proposed 400 Tk/camera AI tier, 5 % keeps 41.3 % (cctv_premium_ai).
    # On base-only sites the installer earns the install fee from the
    # customer, as today.
    "applies_to": "premium_ai",
    "min_paid_months": 1,       # a site counts after its first full paid month
    "trial_counts": False,      # a free-trial month never counts
    "auto_payout": False,       # never — payouts are recorded by a person
}


class PartnerError(ValueError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def new_code():
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))


def normalize_code(v):
    """User input (any case, spaces, dashes, or the whole QR link) -> CODE or ''."""
    s = str(v or "").strip()
    if s.lower().startswith(QR_PREFIX.lower()):
        s = s[len(QR_PREFIX):]
    s = "".join(ch for ch in s.upper() if ch.isalnum())
    if len(s) != CODE_LEN or any(ch not in CODE_ALPHABET for ch in s):
        return ""
    return s


def code_hash(code):
    return hashlib.sha256(("cctv-installer:" + code).encode()).hexdigest()


def qr_payload(code):
    return QR_PREFIX + code


def clean_text(v, n):
    return " ".join(str(v or "").split())[:n]


def clean_apply(name, area):
    name, area = clean_text(name, NAME_MAX), clean_text(area, AREA_MAX)
    if len(name) < 2:
        raise PartnerError("need_name")
    if len(area) < 2:
        raise PartnerError("need_area")
    return name, area


def setup_checklist(facts):
    """facts: {cameras, online, gateway_age_min (None = never), hours (bool),
    zones (int cameras with a zone)} -> ordered steps {key, ok}. Only setup
    facts — this is everything an installer ever sees about a site."""
    cams = int(facts.get("cameras") or 0)
    online = int(facts.get("online") or 0)
    age = facts.get("gateway_age_min")
    steps = [
        ("cameras_added", cams > 0),
        ("cameras_online", cams > 0 and online == cams),
        ("gateway_connected", age is not None and age <= GATEWAY_FRESH_MIN),
        ("hours_set", bool(facts.get("hours"))),
        ("zones_set", cams > 0 and int(facts.get("zones") or 0) >= cams),
    ]
    return [{"key": k, "ok": bool(ok)} for k, ok in steps]


def setup_done(steps):
    return all(s["ok"] for s in steps)


def proposed_commission(net_monthly_bdt, paid_months, in_trial, proposal=None,
                        premium_ai=True):
    """What the PROPOSAL would give for one site this month (taka, rounded
    down). 0 in a trial, before min_paid_months, after `months`, or for a
    site that is not on Premium AI."""
    p = dict(COMMISSION_PROPOSAL, **(proposal or {}))
    if p.get("applies_to") == "premium_ai" and not premium_ai:
        return 0
    try:
        net = float(net_monthly_bdt)
        n = int(paid_months)
    except (TypeError, ValueError):
        return 0
    if in_trial and not p["trial_counts"]:
        return 0
    if n < p["min_paid_months"] or n > p["months"] or net <= 0:
        return 0
    return int(net * p["pct_of_net"] / 100.0)


def margin_after_commission(price_bdt, net_bdt, cost_bdt, commission_bdt):
    """Profit % of the price after the commission — the 40 % rule check."""
    if not price_bdt:
        return 0.0
    return round(100.0 * (net_bdt - cost_bdt - commission_bdt) / price_bdt, 1)
