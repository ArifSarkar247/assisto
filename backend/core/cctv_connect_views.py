"""
cctv_connect_views.py — CCTV Guard V3 (agent cctvconnect):

A1  BRAND CLOUDS: connect EZVIZ / Imou / Hik-Connect / DoLynk once per site,
    list the DVR / camera channels, import them as cameras, live + playback
    URLs for the player (cctvplay uses stream_for()), the camera's own AI
    events into the normal alert path, revoke at any time.
B   DVR HEALTH: reports from the Guard Box (ISAPI / Dahua API on the LAN) or
    from the clouds -> logic/dvr_health.py -> problems -> one camera_health
    alert per new problem (6 h re-fire guard) + the daily green-check card.

Rules: a connector is shown only when its key exists and its Owner Admin
Test passed (never a dead button). Grants are sealed + bound to the site.
Video URLs go ONLY to the site owner or a viewer the owner allowed live —
never to staff / admin (is_superuser gives no access here). No video ever
passes through our server: vendor HLS URLs go straight to the phone.
Gated by the existing CCTV switch (home_watchman) — no new flag.
"""
import logging
import time
from datetime import timedelta

from django.core import signing
from django.db import transaction
from django.http import HttpResponse
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import shop_views as SV
from . import watchman_views as WMV
from .i18n import req_lang, pick
from .logic import cctv_connect as CC
from .logic import dvr_health as DH

log = logging.getLogger("assisto.shop")

OAUTH_SALT = "cctvconnect.oauth"
OAUTH_MAX_AGE_S = 15 * 60
SEEN_KEEP = 200
EVENT_LOOKBACK_S = 10 * 60
CLOUD_HEALTH_EVERY_S = 3 * 3600
LINKS_PER_SITE = 12
SERIALS_PER_LINK = 16
DAILY_HOUR = 9                     # Dhaka time, the daily green check
REF_PREFIX = {"hikconnect": "HC:", "dolynk": "DL:", "ezviz": "EZ:", "imou": ""}


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _cerr(lang, e, status=502):
    return _err(lang, *CC.base.HINT_TEXT.get(e.hint, CC.base.HINT_TEXT["vendor"]),
                status=status, code="vendor_" + e.hint, vendor_code=e.code)


def vendor_ref(pid, serial, channel):
    """Matches the formats the existing Imou / EZVIZ pipelines already use
    (callback, poll, live, evidence) so an imported camera works there too."""
    if pid == "imou":
        return "%s:%s" % (serial, channel)
    return "%s%s:%s" % (REF_PREFIX.get(pid, pid.upper() + ":"), serial, channel)


def parse_ref(cam):
    """camera -> (pid, serial, channel) or (None, None, None)."""
    ref = str(cam.vendor_ref or "")
    if not ref:
        return None, None, None
    for pid, pre in REF_PREFIX.items():
        if pre and ref.startswith(pre):
            parts = ref[len(pre):].split(":")
            return pid, parts[0], (parts[1] if len(parts) > 1 else "1")
    if cam.vendor == "imou":
        dev, _, ch = ref.partition(":")
        return "imou", dev, ch or "0"
    return None, None, None


def link_row(l):
    a = CC.ADAPTERS.get(l.provider)
    return {"id": l.id, "provider": l.provider, "name": a.name if a else l.provider,
            "label": l.label, "mode": l.mode, "status": l.status,
            "serials": list(l.serials or []), "devices": len(l.serials or []),
            "last_sync": SV._iso(l.last_sync), "last_error": l.last_error,
            "created": SV._iso(l.created)}


def provider_row(pid):
    a = CC.adapter(pid)
    return {"id": pid, "name": a.name, "modes": a.modes(),
            "code_label_bn": a.code_label[0], "code_label_en": a.code_label[1],
            "caps": list(a.caps), "camera_vendor": CC.CAMERA_VENDOR[pid]}


def _link_for(request, pk, owner_only=True):
    from .models import CctvCloudLink
    try:
        l = CctvCloudLink.objects.select_related("site").get(pk=int(pk))
    except (CctvCloudLink.DoesNotExist, TypeError, ValueError):
        return None
    if l.site.owner_id != request.user.pk:
        return None
    return l


def _grant(link):
    return CC.unseal(link.site_id, link.grant_blob)


def _save_grant(link, grant):
    link.grant_blob = CC.seal(link.site_id, grant)
    link.save(update_fields=["grant_blob"])


def _fresh(link, a):
    g = _grant(link)
    if not g:
        raise CC.ConnectError("revoked")
    g2, changed = a.fresh(g)
    if changed:
        _save_grant(link, g2)
    return g2


def links_with(pid, serial, statuses=("active", "error"), site=None):
    """Links holding `serial` (JSON 'contains' is not portable to SQLite, and
    a provider has few links per serial prefix: filtered in Python)."""
    from .models import CctvCloudLink
    qs = CctvCloudLink.objects.filter(provider=pid, status__in=statuses)
    if site is not None:
        qs = qs.filter(site=site)
    return [l for l in qs.select_related("site") if serial in (l.serials or [])]


def serial_taken(pid, serial, except_site=None):
    return any(l.site_id != except_site for l in links_with(pid, serial))


LINK_TRIES_PER_HOUR = 10


def link_attempt_ok(user_id):
    """Label codes are short: at most LINK_TRIES_PER_HOUR tries per user per
    hour, so nobody can guess another shop's code through us."""
    from django.core.cache import cache
    key = "cctvconnect:tries:%s:%d" % (user_id, int(time.time() // 3600))
    try:
        n = cache.get_or_set(key, 0, 3700)
        if n >= LINK_TRIES_PER_HOUR:
            return False
        try:
            cache.incr(key)
        except ValueError:
            cache.set(key, 1, 3700)
    except Exception:
        return True
    return True


# ===================================================================== A1
class ProvidersView(WMV._OwnerBase):
    """GET cctv/connect/providers?site=<id> — the brand clouds that are ON
    (keys + passed test) and this site's links. Empty list = only the Wi-Fi
    path (Guard Box discovery) — the app then shows that, never a dead card."""

    def get(self, request):
        lang = req_lang(request)
        from .models import CctvCloudLink
        site = SV._owner_site(request, request.query_params.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        links = CctvCloudLink.objects.filter(site=site).exclude(status="revoked")
        return Response({"providers": [provider_row(p) for p in CC.enabled_ids()],
                         "links": [link_row(l) for l in links],
                         "local_ok": True})


class LinkDeviceView(WMV._OwnerBase):
    """POST cctv/connect/<pid>/link {site, serial, code} — authorize ONE
    device with its label code (the code is used once, never stored). A
    second device of the same brand joins the same link."""

    def post(self, request, pid):
        from .models import CctvCloudLink
        lang = req_lang(request)
        site = SV._owner_site(request, request.data.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if pid not in CC.ADAPTERS or not CC.enabled(pid):
            return _err(lang, *CC.base.HINT_TEXT["not_configured"], status=503,
                        code="not_configured")
        serial = CC.base.clean_serial(request.data.get("serial"))
        code = CC.base.clean_code(request.data.get("code"))
        if not serial:
            return _err(lang, "ক্যামেরা / DVR-এর লেবেলের সিরিয়াল নম্বর (SN) দিন।",
                        "Enter the serial number (SN) from the camera / DVR label.",
                        status=422, code="serial_required")
        if not code:
            return _err(lang, "লেবেলের কোডটি দিন (অক্ষর ও সংখ্যা)।",
                        "Enter the code from the label (letters and digits).",
                        status=422, code="code_required")
        if serial_taken(pid, serial, except_site=site.id):
            return _err(lang, *CC.base.HINT_TEXT["taken"], status=409, code="taken")
        if not link_attempt_ok(request.user.pk):
            return _err(lang, "এক ঘণ্টায় অনেকবার চেষ্টা হয়েছে — একটু পরে আবার চেষ্টা করুন।",
                        "Too many tries this hour — please try again a little later.",
                        status=429, code="rate_limited")
        a = CC.adapter(pid)
        try:
            g = a.link_device(serial, code)
        except CC.ConnectError as e:
            return _cerr(lang, e, status=422 if e.hint in ("wrong_code", "taken") else 502)
        with transaction.atomic():
            link = CctvCloudLink.objects.select_for_update().filter(
                site=site, provider=pid, mode="device_code",
                status__in=("active", "error")).first()
            if link is None:
                if CctvCloudLink.objects.filter(site=site).exclude(
                        status="revoked").count() >= LINKS_PER_SITE:
                    return _err(lang, "এই জায়গায় আর সংযোগ যোগ করা যাবে না।",
                                "No more links can be added to this place.",
                                status=409, code="too_many_links")
                link = CctvCloudLink(site=site, provider=pid, mode="device_code",
                                     label=a.name, state={"since": time.time()})
                link.save()
                grant = {"mode": "device_code", "serials": []}
            else:
                grant = _grant(link) or {"mode": "device_code", "serials": []}
            serials = [s for s in grant.get("serials") or [] if s != serial] + [serial]
            if len(serials) > SERIALS_PER_LINK:
                return _err(lang, "একটি সংযোগে সর্বোচ্চ ১৬টি ডিভাইস।",
                            "Up to 16 devices per link.", status=409, code="too_many_devices")
            grant["serials"] = serials
            link.grant_blob = CC.seal(site.id, grant)
            link.serials = serials
            link.status, link.last_error = "active", ""
            link.save(update_fields=["grant_blob", "serials", "status", "last_error"])
        devices = []
        try:
            devices = [d for d in a.devices({"serials": [serial]})]
        except CC.ConnectError:
            pass
        return Response({"link": link_row(link), "devices": devices}, status=201)


class OAuthStartView(WMV._OwnerBase):
    """POST cctv/connect/<pid>/oauth/start {site} -> {"url"} — the vendor's own
    consent page (only when the owner saved that vendor's OAuth URLs)."""

    def post(self, request, pid):
        lang = req_lang(request)
        site = SV._owner_site(request, request.data.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        a = CC.adapter(pid) if CC.enabled(pid) else None
        if a is None or "oauth" not in a.modes():
            return _err(lang, *CC.base.HINT_TEXT["not_configured"], status=503,
                        code="not_configured")
        state = signing.dumps({"s": site.id, "u": request.user.pk, "p": pid}, salt=OAUTH_SALT)
        return Response({"url": a.oauth_url(state, _redirect_uri(request))})


def _redirect_uri(request):
    from django.conf import settings
    base = getattr(settings, "ASSISTO_BASE_URL", "") or request.build_absolute_uri("/")[:-1]
    return "%s/api/v1/cctv/connect/oauth/callback" % base.rstrip("/")


class OAuthCallbackView(APIView):
    """GET cctv/connect/oauth/callback?code&state — the browser lands here
    after the vendor consent page; a tiny bilingual page says "go back to
    Assisto". The signed state (15 min) carries site + user + vendor."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from .models import CctvCloudLink, ShopSite
        try:
            st = signing.loads(request.query_params.get("state") or "", salt=OAUTH_SALT,
                               max_age=OAUTH_MAX_AGE_S)
        except signing.BadSignature:
            return _page(False)
        site = ShopSite.objects.filter(pk=st.get("s"), owner_id=st.get("u")).first()
        a = CC.adapter(st.get("p")) if CC.enabled(st.get("p")) else None
        code = str(request.query_params.get("code") or "")[:512]
        if site is None or a is None or not code:
            return _page(False)
        try:
            g = a.oauth_finish(code, _redirect_uri(request))
        except CC.ConnectError:
            return _page(False)
        link = CctvCloudLink.objects.create(site=site, provider=a.id, mode="oauth",
                                            label=a.name, state={"since": time.time()})
        _save_grant(link, g)
        return _page(True)


def _page(ok):
    msg = ("সংযোগ সম্পূর্ণ — এখন Assisto অ্যাপে ফিরে যান।<br>Connected — go back to the Assisto app."
           if ok else "সংযোগ হয়নি — Assisto অ্যাপে ফিরে আবার চেষ্টা করুন।<br>"
                      "Not connected — go back to Assisto and try again.")
    return HttpResponse("<!doctype html><meta name=viewport content='width=device-width'>"
                        "<p style='font:18px sans-serif;padding:24px'>%s</p>" % msg,
                        status=200 if ok else 400)


class LinkDevicesView(WMV._OwnerBase):
    """GET cctv/connect/links/<id>/devices — the link's devices + channels,
    each channel marked when it is already a camera here."""

    def get(self, request, pk):
        lang = req_lang(request)
        link = _link_for(request, pk)
        if link is None or link.status == "revoked":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        a = CC.adapter(link.provider)
        if not CC.enabled(link.provider):
            return _err(lang, *CC.base.HINT_TEXT["not_configured"], status=503,
                        code="not_configured")
        try:
            devs = a.devices(_fresh(link, a))
        except CC.ConnectError as e:
            _note_error(link, e)
            return _cerr(lang, e)
        have = set(link.site.cameras.exclude(vendor_ref="").values_list("vendor_ref", flat=True))
        for d in devs:
            for c in d["channels"]:
                c["added"] = vendor_ref(link.provider, d["serial"], c["no"]) in have
        return Response({"link": link_row(link), "devices": devs})


class LinkImportView(WMV._OwnerBase):
    """POST cctv/connect/links/<id>/import {items: [{serial, channel, name?}]}
    — the chosen channels become cameras of the site, within the cameras
    the owner's plan includes (never silently charged). Skipped ones say why."""

    def post(self, request, pk):
        from .models import ShopCamera
        from .logic import watchman as WM
        lang = req_lang(request)
        link = _link_for(request, pk)
        if link is None or link.status == "revoked":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        items = request.data.get("items") or []
        if not isinstance(items, list) or not items:
            return _err(lang, "কোন ক্যামেরা যোগ করবেন বেছে নিন।", "Choose the cameras to add.",
                        status=422, code="items_required")
        allowed_serials = set(link.serials or [])
        free = max(0, SV._included_cameras(request.user)
                   - SV.owner_enabled_cameras(request.user).count())
        added, skipped = [], []
        for it in items[:CC.base.MAX_CHANNELS]:
            if not isinstance(it, dict):
                continue
            serial = CC.base.clean_serial(it.get("serial"))
            try:
                ch = int(it.get("channel"))
            except (TypeError, ValueError):
                ch = -1
            if serial not in allowed_serials or not 0 <= ch < 256:
                skipped.append({"serial": serial, "channel": ch, "why": "not_in_link"})
                continue
            ref = vendor_ref(link.provider, serial, ch)
            if ShopCamera.objects.filter(vendor_ref=ref).exists():
                skipped.append({"serial": serial, "channel": ch, "why": "already_added"})
                continue
            if free <= 0:
                skipped.append({"serial": serial, "channel": ch, "why": "plan_full"})
                continue
            name = str(it.get("name") or "").strip()[:120] or (
                ("ক্যামেরা %s" % SV._bn_digits(ch)) if lang == "bn" else "Camera %d" % ch)
            cam = ShopCamera.objects.create(
                site=link.site, name=name, kind="edge_webhook",
                vendor=CC.CAMERA_VENDOR[link.provider],
                zone_config=WM.default_zone_config(link.site.kind),
                vendor_ref=ref,
                source=SV.clean_source({"device_serial": serial, "channel": ch,
                                        "cloud": link.provider}))
            free -= 1
            added.append(SV._camera_row(cam))
        msg = ""
        if any(s["why"] == "plan_full" for s in skipped):
            msg = pick(lang, "প্ল্যানের সব ক্যামেরা ব্যবহার হয়েছে — বাকিগুলো যোগ করতে প্ল্যানে ক্যামেরার সংখ্যা বাড়ান।",
                       "All cameras in your plan are used — raise the camera count in your plan to add the rest.")
        return Response({"added": added, "skipped": skipped, "message": msg},
                        status=201 if added else 200)


class LinkRevokeView(WMV._OwnerBase):
    """DELETE cctv/connect/links/<id> — revoke: release the devices at the
    vendor (best effort), wipe the grant, unlink the imported cameras' cloud
    reference (the cameras and their old alerts stay; the owner deletes them
    if wanted)."""

    def delete(self, request, pk):
        lang = req_lang(request)
        link = _link_for(request, pk)
        if link is None or link.status == "revoked":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        g = _grant(link)
        if g and CC.enabled(link.provider):
            try:
                CC.adapter(link.provider).unlink(g)
            except CC.ConnectError:
                pass
        refs = [vendor_ref(link.provider, s, "") for s in link.serials or []]
        n = 0
        for cam in link.site.cameras.exclude(vendor_ref=""):
            if any(cam.vendor_ref.startswith(r) for r in refs):
                cam.vendor_ref = ""
                cam.save(update_fields=["vendor_ref"])
                n += 1
        link.grant_blob, link.status, link.revoked_at = "", "revoked", timezone.now()
        link.serials = []
        link.save(update_fields=["grant_blob", "status", "revoked_at", "serials"])
        return Response({"ok": True, "cameras_unlinked": n})


# ---------------------------------------------------------------- streams
def link_of_camera(cam):
    pid, serial, ch = parse_ref(cam)
    if pid is None:
        return None, None, None
    rows = links_with(pid, serial, ("active",), site=cam.site)
    return (rows[0] if rows else None), serial, ch


def stream_for(cam, kind="live", hd=False, start=None, end=None):
    """THE hook for the player (cctvplay, part H): a vendor live / playback
    URL for an imported cloud camera -> dict (url, proto, expires_s, ...).
    Raises CC.ConnectError (hint "not_configured" / "no_stream" / ...).
    The caller has ALREADY checked the user may see this camera."""
    link, serial, ch = link_of_camera(cam)
    if link is None:
        raise CC.ConnectError("not_configured")
    if not CC.enabled(link.provider):
        raise CC.ConnectError("not_configured")
    a = CC.adapter(link.provider)
    g = _fresh(link, a)
    if not a.owns(g, serial):
        raise CC.ConnectError("revoked")
    if kind == "playback":
        now = time.time()
        end = min(float(end or now), now)
        start = max(float(start or end - 60), end - 3600)
        return a.playback(g, serial, ch, start, end)
    return a.live(g, serial, ch, hd)


class CameraStreamView(WMV._OwnerBase):
    """POST cctv/connect/cameras/<id>/stream {kind: live|playback, hd, start, end}
    — the owner, or a viewer the owner allowed live, gets the vendor URL.
    Staff / admin get nothing (no special case for superusers)."""

    def post(self, request, pk):
        from . import cctv_team_views as CTV
        lang = req_lang(request)
        cam, role, viewer = CTV.camera_access(request, pk)
        if cam is None or (role != "owner" and not CTV.viewer_live_ok(cam, viewer)):
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        kind = "playback" if request.data.get("kind") == "playback" else "live"
        try:
            out = stream_for(cam, kind, SV._coerce_bool(request.data.get("hd")),
                             request.data.get("start"), request.data.get("end"))
        except CC.ConnectError as e:
            return _cerr(lang, e, status=503 if e.hint == "not_configured" else 502)
        except (TypeError, ValueError):
            return _err(lang, "সময় ঠিক নেই।", "Bad time range.", status=422)
        if role != "owner":
            CTV.log_access(cam.site, kind if kind == "live" else "live", user=request.user,
                           camera_id=cam.id)
        return Response(dict(out, camera_id=cam.id, kind=kind))


# ---------------------------------------------------------------- events
def _fetch_picture(url, hosts):
    if not url or not CC.base.host_allowed(url, hosts):
        return None
    try:
        import requests
        r = requests.get(url, timeout=8, stream=True, allow_redirects=False)
        if r.status_code != 200 or not (r.headers.get("Content-Type") or "image/").lower(
                ).startswith("image/"):
            return None
        raw = r.raw.read(2 * 1024 * 1024 + 1, decode_content=True)
        return raw if raw and len(raw) <= 2 * 1024 * 1024 else None
    except Exception:  # noqa: BLE001
        return None


def ingest_cloud_event(link, ev, now=None, fetch=None):
    """One normalized vendor event -> the normal alert path. Returns
    "raised" | "grouped" | "duplicate" | "unknown_camera" | "muted"."""
    from .models import ShopCamera
    from . import cctv_alerts as CA
    now = now or timezone.now()
    st = dict(link.state or {})
    seen = list(st.get("seen") or [])
    if ev.get("id") and ev["id"] in seen:
        return "duplicate"
    if ev.get("id"):
        st["seen"] = (seen + [ev["id"]])[-SEEN_KEEP:]
    link.state = st
    link.save(update_fields=["state"])
    cam = ShopCamera.objects.filter(site=link.site, enabled=True,
                                    vendor_ref=vendor_ref(link.provider, ev["serial"],
                                                          ev["channel"])).first()
    if cam is None:
        return "unknown_camera"
    ShopCamera.objects.filter(pk=cam.pk).update(last_seen=now)
    a = CC.ADAPTERS[link.provider]
    snap, raw = None, None
    if ev.get("picture") and link.site.snapshot_retention_days > 0:
        raw = (fetch or _fetch_picture)(ev["picture"], a.pic_hosts)
        if raw and not SV.looks_like_video(raw):
            snap = SV._small_jpeg(raw, "%s%d.jpg" % (link.provider, cam.id))
    sig = {"vendor": link.provider, "alarm_type": ev.get("vendor_type") or "",
           "human": ev.get("object") == "person" or ev.get("kind") == "person",
           "source": "cloud"}
    if ev.get("kind"):
        sig["kind"] = ev["kind"]
    if ev.get("object"):
        sig["object"] = ev["object"]
    etype, sig = SV.vendor_alarm_event(cam, raw if snap is not None else None, sig, now)
    etype = CA.vendor_type(etype, {"kind": ev.get("kind")})
    decision, row = SV._ingest_event(link.site, cam, {"type": etype, "at": ev["at"],
                                                      "signals": sig}, now, snap)
    if row is not None:
        return "raised"
    return "grouped" if decision.get("grouped") else "muted"


def _note_error(link, e):
    link.last_error = ("%s %s" % (e.code, e.msg))[:80]
    if e.hint == "reauth":
        link.status = "error"
    link.save(update_fields=["last_error", "status"])


def sync_link(link, now=None, account_events=None):
    """One sync pass for a link: events (device-scope vendors whose events do
    NOT already flow through the older Imou callback / EZVIZ poll) and,
    every CLOUD_HEALTH_EVERY_S, the cloud health of each device."""
    now = now or timezone.now()
    out = {"events": 0, "health": 0}
    if not CC.enabled(link.provider):
        return out
    a = CC.adapter(link.provider)
    try:
        g = _fresh(link, a)
    except CC.ConnectError as e:
        _note_error(link, e)
        return out
    st = dict(link.state or {})
    # 2 min of slack (vendor clocks / whole-second times); repeats are
    # dropped by the seen-id list, never alerted twice
    since = max(float(st.get("since") or 0), now.timestamp() - EVENT_LOOKBACK_S) - 120
    evs = []
    try:
        if account_events is not None:
            evs = [e for e in account_events if a.owns(g, e["serial"])]
        elif a.events_scope == "device" and link.provider in ("dolynk",):
            for s in g.get("serials") or []:
                evs.extend(a.events(g, s, since, channels=_channels_of(link, s)))
    except CC.ConnectError as e:
        _note_error(link, e)
    for e in sorted(evs, key=lambda x: x["at"]):
        if ingest_cloud_event(link, e, now) == "raised":
            out["events"] += 1
    link.refresh_from_db(fields=["state"])
    st = dict(link.state or {})
    st["since"] = now.timestamp()
    if now.timestamp() - float(st.get("health_at") or 0) >= CLOUD_HEALTH_EVERY_S:
        st["health_at"] = now.timestamp()
        for s in g.get("serials") or []:
            try:
                rep = a.health(g, s)
            except CC.ConnectError:
                continue
            store_report(link.site, rep, now)
            out["health"] += 1
    link.state = st
    link.last_sync = now
    link.save(update_fields=["state", "last_sync"])
    return out


def _channels_of(link, serial):
    out = []
    pre = vendor_ref(link.provider, serial, "")
    for ref in link.site.cameras.filter(vendor_ref__startswith=pre).values_list(
            "vendor_ref", flat=True):
        out.append(ref[len(pre):])
    return out or ["0"]


def sync_all(now=None):
    """Cron entry (management command cctv_connect_sync, every minute)."""
    from .models import CctvCloudLink
    now = now or timezone.now()
    tot = {"links": 0, "events": 0, "health": 0}
    by_pid = {}
    for l in CctvCloudLink.objects.filter(status="active").select_related("site"):
        by_pid.setdefault(l.provider, []).append(l)
    for pid, links in by_pid.items():
        if not CC.enabled(pid):
            continue
        a = CC.adapter(pid)
        acct = None
        if a.events_scope == "account":
            try:
                acct = a.account_events(now.timestamp() - EVENT_LOOKBACK_S)
            except CC.ConnectError:
                acct = []
        for l in links:
            r = sync_link(l, now, account_events=acct)
            tot["links"] += 1
            tot["events"] += r["events"]
            tot["health"] += r["health"]
    return tot


# ===================================================================== B
def _cam_for_channel(site, report, channel):
    """The camera a health problem belongs to: a cloud camera by serial +
    channel, a LAN camera by host + channel, else the site's first camera."""
    cams = list(site.cameras.filter(enabled=True))
    dev = str(report.get("device") or "")
    for c in cams:
        src = c.source or {}
        same = (str(src.get("device_serial") or "") == dev or str(src.get("host") or "") == dev)
        if same and channel is not None and str(src.get("channel", "")) == str(channel):
            return c
    for c in cams:
        src = c.source or {}
        if str(src.get("device_serial") or "") == dev or str(src.get("host") or "") == dev:
            return c
    return cams[0] if cams else None


def _target_days(site):
    from .models import CctvDvrHealth
    row = CctvDvrHealth.objects.filter(site=site, device="_daily").first()
    try:
        return max(1, min(90, int(((row.report or {}).get("target_days")) or DH.DEFAULT_TARGET_DAYS)))
    except (AttributeError, TypeError, ValueError):
        return DH.DEFAULT_TARGET_DAYS


def store_report(site, raw, now=None, alert=True):
    """Save + evaluate one device report; raise ONE camera_health alert per
    NEW red problem (the existing 6-hour re-fire guard applies). Returns the
    evaluation."""
    from .models import CctvDvrHealth
    from . import cctv_alerts as CA
    now = now or timezone.now()
    rep = DH.normalize_report(raw, now.timestamp())
    dev = rep["device"] or "device"
    ev = DH.evaluate(rep, now.timestamp(), _target_days(site))
    row, _ = CctvDvrHealth.objects.get_or_create(site=site, device=dev[:60])
    prev = {(p["kind"], p.get("channel")) for p in (row.evaluation or {}).get("problems") or []}
    row.source, row.report, row.evaluation, row.updated = rep["source"], rep, ev, now
    row.save(update_fields=["source", "report", "evaluation", "updated"])
    if not alert:
        return ev
    for p in ev["problems"]:
        if p["kind"] not in DH.RED or (p["kind"], p.get("channel")) in prev:
            continue
        cam = _cam_for_channel(site, rep, p.get("channel"))
        if cam is None:
            continue
        try:
            CA.ingest_health(cam, p["kind"], now, "dvr_" + (rep["source"] or "box"),
                             extra={"channel": p.get("channel"), "detail": p.get("detail")})
        except Exception:
            log.exception("dvr health alert failed")
    return ev


class GatewayHealthView(APIView):
    """POST shop/gateway/dvr-health (SITE token) {reports: [report, ...]} —
    the Guard Box posts what it read from the DVR over the LAN (ISAPI /
    Dahua API). No video, no passwords (refused if a key looks like one)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        site = WMV._gateway_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        reps = request.data.get("reports")
        if not isinstance(reps, list) or not reps:
            return _err(lang, "রিপোর্ট নেই।", "No reports.", status=422, code="no_reports")
        now = timezone.now()
        SV._touch_seen(site, None, now)
        out = []
        for r in reps[:8]:
            if isinstance(r, dict) and any(k in r for k in ("password", "secret", "pass")):
                return _err(lang, "পাসওয়ার্ড পাঠানো যাবে না।", "Passwords are never sent.",
                            status=422, code="secret_refused")
            ev = store_report(site, dict(r, source=str(r.get("source") or "box")[:16]), now)
            out.append({"problems": len(ev["problems"]), "recorded_days": ev["recorded_days"]})
        return Response({"ok": True, "results": out})


def site_card(site, lang, now=None):
    """The daily green-check card (also shown live on the CCTV screen)."""
    from .models import CctvDvrHealth
    now = now or timezone.now()
    rows = list(CctvDvrHealth.objects.filter(site=site).exclude(device="_daily"))
    fresh = [r for r in rows if r.updated >= now - timedelta(hours=26)]
    evals = [r.evaluation for r in fresh if r.evaluation]
    extra = []
    try:
        from . import cctv_alerts as CA
        for cam in site.cameras.filter(enabled=True):
            fired = CA.load_state(cam).get("health_fired") or {}
            for k in ("covered", "moved", "dark"):
                if now.timestamp() - float(fired.get(k) or 0) < 24 * 3600:
                    extra.append({"kind": k, "channel": None, "cam": cam.name})
    except Exception:
        pass
    target = _target_days(site)
    c = DH.card(evals, extra, now.timestamp(), lang, target)
    c["devices"] = [{"device": r.device, "source": r.source, "updated": SV._iso(r.updated),
                     "stale": r.updated < now - timedelta(hours=26),
                     "recorded_days": (r.evaluation or {}).get("recorded_days"),
                     "problems": len((r.evaluation or {}).get("problems") or [])} for r in rows]
    c["target_days"] = target
    return c


class SiteHealthView(APIView):
    """GET cctv/health/sites/<id> — the card (owner + viewers);
    PUT {target_days} — owner only."""

    def get(self, request, pk):
        lang = req_lang(request)
        if not WMV.feature_on(request):
            return _err(lang, "এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet.",
                        status=403, code="feature_off")
        site, _role = SV._viewable_site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(site_card(site, lang))

    def put(self, request, pk):
        from .models import CctvDvrHealth
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        try:
            days = max(1, min(90, int(request.data.get("target_days"))))
        except (TypeError, ValueError):
            return _err(lang, "১ থেকে ৯০ দিনের মধ্যে দিন।", "Give 1 to 90 days.", status=422)
        row, _ = CctvDvrHealth.objects.get_or_create(site=site, device="_daily")
        row.report = dict(row.report or {}, target_days=days)
        row.save(update_fields=["report"])
        for r in CctvDvrHealth.objects.filter(site=site).exclude(device="_daily"):
            r.evaluation = DH.evaluate(r.report or {}, r.updated.timestamp(), days)
            r.save(update_fields=["evaluation"])
        return Response(site_card(site, lang))

    post = put        # the app's client has no PUT helper


def daily_checks(now=None, push=None):
    """Cron (cctv_health_daily, hourly): at DAILY_HOUR Dhaka time each site
    that has health data gets ONE card push a day — green = a calm "all
    good", red / amber = what is wrong. Returns sites pushed."""
    from .models import CctvDvrHealth, ShopSite
    from .logic import watchman as WM  # noqa: F401  (keeps import order stable)
    now = now or timezone.now()
    local = timezone.localtime(now)
    if local.hour < DAILY_HOUR:
        return 0
    day = local.date().isoformat()
    n = 0
    site_ids = set(CctvDvrHealth.objects.exclude(device="_daily").values_list("site_id", flat=True))
    for site in ShopSite.objects.filter(pk__in=site_ids).select_related("owner"):
        row, _ = CctvDvrHealth.objects.get_or_create(site=site, device="_daily")
        if (row.alerted or {}).get("day") == day:
            continue
        row.alerted = {"day": day}
        row.save(update_fields=["alerted"])
        users = [site.owner]
        try:
            from . import cctv_team_views as CTV
            users += CTV.viewer_users(site)
        except Exception:
            pass
        for u in users:
            lang = "bn" if (getattr(u, "language", "bn") or "bn") != "en" else "en"
            c = site_card(site, lang, now)
            if c["status"] == "unknown":
                continue
            tb = "আজকের CCTV পরীক্ষা: %s" % site.name if c["status"] != "green" else \
                "CCTV আজ ঠিক আছে: %s" % site.name
            te = ("Today's CCTV check: %s" % site.name if c["status"] != "green"
                  else "CCTV all good today: %s" % site.name)
            cb = site_card(site, "bn", now)["title"]
            ce = site_card(site, "en", now)["title"]
            try:
                (push or _push)(u, tb, te, cb, ce, {"site_id": site.id, "route": "cctv_health",
                                                    "status": c["status"]})
            except Exception:
                pass
        n += 1
    return n


def _push(u, tb, te, bb, be, data):
    from . import push
    push.safe_push(u, "shop_alert", tb, te, bb, be, data=data)
