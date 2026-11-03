"""carecall (owner order 4 Nov 01:50) — Care Call endpoints. Rules live in
core/carecall.py; every route is per-user and server-checked.

  GET  /carecall                    everything the screens need (mine)
  GET  /carecall/people             My Circle family I can pick (one tap)
  POST /carecall                    new {receiver_id, text, time, repeat, days?, date?, voice_b64?, voice_sec?}
  POST /carecall/<id>               edit (same fields + active / delete_voice)
  POST /carecall/<id>/delete
  GET  /carecall/<id>/voice         the setter's own recording (setter / accepted receiver)
  POST /carecall/consent            receiver {setter_id, accept}
  POST /carecall/quiet              receiver {start, end} ("" + "" = none)
  POST /carecall/ack                receiver {care_call_id, slot, action: done|snooze}
  POST /carecall/acks               receiver offline queue {acks: [...]} (max 50)
"""
from django.http import FileResponse
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import carecall as CC
from .i18n import pick, req_lang

_MSG = {
    "off": ("কেয়ার কল এখন বন্ধ আছে।", "Care Call is switched off right now."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "not_in_circle": ("এই মানুষটি আপনার My Circle-এর পরিবারে নেই। আগে My Circle-এ যোগ করুন।",
                      "This person is not in your My Circle family. Add them to My Circle first."),
    "receiver_stopped": ("উনি আপনার কেয়ার কল বন্ধ রেখেছেন। উনি আবার চালু করলে পাঠাতে পারবেন।",
                         "They have turned off Care Calls from you. You can send again once they turn it back on."),
    "limit_active": ("ফ্রিতে একসাথে সর্বোচ্চ {n}টি কেয়ার কল চালু রাখা যায়। একটা বন্ধ বা মুছে দিন।",
                     "You can keep up to {n} Care Calls on for free. Turn one off or delete it."),
    "text_required": ("কী মনে করাবেন লিখুন, অথবা নিজের গলায় রেকর্ড করুন।",
                      "Write what to remind, or record it in your own voice."),
    "text_too_long": ("লেখাটা একটু ছোট করুন (সর্বোচ্চ {n} অক্ষর)।",
                      "Please make the text shorter (up to {n} characters)."),
    "bad_time": ("সময় বেছে নিন।", "Pick a time."),
    "bad_repeat": ("কতবার বাজবে বেছে নিন।", "Pick how often it repeats."),
    "bad_days": ("অন্তত একটা দিন বেছে নিন।", "Pick at least one day."),
    "bad_voice": ("রেকর্ডটা পড়া গেল না। আবার রেকর্ড করুন।", "The recording could not be read. Please record again."),
    "voice_too_long": ("রেকর্ড সর্বোচ্চ {n} সেকেন্ড।", "The recording can be up to {n} seconds."),
    "bad_ack": ("উত্তরটা বোঝা গেল না।", "That answer could not be read."),
    "snooze_limit": ("আর পরে করা যাবে না — এখন করে 'হয়ে গেছে' চাপুন।",
                     "No more snoozes — please do it now and tap Done."),
    "bad_quiet": ("শুরু ও শেষের সময় দুটোই দিন।", "Give both a start and an end time."),
}
_CODE = {"not_found": status.HTTP_404_NOT_FOUND, "off": status.HTTP_404_NOT_FOUND,
         "not_in_circle": status.HTTP_404_NOT_FOUND,
         "receiver_stopped": status.HTTP_403_FORBIDDEN,
         "limit_active": status.HTTP_403_FORBIDDEN}


def refuse(request, reason):
    from .family_alerts import bn_num
    bn, en = _MSG.get(reason, _MSG["not_found"])
    lim = CC.limits()
    n = {"limit_active": lim["carecall_active_per_setter"],
         "text_too_long": lim["carecall_text_max_chars"],
         "voice_too_long": lim["carecall_voice_max_seconds"]}.get(reason)
    if n is not None:
        bn, en = bn.format(n=bn_num(n)), en.format(n=n)
    return Response({"ok": False, "reason": reason, "detail": pick(req_lang(request), bn, en)},
                    status=_CODE.get(reason, status.HTTP_400_BAD_REQUEST))


def feature_on(request):
    try:
        from . import feature_flags as FF
        from .i18n import is_play_flavour
        return FF.is_on(CC.FLAG, request.user, is_play_flavour(request))
    except Exception:  # noqa: BLE001 — registry default is ON
        return True


class _Base(APIView):
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        self._off = not feature_on(request)


class CareCallView(_Base):
    def get(self, request):
        if self._off:
            return refuse(request, "off")
        return Response(CC.mine(request.user))

    def post(self, request):
        if self._off:
            return refuse(request, "off")
        cc, link, err = CC.create(request.user, request.data or {})
        if err:
            return refuse(request, err)
        CC.CareCallLinkCache.reset()
        return Response({"ok": True, "care_call": CC.cc_dict(cc, request.user),
                         "link": link.status}, status=status.HTTP_201_CREATED)


class CareCallPeopleView(_Base):
    def get(self, request):
        if self._off:
            return refuse(request, "off")
        return Response({"results": CC.people(request.user)})


class CareCallItemView(_Base):
    def post(self, request, pk):
        if self._off:
            return refuse(request, "off")
        cc, err = CC.update(request.user, pk, request.data or {})
        if err:
            return refuse(request, err)
        CC.CareCallLinkCache.reset()
        return Response({"ok": True, "care_call": CC.cc_dict(cc, request.user)})


class CareCallDeleteView(_Base):
    def post(self, request, pk):
        if not CC.delete(request.user, pk):
            return refuse(request, "not_found")
        return Response({"ok": True})


class CareCallVoiceView(_Base):
    def get(self, request, pk):
        cc = CC.voice_for(request.user, pk)
        if cc is None:
            return refuse(request, "not_found")
        try:
            return FileResponse(cc.voice.open("rb"), content_type="audio/mp4")
        except Exception:  # noqa: BLE001 — missing file on disk
            return refuse(request, "not_found")


class CareCallConsentView(_Base):
    def post(self, request):
        try:
            sid = int((request.data or {}).get("setter_id"))
        except (TypeError, ValueError):
            return refuse(request, "not_found")
        link = CC.decide(request.user, sid, bool((request.data or {}).get("accept")))
        if link is None:
            return refuse(request, "not_found")
        return Response({"ok": True, "status": link.status})


class CareCallQuietView(_Base):
    def post(self, request):
        d = request.data or {}
        if not CC.set_quiet(request.user, str(d.get("start") or ""), str(d.get("end") or "")):
            return refuse(request, "bad_quiet")
        return Response({"ok": True})


def _one_ack(user, a):
    try:
        cid = int((a or {}).get("care_call_id"))
    except (TypeError, ValueError):
        return None, "bad_ack"
    return CC.ack(user, cid, str((a or {}).get("slot") or ""), str((a or {}).get("action") or ""))


class CareCallAckView(_Base):
    """Done / Snooze always land — even with the switch off, an answer the
    receiver already gave is never lost."""
    def post(self, request):
        ring, err = _one_ack(request.user, request.data or {})
        if err:
            return refuse(request, err)
        return Response({"ok": True, "status": ring.status})


class CareCallAcksView(_Base):
    def post(self, request):
        acks = (request.data or {}).get("acks") or []
        done = []
        for a in list(acks)[:50]:
            ring, err = _one_ack(request.user, a)
            done.append({"slot": (a or {}).get("slot"), "ok": err is None or err == "not_found",
                         "status": getattr(ring, "status", None)})
        return Response({"ok": True, "results": done})
