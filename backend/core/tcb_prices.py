"""moneybar: official Dhaka retail market prices from TCB (Trading Corporation
of Bangladesh, a government body) for the Market price radar.

Source: https://tcb.gov.bd/pages/daily-rmps — TCB publishes one Excel file a
working day ("ঢাকা মহানগরীর নিত্য প্রয়োজনীয় পণ্যের দৈনিক খুচরা বাজার দর"):
item, unit, today's min / max, 1 week ago, 1 month ago, 1 year ago.

* ``latest_xlsx_url(html)`` — newest .xlsx link on the listing page. Only
  links on TCB's own object-storage host are accepted (ALLOWED_FILE_HOSTS).
* ``parse_xlsx(data)`` — rows -> items; group headers ("ডাল", "মসলাঃ") become
  each item's ``group``; rows with no price today (0 / blank / "#DIV/0!") are
  skipped — we never show a price TCB did not publish.
* ``fetch_and_store()`` — download + parse + atomic write of one JSON file
  (no DB table, no migration). Idempotent: the same file twice = same JSON.
* ``load()`` — what GET /prices/official serves; None when never fetched.

TLS: tcb.gov.bd serves an incomplete certificate chain (Python cannot verify
it), so ONLY the listing page is read without verification — it yields just a
link, which must point at the pinned file host, and the file itself is
downloaded WITH verification. Nothing from the listing page is shown to users.
"""
import io
import json
import logging
import os
import re
import tempfile
from datetime import date, datetime
from urllib.parse import urlparse

from django.conf import settings
from django.utils import timezone

log = logging.getLogger(__name__)

LIST_URL = "https://tcb.gov.bd/pages/daily-rmps"
ALLOWED_FILE_HOSTS = ("objectstorage.ap-dcc-gazipur-1.oraclecloud15.com",)
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_ITEMS = 400
TIMEOUT_S = 25
STALE_DAYS = 4   # older than this -> the app says "TCB has not published since"

_XLSX_RE = re.compile(r'href="(https://[^"\s]+\.xlsx)"', re.I)


def store_path():
    return getattr(settings, "TCB_PRICES_PATH",
                   os.path.join(str(settings.BASE_DIR), "logs", "tcb_prices.json"))


def latest_xlsx_url(html):
    """First (= newest; the page lists newest first) .xlsx link on an allowed
    host, or None."""
    for url in _XLSX_RE.findall(html or ""):
        if urlparse(url).hostname in ALLOWED_FILE_HOSTS:
            return url
    return None


def _num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().replace(",", "")
    # Bangla digits -> Latin
    s = "".join(chr(ord(c) - 0x09E6 + 0x30) if "০" <= c <= "৯" else c for c in s)
    try:
        return float(s)
    except ValueError:
        return None


def _taka(v):
    """Price cell -> whole/decimal taka, or None when not published (0/blank)."""
    n = _num(v)
    if n is None or n <= 0:
        return None
    return int(n) if n == int(n) else round(n, 2)


def _clean(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()


def parse_rows(rows):
    """rows = iterable of tuples (one per sheet row). -> {date, items}."""
    items, group, day, markets = [], "", None, None
    header_seen = False
    seen = set()
    for row in rows:
        row = list(row or ()) + [None] * 12
        name, unit = _clean(row[0]), _clean(row[1])
        if isinstance(row[2], (datetime, date)) and day is None:
            d = row[2]
            day = (d.date() if isinstance(d, datetime) else d).isoformat()
            header_seen = True
            continue
        if not header_seen or not name:
            continue
        if name.startswith("যে সকল"):
            # end of the main table: the markets line, then a repeat summary
            if "বাজার" in name.split("হতে")[0] and markets is None:
                markets = _clean(" ".join(_clean(c) for c in row[1:12] if c))[:300]
            break
        if name.startswith("পণ্যের নাম"):
            continue
        if not unit and _taka(row[2]) is None and _taka(row[3]) is None:
            group = name.rstrip(":ঃ ").strip()   # a section header row
            continue
        lo, hi = _taka(row[2]), _taka(row[3])
        if lo is None and hi is None:
            continue   # not published today (e.g. imported onion = 0)
        key = (name, unit)
        if key in seen:
            continue
        seen.add(key)
        lo, hi = lo or hi, hi or lo
        if lo > hi:
            lo, hi = hi, lo
        items.append({
            "name": name[:80], "unit": unit[:40], "group": group[:40],
            "min": lo, "max": hi,
            "week_min": _taka(row[4]), "week_max": _taka(row[5]),
            "month_min": _taka(row[6]), "month_max": _taka(row[7]),
            "year_min": _taka(row[9]), "year_max": _taka(row[10]),
        })
        if len(items) >= MAX_ITEMS:
            break
    return {"date": day, "items": items, "markets": markets or ""}


def parse_xlsx(data):
    import openpyxl
    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)
    try:
        ws = wb.worksheets[0]
        return parse_rows(ws.iter_rows(values_only=True, max_col=12))
    finally:
        wb.close()


def _get(url, verify=True):
    import warnings
    import requests
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")   # InsecureRequestWarning (listing page only)
        r = requests.get(url, timeout=TIMEOUT_S, verify=verify, stream=True,
                         headers={"User-Agent": "Assisto price radar (lifeassisto.com)"})
    r.raise_for_status()
    buf = io.BytesIO()
    for chunk in r.iter_content(65536):
        buf.write(chunk)
        if buf.tell() > MAX_FILE_BYTES:
            raise ValueError("file too large")
    return buf.getvalue()


def _write_atomic(path, payload):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tcb-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def fetch_and_store(getter=None, path=None):
    """-> (status, payload). status: 'updated' | 'unchanged' | 'no_link' |
    'empty'. getter(url, verify) -> bytes (tests inject one)."""
    get = getter or _get
    html = get(LIST_URL, verify=False).decode("utf-8", errors="replace")
    url = latest_xlsx_url(html)
    if not url:
        return "no_link", None
    parsed = parse_xlsx(get(url, verify=True))
    if not parsed["items"] or not parsed["date"]:
        return "empty", None
    path = path or store_path()
    old = load(path)
    payload = {"source": "TCB", "source_url": LIST_URL, "file_url": url,
               "date": parsed["date"], "items": parsed["items"],
               "markets": parsed.get("markets", "")}
    if old and old.get("date") == payload["date"] and old.get("items") == payload["items"]:
        return "unchanged", old
    payload["fetched_at"] = timezone.now().isoformat()
    _write_atomic(path, payload)
    return "updated", payload


def load(path=None):
    try:
        with open(path or store_path(), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) and data.get("items") else None
    except (OSError, ValueError):
        return None


def public_view(today=None):
    """What the app gets. Never invents: connected=False when nothing stored."""
    data = load()
    if not data:
        return {"connected": False, "source": "TCB", "source_url": LIST_URL, "items": []}
    today = today or timezone.localdate()
    stale = False
    try:
        stale = (today - date.fromisoformat(data["date"])).days > STALE_DAYS
    except (KeyError, ValueError, TypeError):
        stale = True
    return {"connected": True, "source": "TCB", "source_url": LIST_URL,
            "date": data.get("date"), "fetched_at": data.get("fetched_at"),
            "stale": stale, "markets": data.get("markets", ""),
            "items": data.get("items", [])}
