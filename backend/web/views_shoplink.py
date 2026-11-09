"""bizai: landing for a shop's chat link (https://lifeassisto.com/shop/<code>).
With Assisto installed the Android App Link opens the shop chat in the app;
this page is only the fallback: the shop's name, the honest note that the
shop's AI assistant answers (not end-to-end encrypted) and the install
button. No login, noindex, no-store; reveals nothing but the shop name."""
from django.http import HttpResponse
from django.utils.html import escape

from core import bizai_service as BA

PLAY = "https://play.google.com/store/apps/details?id=com.assisto.assisto"


def shop_landing(request, code):
    b = BA.business_for_code(code)
    ok = b is not None and BA.chat_open(b)[0]
    name = escape((b.shop_name if b else "") or "Assisto")
    head = (f"<h1>{name}</h1><p>এই দোকানের সাথে Assisto অ্যাপে চ্যাট করুন · "
            f"Chat with this shop in the Assisto app</p>") if ok else \
        "<h1>Assisto</h1><p>এই লিংকটি এখন চালু নেই · This link is not active now</p>"
    html = f"""<!doctype html><html lang="bn"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{name} · Assisto</title>
<style>body{{font-family:system-ui,sans-serif;max-width:560px;margin:0 auto;padding:24px 16px;
line-height:1.6;color:#111;background:#fff}}a.btn{{display:block;text-align:center;background:#2563eb;
color:#fff;padding:14px;border-radius:10px;text-decoration:none;font-weight:700;margin:16px 0}}
.note{{font-size:14px;color:#374151}}</style></head><body>
{head}
<a class="btn" href="{PLAY}">Assisto ইনস্টল করুন · Install Assisto</a>
<p class="note">{escape(BA.DISCLOSURE["bn"])}</p>
<p class="note">{escape(BA.DISCLOSURE["en"])}</p></body></html>"""
    resp = HttpResponse(html, status=200 if ok else 404)
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Cache-Control"] = "no-store"
    return resp
