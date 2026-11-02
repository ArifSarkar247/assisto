"""
cctv_team_views.py — cctvteam (W11, CCTV audit F1 F3 F4 F5 + I trust).
Builds on ShopSite / ShopCamera / ShopSiteViewer (watchman_views.py) and the
My Circle communities (Community / CommunityGroup / CommunityMember).

ACCESS (the one server-side rule every CCTV endpoint uses):
  scope_for(site, user) -> (role, scope). role owner | family | manager |
  guard; scope None = every camera, else the allowed camera ids. Callers:
  shop/events (list), shop/events/<id>/* (detail, clip, evidence, share via
  cctvx_views.event_access), shop/live/start, shop/watchman, shop/grid,
  shop/cameras/<id>/still, guard report, push recipients. Staff / the
  Assisto owner have NO path here: only the site owner and people they
  added (or a share link they made) ever see a camera.

OWNER / VIEWER (Token auth, flags cctv_watchman + home_watchman)
  GET    shop/grid                          every site + camera I may see
  GET    shop/cameras/<id>/still            latest still (no vendor call)
  POST   shop/cameras/<id>/still            fresh still from Imou / EZVIZ
  PUT    shop/sites/<id>/viewers/<uid>/role {role, cameras, live_ok} (owner)
  GET    shop/sites/<id>/access-log         who viewed what (owner)
  GET/POST shop/sites/<id>/share-links      list / create (owner)
  POST   shop/share-links/<id>/revoke       (owner)
  GET    shop/watch/groups                  my PRIVATE community groups
  GET    shop/watch/posts?group=<id>        posts of one group (members)
  POST   shop/watch/posts                   share ONE chosen still
  DELETE shop/watch/posts/<id>              author / group admin
  POST   shop/watch/posts/<id>/report       report (3 reports hide it)
  POST   shop/watch/block  {user}           never see this person's posts
PUBLIC (web/views_cctv_share.py): lifeassisto.com/c/<token>[/data|/img/<cam>]
"""
import base64
import hashlib
import secrets
from datetime import timedelta

from django.db.models import OuterRef, Subquery
from django.utils import timezone
from rest_framework.exceptions import PermissionDenied
from rest_framework.response import Response

from .i18n import req_lang, pick
from . import shop_views as SV
from . import watchman_views as WMV
from .logic import cctv_team as CT

FLAG = "cctv_watchman"


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _nf(lang):
    return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)


ERRS = {
    "bad_role": ("ভূমিকা ঠিক নেই।", "Unknown role."),
    "bad_cameras": ("ক্যামেরার তালিকা ঠিক নেই।", "Invalid camera list."),
    "unknown_camera": ("এই জায়গায় এমন ক্যামেরা নেই।", "That camera is not at this place."),
    "guard_needs_camera": ("গার্ড কোন ক্যামেরা দেখবেন — অন্তত একটি বাছুন।",
                           "Choose at least one camera the guard may see."),
    "bad_hours": ("সময় ঠিক নেই।", "Invalid time."),
    "pick_camera": ("অন্তত একটি ক্যামেরা বাছুন।", "Choose at least one camera."),
}


def _team_err(lang, e):
    bn, en = ERRS.get(e.code, ("ঠিক নেই।", "Invalid."))
    return _err(lang, bn, en, status=422, code=e.code)


def team_on(request):
    try:
        from . import feature_flags as FF
        from .i18n import is_play_flavour
        return FF.is_on(FLAG, request.user, is_play_flavour(request))
    except Exception:
        return True


class _TeamBase(WMV._OwnerBase):
    """home_watchman (the watchman screens) AND cctv_watchman (the switch)."""

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not team_on(request):
            lang = req_lang(request)
            raise PermissionDenied(detail={
                "error": "feature_off",
                "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                               "This feature is not available yet.")})


# ===================================================================== access
def viewer_of(site, user):
    from .models import ShopSiteViewer
    if user is None or not getattr(user, "pk", None):
        return None
    return ShopSiteViewer.objects.filter(site=site, user_id=user.pk).first()


def scope_for(site, user):
    """(role, scope) — role 'owner' (scope None) | the viewer's role, or
    (None, None) when this user may not see the site at all."""
    if site is None or user is None or not getattr(user, "pk", None):
        return None, None
    if site.owner_id == user.pk:
        return "owner", None
    v = viewer_of(site, user)
    if v is None:
        return None, None
    role = v.role if v.role in CT.ROLES else "family"
    return role, CT.scope_of(role, v.cameras)


def site_access(request, pk):
    """(site, role, scope) for the owner or a viewer, else (None, None, None)."""
    s, _r = SV._viewable_site(request, pk)
    if s is None:
        return None, None, None
    role, scope = scope_for(s, request.user)
    if role is None:
        return None, None, None
    return s, role, scope


def camera_access(request, pk):
    """(camera, role, viewer_row_or_None) when this user may see the camera."""
    from .models import ShopCamera
    try:
        cam = ShopCamera.objects.select_related("site").get(pk=int(pk))
    except (ShopCamera.DoesNotExist, TypeError, ValueError):
        return None, None, None
    role, scope = scope_for(cam.site, request.user)
    if role is None or not CT.camera_allowed(scope, cam.id):
        return None, None, None
    return cam, role, (None if role == "owner" else viewer_of(cam.site, request.user))


def viewer_users(site, camera_id=None):
    """The viewers (Users) who may see `camera_id` (None = a site-level item:
    only unrestricted viewers). The push / notice hook for alert recipients."""
    out = []
    try:
        for v in site.viewers.select_related("user"):
            role = v.role if v.role in CT.ROLES else "family"
            if CT.camera_allowed(CT.scope_of(role, v.cameras), camera_id):
                out.append(v.user)
    except Exception:
        pass
    return out


def viewer_live_ok(cam, viewer):
    """May this (allowed) viewer open live view of `cam`? The owner's per-
    person switch, or the older per-phone-camera family switch."""
    if viewer is None:
        return False
    if viewer.live_ok:
        return True
    if cam.vendor == "phone":
        try:
            from . import phonecam_views as PCV
            return PCV.viewers_live(cam)
        except Exception:
            return False
    return False


def viewer_live_camera(user, cam_id):
    """shop/live/start hook for a non-owner: (camera, None) or (None|cam, code)
    with code 'not_found' | 'viewer_live_off'."""
    from .models import ShopCamera
    try:
        cam = ShopCamera.objects.select_related("site").get(pk=int(cam_id))
    except (ShopCamera.DoesNotExist, TypeError, ValueError):
        return None, "not_found"
    role, scope = scope_for(cam.site, user)
    if role is None or role == "owner" or not CT.camera_allowed(scope, cam.id):
        return None, "not_found"
    if not viewer_live_ok(cam, viewer_of(cam.site, user)):
        return cam, "viewer_live_off"
    log_access(cam.site, "live", user=user, camera_id=cam.id)
    return cam, None


def manager_event(user, pk):
    """shop/events/<id>/mark hook: the event when `user` is a MANAGER who may
    see its camera, else None."""
    from .models import ShopEvent
    try:
        e = ShopEvent.objects.select_related("site").get(pk=int(pk))
    except (ShopEvent.DoesNotExist, TypeError, ValueError):
        return None
    role, scope = scope_for(e.site, user)
    if CT.can_mark(role) and role != "owner" and CT.camera_allowed(scope, e.camera_id):
        return e
    return None


def log_access(site, action, user=None, camera_id=None, link=None, now=None):
    """One row in the owner's 'who viewed' list. The owner's own views are
    not logged; the same view within LOG_DEDUPE_S is logged once. Never
    raises."""
    from .models import CctvAccessLog
    try:
        if user is not None and getattr(user, "pk", None) == site.owner_id:
            return False
        now = now or timezone.now()
        qs = CctvAccessLog.objects.filter(
            site=site, action=action, camera_id=camera_id,
            user_id=getattr(user, "pk", None), link=link,
            created__gte=now - timedelta(seconds=CT.LOG_DEDUPE_S))
        if qs.exists():
            return False
        CctvAccessLog.objects.create(site=site, action=action, camera_id=camera_id,
                                     user=user if getattr(user, "pk", None) else None,
                                     link=link)
        if secrets.randbelow(50) == 0:      # bounded: prune old rows now and then
            CctvAccessLog.objects.filter(
                created__lt=now - timedelta(days=CT.LOG_KEEP_DAYS)).delete()
        return True
    except Exception:
        return False


# ===================================================================== stills
def _abs(request, f):
    try:
        u = f.url
    except Exception:
        return None
    if request is None:
        return u
    try:
        return request.build_absolute_uri(u)
    except Exception:
        return u


def _abs_name(request, storage, name):
    try:
        u = storage.url(name)
    except Exception:
        return None
    if request is None:
        return u
    try:
        return request.build_absolute_uri(u)
    except Exception:
        return u


def latest_still(cam):
    """(file, at_or_None, source) — the newest still we hold for a camera:
    a fresh vendor still, the last alert photo, or the setup-check photo."""
    best = (None, None, None)
    if cam.still and cam.still_at:
        best = (cam.still, cam.still_at, "camera")
    ev = cam.events.filter(pending=False).exclude(snapshot="").exclude(
        snapshot__isnull=True).only("snapshot", "created").first()
    if ev is not None and (best[1] is None or ev.created > best[1]):
        best = (ev.snapshot, ev.created, "alert")
    if best[0] is None and cam.preview:
        best = (cam.preview, None, "check")
    return best


def fresh_supported(cam):
    """Which vendor cloud can take a fresh still for this camera, or None."""
    ref = cam.vendor_ref or ""
    if cam.vendor == "ezviz" and ref.startswith("EZ:"):
        return "ezviz"
    if cam.vendor == "imou" and ref and not ref.startswith("EZ:"):
        return "imou"
    return None


def vendor_still(cam):
    """(jpeg bytes, None) or (None, reason). Tests patch this."""
    kind = fresh_supported(cam)
    if kind == "imou":
        from .logic import imou as IM
        if not WMV.imou_cloud_on():
            return None, "cloud_off"
        client = IM.ImouClient.from_integration()
        if client is None:
            return None, "cloud_off"
        dev, _, ch = cam.vendor_ref.partition(":")
        try:
            url = client.snapshot_url(dev, ch or "0")
        except IM.ImouError:
            return None, "vendor_error"
        raw = IM.fetch_snapshot(url)
        return (raw, None) if raw else (None, "vendor_error")
    if kind == "ezviz":
        from .logic import ezviz as EZ
        from . import cashguard_views as CGV
        if not CGV.ezviz_on():
            return None, "cloud_off"
        client = EZ.EzvizClient.from_integration()
        if client is None:
            return None, "cloud_off"
        try:
            _, serial, ch = cam.vendor_ref.split(":")
            url = client.capture(serial, int(ch or 1))
        except (ValueError, EZ.EzvizError):
            return None, "vendor_error"
        raw = CGV._fetch_ezviz_pic(url)
        return (raw, None) if raw else (None, "vendor_error")
    return None, "unsupported"


def take_still(cam, now=None):
    """Fetch + keep a fresh vendor still (rate-limited per camera). Returns
    (stored_bool, inline_jpeg_or_None, reason_or_None). With retention 0
    nothing is stored — the bytes come back inline once."""
    from .models import ShopCamera
    now = now or timezone.now()
    if cam.still_at and (now - cam.still_at).total_seconds() < CT.STILL_MIN_S:
        return False, None, "too_soon"
    raw, why = vendor_still(cam)
    if raw is None:
        return False, None, why
    if SV.looks_like_video(raw):
        return False, None, "vendor_error"
    small = SV._small_jpeg(raw, "still%d.jpg" % cam.id)
    if small is None:
        return False, None, "vendor_error"
    if cam.site.snapshot_retention_days <= 0:
        ShopCamera.objects.filter(pk=cam.pk).update(still_at=now)
        cam.still_at = now
        return False, small.read(), None
    old = cam.still.name if cam.still else ""
    cam.still.save(small.name, small, save=False)
    cam.still_at = now
    cam.save(update_fields=["still", "still_at"])
    if old and old != cam.still.name:
        try:
            cam.still.storage.delete(old)
        except Exception:
            pass
    return True, None, None


STILL_REASONS = {
    "unsupported": ("এই ক্যামেরা থেকে এখনই নতুন ছবি আনা যায় না — শেষ সতর্কতার ছবি দেখানো হচ্ছে। "
                    "এখনকার দৃশ্য দেখতে লাইভ খুলুন।",
                    "A fresh photo can't be fetched from this camera — the last alert photo is "
                    "shown. Open live to see it right now."),
    "cloud_off": ("ক্যামেরা কোম্পানির ক্লাউড সংযোগ এখনো চালু হয়নি।",
                  "The camera maker's cloud link is not switched on yet."),
    "vendor_error": ("ক্যামেরা এখন ছবি দিল না — ক্যামেরা অনলাইনে আছে কিনা দেখে আবার চেষ্টা করুন।",
                     "The camera did not send a photo — check it is online and try again."),
    "too_soon": ("কয়েক সেকেন্ড আগেই নতুন ছবি আনা হয়েছে।", "A fresh photo was taken seconds ago."),
}


def still_json(request, cam, inline=None, reason=None, lang="bn"):
    f, at, src = latest_still(cam)
    out = {"camera": cam.id, "still_url": _abs(request, f) if f else None,
           "still_at": SV._iso(at), "source": src,
           "fresh_supported": fresh_supported(cam) is not None}
    if inline:
        out["inline_jpeg"] = base64.b64encode(inline).decode()
        out["still_at"] = SV._iso(cam.still_at)
        out["source"] = "camera"
    if reason:
        bn, en = STILL_REASONS.get(reason, STILL_REASONS["vendor_error"])
        out["reason"] = reason
        out["detail"] = pick(lang, bn, en)
    return out


class CameraStillView(_TeamBase):
    def get(self, request, pk):
        lang = req_lang(request)
        cam, role, _v = camera_access(request, pk)
        if cam is None:
            return _nf(lang)
        log_access(cam.site, "still", user=request.user, camera_id=cam.id)
        return Response(still_json(request, cam, lang=lang))

    def post(self, request, pk):
        lang = req_lang(request)
        cam, role, _v = camera_access(request, pk)
        if cam is None:
            return _nf(lang)
        if not cam.enabled:
            return _err(lang, "ক্যামেরাটি বন্ধ আছে।", "This camera is turned off.",
                        status=409, code="camera_disabled")
        log_access(cam.site, "still", user=request.user, camera_id=cam.id)
        _stored, inline, why = take_still(cam)
        out = still_json(request, cam, inline=inline, reason=why, lang=lang)
        out["fresh"] = why is None
        return Response(out)


# ===================================================================== grid
def _grid_cameras(request, site, role, scope, viewer, now):
    from .models import ShopEvent
    snap = ShopEvent.objects.filter(camera=OuterRef("pk"), pending=False).exclude(
        snapshot="").exclude(snapshot__isnull=True).order_by("-created")
    cams = site.cameras.all().annotate(
        ev_snap=Subquery(snap.values("snapshot")[:1]),
        ev_at=Subquery(snap.values("created")[:1]))
    open_by_cam = {}
    for cid in site.events.filter(status="open", pending=False).values_list(
            "camera_id", flat=True)[:500]:
        open_by_cam[cid] = open_by_cam.get(cid, 0) + 1
    out = []
    for c in cams:
        if not CT.camera_allowed(scope, c.id):
            continue
        online = SV.is_online(c.last_seen, now)
        # newest of: fresh vendor still, last alert photo, setup-check photo
        f, at, src = None, None, None
        if c.still and c.still_at:
            f, at, src = c.still, c.still_at, "camera"
        url = None
        if c.ev_snap and (at is None or (c.ev_at and c.ev_at > at)):
            f, at, src = None, c.ev_at, "alert"
            url = _abs_name(request, ShopEvent._meta.get_field("snapshot").storage, c.ev_snap)
        if f is None and url is None and c.preview:
            f, src = c.preview, "check"
        if f is not None:
            url = _abs(request, f)
        caps = (c.device_info or {}).get("caps") if isinstance(c.device_info, dict) else []
        live_capable = bool(caps and "live" in caps)
        live_ok = live_capable and c.enabled and (role == "owner" or viewer_live_ok(c, viewer))
        out.append({
            "id": c.id, "name": c.name, "vendor": c.vendor,
            "status": CT.camera_status(c.enabled, online, c.last_seen),
            "last_seen": SV._iso(c.last_seen),
            "still_url": url,
            "still_at": SV._iso(at), "still_source": src,
            "fresh_supported": fresh_supported(c) is not None,
            "live_capable": live_capable, "live_ok": live_ok,
            "open_alerts": open_by_cam.get(c.id, 0)})
    return out


class GridView(_TeamBase):
    """Every site I own or may view, each with the cameras I may see: status
    pill, newest still (signed short-lived link), open alerts, live allowed.
    Snapshots, never streams — light on a 2 GB phone."""

    def get(self, request):
        from .models import ShopSite, ShopLiveSession
        from . import shop_ops_views as SOV
        now = timezone.now()
        own = list(ShopSite.objects.filter(owner=request.user))
        viewed = list(ShopSite.objects.filter(viewers__user=request.user)
                      .exclude(owner=request.user).select_related("owner"))
        sites = []
        for s in own + viewed:
            role, scope = scope_for(s, request.user)
            if role is None:
                continue
            viewer = None if role == "owner" else viewer_of(s, request.user)
            cams = _grid_cameras(request, s, role, scope, viewer, now)
            if role != "owner":
                log_access(s, "still", user=request.user, now=now)
            sites.append({
                "id": s.id, "name": s.name, "kind": s.kind, "role": role,
                "owner_name": "" if role == "owner" else (getattr(s.owner, "name", "") or ""),
                "gateway_online": SV.is_online(s.last_seen, now),
                "open_alerts": sum(c["open_alerts"] for c in cams),
                "cameras": cams})
        try:
            live_max = SOV.live_max_per_account()
        except Exception:
            live_max = 2
        live_now = ShopLiveSession.objects.filter(
            site__owner=request.user, status__in=("pending", "active"),
            expires_at__gt=now).count()
        return Response({"sites": sites, "live_max": live_max, "live_now": live_now,
                         "refresh_s": 60})


# ===================================================================== roles
def _role_row(v):
    from .phone import mask
    role = v.role if v.role in CT.ROLES else "family"
    return {"user_id": v.user_id, "name": getattr(v.user, "name", "") or "",
            "phone": mask(v.user.phone or ""), "since": v.created.isoformat(),
            "role": role, "cameras": list(CT.scope_of(role, v.cameras) or []),
            "all_cameras": CT.scope_of(role, v.cameras) is None,
            "live_ok": bool(v.live_ok)}


class ViewerRoleView(_TeamBase):
    """PUT {role: family|manager|guard, cameras: [ids], live_ok} — the owner
    decides what one person may see. A guard sees ONLY the chosen cameras."""

    def put(self, request, pk, uid):
        from .models import ShopSiteViewer
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _nf(lang)
        v = ShopSiteViewer.objects.filter(site=s, user_id=uid).select_related("user").first()
        if v is None:
            return _nf(lang)
        try:
            role, ids = CT.clean_role(request.data.get("role", v.role),
                                      request.data.get("cameras", v.cameras),
                                      s.cameras.values_list("id", flat=True))
        except CT.TeamError as e:
            return _team_err(lang, e)
        v.role, v.cameras = role, ids
        if "live_ok" in request.data:
            v.live_ok = SV._coerce_bool(request.data.get("live_ok"))
        v.save(update_fields=["role", "cameras", "live_ok"])
        return Response(_role_row(v))

    post = put


class ViewerRolesView(_TeamBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _nf(lang)
        return Response({"viewers": [_role_row(v) for v in s.viewers.select_related("user")],
                         "cameras": [{"id": c.id, "name": c.name} for c in s.cameras.all()],
                         "roles": list(CT.ROLES)})


# ===================================================================== access log
def _log_row(r):
    who = None
    if r.user_id:
        who = getattr(r.user, "name", "") or ""
    return {"id": r.id, "at": r.created.isoformat(), "action": r.action,
            "user_id": r.user_id, "name": who,
            "link_id": r.link_id, "link_label": (r.link.label if r.link_id and r.link else ""),
            "camera": r.camera_id,
            "camera_name": (r.camera.name if r.camera_id and r.camera else "")}


class AccessLogView(_TeamBase):
    """The owner sees who (family, guard, manager, a share link) looked at
    which camera and when — last 30 days. Owner-only."""

    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _nf(lang)
        rows = s.access_logs.select_related("user", "link", "camera")[:200]
        return Response({"site": s.id, "rows": [_log_row(r) for r in rows],
                         "keep_days": CT.LOG_KEEP_DAYS,
                         "note": pick(lang,
                                      "শুধু আপনি এই তালিকা দেখেন। Assisto-র কোনো কর্মী বা মালিক আপনার ক্যামেরা দেখতে পারেন না।",
                                      "Only you see this list. No Assisto staff member or owner can see your cameras.")})


# ===================================================================== share links
def _hash(token):
    return hashlib.sha256(str(token).encode()).hexdigest()


def share_url(token):
    from .journey_watch import site as _site
    return "%s/c/%s" % (_site(), token)


def link_json(link, now=None, token=None):
    now = now or timezone.now()
    out = {"id": link.id, "label": link.label, "cameras": list(link.cameras or []),
           "state": CT.link_state(link.revoked_at, link.expires_at, now),
           "expires_at": link.expires_at.isoformat(),
           "created_at": link.created_at.isoformat() if link.created_at else None,
           "views": link.views, "audio": False,
           "last_view_at": SV._iso(link.last_view_at)}
    if token:
        out["url"] = share_url(token)
    return out


class ShareLinksView(_TeamBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _nf(lang)
        now = timezone.now()
        rows = list(s.share_links.all()[:20])
        return Response({"links": [link_json(l, now) for l in rows],
                         "presets": list(CT.SHARE_PRESETS),
                         "max_hours": CT.SHARE_MAX_HOURS,
                         "max_active": CT.MAX_ACTIVE_LINKS})

    def post(self, request, pk):
        from .models import CctvShareLink
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _nf(lang)
        now = timezone.now()
        try:
            hours = CT.share_hours(request.data.get("hours"))
            ids = CT.share_cameras(request.data.get("cameras"),
                                   s.cameras.values_list("id", flat=True))
        except CT.TeamError as e:
            return _team_err(lang, e)
        active = s.share_links.filter(revoked_at__isnull=True, expires_at__gt=now).count()
        if active >= CT.MAX_ACTIVE_LINKS:
            return _err(lang, "একসাথে সর্বোচ্চ ৫টি লিংক চালু থাকতে পারে — পুরনো একটি বন্ধ করুন।",
                        "Up to 5 links can be open at once — turn an old one off.",
                        status=409, code="too_many_links")
        token = secrets.token_urlsafe(24)
        link = CctvShareLink.objects.create(
            site=s, created_by=request.user, token_hash=_hash(token),
            label=" ".join(str(request.data.get("label") or "").split())[:40],
            cameras=ids, expires_at=now + timedelta(hours=hours))
        return Response(link_json(link, now, token=token), status=201)


class ShareLinkRevokeView(_TeamBase):
    def post(self, request, pk):
        from .models import CctvShareLink
        lang = req_lang(request)
        link = CctvShareLink.objects.filter(pk=pk, site__owner=request.user).first()
        if link is None:
            return _nf(lang)
        if link.revoked_at is None:
            link.revoked_at = timezone.now()
            link.save(update_fields=["revoked_at"])
        return Response(link_json(link))


def public_link(token, now=None):
    """(link, state) for the web page; state active | expired | revoked |
    bad | paused (feature switched off). The random token IS the permission."""
    from .models import CctvShareLink
    now = now or timezone.now()
    if not token or len(str(token)) > 64:
        return None, "bad"
    link = CctvShareLink.objects.filter(token_hash=_hash(token)).select_related(
        "site").first()
    if link is None:
        return None, "bad"
    try:
        from . import feature_flags as FF
        if not FF.is_on(FLAG, link.site.owner, False):
            return link, "paused"
    except Exception:
        pass
    return link, CT.link_state(link.revoked_at, link.expires_at, now)


def public_state(token, now=None, count_view=False):
    """Public JSON for /c/<token>/data: stills of the chosen cameras ONLY
    while the link is active. Never audio, never history, never a token."""
    from .models import CctvShareLink, ShopCamera
    now = now or timezone.now()
    link, st = public_link(token, now)
    if link is None:
        return {"state": "bad"}, 404
    if st != "active":
        return {"state": st}, 200
    if count_view:
        from django.db.models import F
        CctvShareLink.objects.filter(pk=link.pk).update(
            views=F("views") + 1, last_view_at=now)
        log_access(link.site, "link", link=link, now=now)
    cams = []
    for c in ShopCamera.objects.filter(site=link.site, pk__in=list(link.cameras or [])):
        if not c.enabled:
            cams.append({"id": c.id, "name": c.name, "status": "off", "has_still": False})
            continue
        # a fresh still at most once per minute per camera, only when the
        # vendor cloud can take one; else the newest photo we already hold
        if fresh_supported(c) and (c.still_at is None or
                                   (now - c.still_at).total_seconds() >= 60):
            try:
                take_still(c, now)
            except Exception:
                pass
        f, at, _src = latest_still(c)
        cams.append({"id": c.id, "name": c.name,
                     "status": CT.camera_status(c.enabled, SV.is_online(c.last_seen, now), c.last_seen),
                     "has_still": f is not None, "still_at": SV._iso(at)})
    return {"state": "active", "expires_at": link.expires_at.isoformat(),
            "site": link.site.name, "cameras": cams, "audio": False,
            "refresh_s": 30}, 200


def public_image(token, cam_id, now=None):
    """JPEG bytes of one shared camera's newest still, or None."""
    link, st = public_link(token, now)
    if link is None or st != "active":
        return None
    try:
        cid = int(cam_id)
    except (TypeError, ValueError):
        return None
    if cid not in [int(i) for i in (link.cameras or [])]:
        return None
    cam = link.site.cameras.filter(pk=cid, enabled=True).first()
    if cam is None:
        return None
    f, _at, _src = latest_still(cam)
    if f is None:
        return None
    try:
        f.open("rb")
        try:
            return f.read()
        finally:
            f.close()
    except Exception:
        return None


# ===================================================================== neighbourhood watch
def _watch_groups(user):
    """Active memberships in PRIVATE communities (never a public one)."""
    from .models import CommunityMember
    return (CommunityMember.objects.filter(member=user, status="active",
                                           community__is_public=False)
            .select_related("group", "community"))


def _member(user, group_id):
    from .models import CommunityMember
    try:
        gid = int(group_id)
    except (TypeError, ValueError):
        return None
    return (CommunityMember.objects.filter(member=user, status="active", group_id=gid,
                                           community__is_public=False)
            .select_related("group", "community").first())


def sweep_watch(now=None):
    """Expire posts: delete the image file, keep a tombstone. Bounded."""
    from .models import CctvWatchPost
    now = now or timezone.now()
    from django.db.models import Q
    todo = CctvWatchPost.objects.filter(expires_at__lte=now).filter(
        Q(removed=False) | (Q(image__isnull=False) & ~Q(image="")))
    for p in todo[:50]:
        try:
            p.image.delete(save=False)
        except Exception:
            pass
        p.image = None
        if not p.removed:
            p.removed, p.removed_reason = True, "expired"
        p.save(update_fields=["image", "removed", "removed_reason"])


def _post_json(request, p, me):
    return {"id": p.id, "group": p.group_id, "caption": p.caption,
            "author_id": p.author_id, "author_name": getattr(p.author, "name", "") or "",
            "mine": p.author_id == me.pk,
            "image_url": _abs(request, p.image) if p.image else None,
            "created": p.created.isoformat(), "expires_at": p.expires_at.isoformat()}


WATCH_NOTE = ("শুধু এই প্রাইভেট গ্রুপের সদস্যরা দেখেন; সময় শেষে ছবিটি মুছে যায়। মুখ ঝাপসা করা হয় না — "
              "অন্যের মুখ থাকলে ভেবে শেয়ার করুন। কাউকে চোর বলবেন না — 'সন্দেহজনক, একটু খেয়াল রাখুন' লিখুন।",
              "Only members of this private group see it; the photo is deleted when time is up. Faces are "
              "NOT blurred — think before sharing someone's face. Never call anyone a thief — write "
              "'suspicious, please keep an eye out'.")


class WatchGroupsView(_TeamBase):
    def get(self, request):
        lang = req_lang(request)
        rows = []
        for m in _watch_groups(request.user)[:50]:
            g = m.group
            if g.announcements_only and m.role != "admin":
                continue
            rows.append({"id": g.id, "name": g.name, "community": m.community.name,
                         "members": g.members.filter(status="active").count()})
        return Response({"groups": rows, "hours": list(CT.WATCH_HOURS),
                         "default_hours": CT.WATCH_DEFAULT_HOURS,
                         "note": pick(lang, *WATCH_NOTE)})


class WatchPostsView(_TeamBase):
    def get(self, request):
        from .models import CctvWatchPost, CctvWatchBlock, CctvWatchReport
        lang = req_lang(request)
        m = _member(request.user, request.query_params.get("group"))
        if m is None:
            return _nf(lang)
        now = timezone.now()
        sweep_watch(now)
        blocked = CctvWatchBlock.objects.filter(blocker=request.user).values_list(
            "blocked_id", flat=True)
        reported = CctvWatchReport.objects.filter(reporter=request.user).values_list(
            "post_id", flat=True)
        qs = (CctvWatchPost.objects.filter(group=m.group, removed=False, expires_at__gt=now)
              .exclude(author_id__in=list(blocked)).exclude(pk__in=list(reported))
              .select_related("author")[:50])
        return Response({"group": m.group_id, "posts": [_post_json(request, p, request.user) for p in qs],
                         "note": pick(lang, *WATCH_NOTE)})

    def post(self, request):
        """{group, event | camera, caption, hours, confirm: true} — the user's
        OWN explicit choice of ONE still. Never automatic."""
        from django.core.files.base import ContentFile
        from .models import CctvWatchPost, ShopEvent
        lang = req_lang(request)
        if not SV._coerce_bool(request.data.get("confirm")):
            return _err(lang, "শেয়ারের আগে নিশ্চিত করুন।", "Please confirm before sharing.",
                        status=422, code="confirm_needed")
        m = _member(request.user, request.data.get("group"))
        if m is None:
            return _nf(lang)
        if m.group.announcements_only and m.role != "admin":
            return _err(lang, "এই গ্রুপে শুধু অ্যাডমিন পোস্ট করতে পারেন।",
                        "Only admins can post in this group.", status=403, code="admins_only")
        try:
            hours = CT.watch_hours(request.data.get("hours"))
        except CT.TeamError as e:
            return _team_err(lang, e)
        # the photo: an alert's snapshot or a camera's newest still the user
        # may see — the server copies it, the phone never uploads anything
        src = None
        eid, cid = request.data.get("event"), request.data.get("camera")
        if eid not in (None, ""):
            from . import cctvx_views as CXV
            ev, role = CXV.event_access(request, eid)
            if ev is not None and ev.snapshot:
                src = ev.snapshot
        elif cid not in (None, ""):
            cam, role, _v = camera_access(request, cid)
            if cam is not None:
                src = latest_still(cam)[0]
        if src is None:
            return _err(lang, "এই ছবিটি পাওয়া যায়নি।", "That photo was not found.",
                        status=404, code="no_photo")
        try:
            src.open("rb")
            try:
                raw = src.read()
            finally:
                src.close()
        except Exception:
            raw = b""
        small = SV._small_jpeg(raw, "watch.jpg") if raw else None
        if small is None:
            return _err(lang, "ছবিটি পড়া গেল না।", "The photo could not be read.",
                        status=422, code="bad_photo")
        now = timezone.now()
        p = CctvWatchPost(group=m.group, author=request.user,
                          caption=CT.clean_caption(request.data.get("caption")),
                          expires_at=now + timedelta(hours=hours))
        p.image.save("watch.jpg", ContentFile(small.read()), save=False)
        p.save()
        self._notify(m, p)
        return Response(_post_json(request, p, request.user), status=201)

    @staticmethod
    def _notify(m, p):
        try:
            from . import push
            from .models import CctvWatchBlock
            blockers = set(CctvWatchBlock.objects.filter(blocked=p.author).values_list(
                "blocker_id", flat=True))
            name = getattr(p.author, "name", "") or ""
            for cm in m.group.members.filter(status="active").exclude(
                    member=p.author).select_related("member")[:256]:
                if cm.member_id in blockers:
                    continue
                push.safe_push(cm.member, "shop_alert",
                               "পাড়া-পাহারা: %s একটি ছবি শেয়ার করেছেন" % (name or "একজন"),
                               "Neighbourhood watch: %s shared a photo" % (name or "Someone"),
                               m.group.name, m.group.name,
                               data={"route": "cctv_watch", "group": m.group_id,
                                     "post": p.id})
        except Exception:
            pass


class WatchPostDeleteView(_TeamBase):
    def delete(self, request, pk):
        from .models import CctvWatchPost
        lang = req_lang(request)
        p = CctvWatchPost.objects.filter(pk=pk, removed=False).select_related("group").first()
        if p is None:
            return _nf(lang)
        m = _member(request.user, p.group_id)
        if p.author_id != request.user.pk and not (m is not None and m.role == "admin"):
            return _nf(lang)
        try:
            p.image.delete(save=False)
        except Exception:
            pass
        p.image = None
        p.removed = True
        p.removed_reason = "author" if p.author_id == request.user.pk else "admin"
        p.save(update_fields=["image", "removed", "removed_reason"])
        return Response({"ok": True})


class WatchReportView(_TeamBase):
    def post(self, request, pk):
        from .models import CctvWatchPost, CctvWatchReport
        lang = req_lang(request)
        p = CctvWatchPost.objects.filter(pk=pk, removed=False).first()
        if p is None or _member(request.user, p.group_id) is None:
            return _nf(lang)
        if p.author_id == request.user.pk:
            return _err(lang, "নিজের পোস্ট রিপোর্ট করা যায় না — মুছে দিন।",
                        "You can't report your own post — delete it.", status=409, code="own_post")
        CctvWatchReport.objects.get_or_create(
            post=p, reporter=request.user,
            defaults={"reason": CT.report_reason(request.data.get("reason"))})
        hidden = False
        if p.reports.count() >= CT.REPORT_HIDE:
            try:
                p.image.delete(save=False)
            except Exception:
                pass
            p.image = None
            p.removed, p.removed_reason = True, "reports"
            p.save(update_fields=["image", "removed", "removed_reason"])
            hidden = True
        if SV._coerce_bool(request.data.get("block")):
            from .models import CctvWatchBlock
            CctvWatchBlock.objects.get_or_create(blocker=request.user, blocked=p.author)
        return Response({"ok": True, "hidden_for_all": hidden})


class WatchBlockView(_TeamBase):
    def post(self, request):
        from .models import CctvWatchBlock, User
        lang = req_lang(request)
        try:
            u = User.objects.get(pk=int(request.data.get("user")))
        except (User.DoesNotExist, TypeError, ValueError):
            return _nf(lang)
        if u.pk == request.user.pk:
            return _err(lang, "নিজেকে ব্লক করা যায় না।", "You can't block yourself.",
                        status=409, code="self")
        CctvWatchBlock.objects.get_or_create(blocker=request.user, blocked=u)
        return Response({"ok": True})

    def delete(self, request):
        from .models import CctvWatchBlock
        CctvWatchBlock.objects.filter(blocker=request.user,
                                      blocked_id=request.query_params.get("user") or 0).delete()
        return Response({"ok": True})
