"""adminboards (owner 9 Nov): read-only parser for the two owner progress files
    owner_actions/OWNER_VISION_CHECKLIST_BN.md  (every item the owner asked for)
    owner_actions/QUALITY_BOARD_BN.md           (each launch feature, /10)
The markdown files in the deployed repo ARE the source of truth: nothing is
copied to the DB. Parsed at request time behind a tiny cache keyed on the
file's mtime+size, so a STATUS update to a file shows on the next page load.
No user data is read here."""
import re
import threading
from pathlib import Path

from django.conf import settings

VISION_FILE = "OWNER_VISION_CHECKLIST_BN.md"
QUALITY_FILE = "QUALITY_BOARD_BN.md"
PASS_SCORE = 9          # the owner's bar: a feature is ready at >= 9/10

_BN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_CACHE = {}
_LOCK = threading.Lock()

STATUS_DONE, STATUS_PARTIAL, STATUS_MISSING, STATUS_UNKNOWN = "done", "partial", "missing", "unknown"
STATUSES = (STATUS_DONE, STATUS_PARTIAL, STATUS_MISSING, STATUS_UNKNOWN)
_EMOJI = (("✅", STATUS_DONE), ("🟡", STATUS_PARTIAL), ("❌", STATUS_MISSING))


def owner_actions_dir():
    d = getattr(settings, "OWNER_BOARDS_DIR", None)
    return Path(d) if d else Path(settings.BASE_DIR).resolve().parent / "owner_actions"


def to_ascii_digits(s):
    return (s or "").translate(_BN)


def to_int(s):
    m = re.search(r"\d+", to_ascii_digits(s))
    return int(m.group()) if m else None


def plain(s):
    """Markdown cell -> plain text (bold/code marks dropped; the template escapes)."""
    s = (s or "").strip()
    s = s.replace("**", "").replace("`", "")
    return s.replace("<br>", " · ").strip()


def _cells(line):
    line = line.strip()
    if not (line.startswith("|") and line.endswith("|")):
        return None
    return [c.strip() for c in line[1:-1].split("|")]


def _is_sep(cells):
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", c or "") for c in cells)


def _tables(text):
    """Yield (heading, header_cells, [row_cells...]) for every pipe table."""
    heading, header, rows, prev = "", None, [], None
    for raw in text.splitlines():
        if raw.startswith("#"):
            heading = raw.lstrip("#").strip()
        cells = _cells(raw)
        if cells is None:
            if header is not None:
                yield heading_at, header, rows
            header, rows, prev = None, [], None
            continue
        if header is None:
            if _is_sep(cells) and prev is not None:
                header, rows, heading_at = prev, [], heading
            prev = cells
            continue
        rows.append(cells)
    if header is not None:
        yield heading_at, header, rows


def _read(path):
    try:
        st = path.stat()
    except OSError:
        return None, None
    key = (str(path), st.st_mtime_ns, st.st_size)
    return key, st


def _cached(path, parse):
    key, st = _read(path)
    if key is None:
        return None
    with _LOCK:
        hit = _CACHE.get(str(path))
        if hit and hit[0] == key:
            return hit[1]
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    data = parse(text)
    data["file"] = path.name
    data["mtime"] = st.st_mtime
    with _LOCK:
        _CACHE[str(path)] = (key, data)
    return data


def _date_line(text):
    m = re.search(r"\*\*তারিখ:\*\*\s*([^·\n]+)", text)
    return plain(m.group(1)).rstrip("।. ") if m else ""


# ------------------------------------------------------------------ vision
def _status_of(cell):
    for emoji, st in _EMOJI:
        if emoji in cell:
            return st
    return STATUS_UNKNOWN


def parse_vision(text):
    items = []
    for heading, header, rows in _tables(text):
        m = re.search(r"গুরুত্ব\s*([০-৯0-9])", heading)
        importance = to_int(m.group(1)) if m else None
        if len(header) < 7:
            continue
        for c in rows:
            if len(c) < 7:
                continue
            n = to_int(c[0])
            if n is None:
                continue
            feat = c[1]
            items.append({
                "n": n,
                "importance": importance,
                "launch_critical": "লঞ্চ-জরুরি" in feat or importance == 1,
                "feature": plain(feat),
                "title": plain(feat).split(" — ")[0].replace("⭐লঞ্চ-জরুরি", "").strip(),
                "status": _status_of(c[2]),
                "status_text": plain(c[2]),
                "missing": plain(c[3]),
                "plan": plain(c[4]),
                "world_class": plain(c[5]),
                "owner_items": plain(c[6]),
            })
    counts = {s: 0 for s in STATUSES}
    for it in items:
        counts[it["status"]] += 1
    return {"items": items, "counts": counts, "total": len(items), "date": _date_line(text)}


# ----------------------------------------------------------------- quality
def parse_quality(text):
    rows_out = []
    for _heading, header, rows in _tables(text):
        if len(header) < 11:
            continue
        for c in rows:
            if len(c) < 11:
                continue
            n = to_int(c[0])
            if n is None:
                continue
            scores = [to_int(x) for x in c[3:9]]
            total = to_int(c[9])
            if total is None and all(s is not None for s in scores):
                total = min(scores)          # the board's own rule: total = lowest
            rows_out.append({
                "n": n, "feature": plain(c[1]), "best_app": plain(c[2]),
                "scores": scores, "total": total,
                "missing": plain(c[10]),
                "ready": total is not None and total >= PASS_SCORE,
            })
    passed = sum(1 for r in rows_out if r["ready"])
    return {"rows": rows_out, "total": len(rows_out), "passed": passed,
            "below": len(rows_out) - passed, "date": _date_line(text)}


def vision():
    return _cached(owner_actions_dir() / VISION_FILE, parse_vision)


def quality():
    return _cached(owner_actions_dir() / QUALITY_FILE, parse_quality)


def clear_cache():
    with _LOCK:
        _CACHE.clear()


def summary():
    """Counts for the 21:00 daily report (management command board_summary)."""
    q, v = quality(), vision()
    out = {}
    if q is not None:
        out["quality"] = {"total": q["total"], "passed": q["passed"], "below": q["below"],
                          "date": q["date"]}
    if v is not None:
        crit = [i for i in v["items"] if i["importance"] == 1]
        out["vision"] = {"total": v["total"], "date": v["date"], **v["counts"],
                         "launch_critical_total": len(crit),
                         "launch_critical_done": sum(1 for i in crit if i["status"] == STATUS_DONE)}
    return out
