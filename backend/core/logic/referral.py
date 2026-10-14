"""
referral.py — Assisto "Connected Circle" referral-points logic (Phase M1, item 2).

An inviter earns points when a person they invited (a) INSTALLS the app, (b)
SIGNS UP a real account, and (c) ACCEPTS the relationship invite.  All three
gates must be true — a mere install or a mere signup earns nothing; the reward
fires only on the *accept* of the relationship (the agent that owns the invite
accept flow calls `award_for_accept` at that one point).

Points redeem for Premium days.  The server never grants the plan here — it
returns the number of Premium days the integrator must apply via the existing
plan mechanism (plans.py: extend `user.plan_until`).

This module is PURE Python and deterministic (no DB, no AI key).  State is
passed in / returned as plain dicts and ledger rows so it is unit-testable and
so the DB models + endpoints stay the integrator's job.  The "ledger" is a list
of grant/clawback rows (an audit log); a user's balance is the signed sum of
their rows, so a clawback is itself a logged, reversing row — nothing is ever
silently deleted.

ANTI-ABUSE (all enforced in `can_award`, all tested):
  - reward only a genuinely-active account (active flag),
  - phone-verified when the SMS key exists (a gate flag the integrator passes),
  - ONE reward per real person (per invitee identity) AND per device,
  - a monthly cap on how many rewards one inviter can earn,
  - reject a self-invite (inviter == invitee),
  - reject a duplicate device (a device that already earned a reward),
  - revocable: `clawback` reverses a grant if the invitee is later found fake,
  - every grant and clawback is an audit row.

Run self-tests (no DB):
    python3 -c "import core.logic.referral_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# TUNABLE CONSTANTS  —  OWNER TO REVIEW (clearly marked)
# ---------------------------------------------------------------------------
# !!! RATE / POLICY — OWNER REVIEW REQUIRED !!!
# These are initial, conservative defaults.  The owner sets the final numbers.

# Points the inviter earns per fully-qualified referral (install+signup+accept).
POINTS_PER_REFERRAL = 50  # OWNER REVIEW

# Optional one-time welcome bonus for the INVITEE on their first accepted
# relationship.  Set to 0 to disable.
WELCOME_BONUS_POINTS = 20  # OWNER REVIEW

# Redemption rate: how many points buy ONE Premium day.
# e.g. 25 points/day with 50 points/referral => 1 referral ≈ 2 Premium days.
POINTS_PER_PREMIUM_DAY = 25  # OWNER REVIEW

# Minimum points you may redeem at once (avoids dust redemptions).
MIN_REDEEM_POINTS = POINTS_PER_PREMIUM_DAY  # OWNER REVIEW (>= 1 day)

# How many rewarded referrals one inviter may earn per calendar month.
MONTHLY_REFERRAL_CAP = 20  # OWNER REVIEW

# Max Premium days a single redemption may apply (safety clamp).
MAX_REDEEM_DAYS = 400  # OWNER REVIEW


# ---------------------------------------------------------------------------
# Ledger row kinds + reasons
# ---------------------------------------------------------------------------

KIND_GRANT = "grant"          # positive points to a user
KIND_CLAWBACK = "clawback"    # negative points reversing a prior grant
KIND_REDEEM = "redeem"        # negative points spent for Premium days
KIND_BONUS = "bonus"          # welcome bonus to the invitee

REASON_REFERRAL = "referral_accept"
REASON_WELCOME = "welcome_bonus"
REASON_CLAWBACK_FAKE = "clawback_fake_invitee"
REASON_REDEEM_PREMIUM = "redeem_premium_days"

# Award decision codes (returned by can_award so the caller/UI can explain).
OK = "ok"
ERR_SELF_INVITE = "self_invite"
ERR_INACTIVE = "inviter_inactive"
ERR_INVITEE_INACTIVE = "invitee_inactive"
ERR_NOT_ACCEPTED = "not_accepted"
ERR_NOT_INSTALLED = "not_installed"
ERR_NOT_SIGNED_UP = "not_signed_up"
ERR_PHONE_UNVERIFIED = "phone_unverified"
ERR_DUP_PERSON = "duplicate_person"
ERR_DUP_DEVICE = "duplicate_device"
ERR_MONTHLY_CAP = "monthly_cap_reached"


# ---------------------------------------------------------------------------
# The 3-condition gate  +  anti-abuse
# ---------------------------------------------------------------------------

def _month_key(dt):
    """Calendar-month bucket 'YYYY-MM' for the monthly cap."""
    return f"{dt.year:04d}-{dt.month:02d}"


def can_award(
    inviter_id,
    invitee_id,
    device_id,
    *,
    installed=True,
    signed_up=True,
    accepted=True,
    inviter_active=True,
    invitee_active=True,
    phone_verified=True,
    sms_gate_enabled=False,
    ledger=None,
    now=None,
    monthly_cap=MONTHLY_REFERRAL_CAP,
):
    """Return (ok: bool, code: str).  The single place every anti-abuse rule
    lives.  The caller (the invite-accept flow) passes the current facts; this
    function never mutates anything.

    The 3-condition gate: installed AND signed_up AND accepted.
    `sms_gate_enabled` mirrors "the SMS key exists" — when True we additionally
    require `phone_verified`; when the owner has no SMS yet it is False and the
    phone check is skipped (so M1 can ship without SMS).

    `ledger` is the inviter's audit rows (list of dicts); it is scanned to
    enforce one-reward-per-person, one-reward-per-device and the monthly cap.
    """
    now = now or datetime.now(timezone.utc)
    ledger = ledger or []

    # self-invite
    if inviter_id == invitee_id:
        return False, ERR_SELF_INVITE

    # genuinely-active accounts
    if not inviter_active:
        return False, ERR_INACTIVE
    if not invitee_active:
        return False, ERR_INVITEE_INACTIVE

    # the 3-condition gate (reward only on ACCEPT, not mere install/signup)
    if not installed:
        return False, ERR_NOT_INSTALLED
    if not signed_up:
        return False, ERR_NOT_SIGNED_UP
    if not accepted:
        return False, ERR_NOT_ACCEPTED

    # phone-verified when the SMS key exists
    if sms_gate_enabled and not phone_verified:
        return False, ERR_PHONE_UNVERIFIED

    # one reward per real person (per invitee identity), counting only
    # still-effective referral grants (a clawed-back one frees the slot).
    if _already_rewarded_person(ledger, invitee_id):
        return False, ERR_DUP_PERSON

    # one reward per device (reject duplicate device)
    if device_id and _device_already_rewarded(ledger, device_id):
        return False, ERR_DUP_DEVICE

    # monthly cap on rewarded referrals for this inviter
    mk = _month_key(now)
    earned_this_month = sum(
        1 for r in ledger
        if r.get("kind") == KIND_GRANT
        and r.get("reason") == REASON_REFERRAL
        and r.get("month") == mk
    )
    if earned_this_month >= monthly_cap:
        return False, ERR_MONTHLY_CAP

    return True, OK


def _effective_referral_grants(ledger):
    """Referral grant rows that have NOT been reversed by a clawback.
    A clawback carries `reverses` = the grant id it undoes."""
    clawed = {
        r.get("reverses")
        for r in ledger
        if r.get("kind") == KIND_CLAWBACK and r.get("reverses") is not None
    }
    return [
        r for r in ledger
        if r.get("kind") == KIND_GRANT
        and r.get("reason") == REASON_REFERRAL
        and r.get("id") not in clawed
    ]


def _already_rewarded_person(ledger, invitee_id):
    return any(r.get("invitee_id") == invitee_id
               for r in _effective_referral_grants(ledger))


def _device_already_rewarded(ledger, device_id):
    return any(r.get("device_id") == device_id
               for r in _effective_referral_grants(ledger))


# ---------------------------------------------------------------------------
# Award / welcome bonus / clawback  —  each returns an audit row (dict)
# ---------------------------------------------------------------------------

def _row(kind, user_id, points, reason, *, now, invitee_id=None,
         device_id=None, reverses=None, row_id=None):
    now = now or datetime.now(timezone.utc)
    return {
        "id": row_id,                      # integrator assigns the DB pk
        "kind": kind,
        "user_id": user_id,                # the account whose balance moves
        "points": int(points),             # signed: grants +, clawback/redeem -
        "reason": reason,
        "invitee_id": invitee_id,          # for referral grants (the real person)
        "device_id": device_id,            # device that triggered the grant
        "reverses": reverses,              # grant id a clawback undoes
        "month": _month_key(now),
        "created_at": now.isoformat(),
    }


def award_for_accept(
    inviter_id,
    invitee_id,
    device_id,
    phone_verified,
    *,
    installed=True,
    signed_up=True,
    accepted=True,
    inviter_active=True,
    invitee_active=True,
    sms_gate_enabled=False,
    ledger=None,
    now=None,
    monthly_cap=MONTHLY_REFERRAL_CAP,
    points=POINTS_PER_REFERRAL,
    welcome_bonus=WELCOME_BONUS_POINTS,
    row_id=None,
    bonus_row_id=None,
):
    """Called by the invite-ACCEPT flow (agent A) at the moment the invitee
    accepts the relationship.  Runs every anti-abuse check via `can_award`;
    on success returns:

        {"ok": True, "code": "ok",
         "grant": <row for the inviter>,
         "bonus": <optional welcome-bonus row for the invitee or None>}

    On refusal returns {"ok": False, "code": <ERR_*>, "grant": None,
    "bonus": None} — the caller persists NOTHING.  The integrator writes the
    returned rows to the ReferralGrant ledger and bumps the cached balance.
    """
    now = now or datetime.now(timezone.utc)
    ok, code = can_award(
        inviter_id, invitee_id, device_id,
        installed=installed, signed_up=signed_up, accepted=accepted,
        inviter_active=inviter_active, invitee_active=invitee_active,
        phone_verified=phone_verified, sms_gate_enabled=sms_gate_enabled,
        ledger=ledger, now=now, monthly_cap=monthly_cap,
    )
    if not ok:
        return {"ok": False, "code": code, "grant": None, "bonus": None}

    grant = _row(KIND_GRANT, inviter_id, points, REASON_REFERRAL,
                 now=now, invitee_id=invitee_id, device_id=device_id,
                 row_id=row_id)

    bonus = None
    if welcome_bonus and welcome_bonus > 0:
        bonus = _row(KIND_BONUS, invitee_id, welcome_bonus, REASON_WELCOME,
                     now=now, row_id=bonus_row_id)

    return {"ok": True, "code": OK, "grant": grant, "bonus": bonus}


def clawback(inviter_id, grant_row, *, now=None, row_id=None,
             reason=REASON_CLAWBACK_FAKE):
    """Reverse a referral grant (the invitee was later found fake / removed).
    Returns a negative audit row that reverses `grant_row` by id.  Idempotency
    (don't claw the same grant twice) is the integrator's DB-unique job, but
    `balance`/`history` already treat a clawed grant as neutralized."""
    now = now or datetime.now(timezone.utc)
    pts = int(grant_row.get("points", 0))
    return _row(
        KIND_CLAWBACK, inviter_id, -abs(pts), reason,
        now=now,
        invitee_id=grant_row.get("invitee_id"),
        device_id=grant_row.get("device_id"),
        reverses=grant_row.get("id"),
        row_id=row_id,
    )


# ---------------------------------------------------------------------------
# Balance / history
# ---------------------------------------------------------------------------

def balance(ledger, user_id=None):
    """Signed sum of a user's ledger rows = their spendable points.
    Grants/bonuses add; clawbacks/redeems subtract (already signed).  Clamped
    at 0 (a balance can never show negative)."""
    rows = ledger or []
    if user_id is not None:
        rows = [r for r in rows if r.get("user_id") == user_id]
    total = sum(int(r.get("points", 0)) for r in rows)
    return max(0, total)


def history(ledger, user_id=None, lang="bn"):
    """Newest-first list of localized ledger entries for the Referral screen.
    Each item: {kind, points, reason, label, created_at}."""
    rows = ledger or []
    if user_id is not None:
        rows = [r for r in rows if r.get("user_id") == user_id]
    rows = sorted(rows, key=lambda r: r.get("created_at", ""), reverse=True)
    out = []
    for r in rows:
        out.append({
            "kind": r.get("kind"),
            "points": int(r.get("points", 0)),
            "reason": r.get("reason"),
            "label": reason_label(r.get("reason"), r.get("kind"), lang),
            "created_at": r.get("created_at"),
        })
    return out


def reason_label(reason, kind=None, lang="bn"):
    labels = {
        REASON_REFERRAL: ("রেফারেল পুরস্কার", "Referral reward"),
        REASON_WELCOME: ("স্বাগত বোনাস", "Welcome bonus"),
        REASON_CLAWBACK_FAKE: ("পুরস্কার প্রত্যাহার", "Reward reversed"),
        REASON_REDEEM_PREMIUM: ("প্রিমিয়াম দিনে রূপান্তর", "Redeemed for Premium days"),
    }
    bn, en = labels.get(reason, ("পয়েন্ট", "Points"))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Redemption  —  points -> Premium days
# ---------------------------------------------------------------------------

def points_to_days(points, rate=POINTS_PER_PREMIUM_DAY):
    """Whole Premium days buyable with `points` (floor division)."""
    if rate <= 0:
        return 0
    return int(points) // int(rate)


def days_to_points(days, rate=POINTS_PER_PREMIUM_DAY):
    """Exact points consumed for `days` Premium days."""
    return int(days) * int(rate)


def redeem(user_id, points, ledger, *, now=None, row_id=None,
           rate=POINTS_PER_PREMIUM_DAY, min_points=MIN_REDEEM_POINTS,
           max_days=MAX_REDEEM_DAYS):
    """Convert `points` into Premium days for `user_id`.

    Returns {"ok": bool, "code": str, "days": int, "spent": int,
             "row": <negative audit row or None>}.

    Math: days = floor(points / rate); only whole days are bought and only the
    exact points for those days are spent (any remainder stays in the balance).
    The caller must then apply `days` Premium days via the plan mechanism
    (plans.py — extend user.plan_until); this module does NOT grant the plan.
    """
    now = now or datetime.now(timezone.utc)
    bal = balance(ledger, user_id)
    want = int(points)

    if want < min_points:
        return {"ok": False, "code": "below_minimum", "days": 0, "spent": 0, "row": None}
    if want > bal:
        return {"ok": False, "code": "insufficient_balance", "days": 0, "spent": 0, "row": None}

    days = points_to_days(want, rate)
    if days <= 0:
        return {"ok": False, "code": "below_minimum", "days": 0, "spent": 0, "row": None}
    if days > max_days:
        days = max_days
    spent = days_to_points(days, rate)

    row = _row(KIND_REDEEM, user_id, -spent, REASON_REDEEM_PREMIUM,
               now=now, row_id=row_id)
    return {"ok": True, "code": OK, "days": days, "spent": spent, "row": row}


# ---------------------------------------------------------------------------
# UI summary (for the Referral screen header)  —  bilingual, no plaintext leak
# ---------------------------------------------------------------------------

def referral_summary(ledger, user_id, lang="bn", *, rate=POINTS_PER_PREMIUM_DAY,
                     min_points=MIN_REDEEM_POINTS):
    """Compact dict the balance card renders: points, redeemable days now, the
    rate, and whether a redeem is currently possible."""
    bal = balance(ledger, user_id)
    days = points_to_days(bal, rate)
    return {
        "points": bal,
        "redeemable_days": days,
        "points_per_day": rate,
        "min_redeem": min_points,
        "can_redeem": bal >= min_points and days >= 1,
        "points_label": pick(lang, "পয়েন্ট", "points"),
        "days_label": pick(lang, "প্রিমিয়াম দিন", "Premium days"),
    }


# ---------------------------------------------------------------------------
# ADVANCED (feature #102 → ADVANCED): friends-joined progress, honest invite
# leaderboard, earned-vs-spent audit, redeemed history.
#
# Everything below is still PURE: it derives from the SAME audit ledger, so it
# can NEVER disagree with `balance`/`history`.  No point value is invented — the
# OWNER-REVIEW constants above are the single source of truth and are echoed to
# the client so the UI can render "N friends = M days" from the server, not from
# a hard-coded client number.
# ---------------------------------------------------------------------------

def my_referrals(ledger, user_id):
    """The effective (not-clawed-back) referral grants this inviter earned, i.e.
    the people who genuinely joined via this user.  Sorted newest-first."""
    rows = [r for r in _effective_referral_grants(ledger)
            if r.get("user_id") == user_id]
    return sorted(rows, key=lambda r: r.get("created_at", ""), reverse=True)


def joined_count(ledger, user_id):
    """How many friends have actually joined via this user (honest count — only
    accepted+rewarded invitees; pending/declined invites are NOT counted here
    because they earned no grant row)."""
    return len(my_referrals(ledger, user_id))


def progress(ledger, user_id, *, rate=POINTS_PER_PREMIUM_DAY,
             points=POINTS_PER_REFERRAL, lang="bn"):
    """The 'earn X Premium days by inviting Y friends' progress model.

    All of it is derived from backend constants (never the client):
      - friends_joined         : effective referrals so far
      - points_per_referral    : what one accepted friend is worth (echoed)
      - points_per_day         : the redemption rate (echoed)
      - days_earned_total      : whole Premium days those friends are worth
      - friends_per_day        : friends needed to clear ONE whole Premium day
      - friends_to_next_day    : how many MORE friends until the next whole day
      - progress_to_next_day   : 0..1 fraction toward the next whole day
    """
    joined = joined_count(ledger, user_id)
    earned_points = joined * int(points)
    days_total = points_to_days(earned_points, rate)
    # whole friends needed to buy one day, rounded UP (honest: never undersell)
    friends_per_day = (
        1 if points >= rate
        else -(-int(rate) // max(1, int(points)))  # ceil(rate/points)
    )
    # points still short of the next whole Premium day
    remainder = earned_points - days_total * int(rate)
    short_points = int(rate) - remainder if remainder else int(rate)
    if points <= 0:
        friends_to_next = 0
        frac = 0.0
    else:
        friends_to_next = -(-short_points // int(points))  # ceil
        frac = (int(rate) - short_points) / int(rate) if rate else 0.0
    return {
        "friends_joined": joined,
        "points_per_referral": int(points),
        "points_per_day": int(rate),
        "days_earned_total": days_total,
        "friends_per_day": friends_per_day,
        "friends_to_next_day": max(0, friends_to_next),
        "progress_to_next_day": round(max(0.0, min(1.0, frac)), 4),
        "earned_points_total": earned_points,
    }


def invite_leaderboard(ledger, user_id, *, lang="bn"):
    """Leaderboard of MY invites — who joined via me.

    HONEST / privacy-respecting: one row per invitee who actually joined (earned
    an effective grant).  It carries only the invitee id (the integrator joins it
    to a display name they are ALREADY allowed to show — a Connected-Circle
    relationship exists, so this is not a new PII leak), the points earned, and
    when.  People who were invited but did NOT join have NO row and NO identity
    exposed here — we never surface a non-joiner's details.
    """
    rows = my_referrals(ledger, user_id)
    out = []
    for i, r in enumerate(rows, start=1):
        out.append({
            "rank": i,
            "invitee_id": r.get("invitee_id"),
            "points": int(r.get("points", 0)),
            "month": r.get("month"),
            "created_at": r.get("created_at"),
            "joined_label": pick(lang, "যুক্ত হয়েছেন", "Joined"),
        })
    return out


def audit(ledger, user_id, lang="bn"):
    """Full earned-vs-spent audit for the user, split by category, so the ledger
    the user sees always reconciles to their balance.

    earned = grants + bonuses (positive rows)
    spent  = redeems        (negative, shown as a positive 'spent' figure)
    reversed = clawbacks    (negative, shown as a positive 'reversed' figure)
    balance = earned - spent - reversed  (== `balance()`, by construction)
    """
    rows = [r for r in (ledger or []) if r.get("user_id") == user_id]
    earned = sum(int(r.get("points", 0)) for r in rows
                 if r.get("kind") in (KIND_GRANT, KIND_BONUS))
    spent = -sum(int(r.get("points", 0)) for r in rows
                 if r.get("kind") == KIND_REDEEM)
    reversed_ = -sum(int(r.get("points", 0)) for r in rows
                     if r.get("kind") == KIND_CLAWBACK)
    return {
        "earned_total": earned,
        "spent_total": spent,
        "reversed_total": reversed_,
        "balance": max(0, earned - spent - reversed_),
        "earned_label": pick(lang, "অর্জিত", "Earned"),
        "spent_label": pick(lang, "খরচ", "Spent"),
        "reversed_label": pick(lang, "প্রত্যাহার", "Reversed"),
    }


def redeemed_history(ledger, user_id, lang="bn", *, rate=POINTS_PER_PREMIUM_DAY):
    """Just the redemptions (points → Premium days), newest-first, with the days
    each redemption bought recomputed from the signed points at the live rate."""
    rows = [r for r in (ledger or [])
            if r.get("user_id") == user_id and r.get("kind") == KIND_REDEEM]
    rows = sorted(rows, key=lambda r: r.get("created_at", ""), reverse=True)
    out = []
    for r in rows:
        spent = -int(r.get("points", 0))
        out.append({
            "spent": spent,
            "days": points_to_days(spent, rate),
            "created_at": r.get("created_at"),
            "label": reason_label(REASON_REDEEM_PREMIUM, KIND_REDEEM, lang),
        })
    return out


def advanced_summary(ledger, user_id, lang="bn", *, rate=POINTS_PER_PREMIUM_DAY,
                     min_points=MIN_REDEEM_POINTS, points=POINTS_PER_REFERRAL):
    """One bundle the advanced Referral screen can render from a single call —
    the basic balance summary PLUS the progress model, honest invite
    leaderboard, earned-vs-spent audit and redeemed history.  The integrator may
    merge this into GET /referral/balance (it is a superset of referral_summary)
    or expose it as GET /referral/overview."""
    s = referral_summary(ledger, user_id, lang, rate=rate, min_points=min_points)
    s.update({
        "progress": progress(ledger, user_id, rate=rate, points=points, lang=lang),
        "leaderboard": invite_leaderboard(ledger, user_id, lang=lang),
        "audit": audit(ledger, user_id, lang),
        "redeemed": redeemed_history(ledger, user_id, lang, rate=rate),
    })
    return s
