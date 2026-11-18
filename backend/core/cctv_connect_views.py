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

OAUTH_MAX_AGE_S = 15 * 60
SEEN_KEEP = 200
EVENT_LOOKBACK_S = 10 * 60
CLOUD_HEALTH_EVERY_S = 3 * 3600
LINKS_PER_SITE = 12
SERIALS_PER_LINK = 16
DAILY_HOUR = 9                     # Dhaka time, the daily green check
REF_PREFIX = {"hikconnect": "HC:", "dolynk": "DL:", "dolynk_arc": "DA:", "ezviz": "EZ:", "imou": ""}


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
    days_left = None
    if l.mode == "oauth" and l.status != "revoked":
        until = float(_grant(l).get("auth_until") or 0)
        days_left = max(0, int((until - time.time()) // 86400)) if until else None
    return {"auth_days_left": days_left,"id": l.id, "provider": l.provider, "name": a.name if a else l.provider,
            "label": l.label, "mode": l.mode, "status": l.status,
            "serials": list(l.serials or []), "devices": len(l.serials or []),
            "last_sync": SV._iso(l.last_sync), "last_error": l.last_error,
            "created": SV._iso(l.created)}


# imou-real (owner 17 Nov): what the customer must do in the vendor's own
# app BEFORE typing the serial + code (a camera sits in ONE cloud account).
# The app shows a picture guide for these ids; none for a share / login path.
REMOVE_FIRST = {"imou": "imou_life", "ezviz": "ezviz_app", "dolynk": "dmss"}


def _switch_on(pid, key):
    a = CC.ADAPTERS.get(pid)
    try:
        from . import integrations as I
        v = str((I.get(a.integration) if a else {}).get(key) or "").strip().lower()
    except Exception:  # noqa: BLE001
        v = ""
    return v in ("on", "1", "yes", "true")


def provider_row(pid, user=None):
    a = CC.adapter(pid)
    modes = [m for m in a.modes() if m != "device_code" or devbind_allowed(user, pid)]
    # the no-delete path (vendor login / DMSS share) leads only when the owner
    # flips the vendor's switch after approval AND that path really exists
    no_delete = bool(modes) and ("oauth" in modes or pid == "dolynk_arc")
    return {"id": pid, "name": a.name, "modes": modes,
            "before": REMOVE_FIRST.get(pid, ""), "no_delete": no_delete,
            "lead": no_delete and _switch_on(pid, "no_delete_default"),
            "consent_bn": CONSENT_TEXT[0], "consent_en": CONSENT_TEXT[1],
            "code_label_bn": a.code_label[0], "code_label_en": a.code_label[1],
            "code_secret": bool(getattr(a, "code_secret", False)),
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
        rows = [provider_row(p, request.user) for p in CC.enabled_ids()]
        # imou-real: an approved no-delete path (switched on) comes first
        rows.sort(key=lambda r: not r.get("lead"))
        return Response({"providers": [r for r in rows if r["modes"]],
                         "links": [link_row(l) for l in links],
                         "local_ok": True})


class BindRefused(Exception):
    def __init__(self, status, code, bn, en, **extra):
        super().__init__(code)
        self.status, self.code, self.bn, self.en, self.extra = status, code, bn, en, extra

    def response(self, lang):
        return _err(lang, self.bn, self.en, status=self.status, code=self.code, **self.extra)


# The words the owner of the camera agrees to, on screen, before a device is
# bound to OUR developer account (owner order 9 Nov 17:20). Versioned: the
# version is stored with the link.
CONSENT_VERSION = "devbind-1"
CONSENT_TEXT = ("আমি এই ক্যামেরার মালিক এবং এটি Assisto-র অ্যাকাউন্টে যুক্ত করতে রাজি; যেকোনো সময় সরাতে পারব।",
                "I own this camera and agree to link it to Assisto's account; I can unlink it any time.")


def devbind_allowed(user, pid):
    """Binding a camera to OUR developer account is for the owner / admin
    accounts (owner test devices) unless the owner switches it on for
    customers in Owner Admin (integration field devbind_customers = on)."""
    if getattr(user, "is_superuser", False) or getattr(user, "is_staff", False):
        return True
    a = CC.ADAPTERS.get(pid)
    try:
        from . import integrations as I
        v = str((I.get(a.integration) if a else {}).get("devbind_customers") or "").strip().lower()
    except Exception:
        v = ""
    return v in ("on", "1", "yes", "true")


def devbind(user, site, pid, serial, code, consent, category=None):
    """Bind ONE device to our developer account with its label code (used
    once, never stored) after the camera owner's on-screen consent.
    -> (link, devices). Raises BindRefused."""
    from .models import CctvCloudLink
    if pid not in CC.ADAPTERS or not CC.enabled(pid):
        raise BindRefused(503, "not_configured", *CC.base.HINT_TEXT["not_configured"])
    if not devbind_allowed(user, pid):
        raise BindRefused(403, "devbind_owner_only",
                          "এভাবে যুক্ত করা এখন শুধু Assisto-র মালিকের পরীক্ষার ক্যামেরার জন্য। "
                          "আপনার নিজের অ্যাকাউন্ট দিয়ে যুক্ত করার সুবিধা শীঘ্রই আসছে — ততক্ষণ একই Wi-Fi দিয়ে যুক্ত করুন।",
                          "This way of linking is only for Assisto's owner test cameras for now. "
                          "Linking with your own account is coming soon — meanwhile add the camera on the same Wi-Fi.")
    if not SV._coerce_bool(consent):
        raise BindRefused(422, "consent_required", "আগে সম্মতির ঘরে টিক দিন: " + CONSENT_TEXT[0],
                          "Please tick the consent first: " + CONSENT_TEXT[1])
    serial = CC.base.clean_serial(serial)
    code = CC.ADAPTERS[pid].clean_code(code)     # dolynkreal: a device password may hold symbols
    if not serial:
        raise BindRefused(422, "serial_required",
                          "ক্যামেরা / DVR-এর লেবেলের সিরিয়াল নম্বর (SN) দিন।",
                          "Enter the serial number (SN) from the camera / DVR label.")
    if not code:
        raise BindRefused(422, "code_required", "লেবেলের কোডটি দিন (অক্ষর ও সংখ্যা)।",
                          "Enter the code from the label (letters and digits).")
    if serial_taken(pid, serial, except_site=site.id):
        raise BindRefused(409, "taken", *CC.base.HINT_TEXT["taken"])
    if not link_attempt_ok(user.pk):
        raise BindRefused(429, "rate_limited",
                          "এক ঘণ্টায় অনেকবার চেষ্টা হয়েছে — একটু পরে আবার চেষ্টা করুন।",
                          "Too many tries this hour — please try again a little later.")
    a = CC.adapter(pid)
    try:
        if pid == "dolynk" and category:
            g = a.link_device(serial, code, category=str(category)[:8])
        else:
            g = a.link_device(serial, code)
    except CC.ConnectError as e:
        bn, en = CC.base.HINT_TEXT.get(e.hint, CC.base.HINT_TEXT["vendor"])
        raise BindRefused(422 if e.hint in ("wrong_code", "taken", "locked", "unsupported") else 502,
                          "vendor_" + e.hint, bn, en, vendor_code=e.code)
    owner_test = bool(getattr(user, "is_superuser", False) or getattr(user, "is_staff", False))
    with transaction.atomic():
        link = CctvCloudLink.objects.select_for_update().filter(
            site=site, provider=pid, mode="device_code",
            status__in=("active", "error")).first()
        if link is None:
            if CctvCloudLink.objects.filter(site=site).exclude(
                    status="revoked").count() >= LINKS_PER_SITE:
                raise BindRefused(409, "too_many_links", "এই জায়গায় আর সংযোগ যোগ করা যাবে না।",
                                  "No more links can be added to this place.")
            link = CctvCloudLink(site=site, provider=pid, mode="device_code",
                                 label=a.name, state={"since": time.time()})
            link.save()
            grant = {"mode": "device_code", "serials": []}
        else:
            grant = _grant(link) or {"mode": "device_code", "serials": []}
        serials = [x for x in grant.get("serials") or [] if x != serial] + [serial]
        if len(serials) > SERIALS_PER_LINK:
            raise BindRefused(409, "too_many_devices", "একটি সংযোগে সর্বোচ্চ ১৬টি ডিভাইস।",
                              "Up to 16 devices per link.")
        grant["serials"] = serials
        st = dict(link.state or {})
        cons = dict(st.get("consent") or {})
        cons[serial] = {"by": user.pk, "at": time.time(), "v": CONSENT_VERSION}
        st["consent"] = cons
        if owner_test:
            st["owner_test"] = sorted(set(st.get("owner_test") or []) | {serial})
        link.state = st
        link.grant_blob = CC.seal(site.id, grant)
        link.serials = serials
        link.status, link.last_error = "active", ""
        link.save(update_fields=["grant_blob", "serials", "status", "last_error", "state"])
    _after_link(a, grant)
    devices = []
    try:
        devices = [d for d in a.devices({"serials": [serial]})]
    except CC.ConnectError:
        pass
    return link, devices


class LinkDeviceView(WMV._OwnerBase):
    """POST cctv/connect/<pid>/link {site, serial, code, consent} — bind ONE
    device to our developer account with its label code (used once, never
    stored), only after the camera owner's on-screen consent. A second
    device of the same brand joins the same link."""

    def post(self, request, pid):
        lang = req_lang(request)
        site = SV._owner_site(request, request.data.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        try:
            link, devices = devbind(request.user, site, pid, request.data.get("serial"),
                                    request.data.get("code"), request.data.get("consent"),
                                    category=request.data.get("category"))
        except BindRefused as e:
            return e.response(lang)
        return Response({"link": link_row(link), "devices": devices}, status=201)


class OAuthStartView(WMV._OwnerBase):
    """POST cctv/connect/<pid>/oauth/start {site} -> {"url"} — the app opens
    this URL in the browser: our /oauth/go sets a short secure cookie, then
    sends the user to the vendor's own consent page (Imou: the "User
    Authorization H5 Page" from its console). Only when the owner saved the
    vendor's OAuth project keys."""

    def post(self, request, pid):
        lang = req_lang(request)
        site = SV._owner_site(request, request.data.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        a = CC.adapter(pid) if CC.enabled(pid) else None
        if a is None or "oauth" not in a.modes():
            return _err(lang, *CC.base.HINT_TEXT["not_configured"], status=503,
                        code="not_configured")
        if not link_attempt_ok(request.user.pk):
            return _err(lang, "এক ঘণ্টায় অনেকবার চেষ্টা হয়েছে — একটু পরে আবার চেষ্টা করুন।",
                        "Too many tries this hour — please try again a little later.",
                        status=429, code="rate_limited")
        state = new_oauth_state(site, request.user, pid)
        return Response({"url": "%s/api/v1/cctv/connect/oauth/go?state=%s" % (_base_url(request), state),
                         "state": state, "expires_s": OAUTH_MAX_AGE_S})


def _base_url(request):
    from django.conf import settings
    from .public_url import public_base_url
    base = public_base_url() or request.build_absolute_uri("/")[:-1]
    return base.rstrip("/")


def _redirect_uri(request, a=None):
    """Exactly the URL configured in the vendor console."""
    path = getattr(a, "oauth_redirect_path", "") or "/api/v1/cctv/connect/oauth/callback"
    return _base_url(request) + path


OAUTH_COOKIE = "ccn_oauth_state"


def new_oauth_state(site, user, pid):
    """An unguessable one-time state held SERVER-side (cache, 15 min) ->
    {site, user, provider}. URL-safe (letters, digits, - and _ only)."""
    import secrets
    from django.core.cache import cache
    state = secrets.token_urlsafe(24)
    cache.set("ccn_oauth_state:" + state, {"s": site.id, "u": user.pk, "p": pid}, OAUTH_MAX_AGE_S)
    return state


def take_oauth_state(state):
    """The pending authorization for this state, used ONCE, else None."""
    from django.core.cache import cache
    st = str(state or "")[:128]
    if not st or not st.replace("-", "").replace("_", "").isalnum():
        return None
    key = "ccn_oauth_state:" + st
    pend = cache.get(key)
    if pend:
        cache.delete(key)
    return pend if isinstance(pend, dict) else None


def has_oauth_state(state):
    from django.core.cache import cache
    st = str(state or "")[:128]
    return bool(st) and st.replace("-", "").replace("_", "").isalnum() and \
        cache.get("ccn_oauth_state:" + st) is not None


class OAuthGoView(APIView):
    """GET cctv/connect/oauth/go?state= — set the state cookie (in case the
    vendor does not hand `state` back), then 302 to the vendor consent page."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from django.core.cache import cache
        from django.http import HttpResponseRedirect
        state = str(request.query_params.get("state") or "")[:128]
        pend = cache.get("ccn_oauth_state:" + state) if state.replace("-", "").replace(
            "_", "").isalnum() else None
        a = CC.adapter(pend.get("p")) if isinstance(pend, dict) and CC.enabled(pend.get("p")) else None
        if a is None:
            return oauth_page(False)
        try:
            url = a.oauth_url(state, _redirect_uri(request, a))
        except CC.ConnectError:
            return oauth_page(False)
        resp = HttpResponseRedirect(url)
        resp.set_cookie(OAUTH_COOKIE, state, max_age=OAUTH_MAX_AGE_S, secure=request.is_secure(),
                        httponly=True, samesite="Lax", path="/api/v1/cctv/")
        resp["Cache-Control"] = "no-store"
        return resp


def finish_oauth(request, code, state=None):
    """The vendor sent the user back with `code`: exchange it server-side,
    seal the tokens for that ONE site, read the device list. -> (ok, link)."""
    from .models import CctvCloudLink, ShopSite
    pend = take_oauth_state(state) or take_oauth_state(request.COOKIES.get(OAUTH_COOKIE))
    if not pend or not code:
        return False, None
    site = ShopSite.objects.filter(pk=pend.get("s"), owner_id=pend.get("u")).first()
    a = CC.adapter(pend.get("p")) if CC.enabled(pend.get("p")) else None
    if site is None or a is None:
        return False, None
    try:
        g = a.oauth_finish(str(code)[:512], _redirect_uri(request, a))
    except CC.ConnectError as e:
        log.info("oauth finish failed: %s %s", a.id, e.code)
        return False, None
    link = CctvCloudLink.objects.create(site=site, provider=a.id, mode="oauth",
                                        label=a.name, state={"since": time.time()})
    try:
        devs = a.devices(g)
        g["serials"] = [d["serial"] for d in devs][:CC.base.MAX_DEVICES]
    except CC.ConnectError:
        devs = []
    link.grant_blob = CC.seal(site.id, g)
    link.serials = list(g.get("serials") or [])
    link.save(update_fields=["grant_blob", "serials"])
    _after_link(a, g)
    return True, link


def _after_link(a, g):
    """Imou: ask for PUSHED alarms + device status + people counting.
    DoLynk: Message Subscription for the linked devices (dolynkreal)."""
    try:
        if a.id == "imou":
            cb = WMV.imou_callback_url(a.cfg.get("app_id"))
        elif a.id in ("dolynk", "dolynk_arc"):
            cb = dolynk_callback_url(a.cfg.get("access_key"), arc=a.id == "dolynk_arc") or None
        else:
            cb = None
        a.after_link(g, cb)
    except Exception:
        log.info("after_link failed for %s", a.id)


class OAuthCallbackView(APIView):
    """GET cctv/connect/oauth/callback?code&state — the generic redirect URI
    (Imou uses its own fixed path, watchman_views.ImouOAuthCallbackView,
    which calls the same finish_oauth)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        ok, _link = finish_oauth(request, request.query_params.get("code"),
                                 request.query_params.get("state"))
        return oauth_page(ok)


def oauth_page(ok):
    msg = ("সংযোগ সম্পূর্ণ — এখন Assisto অ্যাপে ফিরে যান, ক্যামেরা তালিকা নিজে আসবে।<br>"
           "Connected — go back to the Assisto app; your cameras will appear there."
           if ok else "সংযোগ হয়নি — Assisto অ্যাপে ফিরে আবার চেষ্টা করুন।<br>"
                      "Not connected — go back to Assisto and try again.")
    resp = HttpResponse("<!doctype html><meta charset=utf-8><meta name=viewport "
                        "content='width=device-width,initial-scale=1'><meta name=robots content=noindex>"
                        "<title>Assisto</title><p style='font:18px sans-serif;padding:24px'>%s</p>" % msg,
                        status=200 if ok else 400)
    resp["Cache-Control"] = "no-store"
    resp.delete_cookie(OAUTH_COOKIE, path="/api/v1/cctv/")
    return resp


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
            g = _fresh(link, a)
            devs = a.devices(g)
        except CC.ConnectError as e:
            _note_error(link, e)
            return _cerr(lang, e)
        if link.mode == "oauth":
            # the user may have added / removed cameras in his own app since
            g["serials"] = [d["serial"] for d in devs][:CC.base.MAX_DEVICES]
            link.grant_blob = CC.seal(link.site_id, g)
            link.serials = list(g["serials"])
            link.save(update_fields=["grant_blob", "serials"])
        have = set(link.site.cameras.exclude(vendor_ref="").values_list("vendor_ref", flat=True))
        for d in devs:
            for c in d["channels"]:
                c["added"] = vendor_ref(link.provider, d["serial"], c["no"]) in have
        return Response({"link": link_row(link), "devices": devs})


def import_items(link, user, items, lang="bn"):
    """The chosen channels become cameras of the link's site, within the
    cameras the owner's plan includes (never silently charged). -> (added
    rows, skipped [{serial, channel, why}], message)."""
    from .models import ShopCamera
    from .logic import watchman as WM
    allowed_serials = set(link.serials or [])
    free = max(0, SV._included_cameras(user) - SV.owner_enabled_cameras(user).count())
    added, skipped = [], []
    # cctvprice (owner 17 Nov 12:35): EZVIZ is not in the free trial
    from . import cctv_plan_service as CPS
    no_trial = CPS.trial_refuses_vendor(user, CC.CAMERA_VENDOR.get(link.provider, ""))
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
        if no_trial:
            skipped.append({"serial": serial, "channel": ch, "why": "trial_no_ezviz"})
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
                                    "cloud": link.provider}),
            # owner 9 Nov 17:20: bound to OUR developer account for the
            # owner's own test -> a visible "owner test device" badge
            compat={"owner_test": True} if serial in ((link.state or {}).get("owner_test") or [])
            else {})
        free -= 1
        added.append(SV._camera_row(cam))
    msg = ""
    if any(x["why"] == "trial_no_ezviz" for x in skipped):
        msg = pick(lang, CPS.TRIAL_NO_EZVIZ_BN, CPS.TRIAL_NO_EZVIZ_EN)
    elif any(x["why"] == "plan_full" for x in skipped):
        msg = pick(lang, "প্ল্যানের সব ক্যামেরা ব্যবহার হয়েছে — বাকিগুলো যোগ করতে প্ল্যানে ক্যামেরার সংখ্যা বাড়ান।",
                   "All cameras in your plan are used — raise the camera count in your plan to add the rest.")
    return added, skipped, msg


class LinkImportView(WMV._OwnerBase):
    """POST cctv/connect/links/<id>/import {items: [{serial, channel, name?}]}."""

    def post(self, request, pk):
        lang = req_lang(request)
        link = _link_for(request, pk)
        if link is None or link.status == "revoked":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        items = request.data.get("items") or []
        if not isinstance(items, list) or not items:
            return _err(lang, "কোন ক্যামেরা যোগ করবেন বেছে নিন।", "Choose the cameras to add.",
                        status=422, code="items_required")
        added, skipped, msg = import_items(link, request.user, items, lang)
        return Response({"added": added, "skipped": skipped, "message": msg},
                        status=201 if added else 200)


def revoke_link(link):
    """Release the devices at the vendor (best effort: Imou unBindDevice for
    developer-account binds), wipe the grant, unlink the imported cameras'
    cloud reference (cameras and old alerts stay). -> cameras unlinked."""
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
    return n


class LinkRevokeView(WMV._OwnerBase):
    """DELETE cctv/connect/links/<id> — revoke (see revoke_link)."""

    def delete(self, request, pk):
        lang = req_lang(request)
        link = _link_for(request, pk)
        if link is None or link.status == "revoked":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response({"ok": True, "cameras_unlinked": revoke_link(link)})


# ---------------------------------------------------------------- streams
def link_of_camera(cam):
    pid, serial, ch = parse_ref(cam)
    if pid is None:
        return None, None, None
    rows = links_with(pid, serial, ("active",), site=cam.site)
    return (rows[0] if rows else None), serial, ch


STREAM_KINDS = ("live", "playback", "clip", "snapshot", "cloud")


def stream_for(cam, kind="live", hd=False, start=None, end=None, task=None):
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
    if kind in ("playback", "clip"):
        now = time.time()
        end = min(float(end or now), now)
        start = max(float(start or end - 60), end - 3600)
        if kind == "clip":
            # dolynkreal: an MP4 of the recording (DoLynk cloud dump); the
            # app asks again with the returned task until it is ready
            if not hasattr(a, "clip"):
                raise CC.ConnectError("unsupported")
            return a.clip(g, serial, ch, start, end, task=str(task or "")[:40] or None)
        return a.playback(g, serial, ch, start, end)
    if kind in ("snapshot", "cloud"):
        if not hasattr(a, kind):
            raise CC.ConnectError("unsupported")
        return getattr(a, kind)(g, serial, ch)
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
        kind = request.data.get("kind")
        kind = kind if kind in STREAM_KINDS else "live"
        try:
            out = stream_for(cam, kind, SV._coerce_bool(request.data.get("hd")),
                             request.data.get("start"), request.data.get("end"),
                             task=request.data.get("task"))
        except CC.ConnectError as e:
            return _cerr(lang, e, status=503 if e.hint == "not_configured" else 502)
        except (TypeError, ValueError):
            return _err(lang, "সময় ঠিক নেই।", "Bad time range.", status=422)
        if role != "owner":
            CTV.log_access(cam.site, kind if kind == "live" else "live", user=request.user,
                           camera_id=cam.id)
        if cam.vendor == "imou" and out.get("proto") in ("hls", "rtsp"):
            # ESTIMATE for the free 2 GB: one address = up to 5 min of the
            # sub-stream (~512 kbit/s) ~ 19 MB; HD counts 4x
            from .logic.cctv_connect import quota as Q
            Q.bump("imou", mb=19.0 * (4 if SV._coerce_bool(request.data.get("hd")) else 1))
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
        pic = ev["picture"]
        if hasattr(a, "picture_url"):           # dolynkreal: encrypted .dav thumbnails
            try:
                pic = CC.adapter(link.provider).picture_url(pic, ev["serial"])
            except CC.ConnectError:
                pic = ""
        raw = (fetch or _fetch_picture)(pic, a.pic_hosts) if pic else None
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
        elif link.provider == "imou" and link.mode == "oauth" and imou_poll_due(link, now):
            # Imou docs do not promise that an end user's alarms are PUSHED to
            # our callback: poll as a fallback only while no push was seen in
            # 24 h, every 15 min (60 min from 80 % quota, never at 100 %)
            st0 = dict(link.state or {})
            st0["poll_at"] = now.timestamp()
            link.state = st0
            link.save(update_fields=["state"])
            for s in g.get("serials") or []:
                if link.site.cameras.filter(              # only imported cameras
                        vendor_ref__startswith=vendor_ref("imou", s, "")).exists():
                    evs.extend(a.events(g, s, since, channels=_channels_of(link, s)))
        elif link.provider == "dolynk" and dolynk_poll_due(link, now):
            # dolynkreal: alarms are PUSHED (signed); the message list is
            # polled only while no push arrived in 24 h
            st0 = dict(link.state or {})
            st0["poll_at"] = now.timestamp()
            link.state = st0
            link.save(update_fields=["state"])
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


DOLYNK_POLL_EVERY_S = 120


def dolynk_poll_due(link, now):
    from .logic.cctv_connect import quota as Q
    st = link.state or {}
    ts = now.timestamp()
    if ts - float(st.get("push_at") or 0) < 24 * 3600 or Q.stop("dolynk"):
        return False
    every = 900 if Q.saving("dolynk") else DOLYNK_POLL_EVERY_S
    return ts - float(st.get("poll_at") or 0) >= every


def dolynk_arc_poll_due(now):
    """Open ARC messages are pushed; poll the company list only while no
    push arrived in 24 h, every 2 min (15 min from 80 % quota)."""
    from django.core.cache import cache
    from .logic.cctv_connect import quota as Q
    ts = now.timestamp()
    try:
        if ts - float(cache.get("dolynk_arc_push_at") or 0) < 24 * 3600 or Q.stop("dolynk"):
            return False
        every = 900 if Q.saving("dolynk") else DOLYNK_POLL_EVERY_S
        if ts - float(cache.get("dolynk_arc_poll_at") or 0) < every:
            return False
        cache.set("dolynk_arc_poll_at", ts, 3600)
    except Exception:
        return False
    return True


def imou_poll_due(link, now):
    from .logic.cctv_connect import quota as Q
    st = link.state or {}
    ts = now.timestamp()
    if ts - float(st.get("push_at") or 0) < 24 * 3600:
        return False
    if Q.stop("imou"):
        return False
    every = 3600 if Q.saving("imou") else 900
    return ts - float(st.get("poll_at") or 0) >= every


def imou_messages_seen(msgs, now):
    """The Imou callback got these messages: count them (free quota) and
    mark the links of those devices as 'push works' (no polling needed)."""
    from .logic.cctv_connect import quota as Q
    from .models import CctvCloudLink
    Q.bump("imou", msg=len(msgs), now=now)
    serials = {str((m or {}).get("did") or (m or {}).get("deviceId") or "").strip().upper()
               for m in msgs if isinstance(m, dict)}
    serials.discard("")
    if not serials:
        return
    for l in CctvCloudLink.objects.filter(provider="imou", status="active"):
        if serials & set(l.serials or []):
            st = dict(l.state or {})
            st["push_at"] = now.timestamp()
            CctvCloudLink.objects.filter(pk=l.pk).update(state=st)


PEOPLE_TYPES = ("numberstat", "passengerflow", "peoplecount", "humancount", "flowstat")
PEOPLE_KEEP_DAYS = 14


def _num(m, *keys):
    for k in keys:
        v = m.get(k)
        try:
            if v not in (None, ""):
                return max(0, int(float(v)))
        except (TypeError, ValueError):
            continue
    return None


def imou_people_message(m, now):
    """An Imou people-counting (numberstat / passenger-flow) message -> the
    camera's daily in / out counters (no identity, no picture kept). Returns
    True when it WAS such a message (it must never become an alarm)."""
    from .models import ShopCamera
    if not isinstance(m, dict):
        return False
    mtype = str(m.get("msgType") or m.get("type") or "").replace("_", "").lower()
    if not any(t in mtype for t in PEOPLE_TYPES):
        return False
    did = str(m.get("did") or m.get("deviceId") or "").strip().upper()
    cid = str(m.get("cid") if m.get("cid") is not None else m.get("channelId", "0"))
    data = m.get("data") if isinstance(m.get("data"), dict) else m
    n_in = _num(data, "inNum", "enterNum", "in", "enter", "entered", "inCount")
    n_out = _num(data, "outNum", "leaveNum", "out", "leave", "exited", "outCount")
    n_all = _num(data, "num", "number", "count", "total", "people")
    cam = ShopCamera.objects.filter(vendor_ref="%s:%s" % (did, cid), enabled=True).first()
    if cam is None:
        return True
    day = timezone.localtime(now).date().isoformat()
    hour = "%02d" % timezone.localtime(now).hour
    compat = dict(cam.compat or {})
    ppl = dict(compat.get("people") or {})
    d = dict(ppl.get(day) or {"in": 0, "out": 0, "count": 0, "hours": {}})
    d["in"] += n_in or 0
    d["out"] += n_out or 0
    if n_all is not None and n_in is None and n_out is None:
        d["count"] += n_all
    hrs = dict(d.get("hours") or {})
    hrs[hour] = hrs.get(hour, 0) + (n_in or n_all or 0)
    d["hours"] = hrs
    ppl[day] = d
    for k in sorted(ppl)[:-PEOPLE_KEEP_DAYS]:
        ppl.pop(k, None)
    compat["people"] = ppl
    ShopCamera.objects.filter(pk=cam.pk).update(compat=compat, last_seen=now)
    return True


def people_counts(site, day=None):
    """THE feed for the daily report (cctvact): {"day", "cameras": [{id,
    name, in, out, count, hours}], "in", "out"} from Imou people counting.
    Counts only — no identity, no faces."""
    day = day or timezone.localtime(timezone.now()).date().isoformat()
    out = {"day": day, "cameras": [], "in": 0, "out": 0, "count": 0}
    for cam in site.cameras.filter(enabled=True):
        d = ((cam.compat or {}).get("people") or {}).get(day)
        if not d:
            continue
        out["cameras"].append({"id": cam.id, "name": cam.name, "in": d.get("in", 0),
                               "out": d.get("out", 0), "count": d.get("count", 0),
                               "hours": d.get("hours") or {}})
        for k in ("in", "out", "count"):
            out[k] += int(d.get(k) or 0)
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
        if pid == "dolynk_arc" and not dolynk_arc_poll_due(now):
            acct = []                    # pushes arrive: no polling
        elif a.events_scope == "account":
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


# ===================================================================== DoLynk
def dolynk_callback_token(app_id, arc=False, salt=None):
    """publicurl: sha256(key + SECRET_KEY + the rotatable salt) — see
    core/callback_links.py (salt None = the saved one)."""
    from . import callback_links as CL
    slug = "dolynk_arc" if arc else "dolynk"
    return CL.token(slug, app_id, CL.salt(slug) if salt is None else salt)


def dolynk_callback_url(app_id, arc=False):
    """The PUBLIC https link (publicurl: never the server's 127.0.0.1)."""
    if not app_id:
        return ""
    from .public_url import public_url
    from . import callback_links as CL
    return public_url(CL.PATHS["dolynk_arc" if arc else "dolynk"]
                      + dolynk_callback_token(app_id, arc))


DOLYNK_LOG_PER_HOUR = 30
DOLYNK_MAX_MSGS = 50


def _dolynk_log(raw, msgs, tag):
    """ONLY the top-level keys, message type and size (never values: they
    carry pictures, device ids, accounts), at most DOLYNK_LOG_PER_HOUR an hour."""
    from django.core.cache import cache
    key = "dolynk_cb_log:%d" % int(time.time() // 3600)
    try:
        n = cache.get_or_set(key, 0, 3700)
        if n < DOLYNK_LOG_PER_HOUR:
            cache.incr(key)
            first = msgs[0] if msgs and isinstance(msgs[0], dict) else {}
            log.info("dolynk %s callback: %d bytes, %d msg, keys=%s, type=%s", tag, len(raw),
                     len(msgs), sorted(list(first.keys()))[:20],
                     str(first.get("msgType") or "")[:40])
    except Exception:
        pass


def dolynk_message(pid, m, now, a):
    """One VERIFIED DoLynk message -> its result. Alerts go into the normal
    alert path; online / offline / storage messages make the next sync
    re-read the device health (the daily CCTV card); face events and
    unknown types are dropped (owner rule: no face recognition)."""
    from .logic.cctv_connect import dolynk as DL
    what, _k, _o = DL.classify(m.get("msgType"))
    if what is None:
        return {"ignored": "type"}
    serial = CC.base.clean_serial(m.get("deviceId"))
    links = links_with(pid, serial, ("active",)) if serial else []
    if not links:
        return {"ignored": "unknown_device"}
    link = links[0]
    st = dict(link.state or {})
    st["push_at"] = now.timestamp()
    if what in ("status", "storage"):
        st["health_at"] = 0                     # health is due at the next sync
        link.state = st
        link.save(update_fields=["state"])
        return {"result": "health_due"}
    link.state = st
    link.save(update_fields=["state"])
    ev = a.to_event(m)
    if ev is None:
        return {"ignored": "type"}
    return {"result": ingest_cloud_event(link, ev, now)}


def _dolynk_body(request):
    import json
    raw = request.body[:256 * 1024]
    try:
        body = json.loads(raw or b"{}")
    except ValueError:
        body = None
    msgs = body if isinstance(body, list) else [body]
    return raw, [m for m in msgs if isinstance(m, dict)][:DOLYNK_MAX_MSGS]


class DolynkCallbackView(APIView):
    """POST cctv/dolynk/callback/<token> — Open IoT Message Subscription
    pushes here (Doc Center "Message Subscription"). The secret token in the
    URL AND each message's own sign = HMAC-SHA512(id, secretKey) are checked;
    accessKey must be ours. Answer per the docs: 200 {"code": 200, "msg":
    "success"} (a 4xx / 5xx makes DoLynk push again)."""
    permission_classes = [AllowAny]
    authentication_classes = []
    parser_classes = []
    arc = False

    def _cfg(self):
        """publicurl: the saved keys even before the connector is ON (the
        self-test proves the link before the first camera); real messages
        still need CC.enabled (else they are ignored, never alerts)."""
        from . import integrations as I
        pid = "dolynk_arc" if self.arc else "dolynk"
        return pid, (I.get(CC.ADAPTERS[pid].integration) or {})

    def post(self, request, token):
        from . import callback_links as CL
        try:
            pid, cfg = self._cfg()
        except Exception:
            pid, cfg = "dolynk", {}
        ak = str(cfg.get("access_key") or "")
        if not ak or not CL.token_ok(pid, cfg, token):
            return Response({"ok": False}, status=404)
        try:
            on = CC.enabled(pid)
        except Exception:
            on = False
        raw, msgs = _dolynk_body(request)
        _dolynk_log(raw, msgs, "arc" if self.arc else "iot")
        from .logic.cctv_connect import dolynk as DL, quota as Q
        Q.bump("dolynk", msg=len(msgs))
        a = CC.adapter(pid, cfg=cfg)
        now = timezone.now()
        out = []
        for m in msgs:
            if str(m.get("accessKey") or "") != ak:
                out.append({"ignored": "not_ours"})
                continue
            if not self.arc and not DL.verify_push(m, cfg.get("secret_key")):
                out.append({"ignored": "bad_sign"})
                continue
            if CL.is_selftest(m):               # publicurl: proof, never an alert
                out.append(CL.selftest_answer(pid, m))
                continue
            if not on:
                out.append({"ignored": "off"})
                continue
            out.append(dolynk_message(pid, m, now, a))
            if self.arc and m.get("id") not in (None, ""):
                a.ack(m.get("id"))              # else DoLynk pushes it again
        if self.arc and msgs:
            from django.core.cache import cache
            cache.set("dolynk_arc_push_at", now.timestamp(), 2 * 86400)
        return Response({"code": 200, "msg": "success", "ok": True, "events": out})


class DolynkArcCallbackView(DolynkCallbackView):
    """POST cctv/dolynk/arc/<token> — Open ARC pushes (shared DMSS devices).
    ARC messages carry no sign field (Doc Center "Event Message"): the secret
    URL token, our accessKey and an ACTIVE claimed link for that serial are
    required; each message is acknowledged ("Send the Ack message")."""
    arc = True
