#!/usr/bin/env python3
"""Compile the OFFICIAL Bangladesh Railway timetable into one JSON file.

Inputs (committed, backend/core/data/train/br_source/):
  west_lists.json  west zone train lists, parsed from the text layer of the
                   official PDF (tools/train/br/dump_grid.py + bijoy_fix.py)
  west_abbr.json   west zone per-stop intercity schedule (parse_west_grid.py)
  east_lists.txt   east zone train lists, hand-transcribed from the scanned
                   official PDF (no text layer)
  east_abbr.txt    east zone per-stop intercity schedule, hand-transcribed
Output:
  backend/core/data/train/br_official.json

Every train keeps its source URL + date. Pure / offline / deterministic.
Usage: python3 tools/train/br/compile_official.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(ROOT, "backend", "core", "data", "train", "br_source")
OUT = os.path.join(ROOT, "backend", "core", "data", "train", "br_official.json")
sys.path.insert(0, HERE)
from station_names import ALIAS, CANON, MERGED, PAIRS, SOURCE_FIXES  # noqa: E402

PDF_BASE = "https://objectstorage.ap-dcc-gazipur-1.oraclecloud15.com/n/axvjbnqprylg/b/V2Ministry/o/office-railway/2024/12/"
SOURCES = {
    "east": {
        "page": "https://railway.gov.bd/pages/static-pages/691997bf933eb65569ddec51",
        "file": PDF_BASE + "667d364484f84ac7b06d7e8e8804b2c9.pdf",
        "sha256": "d6e1af80252d98b45e8a07e7c30be1ec51f94ddf4b3c942daf4cc3a697137cc9",
        "title": "পূর্বাঞ্চলের ট্রেনের সময়সূচি (Bangladesh Railway, East zone; PDF modified 2025-03-12)",
        "edition": "2025-03-12",
    },
    "west": {
        "page": "https://railway.gov.bd/pages/static-pages/691997b8933eb65569dde71d",
        "file": PDF_BASE + "59b5aa56840546f1a05b0741b8cca044.pdf",
        "sha256": "bc40965826c3f597469d1ddff402b5d78bd340ac3512c22aab944ec28d2de533",
        "title": "পশ্চিমাঞ্চলের ট্রেনের সময়সূচি (Bangladesh Railway, West zone; PDF modified 2025-03-12)",
        "edition": "2025-03-12",
    },
    "intl": {
        "page": "https://railway.gov.bd/pages/static-pages/691997c4933eb65569ddefc1",
        "title": "আন্তঃদেশীয় যাত্রীবাহী ট্রেনের সময়সূচি (বিগত ১৮.০৭.২০২৪ ইং তারিখ হতে যাত্রা স্থগিত রয়েছে)",
        "edition": "page as seen 2026-11-17",
    },
}
FETCHED = "2026-11-17"
WEEKDAYS = {"সোমবার": 0, "মঙ্গলবার": 1, "বুধবার": 2, "বৃহস্পতিবার": 3, "বৃহস্প তিবার": 3,
            "শুক্রবার": 4, "ʹক্রবার": 4, "শনিবার": 5, "রবিবার": 6}
BN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
EN_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def nuk(s):
    """One spelling for the nukta letters (precomposed ড় ঢ় য়)."""
    return (s or "").replace("\u09a1\u09bc", "\u09dc").replace("\u09a2\u09bc", "\u09dd").replace("\u09af\u09bc", "\u09df")


def key(name):
    return re.sub(r"[\s.\-]", "", nuk(name).translate(BN))


CANON = {nuk(k): v for k, v in CANON.items()}
ALIAS = {key(k): nuk(v) for k, v in ALIAS.items()}
MERGED = {key(k): [nuk(x) for x in v] for k, v in MERGED.items()}
CANON_KEYS = {key(k): k for k in CANON}
PAIRS = {(key(a), key(b)): (nuk(x), nuk(y)) for (a, b), (x, y) in PAIRS.items()}


def canon(name, zone=None):
    k = key(name)
    if not k:
        return None
    if zone == "east" and k == key("নোয়াপাড়া"):
        return nuk("নোয়াপাড়া (হবিগঞ্জ)")
    if k in ALIAS:
        return ALIAS[k]
    if k in CANON_KEYS:
        return CANON_KEYS[k]
    return None


def hhmm(v):
    if v is None:
        return None
    v = re.sub(r"\D", "", str(v).translate(BN))
    if not v:
        return None
    v = v.zfill(4)
    h, m = int(v[:2]), int(v[2:])
    if h > 24 or m > 59:
        raise ValueError("bad time %r" % v)
    if h == 24:
        h = 0
    return "%02d:%02d" % (h, m)


def mins_(v):
    return int(v[:2]) * 60 + int(v[3:])


def kind_of(no, name):
    if str(no).startswith("31") and len(str(no)) == 4:
        return "international"
    if re.fullmatch(r"\d+", str(no)) and 700 <= int(no) <= 899:
        return "intercity"
    if "মেইল" in name:
        return "mail"
    if "লোকাল" in name or "মিশ্র" in name:
        return "local"
    return "commuter"


ERR = []


def problem(msg):
    ERR.append(msg)


# ---------------------------------------------------------------- west lists
def west_lists():
    pages = json.load(open(os.path.join(SRC, "west_lists.json"), encoding="utf-8"))
    trains = []
    for pg in sorted(pages, key=int):
        for row in pages[pg]:
            cells = [c.strip() for c in row]
            nonempty = [c for c in cells if c]
            if not nonempty or not re.search(r"।$", nonempty[0]):
                continue
            serial = nonempty[0]
            rest = nonempty[1:]
            no_raw = rest[0]
            rest = rest[1:]
            if no_raw.translate(BN).startswith("31"):
                continue  # international: taken from the dedicated official page
            # name = following cells until an off-day / station / time cell
            name_parts, off, stations, times, route = [], None, [], [], None
            for c in rest:
                cc = c.replace(" ", "")
                if re.fullmatch(r"[0-9০-৯]{3,4}", c.replace(" ", "")):
                    times.append(c)
                elif c in WEEKDAYS or cc in {k.replace(" ", "") for k in WEEKDAYS}:
                    off = WEEKDAYS.get(c, WEEKDAYS.get(c.replace(" ", ""), None))
                    if off is None:
                        off = {k.replace(" ", ""): v for k, v in WEEKDAYS.items()}[cc]
                elif c == "-":
                    continue
                elif "-" in c and not times and canon(c.split("-")[0]):
                    route = c
                elif c.startswith("-") and not times and stations and canon(c[1:]):
                    route = stations.pop() + c
                elif canon(c) and (name_parts or no_raw == "ডেমু"):
                    stations.append(canon(c))
                elif not stations and not times:
                    name_parts.append(c)
                elif c in ("িড়",):
                    continue
                else:
                    problem("west list p%s %s: stray cell %r" % (pg, serial, c))
            name = " ".join(name_parts)
            name = (name.replace("এক্সপ্রেস", " এক্সপ্রেস").replace("কমিউটার", " কমিউটার")
                    .replace("মেইল", " মেইল").replace("সাটল", " শাটল").replace("  ", " ").strip())
            name = re.sub(r"\s+", " ", name)
            trains.append({"page": int(pg), "serial": serial, "no_raw": no_raw, "name_bn": name,
                           "off": off, "stations": stations, "times": [hhmm(t) for t in times],
                           "route": route})
    return trains


NAME_FIX = {
    "রুপসা এক্সপ্রেস": "রূপসা এক্সপ্রেস", "রুপসীবাংলা এক্সপ্রেস": "রূপসী বাংলা এক্সপ্রেস",
    "বুড়িমারী এক্সপ্রেস": "বুড়িমারী এক্সপ্রেস", "দ্রুতযান এক্সপ্রেস": "দ্রুতযান এক্সপ্রেস",
    "প্রত্যাবিত..... এক্সপ্রেস": "প্রস্তাবিত এক্সপ্রেস (ঢাকা–পাবনা)",
    "প্রস্তাবিত..... এক্সপ্রেস": "প্রস্তাবিত এক্সপ্রেস (ঢাকা–পাবনা)",
    "মল্লাি কা কমিউটার": "মল্লিকা কমিউটার", "মল্লাি কাকমিউটার": "মল্লিকা কমিউটার",
    "বগুড়িড়া কমিউটার": "বগুড়া কমিউটার", "বগুড়ি ড়া কমিউটার": "বগুড়া কমিউটার",
    "নকশিকাঁথা কমিউটার": "নকশীকাঁথা কমিউটার",
    "ঈশাখাঁ মেইল": "ঈশাখাঁ মেইল",
}


NAME_SUB = [("সিক্সসিটি", "সিল্কসিটি"), ("সাগরদাড়ী", "সাগরদাঁড়ী"), ("বগুড়ি ড়া", "বগুড়া"), ("বগুড়িড়া", "বগুড়া"),
            ("শাটল", " শাটল"), ("টুঙ্গিপাড়া", "টুঙ্গীপাড়া"), ("প্রস্তাবিত.....", "প্রস্তাবিত")]


def clean_name(n):
    n = nuk(n).replace("প্রত্য াবিত", "প্রস্তাবিত")
    for a, b in NAME_SUB:
        n = n.replace(nuk(a), nuk(b))
    n = re.sub(r"\s+", " ", n).strip()
    if n in ("তযান এক্সপ্রেস", "যান এক্সপ্রেস"):
        n = "দ্রুতযান এক্সপ্রেস"
    n = n.replace("িড়", "").strip()
    n = NAME_FIX.get(n, n)
    if n == "প্রস্তাবিত এক্সপ্রেস":
        n = "প্রস্তাবিত এক্সপ্রেস (ঢাকা–পাবনা)"
    n = n.replace("প্রত্য াবিত", "প্রস্তাবিত")
    return n


# ---------------------------------------------------------------- west abbr
def west_abbr():
    blocks = json.load(open(os.path.join(SRC, "west_abbr.json"), encoding="utf-8"))
    by = {}
    for b in blocks:
        stops = [list(s) for s in b["stops"]]
        # split merged header cells into the empty neighbour column(s)
        i = 0
        out = []
        for s in stops:
            out.append(s)
        stops = out
        for i in range(len(stops) - 1):
            pk = (key(stops[i][0]), key(stops[i + 1][0]))
            if pk in PAIRS:
                stops[i][0], stops[i + 1][0] = PAIRS[pk]
        for i, s in enumerate(stops):
            k = key(s[0])
            if k not in MERGED:
                continue
            parts = MERGED[k]
            prev_empty = i > 0 and not stops[i - 1][0]
            next_empty = i + 1 < len(stops) and not stops[i + 1][0]
            if len(parts) == 3 and prev_empty and next_empty:
                stops[i - 1][0], s[0], stops[i + 1][0] = parts
            elif len(parts) == 2 and next_empty:
                s[0], stops[i + 1][0] = parts
            elif len(parts) == 2 and prev_empty:
                stops[i - 1][0], s[0] = parts
            else:
                problem("west abbr %s: merged header %r with no empty neighbour" % (b["no"], s[0]))
        res = []
        for s in stops:
            c = canon(s[0], "west")
            if not c:
                problem("west abbr %s: unknown station %r" % (b["no"], s[0]))
                continue
            res.append([c, hhmm(s[1]), hhmm(s[2])])
        by.setdefault(b["no"], []).extend(res)
    return by


# ---------------------------------------------------------------- west station pages
STATION_PAGES = {"4": "খুলনা", "5": "রাজশাহী", "6": "সান্তাহার", "7": "পার্বতীপুর", "8": "লালমনিরহাট"}


def west_station_pages():
    """Rows of the official 'trains from station X' tables: an extra
    official time at a junction for trains that otherwise have only their
    origin + destination times (mail / commuter / local)."""
    pages = json.load(open(os.path.join(SRC, "west_stations.json"), encoding="utf-8"))
    out = []
    for pg in sorted(pages, key=int):
        station = STATION_PAGES[pg]
        for row in pages[pg]:
            cells = [c.strip() for c in row if c.strip()]
            if any("হতে" in c for c in cells) and any(canon(c) for c in cells):
                station = next(canon(c) for c in cells if canon(c))
                continue
            if not cells or not cells[0].endswith("।") or len(cells) < 9:
                continue
            no = re.sub(r"\D", "", cells[1].translate(BN))
            vals = cells[-6:]
            arr, dep = (None if re.fullmatch(r"[-.]+", v) else hhmm(v) for v in vals[:2])
            out.append((no, nuk(station), arr, dep))
    return out


# ---------------------------------------------------------------- east files
def east_abbr():
    by = {}
    for line in open(os.path.join(SRC, "east_abbr.txt"), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        stops = []
        for p in parts[1:]:
            nm, t = p.rsplit(" ", 1)
            a, d = t.split("/")
            c = canon(nm, "east")
            if not c:
                problem("east abbr %s: unknown station %r" % (parts[0], nm))
                continue
            stops.append([c, hhmm(a) if a != "-" else None, hhmm(d) if d != "-" else None])
        by[parts[0]] = stops
    return by


def east_lists():
    out = []
    for line in open(os.path.join(SRC, "east_lists.txt"), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        no, name, off, o, dep, d, arr, kind, status = line.split("|")
        out.append({"no": no, "name_bn": name, "off": WEEKDAYS[off] if off else None,
                    "origin": canon(o, "east"), "dep": hhmm(dep) if dep else None,
                    "dest": canon(d, "east"), "arr": hhmm(arr) if arr else None,
                    "kind": kind, "status": status})
        if not out[-1]["origin"] or not out[-1]["dest"]:
            problem("east list %s: unknown station %r/%r" % (no, o, d))
    return out


INTL = [
    # no, name_bn, name_en, BD terminal, BD time (dep if out else arr), direction, foreign terminal, run days
    ("3107", "মৈত্রী এক্সপ্রেস", "Maitree Express", "ঢাকা ক্যান্টনমেন্ট", "08:15", "out", "কলকাতা", [4, 6, 1]),
    ("3110", "মৈত্রী এক্সপ্রেস", "Maitree Express", "ঢাকা ক্যান্টনমেন্ট", "08:15", "out", "কলকাতা", [5, 2]),
    ("3108", "মৈত্রী এক্সপ্রেস", "Maitree Express", "ঢাকা ক্যান্টনমেন্ট", "16:05", "in", "কলকাতা", [5, 0, 2]),
    ("3109", "মৈত্রী এক্সপ্রেস", "Maitree Express", "ঢাকা ক্যান্টনমেন্ট", "16:05", "in", "কলকাতা", [4, 1]),
    ("3130", "বন্ধন এক্সপ্রেস", "Bandhan Express", "খুলনা", "13:30", "out", "কলকাতা", [6, 3]),
    ("3129", "বন্ধন এক্সপ্রেস", "Bandhan Express", "খুলনা", "12:30", "in", "কলকাতা", [6, 3]),
    ("3131", "মিতালী এক্সপ্রেস", "Mitali Express", "ঢাকা ক্যান্টনমেন্ট", "21:50", "out", "নিউ জলপাইগুড়ি", [0, 3]),
    ("3132", "মিতালী এক্সপ্রেস", "Mitali Express", "ঢাকা ক্যান্টনমেন্ট", "22:30", "in", "নিউ জলপাইগুড়ি", [6, 2]),
]

EN_NAMES = {
    "সুবর্ণ এক্সপ্রেস": "Subarna Express", "মহানগর গোধূলী": "Mohanagar Godhuli", "মহানগর প্রভাতী": "Mohanagar Provati",
    "তিস্তা এক্সপ্রেস": "Tista Express", "পারাবত এক্সপ্রেস": "Parabat Express", "উপকূল এক্সপ্রেস": "Upakul Express",
    "জয়ন্তিকা এক্সপ্রেস": "Joyontika Express", "পাহাড়িকা এক্সপ্রেস": "Paharika Express",
    "মহানগর এক্সপ্রেস": "Mohanagar Express", "উদয়ন এক্সপ্রেস": "Udayan Express", "মেঘনা এক্সপ্রেস": "Meghna Express",
    "অগ্নিবীণা এক্সপ্রেস": "Agnibina Express", "এগারসিন্ধুর প্রভাতী": "Egarosindhur Provati",
    "উপবন এক্সপ্রেস": "Upaban Express", "তূর্ণা এক্সপ্রেস": "Turna Express", "ব্রহ্মপুত্র এক্সপ্রেস": "Brahmaputra Express",
    "যমুনা এক্সপ্রেস": "Jamuna Express", "এগারসিন্ধুর গোধূলী": "Egarosindhur Godhuli", "কালনী এক্সপ্রেস": "Kalni Express",
    "হাওর এক্সপ্রেস": "Haor Express", "কিশোরগঞ্জ এক্সপ্রেস": "Kishoreganj Express", "বিজয় এক্সপ্রেস": "Bijoy Express",
    "সোনার বাংলা এক্সপ্রেস": "Sonar Bangla Express", "মোহনগঞ্জ এক্সপ্রেস": "Mohanganj Express",
    "জামালপুর এক্সপ্রেস": "Jamalpur Express", "চট্টলা এক্সপ্রেস": "Chattala Express",
    "কক্সবাজার এক্সপ্রেস": "Cox's Bazar Express", "পর্যটক এক্সপ্রেস": "Parjatak Express", "সৈকত এক্সপ্রেস": "Saikat Express",
    "প্রবাল এক্সপ্রেস": "Prabal Express", "সুবর্ণচর এক্সপ্রেস": "Subarnachar Express", "টাঙ্গুয়ার এক্সপ্রেস": "Tanguar Express",
    "একতা এক্সপ্রেস": "Ekota Express", "করতোয়া এক্সপ্রেস": "Karatoa Express", "কপোতাক্ষ এক্সপ্রেস": "Kapotaksha Express",
    "সুন্দরবন এক্সপ্রেস": "Sundarban Express", "রূপসা এক্সপ্রেস": "Rupsha Express", "বরেন্দ্র এক্সপ্রেস": "Barendra Express",
    "তিতুমীর এক্সপ্রেস": "Titumir Express", "সীমান্ত এক্সপ্রেস": "Simanta Express", "লালমনি এক্সপ্রেস": "Lalmoni Express",
    "সিল্কসিটি এক্সপ্রেস": "Silk City Express", "মধুমতি এক্সপ্রেস": "Modhumoti Express", "দ্রুতযান এক্সপ্রেস": "Drutojan Express",
    "পদ্মা এক্সপ্রেস": "Padma Express", "সাগরদাঁড়ী এক্সপ্রেস": "Sagardari Express", "চিত্রা এক্সপ্রেস": "Chitra Express",
    "নীলসাগর এক্সপ্রেস": "Nilsagar Express", "দোলনচাঁপা এক্সপ্রেস": "Dolonchapa Express", "ধূমকেতু এক্সপ্রেস": "Dhumketu Express",
    "রংপুর এক্সপ্রেস": "Rangpur Express", "সিরাজগঞ্জ এক্সপ্রেস": "Sirajganj Express", "ঢালারচর এক্সপ্রেস": "Dhalarchar Express",
    "টুঙ্গীপাড়া এক্সপ্রেস": "Tungipara Express", "বনলতা এক্সপ্রেস": "Banalata Express", "পঞ্চগড় এক্সপ্রেস": "Panchagarh Express",
    "বেনাপোল এক্সপ্রেস": "Benapole Express", "কুড়িগ্রাম এক্সপ্রেস": "Kurigram Express", "বাংলাবান্ধা এক্সপ্রেস": "Banglabandha Express",
    "চিলাহাটি এক্সপ্রেস": "Chilahati Express", "বুড়িমারী এক্সপ্রেস": "Burimari Express", "জাহানাবাদ এক্সপ্রেস": "Jahanabad Express",
    "রূপসী বাংলা এক্সপ্রেস": "Rupshi Bangla Express", "প্রস্তাবিত এক্সপ্রেস (ঢাকা–পাবনা)": "Proposed Express (Dhaka–Pabna)",
    "ঢাকা মেইল": "Dhaka Mail", "চট্টগ্রাম মেইল": "Chattogram Mail", "কর্ণফুলী কমিউটার": "Karnaphuli Commuter",
    "সুরমা মেইল": "Surma Mail", "নোয়াখালী মেইল": "Noakhali Mail", "জালালাবাদ মেইল": "Jalalabad Mail",
    "সাগরিকা কমিউটার": "Sagarika Commuter", "তিতাস কমিউটার": "Titas Commuter", "ময়মনসিংহ মেইল": "Mymensingh Mail",
    "ঈশাখাঁ মেইল": "Isha Khan Mail", "মহুয়া কমিউটার": "Mohua Commuter", "সমতট মেইল": "Samatat Mail",
    "দেওয়ানগঞ্জ কমিউটার": "Dewanganj Commuter", "বলাকা কমিউটার": "Balaka Commuter", "জামালপুর কমিউটার": "Jamalpur Commuter",
    "ভাওয়াল মেইল": "Bhawal Mail", "ধলেশ্বরী মেইল": "Dhaleshwari Mail", "লোকাল": "Local", "মিশ্র": "Mixed",
    "কুশিয়ারা মেইল": "Kushiyara Mail", "রাজশাহী কমিউটার": "Rajshahi Commuter", "মহানন্দা মেইল": "Mohananda Mail",
    "বগুড়া কমিউটার": "Bogura Commuter", "পদ্মরাগ কমিউটার": "Padmarag Commuter", "রকেট মেইল": "Rocket Mail",
    "নকশীকাঁথা কমিউটার": "Nakshikantha Commuter", "ঘাঘট মেইল": "Ghaghot Mail", "উত্তরা মেইল": "Uttara Mail",
    "কাঞ্চন কমিউটার": "Kanchan Commuter", "বেতনা কমিউটার": "Betna Commuter", "ঈশ্বরদী কমিউটার": "Ishwardi Commuter",
    "রামসাগর মেইল": "Ramsagar Mail", "দিনাজপুর কমিউটার": "Dinajpur Commuter", "লালমনি কমিউটার": "Lalmoni Commuter",
    "বুড়িমারী কমিউটার": "Burimari Commuter", "রহনপুর কমিউটার": "Rohanpur Commuter", "মোংলা কমিউটার": "Mongla Commuter",
    "কুড়িগ্রাম শাটল": "Kurigram Shuttle", "ঢাকা কমিউটার": "Dhaka Commuter", "রাজবাড়ী মেইল": "Rajbari Mail",
    "ভাটিয়াপাড়া মেইল": "Bhatiapara Mail", "চাঁপাইনবাবগঞ্জ শাটল": "Chapainawabganj Shuttle", "পাবনা শাটল": "Pabna Shuttle",
    "চন্দনা কমিউটার": "Chandana Commuter", "ভাঙ্গা কমিউটার": "Bhanga Commuter", "পুনর্ভবা কমিউটার": "Punarbhaba Commuter",
    "মল্লিকা কমিউটার": "Mallika Commuter", "অপরাজিতা কমিউটার": "Aparajita Commuter", "উত্তরবঙ্গ মেইল": "Uttarbanga Mail",
    "রংপুর কমিউটার": "Rangpur Commuter", "পঞ্চগড় কমিউটার": "Panchagarh Commuter", "পার্বতীপুর কমিউটার": "Parbatipur Commuter",
    "চিলমারী কমিউটার": "Chilmari Commuter", "তুরাগ কমিউটার": "Turag Commuter", "নারায়ণগঞ্জ কমিউটার": "Narayanganj Commuter",
    "টাঙ্গাইল কমিউটার": "Tangail Commuter", "জয়দেবপুর কমিউটার": "Joydebpur Commuter",
    "চাঁদপুর কমিউটার (ডেমু)": "Chandpur Commuter (DEMU)", "নোয়াখালী কমিউটার (ডেমু)": "Noakhali Commuter (DEMU)",
}
BN_TO_EN_DIGIT = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


EN_NAMES = {nuk(k): v for k, v in EN_NAMES.items()}


def en_name(bn, no):
    bn = nuk(bn)
    base = re.sub(r"[-–]\s*[০-৯0-9]+$", "", bn).strip()
    suffix = re.search(r"[-–]\s*([০-৯0-9]+)$", bn)
    en = EN_NAMES.get(bn) or EN_NAMES.get(base)
    if not en:
        if bn.startswith("আন্তঃনগর"):
            return "Intercity %s (name not announced)" % no
        problem("no English name for %r" % bn)
        return bn
    if suffix and not EN_NAMES.get(bn):
        en += "-" + suffix.group(1).translate(BN_TO_EN_DIGIT)
    return en


def build():
    trains = []
    wabbr = west_abbr()
    eabbr = east_abbr()
    # ---- west
    for t in west_lists():
        raw = t["no_raw"].translate(BN)
        name = clean_name(t["name_bn"])
        if raw.startswith("31"):
            continue  # international: handled from the dedicated official page below
        if raw == "ডেমু":
            m = re.search(r"[-–]\s*([0-9০-৯]+)$", name)
            base = "RNG" if "রংপুর" in name else "PNC"
            no = "%s-%s" % (base, (m.group(1) if m else "").translate(BN))
        else:
            no = re.sub(r"\D", "", raw)
        if name in ("......শাটল-১", "...... শাটল-১", "শাটল-১") or (name.endswith("শাটল-১") and "চাঁপাই" not in name and "কুড়ি" not in name):
            name = "পাবনা শাটল-১"
        if name.endswith("শাটল-২") and "চাঁপাই" not in name and "কুড়ি" not in name:
            name = "পাবনা শাটল-২"
        if name in ("লোকাল", "মিশ্র") or t["route"]:
            name = name
        st = t["stations"]
        tm = [x for x in t["times"] if x]
        if len(st) != 2 or len(tm) != 2:
            problem("west list %s %s: stations=%r times=%r" % (t["serial"], no, st, tm))
            continue
        status = "proposed" if "প্রস্তাবিত" in name else "running"
        trains.append({"no": no, "name_bn": name, "zone": "west", "off": t["off"], "origin": st[0],
                       "dep": tm[0], "dest": st[1], "arr": tm[1], "status": status,
                       "kind": kind_of(no, name)})
    # ---- east
    for t in east_lists():
        t = dict(t)
        t["zone"] = "east"
        trains.append(t)
    # ---- stops
    extra = {}
    for no, st_name, a_, d_ in west_station_pages():
        extra.setdefault(no, []).append((st_name, a_, d_))
    xcheck = []
    seen = set()
    final = []
    for t in trains:
        if t["no"] in seen:
            problem("duplicate train number %s" % t["no"])
            continue
        seen.add(t["no"])
        abbr = (wabbr if t["zone"] == "west" else eabbr).get(t["no"])
        if abbr:
            stops = [{"st": s[0], "arr": s[1], "dep": s[2], "src": "official"} for s in abbr]
            if not stops[0]["dep"]:
                stops[0]["dep"] = stops[0]["arr"]
            if not stops[-1]["arr"]:
                stops[-1]["arr"] = stops[-1]["dep"]
            stops[0]["arr"] = None
            stops[-1]["dep"] = None
            for fno, fst, ff, printed, fixed, why in SOURCE_FIXES:
                for s in stops:
                    if t["no"] == fno and s["st"] == nuk(fst) and s[ff] == printed:
                        s[ff] = fixed
                        s["note"] = "corrected: %s" % why
        elif t["status"] == "suspended":
            stops = [{"st": t["origin"], "arr": None, "dep": None, "src": "official"},
                     {"st": t["dest"], "arr": None, "dep": None, "src": "official"}]
        else:
            stops = [{"st": t["origin"], "arr": None, "dep": t["dep"], "src": "official"},
                     {"st": t["dest"], "arr": t["arr"], "dep": None, "src": "official"}]
        # official junction times from the station pages
        for st_name, a_, d_ in extra.get(t["no"], []):
            have = next((s for s in stops if s["st"] == st_name), None)
            if have is not None:
                for f, v in (("arr", a_), ("dep", d_)):
                    if v and have.get(f) and have[f] != v:
                        xcheck.append("%s %s %s: schedule %s, station page %s" % (t["no"], st_name, f, have[f], v))
                continue
            if t["status"] != "running" or not (a_ or d_) or not stops[0]["dep"]:
                continue
            t0 = mins_(stops[0]["dep"])
            off = (mins_(a_ or d_) - t0) % 1440
            pos = len(stops) - 1
            for j in range(1, len(stops)):
                v = stops[j]["arr"] or stops[j]["dep"]
                if v and (mins_(v) - t0) % 1440 > off:
                    pos = j
                    break
            stops.insert(pos, {"st": st_name, "arr": a_ or d_, "dep": d_ or a_, "src": "official",
                               "note": "official station timetable (%s)" % st_name})
        # cross-check terminals against the train list
        if abbr and t["status"] != "suspended":
            if stops[0]["st"] != t["origin"] or stops[-1]["st"] != t["dest"]:
                problem("%s: terminals %s→%s in schedule vs %s→%s in list" % (
                    t["no"], stops[0]["st"], stops[-1]["st"], t["origin"], t["dest"]))
            if stops[0]["dep"] != t["dep"] or stops[-1]["arr"] != t["arr"]:
                problem("%s: times %s→%s in schedule vs %s→%s in list" % (
                    t["no"], stops[0]["dep"], stops[-1]["arr"], t["dep"], t["arr"]))
        # monotonic times (with day roll-over); total run < 24 h
        prev, day, total = None, 0, 0
        for s in stops:
            for f in ("arr", "dep"):
                v = s.get(f)
                if not v:
                    continue
                mins = int(v[:2]) * 60 + int(v[3:])
                if prev is not None:
                    d = mins - prev
                    if d < 0:
                        d += 1440
                    if d > (300 if t["kind"] == "intercity" else 600) and len(stops) > 2:
                        problem("%s: %d-minute gap before %s %s" % (t["no"], d, s["st"], f))
                    total += d
                prev = mins
        if total >= 1440:
            problem("%s: runs %d minutes" % (t["no"], total))
        if len({s["st"] for s in stops}) != len(stops):
            problem("%s: a station repeats" % t["no"])
        src = SOURCES[t["zone"]]
        off = [t["off"]] if t.get("off") is not None else []
        final.append({
            "no": t["no"], "name_bn": t["name_bn"], "name_en": en_name(t["name_bn"], t["no"]),
            "kind": t["kind"], "zone": t["zone"], "status": t["status"],
            "origin": t["origin"], "destination": t["dest"], "off_days": off,
            "stops": stops,
            "source": {"url": src["page"], "file": src.get("file"), "edition": src["edition"], "fetched": FETCHED},
        })
    # ---- international (Bangladesh section only)
    for no, bn, en, bd, tm, direction, foreign, run in INTL:
        bn, bd, foreign = nuk(bn), nuk(bd), nuk(foreign)
        src = SOURCES["intl"]
        if direction == "out":
            stops = [{"st": bd, "arr": None, "dep": tm, "src": "official"}]
            o, d = bd, foreign
        else:
            stops = [{"st": bd, "arr": tm, "dep": None, "src": "official"}]
            o, d = foreign, bd
        final.append({
            "no": no, "name_bn": bn, "name_en": en, "kind": "international", "zone": "intl",
            "status": "suspended", "status_note": "বিগত ১৮.০৭.২০২৪ তারিখ হতে যাত্রা স্থগিত (railway.gov.bd)",
            "origin": o, "destination": d, "off_days": [x for x in range(7) if x not in run],
            "stops": stops, "bd_section_only": True,
            "source": {"url": src["page"], "file": None, "edition": src["edition"], "fetched": FETCHED},
        })
    XCHECK[:] = xcheck
    return final


XCHECK = []


def main():
    trains = build()
    stations = sorted({s["st"] for t in trains for s in t["stops"]} | {t["origin"] for t in trains} | {t["destination"] for t in trains})
    unknown = [s for s in stations if s not in CANON]
    for s in unknown:
        problem("station not in CANON: %r" % s)
    doc = {
        "_meta": {
            "title": "Bangladesh Railway official passenger timetable (all zones)",
            "sources": SOURCES, "fetched": FETCHED,
            "method": "west zone: text layer of the official PDF (legacy Bangla font decoded by tools/train/br/bijoy_fix.py, table grid by gridlib.py); east zone: hand transcription of the scanned official PDF; per-stop times are the official 'abbreviated schedule' (major stops) for intercity trains, mail/commuter/local trains have official origin + destination times only",
            "not_included": "freight/container trains (601-608), the 19 west-zone departmental/PNV services, unnumbered suspended DEMU commuters (Nazirhat, Chittagong University, Kaliakair, Narayanganj DEMU) — listed in owner_actions/TRAIN_TRACKER_V2_BN.md",
            "weekday": "off_days: 0=Monday … 6=Sunday",
            "built_by": "tools/train/br/compile_official.py",
            "cross_check": "station-page times that differ from the abbreviated schedule (kept: schedule)",
            "cross_check_diffs": XCHECK,
        },
        "trains": trains,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print("trains", len(trains), "stations", len(stations))
    for e in ERR:
        print("PROBLEM:", e)
    return 1 if ERR else 0


if __name__ == "__main__":
    sys.exit(main())
