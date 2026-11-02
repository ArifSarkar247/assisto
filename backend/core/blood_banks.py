"""blood_banks.py — the blood bank list (finish1, 2 Nov).

RULE (owner, no invented data): the list comes ONLY from an official /
recognised published list the OWNER supplies (DGHS, Bangladesh Red Crescent,
Sandhani, a government hospital directory ...), with its source name, link
and publication date. Nothing here ships a single entry. Until the owner
imports a file the app shows the honest "source pending" state.

  * import: `manage.py import_blood_banks <file.csv> --source-name ...
    --source-url https://... --source-date YYYY-MM-DD [--dry-run]`
    (parse_csv validates every row; nothing is written if any row is bad);
  * store: one JSON file outside the repo (settings.BLOOD_BANKS_FILE, default
    backend/private/blood_banks.json — git-ignored), written atomically;
  * read: load() is cached by the file's mtime; blood_panel.banks() filters
    by district / text and sorts by distance when the phone sends a point.

CSV columns (header row, English names; extra columns ignored):
    name*        bank / hospital unit name (as published)
    district*    district code, English or Bangla name (Chittagong, চট্টগ্রাম ...)
    phone        at least one of phone / address
    address
    area         thana / area (optional)
    kind         govt | red_crescent | ngo | private | hospital (optional)
    hours        e.g. "24 hours" (optional, as published)
    lat, lng     optional, must be inside Bangladesh
"""
from __future__ import annotations

import csv
import io
import json
import os
import re
import tempfile
from datetime import date

from django.conf import settings
from django.utils import timezone

from .logic import missing_rules as MR

MAX_ROWS = 3000
KINDS = ("govt", "red_crescent", "ngo", "private", "hospital")
REQUIRED = ("name", "district")
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
# older / common spellings in published lists -> our district codes
ALIASES = {
    "chittagong": "chattogram", "comilla": "cumilla", "barisal": "barishal",
    "jessore": "jashore", "bogra": "bogura", "nawabganj": "chapainawabganj",
    "chapai nawabganj": "chapainawabganj", "moulvi bazar": "moulvibazar",
    "maulvibazar": "moulvibazar", "netrakona": "netrokona", "jhalakati": "jhalokati",
    "khagrachari": "khagrachhari", "laxmipur": "lakshmipur", "brahmanbaria": "brahmanbaria",
    "coxs bazar": "coxsbazar", "cox's bazar": "coxsbazar",
}


def store_path():
    default = os.path.join(str(settings.BASE_DIR), "private", "blood_banks.json")
    return str(getattr(settings, "BLOOD_BANKS_FILE", "") or default)


# ------------------------------------------------------------------ parsing
def district_code(raw):
    s = str(raw or "").strip()
    if not s:
        return ""
    low = re.sub(r"\s+", " ", s.lower().replace("district", "").replace("জেলা", "")).strip()
    if MR.district(low):
        return low
    low2 = ALIASES.get(low, low)
    if MR.district(low2):
        return low2
    squeezed = low.replace(" ", "").replace("-", "").replace("'", "")
    for code, en, bn, _la, _ln in MR.DISTRICTS:
        if squeezed in (code, en.lower().replace(" ", "").replace("'", "")) or s.replace("জেলা", "").strip() == bn:
            return code
    return ""


def clean_phone(raw):
    """Keep what was published (digits, +, -, spaces, commas for several
    numbers) but require at least one BD-looking number."""
    s = str(raw or "").translate(_BN_DIGITS).strip()
    s = re.sub(r"[^0-9+,/ \-]", "", s)[:60].strip(" ,/-")
    digits = [re.sub(r"\D", "", p) for p in re.split(r"[,/]", s)]
    ok = any(7 <= len(d) <= 13 for d in digits)
    return s if ok else None


def _clean_text(v, n):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


def _clean_date(raw):
    try:
        d = date.fromisoformat(str(raw or "").strip())
    except ValueError:
        return None
    return d if d <= timezone.localdate() else None


def parse_csv(text):
    """-> (rows, errors). errors = ["row 4: district 'Xyz' unknown", ...].
    Duplicate (name, district) rows are merged into one (first wins)."""
    errors, rows, seen = [], [], set()
    rd = csv.DictReader(io.StringIO(text.lstrip("﻿")))
    cols = {c.strip().lower() for c in (rd.fieldnames or []) if c}
    missing = [c for c in REQUIRED if c not in cols]
    if missing:
        return [], ["header: missing column(s) %s" % ", ".join(missing)]
    if not ({"phone", "address"} & cols):
        return [], ["header: needs a phone or an address column"]
    for i, raw in enumerate(rd, start=2):
        r = {str(k or "").strip().lower(): (v or "") for k, v in raw.items()}
        if not any(str(v).strip() for v in r.values()):
            continue
        if len(rows) >= MAX_ROWS:
            errors.append("more than %d rows" % MAX_ROWS)
            break
        name = _clean_text(r.get("name"), 120)
        code = district_code(r.get("district"))
        phone_raw = _clean_text(r.get("phone"), 80)
        phone = clean_phone(phone_raw) if phone_raw else ""
        address = _clean_text(r.get("address"), 200)
        kind = _clean_text(r.get("kind"), 20).lower().replace(" ", "_")
        bad = []
        if not name:
            bad.append("name empty")
        if not code:
            bad.append("district %r unknown" % _clean_text(r.get("district"), 40))
        if phone is None:
            bad.append("phone %r not a number" % phone_raw)
        if not phone and not address:
            bad.append("needs a phone or an address")
        if kind and kind not in KINDS:
            bad.append("kind %r (use %s)" % (kind, "|".join(KINDS)))
        lat = lng = None
        if str(r.get("lat") or "").strip() or str(r.get("lng") or "").strip():
            try:
                lat, lng = float(r.get("lat")), float(r.get("lng"))
            except (TypeError, ValueError):
                lat = lng = None
            if lat is None or not MR.in_bangladesh(lat, lng):
                bad.append("lat/lng not in Bangladesh")
                lat = lng = None
        if bad:
            errors.append("row %d: %s" % (i, "; ".join(bad)))
            continue
        key = (name.lower(), code)
        if key in seen:
            continue
        seen.add(key)
        rows.append({"name": name, "district": code, "phone": phone or "",
                     "address": address, "area": _clean_text(r.get("area"), 60),
                     "kind": kind, "hours": _clean_text(r.get("hours"), 40),
                     "lat": round(lat, 5) if lat is not None else None,
                     "lng": round(lng, 5) if lng is not None else None})
    if not rows and not errors:
        errors.append("no rows")
    return rows, errors


def check_source(name, url, published):
    """The source is mandatory (no list without a named, dated source)."""
    errs = []
    name = _clean_text(name, 120)
    url = str(url or "").strip()
    if not name:
        errs.append("--source-name is required")
    if not re.match(r"^https?://[^\s/]+\.[^\s]+$", url):
        errs.append("--source-url must be the http(s) link where the list is published")
    d = _clean_date(published)
    if d is None:
        errs.append("--source-date must be the list's publication date, YYYY-MM-DD, not in the future")
    return ({"name": name, "url": url[:300], "date": d.isoformat() if d else ""}, errs)


# ------------------------------------------------------------------ store
def save(rows, source, at=None):
    at = at or timezone.now()
    data = {"version": 1, "source": dict(source, imported_at=at.isoformat(), rows=len(rows)),
            "banks": rows}
    path = store_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".blood_banks.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)
    _CACHE.clear()
    return data


def clear():
    try:
        os.remove(store_path())
    except FileNotFoundError:
        pass
    _CACHE.clear()


_CACHE = {}


def load():
    """{"source": {...} | None, "banks": [...]} — never raises."""
    path = store_path()
    try:
        mt = os.path.getmtime(path)
    except OSError:
        return {"source": None, "banks": []}
    hit = _CACHE.get(path)
    if hit and hit[0] == mt:
        return hit[1]
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        src = data.get("source") if isinstance(data, dict) else None
        banks = data.get("banks") if isinstance(data, dict) else None
        if not (isinstance(src, dict) and src.get("name") and src.get("url")
                and isinstance(banks, list)):
            data = {"source": None, "banks": []}     # never show an unsourced list
        else:
            data = {"source": src, "banks": banks}
    except (OSError, ValueError):
        data = {"source": None, "banks": []}
    _CACHE[path] = (mt, data)
    return data
