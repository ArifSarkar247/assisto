"""fcelder: landing for the elder-setup QR (https://lifeassisto.com/e/<code>).
With Assisto installed the Android App Link opens the app straight on the
spoken consent screen; this page is only the fallback (no app yet): install,
then type the code. Bilingual, no login, noindex, no-store. Reveals nothing
about the family (the code alone is not enough: it only works for the one
chosen account, once, for 15 minutes)."""
from django.http import HttpResponse
from django.utils.html import escape

PLAY = "https://play.google.com/store/apps/details?id=com.assisto.assisto"
_ALPHA = set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")


def _norm(code):
    c = "".join(ch for ch in (code or "").upper() if ch.isalnum())
    return c if len(c) == 8 and set(c) <= _ALPHA else ""


def setup_landing(request, code):
    c = _norm(code)
    code_html = (f'<p class="code">{escape(c)}</p>' if c else
                 '<p>এই কোডটি ঠিক নয় · This code is not valid</p>')
    html = f"""<!doctype html><html lang="bn"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Assisto — বাবা-মার ফোন সেটআপ</title>
<style>body{{font-family:system-ui,sans-serif;max-width:560px;margin:0 auto;padding:24px 16px;
line-height:1.7;color:#111;background:#fff;font-size:19px}}.code{{font-size:36px;font-weight:800;
letter-spacing:4px;text-align:center;padding:12px;border:3px solid #1E7A50;border-radius:12px}}
a.btn{{display:block;text-align:center;background:#1E7A50;color:#fff;padding:16px;border-radius:12px;
text-decoration:none;font-weight:700;margin:16px 0}}</style></head><body>
<h1>এই ফোনটা সহজ করে দিন</h1>
{code_html}
<ol><li>এই ফোনে Assisto ইনস্টল করুন (নিচের বোতাম), নিজের নম্বর দিয়ে ঢুকুন।</li>
<li>Assisto খুলুন → পরিবার → "আমার ফোন সেটআপ (সন্তানের QR)" → উপরের কোড লিখুন।</li>
<li>সম্মতির কথা শুনে বড় "হ্যাঁ" চাপুন।</li></ol>
<a class="btn" href="{PLAY}">Assisto ইনস্টল করুন · Install Assisto</a>
<hr><h2>Set up this phone the easy way</h2>
<ol><li>Install Assisto on this phone and sign in with this phone's own number.</li>
<li>Open Assisto → Family → "Set up my phone (child's QR)" → type the code above.</li>
<li>Listen to the consent and tap the big "Yes".</li></ol>
<p>The code works for 15 minutes, once, and only for the person it was made for.</p></body></html>"""
    resp = HttpResponse(html)
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Cache-Control"] = "no-store"
    return resp
