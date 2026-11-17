"""
cctv_act_views.py — CCTV GUARD V3 (owner order 9 Nov 15:15) parts D, E, F, G:
the DB / push / API glue. Pure rules: core/logic/cctv_act.py; Tuya client:
core/logic/tuya.py. Builds ON cctvx / cctv_escalate / cctv_activity —
nothing replaced. Flag: the existing CCTV switch (_OwnerBase).

D  ACT FROM AN ALERT
  (in GET shop/events/<id> "actions.act")   live path, local thana, wrong-
                                            alert state, automations ran
  PUT  shop/sites/<id>/location {lat, lon}  the site's map point (owner)
  GET  shop/sites/<id>/thana[?refresh=1]    nearest police station(s) from
                                            REAL map rows + 999 always
  POST shop/events/<id>/play {sound: siren|warn, confirm: true}
                                            the Guard Box / phone camera plays
                                            it (a gateway "play" task)
  GET  shop/device/warn-clip                (device token) the owner's warning
  automations (Tuya / Smart Life):
  GET/PUT shop/sites/<id>/automations       rules + devices + log
  POST/DELETE shop/sites/<id>/automations/link
  POST shop/sites/<id>/automations/test {device_id}
  POST shop/sites/<id>/automations/lock {pending_id, confirm: true}
  "Wrong alert" learning: shop_views.ShopEventMarkView calls on_verdict();
  shop_views._ingest_event calls apply_learning() + after_alert().
E  GET  shop/sites/<id>/closing-report?date=  + the push at closing (tick)
   POST shop/device/daily-stats             (device token) box-measured
                                            counter-empty minutes, vehicles,
                                            table occupancy
F  GET/POST/DELETE shop/sites/<id>/pos-key  per-shop webhook key (secret
                                            shown ONCE)
   POST shop/pos/webhook                    signed partner events (AllowAny,
                                            HMAC-SHA256 + timestamp + event id)
   POST shop/sites/<id>/pos-csv {csv}       CSV import
   GET  shop/sites/<id>/sales-match?date=   review-only cash clips
G  POST shop/sites/<id>/ask {q}             answers from stored events + clips

PRIVACY: no face recognition, no identity, no staff names; Owner Admin has
no view here; clips stay behind the owner-checked links of cashguard.
"""
import json
import logging
import secrets
from datetime import datetime, timedelta, timezone as dt_timezone

from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import cctv_act as A
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")

THANA_TTL_S = 30 * 86400
AUTO_LOG_MAX = 20
LOCK_CONFIRM_S = 10 * 60
NIGHT_TYPES = ("person_detected", "zone_intrusion", "line_crossing", "after_hours",
               "loitering", "motion", "camera_alarm")
FIRE_KINDS = ("fire", "smoke")


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _local(dt):
    return timezone.localtime(dt)


def guard_get(site, key, default=None):
    g = site.guard if isinstance(site.guard, dict) else {}
    v = g.get(key)
    return v if v is not None else default


def guard_update(site, key, fn):
    """Atomically change site.guard[key]; fn(value_dict) mutates and returns
    a result. Never raises (None on failure)."""
    from .models import ShopSite
    try:
        with transaction.atomic():
            row = ShopSite.objects.select_for_update().only("id", "guard").get(pk=site.pk)
            g = dict(row.guard) if isinstance(row.guard, dict) else {}
            val = dict(g.get(key) or {})
            out = fn(val)
            g[key] = val
            ShopSite.objects.filter(pk=site.pk).update(guard=g)
            site.guard = g
            return out
    except Exception:
        log.exception("cctvact guard update failed")
        return None


def _site(request, pk, owner_only=True):
    """(site, role) for the owner (or a viewer when owner_only is False)."""
    if owner_only:
        s = SV._owner_site(request, pk)
        return (s, "owner") if s is not None else (None, None)
    return SV._viewable_site(request, pk)


def _scope(site, user):
    from . import cctv_team_views as CTV
    try:
        return CTV.scope_for(site, user)[1]
    except Exception:
        return None


def _cam_ok(scope, camera_id):
    from .logic import cctv_team as CT
    return CT.camera_allowed(scope, camera_id)


# ======================================================================= D
# ------------------------------------------------------------ wrong alert
def _event_key(ev, when=None):
    sig = ev.signals if isinstance(ev.signals, dict) else {}
    inp = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else {}
    when = when or ev.created or timezone.now()
    return A.pattern_key(ev.type, ev.camera_id, inp.get("kind"), _local(when).hour)


def on_verdict(ev, before, after, reason=""):
    """The owner's Correct / Wrong on an alert -> this SITE's pattern.
    Called from shop_views.ShopEventMarkView. Never raises."""
    try:
        reason = reason if reason in A.WRONG_REASONS else ""
        if before == after:
            # gap-cctv: Wrong on the card first, then the reason in the sheet —
            # keep the reason (it is not counted as a second wrong)
            if after != "false_alarm" or not reason:
                return None
            key = _event_key(ev)

            def add_reason(learn):
                learn = learn if isinstance(learn, dict) else {}
                row = dict(learn.get(key) or {})
                rs = dict(row.get("r") or {})
                rs[reason] = int(rs.get(reason, 0) or 0) + 1
                row["r"] = rs
                learn[key] = row
                return dict(row)
            return guard_update(ev.site, A.LEARN_KEY, add_reason)
        key = _event_key(ev)
        ts = timezone.now().timestamp()

        def f(learn):
            if before == "false_alarm":
                A.learn_record(learn, key, "undo_wrong", ts)
            A.learn_record(learn, key, "wrong" if after == "false_alarm" else "correct",
                           ts, reason)
            return dict(learn.get(key) or {})
        return guard_update(ev.site, A.LEARN_KEY, f)
    except Exception:
        log.exception("cctvact verdict failed")
        return None


def learn_state(site, ev, lang):
    row = (guard_get(site, A.LEARN_KEY, {}) or {}).get(_event_key(ev)) or {}
    now = timezone.now().timestamp()
    return {"wrong": int(row.get("w", 0) or 0), "correct": int(row.get("c", 0) or 0),
            "factor": A.learn_factor(row, now),
            "quiet": A.net_wrong(row, now) >= A.QUIET_AT_NET,
            "note_bn": A.learn_summary(row, now, "bn"),
            "note_en": A.learn_summary(row, now, "en"),
            "reasons": list(A.WRONG_REASONS)}


def apply_learning(site, cam, cam_event, decision, now, quiet, away):
    """From shop_views._ingest_event once the guard decided to raise: lower
    the confidence of a pattern the owner keeps calling wrong; after enough
    wrong answers save it QUIETLY (no push). Safety and away mode never go
    quiet. -> (decision, quiet)."""
    sig = cam_event.get("signals") if isinstance(cam_event.get("signals"), dict) else {}
    key = A.pattern_key(decision.get("type"), getattr(cam, "id", None), sig.get("kind"),
                        _local(now).hour)
    row = (guard_get(site, A.LEARN_KEY, {}) or {}).get(key)
    if not row:
        return decision, quiet
    conf, lq, f = A.learn_apply(row, now.timestamp(), decision.get("confidence"),
                                decision.get("type"), sig.get("kind"), away)
    if f >= 1.0 and not lq:
        return decision, quiet
    d = dict(decision, confidence=conf, learned=f)
    if lq:
        d["learned_quiet"] = True
    return d, (quiet or lq)


# ------------------------------------------------------------ live + thana
def live_path(cam, site):
    """How the phone can open live for this camera, honestly."""
    if cam is None:
        return {"path": None, "reason": "no_camera"}
    v = (cam.vendor or "").lower()
    if v == "phone":
        return {"path": "webrtc", "camera_id": cam.id, "name": cam.name or ""}
    # flag-cctv-e2e: a camera imported from the Dahua DoLynk / Hik-Connect
    # cloud (vendor dahua / hikvision + a cloud ref) plays its vendor stream
    # too (cctv_traffic_views.CLOUD_LIVE_VENDORS) — it had no Live button
    if v in ("imou", "ezviz", "dahua", "hikvision") and cam.vendor_ref:
        return {"path": "vendor", "camera_id": cam.id, "name": cam.name or ""}
    if site.gateway:
        return {"path": "webrtc", "camera_id": cam.id, "name": cam.name or ""}
    return {"path": None, "reason": "no_route", "camera_id": cam.id}


def _thana_rows(lat, lon, lang):
    from . import nearby
    res = nearby.search(lat, lon, "police", lang=lang)
    rows, src = res if isinstance(res, tuple) else ((res or {}).get("results") or [], "")
    return rows or [], src or ""


def thana_for(site, lang="bn", refresh=False, now=None):
    """{state, stations[], source, lat, lng}. state: ok | no_location |
    none_nearby | unavailable. Cached 30 days on the site."""
    now = now or timezone.now()
    loc = guard_get(site, "_loc") or {}
    if not loc.get("lat"):
        return {"state": "no_location", "stations": [], "emergency": "999"}
    cache = guard_get(site, "_thana") or {}
    fresh = (cache.get("at") and now.timestamp() - float(cache["at"]) < THANA_TTL_S and
             cache.get("lat") == loc["lat"] and cache.get("lng") == loc["lng"])
    if fresh and not refresh and cache.get("lang") == lang:
        return {"state": cache.get("state") or "ok", "stations": cache.get("stations") or [],
                "source": cache.get("source") or "", "emergency": "999",
                "lat": loc["lat"], "lng": loc["lng"]}
    try:
        rows, src = _thana_rows(loc["lat"], loc["lng"], lang)
    except Exception:
        rows, src = [], "unavailable"
    st = A.pick_thana(rows, loc["lat"], loc["lng"])
    state = "unavailable" if src == "unavailable" else ("ok" if st else "none_nearby")
    if state != "unavailable":
        def f(c):
            c.clear()
            c.update({"at": now.timestamp(), "lat": loc["lat"], "lng": loc["lng"],
                      "stations": st, "source": src, "state": state, "lang": lang})
        guard_update(site, "_thana", f)
    return {"state": state, "stations": st, "source": src, "emergency": "999",
            "lat": loc["lat"], "lng": loc["lng"]}


def live_for_role(cam, site, role, user):
    """gap-cctv: the Live tile only for someone the live start will admit —
    the owner, or a viewer whose role covers this camera and whom the owner
    allowed live (brand-cloud live stays owner-only). Never logs access."""
    live = live_path(cam, site)
    if role == "owner" or live.get("path") is None:
        return live
    hidden = {"path": None, "reason": "owner_only"}
    if live.get("path") != "webrtc" or user is None or cam is None:
        return hidden
    try:
        from . import cctv_team_views as CTV
        from .logic import cctv_team as CT
        r, scope = CTV.scope_for(site, user)
        if r is None or r == "owner" or not CT.camera_allowed(scope, cam.id):
            return hidden
        if not CTV.viewer_live_ok(cam, CTV.viewer_of(site, user)):
            return hidden
    except Exception:
        log.exception("cctvact live role check failed")
        return hidden
    return live


def act_actions(ev, role, user=None):
    """Extra alert actions for actions_for() (cctvx). Never raises."""
    try:
        site, cam = ev.site, ev.camera
        lang = "bn"
        out = {"site_id": site.id, "role": role, "live": live_for_role(cam, site, role, user)}
        pend = [{"id": p["id"], "name": p.get("name") or ""}
                for p in _auto(site).get("pending") or [] if p.get("event_id") == ev.id]
        if role == "owner" and pend:
            out["lock_pending"] = pend
        if role == "owner":
            out["wrong"] = learn_state(site, ev, lang)
            loc = guard_get(site, "_loc") or {}
            cache = guard_get(site, "_thana") or {}
            out["thana"] = {"has_location": bool(loc.get("lat")),
                            "stations": cache.get("stations") or [] if loc.get("lat") else [],
                            # gap-cctv: a failed lookup is never cached, so a
                            # location with no cache = "could not look up"
                            "state": ("no_location" if not loc.get("lat") else
                                      (cache.get("state") or "ok") if cache.get("at")
                                      else "unavailable"),
                            "emergency": "999"}
            out["play"] = play_targets(site)
            # gap-cctv: is the owner's own warning recorded? (else the tile
            # offers "record it first" instead of a 409 after confirming)
            out["has_warn"] = bool(((site.guard or {}).get("_warn") or {}).get("name"))
        sig = ev.signals if isinstance(ev.signals, dict) else {}
        if sig.get("auto"):
            out["auto"] = sig["auto"]
        return {"act": out}
    except Exception:
        log.exception("cctvact actions failed")
        return {}


class SiteLocationView(_OwnerBase):
    """PUT {lat, lon} — the owner's tap on "use this phone's location" while
    standing in the shop (foreground location only; no new permission)."""

    def put(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        ll = A.valid_latlon(request.data.get("lat"), request.data.get("lon",
                                                                     request.data.get("lng")))
        if ll is None:
            return _err(lang, "লোকেশন ঠিক নেই।", "The location is not valid.",
                        status=422, code="bad_location")

        def f(loc):
            loc.clear()
            loc.update({"lat": ll[0], "lng": ll[1], "at": timezone.now().isoformat()})
        guard_update(site, "_loc", f)
        return Response(thana_for(site, lang, refresh=True))

    post = put


class SiteThanaView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        refresh = request.query_params.get("refresh") == "1"
        return Response(thana_for(site, lang, refresh=refresh))


# ------------------------------------------------------------ box / phone play
def play_targets(site):
    """Where a siren / the owner's warning can sound: the Guard Box (the
    site's gateway) and phone cameras. Honest list (may be empty)."""
    out = []
    if site.gateway:
        out.append({"target": "box", "camera_id": None})
    for c in site.cameras.filter(enabled=True, vendor="phone").only("id", "name")[:4]:
        out.append({"target": "phone", "camera_id": c.id, "name": c.name or ""})
    return out


PLAY_ERRS = {
    "confirm": ("বাজানোর আগে নিশ্চিত করুন।", "Please confirm before it sounds."),
    "no_target": ("এই দোকানে বক্স বা ফোন-ক্যামেরা নেই — সাইরেন/সতর্কবাণী বাজানোর জায়গা নেই।",
                  "No Guard Box or phone camera at this shop — nothing can play it."),
    "no_clip": ("আগে নিজের কণ্ঠে একটি সতর্কবার্তা রেকর্ড করুন।",
                "Record a warning in your own voice first."),
    "bad_sound": ("এটি চেনা গেল না।", "Not recognised."),
    "not_allowed": ("শুধু মালিক বা যাঁকে পাঠানো হয়েছে তিনি এটি চালাতে পারেন।",
                    "Only the owner or the person this alert was passed to can do this."),
    "cap": ("আজকের সাইরেনের সীমা শেষ।", "Today's siren limit is used up."),
}


def queue_play(site, ev, sound, camera_id=None, seconds=20, by="owner"):
    """One gateway 'play' task per target. -> number queued."""
    from .models import ShopGatewayTask, ShopCamera
    n = 0
    for t in play_targets(site):
        if camera_id and t.get("camera_id") not in (None, camera_id):
            continue
        cam = ShopCamera.objects.filter(pk=t["camera_id"]).first() if t.get("camera_id") else None
        if cam is None and t["target"] == "box":
            # the Android Guard Box only has CAMERA tokens and picks "play"
            # up in its heartbeat for that camera (cctvbox): bind the task to
            # the camera that saw it; the Linux box reads gateway tasks anyway
            cam = getattr(ev, "camera", None)
        ShopGatewayTask.objects.create(
            site=site, camera=cam, action="play",
            request={"sound": sound, "seconds": int(seconds), "target": t["target"],
                     "event_id": getattr(ev, "id", None), "by": by,
                     # the box fetches the clip with its own device token
                     "warn_url": "/api/v1/shop/device/warn-clip" if sound == "warn" else ""})
        n += 1
    return n


class EventPlayView(_OwnerBase):
    """POST {sound: siren|warn, confirm: true[, camera_id]} — the Guard Box or
    a phone camera at the shop plays the siren or the owner's own recorded
    warning through its speaker (picked up by the box within seconds)."""

    def post(self, request, pk):
        from . import cctvx_views as X
        lang = req_lang(request)
        ev, role = X.event_access(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if role not in ("owner", "escalated"):
            return _err(lang, *PLAY_ERRS["not_allowed"], status=403, code="not_allowed")
        sound = str(request.data.get("sound") or "")
        if sound not in ("siren", "warn"):
            return _err(lang, *PLAY_ERRS["bad_sound"], status=400, code="bad_sound")
        if request.data.get("confirm") is not True:
            return _err(lang, *PLAY_ERRS["confirm"], status=428, code="confirm")
        site = ev.site
        if not play_targets(site):
            return _err(lang, *PLAY_ERRS["no_target"], status=409, code="no_target")
        if sound == "warn" and not ((site.guard or {}).get("_warn") or {}).get("name"):
            return _err(lang, *PLAY_ERRS["no_clip"], status=409, code="no_clip")
        now = timezone.now()
        if not X.take_cap(site, "sirens_day", now):
            return _err(lang, *PLAY_ERRS["cap"], status=429, code="cap")
        try:
            cid = int(request.data.get("camera_id")) if request.data.get("camera_id") else None
        except (TypeError, ValueError):
            cid = None
        n = queue_play(site, ev, sound, camera_id=cid, by=role)
        sig = dict(ev.signals or {})
        sig["deter"] = (list(sig.get("deter") or []) + [
            {"at": now.isoformat(), "by": request.user.pk, "feature": sound,
             "route": "box_play", "targets": n}])[-5:]
        type(ev).objects.filter(pk=ev.pk).update(signals=sig)
        return Response({"ok": True, "sound": sound, "queued": n, "status": "queued"})


class DeviceWarnClipView(APIView):
    """GET (X-Shop-Token) — the owner's recorded warning for the box / phone
    camera that was asked to play it. Device auth, never a user session."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from django.http import HttpResponse
        site, _cam = SV._resolve_device_site(request)
        if site is None:
            return Response({"error": "bad_token"}, status=401)
        from . import cctv_escalate_views as CE
        raw, _w = CE._warn_bytes(site)
        if not raw:
            return Response({"error": "no_clip"}, status=404)
        r = HttpResponse(raw, content_type="audio/wav")
        r["Cache-Control"] = "no-store"
        return r


# ------------------------------------------------------------ automations
AUTO_TRIGGERS = ("night_intrusion", "any_alert", "fire_smoke")
AUTO_KINDS = ("light", "plug", "switch", "siren", "lock")
AUTO_DEFAULT_WINDOW = {"start": "22:00", "end": "06:00"}


def _auto(site):
    a = guard_get(site, "_auto") or {}
    return a if isinstance(a, dict) else {}


def tuya_link(site):
    """(client, uid) for the site, or (None, None)."""
    from .logic import tuya as T
    a = _auto(site)
    link = a.get("link") or {}
    uid = link.get("uid")
    if not uid:
        return None, None
    if link.get("mode") == "own" and link.get("sealed"):
        from . import remittance_service as RS
        c = RS.unseal(link["sealed"]) or {}
        if not c.get("id") or not c.get("secret"):
            return None, None
        return T.TuyaClient(c["id"], c["secret"], link.get("region") or "in"), uid
    cl = T.TuyaClient.from_integration()
    return (cl, uid) if cl is not None else (None, None)


def clean_rules(raw, devices):
    """Owner rules -> stored rules (bounded, only known devices)."""
    ids = {d["id"]: d for d in devices or []}
    out = []
    for r in (raw or [])[:10]:
        if not isinstance(r, dict):
            continue
        trig = r.get("trigger")
        if trig not in AUTO_TRIGGERS:
            continue
        acts = []
        for a in (r.get("actions") or [])[:8]:
            if not isinstance(a, dict):
                continue
            did = str(a.get("device_id") or "")
            dev = ids.get(did)
            if not dev or dev["kind"] not in AUTO_KINDS:
                continue
            try:
                secs = max(10, min(600, int(a.get("seconds") or 120)))
            except (TypeError, ValueError):
                secs = 120
            acts.append({"device_id": did, "kind": dev["kind"], "name": dev.get("name") or "",
                         "seconds": secs})
        w = r.get("window") if isinstance(r.get("window"), dict) else AUTO_DEFAULT_WINDOW
        win = {"start": w.get("start") if A._hm(w.get("start")) is not None else "22:00",
               "end": w.get("end") if A._hm(w.get("end")) is not None else "06:00"}
        out.append({"id": str(r.get("id") or secrets.token_hex(4))[:12], "trigger": trig,
                    "on": r.get("on") is not False, "window": win, "actions": acts,
                    "warn": bool(r.get("warn")), "siren_box": bool(r.get("siren_box"))})
    return out


def _in_window(win, local):
    s, e = A._hm(win.get("start")), A._hm(win.get("end"))
    if s is None or e is None:
        return True
    m = local.hour * 60 + local.minute
    return (s <= m < e) if s < e else (m >= s or m < e)


def rule_fires(rule, ev, local):
    if not rule.get("on"):
        return False
    sig = ev.signals if isinstance(ev.signals, dict) else {}
    kind = ((sig.get("inputs") or {}) if isinstance(sig.get("inputs"), dict) else {}).get("kind")
    t = rule["trigger"]
    if t == "fire_smoke":
        return kind in FIRE_KINDS
    if t == "night_intrusion":
        return ev.type in NIGHT_TYPES and kind not in ("animal",) and \
            ev.type != "camera_health" and _in_window(rule.get("window") or {}, local)
    if t == "any_alert":
        return ev.type != "camera_health" and _in_window(rule.get("window") or {}, local)
    return False


def after_alert(site, cam, ev, now, decision=None):
    """From _ingest_event after the push: run the site's automations.
    Lights / plugs / sirens switch on at once (and off after their seconds,
    by the minute tick); a LOCK only becomes a pending question for the
    owner; the box plays the warning / siren. Never raises."""
    try:
        if decision and decision.get("learned_quiet"):
            return None
        a = _auto(site)
        rules = [r for r in a.get("rules") or [] if rule_fires(r, ev, _local(now))]
        if not rules:
            return None
        client, uid = tuya_link(site)
        ran = []
        offs, locks = [], []
        for r in rules:
            for act in r.get("actions") or []:
                if act["kind"] == "lock":
                    locks.append({"id": secrets.token_hex(5), "device_id": act["device_id"],
                                  "name": act.get("name") or "", "event_id": ev.id,
                                  "until": now.timestamp() + LOCK_CONFIRM_S})
                    ran.append({"device": act.get("name") or "", "kind": "lock",
                                "state": "asked"})
                    continue
                if client is None:
                    ran.append({"device": act.get("name") or "", "kind": act["kind"],
                                "state": "not_linked"})
                    continue
                from .logic import tuya as T
                try:
                    client.switch(act["device_id"], act["kind"], on=True)
                    offs.append({"device_id": act["device_id"], "kind": act["kind"],
                                 "at": now.timestamp() + act.get("seconds", 120)})
                    ran.append({"device": act.get("name") or "", "kind": act["kind"],
                                "state": "on"})
                except T.TuyaError as e:
                    ran.append({"device": act.get("name") or "", "kind": act["kind"],
                                "state": "error", "code": e.code})
            if r.get("warn") and ((site.guard or {}).get("_warn") or {}).get("name"):
                if queue_play(site, ev, "warn", by="auto"):
                    ran.append({"device": "box", "kind": "warn", "state": "queued"})
            if r.get("siren_box"):
                if queue_play(site, ev, "siren", by="auto"):
                    ran.append({"device": "box", "kind": "siren", "state": "queued"})

        def f(au):
            au["offs"] = (list(au.get("offs") or []) + offs)[-40:]
            au["pending"] = (list(au.get("pending") or []) + locks)[-10:]
            au["log"] = (list(au.get("log") or []) + [
                {"at": now.isoformat(), "event_id": ev.id, "ran": ran}])[-AUTO_LOG_MAX:]
        guard_update(site, "_auto", f)
        sig = dict(ev.signals or {})
        sig["auto"] = ran[:12]
        type(ev).objects.filter(pk=ev.pk).update(signals=sig)
        if locks:
            from . import cctvx_views as X
            X.notice_site(site, "auto_lock", lambda lang: (
                pick(lang, "দরজা লক করবেন?", "Lock the door?"),
                pick(lang, "রাতে নড়াচড়া দেখা গেছে। লক করতে অ্যাপে সতর্কতাটি খুলে 'হ্যাঁ' চাপুন — "
                           "আপনি না বললে কিছু হবে না।",
                     "Movement was seen at night. To lock, open the alert in the app "
                     "and tap Yes — nothing happens unless you say so.")),
                severity="high", high=True, data={"event_id": ev.id})
        return ran
    except Exception:
        log.exception("cctvact automations failed")
        return None


def run_offs(site, now):
    """Switch off the lights / plugs / sirens whose time is up; drop expired
    lock questions. From the minute tick. Never raises."""
    a = _auto(site)
    due = [o for o in a.get("offs") or [] if float(o.get("at") or 0) <= now.timestamp()]
    expired = [p for p in a.get("pending") or [] if float(p.get("until") or 0) <= now.timestamp()]
    if not due and not expired:
        return 0
    client, _uid = tuya_link(site)
    if client is not None:
        for o in due:
            try:
                client.switch(o["device_id"], o["kind"], on=False)
            except Exception:
                log.warning("tuya off failed for site %s", site.pk)
    keys = {(o["device_id"], o["at"]) for o in due}
    gone = {p["id"] for p in expired}

    def f(au):
        au["offs"] = [o for o in au.get("offs") or [] if (o["device_id"], o["at"]) not in keys]
        au["pending"] = [p for p in au.get("pending") or [] if p.get("id") not in gone]
    guard_update(site, "_auto", f)
    return len(due)


AUTO_ERRS = {
    "not_linked": ("Smart Life এখনো যুক্ত হয়নি।", "Smart Life is not linked yet."),
    "link_failed": ("Tuya-তে যুক্ত হলো না — Access ID, Secret, UID ও ডেটা সেন্টার মিলিয়ে দেখুন।",
                    "Could not link to Tuya — check the Access ID, Secret, UID and data centre."),
    "service_off": ("Assisto-র Tuya সংযোগ এখনো চালু হয়নি — নিজের Tuya প্রজেক্ট দিয়ে যুক্ত করুন।",
                    "Assisto's Tuya connection is not switched on yet — link with your own Tuya project."),
    "bad_uid": ("Smart Life UID ঠিক নেই।", "The Smart Life UID is not valid."),
    "confirm": ("লক করার আগে নিশ্চিত করুন।", "Please confirm before locking."),
    "expired": ("এই প্রশ্নের সময় শেষ — আবার সতর্কতা এলে জিজ্ঞেস করা হবে।",
                "This question has expired — you will be asked again on the next alert."),
    "device_error": ("ডিভাইস অনুরোধটি নেয়নি — অফলাইন হতে পারে।",
                     "The device did not accept the request — it may be offline."),
}


def _ae(lang, key, status, **extra):
    return _err(lang, *AUTO_ERRS[key], status=status, code=key, **extra)


def _devices_cached(site):
    return list(_auto(site).get("devices") or [])


class AutomationsView(_OwnerBase):
    def _out(self, site, lang):
        from .logic import tuya as T
        a = _auto(site)
        link = a.get("link") or {}
        return {"site": site.id,
                "linked": bool(link.get("uid")), "mode": link.get("mode") or None,
                "region": link.get("region") or None,
                "service_on": T.TuyaClient.from_integration() is not None,
                "regions": list(T.REGION_ORDER),
                "devices": _devices_cached(site),
                "rules": a.get("rules") or [],
                "log": list(reversed(a.get("log") or []))[:10],
                "pending": [{"id": p["id"], "name": p.get("name") or "",
                             "event_id": p.get("event_id")}
                            for p in a.get("pending") or []],
                "triggers": list(AUTO_TRIGGERS),
                "has_warn": bool(((site.guard or {}).get("_warn") or {}).get("name")),
                "play_targets": len(play_targets(site)),
                "lock_note": pick(lang, "লক কখনো নিজে নিজে হয় না — প্রতিবার আপনার 'হ্যাঁ' লাগবে।",
                                  "A lock never acts on its own — it needs your Yes every time.")}

    def get(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if request.query_params.get("refresh") == "1":
            client, uid = tuya_link(site)
            if client is not None:
                try:
                    devs = client.devices(uid)
                    guard_update(site, "_auto", lambda au: au.__setitem__("devices", devs))
                except Exception:
                    pass
        return Response(self._out(site, lang))

    def put(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        rules = clean_rules(request.data.get("rules"), _devices_cached(site))
        guard_update(site, "_auto", lambda au: au.__setitem__("rules", rules))
        return Response(self._out(site, lang))

    post = put


class AutomationsLinkView(_OwnerBase):
    """POST {mode: assisto|own, uid, access_id?, access_secret?, region?} —
    proves the link by listing the devices; the own-project secret is
    sealed (Fernet) and never sent back. DELETE unlinks."""

    def post(self, request, pk):
        import re
        from .logic import tuya as T
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        uid = str(request.data.get("uid") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9]{6,40}", uid):
            return _ae(lang, "bad_uid", 422)
        mode = "own" if request.data.get("mode") == "own" else "assisto"
        region = str(request.data.get("region") or "").strip().lower()
        regions = [region] if region in T.REGIONS else list(T.REGION_ORDER)
        aid = str(request.data.get("access_id") or "").strip()
        sec = str(request.data.get("access_secret") or "").strip()
        if mode == "assisto":
            base = T.TuyaClient.from_integration()
            if base is None:
                return _ae(lang, "service_off", 409)
            aid, sec = base.client_id, base.secret
            regions = [base.region]
        elif not aid or not sec:
            return _ae(lang, "link_failed", 422)
        devs, used = None, None
        for rg in regions:
            try:
                devs = _tuya_factory(aid, sec, rg).devices(uid)
                used = rg
                break
            except T.TuyaError:
                continue
        if devs is None:
            return _ae(lang, "link_failed", 422)
        link = {"mode": mode, "uid": uid, "region": used,
                "at": timezone.now().isoformat()}
        if mode == "own":
            from . import remittance_service as RS
            link["sealed"] = RS.seal({"id": aid, "secret": sec})

        def f(au):
            au["link"] = link
            au["devices"] = devs
        guard_update(site, "_auto", f)
        return Response(AutomationsView()._out(site, lang))

    def delete(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)

        def f(au):
            for k in ("link", "devices", "offs", "pending"):
                au.pop(k, None)
        guard_update(site, "_auto", f)
        return Response(AutomationsView()._out(site, lang))


def _tuya_factory(aid, sec, region):
    from .logic import tuya as T
    return T.TuyaClient(aid, sec, region)


class AutomationsTestView(_OwnerBase):
    """POST {device_id} — switch one light / plug / siren ON for 10 s (the
    minute tick switches it off). Never a lock."""

    def post(self, request, pk):
        from .logic import tuya as T
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        did = str(request.data.get("device_id") or "")
        dev = next((d for d in _devices_cached(site) if d["id"] == did), None)
        if dev is None or dev["kind"] == "lock":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        client, _uid = tuya_link(site)
        if client is None:
            return _ae(lang, "not_linked", 409)
        try:
            client.switch(did, dev["kind"], on=True)
        except T.TuyaError as e:
            return _ae(lang, "device_error", 502, vendor_code=e.code)
        at = timezone.now().timestamp() + 10
        guard_update(site, "_auto", lambda au: au.__setitem__(
            "offs", (list(au.get("offs") or []) + [{"device_id": did, "kind": dev["kind"],
                                                    "at": at}])[-40:]))
        return Response({"ok": True, "device_id": did, "seconds": 10})


class AutomationsLockView(_OwnerBase):
    """POST {pending_id, confirm: true} — the owner's Yes to lock. ONLY the
    owner; a lock never runs without this call."""

    def post(self, request, pk):
        from .logic import tuya as T
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if request.data.get("confirm") is not True:
            return _ae(lang, "confirm", 428)
        pid = str(request.data.get("pending_id") or "")
        now = timezone.now().timestamp()
        p = next((x for x in _auto(site).get("pending") or [] if x.get("id") == pid), None)
        if p is None or float(p.get("until") or 0) < now:
            return _ae(lang, "expired", 410)
        client, _uid = tuya_link(site)
        if client is None:
            return _ae(lang, "not_linked", 409)
        try:
            client.lock(p["device_id"], lock=True)
        except T.TuyaError as e:
            return _ae(lang, "device_error", 502, vendor_code=e.code)

        def f(au):
            au["pending"] = [x for x in au.get("pending") or [] if x.get("id") != pid]
            au["log"] = (list(au.get("log") or []) + [
                {"at": timezone.now().isoformat(), "event_id": p.get("event_id"),
                 "ran": [{"device": p.get("name") or "", "kind": "lock", "state": "locked",
                          "by": request.user.pk}]}])[-AUTO_LOG_MAX:]
        guard_update(site, "_auto", f)
        return Response({"ok": True, "locked": True})


# ======================================================================= F
KEY_ERRS = {
    "bad_key": ("চাবি ঠিক নেই।", "Invalid key."),
    "no_signature": ("সই নেই।", "Missing signature."),
    "bad_timestamp": ("সময় ঠিক নেই।", "Invalid timestamp."),
    "stale": ("অনুরোধ পুরোনো — ঘড়ি মিলিয়ে আবার পাঠান।", "Request too old — sync the clock and resend."),
    "bad_signature": ("সই মেলেনি।", "Signature does not match."),
    "too_big": ("অনুরোধ খুব বড়।", "Request too large."),
    "bad_json": ("JSON ঠিক নেই।", "Invalid JSON."),
}


def _poskey(site):
    k = guard_get(site, "_poskey") or {}
    return k if isinstance(k, dict) else {}


def _keys_for(site, kid, now_ts):
    from . import remittance_service as RS
    pk = _poskey(site)
    out = []
    if pk.get("kid") == kid and pk.get("sealed"):
        out.append((RS.unseal(pk["sealed"]) or {}).get("k"))
    prev = pk.get("prev") or {}
    if prev.get("kid") == kid and prev.get("sealed") and float(prev.get("until") or 0) > now_ts:
        out.append((RS.unseal(prev["sealed"]) or {}).get("k"))
    return [k for k in out if k]


def webhook_url(request=None):
    from django.conf import settings
    from .public_url import public_base_url
    base = public_base_url()
    return base + "/api/v1/shop/pos/webhook"


class PosKeyView(_OwnerBase):
    """GET the key's state (never the secret); POST {partner} creates or
    rotates (the old key works for 24 h more) and shows the secret ONCE;
    DELETE revokes at once."""

    def _state(self, site, lang):
        pk = _poskey(site)
        from django.db.models import Max, Count
        agg = site.pos_events.exclude(source="").aggregate(n=Count("id"), last=Max("at"))
        return {"site": site.id, "has_key": bool(pk.get("kid")), "key_id": pk.get("kid"),
                "partner": pk.get("partner") or None, "created": pk.get("created"),
                "url": webhook_url(), "events": agg["n"] or 0,
                "last_at": agg["last"].isoformat() if agg["last"] else None,
                "doc": "owner_actions/CCTV_POS_WEBHOOK.md",
                "note": pick(lang, "এই চাবি শুধু আপনার POS কোম্পানিকে দিন। Assisto কখনো POS-এর সার্ভারে যায় না — POS নিজে Assisto-তে পাঠায়।",
                             "Give this key only to your POS company. Assisto never calls the POS "
                             "server — the POS sends to Assisto.")}

    def get(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(self._state(site, lang))

    def post(self, request, pk):
        from . import remittance_service as RS
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        partner = "asalify" if request.data.get("partner") == "asalify" else "pos"
        secret = "ask_" + secrets.token_urlsafe(32)
        kid = "ak_%d_%s" % (site.id, secrets.token_hex(5))
        now = timezone.now()

        def f(k):
            if k.get("kid") and k.get("sealed"):
                k["prev"] = {"kid": k["kid"], "sealed": k["sealed"],
                             "until": now.timestamp() + A.KEY_GRACE_S}
            k.update({"kid": kid, "sealed": RS.seal({"k": secret}), "partner": partner,
                      "created": now.isoformat()})
        guard_update(site, "_poskey", f)
        out = self._state(site, lang)
        out.update({"secret": secret, "secret_once": True})
        return Response(out, status=201)

    def delete(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        guard_update(site, "_poskey", lambda k: k.clear())
        return Response(self._state(site, lang))


def save_pos_rows(site, rows, source):
    """-> (created, duplicates). Unique (site, source, ext_id) = replay-safe."""
    from .models import ShopPosEvent
    created = dup = 0
    for r in rows:
        if ShopPosEvent.objects.filter(site=site, source=source, ext_id=r["ext_id"]).exists():
            dup += 1
            continue
        try:
            with transaction.atomic():
                ShopPosEvent.objects.create(site=site, kind=r["kind"], amount=r["amount_taka"],
                                            at=r["at"], source=source, ext_id=r["ext_id"],
                                            meta=r["meta"])
            created += 1
        except IntegrityError:
            dup += 1
    return created, dup


class PosWebhookView(APIView):
    """POST shop/pos/webhook — a partner POS (the first: Asalify POS, built
    by the Asalify team on THEIR side) sends sale / refund / void /
    discount / cash_drawer events. Headers:
      X-Assisto-Key-Id: ak_<site>_<id>
      X-Assisto-Timestamp: <unix seconds>
      X-Assisto-Signature: v1=<hex HMAC-SHA256(secret, "v1:<ts>:<raw body>")>
    Body: one event or {"events": [...]} (≤100). A repeated event_id is a
    duplicate (200, not stored twice). Assisto never calls back."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        raw = request.body or b""

        def e(code, status):
            return _err(lang, *KEY_ERRS[code], status=status, code=code)
        if len(raw) > A.MAX_BODY:
            return e("too_big", 413)
        kid = request.META.get("HTTP_X_ASSISTO_KEY_ID") or ""
        sid = A.kid_site(kid)
        from .models import ShopSite
        site = ShopSite.objects.filter(pk=sid).first() if sid else None
        now = timezone.now()
        keys = _keys_for(site, kid, now.timestamp()) if site is not None else []
        if not keys:
            return e("bad_key", 401)
        ok, code = A.verify(keys, request.META.get("HTTP_X_ASSISTO_TIMESTAMP"),
                            request.META.get("HTTP_X_ASSISTO_SIGNATURE"), raw, now.timestamp())
        if not ok:
            return e(code, 401)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return e("bad_json", 400)
        events = body.get("events") if isinstance(body, dict) and "events" in body else [body]
        if not isinstance(events, list) or not events or len(events) > A.MAX_BATCH:
            return e("bad_json", 400)
        source = _poskey(site).get("partner") or "pos"
        rows, errors = [], []
        for i, ev in enumerate(events):
            r, err = A.normalize_pos(ev, now, source)
            if err:
                errors.append({"index": i, "code": err})
            else:
                rows.append(r)
        created, dup = save_pos_rows(site, rows, source)
        status = 200 if not errors else (207 if rows else 422)
        return Response({"ok": not errors, "accepted": created, "duplicates": dup,
                         "errors": errors}, status=status)


class PosCsvView(_OwnerBase):
    """POST {csv} — import a POS export (time, type, amount, id)."""

    def post(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        text = request.data.get("csv")
        if not text and request.FILES.get("file") is not None:
            f = request.FILES["file"]
            if f.size > 1024 * 1024:
                return _err(lang, *KEY_ERRS["too_big"], status=413, code="too_big")
            text = f.read().decode("utf-8-sig", errors="replace")
        if not isinstance(text, str) or not text.strip():
            return _err(lang, "ফাইল খালি।", "The file is empty.", status=422, code="empty")
        if len(text) > 1024 * 1024:
            return _err(lang, *KEY_ERRS["too_big"], status=413, code="too_big")
        rows, errors = A.parse_csv(text, timezone.now())
        created, dup = save_pos_rows(site, rows, "csv")
        return Response({"ok": True, "accepted": created, "duplicates": dup,
                         "errors": errors[:50], "error_count": len(errors)})


def _day_bounds(date_str):
    d = datetime.strptime(date_str, "%Y-%m-%d").date()
    tz = timezone.get_current_timezone()
    lo = timezone.make_aware(datetime(d.year, d.month, d.day), tz)
    return lo, lo + timedelta(days=1)


def _date_arg(request, now):
    v = (request.query_params.get("date") or request.data.get("date") or "") \
        if hasattr(request, "query_params") else ""
    try:
        return datetime.strptime(str(v), "%Y-%m-%d").date().isoformat()
    except ValueError:
        return _local(now).date().isoformat()


def _has_clip(ev):
    try:
        return ev.clip is not None
    except Exception:
        return bool((ev.signals or {}).get("clip_ref")) if isinstance(ev.signals, dict) else False


def match_items(site, date_str, scope=None):
    """Review-only items for one day (drawer with no sale; possible cash to
    pocket after a sale) from POS rows + Assisto sales/khata + camera events."""
    from .models import KhataEntry
    lo, hi = _day_bounds(date_str)
    pad = timedelta(seconds=A.DRAWER_WINDOW_S + A.AFTER_SALE_MAX_S)
    pos = list(site.pos_events.filter(at__gte=lo - pad, at__lt=hi + pad)
               .values("id", "kind", "amount", "at")[:20000])
    sales = [{"at": p["at"].timestamp(), "kind": "sale", "amount": p["amount"]}
             for p in pos if p["kind"] == "sale"]
    try:
        for at in KhataEntry.objects.filter(party__business__user_id=site.owner_id,
                                            at__gte=lo - pad, at__lt=hi + pad
                                            ).values_list("at", flat=True)[:5000]:
            sales.append({"at": at.timestamp(), "kind": "khata", "amount": 0})
    except Exception:
        pass
    evs = list(site.events.filter(created__gte=lo, created__lt=hi, pending=False,
                                  type__in=("hand_in_cash_zone", "drawer_open",
                                            "pose_possible", "motion", "person_detected"))
               .select_related("camera")[:5000])
    cam_events = [{"id": e.id, "at": e.created.timestamp(), "type": e.type,
                   "signals": e.signals, "camera": e.camera.name if e.camera else "",
                   "camera_id": e.camera_id, "has_clip": _has_clip(e)} for e in evs
                  if scope is None or _cam_ok(scope, e.camera_id)]
    drawers = [{"id": p["id"], "at": p["at"].timestamp(), "source": "pos"}
               for p in pos if p["kind"] == "drawer_open" and lo <= p["at"] < hi]
    pos_drawer_ts = [d["at"] for d in drawers]
    for e in cam_events:
        if e["type"] == "drawer_open" and not any(abs(e["at"] - t) <= 30 for t in pos_drawer_ts):
            drawers.append({"id": e["id"], "at": e["at"], "source": "camera",
                            "event_id": e["id"]})
    return A.sales_match(drawers, sales, cam_events)


class SalesMatchView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        date_str = _date_arg(request, now)
        items = match_items(site, date_str)
        out = []
        for it in items[:100]:
            hhmm = _local(datetime.fromtimestamp(it["at"], tz=dt_timezone.utc)).strftime("%H:%M")
            out.append(dict(it, time=hhmm, text=A.review_text(it, lang, hhmm)))
        lo, hi = _day_bounds(date_str)
        feeds = sorted({s or "assisto" for s in site.pos_events.filter(
            at__gte=lo, at__lt=hi).values_list("source", flat=True)[:2000]})
        return Response({"site": site.id, "date": date_str, "items": out,
                         "feeds": feeds, "note": pick(lang, *A.REVIEW_NOTE),
                         "pos_key": bool(_poskey(site).get("kid"))})


# ======================================================================= E
def _box_stats(site, date_str):
    days = (guard_get(site, "_act3") or {}).get("box") or {}
    return days.get(date_str) or {}


def report_inputs(site, date_str, now, lang):
    from . import cctv_activity as CACT
    view = CACT.day_view(site, date_str, now, lang)
    lo, hi = _day_bounds(date_str)
    evs = site.events.filter(created__gte=lo, created__lt=hi, pending=False)
    by_type = {}
    wrong = 0
    veh = {"in": 0, "out": 0}
    veh_seen = False
    for t, st, sig in evs.values_list("type", "status", "signals")[:5000]:
        by_type[t] = by_type.get(t, 0) + 1
        wrong += 1 if st == "false_alarm" else 0
        inp = (sig or {}).get("inputs") if isinstance(sig, dict) else {}
        inp = inp if isinstance(inp, dict) else {}
        if inp.get("kind") == "vehicle":
            veh_seen = True
            d = str(inp.get("direction") or "")
            if d in ("in", "a_to_b"):
                veh["in"] += 1
            elif d in ("out", "b_to_a"):
                veh["out"] += 1
    box = _box_stats(site, date_str)
    if isinstance(box.get("vehicles"), dict):
        veh = {"in": int(box["vehicles"].get("in") or 0), "out": int(box["vehicles"].get("out") or 0)}
        veh_seen = True
    hourly = [0] * 24
    for r in view["foot"]["rows"]:
        hourly[r["hour"]] = r["visitors"]
    review = match_items(site, date_str)
    health = []
    for h in view["health"]:
        health.append({"name": h.get("name") or "", "offline_min": h.get("offline_min") or 0,
                       "sd": h.get("sd") or "unknown"})
    tables = box.get("tables") if isinstance(box.get("tables"), dict) else None
    kind = site_use(site)
    # cctvconnect (when merged): camera-own people counting (Imou passenger
    # flow) and the DVR health card (recorded days). Absent -> skipped.
    visitors = view["foot"]["visitors"]
    dvr = None
    try:
        from . import cctv_connect_views as CCV
        pc = CCV.people_counts(site, day=date_str) or {}
        if not visitors and int(pc.get("count") or pc.get("in") or 0):
            visitors = int(pc.get("count") or pc.get("in") or 0)
            hourly = [0] * 24
            for c in pc.get("cameras") or []:
                for hh, n in ((c or {}).get("hours") or {}).items():
                    try:
                        hourly[int(hh) % 24] += int(n or 0)
                    except (TypeError, ValueError):
                        pass
        dvr = CCV.site_card(site, lang)
    except Exception:
        dvr = None
    return {"site_kind": kind,
            "hours": site.hours if isinstance(site.hours, dict) else {},
            "open_at": view["open_close"].get("open"), "close_at": view["open_close"].get("close"),
            "visitors": visitors, "hourly": hourly, "dvr": dvr,
            "alerts": {"total": sum(by_type.values()), "wrong": wrong, "by_type": by_type},
            "counter_empty_min": (int(box["counter_empty_min"])
                                  if isinstance(box.get("counter_empty_min"), (int, float)) else None),
            "vehicles": veh if (veh_seen or kind == "parking") else None,
            "tables": tables, "health": health,
            "sales": {"count": view["foot"]["sales"], "taka": int(view["foot"]["amount"] or 0)},
            "review_items": review}


SITE_USES = ("shop", "cafe", "parking", "office", "warehouse", "home", "gate")


def site_use(site):
    u = (guard_get(site, "_act3") or {}).get("use")
    return u if u in SITE_USES else ("home" if getattr(site, "kind", "") == "home" else "shop")


def report_cfg(site):
    st = guard_get(site, "_act3") or {}
    return {"use": site_use(site), "push": st.get("push") is not False,
            "uses": list(SITE_USES)}


def build_report(site, date_str, now, lang):
    inp = report_inputs(site, date_str, now, lang)
    rep = A.closing_report(inp, lang)
    return {"site": site.id, "name": site.name or "", "date": date_str,
            "title": A.report_title(lang, site.name, date_str),
            "lines": rep["lines"], "sections": rep["sections"], "all_ok": rep["ok"],
            "cfg": report_cfg(site),
            "measured": {"counter": inp["counter_empty_min"] is not None,
                         "vehicles": inp["vehicles"] is not None,
                         "tables": inp["tables"] is not None},
            "privacy": pick(lang, "মানুষ গোনা হয় পরিচয় ছাড়া — মুখ চেনা নেই।",
                            "People are counted with no identity — no face recognition.")}


class ClosingReportView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        site, role = _site(request, pk, owner_only=False)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        return Response(build_report(site, _date_arg(request, now), now, lang))

    def put(self, request, pk):
        """Owner: {use: shop|cafe|parking|..., push: bool}."""
        lang = req_lang(request)
        site, _ = _site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        use = request.data.get("use")
        push = request.data.get("push")

        def f(st):
            if use in SITE_USES:
                st["use"] = use
            if isinstance(push, bool):
                st["push"] = push
        guard_update(site, "_act3", f)
        return Response(report_cfg(site))

    post = put


def run_closing(site, now):
    """Once a day after closing: the report as a push (Bangla first, each
    person in their language). Never raises."""
    try:
        local = _local(now)
        today = local.date().isoformat()
        st = guard_get(site, "_act3") or {}
        if st.get("push") is False:
            return False
        if not A.report_due(site.hours if isinstance(site.hours, dict) else {},
                            local.hour * 60 + local.minute, st.get("sent"), today):
            return False
        claimed = guard_update(site, "_act3", lambda s: (s.get("sent") != today) and
                               (s.__setitem__("sent", today) or True))
        if not claimed:
            return False
        reps = {lg: build_report(site, today, now, lg) for lg in ("bn", "en")}
        if not (reps["bn"]["sections"]["people"]["visitors"] or
                reps["bn"]["sections"]["alerts"].get("total") or
                reps["bn"]["sections"]["open_close"].get("open_at")):
            return False
        from . import cctvx_views as X
        X.notice_site(site, "closing_report",
                      lambda lang: (reps[lang]["title"], "\n".join(reps[lang]["lines"][:6])),
                      quiet=False, severity="info", data={"date": today, "screen": "closing"})
        return True
    except Exception:
        log.exception("closing report failed for site %s", site.pk)
        return False


def tick_site(site, now):
    """From cctvx_views.tick, every minute. Never raises."""
    out = {}
    try:
        out["closing"] = run_closing(site, now)
    except Exception:
        log.exception("cctvact closing tick failed")
    try:
        out["offs"] = run_offs(site, now)
    except Exception:
        log.exception("cctvact offs tick failed")
    return out


class DeviceDailyStatsView(APIView):
    """POST (device token) {date, counter_empty_min?, vehicles?{in,out},
    tables?{avg_pct, peak_pct, peak_hour}} — numbers the Guard Box measured
    on its own (no pictures, no identity). Kept 35 days."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        site, _cam = SV._resolve_device_site(request)
        if site is None:
            return Response({"error": "bad_token"}, status=401)
        d = request.data if isinstance(request.data, dict) else {}
        try:
            date_str = datetime.strptime(str(d.get("date") or ""), "%Y-%m-%d").date().isoformat()
        except ValueError:
            date_str = _local(timezone.now()).date().isoformat()
        rec = {}

        def num(v, hi):
            try:
                x = int(round(float(v)))
                return x if 0 <= x <= hi else None
            except (TypeError, ValueError):
                return None
        if num(d.get("counter_empty_min"), 1440) is not None:
            rec["counter_empty_min"] = num(d["counter_empty_min"], 1440)
        v = d.get("vehicles")
        if isinstance(v, dict) and num(v.get("in"), 100000) is not None:
            rec["vehicles"] = {"in": num(v.get("in"), 100000) or 0,
                               "out": num(v.get("out"), 100000) or 0}
        t = d.get("tables")
        if isinstance(t, dict) and num(t.get("avg_pct"), 100) is not None:
            rec["tables"] = {"avg_pct": num(t.get("avg_pct"), 100),
                             "peak_pct": num(t.get("peak_pct"), 100) or 0,
                             "peak_hour": num(t.get("peak_hour"), 23) or 0}
        if not rec:
            return Response({"error": "nothing"}, status=422)

        def f(s):
            box = dict(s.get("box") or {})
            box[date_str] = dict(box.get(date_str) or {}, **rec)
            s["box"] = {k: box[k] for k in sorted(box)[-35:]}
        guard_update(site, "_act3", f)
        return Response({"ok": True, "date": date_str, "saved": sorted(rec)})


# ======================================================================= G
ASK_MAX_RESULTS = 20
ASK_ERRS = {"empty": ("কিছু লিখে জিজ্ঞেস করুন।", "Type a question.")}


def ai_parse(q, today, user):
    """The shared AI router (Claude; Gemini is off) reads the question into
    a JSON filter. None when AI is not available — the rules still work."""
    try:
        from . import ai
        text, _cost = ai.generate(A.AI_PARSE_TASK % today.isoformat(), data=q[:300],
                                  tier="cheap", max_tokens=200, feature="cctv_ask",
                                  user=user, task_class="cheap", pii=True)
        return A.parse_ai_json(text)
    except Exception:
        return None


def ask(site, q, lang, user, scope=None, now=None, use_ai=True):
    now = now or timezone.now()
    today = _local(now).date()
    base = A.parse_question(q, today)
    used_ai = False
    if use_ai and not any(base.get(k) for k in ("zone", "kind", "intent", "colour")):
        d = ai_parse(q, today, user)
        if d:
            base = A.clean_ai_filter(d, base)
            used_ai = True
    f = base
    lo, _hi = _day_bounds(f["date"])
    hi = lo + timedelta(hours=30)
    evs = list(site.events.filter(created__gte=lo, created__lt=hi, pending=False)
               .select_related("camera").order_by("-created")[:3000])
    matches = []
    for e in evs:
        if scope is not None and not _cam_ok(scope, e.camera_id):
            continue
        local = _local(e.created)
        at_min = int((e.created - lo).total_seconds() // 60)
        if f.get("from_min") is None and at_min >= 1440:
            continue
        row = {"type": e.type, "at_min": at_min, "signals": e.signals,
               "camera_name": e.camera.name if e.camera else ""}
        if not A.event_matches(row, f):
            continue
        sig = e.signals if isinstance(e.signals, dict) else {}
        inp = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else {}
        what_bn, what_en = SV.EVENT_WORDS.get(e.type, SV.EVENT_WORDS["motion"])
        matches.append({"event_id": e.id, "hhmm": local.strftime("%H:%M"),
                        "camera_name": row["camera_name"], "what": pick(lang, what_bn, what_en),
                        "colour": inp.get("colour") or inp.get("color") or None,
                        "zone": inp.get("zone") or inp.get("zone_name") or None,
                        "snapshot_url": SV._abs_snapshot_url(e) or None,
                        "has_clip": _has_clip(e)})
    oc = None
    if f.get("intent") in ("shutter_open", "shop_close"):
        try:
            from . import cctv_activity as CACT
            oc = CACT.day_view(site, f["date"], now, lang)["open_close"]
        except Exception:
            oc = None
    return {"q": q[:200], "filter": {k: f.get(k) for k in ("date", "from_min", "to_min", "kind",
                                                           "colour", "zone", "intent")},
            "answer": A.answer_lines(f, matches, lang, oc),
            "results": matches[:ASK_MAX_RESULTS], "total": len(matches), "used_ai": used_ai,
            "privacy": pick(lang, "মুখ চেনা নেই, পরিচয় নেই — শুধু সময়, জায়গা, রং আর ধরন দিয়ে খোঁজা।",
                            "No face recognition, no identity — searched by time, place, "
                            "colour and type only.")}


class AskView(_OwnerBase):
    def post(self, request, pk):
        lang = req_lang(request)
        site, role = _site(request, pk, owner_only=False)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        q = str(request.data.get("q") or "").strip()
        if not q:
            return _err(lang, *ASK_ERRS["empty"], status=422, code="empty")
        # reply in the language of the question (Bangla script -> Bangla)
        import re
        qlang = "bn" if re.search(r"[ঀ-৿]", q) else lang
        scope = None if role == "owner" else _scope(site, request.user)
        return Response(ask(site, q, qlang, request.user, scope=scope))
