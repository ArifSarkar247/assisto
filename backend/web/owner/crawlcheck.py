"""owneradmin (18 Nov): a crawler that opens EVERY Owner Admin page the way the
owner does (bn + en), follows every /owner/ link it finds and checks each page:
status 200, server time, size < 300 KB, no English words / ASCII digits in bn
mode, mobile-safe tables, CSRF on every POST form, a confirm on destructive
actions, no secret value ever echoed back, no dead links.

Used by web/tests_owneradmin_crawl.py (CI) and tools/owner_shots/crawl.py
(the ownershots CI job, against a seeded throwaway database). Never wired to a
URL; read-only apart from the GET requests it makes."""
import re
import time
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlencode, urlsplit

MAX_BYTES = 300 * 1024
MAX_SECONDS = 2.0
MAX_PAGES = 420
PER_PATTERN = 4          # at most N different URLs per URL pattern (pk / filters)

# Pages never fetched by the crawler (auth flow, files, sign-out).
SKIP_PREFIX = ("/owner/login", "/owner/2fa", "/owner/enrol", "/owner/logout",
               "/owner/assets/", "/owner/robots.txt")

# Text inside these is machine text (codes, keys, log lines): no language rule.
RAW_TAGS = {"code", "pre", "kbd", "samp", "script", "style", "textarea"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}

# Words allowed in Bangla mode: brands, products, phone makers, standard
# technical acronyms the Bangla UI also uses as-is.
ALLOW = {w.lower() for w in """
Assisto AI Google Play Console bKash Nagad Rocket Upay EPS SSLCommerz SMS OTP TOTP
CCTV Imou EZVIZ Dahua Hikvision TURN STUN API URL IP ID CSV PDF JSON FCM Firebase
Android iOS Gemini OpenAI GPT ChatGPT Claude Anthropic Groq DeepSeek Mistral Maps MB GB KB
SKU Wi Fi WiFi GPS SOS APK AAB QR PIN Gmail WhatsApp imo Messenger Facebook YouTube
SIM RAM CPU HTTP HTTPS www com lifeassisto realme Samsung Xiaomi Redmi OPPO vivo
Tecno Infinix Symphony Walton Nokia Motorola OnePlus Huawei Honor itel POCO ColorOS
MIUI HyperOS AdMob UMP VAT UTC GMT BST Plus Pro Premium Probashi Sim TCP UDP RTSP
ONVIF NVR DVR ANR DAU WAU MAU Spotify Replicate Careerjet Cricbuzz ESPN TikTok
Bing Brave SerpAPI Places Geocoding OSM OpenStreetMap Mapbox SMTP DNS DKIM SPF DMARC
Zoho Brevo Mailgun SendGrid Postmark Resend Telegram Viber Truecaller Pathao
Uber Foodpanda Daraz Chaldal bdapps Robi Grameenphone Banglalink Teletalk Airtel
GP BL Wear OS SDK Assisto's Gemma Llama Qwen Kimi Whisper ElevenLabs Azure AWS
Cloudflare Caddy Django Postgres Redis Linux Ubuntu GitHub CI Flutter Dart Kotlin
SHA HMAC JWT RFC Authenticator Authy Quran Hadith Bangla Dhaka Bangladesh
Sentry Crashlytics Vitals ARB TTS STT ASR LLM VPN NID BRTA BTRC DMP RAB
Meta Instagram Remini Tanzil Cambridge Microsoft RunPod Topaz Crystal Lanczos Doze
coturn turnserver nginx postgresql cron crontab sudo apt journalctl eCPM vCPU Axon
Ranger Amiri Pickthall SeTracker Asalify Prothom Alo Jazeera ExchangeRate
Twilio Infobip Tuya Tavily AppLovin BulkSMSBD BotFather RedX Steadfast ekPay DoLynk
NAFNet GoPro AcuSense Hik Clarity Markdown Agentforce AnyDesk Calendly Coursera Canva
Duolingo Bdjobs Badhan Dropbox Alexa AirTag Apple MapLibre Raspberry Zoom Breeze Muse
Prochar ODbL Real-ESRGAN ESRGAN Real Market Cloud Circle Dynamics
""".split()}

DESTRUCTIVE = re.compile(
    r"(delete|remove|revoke|\bban\b|suspend|purge|wipe|refund|rotate|reset|"
    r"force_logout|terminate|deactivate|erase|unpublish)", re.I)
SECRET_NAME = re.compile(r"(key|secret|token|password|passwd|private)", re.I)
WORD = re.compile(r"[A-Za-z][A-Za-z'’]+")
MACHINE = re.compile(r"(\S+@\S+|\S*://\S*|\S*/\S+|\S+\.\S+|\S*_\S*|\S*[0-9]\S*)")


class _Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.raw = []             # stack of marker tags we are inside (raw / lang=en)
        self.stack = []           # open-tag stack (best effort)
        self.text = []            # visible text chunks (outside raw / lang=en)
        self.links = []
        self.forms = []
        self.form = None
        self.tables = 0
        self.tables_bare = 0
        self.secrets = []         # (name, value) of secret-looking inputs with a value
        self.attr_text = []       # placeholder / title / aria-label (visible text)
        self.csp_dead = []        # style= / on*= attributes the panel CSP blocks

    def _wrapped(self):
        return any(c for t, c in self.stack if c and ({"tbl", "chartbox"} & set(c.split())))

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get("class") or ""
        for k in a:
            if k == "style" or k.startswith("on"):
                self.csp_dead.append("%s[%s]" % (tag, k))
        if self.raw:
            name, n = self.raw[-1]
            if tag == name:
                self.raw[-1] = (name, n + 1)
        elif tag in RAW_TAGS or a.get("lang") == "en" or a.get("translate") == "no":
            if tag not in VOID:
                self.raw.append((tag, 1))
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        if tag == "table":
            self.tables += 1
            if not self._wrapped():
                self.tables_bare += 1
        if tag == "form":
            self.form = {"method": (a.get("method") or "get").lower(),
                         "action": a.get("action") or "", "confirm": "data-confirm" in a,
                         "inputs": [], "buttons": []}
            self.forms.append(self.form)
        if self.form is not None and tag in ("input", "button", "select", "textarea"):
            item = {"tag": tag, "type": (a.get("type") or "").lower(), "name": a.get("name") or "",
                    "value": a.get("value") or "", "required": "required" in a,
                    "confirm": "data-confirm" in a}
            if tag == "button" or item["type"] == "submit":
                self.form["buttons"].append(item)
            else:
                self.form["inputs"].append(item)
        if tag == "input":
            t = (a.get("type") or "text").lower()
            if t not in ("hidden", "checkbox", "radio", "submit") and a.get("value") and \
                    SECRET_NAME.search(a.get("name") or "") and \
                    not re.fullmatch(r"[•*·.\s-]*\S{0,4}", a.get("value") or ""):
                self.secrets.append((a.get("name"), a.get("value")))
        if not self.raw:
            for k in ("placeholder", "title", "aria-label"):
                if a.get(k):
                    self.attr_text.append(a[k])
        if tag not in VOID:
            self.stack.append((tag, cls))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if self.raw:
            name, n = self.raw[-1]
            if tag == name:
                n -= 1
                if n == 0:
                    self.raw.pop()
                else:
                    self.raw[-1] = (name, n)
        if tag == "form":
            self.form = None
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        if not self.raw and data.strip():
            self.text.append(data)


QUOTED = re.compile(r"“[^”]*”|`[^`]*`")    # “Create Key”: the exact label of an English-only outside screen


def english_words(chunks):
    out = []
    for s in chunks:
        s = MACHINE.sub(" ", QUOTED.sub(" ", s))
        for w in WORD.findall(s):
            lw = w.lower().strip("'’")
            if lw in ALLOW or (w.isupper() and len(w) <= 6) or len(lw) < 3:
                continue
            out.append(w)
    return out


def ascii_digits(chunks):
    from .base import keeps_ascii
    out = []
    for s in chunks:
        for tok in s.split():
            if re.search(r"[0-9]", tok) and not keeps_ascii(tok):
                out.append(tok[:40])
    return out


def analyse(html, lang):
    """Findings for one HTML page: {check: [samples]}."""
    p = _Page()
    p.feed(html)
    p.close()
    f = {}
    if lang == "bn":
        en = english_words(p.text) + english_words(p.attr_text)
        if en:
            f["english_in_bn"] = sorted(set(en))
            ctx = []
            for chunk in p.text + p.attr_text:
                if english_words([chunk]):
                    c = " ".join(chunk.split())[:70]
                    if c not in ctx:
                        ctx.append(c)
            f["english_where"] = ctx[:40]
        dg = ascii_digits(p.text)
        if dg:
            f["ascii_digits_in_bn"] = dg[:8]
    if p.csp_dead:
        f["inline_style_or_handler_blocked_by_csp"] = sorted(set(p.csp_dead))
    if p.tables_bare:
        f["table_not_scrollable"] = [p.tables_bare]
    for fm in p.forms:
        if fm["method"] != "post":
            continue
        names = {i["name"] for i in fm["inputs"]}
        if "_ot" not in names or "csrfmiddlewaretoken" not in names:
            f.setdefault("form_without_csrf", []).append(fm["action"] or "(same page)")
        hay = " ".join([fm["action"]] + ["%s=%s" % (i["name"], i["value"]) for i in fm["inputs"]
                                         if i["type"] == "hidden"])
        for b in fm["buttons"]:
            words = hay + " " + "%s=%s" % (b["name"], b["value"])
            if not DESTRUCTIVE.search(words):
                continue
            ok = fm["confirm"] or b["confirm"] or any(
                i["required"] and i["type"] == "checkbox" and i["name"].startswith("confirm")
                for i in fm["inputs"])
            if not ok:
                f.setdefault("destructive_without_confirm", []).append(words.strip()[:90])
    if p.secrets:
        f["secret_value_shown"] = [n for n, _ in p.secrets]
    return f, p.links, [fm["action"] for fm in p.forms if fm["action"]]


def _norm(href, base_path):
    """An internal URL to crawl (path?query without lang) or None."""
    if not href or href.startswith(("#", "mailto:", "tel:", "javascript:", "data:")):
        return None
    base_path = base_path.split("?", 1)[0]
    u = urlsplit(href)
    if u.scheme or u.netloc:
        return None
    path = u.path or base_path
    if not path.startswith("/"):
        path = base_path.rsplit("/", 1)[0] + "/" + path
    q = [(k, v) for k, v in parse_qsl(u.query, keep_blank_values=True)
         if k not in ("lang", "m")]
    return path + ("?" + urlencode(q) if q else "")


def _pattern(url):
    from django.urls import Resolver404, resolve
    path = url.split("?", 1)[0]
    try:
        m = resolve(path)
        return m.route or path
    except Resolver404:
        return None


def seed_urls():
    """Every /owner/ URL pattern without a path argument."""
    from . import urls as U
    out = []
    for p in U.urlpatterns:
        route = str(p.pattern)
        if "<" in route:
            continue
        url = "/owner/" + route
        if not url.startswith(SKIP_PREFIX):
            out.append(url)
    return out


def crawl(client, extra=(), max_pages=MAX_PAGES):
    """Crawl as the signed-in `client`. Returns a report dict:
    {"pages": [{url, lang, status, ms, kb, findings}], "dead": [...],
     "findings": n}."""
    queue = list(dict.fromkeys(seed_urls() + list(extra)))
    seen, per = set(), {}
    pages, dead = [], []
    linked_from = {}
    while queue and len(seen) < max_pages:
        url = queue.pop(0)
        if url in seen or url.startswith(SKIP_PREFIX):
            continue
        pat = _pattern(url)
        if pat is None:
            dead.append({"url": url, "status": 404, "from": linked_from.get(url, "")})
            seen.add(url)
            continue
        per[pat] = per.get(pat, 0) + 1
        if per[pat] > PER_PATTERN:
            continue
        seen.add(url)
        for lang in ("bn", "en"):
            sep = "&" if "?" in url else "?"
            t0 = time.monotonic()
            r = client.get(url + sep + "lang=" + lang)
            ms = int((time.monotonic() - t0) * 1000)
            if r.status_code == 405 and url not in linked_from:
                break      # a POST-only endpoint nobody links to: not a page
            ctype = r.get("Content-Type", "")
            body = b"".join(r.streaming_content) if getattr(r, "streaming", False) else r.content
            row = {"url": url, "lang": lang, "status": r.status_code, "ms": ms,
                   "html": "text/html" in ctype,
                   "kb": round(len(body) / 1024, 1), "findings": {}}
            if r.status_code in (301, 302):
                loc = r.get("Location", "")
                if loc.startswith(("/owner/login", "/owner/2fa", "/owner/enrol")):
                    row["findings"]["redirect_to_login"] = [loc]
                else:
                    n = _norm(loc, url)
                    if n and n not in seen:
                        queue.append(n)
                        linked_from.setdefault(n, url)
            elif r.status_code != 200:
                row["findings"]["status"] = [r.status_code]
                if r.status_code in (404, 405, 500):
                    dead.append({"url": url, "status": r.status_code,
                                 "from": linked_from.get(url, "")})
            if len(body) > MAX_BYTES:
                row["findings"]["too_big_kb"] = [row["kb"]]
            if ms > MAX_SECONDS * 1000:
                row["findings"]["slow_ms"] = [ms]
            if r.status_code == 200 and "text/html" in ctype:
                html = body.decode("utf-8", "replace")
                f, links, actions = analyse(html, lang)
                row["findings"].update(f)
                if lang == "bn":
                    for h in links:
                        n = _norm(h, url)
                        if n is None:
                            continue
                        if n.startswith("/owner") and n not in seen:
                            queue.append(n)
                            linked_from.setdefault(n, url)
                    for act in actions:
                        n = _norm(act, url)
                        if n and n.startswith("/owner") and _pattern(n) is None:
                            dead.append({"url": n, "status": "form action 404", "from": url})
            pages.append(row)
    total = sum(len(p["findings"]) for p in pages) + len(dead)
    return {"pages": pages, "dead": dead, "findings": total}


def summary(report, limit=400):
    """Compact text of every finding (CI log / assertion message)."""
    lines = []
    for p in report["pages"]:
        for k, v in p["findings"].items():
            lines.append("%s [%s] %s: %s" % (p["url"], p["lang"], k,
                                             ", ".join(str(x) for x in v)[:300]))
    for d in report["dead"]:
        lines.append("DEAD %s (%s) linked from %s" % (d["url"], d["status"], d["from"]))
    slow = sorted(report["pages"], key=lambda p: -p["ms"])[:5]
    lines.append("slowest: " + ", ".join("%s %dms" % (p["url"], p["ms"]) for p in slow))
    big = sorted(report["pages"], key=lambda p: -p["kb"])[:5]
    lines.append("biggest: " + ", ".join("%s %.0fKB" % (p["url"], p["kb"]) for p in big))
    ok = sum(1 for p in report["pages"] if p["status"] == 200 and p.get("html"))
    lines.append("pages: %d (%d HTML 200), findings: %d" % (len(report["pages"]), ok,
                                                           report["findings"]))
    return "\n".join(lines[-limit:] if len(lines) > limit else lines)
