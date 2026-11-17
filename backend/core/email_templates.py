"""
emailrel (16 Nov): branded Bangla + English email templates.

    render_otp(code, lang, ttl_seconds)                -> (subject, text, html)
    render_notice(lang, title_bn, title_en, body_bn, body_en,
                  action_url="", action_bn="", action_en="",
                  unsubscribe_url="")                  -> (subject, text, html)

Rules (owner design standards): the user's language first, the other one
below a divider; no images, no remote fonts, no tracking pixels, no link in a
code email; table layout + inline styles (Gmail / Outlook / Apple Mail);
dark-mode safe (color-scheme meta + prefers-color-scheme block, and colours
that stay readable when a client inverts them); a plain-text part always
goes with the HTML; bulk mail (reports) carries an unsubscribe line.
Stdlib only, so `python3 -m core.email_templates` can write previews.
"""
from html import escape

BRAND_GRAD = "linear-gradient(90deg,#06B6D4 0%,#3B82F6 50%,#8B5CF6 100%)"
BRAND_SOLID = "#3B82F6"           # fallback where gradients are not drawn
FOOTER_BN = "Assisto — Axon Dynamics"
FOOTER_EN = "Assisto by Axon Dynamics"
AUTO_BN = "এটি স্বয়ংক্রিয় ইমেইল, উত্তর দেবেন না।"
AUTO_EN = "This is an automated email; please don't reply."
FONT = ("'Noto Sans Bengali','Hind Siliguri','Segoe UI',Roboto,Helvetica,"
        "Arial,sans-serif")
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(s):
    return str(s).translate(_BN)


_CSS = """
:root{color-scheme:light dark;supported-color-schemes:light dark}
body{margin:0;padding:0;background:#F3F4F6}
.bg{background:#F3F4F6}
.card{background:#FFFFFF;color:#111827}
.mut{color:#4B5563}
.code{background:#EEF2FF;color:#1E1B4B;border:1px solid #C7D2FE}
.hr{border-top:1px solid #E5E7EB}
.btn{background:#3B82F6;color:#FFFFFF}
.foot{color:#6B7280}
a{color:#2563EB}
@media (prefers-color-scheme: dark){
 body,.bg{background:#0B1220!important}
 .card{background:#111827!important;color:#E5E7EB!important}
 .mut{color:#C3CAD5!important}
 .code{background:#1E1B4B!important;color:#E0E7FF!important;border-color:#4338CA!important}
 .hr{border-top-color:#374151!important}
 .foot{color:#9CA3AF!important}
 a{color:#93C5FD!important}
}
[data-ogsc] .card{background:#111827!important;color:#E5E7EB!important}
[data-ogsc] .mut{color:#C3CAD5!important}
"""


def _paras(text, cls="", lang="bn", size=15):
    out = []
    for p in [p for p in str(text or "").split("\n\n") if p.strip()]:
        out.append('<p lang="%s" class="%s" style="margin:0 0 12px;font-size:%dpx;'
                   'line-height:1.6">%s</p>'
                   % (lang, cls, size, escape(p.strip()).replace("\n", "<br>")))
    return "".join(out)


def _block(lang, title, body, code="", code_label="", action_url="", action="",
           secondary=False):
    size = 14 if secondary else 15
    h = ['<h1 lang="%s" style="margin:0 0 12px;font-size:%dpx;line-height:1.35;'
         'font-weight:700">%s</h1>' % (lang, 17 if secondary else 21, escape(title))]
    if code:
        h.append('<p lang="%s" class="mut" style="margin:0 0 6px;font-size:13px">%s</p>'
                 % (lang, escape(code_label)))
        h.append('<div class="code" style="display:inline-block;padding:12px 20px;'
                 'border-radius:12px;font-family:\'SFMono-Regular\',Menlo,Consolas,'
                 'monospace;font-size:30px;font-weight:700;letter-spacing:6px;'
                 'background:#EEF2FF;color:#1E1B4B;border:1px solid #C7D2FE;'
                 'margin:0 0 14px" aria-label="%s">%s</div>'
                 % (escape(" ".join(code)), escape(code)))
    h.append(_paras(body, lang=lang, size=size))
    if action_url and action and not secondary:
        h.append('<p style="margin:6px 0 14px"><a class="btn" href="%s" '
                 'style="display:inline-block;padding:12px 22px;border-radius:10px;'
                 'background:#3B82F6;color:#FFFFFF;text-decoration:none;'
                 'font-weight:700;font-size:15px;min-height:24px">%s</a></p>'
                 % (escape(action_url, quote=True), escape(action)))
    elif action_url and secondary:
        h.append('<p class="mut" style="margin:0 0 12px;font-size:13px;'
                 'word-break:break-all">%s</p>' % escape(action_url))
    return "".join(h)


def _page(lang, preheader, first, second, unsubscribe_url=""):
    unsub = ""
    if unsubscribe_url:
        unsub = ('<p class="foot" style="margin:8px 0 0;font-size:12px">'
                 '<a href="%s">এই ধরনের ইমেইল আর চাই না / Unsubscribe</a> — '
                 'কোড ও নিরাপত্তা ইমেইল তবুও আসবে / security emails still come.</p>'
                 % escape(unsubscribe_url, quote=True))
    return (
        '<!doctype html><html lang="%(lang)s"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="color-scheme" content="light dark">'
        '<meta name="supported-color-schemes" content="light dark">'
        '<title>Assisto</title><style>%(css)s</style></head>'
        '<body class="bg" style="margin:0;padding:0;background:#F3F4F6">'
        '<div style="display:none;max-height:0;overflow:hidden;opacity:0">%(pre)s</div>'
        '<table role="presentation" class="bg" width="100%%" cellpadding="0" '
        'cellspacing="0" style="background:#F3F4F6"><tr><td align="center" '
        'style="padding:24px 12px">'
        '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" '
        'style="max-width:560px;border-radius:16px;overflow:hidden">'
        '<tr><td style="background:%(solid)s;background-image:%(grad)s;'
        'padding:18px 24px;color:#FFFFFF;font-family:%(font)s;font-size:22px;'
        'font-weight:800;letter-spacing:.3px">Assisto</td></tr>'
        '<tr><td class="card" style="background:#FFFFFF;color:#111827;'
        'padding:24px;font-family:%(font)s">%(first)s'
        '<div class="hr" style="border-top:1px solid #E5E7EB;margin:18px 0"></div>'
        '%(second)s</td></tr>'
        '<tr><td class="bg" style="padding:14px 8px;font-family:%(font)s;'
        'text-align:center"><p class="foot" style="margin:0;font-size:12px;'
        'line-height:1.6;color:#6B7280">%(fbn)s · %(fen)s<br>%(abn)s / %(aen)s</p>'
        '%(unsub)s</td></tr></table></td></tr></table></body></html>'
        % {"lang": "en" if lang == "en" else "bn", "css": _CSS,
           "pre": escape(preheader), "solid": BRAND_SOLID, "grad": BRAND_GRAD,
           "font": FONT, "first": first, "second": second,
           "fbn": escape(FOOTER_BN), "fen": escape(FOOTER_EN),
           "abn": escape(AUTO_BN), "aen": escape(AUTO_EN), "unsub": unsub})


def _text(lang, bn, en, unsubscribe_url=""):
    body = (en + "\n\n— — —\n\n" + bn) if lang == "en" else (bn + "\n\n— — —\n\n" + en)
    body += "\n\n—\n%s\n%s\n%s / %s" % (FOOTER_BN, FOOTER_EN, AUTO_BN, AUTO_EN)
    if unsubscribe_url:
        body += ("\nএই ধরনের ইমেইল আর না চাইলে / Unsubscribe: %s" % unsubscribe_url)
    return body


# ------------------------------------------------------------------ OTP
def otp_texts(code, ttl_seconds):
    mins = max(1, int(ttl_seconds) // 60)
    bn = ("আপনার Assisto যাচাই কোড: %s\n\n"
          "কোডটি %s মিনিট পর্যন্ত কাজ করবে। কাউকে এই কোড বলবেন না — "
          "Assisto কখনো ফোন বা মেসেজে এই কোড চায় না।\n"
          "আপনি এই কোড না চাইলে এই ইমেইলটি উপেক্ষা করুন; আপনার অ্যাকাউন্ট নিরাপদ আছে।"
          % (code, bn_digits(mins)))
    en = ("Your Assisto verification code: %s\n\n"
          "It works for %d minutes. Never share this code — Assisto will never "
          "ask for it by phone or message.\n"
          "If you didn't ask for this code, ignore this email; your account is safe."
          % (code, mins))
    return bn, en, mins


def render_otp(code, lang, ttl_seconds):
    bn, en, mins = otp_texts(code, ttl_seconds)
    footer = ("\n\n—\n%s\n%s\n%s / %s" % (FOOTER_BN, FOOTER_EN, AUTO_BN, AUTO_EN))
    if lang == "en":
        subject = "Your Assisto code: %s" % code
        text = en + "\n\n— — —\n\n" + bn + footer
    else:
        subject = "Assisto কোড: %s / Your Assisto code" % code
        text = bn + "\n\n— — —\n\n" + en + footer
    body_bn = ("কোডটি %s মিনিট পর্যন্ত কাজ করবে। কাউকে এই কোড বলবেন না — Assisto "
               "কখনো ফোন বা মেসেজে এই কোড চায় না।\n\nআপনি এই কোড না চাইলে ইমেইলটি "
               "উপেক্ষা করুন; আপনার অ্যাকাউন্ট নিরাপদ আছে।" % bn_digits(mins))
    body_en = ("It works for %d minutes. Never share this code — Assisto will never "
               "ask for it by phone or message.\n\nIf you didn't ask for this code, "
               "ignore this email; your account is safe." % mins)
    b_bn = _block("bn", "আপনার যাচাই কোড", body_bn, code=code, code_label="যাচাই কোড",
                  secondary=(lang == "en"))
    b_en = _block("en", "Your verification code", body_en, code=code,
                  code_label="Verification code", secondary=(lang != "en"))
    first, second = (b_en, b_bn) if lang == "en" else (b_bn, b_en)
    pre = ("Code %s · %d min" % (code, mins)) if lang == "en" else \
        ("কোড %s · %s মিনিট" % (code, bn_digits(mins)))
    return subject, text, _page(lang, pre, first, second)


# ------------------------------------------------------------------ notices
def render_notice(lang, title_bn, title_en, body_bn, body_en, action_url="",
                  action_bn="", action_en="", unsubscribe_url="", subject=None):
    """Security alerts, account notices, owner alerts, reset links, reports."""
    if subject is None:
        subject = ("Assisto: %s" % title_en) if lang == "en" else \
            ("Assisto: %s / %s" % (title_bn, title_en))
    tb = body_bn + (("\n\n%s:\n%s" % (action_bn or "লিংক", action_url)) if action_url else "")
    te = body_en + (("\n\n%s:\n%s" % (action_en or "Link", action_url)) if action_url else "")
    text = _text(lang, "%s\n\n%s" % (title_bn, tb), "%s\n\n%s" % (title_en, te),
                 unsubscribe_url)
    b_bn = _block("bn", title_bn, body_bn, action_url=action_url, action=action_bn,
                  secondary=(lang == "en"))
    b_en = _block("en", title_en, body_en, action_url=action_url, action=action_en,
                  secondary=(lang != "en"))
    first, second = (b_en, b_bn) if lang == "en" else (b_bn, b_en)
    pre = (title_en if lang == "en" else title_bn)[:90]
    return subject, text, _page(lang, pre, first, second, unsubscribe_url)


def _previews():
    """{filename: html} — sample data only (made-up code / link)."""
    out = {}
    for lang in ("bn", "en"):
        out["otp_%s.html" % lang] = render_otp("482913", lang, 300)[2]
        out["security_%s.html" % lang] = render_notice(
            lang, "আপনার ইমেইল বদলানো হয়েছে", "Your email was changed",
            "আপনার Assisto অ্যাকাউন্টের ইমেইল বদলানো হয়েছে (নতুন: ra••••@example.com)।\n\n"
            "আপনি করে থাকলে কিছু করতে হবে না। আপনি না করলে নিচের বোতাম চাপুন।",
            "The email on your Assisto account was changed (new: ra••••@example.com).\n\n"
            "If this was you, there is nothing to do. If not, tap the button below.",
            action_url="https://lifeassisto.com/r/sample-not-me",
            action_bn="এটা আমি নই", action_en="This was not me")[2]
        out["report_%s.html" % lang] = render_notice(
            lang, "এই সপ্তাহের ব্যবসার হিসাব", "Your weekly business summary",
            "বিক্রি: ৳১২,৪০০ · বাকি আদায়: ৳৩,২০০\n\nবিস্তারিত অ্যাপে দেখুন।",
            "Sales: ৳12,400 · Dues collected: ৳3,200\n\nSee the details in the app.",
            unsubscribe_url="https://lifeassisto.com/api/v1/email/unsubscribe?t=sample")[2]
    return out


if __name__ == "__main__":       # python3 -m core.email_templates <outdir>
    import os
    import sys
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(d, exist_ok=True)
    for name, html in _previews().items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(html)
    print("\n".join(sorted(_previews())))
