#!/usr/bin/env python3
"""citydata (owner 9 Nov 11:45): polite crawl of PUBLIC transit pages.

Runs ONLY in GitHub Actions (.github/workflows/transit_data.yml), never on
the server. Rules (owner): only what a normal visitor can see — no logins,
no paid areas, no private app servers, no reverse engineering. We honour
robots.txt, identify ourselves (User-Agent below), fetch one page at a time
with a delay, and cache nothing but the parsed facts + source URL + date.

Sources (each is optional; a failing source is reported, never fatal):
  * dhakabusservice.com  — per-company Dhaka local bus pages (ordered stop
                           table, English + Bangla names, counters).
  * Wikipedia            — MRT Line 6 article (raw wikitext) to cross-check
                           station names; Bangla Wikipedia bus terminals.
  * dmtcl.gov.bd         — DMTCL home page text (station names, notices).
  * dhakabusroute.com    — (citydata2) a SECOND, separately published Dhaka
                           bus route list (one index page, "A ⇄ B ⇄ C" stop
                           sequences) used to cross-check every route.
  * brta.gov.bd          — (citydata2) home page text, only to look for an
                           official BRTA hotline / complaint number.
Output: <out>/public_<city>.json
"""
import argparse
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.robotparser
from datetime import date
from html.parser import HTMLParser

UA = "AssistoTransitBot/1.0 (+https://lifeassisto.com; public transit facts; contact via site)"
DELAY = 3.0
MAX_PAGES = 400
_robots = {}
_last = [0.0]


def allowed(url):
    p = urllib.parse.urlsplit(url)
    base = "%s://%s" % (p.scheme, p.netloc)
    rp = _robots.get(base)
    if rp is None:
        rp = urllib.robotparser.RobotFileParser()
        try:
            req = urllib.request.Request(base + "/robots.txt", headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                rp.parse(r.read().decode("utf-8", "replace").splitlines())
        except Exception:
            rp.parse([])          # no robots.txt -> allowed
        _robots[base] = rp
    return rp.can_fetch(UA, url)


def get(url):
    if not allowed(url):
        raise PermissionError("robots.txt disallows " + url)
    wait = DELAY - (time.time() - _last[0])
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en,bn"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.read().decode("utf-8", "replace")
    finally:
        _last[0] = time.time()


class Tables(HTMLParser):
    """All <table>s as rows of cell texts, plus <a href> links and <h1>."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables, self.links, self.h1 = [], [], ""
        self._t = None
        self._row = None
        self._cell = None
        self._in_h1 = False
        self._a = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "table":
            self._t = []
        elif tag == "tr" and self._t is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []
        elif tag == "h1":
            self._in_h1 = True
        elif tag == "a" and a.get("href"):
            self._a = [a["href"], []]

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(re.sub(r"\s+", " ", "".join(self._cell)).strip())
            self._cell = None
        elif tag == "tr" and self._row is not None and self._t is not None:
            if self._row:
                self._t.append(self._row)
            self._row = None
        elif tag == "table" and self._t is not None:
            self.tables.append(self._t)
            self._t = None
        elif tag == "h1":
            self._in_h1 = False
        elif tag == "a" and self._a:
            self.links.append((self._a[0], "".join(self._a[1]).strip()))
            self._a = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)
        if self._in_h1:
            self.h1 += data
        if self._a is not None:
            self._a[1].append(data)


def split_en_bn(cell):
    """'Jashimuddin (Uttara) (জসিমউদ্দিন - উত্তরা)' -> ('Jashimuddin (Uttara)', 'জসিমউদ্দিন - উত্তরা')"""
    m = re.match(r"^(.*?)\s*\(([^()]*[\u0980-\u09FF][^()]*)\)\s*$", cell)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    if re.search(r"[\u0980-\u09FF]", cell):
        return "", cell.strip()
    return cell.strip(), ""


def crawl_dhakabusservice(errors):
    idx = "https://dhakabusservice.com/dhaka-local-bus-routes/"
    out = []
    try:
        page = Tables()
        page.feed(get(idx))
    except Exception as e:
        errors.append("dhakabusservice index: %s" % e)
        return out
    urls = []
    for href, _txt in page.links:
        u = urllib.parse.urljoin(idx, href)
        p = urllib.parse.urlsplit(u)
        if p.netloc.endswith("dhakabusservice.com") and (
                re.search(r"[?&]p=\d+", u) or re.search(r"bus-route", p.path)):
            u = u.split("#")[0]
            if u not in urls and u.rstrip("/") != idx.rstrip("/"):
                urls.append(u)
    print("dhakabusservice: %d route pages" % len(urls), file=sys.stderr)
    for u in urls[:MAX_PAGES]:
        try:
            pg = Tables()
            pg.feed(get(u))
        except Exception as e:
            errors.append("dhakabusservice %s: %s" % (u, e))
            continue
        title = html.unescape(pg.h1).strip()
        m = re.match(r"^(.*?)\s*Bus Route\s*[–-]\s*(.*?)\s*(বাস রুট)?\s*$", title)
        company = (m.group(1) if m else title).strip()
        company_bn = (m.group(2) if m else "").replace("বাস রুট", "").strip()
        stops, counters = [], []
        for t in pg.tables:
            hdr = " ".join(t[0]).lower() if t else ""
            rows = [r for r in t[1:] if len(r) >= 2 and r[0].strip().isdigit()]
            if not rows:
                continue
            names = [split_en_bn(r[1]) for r in rows]
            if stops and ("counter" in hdr or "stoppage" in hdr):
                counters = names
            elif not stops:
                stops = names
        if len(stops) >= 3 and company:
            out.append({"company": company, "company_bn": company_bn, "stops": stops,
                        "counters": counters, "source_url": u,
                        "source": "dhakabusservice.com", "fetched": str(date.today())})
    return out


_BLOCK = re.compile(r"(?i)<\s*(br|/p|/h[1-6]|/li|/div|/tr|/td|/strong|/b|p|li|h[1-6])\b[^>]*>")


def html_lines(page):
    """HTML -> plain text lines (block tags become line breaks)."""
    page = re.sub(r"(?is)<(script|style|noscript)\b.*?</\1>", " ", page)
    page = _BLOCK.sub("\n", page)
    page = html.unescape(re.sub(r"<[^>]+>", " ", page))
    out = []
    for ln in page.split("\n"):
        ln = re.sub(r"\s+", " ", ln).strip()
        if ln:
            out.append(ln)
    return out


SEQ_SEP = re.compile(r"\s*(?:⇄|<=>|⟷|↔)\s*")
TITLE = re.compile(r"(?i)\b(bus|paribahan|poribahan|transport|service|express|route)\b|[\u0980-\u09FF]")


def parse_sequences(lines, source, url, fetched):
    """Lines of a route-list page -> [{company, company_bn, stops:[(en,bn)]}].
    A route = the nearest title-like line before a line with 2+ '⇄'."""
    out, title = [], ""
    for ln in lines:
        parts = [x.strip(" .;:-–") for x in SEQ_SEP.split(ln)]
        if len(parts) >= 3:
            # "Route: A ⇄ B" -> drop the label before the first stop
            parts[0] = re.sub(r"^.*?:\s*", "", parts[0]) if ":" in parts[0] else parts[0]
            parts = [p for p in parts if p and len(p) <= 60]
            if len(parts) < 3 or not title:
                continue
            bn_line = all(re.search(r"[\u0980-\u09FF]", p) for p in parts)
            prev = out[-1] if out else None
            if bn_line and prev and prev["_title"] == title and len(prev["stops"]) == len(parts) \
                    and not any(b for _e, b in prev["stops"]):
                prev["stops"] = [(e, b) for (e, _b), b in zip(prev["stops"], parts)]
                continue
            en, bn = title_names(title)
            stops = [("", p) if bn_line else (p, "") for p in parts]
            out.append({"company": en or title, "company_bn": bn, "stops": stops, "counters": [],
                        "source_url": url, "source": source, "fetched": fetched, "_title": title})
            continue
        if len(ln) <= 120 and "⇄" not in ln and TITLE.search(ln) and not re.match(r"(?i)^(service|time|type|see|fare|note|home)\b", ln):
            title = ln
    for r in out:
        r.pop("_title", None)
    return out


def title_names(t):
    """'Achim Paribahan Bus Route (আছিম পরিবহন)' -> ('Achim Paribahan', 'আছিম পরিবহন')"""
    bn = " ".join(x.strip() for x in re.findall(r"[\u0980-\u09FF][\u0980-\u09FF\s\-–.]*", t)).strip(" -–.")
    en = re.sub(r"[\u0980-\u09FF]+", " ", t)
    en = re.sub(r"\(\s*[-–\s.]*\)", " ", en)
    en = re.sub(r"(?i)\b(bus\s+route|route|bus)\b", " ", en)
    en = re.sub(r"\s+", " ", en).strip(" -–:()|")
    return en, bn


def crawl_dhakabusroute(errors, debug):
    """dhakabusroute.com: ONE public index page with every route's stop
    sequence. A different publisher from dhakabusservice.com -> a second
    source for cross-checking (Verified = both agree)."""
    url = "https://www.dhakabusroute.com/"
    try:
        lines = html_lines(get(url))
    except Exception as e:
        errors.append("dhakabusroute index: %s" % e)
        return []
    routes = parse_sequences(lines, "dhakabusroute.com", url, str(date.today()))
    debug["dhakabusroute"] = {"lines": len(lines), "routes": len(routes),
                              "sample": [(r["company"], r["company_bn"], r["stops"][:4]) for r in routes[:3]],
                              "seq_lines": [ln[:200] for ln in lines if "⇄" in ln][:3]}
    if not routes:
        debug["dhakabusroute"]["head"] = lines[:120]
    print("dhakabusroute: %d routes" % len(routes), file=sys.stderr)
    return routes


PHONE = re.compile(r"(?<!\d)((?:\+?88)?0?1\d{3}[- ]?\d{6}|\d{3,5}|0\d{1,2}[- ]?\d{6,8})(?!\d)")
BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def find_hotlines(text):
    """Numbers printed next to 'hotline' / 'call centre' / 'complaint' words
    on an official page (we only report them; a human confirms)."""
    t = re.sub(r"<[^>]+>", " ", text or "").translate(BN_DIGITS)
    t = re.sub(r"\s+", " ", html.unescape(t))
    found = []
    for m in re.finditer(r"(?i)(hot\s*line|call\s*cent(?:er|re)|complain\w*|হটলাইন|কল সেন্টার|অভিযোগ)", t):
        win = t[m.end(): m.end() + 30]          # the number printed right after the word
        nums = PHONE.findall(win)
        if nums:
            n = nums[0].strip()
            if len(re.sub(r"\D", "", n)) >= 3 and n not in [f["number"] for f in found]:
                found.append({"number": n, "context": t[max(0, m.start() - 30): m.end() + 30]})
    return found[:10]


def crawl_text(url, errors):
    try:
        return get(url)
    except Exception as e:
        errors.append("%s: %s" % (url, e))
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--city", default="dhaka")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    errors = []
    debug = {}
    res = {"city": a.city, "fetched": str(date.today()), "ua": UA, "bus_routes": [],
           "bus_routes_2": [], "texts": {}, "errors": errors, "debug": debug}
    if a.city == "dhaka":
        res["bus_routes"] = crawl_dhakabusservice(errors)
        wiki = crawl_text("https://en.wikipedia.org/wiki/"
                          "MRT_Line_6_(Dhaka_Metro_Rail)", errors)
        res["texts"]["wikipedia_mrt6"] = {
            "url": "https://en.wikipedia.org/wiki/MRT_Line_6_(Dhaka_Metro_Rail)",
            "licence": "CC BY-SA 4.0", "text": wiki[:400000]}
        dm = crawl_text("https://dmtcl.gov.bd/", errors)
        res["texts"]["dmtcl_home"] = {"url": "https://dmtcl.gov.bd/",
                                      "text": re.sub(r"<[^>]+>", " ", dm)[:200000]}
        res["bus_routes_2"] = crawl_dhakabusroute(errors, debug)
        hot = []
        for u in ("https://brta.gov.bd/", "http://www.brta.gov.bd/"):
            page = crawl_text(u, errors)
            if page:
                hot = find_hotlines(page)
                res["texts"]["brta_home"] = {"url": u, "hotlines": hot}
                break
    with open("%s/public_%s.json" % (a.out, a.city), "w") as fh:
        json.dump(res, fh, ensure_ascii=False)
    print("public %s: %d bus routes (+%d second source), %d errors" % (
        a.city, len(res["bus_routes"]), len(res["bus_routes_2"]), len(errors)))
    print("debug", json.dumps(debug, ensure_ascii=False)[:4000])
    for e in errors[:20]:
        print("  ERR", e)


if __name__ == "__main__":
    main()
