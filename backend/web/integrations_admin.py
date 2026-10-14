"""
Owner-only Integrations admin page (server-rendered, Django session auth).

One card per integration: what it unlocks, bn/en setup guide, paste fields,
Test button, status. Secrets are never shown back in full. Rate-limited login,
audit-logged. Reachable at /admin/integrations on assisto.asalify.com.
"""
import html as _html
import time

from django.contrib.auth import authenticate, login as dj_login, logout as dj_logout
from django.http import HttpResponse, HttpResponseRedirect
from django.middleware.csrf import get_token
from django.views.decorators.http import require_http_methods

from core import integrations as I
from core.models import AuditLog

_LOGIN_FAILS = {}  # ip -> (count, first_ts)  simple in-process throttle


def _ip(request):
    xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
    return (xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR", "")) or "?"


def _throttled(ip):
    c, t0 = _LOGIN_FAILS.get(ip, (0, time.time()))
    if time.time() - t0 > 900:  # reset window 15 min
        _LOGIN_FAILS[ip] = (0, time.time())
        return False
    return c >= 8


def _page(body, token, lang="bn"):
    t = {
        "bn": ("Integrations · Assisto", "মালিক-অ্যাডমিন", "লগআউট"),
        "en": ("Integrations · Assisto", "Owner admin", "Log out"),
    }[lang]
    return f"""<!doctype html><html lang="{lang}"><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>{t[0]}</title>
<style>
:root{{--bg:#0a0c14;--card:#14161d;--line:#242734;--fg:#e7e9ee;--mut:#9aa0ad;
--blue:#3b6ef6;--cyan:#22d3ee;--purple:#9b4df0;--ok:#2e9e6b;--bad:#e0485a;--warn:#e0a500}}
*{{box-sizing:border-box}}body{{font-family:system-ui,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:20px;max-width:900px;margin:0 auto}}
h1{{font-size:20px;background:linear-gradient(90deg,var(--cyan),var(--blue),var(--purple));-webkit-background-clip:text;background-clip:text;color:transparent}}
.sub{{color:var(--mut);font-size:13px;margin-top:-6px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin:16px 0}}
.card h3{{margin:0 0 4px}}.cat{{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.5px}}
.unlocks{{color:var(--fg);font-size:13px;margin:6px 0}}
.guide{{color:var(--mut);font-size:12px;margin:6px 0;padding-left:16px}}
label{{display:block;font-size:12px;color:var(--mut);margin:8px 0 2px}}
input{{width:100%;padding:9px 11px;border-radius:9px;border:1px solid var(--line);background:#0e1017;color:var(--fg)}}
.row{{display:flex;gap:8px;margin-top:12px;align-items:center;flex-wrap:wrap}}
button{{padding:9px 16px;border-radius:9px;border:0;font-weight:700;cursor:pointer}}
.save{{background:var(--blue);color:#fff}}.test{{background:#1b2130;color:var(--fg);border:1px solid var(--line)}}
.pill{{font-size:11px;font-weight:700;padding:3px 9px;border-radius:999px}}
.s-working{{background:rgba(46,158,107,.18);color:#5fd6a0}}
.s-failing{{background:rgba(224,72,90,.18);color:#ff8a98}}
.s-not_set{{background:#1b2130;color:var(--mut)}}
.detail{{font-size:12px;color:var(--mut)}}.set{{color:#5fd6a0}}
a{{color:var(--cyan)}}
.dash{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin:16px 0}}
.stats{{display:flex;gap:10px;flex-wrap:wrap}}
.stat{{flex:1;min-width:90px;background:#0e1017;border:1px solid var(--line);border-radius:12px;padding:12px;text-align:center}}
.stat b{{display:block;font-size:26px;line-height:1}}.stat span{{font-size:11px;color:var(--mut)}}
.stat.ok b{{color:#5fd6a0}}.stat.bad b{{color:#ff8a98}}.stat.mut b{{color:var(--mut)}}.stat.tot b{{color:var(--cyan)}}
.catlabel{{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.5px;margin:14px 0 6px}}
.cats{{display:flex;gap:8px;flex-wrap:wrap}}
.catchip{{display:flex;flex-direction:column;gap:4px;text-decoration:none;color:var(--fg);background:#0e1017;border:1px solid var(--line);border-radius:10px;padding:7px 11px;font-size:12px;min-width:120px}}
.catchip b{{color:var(--cyan)}}
.bar{{height:4px;background:#1b2130;border-radius:3px;overflow:hidden}}.bar i{{display:block;height:100%;background:linear-gradient(90deg,var(--cyan),var(--blue))}}
.meta{{display:flex;gap:14px;flex-wrap:wrap;align-items:center;margin:8px 0}}
.doclink{{font-size:12px;color:var(--mut)}}.doclink code{{color:var(--cyan);background:#0e1017;padding:2px 6px;border-radius:6px;font-size:11px}}
details{{margin:6px 0}}summary{{cursor:pointer}}
.banner{{background:rgba(224,165,0,.14);border:1px solid var(--warn);color:#ffcf52;border-radius:12px;padding:12px 14px;margin:16px 0;font-size:13px}}
.banner.err{{background:rgba(224,72,90,.14);border-color:var(--bad);color:#ff8a98}}
</style></head><body>
<div class=row style="justify-content:space-between">
<div><h1>Assisto — Integrations</h1><div class=sub>{t[1]} · key যোগ করলেই ফিচার অটো-চালু / features turn on when a key tests OK</div></div>
<div class=row><a class=test style="text-decoration:none;padding:9px 16px;border-radius:9px;border:1px solid var(--line)" href="?lang={'en' if lang=='bn' else 'bn'}">{'EN' if lang=='bn' else 'বাংলা'}</a>
<form method=post><input type=hidden name=csrfmiddlewaretoken value="{token}">
<input type=hidden name=action value=logout><button class=test>{t[2]}</button></form></div></div>
{body}
<p class=sub>🔒 সব key এনক্রিপ্টেড (Fernet); কখনো পুরো দেখানো হয় না। Secrets encrypted at rest; never shown in full.</p>
</body></html>"""


def _login_page(token, error=""):
    err = f'<p style="color:#ff8a98">{_html.escape(error)}</p>' if error else ""
    return HttpResponse(f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Owner login · Assisto</title>
<style>body{{font-family:system-ui,sans-serif;background:#0a0c14;color:#e7e9ee;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}}
.box{{background:#14161d;border:1px solid #242734;border-radius:16px;padding:28px;width:320px}}
h2{{margin:0 0 4px}}p{{color:#9aa0ad;font-size:13px}}
input{{width:100%;padding:10px;margin:8px 0;border-radius:9px;border:1px solid #242734;background:#0e1017;color:#e7e9ee}}
button{{width:100%;padding:11px;border:0;border-radius:9px;background:#3b6ef6;color:#fff;font-weight:700;margin-top:8px;cursor:pointer}}</style>
<div class=box><h2>Assisto — Owner</h2><p>Integrations admin · owner only</p>{err}
<form method=post><input type=hidden name=csrfmiddlewaretoken value="{token}">
<input type=hidden name=action value=login>
<input name=identifier placeholder="ফোন বা ইমেইল / phone or email" autocomplete=username>
<input name=password type=password placeholder="পাসওয়ার্ড / password" autocomplete=current-password>
<button>Log in</button></form></div>""")


def _dashboard(summary, lang):
    """Top-of-page per-state + per-category roll-up — the advanced KEY STATUS view."""
    c = summary["counts"]
    t = {
        "bn": ("সংযুক্ত", "ঠিক করুন", "সংযুক্ত নয়", "মোট", "বিভাগ অনুযায়ী"),
        "en": ("Connected", "Fix", "Not connected", "Total", "By category"),
    }[lang]
    chips = ""
    for cat, v in sorted(summary["by_category"].items()):
        pct = int(100 * v["connected"] / v["total"]) if v["total"] else 0
        chips += (f'<a class=catchip href="#cat-{_slugify(cat)}">'
                  f'{_html.escape(cat)} <b>{v["connected"]}/{v["total"]}</b>'
                  f'<span class=bar><i style="width:{pct}%"></i></span></a>')
    return f"""<div class=dash>
<div class=stats>
<div class="stat ok"><b>{c['connected']}</b><span>{t[0]}</span></div>
<div class="stat bad"><b>{c['not_working']}</b><span>{t[1]}</span></div>
<div class="stat mut"><b>{c['not_connected']}</b><span>{t[2]}</span></div>
<div class="stat tot"><b>{c['total']}</b><span>{t[3]}</span></div>
</div>
<div class=catlabel>{t[4]}</div>
<div class=cats>{chips}</div></div>"""


def _slugify(s):
    return "".join(ch.lower() if ch.isalnum() else "-" for ch in s)


def _render_cards(lang):
    rows = I.list_all(lang)
    if not rows:  # empty state (Section-21: empty)
        msg = ("কোনো ইন্টিগ্রেশন রেজিস্টার করা নেই।" if lang == "bn"
               else "No integrations are registered yet.")
        return f'<div class=card><p class=detail>{msg}</p></div>'
    cats, out = {}, []
    for r in rows:
        cats.setdefault(r["category"], []).append(r)
    howto = "কীভাবে সংযুক্ত করবেন" if lang == "bn" else "How to connect"
    last_lbl = "সর্বশেষ পরীক্ষা" if lang == "bn" else "Last checked"
    enables_lbl = "যা চালু করে" if lang == "bn" else "Enables"
    for cat, items in sorted(cats.items()):
        out.append(f'<h2 id="cat-{_slugify(cat)}" style="color:#9aa0ad;font-size:14px;margin-top:28px">{_html.escape(cat)}</h2>')
        for r in items:
            st = r["status"]
            guide = "".join(f"<li>{_html.escape(g)}</li>" for g in r["guide"])
            fields = ""
            for f in r["fields"]:
                ph = (f["masked"] if f["set"] else "")
                setmark = ' <span class=set>✓ set</span>' if f["set"] else ""
                fields += (f'<label>{_html.escape(f["label"])}{setmark}</label>'
                           f'<input name="{f["key"]}" placeholder="{_html.escape(str(ph))}" '
                           f'{"type=password" if f["secret"] else ""} autocomplete=off>')
            test_btn = ('<button class=test name=action value=test>Test connection</button>'
                        if r["testable"] else
                        f'<span class=detail>{"Save করলেই সক্রিয় / active on save" if lang=="bn" else "active on save"}</span>')
            detail = _html.escape(r["detail"]) if r["detail"] else ""
            doc = _html.escape(r["doc"])
            last = _html.escape(r["last_tested_human"])
            label = _html.escape(r["status_label"])
            out.append(f"""<div class=card>
<div class=row style="justify-content:space-between"><div>
<div class=cat>{_html.escape(r["category"])}</div><h3>{_html.escape(r["name"])}</h3></div>
<span class="pill s-{st}">{label}</span></div>
<div class=unlocks><strong>{enables_lbl}:</strong> {_html.escape(r["unlocks"])}</div>
<div class=meta><span class=detail>{last_lbl}: {last}</span>
<span class=doclink title="owner note in repo">{howto}: <code>{doc}</code></span></div>
<details><summary class=detail>{howto} ({len(r["guide"])})</summary>
<ul class=guide>{guide}</ul></details>
<form method=post><input type=hidden name=csrfmiddlewaretoken value="__TOK__">
<input type=hidden name=slug value="{r['slug']}">
{fields}
<div class=row><button class=save name=action value=save>Save</button>{test_btn}
<span class=detail>{detail}</span></div></form></div>""")
    return "".join(out)


@require_http_methods(["GET", "POST"])
def integrations_admin(request):
    token = get_token(request)
    lang = request.GET.get("lang", "bn")

    if request.method == "POST":
        action = request.POST.get("action")
        if action == "login":
            ip = _ip(request)
            if _throttled(ip):
                return _login_page(token, "অনেকবার চেষ্টা — ১৫ মিনিট পরে / too many tries, wait 15 min")
            u = authenticate(request,
                             username=request.POST.get("identifier", "").strip(),
                             password=request.POST.get("password", ""))
            if u and u.is_superuser:
                dj_login(request, u)
                AuditLog.objects.create(user=u, action="owner.login", detail={"ip": ip})
                return HttpResponseRedirect(request.path)
            c, t0 = _LOGIN_FAILS.get(ip, (0, time.time()))
            _LOGIN_FAILS[ip] = (c + 1, t0)
            time.sleep(1)
            return _login_page(token, "ভুল তথ্য বা owner নন / wrong details or not owner")

        # all other actions require owner session
        if not (request.user.is_authenticated and request.user.is_superuser):
            return _login_page(token)
        if action == "logout":
            dj_logout(request)
            return HttpResponseRedirect(request.path)
        slug = request.POST.get("slug", "")
        if action == "save":
            data = {k: v for k, v in request.POST.items()
                    if k not in ("action", "slug", "csrfmiddlewaretoken")}
            try:
                I.save(slug, data)
                AuditLog.objects.create(user=request.user, action="integration.save",
                                        detail={"slug": slug})  # never store secret values
            except ValueError:
                pass
        elif action == "test":
            st, detail = I.test(slug)
            AuditLog.objects.create(user=request.user, action="integration.test",
                                    detail={"slug": slug, "result": st})
        return HttpResponseRedirect(request.path + f"?lang={lang}")

    # GET
    if not (request.user.is_authenticated and request.user.is_superuser):
        return _login_page(token)
    try:
        dash = _dashboard(I.summary(lang), lang)
        cards = _render_cards(lang)
        body = (dash + cards).replace("__TOK__", token)
    except RuntimeError as e:
        # Section-21 error state: encryption key not configured — be honest,
        # don't 500. Owner can still see what's wrong.
        msg = ("এনক্রিপশন কি (INTEGRATIONS_FERNET_KEY) সেট করা নেই — "
               "কোনো key সংরক্ষণ করা যাবে না।" if lang == "bn"
               else "Encryption key (INTEGRATIONS_FERNET_KEY) is not configured — "
                    "keys cannot be stored yet.")
        body = (f'<div class="banner err">⚠ {_html.escape(msg)}<br>'
                f'<span class=detail>{_html.escape(str(e)[:200])}</span></div>')
    return HttpResponse(_page(body, token, lang))
