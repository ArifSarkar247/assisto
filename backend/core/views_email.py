"""emailrel (16 Nov): one-click unsubscribe for bulk email (reports,
digests). GET shows a confirm page (link scanners never unsubscribe anyone);
POST (the page button or RFC 8058 List-Unsubscribe-Post) records it. Codes
and security mail are never affected. The token carries only the address
hash + mask (signed), never the address."""
from html import escape

from django.core import signing
from django.http import HttpResponse
from django.views.decorators.csrf import csrf_exempt

_PAGE = """<!doctype html><html lang="bn"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Assisto</title>
<style>body{font-family:'Noto Sans Bengali','Segoe UI',Roboto,Arial,sans-serif;
margin:0;padding:24px 16px;background:#F3F4F6;color:#111827}
.c{max-width:520px;margin:auto;background:#fff;border-radius:16px;padding:24px}
h1{font-size:20px;margin:0 0 12px}p{line-height:1.6}
button{min-height:48px;padding:12px 22px;border:0;border-radius:10px;
background:#3B82F6;color:#fff;font-size:16px;font-weight:700}
@media (prefers-color-scheme:dark){body{background:#0B1220;color:#E5E7EB}
.c{background:#111827}}</style></head><body><div class="c">%s</div></body></html>"""


def _read(token):
    try:
        d = signing.loads(token or "", salt="assisto.email.unsub")
        return d if isinstance(d, dict) and len(str(d.get("h", ""))) == 64 else None
    except signing.BadSignature:
        return None


@csrf_exempt
def unsubscribe(request):
    from .models import EmailSuppression
    token = request.POST.get("t") or request.GET.get("t") or ""
    d = _read(token)
    if d is None:
        return HttpResponse(_PAGE % (
            "<h1>লিংকটি কাজ করছে না / This link doesn't work</h1>"
            "<p>অ্যাপের সেটিংস থেকে ইমেইল বন্ধ করুন। / Turn emails off in the app settings.</p>"),
            status=400)
    masked = escape(str(d.get("m") or ""))
    if request.method == "POST":
        row, made = EmailSuppression.objects.get_or_create(
            to_hash=d["h"], defaults={"to_masked": str(d.get("m") or "")[:80],
                                      "reason": "unsubscribed"})
        return HttpResponse(_PAGE % (
            "<h1>বন্ধ হয়েছে / Unsubscribed</h1><p>%s-এ রিপোর্ট ও এমন ইমেইল আর যাবে না। "
            "লগইন কোড ও নিরাপত্তা ইমেইল তবুও আসবে।</p><p>%s won't get reports and "
            "similar emails any more. Sign-in codes and security emails still come.</p>"
            % (masked, masked)))
    return HttpResponse(_PAGE % (
        "<h1>ইমেইল বন্ধ করবেন? / Unsubscribe?</h1>"
        "<p>%s-এ রিপোর্ট ও এমন ইমেইল বন্ধ হবে (কোড ও নিরাপত্তা ইমেইল চলবে)।<br>"
        "Reports and similar emails to %s will stop (codes and security emails continue).</p>"
        "<form method=\"post\"><input type=\"hidden\" name=\"t\" value=\"%s\">"
        "<button type=\"submit\">বন্ধ করুন / Unsubscribe</button></form>"
        % (masked, masked, escape(token, quote=True))))
