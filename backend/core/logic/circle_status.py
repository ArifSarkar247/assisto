"""
circle_status.py — Assisto "Connected Circle" STATUS / STORIES (M2 item 8).

Pure Python, deterministic, no DB, no AI key.  These are the SERVER-ENFORCED
decision functions for 24-hour status/stories; the integrator wires each into
the relevant view so a client CANNOT skip enforcement.  Benchmarked against
WhatsApp Status + Messenger Stories.

THE STATUS CONTRACT (owner-specified, enforced here — safe defaults):
  - A status is a photo / video / text post that AUTO-EXPIRES after 24 hours.
  - Visibility control, resolved per-viewer SERVER-SIDE: my whole circle /
    family only / only chosen people / everyone-except some.  Block always wins
    (a blocked person never sees your status); a muted author's status is hidden
    from the muter's tray.
  - Viewer list: who saw it (the author may see this; but a viewer who turned
    read-receipts OFF is NOT recorded as a named viewer — the WhatsApp rule).
  - Reply privately -> opens a normal 1:1 E2E chat message (handled by the
    existing circle message relay; here we only build the envelope link).
  - Mute someone's status: their posts stay out of your tray without unfriending
    or notifying them.
  - E2E / ciphertext-only on the server: a TEXT status is inline ciphertext
    (works now via the software-fallback E2E); a PHOTO/VIDEO status is blob-ref
    + ciphertext metadata and is KEY-GATED exactly like M1 media — until the
    encrypted blob bucket is provisioned the UI shows "Available when encrypted
    media storage is enabled" (status_media_available() == False).
  - Auto-cleanup: expired statuses are purged (ciphertext + any blob), honouring
    the same disk floor as M1 media so cleanup never risks fresh data.

The VISIBILITY vocabulary intentionally MIRRORS circle_privacy's audience
concepts (everyone / family / chosen) but is DEFINED LOCALLY here so this module
does not import or edit circle_privacy.py.  INTEGRATOR LINK: the per-field
`status` visibility policy in circle_privacy.default_visibility() ("status" ->
everyone/family/nobody) is the author's DEFAULT audience; this module's
per-post `visibility` object OVERRIDES it per status.  Keep the family relation
set in sync with circle_privacy._FAMILY_RELATIONS / circle.CLOSE_FAMILY.

All functions take plain dicts/values (resolved by the view from the DB) and
return a decision — never touching the DB — so they are trivially unit-testable
and cannot be short-circuited by the client.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_status_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.circle import (
    FORBIDDEN_META_KEYS,
    media_available,
    pick,
)


# ---------------------------------------------------------------------------
# Status kinds + lifetime
# ---------------------------------------------------------------------------

STATUS_TEXT = "text"
STATUS_PHOTO = "photo"
STATUS_VIDEO = "video"
STATUS_KINDS = (STATUS_TEXT, STATUS_PHOTO, STATUS_VIDEO)

# WhatsApp Status / Messenger Stories both expire in 24 hours.
STATUS_TTL_HOURS = 24

# Caption length cap for a TEXT status (the text itself is ciphertext; this is a
# sanity cap on the pre-encryption length the sender enforces).
TEXT_STATUS_MAX_CHARS = 700


def status_ttl():
    return timedelta(hours=STATUS_TTL_HOURS)


# ---------------------------------------------------------------------------
# Key-gating: text works now, photo/video gated like M1 media
# ---------------------------------------------------------------------------
# Reuse circle.media_available as the single source of truth so a status photo
# unlocks the moment the encrypted blob bucket is provisioned — one config flip.

def status_media_available(kind):
    """True if this status kind can be posted now.  Text is always available
    (software-fallback E2E); photo/video follow the M1 media gate."""
    if kind == STATUS_TEXT:
        return True
    if kind in (STATUS_PHOTO, STATUS_VIDEO):
        return media_available(kind)
    return False


def status_gate_reason(kind, lang="bn"):
    """None if the kind can be posted now; else a localized 'Available when ___'
    reason (mirrors the M1 media gate copy)."""
    if status_media_available(kind):
        return None
    reasons = {
        STATUS_PHOTO: ("এনক্রিপ্টেড স্টোরেজ চালু হলে ছবির স্ট্যাটাস দেওয়া যাবে।",
                       "Photo status available when encrypted media storage is enabled."),
        STATUS_VIDEO: ("এনক্রিপ্টেড স্টোরেজ চালু হলে ভিডিও স্ট্যাটাস দেওয়া যাবে।",
                       "Video status available when encrypted media storage is enabled."),
    }
    bn, en = reasons.get(kind, ("শীঘ্রই আসছে।", "Coming soon."))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Lifecycle: create / expiry
# ---------------------------------------------------------------------------

def expiry_for(created_at=None):
    """The UTC moment a status posted at `created_at` auto-expires (24h)."""
    created = _as_dt(created_at) or datetime.now(timezone.utc)
    return created + status_ttl()


def is_expired(status, now=None):
    """True if the status is past its 24-hour life.  `status` carries either an
    explicit `expires_at` or a `created_at` we derive expiry from."""
    now = now or datetime.now(timezone.utc)
    exp = _as_dt((status or {}).get("expires_at"))
    if exp is None:
        exp = expiry_for((status or {}).get("created_at"))
    return now >= exp


def is_active(status, now=None):
    return not is_expired(status, now=now)


def seconds_remaining(status, now=None):
    """Whole seconds until expiry (0 once expired) — for the ring countdown."""
    now = now or datetime.now(timezone.utc)
    exp = _as_dt((status or {}).get("expires_at")) or expiry_for(
        (status or {}).get("created_at"))
    return max(0, int((exp - now).total_seconds()))


# ---------------------------------------------------------------------------
# Visibility — the per-post audience resolver (SERVER-ENFORCED)
# ---------------------------------------------------------------------------
# Audience modes mirror circle_privacy's vocabulary but are defined locally.
#   everyone  -> every member of my circle
#   family    -> close-family relations only
#   chosen    -> ONLY the listed member ids (allowlist)
#   except    -> everyone in my circle EXCEPT the listed member ids (excludelist)
# Block ALWAYS overrides (a blocked viewer never sees a status); a viewer who
# muted the author simply doesn't see it in their tray (enforced client-side via
# `muted` but we also exclude them from push fan-out server-side).

AUD_EVERYONE = "everyone"
AUD_FAMILY = "family"
AUD_CHOSEN = "chosen"      # allowlist of member ids
AUD_EXCEPT = "except"      # everyone minus an excludelist of member ids
AUD_MODES = (AUD_EVERYONE, AUD_FAMILY, AUD_CHOSEN, AUD_EXCEPT)

# Close-family relation codes — kept local (mirror circle.CLOSE_FAMILY /
# circle_privacy._FAMILY_RELATIONS) so there is no import cycle / cross-edit.
_FAMILY_RELATIONS = {"father", "mother", "child", "parent", "husband", "wife",
                     "spouse", "brother", "sister", "sibling"}


def is_family_relation(code):
    return (code or "").strip().lower() in _FAMILY_RELATIONS


def default_visibility():
    """Safe default audience for a new status: the whole circle (all contacts
    are already consented family/friends).  The author may tighten per post."""
    return {"mode": AUD_EVERYONE, "allow_ids": [], "except_ids": []}


def normalize_visibility(vis):
    """Coerce an arbitrary dict into a clean {mode, allow_ids, except_ids}."""
    vis = vis or {}
    mode = str(vis.get("mode", AUD_EVERYONE))
    if mode not in AUD_MODES:
        mode = AUD_EVERYONE
    return {
        "mode": mode,
        "allow_ids": sorted({int(x) for x in (vis.get("allow_ids") or []) if _is_int(x)}),
        "except_ids": sorted({int(x) for x in (vis.get("except_ids") or []) if _is_int(x)}),
    }


def can_view_status(author, viewer, visibility, now=None, status=None):
    """THE per-viewer decision.  Returns True iff `viewer` may see this status.

    SERVER-ENFORCED: the status list/fetch view calls this for every candidate
    viewer so a hidden status is never serialized to them, and the push fan-out
    skips them.

    `author`  dict: {id, blocked (ids author blocked), blocked_by (ids who
                     blocked author)}
    `viewer`  dict: {id, relation (viewer's relation code TO the author),
                     muted_authors (ids the viewer muted)}
    `visibility` dict: the per-post {mode, allow_ids, except_ids}.
    `status`  (optional) dict with created_at/expires_at — an expired status is
              visible to NOBODY (defence in depth; the view also filters).
    """
    author = author or {}
    viewer = viewer or {}
    vid = viewer.get("id")

    # The author never needs this gate for their own post, but be explicit:
    if vid is not None and vid == author.get("id"):
        return True

    # Expired -> nobody.
    if status is not None and is_expired(status, now=now):
        return False

    # Block always wins (either direction).
    if vid in set(author.get("blocked") or []) or vid in set(author.get("blocked_by") or []):
        return False

    # Viewer muted this author -> keep out of their tray / fan-out.
    if author.get("id") in set(viewer.get("muted_authors") or []):
        return False

    v = normalize_visibility(visibility)
    mode = v["mode"]
    if mode == AUD_EVERYONE:
        return True
    if mode == AUD_FAMILY:
        return is_family_relation(viewer.get("relation"))
    if mode == AUD_CHOSEN:
        return vid in set(v["allow_ids"])
    if mode == AUD_EXCEPT:
        return vid not in set(v["except_ids"])
    return False


def audience_ids(author, candidates, visibility, now=None, status=None):
    """Resolve the concrete set of member ids who may see this status, given the
    author's full circle `candidates` (list of viewer dicts).  Used for push
    fan-out and for the "N people can see this" hint."""
    return [c.get("id") for c in (candidates or [])
            if can_view_status(author, c, visibility, now=now, status=status)]


# ---------------------------------------------------------------------------
# Viewer list ("seen by") — respects reciprocal read-receipts
# ---------------------------------------------------------------------------
# WhatsApp rule: if the VIEWER turned read-receipts off, the author does not see
# that they viewed it (and reciprocally the viewer can't see others' view-lists,
# but that's the author's screen only).  A view is recorded once per viewer.

def record_view(views, viewer_id, at=None, viewer_read_receipts=True):
    """Append/refresh a view record.  `views` is a list of {viewer, at,
    anonymous}.  If the viewer has read-receipts OFF we still COUNT the view
    (for the number) but mark it anonymous so the author can't name them.
    Returns the updated list (does not mutate the input)."""
    at = _as_dt(at) or datetime.now(timezone.utc)
    out = []
    seen = False
    for v in (views or []):
        if v.get("viewer") == viewer_id:
            seen = True
            # keep earliest 'at'; only relax anonymity, never tighten it.
            rec = dict(v)
            rec["anonymous"] = rec.get("anonymous", False) or (not viewer_read_receipts)
            out.append(rec)
        else:
            out.append(dict(v))
    if not seen:
        out.append({
            "viewer": viewer_id,
            "at": at.isoformat(),
            "anonymous": not bool(viewer_read_receipts),
        })
    return out


def viewer_count(views):
    """Total number of distinct viewers (named + anonymous)."""
    return len({v.get("viewer") for v in (views or []) if v.get("viewer") is not None})


def named_viewers(views):
    """The subset the author may SEE as names (read-receipts ON).  Anonymous
    views still contribute to viewer_count but are omitted here."""
    return [v for v in (views or []) if not v.get("anonymous")]


def viewer_summary(views, lang="bn"):
    """A localized one-line summary for the author: total seen + anonymous note."""
    total = viewer_count(views)
    named = len(named_viewers(views))
    anon = total - named
    if total == 0:
        return pick(lang, "এখনও কেউ দেখেনি।", "No views yet.")
    base = pick(lang, f"{total} জন দেখেছেন।", f"Seen by {total}.")
    if anon > 0:
        base += " " + pick(lang,
                            f"({anon} জন রিসিট বন্ধ রেখেছেন।)",
                            f"({anon} with receipts off.)")
    return base


# ---------------------------------------------------------------------------
# Reply privately -> a normal 1:1 E2E chat message
# ---------------------------------------------------------------------------
# A status reply is NOT stored on the status; it becomes an ordinary circle
# message to the author, carrying a small CLEARTEXT-SAFE reference to the status
# it answers (status id + kind only — never the status content).  The actual
# reply text is ciphertext produced on the sender's device.

def build_status_reply_envelope(status_id, status_kind, sender_id, author_id,
                                ciphertext, nonce, scheme, sender_key_id):
    """Assemble the relay envelope for a private status reply.  The `reply_to`
    block is routing metadata only (which status); the reply body is ciphertext.
    The integrator feeds the returned dict through circle.validate_envelope (it
    will pass — no forbidden keys) and into the normal message relay."""
    env = {
        "content_type": "text",
        "recipient_ids": [int(author_id)],
        "sender_id": int(sender_id),
        "ciphertext": ciphertext,
        "nonce": nonce,
        "scheme": scheme,
        "sender_key_id": sender_key_id,
        # routing-only reference to the status being answered:
        "reply_to_status": {
            "status_id": status_id,
            "kind": status_kind if status_kind in STATUS_KINDS else STATUS_TEXT,
        },
    }
    # Defence in depth: never let a readable field ride along.
    bad = FORBIDDEN_META_KEYS & set(env.keys())
    if bad:
        raise ValueError("refusing readable field(s) on status reply: "
                         + ",".join(sorted(bad)))
    return env


# ---------------------------------------------------------------------------
# Mute an author's status
# ---------------------------------------------------------------------------
# Muting hides someone's status from your tray without unfriending/notifying.
# Stored per-viewer as a set of author ids.

def apply_status_mute(muted_set, author_id, on=True):
    """Return the updated set of muted author ids."""
    s = set(muted_set or [])
    if on:
        s.add(author_id)
    else:
        s.discard(author_id)
    return s


def is_status_muted(muted_set, author_id):
    return author_id in set(muted_set or [])


# ---------------------------------------------------------------------------
# Status content envelope — ciphertext-only (text inline, photo/video blob-ref)
# ---------------------------------------------------------------------------
# Mirrors circle.validate_envelope / circle_media.validate_blob_meta so the
# server stores CIPHERTEXT ONLY for a status too.

STATUS_ALLOWED_META = {
    "kind", "created_at", "expires_at", "visibility",
    # text status: inline ciphertext
    "ciphertext", "nonce", "scheme", "sender_key_id",
    # photo/video status: opaque blob + ciphertext metadata (see circle_media)
    "blob_ref", "byte_size", "quality", "duration_sec", "width", "height",
    "mime_hint", "thumb_ciphertext", "thumb_nonce",
    "caption_ciphertext", "caption_nonce", "sha256_ct",
}
# A readable caption / the plaintext would be a leak — reject outright.
STATUS_FORBIDDEN_META = FORBIDDEN_META_KEYS | {"filename", "address", "url", "note"}


def validate_status_meta(meta):
    """Return (ok, reason).  Proves a status payload is relay-safe:
      - declares a known kind,
      - TEXT carries inline ciphertext+nonce; PHOTO/VIDEO carry a blob_ref,
      - contains NO forbidden plaintext/secret keys,
      - carries no disallowed key.
    The post view calls this before persisting — the server's guarantee that a
    status is ciphertext only."""
    if not isinstance(meta, dict):
        return False, "meta must be an object"
    kind = meta.get("kind")
    if kind not in STATUS_KINDS:
        return False, "unknown status kind"
    bad = STATUS_FORBIDDEN_META & set(meta.keys())
    if bad:
        return False, "forbidden plaintext/secret field(s): " + ",".join(sorted(bad))
    extra = set(meta.keys()) - STATUS_ALLOWED_META
    if extra:
        return False, "disallowed meta key(s): " + ",".join(sorted(extra))
    if kind == STATUS_TEXT:
        if not meta.get("ciphertext"):
            return False, "missing ciphertext"
        if not meta.get("nonce"):
            return False, "missing nonce"
    else:  # photo / video
        if not status_media_available(kind):
            return False, "media status key-gated (encrypted storage not enabled)"
        if not meta.get("blob_ref"):
            return False, "missing blob_ref for media status"
    return True, "ok"


def build_status_meta(kind, visibility=None, created_at=None,
                      ciphertext=None, nonce=None, scheme=None, sender_key_id=None,
                      blob_ref=None, byte_size=None, quality=None,
                      duration_sec=None, width=None, height=None, mime_hint=None,
                      thumb_ciphertext=None, thumb_nonce=None,
                      caption_ciphertext=None, caption_nonce=None, sha256_ct=None):
    """Assemble a validated, relay-safe status payload (stamps created_at +
    24-hour expires_at + normalized visibility).  Raises on non-opaque input."""
    created = _as_dt(created_at) or datetime.now(timezone.utc)
    meta = {
        "kind": kind,
        "created_at": created.isoformat(),
        "expires_at": expiry_for(created).isoformat(),
        "visibility": normalize_visibility(visibility),
    }
    optional = (
        ("ciphertext", ciphertext), ("nonce", nonce), ("scheme", scheme),
        ("sender_key_id", sender_key_id), ("blob_ref", blob_ref),
        ("byte_size", byte_size), ("quality", quality),
        ("duration_sec", duration_sec), ("width", width), ("height", height),
        ("mime_hint", mime_hint), ("thumb_ciphertext", thumb_ciphertext),
        ("thumb_nonce", thumb_nonce), ("caption_ciphertext", caption_ciphertext),
        ("caption_nonce", caption_nonce), ("sha256_ct", sha256_ct),
    )
    for k, val in optional:
        if val is not None:
            meta[k] = val
    ok, reason = validate_status_meta(meta)
    if not ok:
        raise ValueError("refusing non-opaque status meta: " + reason)
    return meta


# ---------------------------------------------------------------------------
# Auto-cleanup of expired statuses (respect disk floor)
# ---------------------------------------------------------------------------
# A status is purged once it expires (24h).  When free disk is tight we still
# purge expired statuses first (they are dead weight) but never touch a status
# that is still live.  Mirrors circle_media's disk-floor discipline.

MB = 1024 * 1024
STATUS_DISK_FLOOR_BYTES = 512 * MB  # mirror circle_media.DISK_FLOOR_BYTES


def should_cleanup_status(status, now=None):
    """Return (cleanup: bool, reason).  Expired -> purge; else keep."""
    if is_expired(status, now=now):
        return True, "expired"
    return False, "live"


def cleanup_plan(statuses, now=None):
    """The list of status ids to purge now: every EXPIRED status (ciphertext +
    any blob_ref it owns).  Live statuses are never touched regardless of disk
    pressure — a status is tiny and self-expiring, so expiry is the only purge
    trigger; the disk floor is respected by never evicting a live status."""
    now = now or datetime.now(timezone.utc)
    return [s.get("id") for s in (statuses or [])
            if should_cleanup_status(s, now=now)[0]]


def blob_refs_to_free(statuses, now=None):
    """Blob refs owned by expired media statuses, so the view can delete the
    encrypted objects alongside the rows."""
    now = now or datetime.now(timezone.utc)
    refs = []
    for s in (statuses or []):
        if should_cleanup_status(s, now=now)[0] and s.get("blob_ref"):
            refs.append(s["blob_ref"])
    return refs


def disk_floor_ok(free_bytes, incoming_bytes=0, floor=STATUS_DISK_FLOOR_BYTES):
    """True if accepting `incoming_bytes` of new status media still leaves the
    free space at/above the floor.  The post view calls this before accepting a
    photo/video status blob."""
    return (int(free_bytes) - int(incoming_bytes)) >= floor


# ---------------------------------------------------------------------------
# Tray grouping — one entry per author, newest first, unseen ranked up
# ---------------------------------------------------------------------------
# WhatsApp/Messenger group a person's multiple statuses into one tray tile with
# an "unseen" ring.  Pure helper so the UI stays dumb.

def group_by_author(statuses, me_id, now=None):
    """Group ACTIVE statuses into per-author tray entries:
        [{author_id, count, has_unseen, latest_at}]
    'unseen' = at least one of the author's active statuses has no view record
    for `me_id`.  Sorted: unseen first, then most-recent latest_at."""
    now = now or datetime.now(timezone.utc)
    by = {}
    for s in (statuses or []):
        if is_expired(s, now=now):
            continue
        aid = s.get("author_id")
        if aid is None:
            continue
        seen_me = any(v.get("viewer") == me_id for v in (s.get("views") or []))
        latest = _as_dt(s.get("created_at")) or now
        e = by.setdefault(aid, {"author_id": aid, "count": 0,
                                "has_unseen": False, "latest_at": latest})
        e["count"] += 1
        if not seen_me:
            e["has_unseen"] = True
        if latest > e["latest_at"]:
            e["latest_at"] = latest
    entries = list(by.values())
    for e in entries:
        e["latest_at"] = e["latest_at"].isoformat()
    entries.sort(key=lambda e: (0 if e["has_unseen"] else 1, _neg_iso(e["latest_at"])))
    return entries


# ---------------------------------------------------------------------------
# Bilingual labels for the status UI (server-provided, so copy stays in sync)
# ---------------------------------------------------------------------------

def audience_label(mode, lang="bn"):
    labels = {
        AUD_EVERYONE: ("সার্কেলের সবাই", "My circle"),
        AUD_FAMILY: ("শুধু পরিবার", "Family only"),
        AUD_CHOSEN: ("নির্বাচিত ব্যক্তিরা", "Only chosen people"),
        AUD_EXCEPT: ("কিছু জন ছাড়া", "All except..."),
    }
    bn, en = labels.get(mode, labels[AUD_EVERYONE])
    return pick(lang, bn, en)


def kind_label(kind, lang="bn"):
    labels = {
        STATUS_TEXT: ("লেখা", "Text"),
        STATUS_PHOTO: ("ছবি", "Photo"),
        STATUS_VIDEO: ("ভিডিও", "Video"),
    }
    bn, en = labels.get(kind, labels[STATUS_TEXT])
    return pick(lang, bn, en)


def remaining_label(status, now=None, lang="bn"):
    """A short 'expires in' label for the status ring."""
    secs = seconds_remaining(status, now=now)
    if secs <= 0:
        return pick(lang, "শেষ হয়ে গেছে", "Expired")
    hours = secs // 3600
    mins = (secs % 3600) // 60
    if hours > 0:
        return pick(lang, f"{hours} ঘণ্টা বাকি", f"{hours}h left")
    return pick(lang, f"{mins} মিনিট বাকি", f"{mins}m left")


# ---------------------------------------------------------------------------
# Reviewer-pass (§21): conservative default + HONEST tray state
# ---------------------------------------------------------------------------
# §21 requires: a conservative privacy default, a viewer list that respects
# privacy, and HONEST states (a load error is never silently shown as "empty").

def conservative_default_visibility():
    """A STRICTER default than `default_visibility()` for first-time posters who
    have not yet chosen an audience: FAMILY ONLY.  A status is personal; the
    reviewer-pass rule is "status limited" by default.  The composer offers the
    full everyone/family/chosen/except choice, but the pre-selected safe option
    is family-only so nothing ever over-shares on a tap-through.  Pure; the
    existing `default_visibility()` (circle) is left untouched for callers that
    rely on it."""
    return {"mode": AUD_FAMILY, "allow_ids": [], "except_ids": []}


# Honest tray states — the UI renders exactly one of these; an ERROR is NEVER
# conflated with EMPTY (the silent-empty-on-failure anti-pattern §21 forbids).
TRAY_LOADING = "loading"
TRAY_ERROR = "error"
TRAY_EMPTY = "empty"
TRAY_READY = "ready"


def tray_state(entries, loaded=True, errored=False):
    """Resolve the honest tray state the status screen must render.

      errored     -> TRAY_ERROR  (show message + Retry; NOT "no updates")
      not loaded  -> TRAY_LOADING
      no entries  -> TRAY_EMPTY   (honest: genuinely nothing to show)
      otherwise   -> TRAY_READY
    """
    if errored:
        return TRAY_ERROR
    if not loaded:
        return TRAY_LOADING
    if not (entries or []):
        return TRAY_EMPTY
    return TRAY_READY


def tray_state_label(state, lang="bn"):
    """Localized copy for an honest tray state (error/empty)."""
    labels = {
        TRAY_ERROR: ("স্ট্যাটাস লোড করা যায়নি।", "Couldn’t load updates."),
        TRAY_EMPTY: ("এখনও কোনো নতুন আপডেট নেই।", "No recent updates yet."),
        TRAY_LOADING: ("লোড হচ্ছে…", "Loading…"),
        TRAY_READY: ("", ""),
    }
    bn, en = labels.get(state, labels[TRAY_EMPTY])
    return pick(lang, bn, en)


def expired_notice(lang="bn"):
    """Honest copy for a viewer that opened a status which has since expired —
    never a blank black screen, never stale content."""
    return pick(lang, "এই স্ট্যাটাসের মেয়াদ শেষ হয়ে গেছে।",
                "This status has expired.")


def mute_confirm(author_name="", lang="bn"):
    """Confirm-gate copy before muting an author's status (a reversible but
    surprising action — §21 wants a confirm on anything a user may not expect).
    The author is never notified; say so honestly."""
    name = (author_name or "").strip()
    if name:
        bn = f"{name}-এর স্ট্যাটাস আর আপনার ট্রেতে দেখাবে না। তাদের জানানো হবে না।"
        en = f"{name}’s status will stop showing in your tray. They won’t be told."
    else:
        bn = "এই ব্যক্তির স্ট্যাটাস আর আপনার ট্রেতে দেখাবে না। তাদের জানানো হবে না।"
        en = "This person’s status will stop showing in your tray. They won’t be told."
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _is_int(x):
    try:
        int(x)
        return True
    except (TypeError, ValueError):
        return False


def _neg_iso(iso):
    """Sort-key helper: reverse-chronological from an ISO string."""
    d = _as_dt(iso)
    return -(d.timestamp() if d else 0.0)


def _as_dt(v):
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v, tz=timezone.utc)
    if isinstance(v, str):
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None
