"""
sj_live.py — Safe Journey card 1 "Live Location" (owner order 3 Nov 02:25).

Built ON the existing Safe Journey (journey_watch.py, guardian_journey.py,
kidswatch School Mode) — no new tables:

  * SHARE FOR A WHILE: an ordinary Journey whose destination carries
    {"share": true}; eta = the end of the share (1 h / 3 h / custom). It never
    becomes "late" — at the end it simply stops by itself, both sides told.
    An open SOS keeps it running (safety first).
  * REQUEST LOCATION (location only): a guardian request whose destination is
    {"share": true} — same consent / visible banner / one-tap stop as before,
    but no destination and no late tail: it ends exactly at the chosen time.
  * HONEST ACCURACY: each phone fix may carry `acc` (metres, Android's own
    estimate). It is stored with the last fix and shown to watchers as
    "± N m"; a fix too rough for the arrival circle never counts as arrival.
  * WHO IS WHERE NOW: one list for the watcher — every live trip / share /
    location request they may see + their School Mode children's last known
    place. Location only while live; never after a trip ended.
  * CHILD SCHOOL from the child's phone: while the child's phone shares a
    Live Location, its fixes also feed the child's School Mode plan (the same
    state machine a watch uses), so "reached school / reached home" no longer
    need a button press. Holidays live in the plan config (school_mode.py).
  * CCTV GATE SNAPSHOT: only through the existing CCTV snapshot seam — a
    camera the plan owner owns (or may view) is linked to the plan; the
    snapshot nearest the child's arrival / leaving time (+-15 min) is shown.
    No camera linked -> nothing is shown (the app hides the button).
"""
import logging
from datetime import timedelta

from django.utils import timezone

from . import journey_watch as JW
from .logic import safety_journey as SJ

log = logging.getLogger(__name__)

SHARE_PRESETS = (60, 180)
SHARE_MIN_MIN = 15
SHARE_MAX_MIN = 24 * 60
ACC_MAX_M = 20000            # anything rougher is junk, dropped
ARRIVE_ACC_MIN_M = 150       # a fix up to this rough may still count as arrival
SCHOOL_FRESH_H = 12          # a child's last known place older than this is not shown
GATE_WINDOW_MIN = 15


# ------------------------------------------------------------------ share
def share_minutes(raw):
    """Minutes for a "share for a while", or None when not a valid share."""
    try:
        m = int(raw)
    except (TypeError, ValueError):
        return None
    return m if SHARE_MIN_MIN <= m <= SHARE_MAX_MIN else None


def is_share(j):
    return bool((getattr(j, "destination", None) or {}).get("share"))


def share_destination():
    return {"name": "", "share": True}


def end_share(j, now=None):
    """The share's time is over: stop, tell the watchers and the sharer.
    An open SOS keeps sharing (never ended by the clock). True when ended."""
    now = now or timezone.now()
    if j.status != "active" or not is_share(j) or j.sos_active:
        return False
    if j.eta is None or now < j.eta:
        return False
    j.status, j.stopped_at = "stopped", now
    j.expires_at = JW.ended_expiry(j, now)
    j.save(update_fields=["status", "stopped_at", "expires_at"])
    JW.emit(j, "share_ended", key="end")
    JW.push_traveller(
        j.traveller, j.id, "share_ended",
        "লাইভ লোকেশন শেয়ার বন্ধ হয়েছে", "Live Location sharing ended",
        "বাছাই করা সময় শেষ, তাই আর কেউ আপনার লোকেশন দেখছেন না।",
        "The time you chose is over, so nobody sees your location now.")
    JW.clear_urgent(j)
    return True


# --------------------------------------------------------------- accuracy
def clean_acc(raw):
    """Android's accuracy estimate in metres (int) or None."""
    try:
        a = float(raw)
    except (TypeError, ValueError):
        return None
    if not (0 < a <= ACC_MAX_M):
        return None
    return int(round(a))


def acc_ok_for_arrival(acc, radius_m):
    """A fix rougher than the arrival circle (x2, at least 150 m) never says
    "arrived" — a cell-tower fix 1 km wide is not proof of arrival. Old app
    builds send no accuracy: unchanged behaviour."""
    if acc is None:
        return True
    return acc <= max(ARRIVE_ACC_MIN_M, 2 * int(radius_m or 120))


def acc_of(j):
    try:
        v = (j.last_location or {}).get("acc")
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------- who is where now
def _kind(j, user):
    if j.guardian_requests.filter(requester=user, status="active").exists():
        return "request"
    return "share" if is_share(j) else "trip"


def where_now(user, now=None):
    """Rows for "Who is where now" (the caller is a watcher / parent)."""
    from .models import JourneyWatcher, SchoolPlan, CircleMember
    from . import push as PUSH
    from . import kidswatch_service as KW
    now = now or timezone.now()
    out = []
    rows = (JourneyWatcher.objects
            .filter(member__peer_user=user, member__state="accepted",
                    member__blocked=False, journey__expires_at__gt=now)
            .select_related("journey", "journey__traveller")
            .order_by("-journey__created_at")[:30])
    seen = set()
    for w in rows:
        j = w.journey
        if j.id in seen or not (j.status == "active" or j.sos_active):
            continue
        seen.add(j.id)
        fx = JW.fix_of(j)
        out.append({
            "kind": _kind(j, user), "journey_id": j.id,
            "name": PUSH.seen_name(user, j.traveller),
            "status": j.status, "sos": bool(j.sos_active),
            "destination": (j.destination or {}).get("name") or "",
            "until": j.eta.isoformat() if j.eta else None,
            "lat": fx[0] if fx else None, "lng": fx[1] if fx else None,
            "fix_age_s": int((now - fx[2]).total_seconds()) if fx and fx[2] else None,
            "acc_m": acc_of(j) if fx else None,
            "battery": fx[3] if fx else None,
            "url": JW.web_url(j)})
    peers = list(CircleMember.objects.filter(peer_user=user, state="accepted", blocked=False)
                 .values_list("user_id", flat=True))
    plans = SchoolPlan.objects.filter(enabled=True).filter(
        owner_id__in=[user.id] + peers).select_related("owner")[:50]
    for p in plans:
        if p.owner_id != user.id and user.id not in (p.watcher_ids or []):
            continue
        if not KW.can_view_plan(user, p):
            continue
        lk = p.last_known or {}
        at = SJ.parse_dt(lk.get("at")) if lk.get("at") else None
        if at is not None and timezone.is_naive(at):
            at = timezone.make_aware(at)
        fresh = at is not None and now - at <= timedelta(hours=SCHOOL_FRESH_H)
        day = p.day or {}
        out.append({
            "kind": "school", "plan_id": p.id, "name": p.child_name,
            "status": day.get("state", "idle") if day.get("date") == timezone.localtime(
                now, KW.LOCAL_TZ).date().isoformat() else "idle",
            "sos": False, "destination": "", "until": None,
            "lat": lk.get("lat") if fresh else None, "lng": lk.get("lng") if fresh else None,
            "fix_age_s": int((now - at).total_seconds()) if fresh else None,
            "acc_m": None, "battery": None, "source": lk.get("source") or "", "url": ""})
    out.sort(key=lambda r: (not r["sos"], r["lat"] is None,
                            r["fix_age_s"] if r["fix_age_s"] is not None else 10 ** 9))
    return out


# ------------------------------------------------------- child school feed
def feed_school(user, fixes, now=None):
    """The child's phone is sharing: its fixes drive the child's School Mode
    plan(s) (phone plans the child accepted). Never raises. Returns events."""
    try:
        from .models import SchoolPlan
        from . import kidswatch_service as KW
        now = now or timezone.now()
        n = 0
        # fixes: (at, lat, lng, battery, src, acc) from the location view;
        # a rough (cell-tower) fix never moves the school state machine
        pts = [{"at": f[0], "lat": f[1], "lng": f[2]} for f in fixes
               if acc_ok_for_arrival(f[5] if len(f) > 5 else None, 75)]
        if not pts:
            return 0
        for p in SchoolPlan.objects.filter(child_user=user, enabled=True,
                                           accepted_at__isnull=False,
                                           watch__isnull=True, chip__isnull=True):
            n += KW.plan_fixes(p, pts, now)
        return n
    except Exception as e:
        log.warning("sj_live: school feed failed %s", type(e).__name__)
        return 0


# ---------------------------------------------------------- CCTV gate seam
def cameras_for(user):
    """Cameras the user owns or may view (the CCTV snapshot seam's rule)."""
    from .models import ShopCamera
    from django.db.models import Q
    return (ShopCamera.objects.filter(Q(site__owner=user) | Q(site__viewers__user=user))
            .select_related("site").distinct())


def gate_camera_ok(user, cam_id):
    try:
        cam_id = int(cam_id)
    except (TypeError, ValueError):
        return False
    return cameras_for(user).filter(pk=cam_id).exists()


def gate_snapshot(plan, at):
    """(event, None) — the CCTV event snapshot of the plan's gate camera
    nearest `at` (+-GATE_WINDOW_MIN), or (None, reason)."""
    from .models import ShopEvent
    cam_id = (plan.config or {}).get("gate_camera_id")
    if not cam_id:
        return None, "no_camera"
    if not gate_camera_ok(plan.owner, cam_id):
        return None, "no_camera"
    w = timedelta(minutes=GATE_WINDOW_MIN)
    evs = (ShopEvent.objects.filter(camera_id=cam_id, created__gte=at - w, created__lte=at + w)
           .exclude(snapshot="").exclude(snapshot=None))
    best = min(evs[:50], key=lambda e: abs((e.created - at).total_seconds()), default=None)
    if best is None:
        return None, "no_snapshot"
    return best, None
