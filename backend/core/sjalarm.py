"""sjalarm — owner Safe Journey order 3 Nov, Cards 2 + 3 (server side).

  * schedule_verified(): the owner's Owner Admin switch
    `train_schedule_verified` (enabled_all). Until it is ON every train says
    "schedule not verified". An owner PREVIEW never counts — the label must not
    disappear on the owner's own phone only.
  * trip traces (PROOF): the OWNER-ONLY trip recorder uploads real GPS traces
    here. Stored under backend/private/trip_traces/ (outside MEDIA_ROOT, never
    served, never listed to anybody but the uploader). Who may: superuser /
    staff, or a user id on the `trip_recorder` allow-list in Owner Admin.
  * notify_arrived(): the destination alarm's optional "tell family when I
    arrive" — only the My Circle people the traveller picked, through the
    existing family-alert delivery (consent, blocks, quiet hours, rate limit).
No new model, no migration.
"""
import json
import os
import re
from datetime import timezone as dt_tz

from django.conf import settings
from django.utils import timezone

TRACE_FORMAT = "assisto-trip-trace/1"
TRACE_MAX_POINTS = 30000          # > 8 h at 1 Hz
TRACE_MAX_FILES = 300             # per uploader
TRACE_MODES = ("cityBus", "longBus", "train", "metro", "launch", "walking")
STOP_MAX = 80
NOTIFY_MAX = 20
_CTRL = re.compile(r"[\x00-\x1f\x7f]")


def _ff():
    from . import feature_flags as FF
    return FF


def schedule_verified():
    try:
        r = _ff().rows().get("train_schedule_verified") or {}
        return bool(r.get("enabled_all"))
    except Exception:
        return False


# ------------------------------------------------------------ trip traces
def can_record(user):
    if not getattr(user, "is_authenticated", False):
        return False
    FF = _ff()
    if FF.is_privileged(user):
        return True
    try:
        row = FF.rows().get("trip_recorder") or {}
        return user.pk in (row.get("allow_user_ids") or [])
    except Exception:
        return False


def trace_root():
    return getattr(settings, "TRIP_TRACE_ROOT",
                   os.path.join(str(settings.BASE_DIR), "private", "trip_traces"))


def _user_dir(user):
    return os.path.join(trace_root(), "u%d" % int(user.pk))


def _num(v, lo, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    v = float(v)
    return v if lo <= v <= hi and v == v else None


def clean_trace(tr):
    """(clean dict, None) or (None, reason). Keeps only the known fields."""
    if not isinstance(tr, dict) or tr.get("format") != TRACE_FORMAT:
        return None, "bad_format"
    pts = tr.get("points")
    if not isinstance(pts, list) or not pts:
        return None, "no_points"
    if len(pts) > TRACE_MAX_POINTS:
        return None, "too_many_points"
    out = []
    for p in pts:
        if not isinstance(p, dict):
            return None, "bad_point"
        lat, lng = _num(p.get("lat"), -90, 90), _num(p.get("lng"), -180, 180)
        acc = _num(p.get("acc", 0), 0, 100000)
        t = p.get("t")
        if lat is None or lng is None or acc is None or not isinstance(t, str) or len(t) > 40:
            return None, "bad_point"
        sp = p.get("speed")
        sp = _num(sp, 0, 200) if sp is not None else None
        q = {"t": t, "lat": lat, "lng": lng, "acc": acc, "speed": sp}
        b = _num(p.get("bearing"), 0, 360) if p.get("bearing") is not None else None
        if b is not None:
            q["bearing"] = b
        out.append(q)
    mode = tr.get("mode") if tr.get("mode") in TRACE_MODES else "cityBus"
    stop = None
    s = tr.get("stop")
    if isinstance(s, dict):
        sl, sg = _num(s.get("lat"), -90, 90), _num(s.get("lng"), -180, 180)
        if sl is not None and sg is not None:
            stop = {"name": _CTRL.sub("", str(s.get("name") or ""))[:STOP_MAX], "lat": sl, "lng": sg}
    set_m = _num(tr.get("set_m", 10), 0, 20000)
    return {"format": TRACE_FORMAT, "synthetic": False,
            "note": "REAL trip recorded with the Assisto trip recorder (owner).",
            "mode": mode, "set_m": int(set_m if set_m is not None else 10),
            "stop": stop, "expect": {"min_lead_s": 15, "max_lead_s": 900},
            "points": out}, None


def save_trace(user, tr, now=None):
    """Write one cleaned trace. Returns (name, None) or (None, reason)."""
    clean, why = clean_trace(tr)
    if clean is None:
        return None, why
    d = _user_dir(user)
    os.makedirs(d, mode=0o700, exist_ok=True)
    if len([f for f in os.listdir(d) if f.endswith(".json")]) >= TRACE_MAX_FILES:
        return None, "too_many_files"
    now = (now or timezone.now()).astimezone(dt_tz.utc)
    name = "real_%s_%s.json" % (clean["mode"], now.strftime("%Y%m%dT%H%M%S%fZ"))
    path = os.path.join(d, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(clean, f, ensure_ascii=False, separators=(",", ":"))
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return name, None


def list_traces(user):
    d = _user_dir(user)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d), reverse=True):
        if f.endswith(".json"):
            out.append({"name": f, "bytes": os.path.getsize(os.path.join(d, f))})
    return out


# ------------------------------------------------------------ arrival notice
def notify_arrived(user, stop, circle_ids, now=None):
    """Tell the picked My Circle people "<name> arrived at <stop>". Returns
    (stats dict, None) or (None, reason)."""
    from . import family_alerts as FA
    from .models import CircleMember
    from .push import member_peer_user
    stop = _CTRL.sub("", str(stop or "")).strip()[:STOP_MAX]
    ids = []
    for x in (circle_ids if isinstance(circle_ids, list) else [])[:NOTIFY_MAX]:
        try:
            i = int(x)
        except (TypeError, ValueError):
            continue
        if i > 0 and i not in ids:
            ids.append(i)
    if not ids:
        return None, "no_people"
    people = []
    for m in CircleMember.objects.filter(user=user, pk__in=ids, state="accepted", blocked=False):
        u = member_peer_user(m)
        if u is not None:
            people.append(u)
    if not people:
        return None, "no_people"
    now = now or timezone.now()
    st_bn = stop or "গন্তব্যে"
    st_en = stop or "their stop"
    payload = {
        "title_bn": "{name} পৌঁছে গেছেন",
        "title_en": "{name} has arrived",
        "body_bn": "{name} %s পৌঁছেছেন (গন্তব্য অ্যালার্ম)।" % (stop + "-এ" if stop else st_bn),
        "body_en": "{name} reached %s (destination alarm)." % st_en,
    }
    stats = FA.alert(user, "dest_arrived", "dest:%d" % (int(now.timestamp()) // 60),
                     payload=payload, recipients=people, now=now)
    return stats, None
