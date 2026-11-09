"""cctvteam (W11) — pure rules for CCTV teams and sharing (no DB, no I/O).

ROLES (per site, chosen by the owner; enforced server-side everywhere):
  owner    everything (implicit — the site's owner, never a viewer row)
  manager  every camera (or the chosen ones), may mark alerts checked/false
  family   every camera (or the chosen ones), read-only
  guard    ONLY the chosen cameras (at least one), read-only
  staff    (cctvroles, V3 I) a shop worker: every camera (or the chosen
           ones), read-only — never deletes, exports, shares or changes
           anything. Only the OWNER deletes / exports / changes (PERMS).
Live view for a viewer only when the owner switched `live_ok` on for them.

SHARE LINKS: view-only stills of chosen cameras for 1 h / 24 h / custom
(1..72 h), revocable, never audio, never history.

NEIGHBOURHOOD WATCH: one user-chosen still to one PRIVATE community group,
expires after 6 / 24 / 72 h (default 24), hidden after REPORT_HIDE reports.
"""

ROLES = ("family", "manager", "guard", "staff")
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


# cctvroles (V3 I): the one permission table. Server-side checks use can();
# the app shows the same table so nobody is surprised. Only the site owner
# deletes, exports evidence, shares clips/links, changes settings or roles,
# or invites an installer. An installer partner is NOT a role here: it never
# reaches any of these (core/cctv_partner_views.py, setup status only).
ACTIONS = ("view", "mark", "export", "share", "delete", "settings", "roles", "installer")
PERMS = {
    "owner": frozenset(ACTIONS),
    "manager": frozenset(("view", "mark")),
    "family": frozenset(("view",)),
    "guard": frozenset(("view",)),
    "staff": frozenset(("view",)),
}
# what the owner is offered first for each kind of place (all roles stay
# available; a home is for family, a shop for managers / staff / guards)
SUGGESTED = {"home": ("family", "guard"), "shop": ("manager", "staff", "guard", "family")}


def can(role, action):
    return action in PERMS.get(role or "", frozenset())


def perm_table():
    return {r: [a for a in ACTIONS if a in PERMS[r]] for r in ("owner",) + ROLES}


def suggested_roles(kind):
    return list(SUGGESTED.get(kind or "shop", SUGGESTED["shop"]))


# cctvroles (V3 I): the audit list — views (deduped) AND every export /
# share / change / delete / installer step (never deduped, the owner's own
# included). Detail text is short, made by the server (never user video).
AUDIT_ACTIONS = ("export", "share", "change", "delete", "role", "installer")
DETAIL_MAX = 120
AUDIT_KEEP_DAYS = 180             # export / change rows (views: LOG_KEEP_DAYS)


def clean_detail(v):
    s = " ".join(str(v or "").split())
    return s[:DETAIL_MAX]


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


# cctvroles: the audit detail is stored as a short machine string
# ("k=v;k=v") and shown in the reader's language (strict bn / en).
_ROLE_WORDS = {"family": ("পরিবার", "family"), "manager": ("ম্যানেজার", "manager"),
               "guard": ("গার্ড", "guard"), "staff": ("কর্মী", "staff")}
_FIELD_WORDS = {"name": ("নাম", "name"), "hours": ("খোলার সময়", "hours"),
                "snapshot_retention_days": ("ছবি রাখার দিন", "photo days"),
                "pos_link": ("POS যোগ", "POS link"), "gateway": ("সংযোগের ধরন", "connection"),
                "zone_config": ("জোন", "zones"), "enabled": ("চালু/বন্ধ", "on/off"),
                "camera_token": ("ক্যামেরার চাবি", "camera key")}
_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def pack(**kv):
    """k=v;k=v with the separators removed from values (names are typed)."""
    out = []
    for k, v in kv.items():
        s = " ".join(str(v if v is not None else "").split())
        s = s.replace(";", ",").replace("=", "-")[:40]
        out.append("%s=%s" % (k, s))
    return clean_detail(";".join(out))


def unpack(raw):
    d = {}
    for part in str(raw or "").split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def _n(v, lang):
    s = str(v)
    return s.translate(_BN_DIGITS) if lang == "bn" else s


def detail_text(action, raw, lang="bn"):
    """The audit row's 'what' in the reader's language; '' when unknown."""
    d = unpack(raw)
    bn = lang == "bn"
    i = 0 if bn else 1

    def fields(v):
        return ", ".join(_FIELD_WORDS.get(f.strip(), (f.strip(), f.strip()))[i]
                         for f in str(v).split(",") if f.strip())
    if action == "export" and "ev" in d:
        return ("সতর্কতা #%s-এর প্রমাণ" if bn else "evidence of alert #%s") % _n(d["ev"], lang)
    if action == "share":
        if "clip" in d:
            return ("সতর্কতা #%s-এর ক্লিপ" if bn else "clip of alert #%s") % _n(d["clip"], lang)
        if d.get("link") == "off":
            return "লিংক বন্ধ" if bn else "link turned off"
        if "link" in d:
            return ("লিংক %s ঘণ্টা, %s ক্যামেরা" if bn else "link %s h, %s camera(s)") % (
                _n(d["link"], lang), _n(d.get("cam", "0"), lang))
    if action == "change":
        if "alert" in d:
            st = d.get("st", "")
            word = {"checked": ("ঠিক আছে", "checked"),
                    "false_alarm": ("ভুল সতর্কতা", "wrong alert")}.get(st, (st, st))[i]
            return ("সতর্কতা #%s: %s" if bn else "alert #%s: %s") % (_n(d["alert"], lang), word)
        if "removed" in d:
            return ("সরানো হয়েছে: %s" if bn else "removed: %s") % d["removed"]
        if "cam" in d:
            return "%s: %s" % (d["cam"], fields(d.get("f", "")))
        if "place" in d:
            return ("জায়গা: %s" if bn else "place: %s") % fields(d["place"])
    if action == "delete" and "camera" in d:
        return ("ক্যামেরা: %s" if bn else "camera: %s") % d["camera"]
    if action == "role" and "who" in d:
        role = _ROLE_WORDS.get(d.get("role", ""), (d.get("role", ""),) * 2)[i]
        out = "%s → %s" % (d["who"], role)
        if d.get("cam") not in (None, "", "0"):
            out += (" (%s ক্যামেরা)" if bn else " (%s camera(s))") % _n(d["cam"], lang)
        if d.get("live") == "1":
            out += " · লাইভ" if bn else " · live"
        return out
    if action == "installer":
        if "invite" in d:
            return "কোড তৈরি" if bn else "code made"
        if "joined" in d:
            return ("যুক্ত হয়েছেন: %s" if bn else "joined: %s") % d["joined"]
        if "ended" in d:
            return ("বন্ধ: %s" if bn else "ended: %s") % (d["ended"] or ("কোড" if bn else "code"))
    return ""
