"""flag-vehicle (owner 17 Nov): Owner Admin -> Tracker packets. The last 50
raw packets the tracker server saw (tracker/rawlog.py): time (Dhaka), the
device id masked except its last 4 digits, protocol, paired or not, parsed
fields or the parse error, and the raw hex — so the first real ST-906 can be
proven (or fixed) the same day. Read-only; the log keeps 72 h at most."""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from django.views.decorators.http import require_http_methods

from .base import owner_view, page

DHAKA = ZoneInfo("Asia/Dhaka")

L = {
    "bn": {"title": "ট্র্যাকার প্যাকেট",
           "intro": "ট্র্যাকার সার্ভারে (পোর্ট ৫০২৩) আসা শেষ ৫০টি কাঁচা প্যাকেট। ID-র শেষ ৪ অঙ্ক ছাড়া বাকিটা ঢাকা। "
                    "\"পেয়ার করা নেই\" মানে অ্যাপে ID ভুল লেখা বা পেয়ার-জানালা শেষ। ৭২ ঘণ্টা পর নিজে মুছে যায়।",
           "none": "গত ৭২ ঘণ্টায় কোনো প্যাকেট আসেনি। ট্র্যাকারে সার্ভার SMS (8040000 16.4.105.173 5023) ও 7100000 পাঠিয়েছেন? সিমে ডেটা আছে?",
           "time": "সময় (ঢাকা)", "id": "ডিভাইস ID", "proto": "প্রোটোকল", "known": "পেয়ার",
           "parsed": "পড়া তথ্য", "error": "ভুল", "raw": "কাঁচা (hex)", "yes": "হ্যাঁ", "no": "পেয়ার করা নেই",
           "count": "মোট"},
    "en": {"title": "Tracker packets",
           "intro": "The last 50 raw packets the tracker server (port 5023) received. Device ids are masked "
                    "except the last 4 digits. \"Not paired\" means the id was typed wrong in the app or the "
                    "pairing window ended. Deleted automatically after 72 hours.",
           "none": "No packet in the last 72 hours. Did the tracker get the server SMS "
                   "(8040000 16.4.105.173 5023) and 7100000? Does the SIM have data?",
           "time": "Time (Dhaka)", "id": "Device id", "proto": "Protocol", "known": "Paired",
           "parsed": "Parsed", "error": "Error", "raw": "Raw (hex)", "yes": "yes", "no": "not paired",
           "count": "Total"},
}


def _parsed_text(f):
    if not f:
        return ""
    parts = [str(f.get("kind") or "")]
    if "lat" in f and "lng" in f:
        parts.append("%.5f, %.5f" % (float(f["lat"]), float(f["lng"])))
    if "speed_kmh" in f:
        parts.append("%s km/h" % f["speed_kmh"])
    if "ignition" in f:
        parts.append("ACC %s" % ("on" if f["ignition"] else "off"))
    if f.get("valid") is False:
        parts.append("no GPS fix")
    for k in ("alarms", "status", "text", "at"):
        if f.get(k):
            parts.append("%s=%s" % (k, f[k]))
    return " · ".join(p for p in parts if p)


def rows(n=50):
    from tracker import rawlog
    out = []
    for e in rawlog.recent(n):
        try:
            t = datetime.fromtimestamp(float(e.get("ts") or 0), tz=timezone.utc).astimezone(DHAKA)
        except (TypeError, ValueError, OverflowError):
            continue
        out.append({"time": t.strftime("%d %b %H:%M:%S"), "id": rawlog.mask(e.get("imei")),
                    "proto": e.get("proto") or "", "known": e.get("known"),
                    "parsed": _parsed_text(e.get("fields") or {}),
                    "error": e.get("error") or "", "len": e.get("len") or 0,
                    "hex": (e.get("hex") or "")[:160]})
    return out


@require_http_methods(["GET"])
@owner_view()
def tracker_packets(request):
    lang = getattr(request, "owner_lang", "bn")
    r = rows()
    return page(request, "owner/tracker_packets.html",
                {"L": L.get(lang, L["bn"]), "rows": r, "n": len(r)}, nav="tracker_packets")
