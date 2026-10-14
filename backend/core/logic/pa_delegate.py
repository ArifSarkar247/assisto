"""
pa_delegate.py — the deterministic, server-enforced trust core behind Assisto's
PA SECRETARY MODE delegate-access feature (issue #111, SPEC v2.1 §14, ADVANCED).

A busy owner can appoint a PA (a "delegate") to act on their behalf. This module
decides, for a given delegate, WHAT they may see or do for the owner — a
granular, role-based SCOPE model with a LEAST-PRIVILEGE default, a confirm gate
when GRANTING a sensitive scope, a forged-client-scope guard, and an append-only
audit-entry builder recording what the delegate actually accessed.

Pure Python, deterministic, no Django, no DB, no network, no clock, **no AI**.
Every function takes plain dicts/values (resolved by the view from the DB) and
returns a decision — so the CLIENT CANNOT SKIP ENFORCEMENT and the functions are
trivially unit-testable. Mirrors the shape/conventions of
core.logic.family_sharing (the per-item consent cousin).

SERVER-SIDE ENFORCEMENT SEAM
----------------------------
The scope set a client SENDS is advisory only. The authoritative grant lives in
the DB (see up_pa3_integration.md → PADelegate.scopes). On every delegate action
the view MUST call `can_access(stored_scopes, scope)` with the scopes it loaded
FROM THE DB for that (owner, delegate) pair — never with a scope list the client
supplied. `can_access` is default-deny: an unknown or sensitive scope that was
never deliberately granted reads as NOT granted, so a forged client scope is
inert. `normalize_scopes` drops anything outside the catalog as defence in depth.

LEAST PRIVILEGE
---------------
`default_scopes()` returns the conservative starting point — a small set of
low-risk, read-only "help me keep up" scopes. Nothing sensitive (private money,
health, documents) is ever in the default and no helper ever auto-grants a
sensitive scope; granting one always routes through `grant_requires_confirm`.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_delegate_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# SCOPE CATALOG
# ===========================================================================
# Each scope is one capability the owner may delegate. `sensitive=True` means
# granting it exposes private information or lets the delegate act with real
# consequence — those always need the confirm gate and are NEVER in the default.
# `write=True` means the scope lets the delegate DO something (not just see).
# The `exposes` string is a key the UI localises into honest "this lets them…"
# copy; the engine never emits prose.

SCOPE_SEE_SCHEDULE = "see_schedule"
SCOPE_VIEW_BRIEFS = "view_briefs"
SCOPE_SEE_TASKS = "see_tasks"
SCOPE_APPROVE_VISITORS = "approve_visitors"
SCOPE_SEND_FOLLOWUPS = "send_followups"
SCOPE_MANAGE_TASKS = "manage_tasks"
SCOPE_VIEW_CONTACTS = "view_contacts"
SCOPE_SEE_MONEY = "see_money"
SCOPE_SEE_HEALTH = "see_health"
SCOPE_SEE_DOCUMENTS = "see_documents"

# Catalog is an ordered tuple of (scope, sensitive, write, exposes-key). Order is
# the display order in the UI (least-risky first). Keep this the single source of
# truth so the UI chips and the server decision can never drift.
SCOPE_CATALOG = (
    # low-risk, read-only — safe defaults
    (SCOPE_SEE_SCHEDULE, False, False, "scope_exposes_schedule"),
    (SCOPE_VIEW_BRIEFS, False, False, "scope_exposes_briefs"),
    (SCOPE_SEE_TASKS, False, False, "scope_exposes_tasks"),
    # act-on-behalf — sensitive because they have outward consequence
    (SCOPE_APPROVE_VISITORS, True, True, "scope_exposes_visitors"),
    (SCOPE_SEND_FOLLOWUPS, True, True, "scope_exposes_followups"),
    (SCOPE_MANAGE_TASKS, True, True, "scope_exposes_manage_tasks"),
    (SCOPE_VIEW_CONTACTS, True, False, "scope_exposes_contacts"),
    # private categories — sensitive, never delegated by default
    (SCOPE_SEE_MONEY, True, False, "scope_exposes_money"),
    (SCOPE_SEE_HEALTH, True, False, "scope_exposes_health"),
    (SCOPE_SEE_DOCUMENTS, True, False, "scope_exposes_documents"),
)

ALL_SCOPES = tuple(s for (s, _sens, _w, _e) in SCOPE_CATALOG)
_SENSITIVE = frozenset(s for (s, sens, _w, _e) in SCOPE_CATALOG if sens)
_WRITE = frozenset(s for (s, _sens, w, _e) in SCOPE_CATALOG if w)
_EXPOSES = {s: e for (s, _sens, _w, e) in SCOPE_CATALOG}

# The conservative least-privilege default: only the read-only "keep up" scopes.
# NOTHING sensitive is ever in here.
_DEFAULT = (SCOPE_SEE_SCHEDULE, SCOPE_VIEW_BRIEFS, SCOPE_SEE_TASKS)


def is_known_scope(scope):
    return scope in _EXPOSES


def is_sensitive(scope):
    return scope in _SENSITIVE


def is_write_scope(scope):
    return scope in _WRITE


def exposes_key(scope):
    """UI-localisation key describing, honestly, what granting the scope exposes.
    Unknown scope → empty string (the UI shows nothing rather than guessing)."""
    return _EXPOSES.get(scope, "")


def scope_meta(scope):
    """Full metadata for one scope (for the UI row). Unknown → None."""
    if scope not in _EXPOSES:
        return None
    return {
        "scope": scope,
        "sensitive": scope in _SENSITIVE,
        "write": scope in _WRITE,
        "exposes": _EXPOSES[scope],
    }


def catalog():
    """The ordered scope catalog the UI renders as toggle rows."""
    return [scope_meta(s) for s in ALL_SCOPES]


# ===========================================================================
# GRANT STATE — least privilege, default deny
# ===========================================================================

def default_scopes():
    """Conservative starting point for a newly appointed delegate: the small set
    of low-risk, read-only scopes only. Returns a fresh set each call."""
    return set(_DEFAULT)


def normalize_scopes(scopes):
    """Coerce an arbitrary iterable into a clean set of KNOWN scopes. Anything
    outside the catalog is dropped (defence in depth against a stale/hostile
    client). Deterministic; never raises."""
    return {s for s in (scopes or []) if s in _EXPOSES}


def set_scope(scopes, scope, on=True):
    """Return updated scopes with `scope` turned on/off. Never mutates the input.
    An unknown scope is a no-op (a buggy/forged client can't inject a capability
    the server doesn't recognise). This records INTENT only — the authoritative
    write still happens in the view against the DB row."""
    out = normalize_scopes(scopes)
    if not is_known_scope(scope):
        return out
    if on:
        out.add(scope)
    else:
        out.discard(scope)
    return out


def can_access(stored_scopes, scope):
    """THE server-side decision. Default-DENY: returns True only when `scope` is
    a KNOWN scope AND is present in the scopes the caller loaded FROM THE DB for
    this (owner, delegate) pair. A forged, unknown, or never-granted scope reads
    as NOT granted. Deterministic; takes no clock and no client input other than
    the scope name being checked."""
    if not is_known_scope(scope):
        return False
    return scope in normalize_scopes(stored_scopes)


def grant_requires_confirm(scope):
    """Whether turning this scope ON must pass the confirm gate first. Sensitive
    scopes always do; low-risk read-only scopes do not. Unknown scope → True
    (fail-safe: force the gate rather than silently allow)."""
    if not is_known_scope(scope):
        return True
    return is_sensitive(scope)


def confirm_grant(scope, confirmed):
    """Resolve a grant attempt through the confirm gate.

    Returns a dict:
        {"allowed": bool, "needs_confirm": bool, "reason": "<key>"}

    - A non-sensitive scope is allowed immediately (needs_confirm False).
    - A sensitive scope is allowed ONLY when `confirmed` is truthy; otherwise it
      is held with needs_confirm True so the UI can raise the gate.
    - An unknown scope is always refused (reason unknown_scope)."""
    if not is_known_scope(scope):
        return {"allowed": False, "needs_confirm": False,
                "reason": "unknown_scope"}
    if not grant_requires_confirm(scope):
        return {"allowed": True, "needs_confirm": False, "reason": "ok"}
    if confirmed:
        return {"allowed": True, "needs_confirm": False,
                "reason": "ok_confirmed"}
    return {"allowed": False, "needs_confirm": True,
            "reason": "confirm_required"}


def apply_grant(stored_scopes, scope, on, confirmed=False):
    """Combine the confirm gate with the state update. Returns:

        {"scopes": set(...), "changed": bool, "gate": <confirm_grant dict>}

    `scopes` is the resulting scope set the view would persist. When the gate
    holds a sensitive grant (needs_confirm), `changed` is False and `scopes` is
    unchanged — the owner must re-send with confirmed=True. Turning a scope OFF
    (on=False) never needs confirmation (removing access is always safe)."""
    current = normalize_scopes(stored_scopes)
    if not is_known_scope(scope):
        return {"scopes": current, "changed": False,
                "gate": {"allowed": False, "needs_confirm": False,
                         "reason": "unknown_scope"}}
    if not on:
        # revoking is always safe and immediate
        nxt = set_scope(current, scope, on=False)
        return {"scopes": nxt, "changed": (nxt != current),
                "gate": {"allowed": True, "needs_confirm": False,
                         "reason": "revoked"}}
    gate = confirm_grant(scope, confirmed)
    if not gate["allowed"]:
        return {"scopes": current, "changed": False, "gate": gate}
    nxt = set_scope(current, scope, on=True)
    return {"scopes": nxt, "changed": (nxt != current), "gate": gate}


# ===========================================================================
# AUDIT — append-only record of what the delegate actually accessed
# ===========================================================================
# The owner can review, honestly, what their PA did on their behalf. We build a
# normalized audit entry from values the caller supplies (the view knows the
# real actor id + timestamp). The engine never invents a time and never hides a
# denial — a blocked access is logged too, so the trail is honest.

AUDIT_ACTIONS = ("viewed", "acted", "granted", "revoked", "denied")


def audit_entry(*, delegate_id, owner_id, scope, action, at,
                detail="", allowed=True):
    """Build one normalized, append-only audit entry.

    Caller supplies the authoritative actor ids, the ISO-8601 `at` timestamp,
    and whether the access was `allowed`. `action` must be one of AUDIT_ACTIONS
    (unknown → coerced to "viewed" so the trail never crashes). Returns a flat
    dict ready to persist / render. Deterministic — no clock here."""
    act = action if action in AUDIT_ACTIONS else "viewed"
    return {
        "delegate_id": int(delegate_id),
        "owner_id": int(owner_id),
        "scope": scope if is_known_scope(scope) else "unknown",
        "action": act,
        "at": str(at),
        "detail": str(detail or ""),
        "allowed": bool(allowed),
        "sensitive": is_sensitive(scope),
    }


def summarize_audit(entries):
    """Deterministic rollup of an audit list for the owner's review header:

        {"total", "denied", "sensitive", "by_action": {action: count}}

    denied counts entries where allowed is False; sensitive counts touches of a
    sensitive scope. Order-independent; safe on an empty list."""
    total = 0
    denied = 0
    sensitive = 0
    by_action = {a: 0 for a in AUDIT_ACTIONS}
    for e in entries or []:
        total += 1
        if not e.get("allowed", True):
            denied += 1
        if e.get("sensitive"):
            sensitive += 1
        a = e.get("action")
        if a in by_action:
            by_action[a] += 1
    return {"total": total, "denied": denied, "sensitive": sensitive,
            "by_action": by_action}
