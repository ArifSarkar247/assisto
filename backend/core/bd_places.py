"""qjourney (owner Safe Journey V2, 9 Nov): our own free Bangladesh place list.

Destination search asks THIS list first (zero Google cost): divisions,
districts, upazilas, unions, cities / towns / city areas, rail stations,
bus terminals, airports, launch ghats, hospitals, universities and metro
stations, in Bangla and English plus the other spellings OpenStreetMap
knows (alt / old / official names). Built by tools/places/build_bd_places.py
from OpenStreetMap (ODbL) into core/data/bd_places.json.

Matching (from the 2nd letter, owner rule):
  exact name > name starts with the text > every typed word starts a word of
  the name > the same "skeleton" (vowels / h / doubled letters ignored, so
  Gaibanda = Gaibandha, Shahjalal = Shajalal) — weighted by how important
  the kind is and how near it is to the phone.
"""
import json
import math
import re
import threading
import unicodedata
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data" / "bd_places.json"
GOOD = 70                 # a "good" match (owner: Google only when < 5 of these)
WANT = 5
KIND_W = {"division": 9, "district": 10, "city": 9, "airport": 9, "station": 6,
          "bus_terminal": 6, "ghat": 6, "metro": 6, "upazila": 5, "town": 5,
          "area": 5, "university": 3, "hospital": 3, "union": 1}
# arrival radius by place type (owner V2: home/office ~150 m; airport, bus
# terminal, rail station, launch ghat, university ~400 m)
RADIUS = {"airport": 400, "bus_terminal": 400, "station": 400, "ghat": 400,
          "university": 400, "metro": 250, "hospital": 250}

_lock = threading.Lock()
_rows = None      # [(kind, en, bn, alt, lat, lng, parent)]
_names = None     # per row: [(norm, skeleton, tokens)]
_index = None     # 2-char prefix -> set(row index)
_source = ""

_ZW = re.compile("[​-‍﻿]")
_SEP = re.compile(r"[^\wঀ-৿]+")


def norm(s):
    s = unicodedata.normalize("NFC", _ZW.sub("", str(s or ""))).lower()
    return " ".join(_SEP.sub(" ", s).split())


def skeleton(word):
    """Latin spelling skeleton: Gaibandha / Gaibanda -> gbnd; Bangla as is."""
    if not word or not ("a" <= word[0] <= "z"):
        return word
    w = word[0] + re.sub(r"[aeiouyhw]", "", word[1:])
    return re.sub(r"(.)\1+", r"\1", w)


def _load():
    global _rows, _names, _index, _source
    if _rows is not None:
        return
    with _lock:
        if _rows is not None:
            return
        rows, names, index = [], [], {}
        src = ""
        try:
            d = json.loads(DATA.read_text(encoding="utf-8"))
            src = d.get("source", "")
            raw = d.get("rows") or []
        except (OSError, ValueError):
            raw = []
        for r in raw:
            kind, en, bn, alt, lat, lng = r[:6]
            parent = r[6] if len(r) > 6 else ""
            i = len(rows)
            rows.append((kind, en, bn, alt, float(lat), float(lng), parent))
            ns = []
            for n in [en, bn] + [a for a in str(alt or "").split(" | ") if a]:
                nn = norm(n)
                if not nn:
                    continue
                toks = nn.split()
                sk = " ".join(skeleton(t) for t in toks)
                ns.append((nn, sk, toks))
                for t in set(toks) | {skeleton(t) for t in toks}:
                    index.setdefault(t[:2], set()).add(i)
            names.append(ns)
        _rows, _names, _index, _source = rows, names, index, src


def available():
    _load()
    return bool(_rows)


def source():
    _load()
    return _source


def _dist_km(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    h = (math.sin((p2 - p1) / 2) ** 2 +
         math.cos(p1) * math.cos(p2) * math.sin(math.radians(d - b) / 2) ** 2)
    return 12742 * math.asin(min(1.0, math.sqrt(h)))


def _score(q, qtoks, qsk, ns):  # noqa: ARG001 (qsk kept for callers)
    best = 0
    for nn, sk, toks in ns:
        if nn == q:
            s = 100
        elif nn.startswith(q):
            s = 90
        elif all(any(t.startswith(x) for t in toks) for x in qtoks):
            s = 78
        elif len(q) >= 4 and all(
                len(skeleton(x)) >= 3 and
                any(t[:2] == x[:2] and skeleton(t).startswith(skeleton(x)) for t in toks)
                for x in qtoks):
            # same first two letters + same consonant skeleton: Gaibanda =
            # Gaibandha, Shajalal = Shahjalal (never Badda = Boda)
            s = 70
        else:
            s = 0
        best = max(best, s)
        if best == 100:
            break
    return best


def search(q, lat=None, lng=None, lang="bn", limit=8):
    """-> [{place_id, name, secondary, lat, lng, kind, radius_m, score, source}]"""
    _load()
    q = norm(q)
    if len(q) < 2 or not _rows:
        return []
    qtoks = q.split()
    qsk = " ".join(skeleton(t) for t in qtoks)
    cand = set()
    for t in {qtoks[0][:2], skeleton(qtoks[0])[:2]}:
        cand |= _index.get(t, set())
    out = []
    for i in cand:
        s = _score(q, qtoks, qsk, _names[i])
        if not s:
            continue
        kind, en, bn, alt, plat, plng, parent = _rows[i]
        rank = s + KIND_W.get(kind, 2)
        km = None
        if lat is not None and lng is not None:
            km = _dist_km(lat, lng, plat, plng)
            rank += 6 if km < 15 else (3 if km < 60 else 0)
        out.append((rank, s, i, km))
    out.sort(key=lambda x: (-x[0], x[3] if x[3] is not None else 0))
    res, seen = [], set()
    for rank, s, i, km in out:
        kind, en, bn, alt, plat, plng, parent = _rows[i]
        name = (bn or en) if lang == "bn" else (en or bn)
        key = (name, round(plat, 2), round(plng, 2))
        if key in seen:
            continue
        seen.add(key)
        row = {"place_id": "bd:%d" % i, "name": name, "secondary": parent,
               "lat": plat, "lng": plng, "kind": kind,
               "radius_m": RADIUS.get(kind, 150 if kind in ("area",) else 300),
               "score": s, "source": "bd"}
        if km is not None:
            row["distance_m"] = int(km * 1000)
        res.append(row)
        if len(res) >= limit:
            break
    return res


def good_count(rows):
    return sum(1 for r in rows if r.get("score", 0) >= GOOD)
