#!/usr/bin/env python3
"""qjourney: build Assisto's free Bangladesh place list from OpenStreetMap.

usage: python3 -I tools/places/build_bd_places.py <raw-dir> <out.json> [previous.json]

sjstart2: + every official union (BBS list, fetch_bbs.sh: 4,540 unions with
Bangla + English names) placed on OpenStreetMap INSIDE its own upazila
(admin 7-10 boundaries, else the union's village of the same name); a union
that cannot be placed is left out (never a guessed point: a wrong point
would mean a wrong "Arrived"). + hospitals (per-division Overpass layers).

<raw-dir> holds the Overpass answers written by tools/places/fetch_osm.sh
(admin4..7, places, rail, bus, air, ferry, hosp, uni, metro). The output is a
compact list the server searches before any paid Google call:

  {"source": "...", "built": "...", "rows": [[kind, en, bn, alt, lat, lng, parent], ...]}

kind: division district upazila union city town area station bus_terminal
      airport ghat hospital university metro
alt:  other spellings (alt_name, old_name, official_name, short_name, int_name),
      " | " joined.
parent: the district (or division) the row lies in, English, when known.
Data © OpenStreetMap contributors, ODbL 1.0.
"""
import json
import math
import re
import sys
import time
from pathlib import Path

LAYERS = [
    ("admin4", "division"), ("admin5", "district"), ("admin6", "upazila"),
    ("admin7", "union"), ("admin8", "union"), ("places", None), ("rail", "station"),
    ("bus", "bus_terminal"), ("air", "airport"), ("ferry", "ghat"),
    ("hosp", "hospital"), ("uni", "university"), ("metro", "metro"),
    # sjstart2: hosp_<division>.json layers are added in main()
]
PLACE_KIND = {"city": "city", "town": "town", "suburb": "area", "quarter": "area",
              "neighbourhood": "area"}
ALT_TAGS = ("alt_name", "old_name", "official_name", "short_name", "int_name",
            "name:en", "alt_name:en", "official_name:en", "loc_name")
BN_TAGS = ("name:bn", "alt_name:bn", "official_name:bn")
# the 2018 official English spellings people still type the old way
OLD_SPELLINGS = {"Chattogram": "Chittagong", "Cumilla": "Comilla", "Barishal": "Barisal",
                 "Jashore": "Jessore", "Bogura": "Bogra"}
# admin words shown as the KIND, not in the name ("Gaibandha", not
# "Gaibandha District"); the full name stays searchable as an alt
SUFFIX_EN = (" City Corporation", " Union Parishad", " Sadar Upazila", " District",
             " Division", " Upazila", " Union", " Thana")
SUFFIX_BN = (" সিটি কর্পোরেশন", " ইউনিয়ন পরিষদ", " জেলা", " বিভাগ", " উপজেলা", " ইউনিয়ন", " থানা")
ADMIN = ("division", "district", "upazila", "union")


def _bn(s):
    return any("ঀ" <= ch <= "৿" for ch in s)


def point(e):
    if "lat" in e and "lon" in e:
        return e["lat"], e["lon"]
    c = e.get("center") or {}
    if "lat" in c and "lon" in c:
        return c["lat"], c["lon"]
    return None


def clean(s, n=120):
    return " ".join(str(s or "").split())[:n]


def row_of(e, kind):
    tags = e.get("tags") or {}
    pt = point(e)
    if pt is None:
        return None
    name = clean(tags.get("name"))
    if not name:
        return None
    en = clean(tags.get("name:en")) or ("" if _bn(name) else name)
    bn = clean(tags.get("name:bn")) or (name if _bn(name) else "")
    if not en and not bn:
        return None
    alts = []
    for t in ALT_TAGS + BN_TAGS:
        for v in str(tags.get(t) or "").split(";"):
            v = clean(v)
            if v and v not in (en, bn) and v not in alts:
                alts.append(v)
    if name not in (en, bn) and name not in alts:
        alts.append(name)
    if kind in ADMIN:
        for full, sufs in ((en, SUFFIX_EN), (bn, SUFFIX_BN)):
            for sfx in sufs:
                if full.endswith(sfx) and len(full) > len(sfx) + 1:
                    short = full[: -len(sfx)].strip()
                    if sfx == " Sadar Upazila":
                        short += " Sadar"
                    if full not in alts:
                        alts.append(full)
                    if full is en:
                        en = short
                    else:
                        bn = short
                    break
    for new, old in OLD_SPELLINGS.items():
        if en.startswith(new) and old not in alts:
            alts.append(en.replace(new, old, 1))
    if kind == "airport" and not (tags.get("iata") or tags.get("icao")):
        return None             # airstrips / helipads without a code
    return [kind, en, bn, " | ".join(alts)[:300], round(pt[0], 5), round(pt[1], 5)]


# ---- sjstart2: official unions (BBS) placed on OSM --------------------------
_DIR = {"north": "n", "uttar": "n", "uttor": "n", "south": "s", "dakshin": "s",
        "dakkhin": "s", "dokkhin": "s", "dakhin": "s", "east": "e", "purba": "e",
        "purbo": "e", "west": "w", "paschim": "w", "poschim": "w", "pashchim": "w",
        "char": "c", "sadar": "", "union": "", "parishad": "", "up": "",
        "pourashava": "", "paurashava": "", "municipality": ""}
_BN_DROP = ("ইউনিয়ন পরিষদ", "ইউনিয়ন", "পৌরসভা")


def key_en(name):
    """Spelling-tolerant key: Gunaighor = Gunaighar; North X = Uttar X."""
    words = re.sub(r"[^a-z ]+", " ", str(name or "").lower()).split()
    out = []
    for w in words:
        if w in _DIR:
            if _DIR[w]:
                out.append(_DIR[w])
            continue
        sk = w[0] + re.sub(r"[aeiouyhw]", "", w[1:])
        out.append(re.sub(r"(.)\1+", r"\1", sk))
    return " ".join(out)


def key_bn(name):
    s = str(name or "")
    for d in _BN_DROP:
        s = s.replace(d, " ")
    return " ".join(s.split())


def km(a_lat, a_lng, b_lat, b_lng):
    x = math.radians(b_lng - a_lng) * math.cos(math.radians((a_lat + b_lat) / 2))
    y = math.radians(b_lat - a_lat)
    return 6371 * math.hypot(x, y)


def _table(path):
    d = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(d, list):
        for t in d:
            if isinstance(t, dict) and t.get("type") == "table":
                return t.get("data") or []
        return [x for x in d if isinstance(x, dict) and "name" in x]
    return d.get("data") or []


def _elements(raw, pattern):
    for f in sorted(raw.glob(pattern)):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except ValueError:
            print("bad layer", f.name, file=sys.stderr)
            continue
        for e in d.get("elements") or []:
            yield e


def bbs_unions(raw, upazila_rows, stats):
    """[(row, osm_key)] for every BBS union placed inside its upazila."""
    need = [raw / ("bbs_%s.json" % n) for n in ("districts", "upazilas", "unions")]
    if not all(f.exists() for f in need):
        print("no BBS list: unions from OSM levels 7/8 only", file=sys.stderr)
        return []
    dists = {d["id"]: d for d in _table(need[0])}
    upas = {u["id"]: u for u in _table(need[1])}
    unions = _table(need[2])
    # OSM candidates: admin boundaries (7-10) first, then villages
    cands = {}

    def add(e, prio):
        tags = e.get("tags") or {}
        pt = point(e)
        if pt is None:
            return
        names = {tags.get(t) for t in ("name", "name:en", "alt_name", "old_name", "official_name")}
        bns = {tags.get(t) for t in ("name:bn", "name") if _bn(tags.get(t) or "")}
        ref = "%s/%s" % (e.get("type"), e.get("id"))
        for n in names:
            if n and not _bn(n):
                cands.setdefault(("en", key_en(n)), []).append((prio, pt, ref, tags))
        for n in bns:
            if n:
                cands.setdefault(("bn", key_bn(n)), []).append((prio, pt, ref, tags))

    for e in _elements(raw, "unions_*.json"):
        add(e, 0)
    for e in _elements(raw, "admin7.json"):
        add(e, 0)
    for e in _elements(raw, "admin8.json"):
        add(e, 0)
    for e in _elements(raw, "upoffice_*.json"):
        add(e, 0)
    for e in _elements(raw, "villages_*.json"):
        add(e, 1)
    # OSM upazila centres by key, to anchor each BBS upazila
    upa_pts = {}
    for r in upazila_rows:
        for n in [r[1]] + [a for a in r[3].split(" | ") if a and not _bn(a)]:
            upa_pts.setdefault(key_en(n), []).append((r[4], r[5]))
        if r[2]:
            upa_pts.setdefault(("bn", key_bn(r[2])), []).append((r[4], r[5]))
    out = []
    for u in unions:
        up = upas.get(u.get("upazilla_id") or u.get("upazila_id")) or {}
        di = dists.get(up.get("district_id")) or {}
        try:
            d_lat, d_lng = float(di["lat"]), float(di["lon"])
        except (KeyError, TypeError, ValueError):
            stats["no_district"] += 1
            continue
        anchors = [p for p in upa_pts.get(key_en(up.get("name")), []) +
                   upa_pts.get(("bn", key_bn(up.get("bn_name"))), [])
                   if km(p[0], p[1], d_lat, d_lng) <= 80]
        if anchors:
            a_lat, a_lng = min(anchors, key=lambda p: km(p[0], p[1], d_lat, d_lng))
            radius = 25
        else:
            a_lat, a_lng, radius = d_lat, d_lng, 45
            stats["district_anchor"] += 1
        best = None
        for k in (("en", key_en(u.get("name"))), ("bn", key_bn(u.get("bn_name")))):
            if not k[1]:
                continue
            for prio, pt, ref, tags in cands.get(k, []):
                dd = km(pt[0], pt[1], a_lat, a_lng)
                if dd > radius:
                    continue
                score = (prio, dd)
                if best is None or score < best[0]:
                    best = (score, pt, ref, tags)
        if best is None:
            stats["unplaced"] += 1
            continue
        _, pt, ref, tags = best
        en = clean(u.get("name"))
        bn = clean(u.get("bn_name"))
        alts = []
        for v in (tags.get("name"), tags.get("name:en"), tags.get("name:bn"),
                  en + " Union" if en else "", bn + " ইউনিয়ন" if bn else ""):
            v = clean(v)
            if v and v not in (en, bn) and v not in alts:
                alts.append(v)
        stats["placed_boundary" if best[0][0] == 0 else "placed_village"] += 1
        parent = clean(di.get("name"))
        for new, old in OLD_SPELLINGS.items():   # official 2018 spelling shown
            if parent == old:
                parent = new
        out.append(([
            "union", en, bn, " | ".join(alts)[:300], round(pt[0], 5), round(pt[1], 5), parent,
        ], ref))
    return out


def main():
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    rows, seen = [], set()
    stamp = ""
    stats = {"no_district": 0, "district_anchor": 0, "unplaced": 0,
             "placed_boundary": 0, "placed_village": 0}
    layers = list(LAYERS)
    # sjstart2: per-division hospital layers (the whole-country query timed out)
    layers += [(f.stem, "hospital") for f in sorted(raw.glob("hosp_*.json"))]
    # per-division admin 7-10: levels 7/8 are rows as before (9/10 are only
    # used to place the official unions below)
    layers += [(f.stem, "union") for f in sorted(raw.glob("unions_*.json"))]
    for layer, kind in layers:
        f = raw / ("%s.json" % layer)
        if not f.exists():
            print("missing layer", layer, file=sys.stderr)
            continue
        d = json.loads(f.read_text(encoding="utf-8"))
        stamp = stamp or ((d.get("osm3s") or {}).get("timestamp_osm_base") or "")
        for e in d.get("elements") or []:
            k = kind or PLACE_KIND.get((e.get("tags") or {}).get("place", ""))
            if not k:
                continue
            if layer.startswith("unions_") and \
                    (e.get("tags") or {}).get("admin_level") not in ("7", "8"):
                continue
            r = row_of(e, k)
            if r is None:
                continue
            key = (r[0], r[1].lower(), r[2], round(r[4], 2), round(r[5], 2))
            if key in seen:
                continue
            seen.add(key)
            r.append("%s/%s" % (e.get("type"), e.get("id")))   # temp: OSM ref
            rows.append(r)
    # sjstart2: official unions; an OSM level-7/8 row they were placed on is
    # replaced by the official one (Bangla + English from BBS)
    placed = bbs_unions(raw, [r for r in rows if r[0] == "upazila"], stats)
    used = {ref for _, ref in placed}
    rows = [r for r in rows if not (r[0] == "union" and r[-1] in used)]
    for r in rows:
        r.pop()                                              # drop the OSM ref
    have = {(r[0], r[1].lower(), round(r[4], 2), round(r[5], 2)) for r in rows}
    bbs_rows = []
    for r, _ in placed:
        k = (r[0], r[1].lower(), round(r[4], 2), round(r[5], 2))
        if k not in have:
            have.add(k)
            bbs_rows.append(r)
    # parent district: the nearest district centre (cheap, good enough to
    # tell two "Sadar" upazilas apart in the list)
    dists = [(r[1] or r[2], r[4], r[5]) for r in rows if r[0] == "district"]
    for r in rows:
        if r[0] in ("division", "district") or not dists:
            r.append("")
            continue
        best = min(dists, key=lambda d: (d[1] - r[4]) ** 2 + (d[2] - r[5]) ** 2)
        r.append(best[0])
    rows += bbs_rows
    # a layer Overpass answered EMPTY (busy mirror) never wipes what the
    # last good build had: keep the previous rows of that kind
    if len(sys.argv) > 3 and Path(sys.argv[3]).exists():
        prev = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8")).get("rows") or []
        now = {r[0] for r in rows}
        kept = {}
        for r in prev:
            if r[0] not in now and r[0] != "union":
                rows.append(r)
                kept[r[0]] = kept.get(r[0], 0) + 1
        if kept:
            print("kept from the previous list (empty layer now):", kept)
    rows.sort(key=lambda r: (r[0], r[1] or r[2]))
    out.write_text(json.dumps({
        "source": "OpenStreetMap contributors (ODbL 1.0), Overpass snapshot %s; "
                  "union names: Bangladesh BBS/a2i list via github.com/nuhil/bangladesh-geocode (MIT)" % stamp,
        "built": time.strftime("%Y-%m-%d"),
        "rows": rows,
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    by = {}
    for r in rows:
        by[r[0]] = by.get(r[0], 0) + 1
    print(len(rows), by)
    print("unions (BBS):", stats)


if __name__ == "__main__":
    main()
