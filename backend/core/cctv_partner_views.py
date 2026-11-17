"""
cctv_partner_views.py — cctvroles (CCTV Guard V3 J): installer partners.
(V3 K sticker: the app's privacy kit already makes the printable Bangla +
English PDF with correct Bangla shaping — screens/watchman/cctvx_privacy_kit.dart
from GET shop/sites/<id>/privacy-kit, owner only.)
Rules: core/logic/cctv_partner.py. Owner Admin page: web/owner/views_cctvpartners.py.

PRIVACY WALL: a partner reaches ONLY setup facts (counts, online / connected
yes-no, hours set, zones set, camera names). No endpoint here returns a
photo, a clip, a stream, an alert or anything from ShopEvent — and a partner
is never a ShopSiteViewer, so every CCTV media endpoint answers 404 to them
(tests_cctvroles.PartnerWallTests).

SITE OWNER (Token auth, flags cctv_watchman + home_watchman)
  GET  shop/sites/<id>/installer          invites + linked installers
  POST shop/sites/<id>/installer          new invite -> {code, qr, expires_at}
  POST shop/installer/<link id>/end       end an invite / an installer
PARTNER (the technician's own account)
  GET  shop/partner/me                    my partner status + my sites' setup
  POST shop/partner/apply {name, area}    apply (Owner Admin approves)
  POST shop/partner/join {code}           use a site owner's code / QR link
"""
from datetime import timedelta

from django.db import IntegrityError
from django.utils import timezone
from rest_framework.response import Response

from .i18n import req_lang, pick
from . import shop_views as SV
from . import cctv_team_views as CTV
from .logic import cctv_partner as CPT

ERRS = {
    "need_name": ("আপনার বা দোকানের নাম লিখুন।", "Please write your or your shop's name."),
    "need_area": ("কোন এলাকায় কাজ করেন লিখুন।", "Please write the area you work in."),
    "bad_code": ("কোডটি ঠিক নেই — ৮ অক্ষরের কোডটি আবার দেখুন।",
                 "That code is not right — please check the 8-letter code."),
    "expired": ("কোডটির মেয়াদ শেষ — মালিককে নতুন কোড দিতে বলুন।",
                "That code has expired — ask the owner for a new one."),
    "not_approved": ("আপনার পার্টনার আবেদন এখনো অনুমোদন হয়নি।",
                     "Your partner application is not approved yet."),
    "own_site": ("এটি আপনার নিজের জায়গা — ইনস্টলার কোড লাগবে না।",
                 "This is your own place — no installer code needed."),
    "too_many": ("একসাথে সর্বোচ্চ ৩টি কোড খোলা থাকতে পারে — পুরনো একটি বন্ধ করুন।",
                 "Up to 3 codes can be open at once — end an old one."),
    "full": ("এই জায়গায় ইতিমধ্যে ২ জন ইনস্টলার আছেন — একজনকে সরান।",
             "This place already has 2 installers — remove one first."),
}

STATUS_NOTE = ("আপনি শুধু সেটআপের অবস্থা দেখেন — কোনো ভিডিও, ছবি বা সতর্কতা কখনো নয়।",
               "You see only the setup status — never any video, photo or alert.")
OWNER_NOTE = ("ইনস্টলার শুধু সেটআপের অবস্থা দেখেন (ক্যামেরা অনলাইন কিনা) — কখনো ভিডিও, ছবি বা সতর্কতা নয়। যেকোনো সময় বন্ধ করতে পারেন।",
              "An installer sees only the setup status (are the cameras online) — never video, photos or alerts. You can end it any time.")


def _e(lang, code, status=422):
    bn, en = ERRS[code]
    return SV._err(lang, bn, en, status=status, code=code)


def _partner_of(user):
    from .models import CctvPartner
    return CctvPartner.objects.filter(user_id=user.pk).first()


def _partner_json(p):
    if p is None:
        return None
    return {"status": p.status, "name": p.name, "area": p.area,
            "since": p.created.isoformat()}


def _link_json(link, now):
    st = link.status
    if st == "invited" and link.expires_at <= now:
        st = "expired"
    p = link.partner
    return {"id": link.id, "status": st,
            "partner": {"name": p.name, "area": p.area} if p else None,
            "created": link.created.isoformat(),
            "expires_at": link.expires_at.isoformat() if st == "invited" else None,
            "accepted_at": SV._iso(link.accepted_at)}


# ------------------------------------------------------------ site owner
class SiteInstallerView(CTV._TeamBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return CTV._nf(lang)
        now = timezone.now()
        rows = s.installer_links.exclude(status="ended").select_related("partner")[:20]
        return Response({"site": s.id, "links": [_link_json(r, now) for r in rows],
                         "invite_hours": CPT.INVITE_HOURS,
                         "note": pick(lang, *OWNER_NOTE)})

    def post(self, request, pk):
        from .models import CctvInstallerLink
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return CTV._nf(lang)
        now = timezone.now()
        open_n = s.installer_links.filter(status="invited", expires_at__gt=now).count()
        if open_n >= CPT.MAX_OPEN_INVITES:
            return _e(lang, "too_many", 409)
        for _ in range(5):
            code = CPT.new_code()
            try:
                link = CctvInstallerLink.objects.create(
                    site=s, code_hash=CPT.code_hash(code),
                    expires_at=now + timedelta(hours=CPT.INVITE_HOURS))
                break
            except IntegrityError:
                continue
        else:
            return SV._err(lang, "আবার চেষ্টা করুন।", "Please try again.", status=503)
        CTV.audit(s, "installer", request.user, CTV.CT.pack(invite=1))
        out = _link_json(link, now)
        out.update(code=code, qr=CPT.qr_payload(code), note=pick(lang, *OWNER_NOTE))
        return Response(out, status=201)


class InstallerEndView(CTV._TeamBase):
    def post(self, request, pk):
        from .models import CctvInstallerLink
        lang = req_lang(request)
        link = CctvInstallerLink.objects.filter(pk=pk, site__owner=request.user).select_related(
            "site", "partner").first()
        if link is None:
            return CTV._nf(lang)
        if link.status != "ended":
            link.status, link.ended_at = "ended", timezone.now()
            link.save(update_fields=["status", "ended_at"])
            CTV.audit(link.site, "installer", request.user,
                      CTV.CT.pack(ended=link.partner.name if link.partner else ""))
        return Response(_link_json(link, timezone.now()))


# ------------------------------------------------------------ partner
def site_setup(site, now=None):
    """Setup facts of ONE site for its installer — nothing else."""
    now = now or timezone.now()
    cams = list(site.cameras.all().only("id", "name", "enabled", "last_seen", "zone_config"))
    rows, online, zones = [], 0, 0
    for c in cams:
        on = bool(c.enabled) and SV.is_online(c.last_seen, now)
        online += 1 if on else 0
        zc = c.zone_config if isinstance(c.zone_config, dict) else {}
        has_zone = any(isinstance(v, list) and len(v) >= 3 for v in zc.values())
        zones += 1 if has_zone else 0
        rows.append({"name": c.name or "", "online": on, "zone": has_zone})
    age = None
    if site.last_seen:
        age = max(0, int((now - site.last_seen).total_seconds() // 60))
    steps = CPT.setup_checklist({"cameras": len(cams), "online": online,
                                 "gateway_age_min": age,
                                 "hours": bool((site.hours or {}).get("open")),
                                 "zones": zones})
    return {"cameras": len(cams), "online": online, "gateway_age_min": age,
            "camera_rows": rows, "steps": steps, "done": CPT.setup_done(steps)}


def paying(site, now=None):
    """(paying, in_trial, cameras) from the site owner's CCTV plan — the
    only billing fact the commission proposal needs."""
    try:
        from . import cctv_plan_service as CPS
        st = CPS.status(site.owner, now=now)
        return st.get("status") == "active", bool(st.get("in_trial")), int(st.get("cameras") or 0)
    except Exception:
        return False, False, 0


def _commission_json(p):
    """cctvprice (owner-decided 17 Nov 12:35): the rule + the partner's OWN
    ledger totals (owed / paid, taka). Never another partner's numbers."""
    rules = CPT.COMMISSION_RULES
    out = {"status": "decided", "approved": bool(rules["approved"]),
           "pct": rules["pct_of_net"], "months": rules["months"],
           "applies_to": rules["applies_to"], "owed_bdt": 0, "paid_bdt": 0}
    if p is None:
        return out
    try:
        from django.db.models import Sum
        from .models import CctvCommissionEntry
        for k in ("owed", "paid"):
            out[k + "_bdt"] = int(CctvCommissionEntry.objects.filter(partner=p, status=k)
                                  .aggregate(s=Sum("amount_bdt"))["s"] or 0)
    except Exception:
        pass
    return out


class PartnerMeView(CTV._TeamBase):
    def get(self, request):
        lang = req_lang(request)
        p = _partner_of(request.user)
        sites = []
        if p is not None and p.status == "approved":
            now = timezone.now()
            for link in p.links.filter(status="active").select_related("site")[:50]:
                s = link.site
                pay, trial, _n = paying(s, now)
                row = {"link_id": link.id, "site": s.id, "name": s.name or "",
                       "kind": s.kind, "since": SV._iso(link.accepted_at),
                       "paying": pay and not trial}
                row.update(site_setup(s, now))
                sites.append(row)
        return Response({"partner": _partner_json(p), "sites": sites,
                         "commission": _commission_json(p),
                         "note": pick(lang, *STATUS_NOTE)})


class PartnerApplyView(CTV._TeamBase):
    def post(self, request):
        from .models import CctvPartner
        lang = req_lang(request)
        try:
            name, area = CPT.clean_apply(request.data.get("name"), request.data.get("area"))
        except CPT.PartnerError as e:
            return _e(lang, e.code)
        p = _partner_of(request.user)
        if p is None:
            p = CctvPartner.objects.create(user=request.user, name=name, area=area)
        elif p.status == "pending":
            p.name, p.area = name, area
            p.save(update_fields=["name", "area"])
        return Response(_partner_json(p), status=201)


class PartnerJoinView(CTV._TeamBase):
    def post(self, request):
        from .models import CctvInstallerLink
        lang = req_lang(request)
        p = _partner_of(request.user)
        if p is None or p.status != "approved":
            return _e(lang, "not_approved", 403)
        code = CPT.normalize_code(request.data.get("code"))
        if not code:
            return _e(lang, "bad_code")
        now = timezone.now()
        link = CctvInstallerLink.objects.filter(code_hash=CPT.code_hash(code)).select_related(
            "site").first()
        if link is None or link.status == "ended":
            return _e(lang, "bad_code")
        if link.status == "active":
            if link.partner_id == p.id:
                return Response({"ok": True, "site": link.site_id})
            return _e(lang, "bad_code")
        if link.expires_at <= now:
            return _e(lang, "expired", 410)
        if link.site.owner_id == request.user.pk:
            return _e(lang, "own_site")
        if link.site.installer_links.filter(status="active").count() >= CPT.MAX_ACTIVE_INSTALLERS:
            return _e(lang, "full", 409)
        n = CctvInstallerLink.objects.filter(pk=link.pk, status="invited").update(
            status="active", partner=p, accepted_at=now)
        if not n:
            return _e(lang, "bad_code")
        CTV.audit(link.site, "installer", request.user, CTV.CT.pack(joined=p.name))
        return Response({"ok": True, "site": link.site_id}, status=201)

