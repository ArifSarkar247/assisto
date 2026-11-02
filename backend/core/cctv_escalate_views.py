"""
cctv_escalate_views.py — CCTV ESCALATION PLUS (owner CCTV order 3 Nov,
section C; audit rows C3-C6). Builds on cctvx_views (chain of people, siren,
event access) — rules in core/logic/cctv_deter.py. Flag: the existing
CCTV switches through _OwnerBase (no new flag).

C3  run_alarm_call(task)        server job step (shop_guard_tick): ring the
                                next person with the My Circle CALL push
                                (native full-screen ring); the phone shows
                                the alert's alarm page + snapshot.
    cancel_rings(rung)          call_cancel pushes when anyone opens it.
C4  actions_extra(ev)["police"] the 999 card (address, time, snapshot) —
                                the PHONE opens the dialer; never automatic.
C5  POST shop/events/<id>/deter {feature: light|voice, confirm: true,
                                seconds?, camera_id?}
    GET/PUT/DELETE shop/sites/<id>/warn-clip   the owner's recorded warning
    GET  shop/cameras/<id>/deter               per-camera capability table
                                               (?refresh=1 asks EZVIZ)
C6  talk: capability row only (honest "not yet" + the way that works today).
"""
import base64
import hashlib
import logging
from datetime import timedelta

from django.utils import timezone
from rest_framework.response import Response

from .i18n import req_lang
from . import shop_views as SV
from . import cctvx_views as X
from .logic import cctv_deter as CD
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")


# ================================================================ C3
def _push(user, kind, tb, te, bb, be, data):
    from . import push
    return push.safe_push(user, kind, tb, te, bb, be, data=data,
                          high_priority=True)


def ring_alarm(ev, user, n, now):
    """One alarm ring to `user` over the call push. Returns the call id, or
    None when the person cannot be rung (blocked / call notifications off)."""
    from .views_c2_calls import ring_allowed
    site = ev.site
    owner = site.owner
    if not ring_allowed(user, owner):
        return None
    cam = ev.camera
    lang = X._lang_of(user)
    cam_name = (cam.name if cam else "") or SV._subject_label(ev.type, lang)
    snap = SV._abs_snapshot_url(ev) or ""
    cid = CD.alarm_call_id(ev.id, user.pk, n)
    owner_name = getattr(owner, "name", "") or ""
    name = CD.call_caller_name(lang, site.name, cam_name)
    _push(user, "call", name, name,
          CD.call_body("bn", owner_name), CD.call_body("en", owner_name),
          {"call_id": cid, "caller_id": "", "caller_name": name, "video": False,
           "chat_id": "", "caller_photo": snap, "cctv_event_id": ev.id,
           "snapshot_url": snap, "site_name": site.name or "",
           "camera_name": cam_name, "route": "watchman/inbox", "attempt": 0})
    return cid


def run_alarm_call(task, ev, now):
    """The call phase of the escalation task. 'wait' (rang one person, the
    next comes after escalate_min) | 'end' (all rounds done) | 'cap'."""
    from .models import ShopEvent, User
    st = dict(task.state or {})
    logrows = list(st.get("log") or [])
    order = [int(u) for u in st.get("calls") or []][:CD.MAX_RINGS]
    ci = int(st.get("ci") or 0)
    rung = list(st.get("rung") or [])
    site = ev.site
    allowed = {p["uid"] for p in X.circle_people(site.owner)}
    while ci < len(order) and order[ci] not in allowed:
        logrows.append({"at": now.isoformat(), "uid": order[ci], "call_skip": "not_in_circle"})
        ci += 1
    if ci >= len(order):
        task.state = dict(st, ci=ci, log=logrows)
        return "end"
    if not X.take_cap(site, "escalations_day", now):
        logrows.append({"at": now.isoformat(), "stop": "cap", "phase": "call"})
        task.state = dict(st, ci=ci, log=logrows)
        return "cap"
    user = User.objects.filter(pk=order[ci]).first()
    cid = ring_alarm(ev, user, ci, now) if user is not None else None
    if cid:
        sig = dict(ev.signals or {})
        to = X._escalated(ev)
        if user.pk not in to:
            to.append(user.pk)
        sig["escalated_to"] = to
        ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
        ev.signals = sig
        rung.append({"id": cid, "uid": user.pk})
        logrows.append({"at": now.isoformat(), "uid": user.pk, "call": cid})
    else:
        logrows.append({"at": now.isoformat(), "uid": order[ci], "call_skip": "not_ringable"})
    ci += 1
    task.state = dict(st, ci=ci, rung=rung[-CD.MAX_RINGS:], log=logrows[-40:])
    if ci < len(order):
        task.due_at = now + timedelta(minutes=X.settings_for(site)["escalate_min"])
        return "wait"
    return "end"


def cancel_rings(rung):
    """Someone opened the alert: take every alarm ring off the phones."""
    from .models import User
    for r in rung or []:
        try:
            u = User.objects.filter(pk=int(r.get("uid"))).first()
            if u is not None and CD.is_alarm_call_id(r.get("id")):
                _push(u, "call_cancel", "সতর্কতা দেখা হয়েছে", "Alert seen", "", "",
                      {"call_id": r["id"], "reason": "opened"})
        except Exception:
            log.exception("alarm ring cancel failed")


# ================================================================ C4 + table
def _when(ev):
    try:
        return timezone.localtime(ev.created).strftime("%d/%m/%Y %H:%M")
    except Exception:
        return ""


def police_facts(ev, lang):
    s = X.settings_for(ev.site)
    cam = ev.camera
    return {"site": ev.site.name or "", "address": s.get("address") or "",
            "when": _when(ev), "camera": (cam.name if cam else "") or "",
            "kind": SV._subject_label(ev.type, lang), "event_id": ev.id,
            "has_photo": bool(ev.snapshot)}


def deter_table(cam, site, lang):
    return CD.capability_table(cam.vendor, cam.vendor_ref, site.gateway,
                               bool((cam.source or {}).get("host")),
                               cam.compat or {}, lang)


def actions_extra(ev, role):
    site = ev.site
    s = X.settings_for(site)
    out = {}
    pf = {lang: police_facts(ev, lang) for lang in ("bn", "en")}
    out["police"] = {
        "number": "999", "auto": False,
        "address": s.get("address") or "", "address_missing": not s.get("address"),
        "card_bn": CD.police_card("bn", pf["bn"]),
        "card_en": CD.police_card("en", pf["en"]),
        "note_bn": CD.NO_AUTO_POLICE[0], "note_en": CD.NO_AUTO_POLICE[1],
        "snapshot_url": SV._abs_snapshot_url(ev) or "",
    }
    cam = ev.camera
    if cam is not None:
        warn = (site.guard or {}).get("_warn") or {}
        out["deter"] = {
            "camera_id": cam.id, "site_id": site.id,
            "allowed": role in ("owner", "escalated"),
            "table_bn": deter_table(cam, site, "bn"),
            "table_en": deter_table(cam, site, "en"),
            "warn_clip": bool(warn.get("name")),
            "light_seconds": CD.DETER_SECONDS["light"][2],
        }
    return out


# ================================================================ C5 views
ERRS = {
    "confirm": ("শব্দ / আলো চালানোর আগে নিশ্চিত করুন।", "Please confirm before sounding."),
    "too_soon": X.SIREN_ERRS["too_soon"],
    "cap": X.SIREN_ERRS["cap"],
    "no_clip": ("আগে নিজের কণ্ঠে একটি সতর্কবার্তা রেকর্ড করুন।",
                "Record a warning in your own voice first."),
    "not_allowed": ("শুধু মালিক বা যাঁকে পাঠানো হয়েছে তিনি এটি চালাতে পারেন।",
                    "Only the owner or the person this alert was passed to can do this."),
    "vendor_off": ("ক্যামেরার ক্লাউড এখনো চালু হয়নি — এখন চালানো যাচ্ছে না।",
                   "The camera cloud is not switched on yet — it cannot be done now."),
    "vendor_error": ("ক্যামেরা অনুরোধটি নেয়নি — ক্যামেরা অফলাইন হতে পারে।",
                     "The camera did not accept the request — it may be offline."),
    "bad_feature": ("এটি চেনা গেল না।", "Not recognised."),
}


def _e(lang, key, status, **extra):
    bn, en = ERRS[key]
    return X._err(lang, bn, en, status=status, code=key, **extra)


def _imou_client():
    from .logic import imou as IM
    from .watchman_views import imou_cloud_on
    return IM.ImouClient.from_integration() if imou_cloud_on() else None


def _ezviz_client():
    try:
        from .logic import ezviz as EZ
        return EZ.EzvizClient.from_integration()
    except Exception:
        return None


def _warn_bytes(site):
    from django.core.files.storage import default_storage
    w = (site.guard or {}).get("_warn") or {}
    if not w.get("name"):
        return None, w
    try:
        with default_storage.open(w["name"], "rb") as f:
            return f.read(), w
    except Exception:
        return None, w


def _save_warn(site, w):
    from .models import ShopSite
    g = dict(site.guard or {})
    if w:
        g["_warn"] = w
    else:
        g.pop("_warn", None)
    ShopSite.objects.filter(pk=site.pk).update(guard=g)
    site.guard = g


class EventDeterView(_OwnerBase):
    """POST {feature: light|voice, confirm: true}. The siren stays on
    shop/events/<id>/siren (cctvx). Confirm-before-sound is required here
    too (the phone asks first); cooldown + the daily siren cap apply to all
    deterrents together."""

    def post(self, request, pk):
        from .models import ShopCamera, ShopGuardTask
        lang = req_lang(request)
        ev, role = X.event_access(request, pk)
        if ev is None:
            return X._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if role not in ("owner", "escalated"):
            return _e(lang, "not_allowed", 403)
        feature = str(request.data.get("feature") or "")
        if feature not in ("light", "voice"):
            return _e(lang, "bad_feature", 400)
        if request.data.get("confirm") is not True:
            return _e(lang, "confirm", 428)
        cam = ev.camera
        cid = request.data.get("camera_id")
        if cid not in (None, ""):
            try:
                cam = ShopCamera.objects.filter(site=ev.site, pk=int(cid)).first() or cam
            except (TypeError, ValueError):
                pass
        site = ev.site
        if cam is None:
            return X._err(lang, *CD.REASONS["no"], status=409, code="unsupported",
                          reason="no_camera")
        route, why = CD.capability(cam.vendor, cam.vendor_ref, site.gateway,
                                   bool((cam.source or {}).get("host")),
                                   cam.compat or {}, feature)
        if route is None:
            return X._err(lang, CD.reason_text(why, "bn"), CD.reason_text(why, "en"),
                          status=409, code="unsupported", reason=why)
        now = timezone.now()
        compat = dict(cam.compat or {})
        last = max(float(compat.get("siren_at") or 0), float(compat.get("deter_at") or 0))
        if now.timestamp() - last < CD.COOLDOWN_S:
            return _e(lang, "too_soon", 429)
        clip = None
        if feature == "voice":
            clip, warn = _warn_bytes(site)
            if not clip:
                return _e(lang, "no_clip", 409)
        if not X.take_cap(site, "sirens_day", now):
            return _e(lang, "cap", 429)
        compat["deter_at"] = now.timestamp()
        ShopCamera.objects.filter(pk=cam.pk).update(compat=compat)
        secs = CD.clamp_seconds("light", request.data.get("seconds"))
        audit = {"at": now.isoformat(), "by": request.user.pk, "camera": cam.id,
                 "feature": feature, "route": route}
        sig = dict(ev.signals or {})
        sig["deter"] = (list(sig.get("deter") or []) + [audit])[-5:]
        type(ev).objects.filter(pk=ev.pk).update(signals=sig)
        if route == "imou_cloud":
            from .logic import imou as IM
            client = _imou_client()
            if client is None:
                return _e(lang, "vendor_off", 503)
            dev, _, ch = cam.vendor_ref.partition(":")
            try:
                CD.imou_light(client, dev, ch or "0", on=True)
            except IM.ImouError as e:
                if e.code in CD.IMOU_NOT_SUPPORTED:
                    ShopCamera.objects.filter(pk=cam.pk).update(
                        compat=CD.learn_no(compat, "light"))
                    return X._err(lang, *CD.REASONS["no"], status=409,
                                  code="unsupported", reason="learned_no")
                return _e(lang, "vendor_error", 502, vendor_code=e.code)
            ShopGuardTask.objects.create(site=site, event=ev, kind="siren_off",
                                         due_at=now + timedelta(seconds=secs),
                                         state={"camera_id": cam.id, "action": "light"})
            return Response({"ok": True, "feature": feature, "route": route,
                             "seconds": secs, "status": "on"})
        # EZVIZ voice: upload the owner's clip once (cached url), then send
        from .logic import ezviz as EZ
        client = _ezviz_client()
        if client is None:
            return _e(lang, "vendor_off", 503)
        serial, ch = CD.ezviz_ref(cam.vendor_ref)
        try:
            url = warn.get("ezviz_url")
            if not url:
                url = CD.ezviz_voice_upload(client, "assisto_warn_%d" % site.id, clip)
                _save_warn(site, dict(warn, ezviz_url=url))
            CD.ezviz_voice_send(client, serial, ch, url)
        except EZ.EzvizError as e:
            if e.code in CD.EZVIZ_NOT_SUPPORTED:
                ShopCamera.objects.filter(pk=cam.pk).update(
                    compat=CD.learn_no(compat, "voice"))
                return X._err(lang, CD.reason_text("voice_no_speaker", "bn"),
                              CD.reason_text("voice_no_speaker", "en"), status=409,
                              code="unsupported", reason="voice_no_speaker")
            return _e(lang, "vendor_error", 502, vendor_code=e.code)
        return Response({"ok": True, "feature": feature, "route": route,
                         "status": "playing"})


class WarnClipView(_OwnerBase):
    """The owner's recorded warning (WAV, <= 20 s), ONE per site. PUT
    {wav_b64}; DELETE removes it. GET says whether one exists + the lines to
    read."""

    def _out(self, site, lang):
        w = (site.guard or {}).get("_warn") or {}
        return {"site": site.id, "has_clip": bool(w.get("name")),
                "seconds": w.get("seconds"), "max_seconds": CD.WARN_MAX_S,
                "lines": list(CD.WARN_LINES_BN)}

    def get(self, request, pk):
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return X._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(self._out(site, lang))

    def put(self, request, pk):
        from django.core.files.base import ContentFile
        from django.core.files.storage import default_storage
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return X._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        try:
            raw = base64.b64decode(str(request.data.get("wav_b64") or ""), validate=True)
        except Exception:
            raw = b""
        secs = CD.wav_seconds(raw)
        if not raw or len(raw) > CD.WARN_MAX_BYTES or secs is None or \
                not 1 <= secs <= CD.WARN_MAX_S:
            return X._err(lang, "রেকর্ডিংটি নেওয়া গেল না — ১ থেকে ২০ সেকেন্ডের মধ্যে আবার রেকর্ড করুন।",
                          "The recording could not be used — record again, 1 to 20 seconds.",
                          status=422, code="bad_clip")
        old = (site.guard or {}).get("_warn") or {}
        sha = hashlib.sha256(raw).hexdigest()
        name = default_storage.save("cctv_warn/%d/%s.wav" % (site.id, sha[:24]),
                                    ContentFile(raw))
        if old.get("name") and old["name"] != name:
            try:
                default_storage.delete(old["name"])
            except Exception:
                pass
        _save_warn(site, {"name": name, "sha256": sha, "seconds": secs,
                          "at": timezone.now().isoformat()})
        return Response(self._out(site, lang))

    post = put

    def delete(self, request, pk):
        from django.core.files.storage import default_storage
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return X._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        old = (site.guard or {}).get("_warn") or {}
        if old.get("name"):
            try:
                default_storage.delete(old["name"])
            except Exception:
                pass
        _save_warn(site, None)
        return Response(self._out(site, lang))


class CameraDeterView(_OwnerBase):
    """GET the per-camera table (siren / light / voice / talk). ?refresh=1
    asks EZVIZ /api/lapp/device/capacity once and remembers support_talk."""

    def get(self, request, pk):
        from .models import ShopCamera
        lang = req_lang(request)
        cam = ShopCamera.objects.select_related("site").filter(
            pk=pk, site__owner=request.user).first()
        if cam is None:
            return X._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if request.query_params.get("refresh") == "1" and cam.vendor == "ezviz" \
                and cam.vendor_ref:
            client = _ezviz_client()
            if client is not None:
                try:
                    serial, _ = CD.ezviz_ref(cam.vendor_ref)
                    cap = CD.ezviz_capacity(client, serial)
                    if "support_talk" in cap:
                        compat = dict(cam.compat or {}, support_talk=str(cap["support_talk"]))
                        ShopCamera.objects.filter(pk=cam.pk).update(compat=compat)
                        cam.compat = compat
                except Exception:
                    pass
        return Response({"camera": cam.id, "vendor": cam.vendor,
                         "table": deter_table(cam, cam.site, lang)})
