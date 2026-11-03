"""cctvteam (W11) — pure rules for CCTV teams and sharing (no DB, no I/O).

ROLES (per site, chosen by the owner; enforced server-side everywhere):
  owner    everything (implicit — the site's owner, never a viewer row)
  manager  every camera (or the chosen ones), may mark alerts checked/false
  family   every camera (or the chosen ones), read-only
  guard    ONLY the chosen cameras (at least one), read-only
Live view for a viewer only when the owner switched `live_ok` on for them.

SHARE LINKS: view-only stills of chosen cameras for 1 h / 24 h / custom
(1..72 h), revocable, never audio, never history.

NEIGHBOURHOOD WATCH: one user-chosen still to one PRIVATE community group,
expires after 6 / 24 / 72 h (default 24), hidden after REPORT_HIDE reports.
"""

ROLES = ("family", "manager", "guard")
MAX_VIEWERS = 8                 # people per site (owner excluded)
SHARE_PRESETS = (1, 24)         # hours offered as one-tap choices
SHARE_MAX_HOURS = 72            # custom upper bound (3 days)
MAX_ACTIVE_LINKS = 5            # per site
WATCH_HOURS = (6, 24, 72)
WATCH_DEFAULT_HOURS = 24
REPORT_HIDE = 3                 # reports from different members hide a post
REPORT_REASONS = ("wrong_person", "private", "abuse", "spam", "other")
STILL_MIN_S = 30                # a fresh vendor still at most this often per camera
LOG_DEDUPE_S = 300              # the same view within 5 min is logged once
LOG_KEEP_DAYS = 30
CAPTION_MAX = 200


class TeamError(ValueError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _ids(v):
    if v in (None, ""):
        return []
    if not isinstance(v, (list, tuple)):
        raise TeamError("bad_cameras")
    out = []
    for x in v:
        if isinstance(x, bool):
            raise TeamError("bad_cameras")
        try:
            i = int(x)
        except (TypeError, ValueError):
            raise TeamError("bad_cameras")
        if i <= 0:
            raise TeamError("bad_cameras")
        if i not in out:
            out.append(i)
    return out


def clean_role(role, cameras, site_camera_ids):
    """(role, [camera ids]) validated against the site's cameras. A guard
    needs at least one camera; family/manager [] = every camera."""
    role = str(role or "family").strip().lower()
    if role not in ROLES:
        raise TeamError("bad_role")
    ids = _ids(cameras)
    known = set(int(i) for i in site_camera_ids)
    if any(i not in known for i in ids):
        raise TeamError("unknown_camera")
    if role == "guard" and not ids:
        raise TeamError("guard_needs_camera")
    return role, ids


def scope_of(role, cameras):
    """None = every camera of the site; else the frozenset of allowed ids."""
    try:
        ids = _ids(cameras)
    except TeamError:
        ids = []
    if role == "guard":
        return frozenset(ids)            # a guard with nothing sees nothing
    return frozenset(ids) if ids else None


def camera_allowed(scope, camera_id):
    """May someone with `scope` see camera `camera_id`? A camera-less item
    (a site-level POS / end-of-day alert) only for an unrestricted scope."""
    if scope is None:
        return True
    if camera_id is None:
        return False
    try:
        return int(camera_id) in scope
    except (TypeError, ValueError):
        return False


def can_mark(role):
    return role in ("owner", "manager")


def share_hours(v):
    try:
        h = int(v)
    except (TypeError, ValueError):
        raise TeamError("bad_hours")
    if isinstance(v, bool) or h < 1 or h > SHARE_MAX_HOURS:
        raise TeamError("bad_hours")
    return h


def share_cameras(v, site_camera_ids):
    ids = _ids(v)
    if not ids:
        raise TeamError("pick_camera")
    known = set(int(i) for i in site_camera_ids)
    if any(i not in known for i in ids):
        raise TeamError("unknown_camera")
    return ids


def link_state(revoked_at, expires_at, now):
    if revoked_at is not None:
        return "revoked"
    if expires_at <= now:
        return "expired"
    return "active"


def watch_hours(v):
    if v in (None, ""):
        return WATCH_DEFAULT_HOURS
    try:
        h = int(v)
    except (TypeError, ValueError):
        raise TeamError("bad_hours")
    if isinstance(v, bool) or h not in WATCH_HOURS:
        raise TeamError("bad_hours")
    return h


def clean_caption(v):
    s = " ".join(str(v or "").split())
    return s[:CAPTION_MAX]


def report_reason(v):
    v = str(v or "other").strip().lower()
    return v if v in REPORT_REASONS else "other"


def camera_status(enabled, online, last_seen):
    """The grid pill: off | online | offline | never."""
    if not enabled:
        return "off"
    if last_seen is None:
        return "never"
    return "online" if online else "offline"
