"""channels (2 Nov): web fallback pages for shared channel / community links.

https://lifeassisto.com/ch/<handle>[?k=<code>] and /cm/<code>. With Assisto
installed the Android App Link opens the app straight on the channel /
community; this page is what everyone else sees: the name, a short line, an
"Open in Assisto" button (Android intent link: opens the app if installed,
else the Play listing) and "Get the app". A private channel shows nothing
without its code; never a phone number or a follower name."""
from django.http import HttpResponse
from django.utils.html import escape

from core import channels_service as CS


def _page(title_bn, title_en, line_bn, line_en, path, found=True):
    play = CS.play_url()
    pkg = play.split("id=", 1)[-1].split("&", 1)[0]
    intent = ("intent://lifeassisto.com%s#Intent;scheme=https;package=%s;"
              "S.browser_fallback_url=%s;end" % (path, pkg, play))
    btn = ('<p><a class="b" href="%s">Assisto-তে খুলুন / Open in Assisto</a></p>'
           % escape(intent)) if found else ""
    html = """<!doctype html><html lang="bn"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Assisto — %(te)s</title>
<style>body{font-family:system-ui,sans-serif;max-width:560px;margin:auto;padding:24px;line-height:1.55;color:#0f172a}
a.b{display:inline-block;background:#2563eb;color:#fff;padding:14px 20px;border-radius:12px;text-decoration:none;font-weight:600}
a.g{color:#2563eb}.m{color:#475569}</style></head><body>
<h2>%(tb)s</h2><p class="m">%(lb)s</p><h3>%(te)s</h3><p class="m">%(le)s</p>
%(btn)s<p><a class="g" href="%(play)s">অ্যাপ নিন (Google Play) / Get the app</a></p>
</body></html>""" % {"tb": escape(title_bn), "te": escape(title_en),
                     "lb": escape(line_bn), "le": escape(line_en),
                     "btn": btn, "play": escape(play)}
    return HttpResponse(html, status=200 if found else 404)


def channel_link(request, handle):
    from core.logic import msg_channel as mch
    from core.models import Channel
    h = mch.sanitize_handle(handle)
    ch = Channel.objects.filter(handle=h).first() if h else None
    k = str(request.GET.get("k", ""))[:32]
    ok = ch is not None and ch.content_status != "removed" and (
        CS.listed(ch) or (ch.invite_code and k == ch.invite_code))
    if not ok:
        return _page("চ্যানেলটি পাওয়া যায়নি", "Channel not found",
                     "লিংকটি ভুল, পুরোনো বা চ্যানেলটি প্রাইভেট।",
                     "The link is wrong, old, or the channel is private.",
                     "/ch/", found=False)
    path = "/ch/%s" % ch.handle + ("?k=%s" % k if k else "")
    return _page(
        "%s — Assisto চ্যানেল" % ch.name, "%s — an Assisto channel" % ch.name,
        "%s · %s জন ফলো করছেন" % (ch.description or "@" + ch.handle,
                                  ch.follower_count),
        "%s · %s followers" % (ch.description or "@" + ch.handle,
                               ch.follower_count), path)


def community_link(request, code):
    from core.models import Community
    c = Community.objects.filter(
        invite_code="".join(x for x in code.lower() if x in CS.CODE_ALPHABET)[:16]
    ).first() if code else None
    if c is None:
        return _page("কমিউনিটি পাওয়া যায়নি", "Community not found",
                     "লিংকটি ভুল বা পুরোনো — নতুন লিংক চেয়ে নিন।",
                     "The link is wrong or old — ask for a new one.",
                     "/cm/", found=False)
    return _page(
        "%s — Assisto কমিউনিটি" % c.name, "%s — an Assisto community" % c.name,
        "যোগ দিতে অ্যাপে খুলুন — অ্যাডমিন অনুমতি দিলে আপনি ভেতরে।",
        "Open in the app to ask to join — you're in once an admin approves.",
        "/cm/%s" % c.invite_code)
