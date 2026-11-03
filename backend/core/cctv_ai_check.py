"""
cctv_ai_check.py — AI check of the ALERT SNAPSHOT (agent/cctvaicheck; owner
CCTV order B, audit W4 B3/B4). Pure rules: core/logic/cctv_ai_check.py.

  check_due(now)            from cctvx_views.tick (shop_guard_tick, every
                            minute; no new cron): up to PER_TICK fresh alerts
                            with a photo get ONE vision call each — only with
                            a vision key (the existing switchable providers
                            in core/vision_providers.py, picked by
                            chat_vision_service — never a new provider), the
                            camera's "AI দিয়ে যাচাই" switch on, and room in
                            the account's monthly AI allowance
                            (logic/cctv_ai_budget.py, shared with the visitor
                            descriptions).
  event_label(ev, lang)     the {state, cls, conf, likely_false, text} shown
                            on the alert (shop_views._event_row).
  camera_payload(cam, lang) the per-camera switch for the alert-types screen.

The alert and its push are NEVER held back or hidden: they go out in
_ingest_event exactly as before; this only adds a label ~1 minute later.
Only the one still is sent (shrunk to 512 px) — never video, never audio.
Every call lands in the AIUsage ledger (feature "cctv_ai_check", provider
token counts) and the Profit Guard. Behind the existing home_watchman /
cctv_watchman switches. Never raises into the tick or a list view.
"""
import io
import logging
import time
from datetime import timedelta

from django.utils import timezone

from .logic import cctv_ai_check as AC

log = logging.getLogger(__name__)

FEATURE = "cctv_ai_check"


# ---------------------------------------------------------------- key / cost
def vision_key():
    """(slug, conf, provider_cost_usd) of the active vision provider, or
    (None, None, 0.0)."""
    try:
        from . import chat_vision_service as CVS
        slug, conf, cost = CVS._active()
        if slug:
            return slug, conf or {}, float(cost or 0)
    except Exception:
        pass
    return None, None, 0.0


def key_ready_for(request):
    """vision key present? asked ONCE per request (list views label 200 rows)."""
    if request is None:
        return bool(vision_key()[0])
    v = getattr(request, "_cctv_ai_key_ready", None)
    if v is None:
        v = bool(vision_key()[0])
        try:
            setattr(request, "_cctv_ai_key_ready", v)
        except Exception:
            pass
    return v


def plan_check_usd():
    """The profit table's per-check cost assumption (cctv_plan.ai_check_usd)."""
    try:
        from . import billing
        from .logic import cctv_plan as CP
        return float(CP.normalize_cfg(billing.cfg().get("cctv_plan")).get("ai_check_usd"))
    except Exception:
        try:
            from .logic import cctv_plan as CP
            return float(CP.defaults()["ai_check_usd"])
        except Exception:
            return 0.002


def switch_on(cam, key_ready=None):
    if key_ready is None:
        key_ready = bool(vision_key()[0])
    return AC.camera_switch(getattr(cam, "zone_config", None), key_ready)


# ---------------------------------------------------------------- image
def shrink(raw):
    """JPEG, longest side <= IMAGE_MAX_PX (fewer image tokens = lower cost).
    Falls back to the original bytes (<= 2 MB) when Pillow can't read it."""
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw))
        im = im.convert("RGB")
        im.thumbnail((AC.IMAGE_MAX_PX, AC.IMAGE_MAX_PX))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=80)
        return out.getvalue(), "image/jpeg"
    except Exception:
        if raw and len(raw) <= 2 * 1024 * 1024:
            return raw, ("image/png" if raw[:4] == b"\x89PNG" else "image/jpeg")
        return None, None


# ---------------------------------------------------------------- ledger
def _ledger(owner, slug, conf, usage, cost, ok, latency_ms, error_kind=""):
    try:
        from .models import AIUsage
        from . import vision_providers as VP
        model = ((conf or {}).get("model") or VP.DEFAULT_MODELS.get(slug, "") or "")
        AIUsage.objects.create(
            user=owner, feature=FEATURE, model=str(model)[:40],
            input_tokens=int(usage.get("input_tokens", 0) or 0),
            output_tokens=int(usage.get("output_tokens", 0) or 0),
            cost_usd=float(cost if ok else 0.0), provider=str(slug or "")[:20],
            task_class="vision", latency_ms=int(latency_ms), ok=bool(ok),
            error_kind=str(error_kind or "")[:30])
    except Exception:
        log.exception("cctv ai check ledger failed")
    if ok and cost:
        try:
            from . import billing
            billing.record_ai_cost_usd(cost)     # Profit Guard (USD -> ৳ ledger)
        except Exception:
            pass


# ---------------------------------------------------------------- one check
def _save(ev, ai):
    from .models import ShopEvent
    sig = dict(ev.signals) if isinstance(ev.signals, dict) else {}
    sig["ai_check"] = ai
    ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
    ev.signals = sig
    return ai


def check_one(ev, slug, conf, prov_cost, now=None):
    """AI check for ONE alert photo. Returns the stored ai_check dict."""
    from .logic import cctv_ai_budget as BUD
    from . import vision_providers as VP
    from . import cctv_activity as CACT
    now = now or timezone.now()
    cam = ev.camera
    if not slug:
        return _save(ev, {"state": "no_key"})
    if cam is None or not switch_on(cam, True):
        return _save(ev, {"state": "off"})
    cost, cost_ok = AC.check_cost_usd(prov_cost, plan_check_usd())
    if not cost_ok:
        return _save(ev, {"state": "cost"})
    if not BUD.ai_check_allowed(cam, now):
        return _save(ev, {"state": "cap"})
    raw = CACT.snapshot_bytes(ev)
    img, mime = shrink(raw) if raw else (None, None)
    if not img:
        return _save(ev, {"state": "no_photo"})
    # the allowance is taken BEFORE the call: a paid call is never free
    BUD.ai_check_used(cam, now)
    _save(ev, {"state": "pending", "at": now.isoformat()})
    usage = {}
    t0 = time.monotonic()
    try:
        reply = VP.ask(slug, conf, image_bytes=img, mime=mime, system=AC.SYSTEM,
                       question=AC.QUESTION, timeout=AC.TIMEOUT_S,
                       max_tokens=AC.MAX_TOKENS, usage=usage)
        err = ""
    except Exception as e:  # noqa: BLE001 — VisionError / timeout -> honest label
        reply, err = None, (str(e) or type(e).__name__)
    latency = int((time.monotonic() - t0) * 1000)
    parsed = AC.parse_reply(reply) if reply else None
    if parsed is None:
        # a reply that came back is still paid; a timeout usually is not
        _ledger(ev.site.owner, slug, conf, usage, cost, bool(reply), latency,
                err or "bad_reply")
        return _save(ev, {"state": "failed"})
    _ledger(ev.site.owner, slug, conf, usage, cost, True, latency)
    out = AC.result_of(parsed)
    out["at"] = now.isoformat()
    return _save(ev, out)


def check_due(now=None, limit=AC.PER_TICK):
    """Bounded pass over fresh alerts with a photo. Never raises."""
    now = now or timezone.now()
    out = {"checked": 0, "skipped": 0}
    try:
        slug, conf, prov_cost = vision_key()
        if not slug:
            return out                     # labels say "no AI key" at read time
        from .models import ShopEvent
        from . import cctv_alerts as CA
        qs = (ShopEvent.objects.filter(created__gte=now - timedelta(minutes=AC.MAX_AGE_MIN),
                                       pending=False, type__in=AC.CHECK_TYPES)
              .exclude(snapshot="").exclude(snapshot__isnull=True)
              .select_related("site", "site__owner", "camera").order_by("-created")[:40])
        for ev in qs:
            if out["checked"] >= limit:
                break
            sig = ev.signals if isinstance(ev.signals, dict) else {}
            if isinstance(sig.get("ai_check"), dict):
                continue
            if not CA.feature_on_for(ev.site.owner):
                continue
            r = check_one(ev, slug, conf, prov_cost, now)
            if r.get("state") == "done":
                out["checked"] += 1
            else:
                out["skipped"] += 1
    except Exception:
        log.exception("cctv ai check pass failed")
    return out


# ---------------------------------------------------------------- read side
def event_label(ev, lang="bn", now=None, key_ready=None):
    """Label for one alert row, or None for alert types the AI never checks."""
    try:
        if ev.type not in AC.CHECK_TYPES:
            return None
        sig = ev.signals if isinstance(ev.signals, dict) else {}
        ai = sig.get("ai_check") if isinstance(sig.get("ai_check"), dict) else None
        now = now or timezone.now()
        stale = ev.created and ev.created < now - timedelta(minutes=AC.MAX_AGE_MIN)
        if ai is None:
            if not ev.snapshot:
                ai = {"state": "no_photo"}
            elif not (key_ready if key_ready is not None else vision_key()[0]):
                ai = {"state": "no_key"}
            elif ev.camera_id and ev.camera and not switch_on(ev.camera, True):
                ai = {"state": "off"}
            else:
                ai = {"state": "failed" if stale else "pending"}
        elif ai.get("state") == "pending" and stale:
            ai = {"state": "failed"}
        return AC.label(ai, lang)
    except Exception:
        return None


def camera_payload(cam, lang="bn"):
    """The "AI দিয়ে যাচাই" switch for one camera (alert-types screen)."""
    from .logic import cctv_ai_budget as BUD
    bn = lang == "bn"
    slug = vision_key()[0]
    ready = bool(slug)
    try:
        st = BUD.ai_check_status(cam)
    except Exception:
        st = {"used": 0, "cap": 0, "left": 0}
    d = AC.bn_digits if bn else str
    if not ready:
        note = ("AI চাবি যুক্ত নেই — তাই যাচাই হয় না; সতর্কতা আগের মতোই আসে।" if bn else
                "No AI key connected — no check; alerts still come as before.")
    else:
        note = ("সতর্কতা সাথে সাথেই যায়; তারপর শুধু ছবিটা AI দেখে বলে মানুষ / গাড়ি / প্রাণী "
                "নাকি কিছুই না। ভিডিও বা শব্দ কখনো যায় না, কাউকে চেনা হয় না। "
                "এই মাসে ব্যবহার %s / %s।" % (d(st["used"]), d(st["cap"])) if bn else
                "The alert goes out at once; then only the photo is shown to the AI: person, "
                "vehicle, animal or nothing. Never video or sound, nobody is identified. "
                "Used this month: %s / %s." % (st["used"], st["cap"]))
    return {"on": switch_on(cam, ready), "ready": ready,
            "used": st["used"], "cap": st["cap"],
            "title": "AI দিয়ে যাচাই" if bn else "Check with AI",
            "note": note}


def set_switch(cam, on):
    from .models import ShopCamera
    zc = dict(cam.zone_config) if isinstance(cam.zone_config, dict) else {}
    zc["ai_check"] = bool(on)
    ShopCamera.objects.filter(pk=cam.pk).update(zone_config=zc)
    cam.zone_config = zc
