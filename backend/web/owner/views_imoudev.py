"""cctvconnect (owner order 9 Nov 17:20): Owner Admin -> Imou test cameras.
The owner adds HIS OWN Imou camera (e.g. a Ranger 2C on his desk) by the
sticker's serial number + Safety Code, bound to Assisto's Imou developer
account (bindDevice; the code is used once, never stored), after ticking the
on-screen consent. The camera lands on the owner's own CCTV place as an
"owner test device"; live, alarms and snapshots then work in the app like
any Imou camera. "Unlink" calls unBindDevice. No video or picture is ever
shown on this page (admin never sees video) — serials and states only."""
from django.http import HttpResponseRedirect
from django.views.decorators.http import require_http_methods

from .base import owner_view, page

L = {
    "bn": {"title": "Imou পরীক্ষার ক্যামেরা", "serial": "সিরিয়াল নম্বর (SN)",
           "code": "Safety Code (স্টিকারে লেখা)", "name": "নাম (ঐচ্ছিক)", "add": "যুক্ত করুন",
           "unlink": "সরান (unbind)", "none": "এখনো কোনো পরীক্ষার ক্যামেরা নেই।",
           "intro": "আপনার নিজের Imou ক্যামেরা (যেমন Ranger 2C) Assisto-র Imou ডেভেলপার অ্যাকাউন্টে যুক্ত করুন। "
                    "কোডটি একবারই ব্যবহার হয়, কোথাও রাখা হয় না। ক্যামেরাটি আপনার নিজের CCTV জায়গায় \"মালিকের পরীক্ষার ডিভাইস\" হিসেবে আসবে — "
                    "লাইভ, সতর্কতা ও ছবি অ্যাপে দেখুন। গ্রাহকের ক্যামেরা তাঁর উপস্থিতি ও সম্মতি ছাড়া কখনো এভাবে যুক্ত করবেন না।",
           "off": "Imou চাবি এখনো সবুজ নয় — Integrations → Imou → Test আগে চাপুন।",
           "state": "অবস্থা", "cams": "ক্যামেরা", "lat": "সতর্কতা পৌঁছাতে", "ok": "যুক্ত হয়েছে", "removed": "সরানো হয়েছে"},
    "en": {"title": "Imou test cameras", "serial": "Serial number (SN)",
           "code": "Safety Code (on the sticker)", "name": "Name (optional)", "add": "Link",
           "unlink": "Unlink (unbind)", "none": "No test camera yet.",
           "intro": "Link your OWN Imou camera (e.g. a Ranger 2C) to Assisto's Imou developer account. "
                    "The code is used once and never stored. It appears on your own CCTV place as an "
                    "\"owner test device\" — watch live, alerts and snapshots in the app. Never link a "
                    "customer's camera this way without them present and agreeing.",
           "off": "The Imou keys are not green yet — press Integrations → Imou → Test first.",
           "state": "State", "cams": "Cameras", "lat": "Alert delay", "ok": "Linked", "removed": "Unlinked"},
}


def _owner_site(user):
    from core.models import ShopSite
    site = ShopSite.objects.filter(owner=user).order_by("created").first()
    if site is None:
        site = ShopSite.objects.create(owner=user, name="Owner test (Imou)", kind="home")
    return site


def rows_for(user, lang="en"):
    from core.models import CctvCloudLink
    out = []
    for l in CctvCloudLink.objects.filter(site__owner=user, provider="imou",
                                          mode="device_code").exclude(status="revoked"):
        for s in l.serials or []:
            qs = l.site.cameras.filter(vendor_ref__startswith="%s:" % s)
            cams = qs.count()
            # imou-real: alarm push latency (camera -> Assisto), last + median
            lats = sorted(x for c in qs.only("compat") for x in
                          ((c.compat or {}).get("imou_latency_s") or []) if isinstance(x, (int, float)))
            last = [x for c in qs.only("compat") for x in ((c.compat or {}).get("imou_latency_s") or [])[-1:]]
            out.append({"link": l.id, "serial": s, "site": l.site.name, "status": l.status,
                        "cameras": cams,
                        "latency": _lat_text(last[-1], lats, lang) if lats and last else "—",
                        "test": s in ((l.state or {}).get("owner_test") or [])})
    return out


@require_http_methods(["GET", "POST"])
@owner_view()
def imou_devices(request):
    from core import cctv_connect_views as V
    from core.logic import cctv_connect as CC
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    msg, err = "", ""
    if request.method == "POST":
        act = request.POST.get("action", "")
        if act == "add":
            site = _owner_site(request.owner)
            try:
                link, devs = V.devbind(request.owner, site, "imou", request.POST.get("serial"),
                                       request.POST.get("code"), request.POST.get("consent"))
                items = [{"serial": d["serial"], "channel": c["no"],
                          "name": request.POST.get("name", "")[:100]}
                         for d in devs for c in d["channels"]] or [
                    {"serial": CC.base.clean_serial(request.POST.get("serial")), "channel": 0,
                     "name": request.POST.get("name", "")[:100]}]
                V.import_items(link, request.owner, items, lang)
                msg = lab["ok"]
            except V.BindRefused as e:
                err = e.bn if lang == "bn" else e.en
        elif act == "unlink":
            from core.models import CctvCloudLink
            link = CctvCloudLink.objects.filter(pk=request.POST.get("link"), site__owner=request.owner,
                                                provider="imou").first()
            if link is not None:
                V.revoke_link(link)
                msg = lab["removed"]
        if not err:
            return HttpResponseRedirect("/owner/imou-devices?m=" + msg)
    return page(request, "owner/imou_devices.html",
                {"L": lab, "rows": rows_for(request.owner, lang), "on": CC.enabled("imou"),
                 "consent": V.CONSENT_TEXT[0] if lang == "bn" else V.CONSENT_TEXT[1],
                 "err": err, "usage": _usage(lang)}, nav="imou_devices")


def _lat_text(last, lats, lang):
    if lang == "bn":
        bd = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
        return ("শেষ %.1f সে. · মাঝামাঝি %.1f সে. · %dটি সতর্কতা" % (
            last, lats[len(lats) // 2], len(lats))).translate(bd)
    return "last %.1f s · median %.1f s · %d alerts" % (last, lats[len(lats) // 2], len(lats))


def _usage(lang):
    """imou-real: this month's free-quota use (requests / pushes / data)."""
    try:
        from core.logic.cctv_connect import quota as Q
        return Q.text("imou", lang)
    except Exception:  # noqa: BLE001
        return ""
