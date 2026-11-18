"""
views_sjduring.py — sjduring: Safe Journey V2 DURING-the-trip endpoints.
Rules: core/journey_during.py. Spec: owner_actions/SAFE_JOURNEY_V2_SPEC_BN.md.

  GET  /journey/<pk>/during          traveller: state + the PRIVATE ask + PIN wait
  POST /journey/<pk>/answer          traveller: extend | share | ok | danger
  POST /journey/<pk>/arrive-pin      traveller: safe PIN / danger PIN on arrival
  POST /journey/<pk>/danger-audio    traveller: the 30 s clip after a danger PIN
  GET  /journey/<pk>/danger-audio    watcher: play it
  GET/POST /journey/arrive-pin-pref  traveller: ask the PIN on every arrival
  GET  /journey/watch-board          watcher: active (with count) + finished
"""
import base64
import secrets

from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import journey_during as JDUR
from . import journey_watch as JW
from . import push as PUSH
from .models import DuressPin, Journey, JourneyWatcher


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _mine(request, pk):
    return Journey.objects.filter(traveller=request.user, pk=pk).first()


def _arrived_face():
    """What the traveller's screen sees after ANY PIN arrival (identical for
    the safe and the danger PIN — an onlooker can never tell)."""
    return {"ok": True, "status": "arrived", "state": "arrived"}


def traveller_view(j, now):
    d = j.during or {}
    if d.get("cover") or j.status != "active":
        return {"id": j.id, "status": "arrived" if d.get("cover") else j.status,
                "state": "arrived" if d.get("cover") or j.status == "arrived" else j.status}
    st = JDUR.state_of(j, now)
    configured, always = JDUR.pin_prefs(j.traveller)
    out = {"id": j.id, "status": j.status, "state": st.get("state"),
           "state_minutes": st.get("minutes") or st.get("stopped_min"),
           "distance_m": st.get("distance_m"), "battery": st.get("battery"),
           "near_note": bool(st.get("near_note")), "night": bool(st.get("night")),
           "pin_configured": configured, "arrive_always": always,
           "extend_default": JDUR.EXTEND_DEFAULT,
           "earliest_at": JDUR._iso(JDUR.earliest_for(j)),
           "pin_wait": d.get("pin_wait") or None}
    ask = d.get("ask") or {}
    if ask and not ask.get("answered") and ask.get("kind") != "phone_off":
        at = JDUR._dt(ask.get("at"))
        out["ask"] = {
            "id": ask.get("id"), "kind": ask.get("kind"), "at": ask.get("at"),
            "deadline": JDUR._iso(at + timezone.timedelta(minutes=JDUR.ASK_MIN)) if at else None,
            "amber": bool(ask.get("amber_at")),
            "from": ask.get("from"),
            "to": ({"lat": ask["lat"], "lng": ask["lng"]}
                   if ask.get("lat") is not None else None),
            "minutes": ask.get("minutes"),
        }
    return out


class DuringView(APIView):
    def get(self, request, pk):
        j = _mine(request, pk)
        if j is None:
            return _nf()
        return Response(traveller_view(j, timezone.now()))


class AnswerView(APIView):
    """The private screen's four buttons. Watchers learn only what the
    traveller chose to tell: Time extended (no place), or the stop place."""
    def post(self, request, pk):
        j = _mine(request, pk)
        if j is None or j.status != "active":
            return _nf()
        data = request.data or {}
        action = str(data.get("action") or "")
        if action not in ("extend", "share", "ok", "danger"):
            return Response({"detail": "bad action"}, status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        d, was_amber = JDUR.answer_ask(j.during, action, now)
        j.during = d
        j.responded_at = now
        j.last_activity_at = now
        fields = ["during", "responded_at", "last_activity_at"]
        if action == "extend":
            try:
                mins = int(data.get("minutes") or JDUR.EXTEND_DEFAULT)
            except (TypeError, ValueError):
                mins = JDUR.EXTEND_DEFAULT
            mins = max(JW.EXTEND_MIN, min(180, mins))
            j.eta = max(j.eta or now, now) + timezone.timedelta(minutes=mins)
            j.expires_at = max(j.expires_at or now, j.eta + timezone.timedelta(hours=12))
            j.extended_count += 1
            j.ask_sent_at, j.escalated_at, j.escalations = None, None, 0
            fields += ["eta", "expires_at", "extended_count", "ask_sent_at",
                       "escalated_at", "escalations"]
            j.save(update_fields=fields)
            # watchers see ONLY "Time extended" — never where or why
            JW.emit(j, "extended", key="d%s" % j.extended_count,
                    payload={"minutes": mins, "lat": None, "lng": None})
        elif action == "share":
            j.save(update_fields=fields)
            fx = JW.fix_of(j)
            JW.emit(j, "stop_place", key=str(int(now.timestamp())),
                    payload={"lat": fx[0] if fx else None, "lng": fx[1] if fx else None})
        else:
            j.save(update_fields=fields)
        if was_amber and action in ("extend", "share", "ok"):
            JW.emit(j, "ok_again", key="d:%s" % now.isoformat(),
                    payload={"lat": None, "lng": None})
            JW.clear_urgent(j)
        # 'danger': the app opens the SOS screen at once (fcsos), which
        # sends the SOS with its own countdown — never sent twice
        return Response({"ok": True, "action": action,
                         **({"eta": j.eta.isoformat()} if j.eta else {})})


def _classify(request, pin):
    from .views_build61 import _classify_pin
    return _classify_pin(request, pin)


def danger_cover(user, j, now):
    """The danger PIN (here or in the "I've arrived" PIN box, sjproof): the
    traveller's screen says Arrived; the trip silently stays live for the
    watchers (COVER_MIN), red + the SOS with the last location; the phone
    then records 30 s of audio (answer k=1)."""
    d = dict(j.during or {})
    d.pop("pin_wait", None)
    fx = JW.fix_of(j)
    d.update({"pin": "danger", "cover": True,
              "cover_until": JDUR._iso(now + timezone.timedelta(minutes=JDUR.COVER_MIN))})
    j.during = d
    j.sos_active, j.silent = True, True
    keep = now + timezone.timedelta(hours=24)
    if not j.expires_at or j.expires_at < keep:
        j.expires_at = keep
    j.save(update_fields=["during", "sos_active", "silent", "expires_at"])
    JW.emit(j, "danger_pin", key="1", payload={"level": "red"})
    PUSH.hook_sos(user, lat=fx[0] if fx else None, lng=fx[1] if fx else None,
                  silent=True, journey_id=j.id, source="journey_danger_pin")


class ArrivePinView(APIView):
    """POST {pin}. Safe PIN -> Arrived, watchers: "Confirmed with PIN".
    Danger PIN -> the SAME answer on this phone; watchers silently get red
    + live location (COVER_MIN more minutes) + the SOS, and the app quietly
    records 30 s of audio (k=1)."""
    def post(self, request, pk):
        j = _mine(request, pk)
        if j is None:
            return _nf()
        if j.status != "active" or (j.during or {}).get("cover"):
            return Response(_arrived_face())
        action = _classify(request, (request.data or {}).get("pin"))
        if action in ("none",):
            return Response({"ok": False, "pin": "not_set"}, status=status.HTTP_400_BAD_REQUEST)
        if action == "required":
            return Response({"ok": False, "pin": "required"}, status=status.HTTP_400_BAD_REQUEST)
        if action == "locked":
            return Response({"ok": False, "pin": "locked"}, status=status.HTTP_429_TOO_MANY_REQUESTS)
        if action == "wrong":
            return Response({"ok": False, "pin": "wrong"}, status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        d = dict(j.during or {})
        d.pop("pin_wait", None)
        if action == "duress":
            danger_cover(request.user, j, now)
            return Response({**_arrived_face(), "k": 1})
        d["pin"] = "ok"
        b = list(d.get("badges") or [])
        if "pin_ok" not in b:
            b.append("pin_ok")
        d["badges"] = b
        j.during = d
        try:   # watchers: "Confirmed with PIN" (qjourney's on_arrived takes a payload)
            JW.on_arrived(j, now, kind="arrived", payload={"confirmed_pin": True})
        except TypeError:
            JW.on_arrived(j, now)
        j.save()
        from . import guardian_journey as GJ
        GJ.on_journey_arrived(j, now)
        return Response({**_arrived_face(), "k": 0})


class DangerAudioView(APIView):
    def post(self, request, pk):
        j = _mine(request, pk)
        d = dict((j.during or {}) if j else {})
        if j is None or d.get("pin") != "danger" or d.get("audio"):
            # identical, quiet answer: nothing to learn from it
            return Response({"ok": True})
        raw = str((request.data or {}).get("audio_b64") or "")
        try:
            blob = base64.b64decode(raw, validate=True)
        except Exception:
            return Response({"ok": True})
        if not blob or len(blob) > JDUR.AUDIO_MAX_BYTES:
            return Response({"ok": True})
        from django.core.files.base import ContentFile
        from django.core.files.storage import default_storage
        path = default_storage.save("journey_danger/%d_%s.m4a" % (j.id, secrets.token_hex(8)),
                                    ContentFile(blob))
        d["audio"] = path
        j.during = d
        j.save(update_fields=["during"])
        JW.emit(j, "danger_audio", key="1", payload={"level": "red"})
        return Response({"ok": True})

    def get(self, request, pk):
        j = Journey.objects.filter(pk=pk).select_related("traveller").first()
        if j is None or not JW.is_watcher(j, request.user):
            return _nf()
        path = (j.during or {}).get("audio")
        if not path or (j.expires_at and timezone.now() >= j.expires_at):
            return _nf()
        from django.core.files.storage import default_storage
        try:
            with default_storage.open(path, "rb") as f:
                blob = f.read()
        except Exception:
            return _nf()
        return Response({"audio_b64": base64.b64encode(blob).decode("ascii"),
                         "mime": "audio/mp4"})


class ArrivePinPrefView(APIView):
    def get(self, request):
        configured, always = JDUR.pin_prefs(request.user)
        return Response({"configured": configured, "always": always})

    def post(self, request):
        dp = DuressPin.objects.filter(user=request.user).first()
        if not (dp and dp.salt and dp.normal_hash):
            return Response({"detail": "pin_not_set"}, status=status.HTTP_400_BAD_REQUEST)
        dp.arrive_always = bool((request.data or {}).get("always"))
        dp.save(update_fields=["arrive_always"])
        return Response({"configured": True, "always": dp.arrive_always})


class WatchBoardView(APIView):
    """Active journeys (with a count — also shown on the Family screen) and
    finished ones (within the privacy window) with their badges."""
    def get(self, request):
        now = timezone.now()
        rows = (JourneyWatcher.objects
                .filter(member__peer_user=request.user, member__state="accepted",
                        member__blocked=False, journey__expires_at__gt=now)
                .select_related("journey", "journey__traveller")
                .order_by("-journey__created_at")[:30])
        active, finished, seen = [], [], set()
        # safety-plan: + a guarded child's trips (both guardians see them)
        for j in [w.journey for w in rows] + JW.guardian_child_journeys(request.user, now):
            if j.id in seen or (j.destination or {}).get("share"):
                continue
            seen.add(j.id)
            try:
                card = JDUR.board_card(j, request.user, now)
            except Exception:
                continue
            (active if card["status"] == "active" else finished).append(card)
        return Response({"count": len(active), "active": active, "finished": finished[:20]})
