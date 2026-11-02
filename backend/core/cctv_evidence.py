"""
cctv_evidence.py — CCTV evidence package W7 (owner CCTV order 3 Nov, part D +
I1/I2). Builds ON the watchman / cash guard / cctvx code — nothing replaced.

OWNER (Token auth, behind the existing watchman switch via _OwnerBase)
  GET  shop/cameras/<id>/recording     SD-card health + "about N days" (where
                                       the vendor reports it), the video
                                       add-on state + prices, today's clips
                                       and whether this camera can hand an SD
                                       clip over (honest reason when not).
                                       ?refresh=1 asks the vendor again.
  POST shop/cameras/<id>/video-addon   {tier: "7d"|"30d"} buy one month with
                                       Assisto credits (Play: see PLAY seam).
  PUT  shop/sites/<id>/address         {address} printed in the evidence pack.
OWNER / ALLOWED VIEWER / ESCALATION PERSON
  GET  shop/events/<id>/sd-clip        the 10-s SD clip's state + a short-
                                       lived signed link when ready.

JOBS (no new cron line): SD-clip fetches run inside the existing per-minute
shop_guard_tick (cctvx tick -> run_sd_clips); expired clips go in the hourly
shop_clip_purge and the daily shop_prune_snapshots (purge_sd_clips).

PRIVACY (I1): media are only reachable through the signed links these
owner-checked views hand out; no Owner Admin / staff view lists them, and
the bytes at rest are sealed (core/logic/cctv_store.py).
"""
import hashlib
import logging
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework.response import Response

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import cctv_store as STORE
from .logic import cctv_video_addon as VA
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")

SD_CACHE_S = 600
FETCH_DELAY_S = 90          # let the camera finish writing the 6 s after
MAX_TRIES = 3
TICK_LIMIT = 10
HLS_MAX_SEGMENTS = 8


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


# ================================================================ add-on
def active_addon(cam, now=None):
    """The camera's active add-on row, or None."""
    now = now or timezone.now()
    try:
        a = cam.video_addon
    except Exception:
        return None
    if a.active_until and a.active_until > now and VA.tier_ok(a.tier):
        return a
    return None


def addon_tier(cam, now=None):
    a = active_addon(cam, now) if cam is not None else None
    return a.tier if a else None


def grant_addon(cam, tier, months=1, source="credits", ref="", now=None):
    """THE seam for every way of paying (credits now; Play Billing from the
    pricing package): extends the camera's add-on by `months` x 30 days. A
    tier change takes effect at once and keeps the remaining paid days."""
    from .models import ShopVideoAddon
    if not VA.tier_ok(tier):
        raise ValueError("bad_tier")
    now = now or timezone.now()
    with transaction.atomic():
        a, _ = ShopVideoAddon.objects.select_for_update().get_or_create(camera=cam)
        base = a.active_until if (a.active_until and a.active_until > now) else now
        a.tier = tier
        a.active_until = base + timedelta(days=VA.PERIOD_DAYS * max(1, int(months)))
        a.source = str(source or "")[:12]
        a.ref = str(ref or "")[:120]
        a.save()
    return a


def photo_days_for(site, cam, now=None):
    return VA.photo_days(site.snapshot_retention_days, addon_tier(cam, now))


def clip_ttl_s(cam, default_s, now=None):
    """cash-guard E2E clips: kept for the add-on's days instead of 24 h."""
    tier = addon_tier(cam, now) if cam is not None else None
    return VA.clip_days(tier) * 86400 if tier else default_s


def _local_day_start(now):
    return timezone.localtime(now).replace(hour=0, minute=0, second=0, microsecond=0)


def clips_today(cam, now=None):
    from .models import ShopSdClip
    now = now or timezone.now()
    return ShopSdClip.objects.filter(camera=cam, created__gte=_local_day_start(now)) \
        .exclude(status="unsupported").count()


# ================================================================ vendor support
def clip_support(cam):
    """(supported, reason) — can this camera hand a 10-s SD clip over through
    an official vendor API we use?"""
    ref = cam.vendor_ref or ""
    if cam.vendor == "ezviz" and ref.startswith("EZ:"):
        try:
            from . import cashguard_views as CGV
            if not CGV.ezviz_on():
                return False, "ezviz_off"
        except Exception:
            return False, "ezviz_off"
        return True, ""
    if cam.vendor in ("imou", "dahua") and ref:
        return False, "imou_no_download"
    if cam.vendor == "phone":
        return False, "phone_camera"
    return False, "vendor_no_api"


SUPPORT_WORDS = {
    "ezviz_off": ("EZVIZ সংযোগ এখনো চালু হয়নি (মালিকের ডেভেলপার অ্যাকাউন্ট লাগবে)।",
                  "The EZVIZ link is not on yet (needs the owner's developer account)."),
    "imou_no_download": ("Imou-র অফিসিয়াল API-তে SD কার্ডের ভিডিও নামানো যায় না — "
                         "রেকর্ড আছে কিনা দেখা যায়; ভিডিওটি Imou Life অ্যাপে দেখুন।",
                         "Imou's official API cannot download SD-card video — it only shows "
                         "that a recording exists; watch it in the Imou Life app."),
    "phone_camera": ("ফোন-ক্যামেরা নিজের ফোনেই রেকর্ড রাখে।",
                     "A phone camera keeps its recording on that phone."),
    "vendor_no_api": ("এই ক্যামেরার কোম্পানির কোনো অফিসিয়াল API থেকে SD-কার্ডের ক্লিপ আনা যায় না।",
                      "This camera's maker offers no official API to fetch an SD-card clip."),
    "no_recording": ("ওই সময়ে SD কার্ডে কোনো রেকর্ড পাওয়া যায়নি।",
                     "No SD-card recording was found for that moment."),
    "fetch_failed": ("ক্যামেরা থেকে ক্লিপ আনা যায়নি (অফলাইন বা নেটওয়ার্ক)।",
                     "The clip could not be fetched (camera offline or network)."),
    "daily_cap": ("আজ এই ক্যামেরার ৩০টি ক্লিপের সীমা শেষ — ছবি আছে।",
                  "Today's 30-clip limit for this camera is used — the photo stays."),
    "expired": ("রাখার মেয়াদ শেষ হওয়ায় ক্লিপটি মুছে গেছে।",
                "The clip was deleted when its keep period ended."),
}


def support_text(lang, reason):
    bn, en = SUPPORT_WORDS.get(reason, SUPPORT_WORDS["vendor_no_api"])
    return pick(lang, bn, en)


# ================================================================ SD health
def sd_health(cam, refresh=False, now=None, ezviz=None, imou=None):
    """{"state", "total_bytes", "used_bytes", "days", "source", "checked_at",
    "reason"} — cached 10 min in cam.compat["sd"]. Never raises."""
    from .models import ShopCamera
    now = now or timezone.now()
    cached = (cam.compat or {}).get("sd") or {}
    try:
        age = now.timestamp() - float(cached.get("ts") or 0)
    except (TypeError, ValueError):
        age = SD_CACHE_S + 1
    if cached and not refresh and age < SD_CACHE_S:
        return cached
    out = {"state": "unknown", "total_bytes": None, "used_bytes": None,
           "days": None, "source": "", "reason": "", "ts": now.timestamp(),
           "checked_at": now.isoformat()}
    ref = cam.vendor_ref or ""
    try:
        if cam.vendor == "ezviz" and ref.startswith("EZ:"):
            from .logic import ezviz as EZ
            client = ezviz or EZ.EzvizClient.from_integration()
            if client is None:
                out["reason"] = "ezviz_off"
            else:
                out["state"] = EZ.sd_state(client.sd_status(ref.split(":")[1]))
                out["source"] = "ezviz"
                out["reason"] = "size_not_reported"
        elif cam.vendor in ("imou", "dahua") and ref:
            from .logic import imou as IM
            client = imou or IM.ImouClient.from_integration()
            if client is None:
                out["reason"] = "imou_off"
            else:
                did = ref.split(":")[0]
                out["state"] = IM.sd_state(client.sd_status(did))
                out["source"] = "imou"
                if out["state"] in ("ok", "formatting"):
                    try:
                        st = client.sd_storage(did)
                        total = int(st.get("totalBytes") or 0)
                        used = int(st.get("usedBytes") or 0)
                        if total > 0:
                            out["total_bytes"], out["used_bytes"] = total, used
                            out["days"] = VA.sd_days_estimate(total)
                    except Exception:
                        out["reason"] = "size_not_reported"
        else:
            out["reason"] = "vendor_no_api"
    except Exception as e:  # noqa: BLE001 - vendor error: honest unknown
        out["state"] = "unknown"
        out["reason"] = "vendor_error"
        log.info("sd health failed for cam %s: %s", cam.pk, str(e)[:80])
    ShopCamera.objects.filter(pk=cam.pk).update(compat=dict(cam.compat or {}, sd=out))
    cam.compat = dict(cam.compat or {}, sd=out)
    return out


SD_WORDS = {
    "ok": ("SD কার্ড ঠিক আছে", "SD card OK"),
    "error": ("SD কার্ডে সমস্যা — বদলান বা ফরম্যাট করুন", "SD card error — replace or format it"),
    "unformatted": ("SD কার্ড ফরম্যাট করা নেই", "SD card not formatted"),
    "formatting": ("SD কার্ড ফরম্যাট হচ্ছে", "SD card formatting"),
    "none": ("ক্যামেরায় SD কার্ড নেই — ২৪ ঘণ্টা রেকর্ড হচ্ছে না", "No SD card — nothing is recorded 24/7"),
    "unknown": ("SD কার্ডের অবস্থা জানা যায় না", "SD card state not known"),
}


# ================================================================ clip pipeline
def on_event(ev, now=None):
    """Called once for every NEW alert (shop_views._ingest_event). A person
    alert on a camera with an active add-on queues ONE SD clip (daily cap).
    Never raises."""
    from .models import ShopSdClip
    try:
        cam = ev.camera
        now = now or timezone.now()
        if cam is None or ev.pending or not VA.is_person_alert(ev.type, ev.signals):
            return None
        if active_addon(cam, now) is None:
            return None
        ok, reason = clip_support(cam)
        start_ts, end_ts = VA.clip_window(ev.created.timestamp())
        tz = timezone.get_current_timezone()
        from datetime import datetime
        row = dict(event=ev, camera=cam,
                   start=datetime.fromtimestamp(start_ts, tz),
                   end=datetime.fromtimestamp(end_ts, tz))
        if not ok:
            return ShopSdClip.objects.create(status="unsupported", reason=reason, **row)
        if not VA.can_add_clip(clips_today(cam, now)):
            return ShopSdClip.objects.create(status="unsupported", reason="daily_cap", **row)
        return ShopSdClip.objects.create(status="pending",
                                         due_at=now + timedelta(seconds=FETCH_DELAY_S), **row)
    except Exception:
        log.exception("sd clip queue failed")
        return None


def _fmt_local(dt):
    return timezone.localtime(dt).strftime("%Y-%m-%d %H:%M:%S")


def _http_get(url, limit):
    import requests
    r = requests.get(url, timeout=10, stream=True, allow_redirects=False)
    if r.status_code != 200:
        return None
    raw = r.raw.read(limit + 1, decode_content=True)
    return raw if len(raw) <= limit else raw[:limit + 1]


def fetch_hls_clip(m3u8_url, getter=None, max_bytes=VA.MAX_CLIP_BYTES,
                   allowed=None):
    """Download the HLS playlist + its MPEG-TS segments (<= max_bytes, at
    most HLS_MAX_SEGMENTS) -> one .ts byte string, or None. Every URL must
    pass `allowed` (vendor host allow-list; SSRF guard)."""
    from urllib.parse import urljoin
    get = getter or _http_get
    allowed = allowed or (lambda u: u.startswith("https://"))
    if not allowed(m3u8_url):
        return None
    pl = get(m3u8_url, 64 * 1024)
    if not pl:
        return None
    try:
        text = pl.decode("utf-8", "replace")
    except AttributeError:
        text = str(pl)
    if "#EXTM3U" not in text:
        return None
    segs = [urljoin(m3u8_url, ln.strip()) for ln in text.splitlines()
            if ln.strip() and not ln.startswith("#")]
    out = bytearray()
    for u in segs[:HLS_MAX_SEGMENTS]:
        if not allowed(u):
            return None
        room = max_bytes - len(out)
        if room <= 0:
            break
        b = get(u, room)
        if not b:
            break
        out += bytes(b[:room])
    return bytes(out) if len(out) >= 1024 else None


def fetch_one(clip, now=None, ezviz=None, getter=None):
    """Try to fetch one pending clip. Returns the new status."""
    from .logic import ezviz as EZ
    now = now or timezone.now()
    cam = clip.camera
    clip.tries += 1
    try:
        client = ezviz or EZ.EzvizClient.from_integration()
        if client is None:
            clip.status, clip.reason = "unsupported", "ezviz_off"
        else:
            _, serial, ch = (cam.vendor_ref or "EZ::1").split(":")
            url = client.playback_hls(serial, ch, _fmt_local(clip.start), _fmt_local(clip.end))
            if not url:
                clip.status, clip.reason = "failed", "no_recording"
            else:
                data = fetch_hls_clip(url, getter=getter, allowed=EZ.snapshot_url_allowed)
                if not data:
                    clip.status, clip.reason = "failed", "fetch_failed"
                else:
                    name = "shop/sdclip/e%d_%s.ts" % (clip.event_id, hashlib.sha1(
                        str(clip.pk).encode()).hexdigest()[:8])
                    STORE.put(name, data)
                    days = VA.clip_days(addon_tier(cam, now)) or VA.TIERS["7d"]["days"]
                    clip.name, clip.size = name, len(data)
                    clip.sha256 = hashlib.sha256(data).hexdigest()
                    clip.status, clip.reason = "ready", ""
                    clip.expires_at = now + timedelta(days=days)
    except Exception as e:  # noqa: BLE001
        clip.status, clip.reason = "failed", "fetch_failed"
        log.info("sd clip fetch failed (clip %s): %s", clip.pk, str(e)[:80])
    if clip.status == "failed" and clip.tries < MAX_TRIES:
        clip.status = "pending"                  # retry in 2 minutes
        clip.due_at = now + timedelta(minutes=2)
    clip.save()
    return clip.status


def run_sd_clips(now=None, ezviz=None, getter=None):
    """Minute job body (inside shop_guard_tick). Bounded; never raises."""
    from .models import ShopSdClip
    now = now or timezone.now()
    n = 0
    try:
        for c in ShopSdClip.objects.filter(status="pending", due_at__lte=now) \
                .select_related("camera").order_by("due_at")[:TICK_LIMIT]:
            fetch_one(c, now, ezviz=ezviz, getter=getter)
            n += 1
    except Exception:
        log.exception("sd clip run failed")
    return n


def purge_sd_clips(now=None):
    """Lifecycle delete: SD clips past expires_at (bytes go, the row stays
    as a tombstone with its SHA-256). Never raises. Returns the count."""
    from .models import ShopSdClip
    now = now or timezone.now()
    n = 0
    try:
        for c in ShopSdClip.objects.filter(status="ready", expires_at__lte=now):
            try:
                STORE.delete(c.name)
            except Exception:
                log.exception("sd clip delete failed")
                continue
            c.status, c.reason, c.name = "expired", "expired", ""
            c.save(update_fields=["status", "reason", "name"])
            n += 1
        # never-fetched rows older than a day are closed honestly
        ShopSdClip.objects.filter(status="pending", created__lt=now - timedelta(days=1)) \
            .update(status="failed", reason="fetch_failed")
    except Exception:
        log.exception("sd clip purge failed")
    return n


def sd_clip_json(clip, lang, request=None):
    if clip is None:
        return None
    d = {"status": clip.status, "reason": clip.reason or None,
         "seconds": VA.CLIP_SECONDS, "size": clip.size, "sha256": clip.sha256 or None,
         "start": SV._iso(clip.start), "end": SV._iso(clip.end),
         "expires_at": SV._iso(clip.expires_at), "url": None, "file": None}
    if clip.status == "ready" and clip.name:
        from .media_sign import signed_url
        d["url"] = signed_url(clip.name)
        if request is not None:
            d["url"] = request.build_absolute_uri(d["url"])
        d["file"] = "sd_clip_%s.ts" % timezone.localtime(clip.start).strftime("%Y%m%d_%H%M%S")
    if clip.reason:
        d["reason_text"] = support_text(lang, clip.reason)
    return d


# ================================================================ views
def _owner_cam(request, pk):
    from .models import ShopCamera
    try:
        return ShopCamera.objects.select_related("site").get(
            pk=int(pk), site__owner=request.user)
    except (ShopCamera.DoesNotExist, TypeError, ValueError):
        return None


def _credit_bdt():
    try:
        from . import billing
        return float(billing.cfg().get("credit_bdt") or 1.0)
    except Exception:
        return 1.0


def recording_state(cam, lang, refresh=False, now=None):
    now = now or timezone.now()
    a = active_addon(cam, now)
    ok, reason = clip_support(cam)
    sd = sd_health(cam, refresh=refresh, now=now)
    sd_out = {k: sd.get(k) for k in ("state", "total_bytes", "used_bytes", "days",
                                     "source", "checked_at", "reason")}
    words = SD_WORDS.get(sd_out["state"] or "unknown", SD_WORDS["unknown"])
    sd_out["label"] = pick(lang, *words)
    cb = _credit_bdt()
    try:
        row = cam.video_addon
    except Exception:
        row = None
    return {
        "camera_id": cam.id, "vendor": cam.vendor,
        "sd": sd_out,
        "addon": {"active": a is not None, "tier": a.tier if a else None,
                  "active_until": SV._iso(a.active_until) if a else None,
                  "last_tier": row.tier if row else None,
                  "tiers": [{"tier": t, "days": VA.TIERS[t]["days"],
                             "price_tk": VA.TIERS[t]["price_tk"],
                             "credits": VA.credits_for(t, cb),
                             "play_product": VA.PLAY_PRODUCTS[t]} for t in VA.TIERS],
                  "photo_days": photo_days_for(cam.site, cam, now),
                  "base_photo_days": VA.BASE_PHOTO_DAYS},
        "clips": {"today": clips_today(cam, now), "max_per_day": VA.MAX_CLIPS_PER_CAMERA_DAY,
                  "seconds": VA.CLIP_SECONDS},
        "clip_support": {"supported": ok, "reason": reason or None,
                         "text": support_text(lang, reason) if reason else None},
        "storage": STORE.backend_name(),
        "address": cam.site.address,
        "site_id": cam.site_id,
    }


class CameraRecordingView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "ক্যামেরা পাওয়া যায়নি।", "Camera not found.", status=404)
        refresh = str(request.GET.get("refresh") or "") in ("1", "true")
        return Response(recording_state(cam, lang, refresh=refresh))


class CameraVideoAddonView(_OwnerBase):
    def post(self, request, pk):
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "ক্যামেরা পাওয়া যায়নি।", "Camera not found.", status=404)
        tier = str(request.data.get("tier") or "")
        if not VA.tier_ok(tier):
            return _err(lang, "প্যাকেজ ঠিক নেই।", "Unknown package.", status=422,
                        code="bad_tier")
        need = VA.credits_for(tier, _credit_bdt())
        got = SV._debit_camera_credits(request.user, need,
                                       note="cctv_video_%s cam %d" % (tier, cam.id))
        if got < need:
            return _err(lang, "যথেষ্ট ক্রেডিট নেই।", "Not enough credits.", status=402,
                        code="no_credits", credits_needed=need)
        grant_addon(cam, tier, 1, source="credits", ref="spend:%d" % need)
        cam.refresh_from_db()
        out = recording_state(cam, lang)
        out["charged_credits"] = need
        return Response(out, status=201)


class SiteAddressView(_OwnerBase):
    def put(self, request, pk):
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        addr = " ".join(str(request.data.get("address") or "").split())[:200]
        type(site).objects.filter(pk=site.pk).update(address=addr)
        return Response({"ok": True, "address": addr})

    post = put          # the app's ApiClient posts JSON


class EventSdClipView(_OwnerBase):
    def get(self, request, pk):
        from .cctvx_views import event_access
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None or role not in ("owner", "viewer", "escalated"):
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        try:
            clip = ev.sd_clip
        except Exception:
            clip = None
        if clip is not None and clip.status == "ready" and clip.expires_at and \
                clip.expires_at <= timezone.now():
            purge_sd_clips()
            clip.refresh_from_db()
        out = sd_clip_json(clip, lang, request)
        if out is None:
            cam = ev.camera
            has = cam is not None and active_addon(cam) is not None
            out = {"status": "none", "addon": has,
                   "reason_text": None if has else pick(
                       lang, "এই ক্যামেরায় ভিডিও অ্যাড-অন নেই — শুধু ছবি রাখা হয়।",
                       "No video add-on on this camera — only the photo is kept.")}
        return Response(out)
