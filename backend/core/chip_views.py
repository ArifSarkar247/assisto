"""
Tracker chip HTTP API (chipbuy, owner 2 Nov) — /api/kids-watch/chips/...
Behind the same server flag as the Kids screen (`kids_watch`).

A chip is a VehicleTracker(kind='chip') paired exactly like a vehicle
tracker (IMEI + pairing window + the brand's SMS setup, see
/api/vehicle/setup-guide). ACCESS (server-enforced, tested):
  * owner                         -> view + manage
  * guardian (family grant, still an accepted unblocked Circle peer) -> view
  * the child (child_user)        -> ONLY "a chip is on + who can see"
                                     (`worn`), never location / history
  * anyone else                   -> 404
Never charged: a child's safety device is never paywalled.
"""
from datetime import timedelta

from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import chip_service as CS
from . import kidswatch_service as KW
from . import vehicle_service as VS
from .kidswatch_views import flag_on, _off

R = Response


def _protocols():
    from .models import VehicleTracker
    return [p for p, _ in VehicleTracker.PROTOCOLS if p != "auto"]


def _load(request, pk, manage=False):
    from .models import VehicleTracker
    t = VehicleTracker.objects.filter(pk=pk, kind="chip").select_related(
        "owner", "child_user").first()
    if t is None or not CS.can_view(request.user, t):
        return None, R({"ok": False, "reason": "not_found"}, status=404)
    if manage and t.owner_id != request.user.id:
        return None, R({"ok": False, "reason": "forbidden"}, status=403)
    return t, None


def _tell_child(t, owner):
    """Consent + visibility: the child (if on Assisto) is told a chip is on
    and who can see it. Never silent tracking of a person with a phone."""
    if t.child_user_id is None:
        return
    names = ", ".join(u.name or "" for u in CS.viewers(t) if u.name) or (owner.name or "")
    KW._send([t.child_user], "তোমার ব্যাগে ট্র্যাকার চিপ চালু", "A tracker chip is on for you",
             "%s তোমার জন্য একটি ট্র্যাকার চিপ চালু করেছেন। যারা অবস্থান দেখতে পারেন: %s।"
             % (owner.name or "", names),
             "%s turned on a tracker chip for you. Who can see where it is: %s."
             % (owner.name or "", names),
             {"chip_id": t.id, "event": "chip_on"}, family_alert=False, route="kids_watch")


class ChipListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import VehicleTracker
        if not flag_on(request.user):
            return _off()
        now = timezone.now()
        own = list(VehicleTracker.objects.filter(owner=request.user, kind="chip")
                   .select_related("owner", "child_user"))
        for t in own:                       # chipbuy2: find mode ends on time
            try:
                CS.end_find_if_due(t, now)
            except Exception:  # noqa: BLE001 — the list must still load
                pass
        shared = [t for t in VehicleTracker.objects.filter(
            kind="chip", grants__grantee=request.user, grants__kind="family")
            .exclude(owner=request.user).select_related("owner").distinct()[:50]
            if CS.can_view(request.user, t)]
        worn = [CS.worn_json(t) for t in VehicleTracker.objects.filter(
            kind="chip", child_user=request.user).exclude(owner=request.user)
            .select_related("owner")[:10]]
        return R({"chips": [CS.chip_json(t, request.user, now) for t in own + shared],
                  "worn": worn, "history_hours": CS.HISTORY_HOURS,
                  "protocols": _protocols()})

    def post(self, request):
        from .models import VehicleTracker, User
        if not flag_on(request.user):
            return _off()
        d = request.data or {}
        proto = d.get("protocol") if d.get("protocol") in _protocols() else "auto"
        imei = VS.normalize_imei(d.get("imei"))
        if not VS.imei_valid(imei, proto):
            return R({"ok": False, "reason": "bad_imei"}, status=400)
        name = str(d.get("child_name") or "").strip()[:60]
        if not name:
            return R({"ok": False, "reason": "name_required"}, status=400)
        child = None
        if d.get("child_user_id"):
            try:
                cid = int(d.get("child_user_id"))
            except (TypeError, ValueError):
                cid = 0
            if not KW._peer_ok(request.user, cid):
                return R({"ok": False, "reason": "child_not_in_circle"}, status=400)
            child = User.objects.filter(pk=cid).first()
        existing = VehicleTracker.objects.filter(imei=imei).first()
        if existing is not None and existing.owner_id != request.user.id:
            VS.audit(existing, "pair_conflict", actor=request.user)
            return R({"ok": False, "reason": "imei_taken"}, status=409)
        if existing is not None and existing.kind != "chip":
            return R({"ok": False, "reason": "imei_is_vehicle"}, status=409)
        if existing is None and VehicleTracker.objects.filter(
                owner=request.user, kind="chip").count() >= CS.MAX_CHIPS_PER_USER:
            return R({"ok": False, "reason": "limit"}, status=409)
        now = timezone.now()
        cfg = VS.vcfg()
        t = existing or VehicleTracker(owner=request.user, imei=imei, kind="chip")
        t.child_name = name
        t.name = name[:80]
        t.child_user = child
        t.protocol = proto if existing is None or proto != "auto" else t.protocol
        if existing is None:
            # chip defaults: walking-pace interval, no vehicle-only alerts
            t.moving_interval_s = CS.MOVING_INTERVAL_S
            t.parked_interval_s = CS.PARKED_INTERVAL_S
            t.night_ignition_alert = False
            t.speed_limit_kmh = 0
            t.alert_prefs = dict(CS.CHIP_PREFS)
        if t.state != "paired":
            t.state = "pending"
            t.disabled_reason = ""
            t.pair_expires_at = now + timedelta(minutes=cfg["pair_window_min"])
        t.save()
        CS.set_guardians(t, d.get("guardian_ids"))
        VS.audit(t, "chip_pair_requested", actor=request.user)
        _tell_child(t, request.user)
        from .views_vehicle import _server_info
        return R({"ok": True, "chip": CS.chip_json(t, request.user, now),
                  "server": _server_info()}, status=201 if existing is None else 200)


class ChipDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk)
        if err:
            return err
        return R(CS.chip_json(t, request.user))

    def patch(self, request, pk):
        from .models import User
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk, manage=True)
        if err:
            return err
        d = request.data or {}
        if "child_name" in d:
            name = str(d.get("child_name") or "").strip()[:60]
            if not name:
                return R({"ok": False, "reason": "name_required"}, status=400)
            t.child_name, t.name = name, name[:80]
        told = False
        if isinstance(d.get("left_behind"), dict):          # chipbuy2
            try:
                CS.set_left_cfg(t, d["left_behind"])
            except ValueError as e:
                return R({"ok": False, "reason": str(e)}, status=400)
        if "child_user_id" in d:
            cid = d.get("child_user_id")
            if cid in (None, "", 0):
                t.child_user = None
            else:
                try:
                    cid = int(cid)
                except (TypeError, ValueError):
                    cid = 0
                if not KW._peer_ok(request.user, cid):
                    return R({"ok": False, "reason": "child_not_in_circle"}, status=400)
                told = t.child_user_id != cid
                t.child_user = User.objects.filter(pk=cid).first()
        t.save()
        if "guardian_ids" in d:
            CS.set_guardians(t, d.get("guardian_ids"))
            plan = getattr(t, "school_plan", None)
            if plan is not None:
                plan.watcher_ids = [u.id for u in CS.guardian_users(t)]
                plan.save(update_fields=["watcher_ids", "updated_at"])
            told = True
        if told:
            _tell_child(t, request.user)
        return R({"ok": True, "chip": CS.chip_json(t, request.user)})

    def delete(self, request, pk):
        """Remove the chip and ALL its location history."""
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk, manage=True)
        if err:
            return err
        VS.audit(None, "chip_removed", actor=request.user, imei=t.imei)
        t.delete()
        return R({"ok": True})


class ChipRepairView(APIView):
    """Open a new pairing window (the SMS setup was not done in time)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk, manage=True)
        if err:
            return err
        if t.state != "paired":
            t.state = "pending"
            t.pair_expires_at = timezone.now() + timedelta(
                minutes=VS.vcfg()["pair_window_min"])
            t.save(update_fields=["state", "pair_expires_at", "updated_at"])
        return R({"ok": True, "chip": CS.chip_json(t, request.user)})


class ChipHistoryView(APIView):
    """Guardian-only location history (owner + valid guardians), last 48 h."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk)
        if err:
            return err
        try:
            hours = int(request.GET.get("hours") or 24)
        except ValueError:
            hours = 24
        return R({"points": CS.history(t, hours), "history_hours": CS.HISTORY_HOURS})


class ChipFindView(APIView):
    """chipbuy2: FIND NOW — the chip sends a fix every 10 s for 10 minutes
    (owner or a guardian; once per 10 minutes). Honest: 'acked' only when the
    chip itself replied OK; many cheap models ignore interval commands."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        t, err = _load(request, pk)
        if err:
            return err
        ok, reason = CS.start_find(t, request.user)
        if not ok:
            return R({"ok": False, "reason": reason,
                      "chip": CS.chip_json(t, request.user)}, status=409)
        return R({"ok": True, "chip": CS.chip_json(t, request.user)})


class BuyLinksView(APIView):
    """chipbuy2: GET /app/buy-links[?category=chip] — the owner's own shop
    links (Owner Admin -> Buy links). No prices, links only."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from . import buy_links as BL
        cat = request.GET.get("category") or None
        if cat is not None and cat not in BL.CATEGORIES:
            return R({"ok": False, "reason": "bad_category"}, status=400)
        return R(BL.public(cat))
