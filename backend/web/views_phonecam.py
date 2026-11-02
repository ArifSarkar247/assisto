"""cctvphone: landing for the phone-camera pairing QR
(https://lifeassisto.com/pc/<code>). With Assisto installed the Android App
Link opens the app straight on the pairing screen; this page is only the
fallback (no app / old phone): it shows the code to type. Bilingual, no
login, noindex, no-store. Reveals nothing about the owner."""
from django.http import HttpResponse
from django.utils.html import escape

from core.logic import phonecam as PC

PLAY = "https://play.google.com/store/apps/details?id=com.assisto.assisto"


def pair_landing(request, code):
    c = PC.normalize_code(code)
    shown = escape(c) if c else ""
    code_html = (f'<p class="code">{shown}</p>' if c else
                 '<p>এই কোডটি ঠিক নয় · This code is not valid</p>')
    html = f"""<!doctype html><html lang="bn"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Assisto ফোন ক্যামেরা</title>
<style>body{{font-family:system-ui,sans-serif;max-width:560px;margin:0 auto;padding:24px 16px;
line-height:1.6;color:#111;background:#fff}}.code{{font-size:34px;font-weight:800;letter-spacing:3px;
text-align:center;padding:12px;border:2px solid #2563eb;border-radius:12px}}
a.btn{{display:block;text-align:center;background:#2563eb;color:#fff;padding:14px;border-radius:10px;
text-decoration:none;font-weight:700;margin:16px 0}}</style></head><body>
<h1>এই ফোনকে Assisto ক্যামেরা বানান</h1>
{code_html}
<ol><li>এই ফোনে Assisto ইনস্টল করুন (নিচের বোতাম)।</li>
<li>Assisto খুলুন → পাহারাদার → "এই ফোনকে ক্যামেরা বানান" → উপরের কোড লিখুন।</li></ol>
<a class="btn" href="{PLAY}">Assisto ইনস্টল করুন · Install Assisto</a>
<hr><h2>Make this phone an Assisto camera</h2>
<ol><li>Install Assisto on this phone.</li>
<li>Open Assisto → Watchman → "Use this phone as a camera" → type the code above.</li></ol>
<p>The code works for about 10 minutes and only once.</p></body></html>"""
    resp = HttpResponse(html)
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Cache-Control"] = "no-store"
    return resp
