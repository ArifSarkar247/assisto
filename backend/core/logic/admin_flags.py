"""
admin_flags.py — the PURE, deterministic engine behind Assisto's COST
KILL-SWITCH & FEATURE-FLAGS admin surface (issue #178, SPEC v2.1 §21, ADVANCED).

The owner/superuser gets one console to see every operational flag — the
cost-sensitive "kill switches" (anything that spends money: AI calls, SMS/push
fan-out, cloud media processing, maps/geocoding) plus plain feature toggles —
and flip them with a CONFIRM GATE in front of anything that affects cost or
disables a user-facing feature, backed by an append-only AUDIT TRAIL of
who-flipped-what-when-and-why.

This module is PURE, exactly like `social.py` / `family_sharing.py`: no Django,
no DB, no network, no clock, no AI. It is the SINGLE SOURCE OF TRUTH for:

  * the canonical flag CATALOG (id, group, cost/feature classification, the
    default value, and whether flipping it needs a typed confirm),
  * flip VALIDATION (unknown flag, no-op, missing reason when confirm is
    required, bad value type),
  * the CONFIRM-GATE decision (does this flip need the owner to confirm?),
  * APPLYING a flip to a state dict (returns the new state + an audit entry),
  * building append-only AUDIT entries (who / what / old→new / when / why).

Because it is deterministic, the on-device Dart mirror classifies a flip
identically (so the confirm dialog fires for the same flips offline) and the
tests can pin every outcome. The server stays the authority: the Dart side only
*predicts* the confirm requirement for UX; the backend re-validates on write.

NEVER HOLDS MONEY / NEVER SERVER-SIDE PRICING
---------------------------------------------
A kill switch only turns a *capability* on/off (e.g. "AI drafting enabled").
Min-price / commission / any pricing math stays elsewhere and server-side; this
engine never computes a price and never moves money. Turning a cost switch OFF
is the safe direction (spend nothing); turning it ON is the one that can cost
money, which is exactly why ON needs the confirm gate.
"""

# --------------------------------------------------------------- classification
# A flag is one of two KINDS:
#   * "cost"    — flipping it changes money spend (external paid APIs / fan-out).
#   * "feature" — flipping it enables/disables a user-facing capability.
# plus a GROUP for display ordering. The `confirm` policy below decides when a
# flip needs the owner to type a reason + confirm.

KIND_COST = "cost"
KIND_FEATURE = "feature"
KINDS = (KIND_COST, KIND_FEATURE)

# Canonical catalog. `default` is the shipped-on value. `confirm_on` lists the
# directions that require a confirm gate:
#   * cost switches: confirming is required when turning ON (it can spend) AND
#     when turning OFF a switch that disables a running paid capability — we
#     require confirm BOTH ways for cost flags because either direction has an
#     operational blast radius (turning a cost switch off can break a feature
#     users rely on; turning it on can spend). So cost → confirm always.
#   * feature switches: confirm only when DISABLING (turning a feature OFF for
#     everyone is the destructive direction). Turning a feature back ON is safe.
#
# Values are plain bools. Everything the UI shows is localized by key; this
# engine never emits user prose — only stable ids/kinds/groups.

CATALOG = (
    # id, kind, group, default
    ("ai_drafting", KIND_COST, "ai", True),
    ("ai_inbox_summary", KIND_COST, "ai", True),
    ("ai_scam_check", KIND_COST, "ai", True),
    ("sms_fanout", KIND_COST, "messaging", True),
    ("push_fanout", KIND_COST, "messaging", True),
    ("cloud_photo_enhance", KIND_COST, "media", True),
    ("maps_geocoding", KIND_COST, "location", True),
    ("messenger_public", KIND_FEATURE, "features", True),
    ("business_crm", KIND_FEATURE, "features", True),
    ("family_sharing", KIND_FEATURE, "features", True),
    ("new_signups", KIND_FEATURE, "ops", True),
    # Business Model Build 2 — owner kill-switches for monetization abuse.
    ("topups_enabled", KIND_FEATURE, "monetization", True),
    ("ads_rewarded", KIND_FEATURE, "monetization", True),
    # a6: app-open ad kill-switch (still needs AdMob configured; never shown to
    # Premium/Business, never on safety/payment/login/call screens).
    ("ads_app_open", KIND_FEATURE, "monetization", True),
    # h1-home: the large native-ad hero on home (free plan only; replaces the
    # logo block, never overlaps content; no fill -> normal logo block).
    ("ads_home_hero", KIND_FEATURE, "monetization", True),
    # h1-home: the hero's video starts MUTED (AdMob VideoOptions startMuted)
    # with a visible speaker control. Default ON = never autoplay with sound.
    ("ads_hero_start_muted", KIND_FEATURE, "monetization", True),
    # o1-otp: launch gate. ON = password-only sign-up still allowed (test
    # builds / today). Turn OFF at public launch -> sign-up REQUIRES an
    # OTP-verified phone. Existing users' password login is never affected.
    ("auth_password_only_signup", KIND_FEATURE, "ops", True),
    # c1-contacts: discoverability gate. ON (test builds) = any registered
    # account with a phone can be found by contacts match / number search.
    # Turn OFF before public launch -> only OTP-verified numbers are found.
    ("contacts_match_unverified", KIND_FEATURE, "ops", True),
)

_BY_ID = {row[0]: row for row in CATALOG}
FLAG_IDS = tuple(row[0] for row in CATALOG)
GROUPS = tuple(dict.fromkeys(row[2] for row in CATALOG))  # ordered-unique


def catalog():
    """The full catalog as a list of dicts (id/kind/group/default/is_cost)."""
    return [
        {
            "id": fid,
            "kind": kind,
            "group": group,
            "default": default,
            "is_cost": kind == KIND_COST,
        }
        for (fid, kind, group, default) in CATALOG
    ]


def is_known(flag_id):
    return flag_id in _BY_ID


def kind_of(flag_id):
    return _BY_ID[flag_id][1] if flag_id in _BY_ID else None


def default_of(flag_id):
    return _BY_ID[flag_id][3] if flag_id in _BY_ID else None


def default_state():
    """The shipped default value for every known flag."""
    return {fid: default for (fid, _k, _g, default) in CATALOG}


def normalize_state(raw):
    """Project an arbitrary dict onto the known flags, filling defaults for any
    missing flag and dropping unknown keys. Non-bool values coerce via bool()
    only for the known truthy/falsy forms we accept (True/False/1/0)."""
    raw = raw or {}
    out = {}
    for (fid, _k, _g, default) in CATALOG:
        if fid in raw:
            v = raw[fid]
            out[fid] = _as_bool(v, default)
        else:
            out[fid] = default
    return out


def _as_bool(v, fallback):
    if isinstance(v, bool):
        return v
    if v in (1, 0):
        return bool(v)
    if isinstance(v, str) and v.lower() in ("true", "false", "1", "0"):
        return v.lower() in ("true", "1")
    return fallback


# --------------------------------------------------------------- confirm gate

def needs_confirm(flag_id, new_value):
    """Does flipping `flag_id` to `new_value` require a typed-reason confirm?

    * cost flags: ALWAYS (both directions have a cost/operational blast radius).
    * feature flags: only when DISABLING (new_value is False).

    Returns False for an unknown flag (the validator rejects it separately).
    """
    if flag_id not in _BY_ID:
        return False
    kind = _BY_ID[flag_id][1]
    if kind == KIND_COST:
        return True
    # feature: confirm only when turning OFF
    return new_value is False


def confirm_reason_code(flag_id, new_value):
    """A stable reason-code the UI can map to localized confirm copy. One of:
    'enable_cost' | 'disable_cost' | 'disable_feature' | '' (no confirm)."""
    if not needs_confirm(flag_id, new_value):
        return ""
    if _BY_ID[flag_id][1] == KIND_COST:
        return "enable_cost" if new_value else "disable_cost"
    return "disable_feature"


# --------------------------------------------------------------- validation

def validate_flip(flag_id, new_value, current_value, reason):
    """Return a list of problem codes for a requested flip; empty == OK.

    Codes: 'unknown_flag', 'bad_value', 'no_op', 'reason_required'.
    """
    problems = []
    if not is_known(flag_id):
        problems.append("unknown_flag")
        return problems  # nothing else is meaningful
    if not isinstance(new_value, bool):
        problems.append("bad_value")
        return problems
    if current_value is not None and bool(current_value) == new_value:
        problems.append("no_op")
    if needs_confirm(flag_id, new_value) and not (reason or "").strip():
        problems.append("reason_required")
    return problems


# --------------------------------------------------------------- apply + audit

def make_audit_entry(flag_id, old_value, new_value, actor, reason, at_iso):
    """Build ONE append-only audit entry. Caller supplies the timestamp (ISO
    string) and actor id/label — the engine never reads a clock or identity."""
    return {
        "flag": flag_id,
        "kind": kind_of(flag_id),
        "old": bool(old_value) if old_value is not None else None,
        "new": bool(new_value),
        "actor": actor,
        "reason": (reason or "").strip(),
        "at": at_iso,
        "confirm_code": confirm_reason_code(flag_id, new_value),
    }


def apply_flip(state, flag_id, new_value, actor, reason, at_iso):
    """Validate + apply a flip to a (normalized) state dict.

    Returns {"ok", "problems", "state", "audit"}:
      * on failure: ok=False, problems=[...], state unchanged, audit=None.
      * on success: ok=True, problems=[], state=NEW dict, audit=entry.

    Pure: `state` is never mutated in place — a new dict is returned.
    """
    state = normalize_state(state)
    old = state.get(flag_id)
    problems = validate_flip(flag_id, new_value, old, reason)
    if problems:
        return {"ok": False, "problems": problems, "state": state, "audit": None}
    new_state = dict(state)
    new_state[flag_id] = new_value
    entry = make_audit_entry(flag_id, old, new_value, actor, reason, at_iso)
    return {"ok": True, "problems": [], "state": new_state, "audit": entry}


def summarize(state):
    """A tiny honest summary for the console header: how many cost switches are
    ON (spending), how many features are disabled, total known flags."""
    state = normalize_state(state)
    cost_on = sum(
        1 for (fid, k, _g, _d) in CATALOG if k == KIND_COST and state[fid]
    )
    cost_total = sum(1 for (_f, k, _g, _d) in CATALOG if k == KIND_COST)
    feat_off = sum(
        1 for (fid, k, _g, _d) in CATALOG if k == KIND_FEATURE and not state[fid]
    )
    feat_total = sum(1 for (_f, k, _g, _d) in CATALOG if k == KIND_FEATURE)
    return {
        "cost_on": cost_on,
        "cost_total": cost_total,
        "features_off": feat_off,
        "features_total": feat_total,
        "total": len(CATALOG),
    }
