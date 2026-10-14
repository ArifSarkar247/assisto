"""
msg_moderation.py — Assisto Messenger MODERATION + OWNER-ADMIN (Step 3).

Pure Python, deterministic, NO Django, NO DB, NO AI key.  Every function takes
plain dicts/values (resolved by the view from the DB) and returns a decision or
a new immutable-ish record — it never touches the DB — so enforcement CANNOT be
skipped by the client and every branch is trivially unit-testable.

This module governs PUBLIC surfaces (channels / posts / communities / groups /
people) where unsolicited exposure is possible — distinct from the circle-only
E2E chat, whose contents the server and owner NEVER read.  The guiding owner
rule: when valid complaints arrive, the offending CONTENT is removed (hidden)
and a human admin then reviews to remove / restore / warn / suspend / ban.

THE MODERATION CONTRACT (owner-specified, SERVER-ENFORCED here):

  REPORTING
  - A member reports a target (channel/post/community/group/person) with one or
    more reason categories + optional note.
  - SEVERE categories (child sexual abuse, violent threats, terrorism,
    scams/fraud) => the target is HIDDEN IMMEDIATELY on the FIRST valid report,
    then queued for admin review.  One report is enough — safety first.
  - OTHER categories => normally admin review only; BUT if MANY distinct
    reporters report the same target within a short window (configurable
    threshold), the target is TEMPORARILY AUTO-HIDDEN pending review.  This is a
    separate mechanism from severe-immediate and is explicitly tuned to resist
    mass FALSE reporting (requires DISTINCT reporters, within a window).

  ADMIN STATE MACHINE (human, audit-logged)
    queued -> remove | restore | warn | suspend | ban
    An APPEAL by the affected user re-opens the item (-> under_appeal -> queued).
    Every admin action writes an AUDIT entry (who / what / when / reason).

  LEGAL RETENTION
  - Records of illegal content (severe categories) carry retention flags so the
    owner can meet any legally-required reporting duty.  The ACTUAL legal
    guidance (what/where/how long to report) is === TO REVIEW BY OWNER/LAWYER ===
    — this module only MODELS the retention, it does not give legal advice.

  OWNER ADMIN — USERS
  - The owner/admin may list & search users by PUBLIC fields only and may
    suspend / unsuspend / reset-sessions.  ***CRITICAL PRIVACY GUARD***: the
    admin projection NEVER includes message contents or contact lists.  Those
    fields are stripped here, not in the view, so there is no code path that
    leaks them.  Every admin view and action is audit-logged.

Run self-tests (no DB):
    python3 -c "import core.logic.msg_moderation_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


def _now(now=None):
    return now or datetime.now(timezone.utc)


# ===========================================================================
# REPORT reasons / categories
# ===========================================================================
# Reason codes.  The SEVERE set triggers immediate hide on a single valid
# report.  Everything else is an "other" category (threshold-gated).

R_CSAE = "child_sexual_abuse"      # SEVERE
R_VIOLENT_THREAT = "violent_threat"  # SEVERE
R_TERRORISM = "terrorism"          # SEVERE
R_SCAM_FRAUD = "scam_fraud"        # SEVERE
R_HARASSMENT = "harassment"        # other
R_HATE = "hate_speech"             # other
R_NUDITY = "adult_nudity"          # other (18+ / non-consensual handled by review)
R_SPAM = "spam"                    # other
R_MISINFO = "misinformation"       # other
R_IMPERSONATION = "impersonation"  # other
R_OTHER = "other"                  # other

SEVERE_CATEGORIES = frozenset({R_CSAE, R_VIOLENT_THREAT, R_TERRORISM, R_SCAM_FRAUD})

# Severe categories whose records must be retained for legally-required
# reporting of illegal content.  === legal specifics TO REVIEW BY OWNER/LAWYER.
LEGAL_RETENTION_CATEGORIES = frozenset({R_CSAE, R_TERRORISM, R_VIOLENT_THREAT})

ALL_CATEGORIES = frozenset({
    R_CSAE, R_VIOLENT_THREAT, R_TERRORISM, R_SCAM_FRAUD,
    R_HARASSMENT, R_HATE, R_NUDITY, R_SPAM, R_MISINFO, R_IMPERSONATION, R_OTHER,
})

_CATEGORY_LABELS = {
    R_CSAE: ("শিশু যৌন নির্যাতন", "Child sexual abuse"),
    R_VIOLENT_THREAT: ("সহিংস হুমকি", "Violent threat"),
    R_TERRORISM: ("সন্ত্রাসবাদ", "Terrorism"),
    R_SCAM_FRAUD: ("প্রতারণা / জালিয়াতি", "Scam / fraud"),
    R_HARASSMENT: ("হয়রানি", "Harassment"),
    R_HATE: ("ঘৃণামূলক বক্তব্য", "Hate speech"),
    R_NUDITY: ("প্রাপ্তবয়স্ক নগ্নতা", "Adult nudity"),
    R_SPAM: ("স্প্যাম", "Spam"),
    R_MISINFO: ("ভুল তথ্য", "Misinformation"),
    R_IMPERSONATION: ("ছদ্মবেশ", "Impersonation"),
    R_OTHER: ("অন্যান্য", "Other"),
}


def category_label(code, lang="en"):
    bn, en = _CATEGORY_LABELS.get(code, ("অন্যান্য", "Other"))
    return pick(lang, bn, en)


def is_severe(categories):
    """True if ANY supplied category is severe."""
    return bool(SEVERE_CATEGORIES.intersection(_as_set(categories)))


def requires_legal_retention(categories):
    return bool(LEGAL_RETENTION_CATEGORIES.intersection(_as_set(categories)))


def _as_set(categories):
    if categories is None:
        return set()
    if isinstance(categories, str):
        return {categories}
    return set(categories)


def normalize_categories(categories):
    """Keep only recognised codes; drop blanks/dupes.  Returns a sorted list."""
    valid = {c for c in _as_set(categories) if c in ALL_CATEGORIES}
    return sorted(valid)


# ===========================================================================
# Target kinds
# ===========================================================================

T_CHANNEL = "channel"
T_POST = "post"
T_COMMUNITY = "community"
T_GROUP = "group"
T_PERSON = "person"

TARGET_KINDS = frozenset({T_CHANNEL, T_POST, T_COMMUNITY, T_GROUP, T_PERSON})


# ===========================================================================
# Content status state machine
# ===========================================================================

STATUS_VISIBLE = "visible"
STATUS_HIDDEN = "hidden"            # auto or admin hide; pending review
STATUS_REMOVED = "removed"         # admin confirmed removal (terminal-ish)
STATUS_RESTORED = "restored"       # admin cleared report; back to visible meaning


# ===========================================================================
# Moderation config (ALL tunables passed in; defaults here for convenience)
# ===========================================================================

def default_config():
    return {
        # mass-report auto-hide: >= this many DISTINCT reporters ...
        "mass_report_threshold": 5,
        # ... within this many minutes.
        "mass_report_window_minutes": 60,
        # appeals allowed within this many days of action.
        "appeal_window_days": 30,
    }


# ===========================================================================
# REPORT ingestion -> decision
# ===========================================================================

def build_report(report_id, reporter_id, target_kind, target_id,
                 categories, note="", now=None):
    """Create a normalised report record (pure)."""
    cats = normalize_categories(categories)
    return {
        "id": report_id,
        "reporter_id": reporter_id,
        "target_kind": target_kind,
        "target_id": target_id,
        "categories": cats,
        "note": (note or "").strip(),
        "created_at": _now(now),
        "valid": _is_valid_report(reporter_id, target_kind, target_id, cats),
    }


def _is_valid_report(reporter_id, target_kind, target_id, categories):
    """A report must have a reporter, a known target kind, and >=1 known reason.
    (Self-reports and empty-reason reports are rejected.)"""
    if reporter_id is None:
        return False
    if target_kind not in TARGET_KINDS or target_id is None:
        return False
    if not categories:
        return False
    # A person reporting themselves is not a valid moderation signal.
    if target_kind == T_PERSON and reporter_id == target_id:
        return False
    return True


def distinct_recent_reporters(reports, window_minutes, now=None):
    """Count DISTINCT valid reporters within the window (anti mass-false-report:
    only distinct reporters count, so one person spamming reports counts once)."""
    now = _now(now)
    cutoff = now - timedelta(minutes=window_minutes)
    ids = set()
    for r in reports or []:
        if not r.get("valid"):
            continue
        ca = r.get("created_at")
        if ca is not None and ca < cutoff:
            continue
        ids.add(r.get("reporter_id"))
    return len(ids)


def evaluate_report(new_report, existing_reports, current_status, config=None,
                    now=None):
    """Core decision: given a freshly-built report plus the target's prior
    reports and current status, return what the server should do.

    Returns a dict:
      {
        "accepted": bool,               # was the report itself valid
        "action": "none|hide|queue",    # what to apply to the target
        "new_status": <status or None>, # None means leave as-is
        "severe": bool,
        "reason": "severe_immediate|mass_report|non_severe_review|
                   already_hidden|invalid_report",
        "queue": bool,                  # add/keep a review-queue item
        "legal_retention": bool,
        "distinct_reporters": int,
      }
    """
    config = config or default_config()
    out = {
        "accepted": bool(new_report.get("valid")),
        "action": "none",
        "new_status": None,
        "severe": False,
        "reason": "",
        "queue": False,
        "legal_retention": False,
        "distinct_reporters": 0,
    }

    if not new_report.get("valid"):
        out["reason"] = "invalid_report"
        return out

    cats = new_report.get("categories", [])
    out["severe"] = is_severe(cats)
    out["legal_retention"] = requires_legal_retention(cats)

    # The full picture = prior reports + this one (so distinct count includes it).
    all_reports = list(existing_reports or []) + [new_report]
    out["distinct_reporters"] = distinct_recent_reporters(
        all_reports, config["mass_report_window_minutes"], now=now)

    already_hidden = current_status in (STATUS_HIDDEN, STATUS_REMOVED)

    # SEVERE -> immediate hide on first valid report, then queue for review.
    if out["severe"]:
        out["queue"] = True
        out["reason"] = "severe_immediate"
        if already_hidden:
            # keep hidden; still queue so the new severe report is reviewed.
            out["action"] = "queue"
            out["new_status"] = None
        else:
            out["action"] = "hide"
            out["new_status"] = STATUS_HIDDEN
        return out

    # NON-SEVERE.
    if already_hidden:
        out["action"] = "queue"
        out["queue"] = True
        out["reason"] = "already_hidden"
        return out

    # Mass-report temp auto-hide: distinct reporters within window >= threshold.
    if out["distinct_reporters"] >= config["mass_report_threshold"]:
        out["action"] = "hide"
        out["new_status"] = STATUS_HIDDEN
        out["queue"] = True
        out["reason"] = "mass_report"
        return out

    # Otherwise: plain admin review, content stays visible for now.
    out["action"] = "queue"
    out["queue"] = True
    out["reason"] = "non_severe_review"
    return out


# ===========================================================================
# REVIEW-QUEUE item
# ===========================================================================

Q_QUEUED = "queued"
Q_UNDER_APPEAL = "under_appeal"
Q_RESOLVED = "resolved"


def build_queue_item(item_id, target_kind, target_id, categories,
                     severe, status, now=None):
    return {
        "id": item_id,
        "target_kind": target_kind,
        "target_id": target_id,
        "categories": normalize_categories(categories),
        "severe": bool(severe),
        "content_status": status,          # visible/hidden/removed/restored
        "queue_state": Q_QUEUED,
        "legal_retention": requires_legal_retention(categories),
        "opened_at": _now(now),
        "resolved_at": None,
        "report_count": 1,
        "decision": None,                  # last admin decision code
    }


def bump_queue_item(item, severe=None, categories=None):
    """A further report on an already-queued target: increase count, upgrade
    severe/legal flags, and re-open if it had been resolved."""
    it = dict(item)
    it["report_count"] = int(it.get("report_count", 0)) + 1
    if categories:
        merged = sorted(set(it.get("categories", [])) | set(normalize_categories(categories)))
        it["categories"] = merged
        it["legal_retention"] = it.get("legal_retention") or requires_legal_retention(merged)
    if severe:
        it["severe"] = True
    if it["queue_state"] == Q_RESOLVED:
        it["queue_state"] = Q_QUEUED
        it["resolved_at"] = None
        it["decision"] = None
    return it


# ===========================================================================
# ADMIN actions state machine
# ===========================================================================

A_REMOVE = "remove"
A_RESTORE = "restore"
A_WARN = "warn"
A_SUSPEND = "suspend"
A_BAN = "ban"
A_UNSUSPEND = "unsuspend"
A_RESET_SESSIONS = "reset_sessions"

CONTENT_ACTIONS = frozenset({A_REMOVE, A_RESTORE, A_WARN, A_SUSPEND, A_BAN})

# What each content action does to the target's content_status.
_ACTION_STATUS = {
    A_REMOVE: STATUS_REMOVED,
    A_RESTORE: STATUS_RESTORED,
    A_WARN: None,       # content state unchanged (person warned)
    A_SUSPEND: STATUS_HIDDEN,   # content stays hidden while owner suspended
    A_BAN: STATUS_REMOVED,
}


def apply_admin_action(item, action, admin_id, reason, now=None):
    """Transition a queue item via an admin decision.  Returns (new_item, audit).
    Raises ValueError on an unknown action or a missing reason (reason is
    MANDATORY — it is recorded for the audit log and legal retention)."""
    if action not in CONTENT_ACTIONS:
        raise ValueError(f"unknown admin action: {action}")
    if not (reason or "").strip():
        raise ValueError("admin action requires a reason")

    it = dict(item)
    new_status = _ACTION_STATUS.get(action)
    if new_status is not None:
        it["content_status"] = new_status
    it["queue_state"] = Q_RESOLVED
    it["resolved_at"] = _now(now)
    it["decision"] = action

    audit = build_audit_entry(
        actor_id=admin_id,
        action=action,
        target_kind=it.get("target_kind"),
        target_id=it.get("target_id"),
        reason=reason,
        now=now,
        extra={"queue_item": it.get("id"),
               "legal_retention": it.get("legal_retention", False)},
    )
    return it, audit


# ===========================================================================
# APPEALS
# ===========================================================================

def can_appeal(item, action_time, config=None, now=None):
    """A resolved item may be appealed within the appeal window."""
    config = config or default_config()
    if item.get("queue_state") != Q_RESOLVED:
        return False
    if action_time is None:
        return False
    deadline = action_time + timedelta(days=config["appeal_window_days"])
    return _now(now) <= deadline


def open_appeal(item, appellant_id, reason, now=None):
    """User appeals a resolved decision -> item re-opens for re-review.
    Returns (new_item, audit).  (Caller should have checked can_appeal.)"""
    it = dict(item)
    it["queue_state"] = Q_UNDER_APPEAL
    it["resolved_at"] = None
    audit = build_audit_entry(
        actor_id=appellant_id,
        action="appeal",
        target_kind=it.get("target_kind"),
        target_id=it.get("target_id"),
        reason=reason or "",
        now=now,
        extra={"queue_item": it.get("id")},
    )
    return it, audit


def reopen_for_review(item):
    """Move an appealed item back into the admin queue for a fresh decision."""
    it = dict(item)
    if it.get("queue_state") == Q_UNDER_APPEAL:
        it["queue_state"] = Q_QUEUED
    return it


# ===========================================================================
# AUDIT LOG
# ===========================================================================

def build_audit_entry(actor_id, action, target_kind, target_id, reason,
                      now=None, extra=None):
    """Immutable record of WHO did WHAT, WHEN, and WHY.  Append-only; retained
    for legally-required reporting of illegal content where flagged."""
    entry = {
        "actor_id": actor_id,          # admin / owner / appellant
        "action": action,
        "target_kind": target_kind,
        "target_id": target_id,
        "reason": (reason or "").strip(),
        "at": _now(now),
    }
    if extra:
        entry.update(extra)
    return entry


# ===========================================================================
# OWNER ADMIN — USERS projection + actions
# ===========================================================================
# The PUBLIC fields an admin is allowed to see.  Anything NOT in this set is
# never exposed.  Message contents and contact lists are DELIBERATELY absent.

ADMIN_USER_PUBLIC_FIELDS = (
    "id",
    "name",
    "phone",
    "photo_url",
    "signup_date",
    "plan",
    "last_active",
    "app_version",
    "report_count",
    "status",          # active / suspended / banned
)

# Fields that must NEVER appear in an admin projection, no matter what the raw
# user record contains.  This is the privacy GUARD — enforced here, centrally.
ADMIN_FORBIDDEN_FIELDS = frozenset({
    "messages", "message", "message_contents", "chats", "chat_history",
    "contacts", "contact_list", "contact_ids", "address_book",
    "e2e_keys", "private_key", "password", "password_hash", "ciphertext",
    "message_bodies",
})


def admin_user_projection(user):
    """Return ONLY the allowed public fields for admin display.

    GUARD: message contents and contact lists are NEVER included.  We build the
    output from an allow-list (not by deleting from the source), so even if the
    raw record grows new private fields later, they can never leak through here.
    """
    out = {f: user.get(f) for f in ADMIN_USER_PUBLIC_FIELDS}
    # Defensive double-check: assert no forbidden field slipped in via the
    # allow-list (it can't, but we prove it so a test can rely on it).
    assert not (ADMIN_FORBIDDEN_FIELDS & set(out.keys())), \
        "admin projection must never contain message contents or contacts"
    return out


def list_users_for_admin(users, query=None, status=None, limit=None):
    """List/search users by PUBLIC fields only.  `query` matches name or phone
    (case-insensitive substring).  Returns a list of safe projections."""
    q = (query or "").strip().lower()
    rows = []
    for u in users or []:
        if status is not None and u.get("status") != status:
            continue
        if q:
            name = str(u.get("name") or "").lower()
            phone = str(u.get("phone") or "").lower()
            if q not in name and q not in phone:
                continue
        rows.append(admin_user_projection(u))
        if limit is not None and len(rows) >= limit:
            break
    return rows


# User account statuses (admin-managed).
U_ACTIVE = "active"
U_SUSPENDED = "suspended"
U_BANNED = "banned"


def admin_user_action(user_status, action, admin_id, target_user_id, reason,
                      now=None):
    """Suspend / unsuspend / reset-sessions (and ban via content machine).
    Returns (new_status, reset_sessions, audit).  Reason is MANDATORY and the
    action is audit-logged."""
    if not (reason or "").strip():
        raise ValueError("admin user action requires a reason")

    reset_sessions = False
    new_status = user_status

    if action == A_SUSPEND:
        new_status = U_SUSPENDED
        reset_sessions = True          # suspended users are logged out
    elif action == A_UNSUSPEND:
        new_status = U_ACTIVE
    elif action == A_BAN:
        new_status = U_BANNED
        reset_sessions = True
    elif action == A_RESET_SESSIONS:
        reset_sessions = True
    else:
        raise ValueError(f"unknown admin user action: {action}")

    audit = build_audit_entry(
        actor_id=admin_id,
        action=action,
        target_kind=T_PERSON,
        target_id=target_user_id,
        reason=reason,
        now=now,
        extra={"new_status": new_status, "reset_sessions": reset_sessions},
    )
    return new_status, reset_sessions, audit


# ===========================================================================
# Labels (bilingual) for the admin panel
# ===========================================================================

_ACTION_LABELS = {
    A_REMOVE: ("সরান", "Remove"),
    A_RESTORE: ("পুনরুদ্ধার", "Restore"),
    A_WARN: ("সতর্ক করুন", "Warn"),
    A_SUSPEND: ("স্থগিত", "Suspend"),
    A_BAN: ("নিষিদ্ধ", "Ban"),
    A_UNSUSPEND: ("স্থগিতাদেশ তুলুন", "Unsuspend"),
    A_RESET_SESSIONS: ("সেশন রিসেট", "Reset sessions"),
}

_STATUS_LABELS = {
    STATUS_VISIBLE: ("দৃশ্যমান", "Visible"),
    STATUS_HIDDEN: ("লুকানো", "Hidden"),
    STATUS_REMOVED: ("অপসারিত", "Removed"),
    STATUS_RESTORED: ("পুনরুদ্ধারকৃত", "Restored"),
    U_ACTIVE: ("সক্রিয়", "Active"),
    U_SUSPENDED: ("স্থগিত", "Suspended"),
    U_BANNED: ("নিষিদ্ধ", "Banned"),
}


def action_label(code, lang="en"):
    bn, en = _ACTION_LABELS.get(code, ("", code))
    return pick(lang, bn, en)


def status_label(code, lang="en"):
    bn, en = _STATUS_LABELS.get(code, ("", code))
    return pick(lang, bn, en)
