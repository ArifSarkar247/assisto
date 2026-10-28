"""
Kids Watch + Child School Mode HTTP API (owner idea 2, 28 Oct). Behind the
NEW flag `kids_watch` (OFF; owner / staff / allow-listed testers preview)
until the owner's real-watch test. The child's privacy controls (see who
watches, one-tap stop, delete history) are NEVER flag-gated.

  GET  /kids-watch/config                       server, SMS steps, prices, free list
  GET  /kids-watch/watches                      mine + shared with me
  POST /kids-watch/watches                      {code, child_name, guardian_ids?,
                                                 sos_numbers?, child_user_id?} -> pending
  GET|PATCH|DELETE /kids-watch/watches/<id>
  POST /kids-watch/watches/<id>/repair          new pairing window
  POST /kids-watch/watches/<id>/command         {kind: locate_now|find_watch}
  GET  /kids-watch/watches/<id>/history?hours=  full mode only
  GET  /kids-watch/watches/<id>/voice           voice notes (both directions)
  POST /kids-watch/watches/<id>/voice           {audio_b64} AMR-NB reply -> TK push
  GET  /kids-watch/voice/<id>/audio             decrypted bytes (marks heard)
  POST /kids-watch/voice/<id>/transcript        paid plans only
  DELETE /kids-watch/voice/<id>
  GET|POST /school-mode/plans                   owner side
  GET|PATCH|DELETE /school-mode/plans/<id>
  GET  /school-mode/mine                        the child's side (never gated)
  POST /school-mode/plans/<id>/accept|stop|pause-today|resume-today
  POST /school-mode/plans/<id>/checkin          {kind, lat?, lng?, audio_b64?, mime?}
  GET  /school-mode/plans/<id>/events,  POST /school-mode/plans/<id>/events/clear
  GET  /school-mode/places                      my saved places (home / school picks)

NO REMOTE LISTENING: the command endpoint accepts only locate_now and
find_watch; everything a watch is told is built by
tracker.protocols.watch.command_content(), which refuses MONITOR & co.
"""
import base64
import binascii
import re
from datetime import timedelta

from django.conf import settings
from django.http import HttpResponse
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import kidswatch_service as KW
from .logic import school_mode as SM

R = Response
FLAG = "kids_watch"
MAX_PLANS_PER_USER = 6
PHONE_RE = re.compile(r"^\+?\d{6,15}$")


def flag_on(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:
        return False


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _iso(dt):
    return dt.isoformat() if dt else None


def _b64(raw, cap):
    try:
        data = base64.b64decode(str(raw or ""), validate=True)
    except (binascii.Error, ValueError):
        return None
    return data if 0 < len(data) <= cap else None


def server_info():
    host = getattr(settings, "TRACKER_PUBLIC_HOST", "track.lifeassisto.com")
    port = int(getattr(settings, "TRACKER_PUBLIC_PORT", 5023))
    return {"host": host, "port": port}


def sms_steps(host, port, password="123456"):
    """The SMS the parent sends FROM their own phone TO the watch's SIM.
    Never contains a listening command."""
    pw = password or "123456"
    return [
        {"step": "check", "sms": "pw,%s,ts#" % pw},
        {"step": "server", "sms": "pw,%s,ip,%s,%d#" % (pw, host, port)},
        {"step": "timezone", "sms": "pw,%s,lz,1,6#" % pw},
        {"step": "interval", "sms": "pw,%s,upload,600#" % pw},
        {"step": "new_password", "sms": "pw,%s,pw,<NEW 6 DIGITS>#" % pw},
    ]


# --------------------------------------------------------------- watches

def _watch_json(w, user, now):
    online = bool(w.last_seen_at and (now - w.last_seen_at).total_seconds() < 900)
    plan = KW._plan_of(w)
    out = {"id": w.id, "child_name": w.child_name, "code_tail": w.imei[-4:],
           "state": w.state, "mine": w.owner_id == user.id, "maker": w.maker,
           "mode": "full" if KW.full_mode(w, now) else "safety_only",
           "billed_until": _iso(w.billed_until), "online": online,
           "last_seen_at": _iso(w.last_seen_at), "battery": w.battery, "steps": w.steps,
           "interval_s": w.interval_s, "phase": w.phase,
           "pair_expires_at": _iso(w.pair_expires_at),
           "live": ({"lat": w.last_lat, "lng": w.last_lng, "at": _iso(w.last_fix_at),
                     "acc_m": w.last_acc_m, "source": w.last_source}
                    if w.last_lat is not None else None),
           "school_plan_id": plan.id if plan else None}
    if w.owner_id == user.id:
        from .models import User
        out["guardians"] = [{"id": u.id, "name": u.name or ""} for u in
                            User.objects.filter(pk__in=KW.clean_guardians(
                                w.owner, w.guardian_ids))]
        out["sos_numbers"] = list(w.sos_numbers or [])
        out["code"] = w.imei
        out["commands"] = [{"id": c.id, "kind": c.kind, "state": c.state,
                            "error": c.error, "at": _iso(c.created_at)}
                           for c in w.commands.order_by("-id")[:8]]
    return out


def _load_watch(request, pk, manage=False):
    from .models import KidsWatch
    w = KidsWatch.objects.filter(pk=pk).select_related("owner").first()
    if w is None or not KW.can_view_watch(request.user, w):
        return None, R({"ok": False, "reason": "not_found"}, status=404)
    if manage and w.owner_id != request.user.id:
        return None, R({"ok": False, "reason": "forbidden"}, status=403)
    return w, None


def _clean_sos(raw):
    out = []
    for p in raw or []:
        s = "".join(ch for ch in str(p) if ch.isdigit() or ch == "+")
        if s:
            if not PHONE_RE.match(s):
                raise ValueError("bad_phone")
            out.append(s)
    return out[:3]


class ConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        srv = server_info()
        return R({"enabled": flag_on(request.user), "server": srv,
                  "sms": sms_steps(srv["host"], srv["port"]),
                  "month_credits": KW.month_credits(),
                  "pair_window_min": KW.PAIR_WINDOW_MIN,
                  "voice_days": KW.VOICE_DAYS, "retention_days": KW.RETENTION_DAYS,
                  "transcript_credits": _transcript_credits(),
                  "free_always": ["sos", "school_alerts", "last_location",
                                  "phone_checkin", "find_watch"],
                  "transport_note": "plain_tcp_device_leg",
                  "no_remote_listening": True})


def _transcript_credits():
    from . import billing
    from .logic import pricing
    try:
        return pricing.credits_for(KW.TRANSCRIPT_ACTION, 1, billing.cfg())
    except Exception:
        return 0


class WatchListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import KidsWatch
        if not flag_on(request.user):
            return _off()
        now = timezone.now()
        own = list(KidsWatch.objects.filter(owner=request.user))
        qs = KidsWatch.objects.exclude(owner=request.user).select_related("owner")
        if _json_contains_ok():
            qs = qs.filter(guardian_ids__contains=[request.user.id])
        shared = [w for w in qs[:2000] if KW.can_view_watch(request.user, w)]
        return R({"watches": [_watch_json(w, request.user, now) for w in own + shared],
                  "month_credits": KW.month_credits()})

    def post(self, request):
        from .models import KidsWatch, User
        if not flag_on(request.user):
            return _off()
        d = request.data or {}
        code = KW.normalize_id(d.get("code"))
        if not KW.id_valid(code):
            return R({"ok": False, "reason": "bad_code"}, status=400)
        name = str(d.get("child_name") or "").strip()[:60]
        if not name:
            return R({"ok": False, "reason": "name_required"}, status=400)
        if KidsWatch.objects.filter(owner=request.user).count() >= KW.MAX_WATCHES_PER_USER:
            return R({"ok": False, "reason": "limit"}, status=409)
        try:
            sos = _clean_sos(d.get("sos_numbers"))
        except ValueError:
            return R({"ok": False, "reason": "bad_phone"}, status=400)
        child = None
        if d.get("child_user_id"):
            cid = int(d.get("child_user_id") or 0)
            if not KW._peer_ok(request.user, cid):
                return R({"ok": False, "reason": "child_not_in_circle"}, status=400)
            child = User.objects.filter(pk=cid).first()
        now = timezone.now()
        w = KidsWatch.objects.filter(imei=code).first()
        if w is not None and w.owner_id != request.user.id:
            return R({"ok": False, "reason": "in_use"}, status=409)
        if w is None:
            w = KidsWatch(owner=request.user, imei=code)
        w.child_name = name
        w.child_user = child
        w.guardian_ids = KW.clean_guardians(request.user, d.get("guardian_ids"))
        w.sos_numbers = sos
        if w.state != "paired":
            w.state = "pending"
            w.pair_expires_at = now + timedelta(minutes=KW.PAIR_WINDOW_MIN)
        w.save()
        srv = server_info()
        return R({"ok": True, "watch": _watch_json(w, request.user, now),
                  "sms": sms_steps(srv["host"], srv["port"])}, status=201)


def _json_contains_ok():
    from django.db import connection
    return connection.vendor == "postgresql"


class WatchDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk)
        if err:
            return err
        return R({"watch": _watch_json(w, request.user, timezone.now())})

    def patch(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk, manage=True)
        if err:
            return err
        d = request.data or {}
        if "child_name" in d:
            name = str(d.get("child_name") or "").strip()[:60]
            if not name:
                return R({"ok": False, "reason": "name_required"}, status=400)
            w.child_name = name
        if "guardian_ids" in d:
            w.guardian_ids = KW.clean_guardians(request.user, d.get("guardian_ids"))
        if "sos_numbers" in d:
            try:
                w.sos_numbers = _clean_sos(d.get("sos_numbers"))
            except ValueError:
                return R({"ok": False, "reason": "bad_phone"}, status=400)
            if w.state == "paired":
                KW.queue(w, "sos_numbers", {"numbers": w.sos_numbers}, actor=request.user)
        w.save()
        return R({"ok": True, "watch": _watch_json(w, request.user, timezone.now())})

    def delete(self, request, pk):
        """Remove the watch and ALL its data (positions, voice, commands)."""
        w, err = _load_watch(request, pk, manage=True)
        if err:
            return err
        for note in w.voice_notes.all():
            KW.delete_audio(note)
        w.delete()
        return R({"ok": True})


class WatchRepairView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk, manage=True)
        if err:
            return err
        w.state = "pending"
        w.pair_expires_at = timezone.now() + timedelta(minutes=KW.PAIR_WINDOW_MIN)
        w.save(update_fields=["state", "pair_expires_at", "updated_at"])
        return R({"ok": True, "watch": _watch_json(w, request.user, timezone.now())})


USER_COMMANDS = ("locate_now", "find_watch")


class WatchCommandView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk)
        if err:
            return err
        kind = str((request.data or {}).get("kind") or "")
        if kind not in USER_COMMANDS:
            return R({"ok": False, "reason": "bad_kind"}, status=400)
        if w.state != "paired":
            return R({"ok": False, "reason": "not_paired"}, status=409)
        c = KW.queue(w, kind, actor=request.user)
        return R({"ok": True, "command": {"id": c.id, "kind": c.kind, "state": c.state}},
                 status=201)


class WatchHistoryView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk)
        if err:
            return err
        now = timezone.now()
        if not KW.full_mode(w, now):
            return R({"ok": False, "reason": "safety_only", "points": [],
                      "month_credits": KW.month_credits()}, status=402)
        try:
            hours = max(1, min(24 * KW.RETENTION_DAYS, int(request.GET.get("hours") or 24)))
        except ValueError:
            hours = 24
        pts = w.positions.filter(at__gte=now - timedelta(hours=hours)).order_by("at")[:3000]
        return R({"points": [{"at": _iso(p.at), "lat": p.lat, "lng": p.lng,
                              "source": p.source, "acc_m": p.acc_m} for p in pts]})


def _note_json(n, user):
    return {"id": n.id, "direction": n.direction, "at": _iso(n.at),
            "duration_s": n.duration_s, "lat": n.lat, "lng": n.lng, "state": n.state,
            "heard": user.id in (n.heard_by or []), "mime": n.mime,
            "transcript": n.transcript if n.transcript_state == "done" else "",
            "from_me": n.sender_id == user.id, "expires_at": _iso(n.expires_at)}


class WatchVoiceView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk)
        if err:
            return err
        return R({"notes": [_note_json(n, request.user)
                            for n in w.voice_notes.order_by("-at")[:100]],
                  "voice_days": KW.VOICE_DAYS})

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        w, err = _load_watch(request, pk)
        if err:
            return err
        audio = _b64((request.data or {}).get("audio_b64"), KW.MAX_VOICE_BYTES)
        if audio is None:
            return R({"ok": False, "reason": "bad_audio"}, status=400)
        note, reason = KW.voice_down(w, request.user, audio)
        if note is None:
            return R({"ok": False, "reason": reason},
                     status=402 if reason == "safety_only" else 400)
        return R({"ok": True, "note": _note_json(note, request.user)}, status=201)


def _load_note(request, pk):
    from .models import KidsVoiceNote
    n = KidsVoiceNote.objects.filter(pk=pk).select_related("watch", "plan").first()
    if n is None:
        return None
    if n.watch_id and KW.can_view_watch(request.user, n.watch):
        return n
    if n.plan_id and KW.can_view_plan(request.user, n.plan):
        return n
    return None


class VoiceAudioView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        n = _load_note(request, pk)
        if n is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        data = KW.read_audio(n)
        if not data:
            return R({"ok": False, "reason": "gone"}, status=410)
        if request.user.id not in (n.heard_by or []):
            n.heard_by = list(n.heard_by or []) + [request.user.id]
            n.save(update_fields=["heard_by"])
        resp = HttpResponse(data, content_type=n.mime or "application/octet-stream")
        resp["Cache-Control"] = "no-store"
        return resp


class VoiceTranscriptView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        n = _load_note(request, pk)
        if n is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        res = KW.transcript(n, request.user)
        if not res.get("ok"):
            code = {"paid_only": 402, "daily_cap": 429, "insufficient": 402,
                    "no_key": 503}.get(res.get("reason"), 400)
            return R(res, status=code)
        return R(res)


class VoiceDeleteView(APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, pk):
        n = _load_note(request, pk)
        if n is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        owner_id = n.watch.owner_id if n.watch_id else n.plan.owner_id
        if request.user.id not in (owner_id, n.sender_id) and not (
                n.plan_id and n.plan.child_user_id == request.user.id):
            return R({"ok": False, "reason": "forbidden"}, status=403)
        KW.delete_note(n)
        return R({"ok": True})


# --------------------------------------------------------------- school mode

def _people(owner, ids):
    return [{"id": u.id, "name": u.name or "", "owner": u.id == owner.id}
            for u in KW.guardians(owner, ids)]


def _plan_json(p, user, now=None):
    now = now or timezone.now()
    try:
        cfg = SM.validate(p.config)
    except ValueError:
        cfg = None
    local = now.astimezone(KW.LOCAL_TZ)
    day = p.day if (p.day or {}).get("date") == local.date().isoformat() else {}
    out = {"id": p.id, "child_name": p.child_name, "enabled": p.enabled,
           "accepted": p.accepted_at is not None, "mode": "watch" if p.watch_id else "phone",
           "watch_id": p.watch_id, "i_am_child": p.child_user_id == user.id,
           "mine": p.owner_id == user.id, "config": cfg,
           "watchers": _people(p.owner, p.watcher_ids),
           "today": {"state": day.get("state", "idle"),
                     "window": SM.window(cfg, local) if cfg else "off",
                     "paused": bool(day.get("paused")),
                     "left_home_at": day.get("left_home_at"),
                     "arrived_school_at": day.get("arrived_school_at"),
                     "left_school_at": day.get("left_school_at"),
                     "home_at": day.get("home_at"),
                     "ask": day.get("ask") or {},
                     "alerts": day.get("alerts") or {}},
           "last_known": p.last_known or None}
    if cfg:
        t = SM.times(cfg, local)
        out["today"].update(school_day=SM.is_school_day(cfg, local),
                            arrive_due=_iso(t["arrive_due"]), home_due=_iso(t["home_due"]))
    return out


def _load_plan(request, pk, manage=False):
    from .models import SchoolPlan
    p = SchoolPlan.objects.filter(pk=pk).select_related("owner", "child_user",
                                                        "watch").first()
    if p is None or not KW.can_view_plan(request.user, p):
        return None, R({"ok": False, "reason": "not_found"}, status=404)
    if manage and p.owner_id != request.user.id:
        return None, R({"ok": False, "reason": "forbidden"}, status=403)
    return p, None


def _config_from(d, base=None):
    cfg = dict(base or {})
    for k in ("start", "end", "commute_min", "late_min", "days", "home", "school"):
        if k in d:
            cfg[k] = d[k]
    if "class_mode" in d:
        cfg["class_mode"] = bool(d["class_mode"])
    return SM.validate(cfg)


def _class_mode(plan, user):
    """Watch 'class mode' (SILENCETIME): no calls / games during school
    hours. SOS keeps working on these watches in class mode."""
    if not plan.watch_id or plan.watch.state != "paired":
        return None
    cfg = plan.config or {}
    if cfg.get("class_mode"):
        return KW.queue(plan.watch, "class_mode",
                        {"start": cfg["start"], "end": cfg["end"]}, actor=user)
    return KW.queue(plan.watch, "class_mode_off", actor=user)


def _place_from_saved(user, pid):
    from .models import SavedPlace
    sp = SavedPlace.objects.filter(user=user, pk=pid).first()
    if sp is None or sp.lat is None:
        return None
    return {"lat": sp.lat, "lng": sp.lng, "name": sp.label or sp.name}


class PlacesView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import SavedPlace
        return R({"places": [{"id": s.id, "label": s.label, "name": s.name,
                              "lat": s.lat, "lng": s.lng}
                             for s in SavedPlace.objects.filter(user=request.user,
                                                                lat__isnull=False)[:50]]})


class PlanListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import SchoolPlan
        if not flag_on(request.user):
            return _off()
        now = timezone.now()
        mine = list(SchoolPlan.objects.filter(owner=request.user)
                    .select_related("owner", "child_user", "watch"))
        return R({"plans": [_plan_json(p, request.user, now) for p in mine]})

    def post(self, request):
        from .models import SchoolPlan, KidsWatch, User
        if not flag_on(request.user):
            return _off()
        d = dict(request.data or {})
        if SchoolPlan.objects.filter(owner=request.user).count() >= MAX_PLANS_PER_USER:
            return R({"ok": False, "reason": "limit"}, status=409)
        for k in ("home", "school"):
            if d.get(k + "_place_id"):
                d[k] = _place_from_saved(request.user, d.get(k + "_place_id"))
        try:
            cfg = _config_from(d)
        except ValueError as e:
            return R({"ok": False, "reason": str(e)}, status=400)
        if not cfg["home"] or not cfg["school"]:
            return R({"ok": False, "reason": "places_required"}, status=400)
        watch, child = None, None
        if d.get("watch_id"):
            watch = KidsWatch.objects.filter(pk=d.get("watch_id"), owner=request.user).first()
            if watch is None:
                return R({"ok": False, "reason": "watch_not_found"}, status=400)
            if SchoolPlan.objects.filter(watch=watch).exists():
                return R({"ok": False, "reason": "watch_has_plan"}, status=409)
        elif d.get("child_user_id"):
            cid = int(d.get("child_user_id") or 0)
            if not KW._peer_ok(request.user, cid):
                return R({"ok": False, "reason": "child_not_in_circle"}, status=400)
            child = User.objects.filter(pk=cid).first()
        else:
            return R({"ok": False, "reason": "watch_or_child_required"}, status=400)
        name = str(d.get("child_name") or (watch.child_name if watch else "")
                   or (child.name if child else "")).strip()[:60]
        now = timezone.now()
        p = SchoolPlan.objects.create(
            owner=request.user, watch=watch, child_user=child or (
                watch.child_user if watch else None),
            child_name=name or "?", config=cfg,
            watcher_ids=KW.clean_guardians(request.user, d.get("watcher_ids")),
            # a watch plan runs at once (the parent set the watch up); a PHONE
            # plan waits until the child accepted it on their own phone
            accepted_at=now if watch else None)
        if child is not None and watch is None:
            KW._send([child], "স্কুল-মোডের অনুরোধ", "School mode request",
                     "%s আপনার জন্য স্কুল-মোড চালু করতে চান। দেখে রাজি হলে চালু হবে।"
                     % (request.user.name or ""),
                     "%s would like to turn on School Mode for you. It starts only "
                     "if you agree." % (request.user.name or ""),
                     {"plan_id": p.id, "event": "invite"}, family_alert=False,
                     route="school_mode")
        if watch is not None:
            KW.apply_phase(watch, now, force=True)
            _class_mode(p, request.user)
        return R({"ok": True, "plan": _plan_json(p, request.user, now)}, status=201)


class PlanDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        p, err = _load_plan(request, pk)
        if err:
            return err
        return R({"plan": _plan_json(p, request.user)})

    def patch(self, request, pk):
        if not flag_on(request.user):
            return _off()
        p, err = _load_plan(request, pk, manage=True)
        if err:
            return err
        d = dict(request.data or {})
        for k in ("home", "school"):
            if d.get(k + "_place_id"):
                d[k] = _place_from_saved(request.user, d.get(k + "_place_id"))
        try:
            cfg = _config_from(d, p.config)
        except ValueError as e:
            return R({"ok": False, "reason": str(e)}, status=400)
        if not cfg["home"] or not cfg["school"]:
            return R({"ok": False, "reason": "places_required"}, status=400)
        p.config = cfg
        if "watcher_ids" in d:
            p.watcher_ids = KW.clean_guardians(request.user, d.get("watcher_ids"))
        if "enabled" in d:
            p.enabled = bool(d.get("enabled"))
        if "child_name" in d and str(d.get("child_name") or "").strip():
            p.child_name = str(d["child_name"]).strip()[:60]
        p.save()
        if "class_mode" in d or "start" in d or "end" in d:
            _class_mode(p, request.user)
        return R({"ok": True, "plan": _plan_json(p, request.user)})

    def delete(self, request, pk):
        """The owner (or the child) removes the plan and its whole history."""
        p, err = _load_plan(request, pk)
        if err:
            return err
        if request.user.id not in (p.owner_id, p.child_user_id):
            return R({"ok": False, "reason": "forbidden"}, status=403)
        for note in p.voice_notes.all():
            KW.delete_audio(note)
        p.delete()
        return R({"ok": True})


class MyPlansView(APIView):
    """The CHILD's side: every plan about me, who sees it, and the button.
    Never flag-gated (transparency + one-tap stop must always work)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import SchoolPlan
        now = timezone.now()
        return R({"plans": [_plan_json(p, request.user, now) for p in
                            SchoolPlan.objects.filter(child_user=request.user)
                            .select_related("owner", "child_user", "watch")]})


class PlanActionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk, action):
        p, err = _load_plan(request, pk)
        if err:
            return err
        now = timezone.now()
        is_child = p.child_user_id == request.user.id
        is_owner = p.owner_id == request.user.id
        if action == "accept":
            if not is_child:
                return R({"ok": False, "reason": "forbidden"}, status=403)
            p.accepted_at = p.accepted_at or now
            p.enabled = True
            p.save(update_fields=["accepted_at", "enabled", "updated_at"])
            KW._send([p.owner], "স্কুল-মোড চালু হয়েছে", "School mode is on",
                     "%s রাজি হয়েছে। স্কুল-মোড চালু।" % p.child_name,
                     "%s agreed. School mode is on." % p.child_name,
                     {"plan_id": p.id, "event": "accepted"}, family_alert=False)
        elif action == "stop":
            # one tap, child or owner, never gated; the owner is told
            if not (is_child or is_owner):
                return R({"ok": False, "reason": "forbidden"}, status=403)
            p.enabled = False
            p.save(update_fields=["enabled", "updated_at"])
            if is_child:
                KW._send([p.owner], "স্কুল-মোড বন্ধ করা হয়েছে", "School mode was turned off",
                         "%s স্কুল-মোড বন্ধ করেছে।" % p.child_name,
                         "%s turned School Mode off." % p.child_name,
                         {"plan_id": p.id, "event": "stopped_by_child"}, family_alert=False)
        elif action in ("pause-today", "resume-today"):
            if not (is_child or is_owner):
                return R({"ok": False, "reason": "forbidden"}, status=403)
            local = now.astimezone(KW.LOCAL_TZ)
            day = SM.ensure_day(p.day, local)
            day["paused"] = action == "pause-today"
            p.day = day
            p.save(update_fields=["day", "updated_at"])
        else:
            return R({"ok": False, "reason": "bad_action"}, status=400)
        return R({"ok": True, "plan": _plan_json(p, request.user, now)})


class PlanCheckinView(APIView):
    """The child's ONE big button (phone). Location of that moment only if
    the child allowed it; optional voice note. Free on every plan."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        p, err = _load_plan(request, pk)
        if err:
            return err
        if p.child_user_id != request.user.id:
            return R({"ok": False, "reason": "forbidden"}, status=403)
        if not p.enabled or p.accepted_at is None:
            return R({"ok": False, "reason": "not_active"}, status=409)
        d = request.data or {}
        kind = str(d.get("kind") or "")
        if kind not in SM.CHECKINS:
            return R({"ok": False, "reason": "bad_kind"}, status=400)
        lat = lng = None
        try:
            if d.get("lat") is not None and d.get("lng") is not None:
                lat, lng = float(d["lat"]), float(d["lng"])
                if not (-90 <= lat <= 90 and -180 <= lng <= 180):
                    raise ValueError
        except (TypeError, ValueError):
            return R({"ok": False, "reason": "bad_location"}, status=400)
        audio = None
        if d.get("audio_b64"):
            audio = _b64(d.get("audio_b64"), KW.MAX_VOICE_BYTES * 2)
            if audio is None:
                return R({"ok": False, "reason": "bad_audio"}, status=400)
        mime = str(d.get("mime") or "audio/mp4")
        if mime not in ("audio/mp4", "audio/aac", "audio/amr", "audio/ogg"):
            mime = "audio/mp4"
        try:
            evs = KW.phone_checkin(p, kind, lat, lng, audio, mime)
        except ValueError as e:
            return R({"ok": False, "reason": str(e)}, status=400)
        p.refresh_from_db()
        return R({"ok": True, "events": [e["kind"] for e in evs],
                  "plan": _plan_json(p, request.user)})


class PlanEventsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        p, err = _load_plan(request, pk)
        if err:
            return err
        return R({"events": [{"id": e.id, "kind": e.kind, "at": _iso(e.at), "lat": e.lat,
                              "lng": e.lng, "source": e.source,
                              "voice_id": e.voice_id,
                              "place_match": (e.detail or {}).get("place_match")}
                             for e in p.events.order_by("-at")[:100]]})

    def post(self, request, pk):
        """POST .../events/clear — the child or the owner deletes the history
        (and its voice notes). Never flag-gated."""
        p, err = _load_plan(request, pk)
        if err:
            return err
        if request.user.id not in (p.owner_id, p.child_user_id):
            return R({"ok": False, "reason": "forbidden"}, status=403)
        n = p.events.count()
        p.events.all().delete()
        for note in p.voice_notes.all():
            KW.delete_note(note)
        p.last_known = {}
        p.save(update_fields=["last_known", "updated_at"])
        return R({"ok": True, "deleted": n})
