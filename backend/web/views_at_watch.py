"""
antitheft2 (owner 27 Oct) — the trusted contact's WEB view of a protected
phone: GET /w/phone/<signed token>.

The link is put on every anti-theft alert a trusted contact receives. It is
signed, bound to that ONE viewer, expires after 7 days and stops working as
soon as the owner removes that person from the alert list (can_view is
re-checked on every load). It shows only what the app shows the same person:
the last known location (time + accuracy) and the recent alert history.
Never indexed, never cached.
"""
from django.http import Http404
from django.shortcuts import render
from django.utils import timezone

from core import views_antitheft as atv
from core.logic import antitheft as at

KIND_LABELS = {
    "snatch": ("Sudden grab and fast movement", "হঠাৎ টান ও দ্রুত নড়াচড়া"),
    "snatch_cleared": ("Unlocked by the owner", "মালিক আনলক করেছেন"),
    "sim_change": ("SIM changed", "সিম পরিবর্তন"),
    "offline": ("Went offline", "অফলাইন হয়েছে"),
    "online": ("Back online", "আবার অনলাইন"),
    "low_battery": ("Battery low", "চার্জ কম"),
    "shutdown": ("Switching off", "বন্ধ হচ্ছে"),
    "boot": ("Restarted", "রিস্টার্ট হয়েছে"),
    "failed_unlock": ("Wrong unlock attempts", "ভুল আনলক চেষ্টা"),
    "intruder_photo": ("Wrong unlock attempts (photo saved)",
                       "ভুল আনলক চেষ্টা (ছবি সংরক্ষিত)"),
    "went_dark": ("Stopped checking in", "তথ্য আসা বন্ধ"),
    "test": ("Test alert", "পরীক্ষামূলক সতর্কবার্তা"),
}


def _when(dt):
    return timezone.localtime(dt).strftime("%d %b %Y, %I:%M %p") if dt else ""


def phone_page(request, token):
    phone, viewer = atv.watch_resolve(token)
    if phone is None:
        raise Http404
    en = (getattr(viewer, "language", "bn") or "bn") == "en"
    if request.GET.get("lang") in ("bn", "en"):
        en = request.GET["lang"] == "en"
    eng = atv._engine(phone, create=False)
    loc = atv.best_location(phone, eng, None)
    loc_en, loc_bn = at.location_text(loc, timezone.now())
    rows = []
    for ev in phone.engine_events.exclude(data__has_key="suppressed").exclude(
            escalate_at__isnull=False, alerted=False)[:30]:
        if (ev.data or {}).get("false_alarm"):
            continue
        lab = KIND_LABELS.get(ev.kind, (ev.kind, ev.kind))
        evloc = atv.best_location(phone, eng, ev) if ev.lat is not None else None
        rows.append({
            "label": lab[0] if en else lab[1],
            "when": _when(ev.at),
            "late": ev.late,
            "map": at._map(ev.lat, ev.lng),
            "acc": at._acc_txt(ev.accuracy_m),
            "fix": _when(ev.fix_at) if evloc and ev.fix_at else "",
        })
    from core import push
    ctx = {
        "lang": "en" if en else "bn",
        "en": en,
        "owner": push.display_name(phone.owner),
        "loc_line": loc_en if en else loc_bn,
        "map": at._map(loc.get("lat"), loc.get("lng")),
        "lost_mode": phone.lost_mode,
        "rows": rows,
        "now": _when(timezone.now()),
    }
    resp = render(request, "web/at_watch.html", ctx)
    resp["Cache-Control"] = "private, no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Referrer-Policy"] = "no-referrer"
    return resp
