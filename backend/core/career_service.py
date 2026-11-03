"""Career tools glue (p2career, owner PART 2 rows 2.2-2.4; flag career_plus).

  * CV: ATS-friendly PDF (English, reportlab, one column, real text) and a
    signed 30-minute print page (any language — the browser shapes Bangla
    conjuncts correctly, so Bangla CVs go through "Save as PDF"), ATS check,
    AI polish through the existing router (ai.generate -> credits, PII masked).
  * Jobs: LEGAL sources only — Careerjet's official partner API (owner key),
    company Greenhouse / Lever public job-board APIs and RSS/Atom feeds the
    USER adds. Server reads go through link_preview.safe_fetch (https/http
    only, private IPs blocked, size cap). Plain career PAGES are never read
    (that would be scraping) — they stay links. Bdjobs / BPSC / Teletalk have
    no open feed: link-out only (logic.world_content.JOB_PORTALS).
  * Deadline reminders: two Reminder rows (3 days before + the day, 09:00
    Dhaka) through the normal reminder pipeline.
  * Mock interview: rubric (logic.career_content) always; AI feedback via the
    router within a per-user daily cap on top of the credit charge.
"""
import base64
import hashlib
import html
import io
import json
import re
from datetime import datetime, time, timedelta
from datetime import timezone as dt_timezone

from django.core import signing
from django.utils import timezone

from .logic import career_content as CC

FLAG = "career_plus"
PRINT_SALT = "career.cv.print"
PRINT_TTL_S = 30 * 60
AI_INTERVIEW_DAILY_CAP = 20
AI_POLISH_DAILY_CAP = 10
MAX_USER_SOURCES = 10
MAX_PHOTO_B64 = 400_000
FEED_MAX_BYTES = 512 * 1024
SOURCE_KINDS = ("greenhouse", "lever", "rss", "link")
_SLUG = re.compile(r"^[A-Za-z0-9_.-]{2,64}$")


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user, play))
    except Exception:  # noqa: BLE001
        return False


# ======================================================================= CV
def cv_row(user):
    from .models import PaCollectionItem
    it = PaCollectionItem.objects.filter(user=user, collection="cv").order_by("id").first()
    return dict(it.data or {}) if it else None


def prefill(user):
    """Profile -> CV header fields (only what the user already gave us)."""
    return {"name": (user.name or "")[:120], "phone": (user.phone or "")[:40],
            "email": (user.email or "")[:120]}


def photo_bytes(row):
    """Optional photo stored in the CV row as a small data: URI -> JPEG/PNG
    bytes, or None. Anything that is not a real image is ignored."""
    raw = (row or {}).get("photo") or ""
    if not isinstance(raw, str) or not raw.startswith("data:image/") or len(raw) > MAX_PHOTO_B64:
        return None
    try:
        data = base64.b64decode(raw.split(",", 1)[1], validate=False)
        from PIL import Image
        Image.open(io.BytesIO(data)).verify()
        return data
    except Exception:  # noqa: BLE001
        return None


def cv_pdf(row, lang="en"):
    """ATS-friendly English PDF bytes: single column, Helvetica, real text,
    standard headings, no tables. Photo (optional) top-right."""
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.utils import ImageReader, simpleSplit
    from reportlab.pdfgen import canvas
    cv = CC.normalize_cv(row)
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    c.setTitle((cv["name"] or "CV") + " — CV")
    c.setAuthor(cv["name"] or "")
    w, h = A4
    left, right = 50, w - 50
    y = h - 56
    photo = photo_bytes(row)
    text_right = right
    if photo:
        try:
            c.drawImage(ImageReader(io.BytesIO(photo)), right - 80, h - 140, 80, 96,
                        preserveAspectRatio=True, mask="auto")
            text_right = right - 95
        except Exception:  # noqa: BLE001
            pass

    def line(txt, font="Helvetica", size=10.5, gap=14, indent=0, width=None):
        nonlocal y
        for part in simpleSplit(txt, font, size, (width or (right - left)) - indent):
            if y < 60:
                c.showPage()
                y = h - 56
            c.setFont(font, size)
            c.drawString(left + indent, y, part)
            y -= gap

    if cv["name"]:
        line(cv["name"], "Helvetica-Bold", 18, 22, width=text_right - left)
    if cv["headline"]:
        line(cv["headline"], "Helvetica", 11.5, 16, width=text_right - left)
    contact = CC.contact_line(cv)
    if contact:
        line(contact, "Helvetica", 10, 14, width=text_right - left)
    if photo:
        y = min(y, h - 150)
    for b in CC.cv_blocks(cv, "en"):
        y -= 8
        line(b["heading"].upper(), "Helvetica-Bold", 11.5, 15)
        c.setLineWidth(0.5)
        c.line(left, y + 10, right, y + 10)
        y -= 2
        if b["kind"] == "items":
            for it in b["items"]:
                if it["head"]:
                    line(it["head"], "Helvetica-Bold", 10.5, 14)
                for bl in it["bullets"]:
                    line("- " + bl, indent=10)
        elif b["kind"] == "list":
            for ln in b["lines"]:
                line("- " + ln, indent=4)
        else:
            for ln in b["lines"]:
                line(ln)
        if b["kind"] == "declaration":
            y -= 24
            line("Signature: ______________________        Date: ____________")
    c.showPage()
    c.save()
    return buf.getvalue()


def print_token(user, lang):
    return signing.dumps({"u": user.pk, "l": "bn" if lang == "bn" else "en"},
                         salt=PRINT_SALT, compress=True)


def read_print_token(token):
    """-> (user_id, lang) or (None, None) when bad / older than 30 minutes."""
    try:
        d = signing.loads(token, salt=PRINT_SALT, max_age=PRINT_TTL_S)
        return int(d["u"]), d.get("l", "en")
    except Exception:  # noqa: BLE001
        return None, None


def print_html(row, lang="en"):
    """A printable, single-column HTML CV (every value escaped). The page is
    noindex and says so: the link expires in 30 minutes."""
    cv = CC.normalize_cv(row)
    e = html.escape
    lang = "bn" if lang == "bn" else "en"
    photo = ""
    if photo_bytes(row):
        photo = '<img class="ph" alt="" src="%s">' % e(row.get("photo"))
    parts = []
    for b in CC.cv_blocks(cv, lang):
        parts.append("<h2>%s</h2>" % e(b["heading"]))
        if b["kind"] == "items":
            for it in b["items"]:
                if it["head"]:
                    parts.append("<h3>%s</h3>" % e(it["head"]))
                if it["bullets"]:
                    parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % e(x) for x in it["bullets"]))
        elif b["kind"] == "list":
            parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % e(x) for x in b["lines"]))
        else:
            parts.extend("<p>%s</p>" % e(x) for x in b["lines"])
        if b["kind"] == "declaration":
            sig = "স্বাক্ষর: ____________ &nbsp; তারিখ: ________" if lang == "bn" else \
                "Signature: ____________ &nbsp; Date: ________"
            parts.append('<p class="sig">%s</p>' % sig)
    btn = "PDF হিসেবে সেভ / প্রিন্ট" if lang == "bn" else "Save as PDF / Print"
    note = ("এই লিংক ৩০ মিনিট পরে বন্ধ হবে। কাউকে লিংকটা পাঠাবেন না — PDF সেভ করে পাঠান।"
            if lang == "bn" else
            "This link expires in 30 minutes. Do not share the link — save the PDF and share that.")
    return """<!doctype html><html lang="%(lang)s"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>%(title)s</title>
<style>
body{font-family:'Noto Sans Bengali','Noto Sans',Arial,sans-serif;color:#111;background:#fff;max-width:760px;margin:0 auto;padding:24px 16px;line-height:1.5}
h1{font-size:26px;margin:0}.hl{font-size:16px;margin:2px 0}.ct{font-size:14px;color:#333}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.04em;border-bottom:1px solid #444;margin:20px 0 6px;padding-bottom:2px}
h3{font-size:14px;margin:8px 0 2px}ul{margin:2px 0 4px 20px;padding:0}li,p{font-size:14px;margin:2px 0}
.ph{float:right;width:96px;height:116px;object-fit:cover;border:1px solid #ccc;margin-left:12px}
.bar{background:#eef3ff;border-radius:8px;padding:12px;margin-bottom:16px;font-size:14px}
.bar button{font-size:16px;min-height:48px;padding:0 18px;border-radius:24px;border:0;background:#2950d6;color:#fff}
.sig{margin-top:28px}@media print{.bar{display:none}body{padding:0}}
</style></head><body>
<div class="bar"><button onclick="window.print()">%(btn)s</button><p>%(note)s</p></div>
%(photo)s<h1>%(name)s</h1><p class="hl">%(headline)s</p><p class="ct">%(contact)s</p>
%(body)s
</body></html>""" % {
        "lang": lang, "title": e((cv["name"] or "CV") + " — CV"), "btn": btn, "note": e(note),
        "photo": photo, "name": e(cv["name"]), "headline": e(cv["headline"]),
        "contact": e(CC.contact_line(cv)), "body": "\n".join(parts)}


def _ai_calls_today(user, feature):
    from .models import AIUsage
    since = timezone.localtime().replace(hour=0, minute=0, second=0, microsecond=0)
    return AIUsage.objects.filter(user=user, feature=feature, created_at__gte=since).count()


def _ai_unavailable(lang, reason):
    from .i18n import pick
    msgs = {
        "no_key": ("AI এখনো যুক্ত হয়নি — বাকি সব কাজ করে।", "AI is not connected yet — everything else works."),
        "credits": ("AI ক্রেডিট শেষ — ক্রেডিট নিন বা কাল আবার চেষ্টা করুন।", "Out of AI credits — top up or try again tomorrow."),
        "user_limit": ("আজকের AI সীমা শেষ — কাল আবার চেষ্টা করুন।", "Today's AI limit is used up — try again tomorrow."),
        "budget": ("AI আজ ব্যস্ত — একটু পরে চেষ্টা করুন।", "AI is busy today — please try later."),
        "queued": ("AI এখন সাড়া দিচ্ছে না — একটু পরে চেষ্টা করুন।", "AI is not responding right now — please try later."),
        "cap": ("এই কাজে আজকের AI সীমা শেষ — কাল আবার।", "Today's AI limit for this tool is used — try tomorrow."),
    }
    bn, en = msgs.get(reason, msgs["queued"])
    return {"ai_used": False, "reason": reason, "message": pick(lang, bn, en)}


def polish_cv(user, row, lang="bn"):
    """AI polish of the summary + experience bullets. NEVER invents facts.
    -> {ai_used, summary, experience:[{bullets}]} or the honest state."""
    from . import ai
    feature = "career.cv_polish"
    if _ai_calls_today(user, feature) >= AI_POLISH_DAILY_CAP:
        return _ai_unavailable(lang, "cap")
    cv = CC.normalize_cv(row)
    payload = {"summary": cv["summary"], "headline": cv["headline"],
               "experience": [{"title": x["title"], "org": x["org"], "bullets": x["bullets"]}
                              for x in cv["experience"]],
               "skills": cv["skills"], "education": cv["education"]}
    target = "Bangla" if lang == "bn" else "English"
    task = ("You polish a job seeker's CV for Bangladeshi employers and ATS software. "
            "Rewrite the summary (2-3 sentences) and each experience's bullets with "
            "strong action verbs, in %s. STRICT: use ONLY facts in the data; never add "
            "jobs, degrees, numbers, employers or skills that are not there. Keep the "
            "same number of experiences in the same order. Reply with JSON only: "
            '{"summary": "...", "experience": [{"bullets": ["..."]}]}' % target)
    try:
        out, _cost = ai.generate(task=task, data=json.dumps(payload, ensure_ascii=False),
                                 tier="cheap", feature=feature, max_tokens=900,
                                 user=user, pii=True)
    except ai.AIUnavailable as e:
        return _ai_unavailable(lang, e.reason)
    m = re.search(r"\{.*\}", out or "", re.S)
    try:
        d = json.loads(m.group(0)) if m else {}
    except ValueError:
        d = {}
    exp = d.get("experience") if isinstance(d.get("experience"), list) else []
    if not isinstance(d.get("summary"), str) or len(exp) != len(cv["experience"]):
        return _ai_unavailable(lang, "queued")
    return {"ai_used": True, "summary": CC._s(d["summary"], 900),
            "experience": [{"bullets": CC._bullets((x or {}).get("bullets") if isinstance(x, dict) else [])}
                           for x in exp]}


# ===================================================================== JOBS
def source_url(kind, value):
    """Validate a user-added source -> the URL we may read, or None for a
    plain link (never fetched). Raises ValueError on bad input."""
    value = (value or "").strip()
    if kind == "greenhouse":
        if not _SLUG.match(value):
            raise ValueError("bad_board")
        return "https://boards-api.greenhouse.io/v1/boards/%s/jobs" % value
    if kind == "lever":
        if not _SLUG.match(value):
            raise ValueError("bad_board")
        return "https://api.lever.co/v0/postings/%s?mode=json" % value
    if kind in ("rss", "link"):
        if not re.match(r"^https://[^\s/]+\.[^\s]+$", value) or len(value) > 500:
            raise ValueError("bad_url")
        return value if kind == "rss" else None
    raise ValueError("bad_kind")


def parse_greenhouse(doc, company=""):
    out = []
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    for j in jobs if isinstance(jobs, list) else []:
        if not isinstance(j, dict):
            continue
        url = str(j.get("absolute_url") or "")
        title = CC._s(j.get("title"), 160)
        if title and url.startswith("https://"):
            loc = j.get("location") if isinstance(j.get("location"), dict) else {}
            out.append({"title": title, "company": company, "url": url,
                        "location": CC._s(loc.get("name"), 80),
                        "posted": CC._s(j.get("updated_at"), 40)})
    return out


def parse_lever(doc, company=""):
    out = []
    for j in doc if isinstance(doc, list) else []:
        if not isinstance(j, dict):
            continue
        url = str(j.get("hostedUrl") or "")
        title = CC._s(j.get("text"), 160)
        if title and url.startswith("https://"):
            cat = j.get("categories") if isinstance(j.get("categories"), dict) else {}
            posted = ""
            try:
                posted = datetime.fromtimestamp(int(j.get("createdAt")) / 1000,
                                                tz=dt_timezone.utc).date().isoformat()
            except (TypeError, ValueError, OverflowError):
                pass
            out.append({"title": title, "company": company, "url": url,
                        "location": CC._s(cat.get("location"), 80), "posted": posted})
    return out


def fetch_source(src, net=None):
    """Read ONE user source -> list of jobs. Raises on any failure (the
    caller reports it honestly per source). Cached 30 minutes. `net` (tests)
    = {"opener": fn, "resolver": fn} handed to link_preview.safe_fetch."""
    from django.core.cache import cache
    from . import link_preview as LP
    from .logic import world_feeds as WF
    kind, value = src.get("kind"), src.get("value", "")
    url = source_url(kind, value)
    if url is None:
        return []
    ck = "career:src:" + hashlib.sha1(url.encode()).hexdigest()
    if net is None:
        try:
            hit = cache.get(ck)
        except Exception:  # noqa: BLE001
            hit = None
        if hit is not None:
            return hit
    net = net or {}
    res = LP.safe_fetch(url, max_bytes=FEED_MAX_BYTES, opener=net.get("opener"),
                        resolver=net.get("resolver"))
    if res["status"] != 200:
        raise ValueError("HTTP %s" % res["status"])
    label = CC._s(src.get("label") or value, 80)
    if kind == "rss":
        rows = [{"title": r["title"], "company": label, "url": r["link"],
                 "location": "", "posted": (r.get("published") or "")[:10]}
                for r in WF.parse_rss(res["body"], label, limit=40)]
    else:
        try:
            doc = json.loads(res["body"].decode("utf-8", "replace"))
        except ValueError:
            raise ValueError("bad_json")
        rows = parse_greenhouse(doc, label) if kind == "greenhouse" else parse_lever(doc, label)
    rows = rows[:60]
    if not net:
        try:
            cache.set(ck, rows, 30 * 60)
        except Exception:  # noqa: BLE001
            pass
    return rows


def user_sources(user):
    from .models import PaCollectionItem
    out = []
    for it in PaCollectionItem.objects.filter(user=user, collection="career/sources").order_by("id")[:MAX_USER_SOURCES]:
        d = dict(it.data or {})
        d["id"] = it.id
        if d.get("kind") in SOURCE_KINDS:
            out.append(d)
    return out


def _match(job, words, location):
    hay = (job.get("title", "") + " " + job.get("company", "") + " " + job.get("location", "")).lower()
    if words and not all(w in hay for w in words):
        return False
    if location and location not in (job.get("location", "") + " " + job.get("title", "")).lower():
        return False
    return True


def careerjet_jobs(query):
    """Careerjet official partner API (owner key) — None when not connected."""
    from django.core.cache import cache
    from . import integrations as I
    from . import world_service as WS
    if not WS.careerjet_ready():
        return None
    ck = "career:cj:" + hashlib.sha1(query.lower().encode()).hexdigest()
    try:
        hit = cache.get(ck)
    except Exception:  # noqa: BLE001
        hit = None
    if hit is not None:
        return hit
    rows = [{"title": r["title"], "company": r.get("company", ""), "url": r["url"],
             "location": "", "posted": ""}
            for r in WS._careerjet_query(I.get("jobs_careerjet").get("api_key", ""), query)]
    try:
        cache.set(ck, rows, 6 * 3600)
    except Exception:  # noqa: BLE001
        pass
    return rows


def search(user, query="", location="", net=None):
    """-> {jobs:[{title, company, url, location, posted, source, source_kind}],
           sources:[{id, label, kind, ok, count, error}]}  — every job keeps
    an honest source label; failures are reported, never hidden."""
    words = [w for w in re.split(r"\s+", (query or "").lower().strip()) if w][:6]
    location = (location or "").lower().strip()[:60]
    jobs, report = [], []
    if words:
        try:
            cj = careerjet_jobs(" ".join(words))
            if cj is None:
                report.append({"id": "careerjet", "label": "Careerjet", "kind": "careerjet",
                               "ok": False, "count": 0, "error": "not_connected"})
            else:
                for j in cj:
                    jobs.append(dict(j, source="Careerjet", source_kind="careerjet"))
                report.append({"id": "careerjet", "label": "Careerjet", "kind": "careerjet",
                               "ok": True, "count": len(cj), "error": ""})
        except Exception:  # noqa: BLE001
            report.append({"id": "careerjet", "label": "Careerjet", "kind": "careerjet",
                           "ok": False, "count": 0, "error": "failed"})
    for src in user_sources(user):
        if src["kind"] == "link":
            continue
        label = CC._s(src.get("label") or src.get("value"), 80)
        try:
            rows = [j for j in fetch_source(src, net=net) if _match(j, words, location)]
            for j in rows:
                jobs.append(dict(j, source=label, source_kind=src["kind"]))
            report.append({"id": src["id"], "label": label, "kind": src["kind"],
                           "ok": True, "count": len(rows), "error": ""})
        except Exception:  # noqa: BLE001
            report.append({"id": src["id"], "label": label, "kind": src["kind"],
                           "ok": False, "count": 0, "error": "failed"})
    seen, uniq = set(), []
    for j in jobs:
        if j["url"] in seen:
            continue
        seen.add(j["url"])
        uniq.append(j)
    return {"jobs": uniq[:100], "sources": report}


def test_source(kind, value, label="", net=None):
    rows = fetch_source({"kind": kind, "value": value, "label": label}, net=net)
    return {"ok": True, "count": len(rows), "sample": [r["title"] for r in rows[:3]]}


def set_deadline(user, title, deadline, ref):
    """Replace this job's deadline reminders: 3 days before + the day, 09:00
    Dhaka (only the ones still in the future). -> list of due datetimes."""
    from .models import Reminder
    ref = CC._s(ref, 80)
    Reminder.objects.filter(user=user, link__type="career_deadline", link__ref=ref,
                            done=False).delete()
    if deadline is None:
        return []
    tz = timezone.get_current_timezone()
    now = timezone.now()
    made = []
    for days, tag in ((3, "3d"), (0, "day")):
        at = timezone.make_aware(datetime.combine(deadline - timedelta(days=days), time(9, 0)), tz)
        if at <= now:
            continue
        if getattr(user, "language", "bn") == "en":
            head = "Application deadline today: " if tag == "day" else "Application deadline in 3 days: "
        else:
            head = "আবেদনের শেষ দিন আজ: " if tag == "day" else "৩ দিন পরে আবেদনের শেষ দিন: "
        Reminder.objects.create(
            user=user, due_at=at, category="career", title=CC._s(head + title, 200),
            link={"type": "career_deadline", "ref": ref, "label": CC._s(title, 80)})
        made.append(at.isoformat())
    return made


# ================================================================ INTERVIEW
def interview_feedback(user, qid, answer, lang="bn", want_ai=False):
    rub = CC.rubric(qid, answer)
    if rub is None:
        return None
    out = {"rubric": rub, "ai": None}
    if not want_ai or not (answer or "").strip():
        return out
    from . import ai
    feature = "career.interview"
    if _ai_calls_today(user, feature) >= AI_INTERVIEW_DAILY_CAP:
        out["ai"] = _ai_unavailable(lang, "cap")
        return out
    _role, q = CC.find_question(qid)
    target = "Bangla" if lang == "bn" else "English"
    task = ("You are a fair, encouraging interview coach in Bangladesh. Give feedback in "
            "%s on the candidate's answer to the interview question: 2 strengths, 2 "
            "improvements, and one improved sample opening sentence. Plain text, short "
            "lines starting with '- '. Do not invent facts about the candidate." % target)
    data = "Question: %s\n\nAnswer: %s" % (q["en"] if lang != "bn" else q["bn"], CC._s(answer, 4000))
    try:
        txt, _cost = ai.generate(task=task, data=data, tier="cheap", feature=feature,
                                 max_tokens=450, user=user, pii=True)
        out["ai"] = {"ai_used": True, "text": (txt or "").strip()[:3000]}
    except ai.AIUnavailable as e:
        out["ai"] = _ai_unavailable(lang, e.reason)
    return out
