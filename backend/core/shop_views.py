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
    try:
        pk = int(pk)
    except (TypeError, ValueError):
        return None
    return ShopSite.objects.filter(pk=pk, owner=request.user).first()


def _viewable_site(request, pk):
    """(site, 'owner'|'viewer') for the owner or a family viewer, else
    (None, None). Viewers are READ-ONLY (cctv1)."""
    from .models import ShopSite
    s = _owner_site(request, pk)
    if s is not None:
        return s, "owner"
    try:
        pk = int(pk)
    except (TypeError, ValueError):
        return None, None
    s = ShopSite.objects.filter(pk=pk, viewers__user=request.user).first()
    return (s, "viewer") if s is not None else (None, None)


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

        # cctv1: ONE still image or nothing — a video (or anything that is not
        # a decodable image) is refused outright, never stored.
        snap = None
        upload = request.FILES.get("snapshot")
        if upload is not None:
            snap, why = clean_snapshot(upload)
            if snap is None:
                return _snapshot_refused(lang, why)
        for extra in request.FILES:
            if extra != "snapshot":
                return _snapshot_refused(lang, "extra_file")

        # cashguard: the edge names the encrypted clip it will upload for this
        # event (a random hex ref — never inside `signals`, never evidence)
        from .logic import cash_guard as CG
        clip_ref = CG.clean_clip_ref(request.data.get("clip_ref"))
        decision, ev = _ingest_event(site, cam, cam_event, now, snap,
                                     clip_ref=clip_ref)
        if ev is None:
            # logged/ignored — honest: no alert, no snapshot stored, no video.
            return Response({"raised": False, "type": etype,
                             "confidence": decision["confidence"],
                             "reason_signals": decision["reason_signals"],
                             **({"held": decision["held"]}
                                if decision.get("held") else {})})

        return Response({"raised": True, "event_id": ev.id,
                         "type": ev.type, "confidence": ev.confidence,
                         "possible": ev.possible,
                         "grouped": bool(decision.get("grouped")),
                         "count": ev.count,
                         "reason_signals": decision["reason_signals"],
                         **({"clip_ref": clip_ref,
                             "clip_wanted": clip_wanted(site, ev)}
                            if clip_ref else {})},
                        status=200 if decision.get("grouped") else 201)

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
    def _notify_owner(site, cam, ev, quiet=False):
        """Fire an HONEST alert to the owner AND every family viewer of the
        site: FamilyAlert (foreground-polled) + a NotifEvent feed row, in each
        person's language. Every alert is labelled "Suspicious — please check"
        / "সন্দেহজনক — একটু দেখে নিন" — never "theft"/"চুরি", never an
        accusation. Confidence is always shown. The ONE snapshot rides along
        (signed, expiring link). In the camera's quiet hours the alert is saved
        but no phone notification is pushed. Best-effort; never raises."""
        recipients = [site.owner]
        try:
            recipients += [v.user for v in site.viewers.select_related("user")]
        except Exception:
            pass
        snap_url = _abs_snapshot_url(ev)
        for user in recipients:
            _notify_one(user, site, cam, ev, snap_url, quiet)


def _alert_text(cam_name, ev):
    """(title_bn, title_en, body_bn, body_en) — 'Suspicious — please check'.
    cashguard: a CASH event says "Possible cash removal — watch the clip and
    decide" (never an accusation; the owner decides), prefixed "You are
    away — " in owner-away mode."""
    pct = int(round(ev.confidence * 100))
    what_bn, what_en = EVENT_WORDS.get(ev.type, EVENT_WORDS["motion"])
    from .logic import cash_guard as CG
    inputs = (ev.signals or {}).get("inputs") if isinstance(ev.signals, dict) else {}
    inputs = inputs if isinstance(inputs, dict) else {}
    if CG.is_cash_event(ev.type, inputs):
        away = bool(inputs.get("away"))
        has_clip = bool((ev.signals or {}).get("clip_ref"))
        if ev.type == "after_hours":
            what_bn, what_en = CG.AFTER_HOURS_ZONE_BN, CG.AFTER_HOURS_ZONE_EN
        title_bn = "%s: %s" % (CG.cash_title("bn", has_clip, away), cam_name)
        title_en = "%s: %s" % (CG.cash_title("en", has_clip, away), cam_name)
        body_bn = ("%s (আত্মবিশ্বাস %s%%)। অনুগ্রহ করে নিজে দেখে নিন — "
                   "এটা ভুলও হতে পারে।" % (what_bn, _bn_digits(pct)))
        body_en = ("%s (confidence %d%%). Please check it yourself — it may "
                   "be nothing." % (what_en, pct))
        return title_bn, title_en, body_bn, body_en
    title_bn = "সন্দেহজনক — একটু দেখে নিন: %s" % cam_name
    title_en = "Suspicious — please check: %s" % cam_name
    body_bn = ("%s (আত্মবিশ্বাস %s%%)। অনুগ্রহ করে নিজে দেখে নিশ্চিত করুন — "
               "এটা ভুলও হতে পারে।" % (what_bn, _bn_digits(pct)))
    body_en = ("%s (confidence %d%%). Please have a look yourself — it may be "
               "nothing." % (what_en, pct))
    return title_bn, title_en, body_bn, body_en


def _notify_one(user, site, cam, ev, snap_url, quiet):
    try:
        from .models import FamilyAlert, NotifEvent
        # notify in the RECIPIENT's stored language (the device sent no lang)
        olang = getattr(user, "language", None)
        olang = olang if olang in ("bn", "en") else "bn"
        cam_name = (cam.name if cam else "") or _subject_label(ev.type, olang)
        title_bn, title_en, body_bn, body_en = _alert_text(cam_name, ev)
        from .logic import cash_guard as CG
        inputs = (ev.signals or {}).get("inputs") if isinstance(ev.signals, dict) else {}
        inputs = inputs if isinstance(inputs, dict) else {}
        away = bool(inputs.get("away"))
        cash = CG.is_cash_event(ev.type, inputs)
        meta = {"source": "shop_guard", "event_id": ev.id, "site_id": site.id,
                "type": ev.type, "confidence": ev.confidence,
                "possible": ev.possible, "label": "suspicious_please_check",
                "viewer": user.pk != site.owner_id, "quiet": bool(quiet),
                # cashguard
                "cash": cash, "away": away,
                "clip": bool((ev.signals or {}).get("clip_ref"))}
        FamilyAlert.objects.create(
            user=user, kind="shop_guard",
            title=title_en[:160] if olang == "en" else title_bn[:160],
            body=body_en if olang == "en" else body_bn,
            severity=("high" if away else
                      "info" if (ev.possible or quiet) else "med"),
            payload=meta)
        NotifEvent.objects.create(
            user=user, type="business",
            title_bn=title_bn[:200], title_en=title_en[:200],
            body_bn=body_bn, body_en=body_en, route="business",
            meta=meta)
    except Exception:
        return
    if quiet:
        return
    # FCM to the person's phones — same wording, never "theft". Key-gated +
    # async; its own guard so it can't affect ingest.
    try:
        from . import push
        push.safe_push(
            user, "shop_alert", title_bn, title_en, body_bn, body_en,
            data={"event_id": ev.id, "site_id": site.id,
                  "camera_id": cam.id if cam else "",
                  "camera_name": cam_name, "type": ev.type,
                  "confidence": ev.confidence, "possible": ev.possible,
                  "label": "suspicious_please_check",
                  "cash": cash, "away": away, "clip": meta["clip"],
                  **({"snapshot_url": snap_url} if snap_url else {}),
                  # cctv1: places made in the watchman wizard open the watchman
                  "route": "watchman" if site.gateway else "business/shop-box"},
            high_priority=(away or not ev.possible))
    except Exception:
        pass


# what the alert is about, in plain words (never accusatory) — bn, en
EVENT_WORDS = {
    "hand_in_cash_zone": ("ক্যাশের জায়গায় হাত, কোনো বিক্রি মেলেনি",
                          "A hand at the cash area with no matching sale"),
    "drawer_open": ("ক্যাশ ড্রয়ার খোলা, কোনো বিক্রি মেলেনি",
                    "Cash drawer opened with no matching sale"),
    "void_spike": ("আজ বাতিল বিক্রি স্বাভাবিকের চেয়ে বেশি",
                   "More voided sales than usual today"),
    "refund_spike": ("আজ ফেরত স্বাভাবিকের চেয়ে বেশি",
                     "More refunds than usual today"),
    "discount_spike": ("আজ ছাড় স্বাভাবিকের চেয়ে বেশি",
                       "More discounts than usual today"),
    "eod_mismatch": ("দিনশেষের ক্যাশ হিসাব মেলেনি",
                     "The end-of-day cash count does not match"),
    "motion": ("নড়াচড়া দেখা গেছে", "Movement seen"),
    "after_hours": ("বন্ধের সময়ে নড়াচড়া", "Movement outside opening hours"),
    "pose_possible": ("কেউ থাকতে পারে", "Someone may be there"),
    "person_detected": ("পাহারার সময়ে একজন মানুষ দেখা গেছে",
                        "A person seen while the camera is on guard"),
    "zone_intrusion": ("নিষিদ্ধ জায়গায় কেউ ঢুকেছে",
                       "Someone entered a restricted area"),
    "line_crossing": ("প্রবেশ-রেখা পার হয়েছে", "The entry line was crossed"),
    "camera_alarm": ("ক্যামেরার নিজের সতর্কতা", "The camera's own alarm"),
}

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def _bn_digits(v):
    return str(v).translate(_BN_DIGITS)


def _abs_snapshot_url(ev):
    """Absolute signed link to the event's ONE snapshot, or None."""
    if not ev.snapshot:
        return None
    try:
        from django.conf import settings
        url = ev.snapshot.url
        if url.startswith("/"):
            url = getattr(settings, "ASSISTO_BASE_URL", "").rstrip("/") + url
        return url
    except Exception:
        return None


# ---------------------------------------------------------------- snapshots
VIDEO_EXTS = (".mp4", ".mov", ".avi", ".mkv", ".webm", ".3gp", ".m4v", ".ts",
              ".flv", ".wmv", ".mpg", ".mpeg", ".h264", ".h265", ".dav")


def snapshot_limit_bytes():
    from . import billing
    try:
        kb = int((billing.cfg().get("shop") or {}).get("watchman_snapshot_kb", 1024))
    except Exception:
        kb = 1024
    return max(64, min(4096, kb)) * 1024


def clean_snapshot(upload, name="snapshot.jpg"):
    """The ONE still an event may keep. Returns (ContentFile, None) — a
    downscaled JPEG — or (None, reason): 'video' for any video content type /
    extension (NO VIDEO EVER ON OUR SERVER), 'too_large', 'not_an_image'."""
    ctype = (getattr(upload, "content_type", "") or "").lower()
    fname = (getattr(upload, "name", "") or "").lower()
    if ctype.startswith("video/") or fname.endswith(VIDEO_EXTS) or \
            ctype in ("application/vnd.apple.mpegurl", "application/x-mpegurl"):
        return None, "video"
    size = getattr(upload, "size", None)
    limit = snapshot_limit_bytes()
    if size is not None and size > limit:
        return None, "too_large"
    try:
        raw = upload.read(limit + 1)
    except Exception:
        return None, "not_an_image"
    if len(raw) > limit:
        return None, "too_large"
    # magic bytes of common video containers, whatever the label says
    if looks_like_video(raw):
        return None, "video"
    cf = _small_jpeg(raw, name)
    if cf is None:
        return None, "not_an_image"
    return cf, None


def looks_like_video(raw):
    """Magic bytes of common video containers, whatever the label claims."""
    head = raw[:16]
    return (head[4:8] in (b"ftyp", b"moov", b"mdat", b"wide")      # MP4/MOV/3GP
            or head[:4] == b"\x1aE\xdf\xa3"                         # MKV/WebM
            or (head[:4] == b"RIFF" and raw[8:12] == b"AVI ")       # AVI
            or head[:3] == b"FLV"
            or head[:4] in (b"\x00\x00\x01\xba", b"\x00\x00\x01\xb3")  # MPEG-PS
            or (head[:1] == b"G" and len(raw) > 376 and raw[188:189] == b"G"
                and raw[376:377] == b"G"))                          # MPEG-TS


def _snapshot_refused(lang, why):
    if why == "video":
        return _err(lang, "ভিডিও কখনো নেওয়া হয় না — শুধু একটি ছবি পাঠানো যায়।",
                    "Video is never accepted — only one still image.",
                    status=415, code="video_not_accepted")
    if why == "too_large":
        return _err(lang, "ছবিটি খুব বড়।", "The image is too large.",
                    status=413, code="snapshot_too_large")
    return _err(lang, "শুধু একটি ছবি (JPEG/PNG) পাঠানো যায়।",
                "Only one still image (JPEG/PNG) is accepted.",
                status=415, code="not_an_image")


def _ingest_event(site, cam, cam_event, now, snapshot=None, pos_rows=None,
                  clip_ref=""):
    """Shared core of every device ingest (Shop Box POST + camera webhooks):
    run the pure combined-signal guard against recent POS rows; when it raises,
    persist ONE ShopEvent + at most one snapshot and notify the owner.
    `pos_rows` overrides the recent-window POS rows (the void/discount spike
    check passes TODAY's rows). Returns (decision, event_or_None)."""
    from .logic import watchman as WM
    if pos_rows is None:
        pos_rows = _pos_rows_for(site, now, SG.DEFAULT_WINDOW_S)
    # cctv1: the ARMED state is the SERVER's (from the owner's schedule) — a
    # device can never claim it. Only cameras with a v2 watchman config are
    # schedule-driven; legacy Shop Box configs keep their old behaviour.
    signals = dict(cam_event.get("signals") or {})
    signals.pop("armed", None)
    signals.pop("away", None)          # cashguard: the server's state only
    quiet = False
    # cashguard OWNER-AWAY: every camera armed, quiet hours ignored, high
    # priority push (the alert text says "You are away — ...")
    away = away_now(site, now)
    if away:
        signals["away"] = True
    v2 = WM.zone_v2(cam.zone_config) if cam is not None else None
    if v2 is not None:
        local = timezone.localtime(now)
        armed = WM.is_armed(v2.get("schedule"), local) or away
        if cam_event.get("type") in WATCHMAN_ARMED_TYPES and not armed:
            return ({"raise": False, "type": cam_event.get("type"),
                     "confidence": 0.0, "reason_signals": ["not_armed"],
                     "possible": False, "pos_matched": False}, None)
        signals["armed"] = armed
        quiet = WM.in_window(v2.get("quiet_hours"), local) and not away
    cam_event = dict(cam_event, signals=signals)
    decision = SG.combine(cam_event, pos_rows, now=now.timestamp())
    if not decision["raise"]:
        return decision, None

    from .models import ShopEvent
    # GROUPING: the same camera + type still open inside the group window ->
    # bump that alert's count instead of a new alert + push.
    if cam is not None:
        since = now - timedelta(minutes=watchman_cfg("watchman_group_min", 10))
        prev = (ShopEvent.objects.filter(camera=cam, type=decision["type"],
                                         status="open")
                .filter(models_Q(last_at__gte=since) |
                        models_Q(last_at__isnull=True, created__gte=since))
                .order_by("-created").first())
        if prev is not None:
            ShopEvent.objects.filter(pk=prev.pk).update(
                count=F_("count") + 1, last_at=now,
                confidence=max(prev.confidence, decision["confidence"]))
            prev.refresh_from_db()
            if snapshot is not None and not prev.snapshot and \
                    site.snapshot_retention_days > 0:
                prev.snapshot.save(snapshot.name, snapshot, save=True)
            if clip_ref and not (prev.signals or {}).get("clip_ref") and \
                    not hasattr_clip(prev):
                sig = dict(prev.signals or {})
                sig["clip_ref"] = clip_ref
                ShopEvent.objects.filter(pk=prev.pk).update(signals=sig)
                prev.signals = sig
            return dict(decision, grouped=True), prev

    # DAILY CAP per site: beyond it, alerts are only counted (honestly shown
    # in the app as "N more held back today"), never silently unlimited.
    start = timezone.localtime(now).replace(hour=0, minute=0, second=0,
                                            microsecond=0)
    cap = watchman_cfg("watchman_daily_alert_cap", 30)
    # cashguard: the owner's PLAN caps alerts per day across ALL their sites
    # too (Free 5, Premium 12, Business 30 by default — admin-editable,
    # bounded; inside the 40 % rule, core/logic/cash_guard.py)
    plan_cap = owner_caps(site.owner)["alerts_day"]
    if ShopEvent.objects.filter(site=site, created__gte=start).count() >= cap or \
            ShopEvent.objects.filter(site__owner_id=site.owner_id,
                                     created__gte=start).count() >= plan_cap:
        _count_held(site, timezone.localtime(now).date().isoformat())
        held = dict(decision)
        held.update({"raise": False, "held": "daily_cap"})
        return held, None

    ev = ShopEvent.objects.create(
        site=site, camera=cam, type=decision["type"],
        signals={"inputs": signals,
                 "reason": decision["reason_signals"],
                 "pos_matched": decision["pos_matched"],
                 **({"clip_ref": clip_ref} if clip_ref else {})},
        confidence=decision["confidence"],
        pos_matched=decision["pos_matched"], possible=decision["possible"],
        last_at=now)

    # store AT MOST the one small snapshot (only if retention allows it)
    if snapshot is not None and site.snapshot_retention_days > 0:
        ev.snapshot.save(snapshot.name, snapshot, save=True)

    ShopIngestView._notify_owner(site, cam, ev, quiet=quiet)
    return decision, ev


# event types that only count while the owner's schedule is ARMED (cctv1)
WATCHMAN_ARMED_TYPES = ("motion", "person_detected", "zone_intrusion",
                        "line_crossing", "camera_alarm", "pose_possible")


def away_now(site, now=None):
    """cashguard: is the site's owner in away mode right now? Never raises."""
    from .logic import cash_guard as CG
    from .logic import watchman as WM
    try:
        now = now or timezone.now()
        return CG.away_active(site.away or {}, now, timezone.localtime(now),
                              WM.is_armed)
    except Exception:
        return False


def owner_caps(owner):
    """cashguard plan caps for a site OWNER: {tier, cameras, alerts_day,
    clips_day, clip_kb}. The resource owner's plan counts, never a viewer's."""
    from . import billing
    from .logic import cash_guard as CG
    try:
        from . import entitlements_service as ES
        tier = ES.E.tier_of("free") if owner is None else ES.tier(owner)
    except Exception:
        tier = "free"
    try:
        c = billing.cfg()
        shop = c.get("shop") or {}
        biz = int(c["limits"]["business_included_cameras"])
    except Exception:
        shop, biz = {}, 4
    return CG.caps_for(tier, shop, biz)


def vendor_alarm_event(cam, raw_jpeg, signals, now):
    """cashguard SERVER CHECK for a vendor-cloud alarm (Imou, EZVIZ): the
    camera's own alarm stays a `camera_alarm` — unless the ONE still shows a
    person inside the owner's CASH zone (optional model, off by default),
    which makes it a cash-zone event correlated with POS sales.
    Returns (type, signals). Never raises."""
    try:
        from .logic.cash_guard import cash_zone_of
        from .logic import camera_hooks as CH
        from . import cashguard_detect as CD
        zc = effective_zone_config(cam)
        cash = cash_zone_of(zc)
        if raw_jpeg and cash and CD.check_snapshot(raw_jpeg, cash):
            sig = dict(signals, server_check="snapshot_model",
                       person_in_cash_zone=True)
            if CH.is_after_hours(zc.get("hours"), timezone.localtime(now)):
                return "after_hours", dict(sig, after_hours=True,
                                           person_in_zone=True)
            return "hand_in_cash_zone", sig
    except Exception:
        pass
    return "camera_alarm", signals


def hasattr_clip(ev):
    try:
        return ev.clip is not None
    except Exception:
        return False


def clips_today(site, now=None):
    from .models import ShopEventClip
    start = timezone.localtime(now or timezone.now()).replace(
        hour=0, minute=0, second=0, microsecond=0)
    return ShopEventClip.objects.filter(event__site__owner_id=site.owner_id,
                                        created__gte=start).count()


def clip_wanted(site, ev):
    """Will the server accept a clip for this event right now? (plan clip cap
    left, someone with a public key to seal it for, no clip yet)."""
    try:
        if hasattr_clip(ev):
            return False
        if clips_today(site) >= owner_caps(site.owner)["clips_day"]:
            return False
        return bool(clip_recipients(site))
    except Exception:
        return False


def clip_recipients(site):
    """[{uid, key_id, pub}] — the site owner + family viewers that have a
    published E2E public key. The edge seals each clip's key for these."""
    from .models import UserPublicKey
    users = [site.owner_id] + list(site.viewers.values_list("user_id", flat=True))
    rows = UserPublicKey.objects.filter(user_id__in=users).exclude(public_key="")
    out = []
    for r in rows:
        out.append({"uid": r.user_id, "key_id": r.key_id or "",
                    "pub": r.public_key})
    out.sort(key=lambda x: (x["uid"] != site.owner_id, x["uid"]))
    return out[:8]


def models_Q(**kw):
    from django.db.models import Q
    return Q(**kw)


def F_(name):
    from django.db.models import F
    return F(name)


def watchman_cfg(key, default):
    from . import billing
    try:
        return int((billing.cfg().get("shop") or {}).get(key, default))
    except Exception:
        return default


def _count_held(site, day):
    from .models import ShopSite
    try:
        st = dict(site.stats or {})
        if st.get("day") != day:
            st = {"day": day, "held": 0}
        st["held"] = int(st.get("held", 0)) + 1
        ShopSite.objects.filter(pk=site.pk).update(stats=st)
        site.stats = st
    except Exception:
        pass


def held_today(site, now=None):
    st = site.stats if isinstance(site.stats, dict) else {}
    day = timezone.localtime(now or timezone.now()).date().isoformat()
    return int(st.get("held", 0)) if st.get("day") == day else 0


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
            # cashguard: no target box from the camera -> optionally check the
            # ONE still on the server (off by default; ~60 ms on one core)
            if vev.get("image") and not vev.get("box") and vev.get("active"):
                try:
                    from . import cashguard_detect as CD
                    from .logic.cash_guard import cash_zone_of
                    hit = CD.check_snapshot(vev["image"], cash_zone_of(zc))
                    if hit:
                        vev["server_person_in_zone"] = True
                except Exception:
                    pass
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
        # cctv1: the watchman gateway can be switched later
        if request.data.get("gateway") in ("phone", "shopbox", "pc"):
            s.gateway = request.data["gateway"]
            changed.append("gateway")
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
        # NOTE: this is a HARDWARE/ENTITLEMENT charge, not an AI action — it is
        # priced on its own (shop_extra_camera) and debited directly here, not
        # via billing.charge. (No plan is unlimited any more, for AI or this.)
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
        # cctv1: vendor + LAN source (never a password — that goes to the
        # gateway once, through a check task) + a v2 watchman zone config.
        vendor = request.data.get("vendor") or ""
        if vendor not in {v for v, _ in ShopCamera.VENDORS}:
            vendor = ""
        zc = _coerce_json(request.data.get("zone_config"))
        if not zc and vendor:
            from .logic import watchman as WM
            zc = WM.default_zone_config(s.kind)
        cam = ShopCamera.objects.create(
            site=s, name=(request.data.get("name") or "").strip()[:120],
            kind=kind, zone_config=zc,
            enabled=bool(request.data.get("enabled", True)),
            vendor=vendor, source=clean_source(request.data.get("source")),
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
        # cctv1: a family VIEWER of the site may read its alerts too
        s, role = _viewable_site(request, sid) if sid else (None, None)
        if s is None:
            return _err(lang, "সাইট পাওয়া যায়নি।", "Site not found.", status=404)
        status_f = request.query_params.get("status")
        qs = s.events.select_related("camera", "clip")
        if status_f in {"open", "checked", "false_alarm"}:
            qs = qs.filter(status=status_f)
        cam_f = request.query_params.get("camera")
        if cam_f and str(cam_f).isdigit():
            qs = qs.filter(camera_id=int(cam_f))
        rows = [_event_row(e, request) for e in qs[:200]]
        return Response({"events": rows, "site": s.id, "role": role,
                         "held_today": held_today(s)})


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
        # cctv1: the owner's Correct / Wrong verdict (checked / false_alarm)
        status_v = {"correct": "checked", "wrong": "false_alarm"}.get(
            status_v, status_v)
        if status_v not in {"checked", "false_alarm"}:
            return _err(lang, "স্ট্যাটাস ভুল।", "Invalid status.", status=422,
                        code="bad_status")
        before = e.status
        e.status = status_v
        e.save(update_fields=["status"])
        tuning = None
        # adapt this camera's thresholds ONCE per verdict change (bounded)
        if e.camera_id and before != status_v:
            from .logic import watchman as WM
            from .models import ShopCamera
            cam = ShopCamera.objects.filter(pk=e.camera_id).first()
            if cam is not None:
                verdict = "wrong" if status_v == "false_alarm" else "correct"
                cam.tuning = WM.adapt(cam.tuning, verdict)
                cam.save(update_fields=["tuning"])
                tuning = WM.tuning_of(cam.tuning)
        return Response({"ok": True, "event_id": e.id, "status": e.status,
                         "verdict": "wrong" if e.status == "false_alarm" else "correct",
                         "tuning": tuning})


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
            # cashguard (owner 28 Oct): Free includes 1 camera, Premium 2
            # (admin-editable shop knobs); more = credits, as before
            return owner_caps(user)["cameras"]
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
    """ATOMICALLY debit `need` credits for an EXTRA camera entitlement through
    the bucketed engine (billing-v2). Returns the amount charged (0 if it
    couldn't cover it — the balance stays untouched then)."""
    from . import credits as CR
    need = int(need or 0)
    if need <= 0:
        return 0
    res = CR.spend(user, need, note=(note or "shop_extra_camera")[:120])
    return need if res["ok"] else 0


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
           "kind": s.kind, "gateway": s.gateway,
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
           "billed_until": _iso(c.billed_until),
           # cctv1 (no secrets: the camera password never reaches the server
           # beyond the one-time hand-off to the gateway)
           "vendor": c.vendor, "source": c.source or {},
           "compat": c.compat or {}, "has_preview": bool(c.preview),
           "zones_v2": zc.get("v") == 2,
           "cloud_alarms": bool(c.vendor_ref)}
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
            "camera_name": (e.camera.name if e.camera_id and e.camera else ""),
            # cctv1: grouped repeats + the never-accusatory label
            "count": e.count, "last_at": _iso(e.last_at or e.created),
            "label": "suspicious_please_check",
            "verdict": ("wrong" if e.status == "false_alarm" else
                        "correct" if e.status == "checked" else None),
            # cashguard: cash event? owner away? the encrypted clip's state
            **_cash_fields(e),
            "created": e.created.isoformat()}


def _cash_fields(e):
    from .logic import cash_guard as CG
    sig = e.signals if isinstance(e.signals, dict) else {}
    inputs = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else {}
    clip = None
    try:
        c = e.clip
    except Exception:
        c = None
    if c is not None:
        st = c.status
        if st == "ready" and c.expires_at <= timezone.now():
            st = "expired"
        clip = {"status": st, "expires_at": _iso(c.expires_at),
                "size": c.size}
    elif sig.get("clip_ref"):
        clip = {"status": "pending"}
    return {"cash": CG.is_cash_event(e.type, inputs),
            "away": bool(inputs.get("away")), "clip": clip}


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


def clean_source(v):
    """cctv1: where the gateway finds a camera on the LAN. Secrets are dropped
    here on purpose — the server never keeps a camera password."""
    if not isinstance(v, dict):
        return {}
    out = {}
    host = str(v.get("host") or "").strip()[:64]
    import re
    if host and re.fullmatch(r"[A-Za-z0-9.\-:\[\]]+", host):
        out["host"] = host
    for k, lo, hi in (("port", 1, 65535), ("onvif_port", 1, 65535),
                      ("channel", 1, 64)):
        try:
            n = int(v.get(k))
            if lo <= n <= hi:
                out[k] = n
        except (TypeError, ValueError):
            pass
    if v.get("stream") in ("main", "sub"):
        out["stream"] = v["stream"]
    user = str(v.get("username") or "").strip()[:40]
    if user:
        out["username"] = user
    path = str(v.get("rtsp_path") or "").strip()[:200]
    if path and "@" not in path and "://" not in path:
        out["rtsp_path"] = path
    dev = str(v.get("device_serial") or "").strip()[:40]
    if dev and re.fullmatch(r"[A-Za-z0-9\-]+", dev):
        out["device_serial"] = dev
    return out


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
