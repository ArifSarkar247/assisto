"""
shop_views.py — CCTV / shop loss-prevention (Business, Part 4): the ingest +
alert + config BACKEND. DRF wiring only; the decision logic is pure in
core/logic/shop_guard.py.

TWO AUTH WORLDS (never mixed):
  * DEVICE endpoints (ingest, pos) authenticate with a per-shop ENROLLMENT
    TOKEN (ShopSite.enrollment_token) or a per-camera token — NOT a user login.
    AllowAny + explicit token resolution; a device can WRITE its own site's
    signals and NOTHING else (it can never read another owner's events).
  * OWNER endpoints (sites, cameras, events, summary, retention) use the normal
    Token auth + the owner/business gate (a site is scoped to request.user).

HARD SAFETY RULES enforced here:
  * NO VIDEO is ever accepted or stored — only `signals` (JSON) + AT MOST ONE
    small snapshot image, auto-deleted after the site's retention window.
  * Heavy AI never runs on this server: the edge/Shop Box detects; we only
    receive the SIGNALS and run the pure, deterministic shop_guard.combine().
  * An alert is raised only on COMBINED signals (shop_guard's rule), never a
    single input; a lone pose is at most a low-confidence "possible".
  * The owner-facing wording is ALWAYS "please check camera X" — NEVER "theft".
    Confidence is always shown; the owner marks false alarms.
"""
from datetime import timedelta

from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import shop_guard as SG


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _err(lang, bn, en, status=400, **extra):
    d = {"error": extra.pop("code", "error"), "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


# POS correlation window + a short ingest rate-limit (abuse guard on the public
# device webhook). Per site+type: at most this many ingests in the window.
INGEST_WINDOW_S = 2
INGEST_MAX_PER_WINDOW = 10


def _resolve_device_site(request):
    """Resolve the ShopSite a DEVICE request is authenticated for, from either a
    `site_token` (enrollment token) or a `camera_token`. Returns
    (site, camera_or_None) or (None, None). NO user login involved.

    Tokens come from the body, or (for GET device calls) from the
    `X-Shop-Token` header (a camera OR site token — never the query string, so
    tokens stay out of access logs). With a SITE token the device may name one
    of that site's cameras via `camera_id` / `X-Shop-Camera`."""
    from .models import ShopSite, ShopCamera
    try:
        data = request.data if hasattr(request, "data") else {}
    except Exception:
        data = {}
    if not hasattr(data, "get"):
        data = {}
    site_token = str(data.get("site_token") or "").strip()
    cam_token = str(data.get("camera_token") or "").strip()
    hdr = (request.META.get("HTTP_X_SHOP_TOKEN") or "").strip()
    if hdr and not (site_token or cam_token):
        cam_token = site_token = hdr
    if cam_token:
        cam = ShopCamera.objects.filter(camera_token=cam_token).select_related(
            "site").first()
        if cam is not None:
            return (cam.site, cam)
    if site_token:
        site = ShopSite.objects.filter(enrollment_token=site_token).first()
        if site is not None:
            cid = data.get("camera_id") or request.META.get("HTTP_X_SHOP_CAMERA")
            cam = None
            if cid not in (None, ""):
                try:
                    cam = site.cameras.filter(pk=int(cid)).first()
                except (TypeError, ValueError):
                    cam = None
            return (site, cam)
    return (None, None)


def _touch_seen(site, cam, now):
    """Any authenticated device call proves the device is alive (a2-cctv)."""
    from .models import ShopSite, ShopCamera
    try:
        ShopSite.objects.filter(pk=site.pk).update(last_seen=now)
        if cam is not None:
            ShopCamera.objects.filter(pk=cam.pk).update(last_seen=now)
    except Exception:
        pass


def _pos_rows_for(site, now, window_s):
    """Recent ShopPosEvent rows (as the plain dicts shop_guard wants), within a
    generous lookback so the correlation window has data to match against."""
    since = now - timedelta(seconds=max(window_s, SG.DEFAULT_WINDOW_S) + 5)
    rows = site.pos_events.filter(at__gte=since)
    out = []
    for p in rows:
        out.append({"kind": p.kind, "amount": p.amount, "at": p.at.timestamp()})
    return out


def _owner_site(request, pk):
    """Fetch a ShopSite the authenticated user OWNS, or None (owner gate)."""
    from .models import ShopSite
    return ShopSite.objects.filter(pk=pk, owner=request.user).first()


# ---------------------------------------------------------------------------
# DEVICE INGEST (enrollment-token auth, NOT a user login)
# ---------------------------------------------------------------------------

class ShopIngestView(APIView):
    """POST shop/ingest — a camera / Shop Box posts a detection SIGNAL.

    Body: {site_token|camera_token, type, signals?, at?, snapshot?(multipart)}.
    Runs shop_guard.combine() against recent POS rows. If it raises, create a
    ShopEvent (+ at most the one snapshot) and notify the owner. Else log/ignore.
    NEVER stores video; NEVER runs AI here."""
    permission_classes = [AllowAny]
    authentication_classes = []        # device token, not a user session

    def post(self, request):
        lang = req_lang(request)
        site, cam = _resolve_device_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")

        etype = (request.data.get("type") or "").strip()
        valid = {t for t, _ in _shop_event_types()}
        if etype not in valid:
            return _err(lang, "ইভেন্টের ধরন ভুল।", "Invalid event type.",
                        status=422, code="bad_type")

        # cheap per-site+type rate limit (abuse guard on a public endpoint)
        now = timezone.now()
        _touch_seen(site, cam, now)
        if self._rate_limited(site, etype, now):
            return _err(lang, "অনেক দ্রুত অনুরোধ।", "Too many requests.",
                        status=429, code="rate_limited")

        signals = request.data.get("signals")
        if isinstance(signals, str):
            # multipart uploads (signals + snapshot) carry signals as a JSON string
            try:
                import json
                signals = json.loads(signals)
            except ValueError:
                signals = {}
        if not isinstance(signals, dict):
            signals = {}
        # the camera event the pure guard consumes (its own `at`, epoch seconds)
        at_ts = _coerce_epoch(request.data.get("at"), now)
        cam_event = {"type": etype, "signals": signals, "at": at_ts}

        decision, ev = _ingest_event(site, cam, cam_event, now,
                                     request.FILES.get("snapshot"))
        if ev is None:
            # logged/ignored — honest: no alert, no snapshot stored, no video.
            return Response({"raised": False, "type": etype,
                             "confidence": decision["confidence"],
                             "reason_signals": decision["reason_signals"]})

        return Response({"raised": True, "event_id": ev.id,
                         "type": ev.type, "confidence": ev.confidence,
                         "possible": ev.possible,
                         "reason_signals": decision["reason_signals"]},
                        status=201)

    @staticmethod
    def _rate_limited(site, etype, now):
        from .models import ShopEvent
        # count raised events only (open ingests are not persisted), plus a
        # lightweight guard: reject bursts of the SAME type within the window.
        since = now - timedelta(seconds=INGEST_WINDOW_S)
        recent = ShopEvent.objects.filter(
            site=site, type=etype, created__gte=since).count()
        return recent >= INGEST_MAX_PER_WINDOW

    @staticmethod
    def _notify_owner(site, cam, ev):
        """Fire an HONEST owner alert: FamilyAlert (foreground-polled) + a
        NotifEvent feed row, in the OWNER's language (not the device's). Wording
        is ALWAYS "please check" / "একটু দেখে নিন" — never "theft"/"চুরি".
        Confidence is always shown. Best-effort; never raises."""
        try:
            from .models import FamilyAlert, NotifEvent
            # notify in the OWNER's stored language (the device sent no user lang)
            olang = getattr(site.owner, "language", None)
            olang = olang if olang in ("bn", "en") else "bn"
            cam_name = (cam.name if cam else "") or _subject_label(
                ev.type, olang)
            pct = int(round(ev.confidence * 100))
            reason = ", ".join(ev.signals.get("reason", []))
            title_bn = "একটু দেখে নিন — %s" % cam_name
            title_en = "Please check — %s" % cam_name
            body_bn = ("%s এ একটু দেখে নিন (%s, আত্মবিশ্বাস %d%%)। "
                       "অনুগ্রহ করে নিজে দেখে নিশ্চিত করুন।" % (cam_name, reason, pct))
            body_en = ("Please check %s — %s, confidence %d%%. "
                       "Have a look yourself to confirm." % (cam_name, reason, pct))
            FamilyAlert.objects.create(
                user=site.owner, kind="shop_guard",
                title=title_en[:160] if olang == "en" else title_bn[:160],
                body=body_en if olang == "en" else body_bn,
                severity=("info" if ev.possible else "med"),
                payload={"source": "shop_guard", "event_id": ev.id,
                         "site_id": site.id, "type": ev.type,
                         "confidence": ev.confidence, "possible": ev.possible})
            NotifEvent.objects.create(
                user=site.owner, type="business",
                title_bn=title_bn[:200], title_en=title_en[:200],
                body_bn=body_bn, body_en=body_en, route="business",
                meta={"source": "shop_guard", "event_id": ev.id,
                      "site_id": site.id, "type": ev.type,
                      "confidence": ev.confidence})
        except Exception:
            pass
        # FCM to the owner's phones — same "please check" wording, never
        # "theft". Key-gated + async; its own guard so it can't affect ingest.
        try:
            from . import push
            push.safe_push(
                site.owner, "shop_alert", title_bn, title_en, body_bn, body_en,
                data={"event_id": ev.id, "site_id": site.id,
                      "camera_id": cam.id if cam else "",
                      "camera_name": cam_name, "type": ev.type,
                      "confidence": ev.confidence, "possible": ev.possible,
                      "route": "business/shop-box"},
                high_priority=not ev.possible)
        except Exception:
            pass


def _ingest_event(site, cam, cam_event, now, snapshot=None, pos_rows=None):
    """Shared core of every device ingest (Shop Box POST + camera webhooks):
    run the pure combined-signal guard against recent POS rows; when it raises,
    persist ONE ShopEvent + at most one snapshot and notify the owner.
    `pos_rows` overrides the recent-window POS rows (the void/discount spike
    check passes TODAY's rows). Returns (decision, event_or_None)."""
    if pos_rows is None:
        pos_rows = _pos_rows_for(site, now, SG.DEFAULT_WINDOW_S)
    decision = SG.combine(cam_event, pos_rows, now=now.timestamp())
    if not decision["raise"]:
        return decision, None

    from .models import ShopEvent
    ev = ShopEvent.objects.create(
        site=site, camera=cam, type=decision["type"],
        signals={"inputs": cam_event.get("signals") or {},
                 "reason": decision["reason_signals"],
                 "pos_matched": decision["pos_matched"]},
        confidence=decision["confidence"],
        pos_matched=decision["pos_matched"], possible=decision["possible"])

    # store AT MOST the one small snapshot (only if retention allows it)
    if snapshot is not None and site.snapshot_retention_days > 0:
        ev.snapshot.save(snapshot.name, snapshot, save=True)

    ShopIngestView._notify_owner(site, cam, ev)
    return decision, ev


# Camera webhooks: a camera repeats "active" every second or so while an event
# lasts — collapse a burst into ONE alert per camera+type in this window.
HOOK_DEDUPE_S = 60
HOOK_SNAPSHOT_MAX_PX = 640


def _small_jpeg(raw, name):
    """Downscale a camera JPEG to <= HOOK_SNAPSHOT_MAX_PX on the long side.
    Returns a ContentFile, or None when the bytes are not a readable image."""
    import io
    from django.core.files.base import ContentFile
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw))
        im = im.convert("RGB")
        im.thumbnail((HOOK_SNAPSHOT_MAX_PX, HOOK_SNAPSHOT_MAX_PX))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=75, optimize=True)
        return ContentFile(out.getvalue(), name=name)
    except Exception:
        return None


class ShopCameraHookView(APIView):
    """POST shop/hook/<vendor>/<camera_token> — an IP camera's OWN event push
    (Hikvision ISAPI HTTP Listening, Dahua event push). The camera token is in
    the path because cameras cannot add headers. Always answers 200 quickly
    (cameras retry/stall on errors), except an unknown token → 401.

    Line-crossing / intrusion → after_hours alert outside the camera's hours,
    else a restricted-zone breach; plain motion is only logged unless after
    hours. Same combined-signal guard + "please check" wording as the Shop Box."""
    permission_classes = [AllowAny]
    authentication_classes = []
    parser_classes = []                # we parse the raw body ourselves

    def post(self, request, vendor, camera_token):
        from .logic import camera_hooks as CH
        from .models import ShopCamera, ShopEvent
        lang = req_lang(request)
        parser = CH.PARSERS.get(vendor)
        cam = ShopCamera.objects.filter(camera_token=camera_token).select_related(
            "site").first() if parser else None
        if cam is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        if not cam.enabled:
            return Response({"ok": True, "ignored": "camera_disabled"})

        events = parser(request.content_type or "", request.body[:4 * 1024 * 1024])
        now = timezone.now()
        local_now = timezone.localtime(now)
        ShopCamera.objects.filter(pk=cam.pk).update(last_seen=now)
        # hours: the camera's own, else the site's (a2-cctv)
        zc = effective_zone_config(cam)
        results = []
        for vev in events:
            mapped = CH.map_event(vev, zc, local_now)
            if mapped is None:
                continue
            etype, signals = mapped
            recent = ShopEvent.objects.filter(
                camera=cam, type__in=(etype, "after_hours", "motion"),
                created__gte=now - timedelta(seconds=HOOK_DEDUPE_S)).exists()
            if recent:
                results.append({"type": etype, "raised": False, "dedupe": True})
                continue
            snap = _small_jpeg(vev["image"], "cam%d.jpg" % cam.id) if vev.get("image") else None
            decision, ev = _ingest_event(
                cam.site, cam, {"type": etype, "signals": signals,
                                "at": now.timestamp()}, now, snap)
            results.append({"type": decision["type"], "raised": ev is not None,
                            "confidence": decision["confidence"]})
        return Response({"ok": True, "events": results})


class ShopPosIngestView(APIView):
    """POST shop/pos — the shop's POS (or the Shop Box) posts a ShopPosEvent row
    used to CORRELATE camera events. Enrollment-token auth, not a user login."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        site, _cam = _resolve_device_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        kind = (request.data.get("kind") or "").strip()
        valid = {k for k, _ in _pos_kinds()}
        if kind not in valid:
            return _err(lang, "POS ধরন ভুল।", "Invalid POS kind.", status=422,
                        code="bad_kind")
        try:
            amount = int(request.data.get("amount") or 0)
        except (TypeError, ValueError):
            amount = 0
        now = timezone.now()
        at = _coerce_dt(request.data.get("at"), now)
        from .models import ShopPosEvent
        row = ShopPosEvent.objects.create(site=site, kind=kind,
                                          amount=amount, at=at)
        return Response({"ok": True, "pos_id": row.id}, status=201)


# ---------------------------------------------------------------------------
# OWNER endpoints (normal Token auth + owner gate)
# ---------------------------------------------------------------------------

class ShopSitesView(APIView):
    """GET shop/sites — the owner's sites. POST — create a site + enrollment
    token."""
    def get(self, request):
        from .models import ShopSite
        rows = []
        for s in ShopSite.objects.filter(owner=request.user):
            rows.append(_site_row(s))
        return Response({"sites": rows})

    def post(self, request):
        from .models import ShopSite
        name = (request.data.get("name") or "").strip()[:120]
        retention = _coerce_retention(request.data.get("snapshot_retention_days"),
                                      default=7)
        s = ShopSite.objects.create(owner=request.user, name=name,
                                    snapshot_retention_days=retention)
        return Response(_site_row(s, reveal_token=True), status=201)


class ShopSiteDetailView(APIView):
    """PATCH shop/sites/<id> — owner-settable snapshot_retention_days (0–30)."""
    def patch(self, request, pk):
        lang = req_lang(request)
        s = _owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        changed = []
        if "snapshot_retention_days" in request.data:
            s.snapshot_retention_days = _coerce_retention(
                request.data.get("snapshot_retention_days"),
                default=s.snapshot_retention_days)
            changed.append("snapshot_retention_days")
        if "name" in request.data:
            s.name = (request.data.get("name") or "").strip()[:120]
            changed.append("name")
        if "hours" in request.data:
            h = coerce_hours(request.data.get("hours"))
            if h is False:
                return _err(lang, "সময় HH:MM আকারে দিন।",
                            "Give hours as HH:MM.", status=422, code="bad_hours")
            s.hours = h
            changed.append("hours")
        if "pos_link" in request.data:
            s.pos_link = _coerce_bool(request.data.get("pos_link"))
            changed.append("pos_link")
        if changed:
            s.save(update_fields=changed)
        return Response(_site_row(s, reveal_token=True))


class ShopCamerasView(APIView):
    """POST shop/sites/<id>/cameras — create a camera, enforcing the
    'Business includes 4 edge cameras; more = credits' cap. GET — list cameras."""
    def get(self, request, pk):
        lang = req_lang(request)
        s = _owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        rows = [_camera_row(c) for c in s.cameras.all()]
        return Response({"cameras": rows, "included": _included_cameras(request.user),
                         "used": s.cameras.count(),
                         "used_total": owner_enabled_cameras(request.user).count(),
                         "extra_camera_credits": _extra_camera_credits()})

    def post(self, request, pk):
        lang = req_lang(request)
        s = _owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)

        # CAP: Business includes N edge cameras free; the N+1th costs credits.
        # NOTE: this is a HARDWARE/ENTITLEMENT charge, not an AI action — so it
        # must bite even for 'unlimited AI' plans. We debit purchased credits
        # directly (NOT via billing.charge, which exempts unlimited-AI plans).
        included = _included_cameras(request.user)
        # the free allowance is per OWNER (across all their sites), counting
        # enabled cameras — the same ranking the monthly billing uses.
        existing = owner_enabled_cameras(request.user).count()
        charge_extra = existing >= included
        need = _extra_camera_credits() if charge_extra else 0
        if charge_extra and int(request.user.ai_credits or 0) < need:
            # honest, specific error — never silently add an unpaid camera.
            return _err(
                lang,
                "আপনার প্ল্যানে %d টি ক্যামেরা ফ্রি; বাড়তি ক্যামেরার জন্য "
                "%d ক্রেডিট দরকার (এখন যথেষ্ট ক্রেডিট নেই)।" % (included, need),
                "Your plan includes %d cameras; an extra camera needs %d "
                "credits (you don't have enough)." % (included, need),
                status=402, code="camera_cap", included=included,
                used=existing, credits_needed=need, balance=int(request.user.ai_credits or 0))

        kind = request.data.get("kind") or "edge_webhook"
        if kind not in {k for k, _ in ShopCamera_kinds()}:
            kind = "edge_webhook"

        charged = 0
        if charge_extra:
            charged = _debit_camera_credits(request.user, need,
                                            note="shop camera #%d" % (existing + 1))
            if charged < need:
                # lost a race for the credits — refuse, add nothing.
                return _err(lang, "যথেষ্ট ক্রেডিট নেই।",
                            "Not enough credits.", status=402,
                            code="camera_cap", credits_needed=need)

        from .models import ShopCamera
        cam = ShopCamera.objects.create(
            site=s, name=(request.data.get("name") or "").strip()[:120],
            kind=kind, zone_config=_coerce_json(request.data.get("zone_config")),
            enabled=bool(request.data.get("enabled", True)),
            billed_until=(timezone.now() + timedelta(days=BILLING_PERIOD_DAYS)
                          if charged else None))
        out = _camera_row(cam, reveal_token=True)
        out["charged_credits"] = charged
        return Response(out, status=201)


class ShopEventsView(APIView):
    """GET shop/events?site=<id> — the owner's alerts (newest first) with the
    snapshot url. Owner-scoped: the device enrollment token can INGEST but can
    never reach this read endpoint (it has no user)."""
    def get(self, request):
        lang = req_lang(request)
        sid = request.query_params.get("site")
        s = _owner_site(request, sid) if sid else None
        if s is None:
            return _err(lang, "সাইট পাওয়া যায়নি।", "Site not found.", status=404)
        status_f = request.query_params.get("status")
        qs = s.events.all()
        if status_f in {"open", "checked", "false_alarm"}:
            qs = qs.filter(status=status_f)
        rows = [_event_row(e, request) for e in qs[:200]]
        return Response({"events": rows, "site": s.id})


class ShopEventMarkView(APIView):
    """POST shop/events/<id>/mark {status: checked|false_alarm} — the owner's
    verdict. Only the owner of the event's site may mark it."""
    def post(self, request, pk):
        lang = req_lang(request)
        from .models import ShopEvent
        e = ShopEvent.objects.filter(pk=pk, site__owner=request.user).first()
        if e is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        status_v = (request.data.get("status") or "").strip()
        if status_v not in {"checked", "false_alarm"}:
            return _err(lang, "স্ট্যাটাস ভুল।", "Invalid status.", status=422,
                        code="bad_status")
        e.status = status_v
        e.save(update_fields=["status"])
        return Response({"ok": True, "event_id": e.id, "status": e.status})


class ShopSummaryView(APIView):
    """GET shop/summary?site=<id> — daily summary + exception report:
    counts by type, voids/refunds/discounts, after-hours events. Works in
    CAMERA-ONLY mode too (no POS feed needed)."""
    def get(self, request):
        lang = req_lang(request)
        sid = request.query_params.get("site")
        s = _owner_site(request, sid) if sid else None
        if s is None:
            return _err(lang, "সাইট পাওয়া যায়নি।", "Site not found.", status=404)

        now = timezone.now()
        try:
            days = max(1, min(90, int(request.query_params.get("days") or 1)))
        except (TypeError, ValueError):
            days = 1
        since = now - timedelta(days=days)

        events = s.events.filter(created__gte=since)
        by_type = {}
        after_hours = 0
        open_count = 0
        false_alarms = 0
        for e in events:
            by_type[e.type] = by_type.get(e.type, 0) + 1
            if e.type == "after_hours":
                after_hours += 1
            if e.status == "open":
                open_count += 1
            elif e.status == "false_alarm":
                false_alarms += 1

        pos = s.pos_events.filter(at__gte=since)
        pos_by_kind = {}
        for p in pos:
            pos_by_kind[p.kind] = pos_by_kind.get(p.kind, 0) + 1
        camera_only = not s.pos_events.exists()

        return Response({
            "site": s.id, "days": days,
            "total_events": events.count(),
            "by_type": by_type,
            "open": open_count,
            "false_alarms": false_alarms,
            "after_hours": after_hours,
            # exception report — the POS-side counts the owner reviews
            "exceptions": {
                "voids": pos_by_kind.get("void", 0),
                "refunds": pos_by_kind.get("refund", 0),
                "discounts": pos_by_kind.get("discount", 0),
                "drawer_opens": pos_by_kind.get("drawer_open", 0),
            },
            "pos_by_kind": pos_by_kind,
            "camera_only": camera_only,
        })


# ---------------------------------------------------------------------------
# shaping + coercion helpers
# ---------------------------------------------------------------------------

# what a camera-less alert is about (POS / end-of-day checks), bn + en.
_SUBJECTS = {
    "void_spike": ("বাতিল করা বিক্রি", "voided sales"),
    "discount_spike": ("ছাড়", "discounts"),
    "refund_spike": ("ফেরত", "refunds"),
    "eod_mismatch": ("দিনশেষের ক্যাশ হিসাব", "end-of-day cash count"),
}


def _subject_label(etype, lang):
    bn, en = _SUBJECTS.get(etype, ("ক্যামেরা", "camera"))
    return bn if lang == "bn" else en


def _shop_event_types():
    from .models import ShopEvent
    return ShopEvent.TYPES


def _pos_kinds():
    from .models import ShopPosEvent
    return ShopPosEvent.KINDS


def ShopCamera_kinds():
    from .models import ShopCamera
    return ShopCamera.KINDS


def _included_cameras(user):
    """Cameras included free for this user's plan: Business includes
    limits.business_included_cameras (default 4, admin-editable), others 0."""
    from . import plans, billing
    try:
        if plans.effective_plan(user) != "business":
            return 0
        return int(billing.cfg()["limits"]["business_included_cameras"])
    except Exception:
        return 0


def _extra_camera_credits():
    from . import billing
    from .logic import pricing
    try:
        return pricing.credits_for("shop_extra_camera", 1, billing.cfg())
    except Exception:
        return 0


def _debit_camera_credits(user, need, note=""):
    """ATOMICALLY debit `need` purchased credits for an EXTRA camera entitlement,
    writing one CreditLedger row. Unlike billing.charge this is NOT an AI action,
    so 'unlimited AI' plans are still charged (the included-camera count already
    gave Business its free allowance). Returns the amount actually charged (0 if
    it couldn't cover it — the balance stays untouched then)."""
    from django.db import transaction
    from django.db.models import F
    from .models import User, CreditLedger
    need = int(need or 0)
    if need <= 0:
        return 0
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        bal = int(locked.ai_credits or 0)
        if bal < need:
            return 0
        User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") - need)
        CreditLedger.objects.create(user=locked, delta=-need, reason="consume",
                                    note=(note or "shop_extra_camera")[:120])
    try:
        user.ai_credits = bal - need
    except Exception:
        pass
    return need


def _iso(dt):
    return dt.isoformat() if dt else None


# a device that heartbeated (or a camera that pushed a webhook) within this
# many seconds counts as ONLINE; the app shows "offline since <last_seen>".
ONLINE_WINDOW_S = 180
BILLING_PERIOD_DAYS = 30


def is_online(last_seen, now=None):
    if not last_seen:
        return False
    now = now or timezone.now()
    return (now - last_seen).total_seconds() <= ONLINE_WINDOW_S


def effective_zone_config(cam):
    """The camera's zone_config with hours falling back to its SITE's hours."""
    zc = dict(cam.zone_config) if isinstance(cam.zone_config, dict) else {}
    site_hours = getattr(cam.site, "hours", None)
    if not zc.get("hours") and isinstance(site_hours, dict) and site_hours:
        zc["hours"] = dict(site_hours)
    return zc


def owner_enabled_cameras(user):
    """The owner's ENABLED cameras across all their sites, oldest first — the
    first N (plan's included count) are free; the rest are 'extra'."""
    from .models import ShopCamera
    return ShopCamera.objects.filter(site__owner=user, enabled=True).order_by(
        "created", "id")


def _site_row(s, reveal_token=False):
    row = {"id": s.id, "name": s.name,
           "snapshot_retention_days": s.snapshot_retention_days,
           "cameras": s.cameras.count(),
           "hours": s.hours or {}, "pos_link": s.pos_link,
           "last_seen": _iso(s.last_seen), "online": is_online(s.last_seen),
           "created": s.created.isoformat()}
    if reveal_token:
        row["enrollment_token"] = s.enrollment_token
    return row


def _camera_row(c, reveal_token=False):
    zc = c.zone_config if isinstance(c.zone_config, dict) else {}
    caps = (c.device_info or {}).get("caps") if isinstance(c.device_info, dict) else []
    row = {"id": c.id, "name": c.name, "kind": c.kind, "enabled": c.enabled,
           "zone_config": c.zone_config, "created": c.created.isoformat(),
           "hours": zc.get("hours") or None,
           "restricted_zone": bool(zc.get("restricted_zone", True)),
           "last_seen": _iso(c.last_seen), "online": is_online(c.last_seen),
           "live_capable": bool(caps and "live" in caps),
           "billed_until": _iso(c.billed_until)}
    if reveal_token:
        row["camera_token"] = c.camera_token
    return row


def _event_row(e, request):
    url = None
    if e.snapshot:
        try:
            url = request.build_absolute_uri(e.snapshot.url)
        except Exception:
            url = e.snapshot.url
    return {"id": e.id, "type": e.type, "confidence": e.confidence,
            "possible": e.possible, "pos_matched": e.pos_matched,
            "status": e.status, "signals": e.signals,
            "snapshot_url": url, "camera": e.camera_id,
            "created": e.created.isoformat()}


def _coerce_retention(v, default=7):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return default
    return max(0, min(30, n))


def coerce_hours(v):
    """{"open":"HH:MM","close":"HH:MM"} -> normalised dict; None/{} -> {} (no
    hours); anything malformed -> False (caller answers 422)."""
    if v in (None, "", {}):
        return {}
    if not isinstance(v, dict):
        return False
    from .logic.camera_hooks import _parse_hhmm
    o, c = _parse_hhmm(v.get("open")), _parse_hhmm(v.get("close"))
    if o is None or c is None:
        return False
    return {"open": o.strftime("%H:%M"), "close": c.strftime("%H:%M")}


def _coerce_bool(v):
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


def _coerce_json(v):
    return v if isinstance(v, dict) else {}


def _coerce_epoch(v, now):
    """A client `at` -> epoch seconds (float). Accepts epoch number or ISO; falls
    back to `now`."""
    if v is None:
        return now.timestamp()
    try:
        return float(v)
    except (TypeError, ValueError):
        pass
    dt = _coerce_dt(v, now)
    return dt.timestamp()


def _coerce_dt(v, now):
    """A client `at` -> aware datetime; falls back to `now`."""
    if v is None:
        return now
    from django.utils.dateparse import parse_datetime
    if isinstance(v, (int, float)):
        try:
            from datetime import datetime, timezone as _tz
            return datetime.fromtimestamp(float(v), tz=_tz.utc)
        except (OverflowError, OSError, ValueError):
            return now
    try:
        dt = parse_datetime(str(v))
    except (TypeError, ValueError):
        dt = None
    if dt is None:
        return now
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt, timezone.get_current_timezone())
    return dt
