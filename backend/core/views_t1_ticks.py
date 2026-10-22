"""t1-ticks — round-2 fixes for My Circle ticks (owner test of build 183).

1a  LEGACY messages. Messages created before read receipts existed (before the
    c3 receipts migration 0055_c3_msg was applied on this server) have no real
    delivered/seen data: any receipt row they carry was written later by a
    bulk sync or by opening the chat, so its time is NOT when the message was
    delivered or read. Such messages are flagged `receipts_legacy: true`, show
    a single neutral tick (status "sent") and Message info says "Sent before
    read receipts were enabled" instead of "Not yet" forever.
    The epoch is settings.CIRCLE_RECEIPTS_EPOCH (ISO string / datetime) when
    set, else the time Django recorded applying core.0055_c3_msg, else none
    (nothing is legacy).

1b  DELIVERED on hand-off is owned by x2-ticks (views_c3_msg.mark_fetched
    on every message fetch, sync_delivered on the chat list / app open) and
    the device's push ack. t1's own deliver_fetched()/on_fcm_accepted() were
    dropped at the Build B merge so receipts are written by ONE code path
    (FCM "accepted" was not proof the phone had the message).

1c  Minimum-version gate. `limits.my_circle_min_version` in the admin pricing
    config (/admin/pricing, default 183) is published in GET app/latest and in
    GET circle/t1/gate. The app compares its own build; the gate also reports
    which PEERS run an older build (User.app_version, recorded on
    devices/register and on every gate call) so the chat shows an honest
    "<name> needs to update Assisto for ticks/calls" banner — sending is never
    blocked.
"""
import re
from datetime import datetime, timezone as dt_tz

from django.conf import settings
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework.response import Response
from rest_framework.views import APIView

DEFAULT_MIN_VERSION = 183
PEERS_LISTED_MAX = 3

_EPOCH_CACHE = {"v": None, "ok": False}


# ---------------------------------------------------------------------------
# 1a legacy epoch
# ---------------------------------------------------------------------------
def _as_aware(v):
    if isinstance(v, str):
        v = parse_datetime(v.strip())
    if not isinstance(v, datetime):
        return None
    if timezone.is_naive(v):
        v = timezone.make_aware(v, dt_tz.utc)
    return v


def receipts_epoch():
    """When per-message receipts started on this server (aware datetime) or
    None. Cached once found (the migration row never moves)."""
    forced = getattr(settings, "CIRCLE_RECEIPTS_EPOCH", None)
    if forced:
        return _as_aware(forced)
    if _EPOCH_CACHE["ok"]:
        return _EPOCH_CACHE["v"]
    try:
        from django.db.migrations.recorder import MigrationRecorder
        row = (MigrationRecorder.Migration.objects
               .filter(app="core", name__startswith="0055_c3_msg")
               .order_by("applied").first())
        v = _as_aware(row.applied) if row is not None else None
    except Exception:
        return None
    _EPOCH_CACHE.update(v=v, ok=True)
    return v


def reset_epoch_cache():
    _EPOCH_CACHE.update(v=None, ok=False)


def is_legacy(x, epoch=None):
    """True when message x was created before receipts existed."""
    epoch = epoch if epoch is not None else receipts_epoch()
    if epoch is None or x is None or getattr(x, "created_at", None) is None:
        return False
    return x.created_at < epoch


def legacy_ids(msgs):
    epoch = receipts_epoch()
    if epoch is None:
        return set()
    return {x.id for x in msgs if is_legacy(x, epoch)}


# ---------------------------------------------------------------------------
# 1b delivered on hand-off — merged into x2-ticks (Build B integration):
# views_c3_msg.mark_fetched() (history + poll fetch) and sync_delivered()
# (chat list fetch, app open) are the ONE implementation; push delivery is
# the device's own ack (x2 ackPushDelivery), not "FCM accepted".
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 1c minimum version
# ---------------------------------------------------------------------------
_BUILD_RE = re.compile(r"(\d+)")


def build_of(v):
    """App version string -> build number. '1.0.183+183' -> 183, '183' -> 183,
    '1.0.145' -> 145 (last number), '' / garbage -> None."""
    s = str(v or "").strip()
    if not s:
        return None
    if "+" in s:
        tail = s.rsplit("+", 1)[1]
        m = _BUILD_RE.search(tail)
        if m:
            return int(m.group(1))
    nums = _BUILD_RE.findall(s)
    return int(nums[-1]) if nums else None


def min_version():
    try:
        from . import billing
        return int(billing.cfg()["limits"].get("my_circle_min_version",
                                               DEFAULT_MIN_VERSION))
    except Exception:
        return DEFAULT_MIN_VERSION


def record_app_version(user, app_version):
    """Remember the caller's app version on the User (never downgrades to
    blank). Never raises."""
    try:
        from .models import User
        v = str(app_version or "").strip()[:24]
        if not v or build_of(v) is None or user is None:
            return False
        if getattr(user, "app_version", "") == v:
            return False
        User.objects.filter(pk=user.pk).update(app_version=v)
        user.app_version = v
        return True
    except Exception:
        return False


def user_build(u):
    """Last known build of user `u`: User.app_version, else their most
    recently seen push device's version. None = unknown."""
    b = build_of(getattr(u, "app_version", ""))
    if b is not None:
        return b
    try:
        from .models import Device
        v = (Device.objects.filter(user=u).exclude(app_version="")
             .order_by("-last_seen").values_list("app_version", flat=True)
             .first())
        return build_of(v)
    except Exception:
        return None


def _chat_peers(user, kind, chat_id):
    """Other users of one of the caller's chats, or None if not theirs."""
    from .models import CircleGroupMember, CircleMember
    from . import push
    try:
        cid = int(chat_id)
    except (TypeError, ValueError):
        return None
    if kind == "group":
        if not CircleGroupMember.objects.filter(
                group_id=cid, member=user, status="active").exists():
            return None
        return [r.member for r in CircleGroupMember.objects.filter(
            group_id=cid, status="active").exclude(member=user)
            .select_related("member")]
    edge = CircleMember.objects.filter(user=user, pk=cid).first()
    if edge is None:
        return None
    p = push.member_peer_user(edge)
    return [p] if p is not None and p.id != user.id else []


class McGateView(APIView):
    """GET circle/t1/gate?kind=member|group&id=<chat id>&build=<my build>

    -> {min_version, my_build, me_outdated, peer_build (1:1), peers_outdated:
        [{user_id, name, build}] (≤3), peers_outdated_count}
    `build` (optional) also records the caller's version. Peers whose build is
    unknown are never reported as outdated (honest: we don't know)."""

    def get(self, request):
        q = request.query_params
        mv = min_version()
        mine = build_of(q.get("build"))
        if mine is not None:
            record_app_version(request.user, str(mine))
        out = {"min_version": mv, "my_build": mine,
               "me_outdated": bool(mine is not None and mine < mv),
               "peer_build": None, "peers_outdated": [],
               "peers_outdated_count": 0}
        kind = "group" if str(q.get("kind", "")) == "group" else "member"
        if q.get("id") in (None, ""):
            return Response(out)
        peers = _chat_peers(request.user, kind, q.get("id"))
        if peers is None:
            return Response({"detail": "not found"}, status=404)
        old = []
        for p in peers:
            b = user_build(p)
            if kind == "member":
                out["peer_build"] = b
            if b is not None and b < mv:
                old.append({"user_id": p.id, "name": (p.name or "").strip(),
                            "build": b})
        out["peers_outdated"] = old[:PEERS_LISTED_MAX]
        out["peers_outdated_count"] = len(old)
        return Response(out)
