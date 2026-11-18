"""seoblog (owner order 17 Nov 00:32, item 6) — the lifeassisto.com blog.

* Model: core.models.BlogPost (Bangla + English Markdown, cover image as a
  private upload behind a signed link, publish switch, last-reviewed date).
* Only a PUBLISHED post with both languages filled is reachable, listed and in
  the sitemap; everything else is a 404 (never a half page in Google).
* Markdown: a small SAFE subset rendered here (no raw HTML ever passes):
  ## / ### headings, paragraphs, - and 1. lists, > note boxes, | tables |,
  **bold**, [links](https://… or /path). Every link is checked: only https,
  http or a site path; anything else is shown as plain text.
* FEATURES: the one feature-page map every article links to (seogrow owns the
  pages themselves). Change a path here and every article follows.
"""
import json
import re

from django.utils import timezone
from django.utils.html import escape

FEATURES = {
    # key: (path, Bangla name, English name)
    "family-care": ("/features/family-care", "পরিবারের যত্ন", "Family Care"),
    "safe-journey": ("/features/safe-journey", "নিরাপদ যাত্রা", "Safe Journey"),
    "cctv-app": ("/features/cctv-app", "সিসিটিভি অ্যাপ", "CCTV app"),
    "my-circle": ("/features/my-circle", "My Circle", "My Circle"),
    "ai-assistant": ("/features/ai-assistant", "AI সহকারী", "AI assistant"),
    "business-khata": ("/features/business-khata", "ব্যবসা ও খাতা", "Business and khata"),
    "mess": ("/features/mess", "মেস ও ব্যাচেলর", "Mess and bachelor"),
    "language-partner": ("/features/language-partner", "ভাষা শেখার সঙ্গী ও IELTS", "Language Partner and IELTS"),
    "quran": ("/features/quran", "কুরআন", "Quran"),
    "city-service": ("/features/city-service", "সিটি সার্ভিস", "City Service"),
    "blood-donor": ("/features/blood-donor", "রক্তদাতা", "Blood donor"),
}

ORG = {"@type": "Organization", "name": "Axon Dynamics", "url": "https://lifeassisto.com/",
       "email": "assistoaiagent@gmail.com",
       "address": {"@type": "PostalAddress", "streetAddress": "Cha-63/3, Uttar Badda, Badda",
                   "addressLocality": "Dhaka", "postalCode": "1212", "addressCountry": "BD"}}

SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_COVER_BYTES = 2 * 1024 * 1024


# ----------------------------------------------------------------- markdown
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD = re.compile(r"\*\*(.+?)\*\*")


def _safe_href(url):
    u = (url or "").strip()
    if u.startswith("/") and not u.startswith("//"):
        return u
    if re.match(r"^https?://[A-Za-z0-9.-]+(?:[/?#].*)?$", u):
        return u
    return ""


def _inline(text):
    """Escape first, then turn the safe inline marks into tags."""
    out, pos = [], 0
    for m in _LINK.finditer(text):
        out.append(_bold(escape(text[pos:m.start()])))
        label, href = m.group(1), _safe_href(m.group(2))
        if href:
            ext = not href.startswith("/")
            out.append('<a href="%s"%s>%s</a>' % (
                escape(href), ' rel="noopener" target="_blank"' if ext else "", _bold(escape(label))))
        else:
            out.append(_bold(escape(label)))
        pos = m.end()
    out.append(_bold(escape(text[pos:])))
    return "".join(out)


def _bold(escaped):
    return _BOLD.sub(r"<strong>\1</strong>", escaped)


def _table(rows):
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    head, body = cells[0], cells[1:]
    if body and all(re.match(r"^:?-{2,}:?$", c) for c in body[0]):
        body = body[1:]
    h = "".join("<th scope=\"col\">%s</th>" % _inline(c) for c in head)
    b = "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % _inline(c) for c in r) for r in body)
    return '<div class="tbl"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (h, b)


def render_markdown(md):
    """Safe Markdown subset -> HTML. Returns (html, headings) where headings
    is [(id, text)] of the ## level (the article's table of contents)."""
    lines = (md or "").replace("\r\n", "\n").split("\n")
    html, heads, para, i = [], [], [], 0

    def flush():
        if para:
            html.append("<p>%s</p>" % _inline(" ".join(para)))
            para.clear()

    while i < len(lines):
        ln = lines[i].rstrip()
        s = ln.strip()
        if not s:
            flush()
            i += 1
            continue
        m = re.match(r"^(#{1,3})\s+(.*)$", s)
        if m:
            flush()
            level = 3 if len(m.group(1)) == 3 else 2
            text = m.group(2).strip()
            if level == 2:
                hid = "s%d" % (len(heads) + 1)
                heads.append((hid, text))
                html.append('<h2 id="%s">%s</h2>' % (hid, _inline(text)))
            else:
                html.append("<h3>%s</h3>" % _inline(text))
            i += 1
            continue
        if s.startswith("|"):
            flush()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i])
                i += 1
            html.append(_table(rows))
            continue
        if re.match(r"^[-*]\s+", s) or re.match(r"^\d+[.)]\s+", s):
            flush()
            ordered = bool(re.match(r"^\d+[.)]\s+", s))
            pat = r"^\d+[.)]\s+" if ordered else r"^[-*]\s+"
            items = []
            while i < len(lines) and re.match(pat, lines[i].strip()):
                items.append(re.sub(pat, "", lines[i].strip(), count=1))
                i += 1
            tag = "ol" if ordered else "ul"
            html.append("<%s>%s</%s>" % (tag, "".join("<li>%s</li>" % _inline(t) for t in items), tag))
            continue
        if s.startswith(">"):
            flush()
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip()[1:].strip())
                i += 1
            html.append('<aside class="note"><p>%s</p></aside>' % _inline(" ".join(quote)))
            continue
        para.append(s)
        i += 1
    flush()
    return "\n".join(html), heads


# ------------------------------------------------------------------- posts
def is_complete(p):
    return bool(p.title_bn and p.title_en and p.body_bn.strip() and p.body_en.strip())


def published():
    from core.models import BlogPost
    return [p for p in BlogPost.objects.filter(published=True) if is_complete(p)]


def get_published(slug):
    from core.models import BlogPost
    p = BlogPost.objects.filter(slug=slug, published=True).first()
    return p if p is not None and is_complete(p) else None


def sitemap_paths():
    """/blog and every published article — nothing while none is published."""
    try:
        posts = published()
    except Exception:  # noqa: BLE001 — the sitemap must never break
        return []
    if not posts:
        return []
    return ["/blog"] + ["/blog/%s" % p.slug for p in posts]


def sitemap_lastmod():
    """seolive: {path: date} for the sitemap — an article's last-reviewed date
    (or its last edit), /blog = the newest of them."""
    try:
        posts = published()
    except Exception:  # noqa: BLE001 — the sitemap must never break
        return {}
    out = {}
    for p in posts:
        d = p.last_reviewed or (p.updated_at or p.published_at or timezone.now()).date()
        if p.updated_at and p.updated_at.date() > d:
            d = p.updated_at.date()
        out["/blog/%s" % p.slug] = d
    if out:
        out["/blog"] = max(out.values())
    return out


def feature_link(key, lang):
    """The CTA link to a feature landing page. Once seogrow's
    web.site_landing is merged, its url_for() decides (None while that app
    feature is switched off -> no link, never a 404 link)."""
    f = FEATURES.get(key)
    if not f:
        return None
    name = f[2] if lang == "en" else f[1]
    try:
        from .site_landing import url_for
    except ImportError:
        return {"href": f[0] + ("?lang=en" if lang == "en" else ""), "name": name}
    try:
        href = url_for(key, lang)
    except Exception:  # noqa: BLE001 — a link must never break the article
        href = None
    return {"href": href, "name": name} if href else None


def text(p, field, lang):
    return getattr(p, "%s_%s" % (field, lang)) or getattr(p, "%s_bn" % field)


def date_label(d, lang):
    if not d:
        return ""
    from .site_content import bn_digits
    bn_m = ["জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই", "আগস্ট",
            "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর"]
    if lang == "en":
        return d.strftime("%-d %B %Y")
    return bn_digits("%d %s %d" % (d.day, bn_m[d.month - 1], d.year))


def cover_path(p):
    return "/blog/%s/cover" % p.slug if p.cover else ""


# ------------------------------------------------------------------ JSON-LD
def jsonld_article(p, lang, site, url, image):
    when = p.published_at or p.created_at or timezone.now()
    mod = p.last_reviewed.isoformat() if p.last_reviewed else (p.updated_at or when).date().isoformat()
    crumbs = [("Assisto", site + "/"), ("Blog" if lang == "en" else "ব্লগ", site + "/blog" + ("?lang=en" if lang == "en" else "")),
              (text(p, "title", lang), url)]
    graph = [
        {"@type": "Article", "headline": text(p, "title", lang)[:110],
         "description": text(p, "summary", lang), "inLanguage": "en" if lang == "en" else "bn",
         "datePublished": when.date().isoformat(), "dateModified": mod,
         "image": [image], "mainEntityOfPage": {"@type": "WebPage", "@id": url},
         "author": {"@type": "Organization", "name": "Axon Dynamics", "url": site + "/about"},
         "publisher": dict(ORG, logo={"@type": "ImageObject", "url": site + "/apple-touch-icon.png"})},
        {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": i + 1, "name": n, "item": u} for i, (n, u) in enumerate(crumbs)]},
    ]
    return _dump({"@context": "https://schema.org", "@graph": graph})


def jsonld_index(posts, lang, site, url):
    q = "?lang=en" if lang == "en" else ""
    graph = [
        {"@type": "Blog", "name": "Assisto Blog" if lang == "en" else "Assisto ব্লগ", "url": url,
         "inLanguage": "en" if lang == "en" else "bn", "publisher": ORG,
         "blogPost": [{"@type": "BlogPosting", "headline": text(p, "title", lang)[:110],
                       "url": site + "/blog/" + p.slug + q} for p in posts]},
        {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Assisto", "item": site + "/"},
            {"@type": "ListItem", "position": 2, "name": "Blog" if lang == "en" else "ব্লগ", "item": url}]},
    ]
    return _dump({"@context": "https://schema.org", "@graph": graph})


def _dump(d):
    # safe inside <script>: no "</" can close the tag early
    return json.dumps(d, ensure_ascii=False).replace("</", "<\\/")


# ------------------------------------------------------------ owner editing
FIELDS = ("slug", "title_bn", "title_en", "summary_bn", "summary_en", "body_bn", "body_en",
          "feature", "keywords", "cover_alt_bn", "cover_alt_en")
LIMITS = {"slug": 80, "title_bn": 120, "title_en": 120, "summary_bn": 200, "summary_en": 200,
          "feature": 40, "keywords": 300, "cover_alt_bn": 160, "cover_alt_en": 160,
          "body_bn": 60000, "body_en": 60000}


def clean(data, post=None):
    """Owner form -> (values, errors). Errors are field -> code."""
    from core.models import BlogPost
    v, e = {}, {}
    for f in FIELDS:
        s = (data.get(f) or "").strip() if f not in ("body_bn", "body_en") else (data.get(f) or "").replace("\r\n", "\n")
        if len(s) > LIMITS[f]:
            e[f] = "too_long"
        v[f] = s
    v["slug"] = v["slug"].lower()
    if not SLUG_RE.match(v["slug"]):
        e["slug"] = "slug"
    elif BlogPost.objects.filter(slug=v["slug"]).exclude(pk=getattr(post, "pk", None)).exists():
        e["slug"] = "taken"
    if not v["title_bn"]:
        e["title_bn"] = "required"
    if v["feature"] and v["feature"] not in FEATURES:
        e["feature"] = "unknown"
    lr = (data.get("last_reviewed") or "").strip()
    if lr:
        from django.utils.dateparse import parse_date
        try:
            d = parse_date(lr)
        except ValueError:
            d = None
        if d is None:
            e["last_reviewed"] = "date"
        v["last_reviewed"] = d
    else:
        v["last_reviewed"] = None
    try:
        v["order"] = int(data.get("order") or 0)
    except (TypeError, ValueError):
        e["order"] = "number"
    v["published"] = data.get("published") in ("on", "1", "true", True)
    if v["published"] and not (v["title_bn"] and v["title_en"] and v["body_bn"].strip() and v["body_en"].strip()):
        e["published"] = "both_languages"
    return v, e


def apply(post, v):
    for k, val in v.items():
        setattr(post, k, val)
    if post.published and not post.published_at:
        post.published_at = timezone.now()
    post.save()
    return post


def save_cover(post, f):
    """Validate (size, real PNG/JPEG/WEBP) and store. Error code or ''."""
    if f.size > MAX_COVER_BYTES:
        return "too_large"
    try:
        from PIL import Image
        img = Image.open(f)
        img.verify()
        if (img.format or "").upper() not in ("PNG", "JPEG", "WEBP"):
            raise ValueError("format")
        f.seek(0)
    except Exception:  # noqa: BLE001
        return "not_an_image"
    if post.cover:
        try:
            post.cover.delete(save=False)
        except Exception:  # noqa: BLE001
            pass
    post.cover.save("cover-%s.%s" % (post.slug, (img.format or "png").lower().replace("jpeg", "jpg")), f, save=True)
    return ""
