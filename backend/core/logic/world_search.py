"""
world_search.py — the PURE side of "Ask anything" (live web search answers
with numbered sources), p4-world.

No Django, no DB, no network. core/world_service.py does the HTTP call with
the request this module builds, hands the raw JSON back to `parse_*`, builds
the LLM prompt with `build_prompt`, and cleans the reply with `finalize`.

Provider-agnostic: two adapters (Brave Search API, Tavily). The owner picks
one in Owner Admin → Integrations → web_search (field `provider`).

Safety: the model may only use the numbered sources; every claim carries [n];
health / legal / money questions get a "verify with a professional" note; no
dosage; when nothing reliable was found we say so instead of guessing.
"""
import hashlib
import json
import re
from urllib.parse import urlencode, urlparse

PROVIDERS = ("brave", "tavily")
MAX_RESULTS = 6
SNIPPET_MAX = 400
QUESTION_MAX = 300

DEFAULT_COST_USD = {"brave": 0.005, "tavily": 0.008}


class SearchError(Exception):
    pass


def provider_of(cfg):
    """The configured provider whose key is present, else ''."""
    p = str((cfg or {}).get("provider") or "").strip().lower()
    if p not in PROVIDERS:
        # no explicit choice: the first provider with a key
        for cand in PROVIDERS:
            if (cfg or {}).get(cand + "_api_key"):
                return cand
        return ""
    return p if (cfg or {}).get(p + "_api_key") else ""


def cost_per_search(cfg, provider):
    try:
        v = float((cfg or {}).get("cost_per_search_usd") or 0)
    except (TypeError, ValueError):
        v = 0.0
    return v if v > 0 else DEFAULT_COST_USD.get(provider, 0.008)


def normalize_question(q):
    q = re.sub(r"\s+", " ", str(q or "")).strip()
    return q[:QUESTION_MAX]


def qhash(question, lang):
    key = "%s|%s" % (lang, normalize_question(question).lower())
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


# ------------------------------------------------------------------ requests
def build_request(provider, cfg, question, lang):
    """-> (method, url, headers, body_bytes_or_None). Pure."""
    q = normalize_question(question)
    if provider == "brave":
        params = {"q": q, "count": MAX_RESULTS, "safesearch": "strict",
                  "search_lang": "bn" if lang == "bn" else "en", "country": "BD",
                  "text_decorations": "false"}
        return ("GET", "https://api.search.brave.com/res/v1/web/search?" + urlencode(params),
                {"Accept": "application/json", "X-Subscription-Token": cfg.get("brave_api_key", "")},
                None)
    if provider == "tavily":
        body = {"query": q, "max_results": MAX_RESULTS, "search_depth": "basic",
                "include_answer": False, "include_raw_content": False}
        return ("POST", "https://api.tavily.com/search",
                {"Content-Type": "application/json",
                 "Authorization": "Bearer " + cfg.get("tavily_api_key", "")},
                json.dumps(body).encode("utf-8"))
    raise SearchError("unknown provider")


def _clean(s, limit):
    s = re.sub(r"<[^>]+>", " ", str(s or ""))
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def _ok_url(u):
    try:
        p = urlparse(u)
    except ValueError:
        return False
    return p.scheme in ("http", "https") and bool(p.netloc)


def _dedupe(rows):
    out, seen = [], set()
    for r in rows:
        if not r["title"] or not _ok_url(r["url"]) or r["url"] in seen:
            continue
        seen.add(r["url"])
        r["site"] = urlparse(r["url"]).netloc.lower().removeprefix("www.")
        out.append(r)
        if len(out) >= MAX_RESULTS:
            break
    return out


def parse_brave(doc):
    if not isinstance(doc, dict):
        raise SearchError("bad payload")
    if doc.get("type") == "ErrorResponse" or "error" in doc and "web" not in doc:
        raise SearchError("provider error: %s" % str(doc.get("error"))[:120])
    rows = []
    for r in ((doc.get("web") or {}).get("results") or []):
        rows.append({"title": _clean(r.get("title"), 200), "url": str(r.get("url") or ""),
                     "snippet": _clean(r.get("description"), SNIPPET_MAX)})
    return _dedupe(rows)


def parse_tavily(doc):
    if not isinstance(doc, dict):
        raise SearchError("bad payload")
    if doc.get("detail") and "results" not in doc:
        raise SearchError("provider error: %s" % str(doc.get("detail"))[:120])
    rows = []
    for r in doc.get("results") or []:
        rows.append({"title": _clean(r.get("title"), 200), "url": str(r.get("url") or ""),
                     "snippet": _clean(r.get("content"), SNIPPET_MAX)})
    return _dedupe(rows)


def parse(provider, doc):
    return parse_brave(doc) if provider == "brave" else parse_tavily(doc)


# ------------------------------------------------------------------ safety
_CAUTION = {
    "health": (r"\b(medicine|medication|dose|dosage|symptom|disease|pain|fever|"
               r"pregnan\w*|tablet|treatment|cancer|diabetes|pressure|doctor)\b|"
               r"ওষুধ|ঔষধ|ডোজ|রোগ|জ্বর|ব্যথা|চিকিৎসা|গর্ভ|ডায়াবেটিস|প্রেশার|ডাক্তার|লক্ষণ"),
    "legal": (r"\b(law|legal|court|case|lawsuit|divorce|police|visa|contract|"
              r"inherit\w*|land dispute)\b|আইন|মামলা|আদালত|তালাক|পুলিশ|ভিসা|চুক্তি|উত্তরাধিকার|জমির বিরোধ"),
    "money": (r"\b(invest\w*|loan|stock|share market|crypto|interest rate|tax)\b|"
              r"বিনিয়োগ|ঋণ|লোন|শেয়ার|ক্রিপ্টো|সুদ|ট্যাক্স|আয়কর"),
}
_CAUTION_NOTE = {
    "health": ("এটি সাধারণ তথ্য, চিকিৎসা পরামর্শ নয় — ডাক্তার বা ফার্মাসিস্টের সাথে কথা বলুন।",
               "This is general information, not medical advice — please talk to a doctor or pharmacist."),
    "legal": ("এটি সাধারণ তথ্য, আইনি পরামর্শ নয় — একজন আইনজীবী বা সংশ্লিষ্ট সরকারি অফিসে যাচাই করুন।",
              "This is general information, not legal advice — please check with a lawyer or the official office."),
    "money": ("এটি সাধারণ তথ্য, আর্থিক পরামর্শ নয় — সিদ্ধান্তের আগে যাচাই করুন।",
              "This is general information, not financial advice — please verify before deciding."),
}


def caution_of(question):
    q = str(question or "").lower()
    return [k for k, rx in _CAUTION.items() if re.search(rx, q)]


def caution_notes(kinds, lang):
    i = 0 if lang == "bn" else 1
    return [_CAUTION_NOTE[k][i] for k in kinds]


# ------------------------------------------------------------------ prompt
def build_prompt(question, results, lang, today_iso=""):
    """-> (task, data, extra_system). Sources go in `data` (untrusted)."""
    lang_name = "Bangla" if lang == "bn" else "English"
    lines = []
    for i, r in enumerate(results, 1):
        lines.append("[%d] %s (%s)\n%s" % (i, r["title"], r["site"], r["snippet"]))
    data = "QUESTION: %s\n\nSOURCES:\n%s" % (normalize_question(question), "\n\n".join(lines))
    task = ("Answer the QUESTION in %s using ONLY the numbered SOURCES inside the data. "
            "Put the source number in square brackets right after each fact, like [1] or [2][3]. "
            "Use only numbers that exist in SOURCES. Keep it short (at most 6 sentences or a short list). "
            "If the sources do not answer the question, say clearly that you could not find a reliable answer. "
            "Write digits as normal Arabic numerals inside the brackets.%s"
            % (lang_name, (" Today is %s." % today_iso) if today_iso else ""))
    extra = ("Web-answer rules: never invent facts, numbers, prices or dates that are not in the sources; "
             "for health, legal or money questions give general information only, never a medicine dose, "
             "never certainty, and suggest a professional; never claim the sources say something they do not.")
    return task, data, extra


_CITE_RE = re.compile(r"\[(\d{1,2})\]")
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def finalize(answer, results, question, lang):
    """Clean the model reply: Bangla digits in brackets -> ASCII, drop any
    [n] that is not a real source, list ONLY the cited sources (renumbered
    1..k in order of first use), add caution notes. Returns
    {answer, sources:[{n,title,url,site}], cited, caution:[...]}"""
    text = str(answer or "").strip()
    text = re.sub(r"\[([০-৯]{1,2})\]", lambda m: "[%s]" % m.group(1).translate(_BN_DIGITS), text)
    n = len(results)
    order = []
    for m in _CITE_RE.finditer(text):
        k = int(m.group(1))
        if 1 <= k <= n and k not in order:
            order.append(k)
    remap = {old: new for new, old in enumerate(order, 1)}

    def rep(m):
        k = int(m.group(1))
        return "[%d]" % remap[k] if k in remap else ""
    text = _CITE_RE.sub(rep, text)
    text = re.sub(r"[ \t]+([.,।!?])", r"\1", text)
    text = re.sub(r"[ \t]{2,}", " ", text).strip()
    sources = [{"n": remap[k], "title": results[k - 1]["title"], "url": results[k - 1]["url"],
                "site": results[k - 1]["site"]} for k in order]
    kinds = caution_of(question)
    caution = caution_notes(kinds, lang)
    # aieval guard: a number that is in none of the sources (nor the
    # question) is flagged to the reader — never shown as a verified fact.
    from ..ai_guard import ungrounded_numbers
    src = [question] + ["%s %s" % (r.get("title", ""), r.get("snippet", "")) for r in results]
    plain = _CITE_RE.sub(" ", text)
    if ungrounded_numbers(plain, src):
        caution = caution + [UNVERIFIED_NOTE["en" if lang == "en" else "bn"]]
    return {"answer": text, "sources": sources, "cited": bool(sources),
            "caution": caution}


UNVERIFIED_NOTE = {
    "bn": "এই উত্তরের কোনো সংখ্যা সূত্রে পাওয়া যায়নি — ব্যবহারের আগে নিজে যাচাই করুন।",
    "en": "A number in this answer was not found in the sources — check it before you rely on it.",
}


NO_RESULTS = {
    "bn": "এই প্রশ্নের জন্য নির্ভরযোগ্য কোনো সূত্র খুঁজে পাইনি। প্রশ্নটি একটু অন্যভাবে লিখে আবার চেষ্টা করুন।",
    "en": "I could not find a reliable source for this question. Try asking it a different way.",
}
UNCITED_NOTE = {
    "bn": "এই উত্তরে কোনো সূত্র উল্লেখ নেই — নিচের লিংকগুলো দেখে নিজে যাচাই করুন।",
    "en": "This answer cites no source — please check the links yourself.",
}
