"""
pa_shoot.py — the deterministic engine behind PA SECRETARY MODE (celebrity tier)
SHOOTING / CONCERT LOGISTICS — call-sheet builder (issue #124, SPEC v2.1 §14,
ADVANCED).

A performer's PA builds the EVENT-DAY call-sheet by hand, offline, with NO key:
a call-sheet header (title, date, call-time, location), an ordered SCHEDULE of
time-blocks (scene / soundcheck / set / break), a WARDROBE list, an EQUIPMENT
checklist, a crew/cast CONTACTS list, and a "what to bring" prep list. This
engine orders the schedule chronologically, tallies checklist progress, and
produces a deterministic printable call-sheet SUMMARY.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.
Nothing is fetched or invented — every name, time and item is one the PA typed.
Mirrors the conventions of the other pa_*/logic modules.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_shoot_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Schedule block kinds (neutral English seed keys; the UI localises them).
BLK_SCENE = "scene"
BLK_SOUNDCHECK = "soundcheck"
BLK_SET = "set"
BLK_BREAK = "break"
BLK_TRAVEL = "travel"
BLK_OTHER = "other"
BLOCK_KINDS = (BLK_SCENE, BLK_SOUNDCHECK, BLK_SET, BLK_BREAK, BLK_TRAVEL,
               BLK_OTHER)


# ------------------------------------------------------------------ parsing

def _parse(dt):
    if not dt:
        return None
    s = str(dt).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


def _parse_time(t):
    """Lenient HH:MM (24h) → minutes-since-midnight, or None. Accepts a full
    datetime too (uses its time). Never raises."""
    if not t:
        return None
    s = str(t).strip()
    if not s:
        return None
    dt = _parse(s)
    if dt is not None and ("T" in s or " " in s):
        return dt.hour * 60 + dt.minute
    parts = s.split(":")
    try:
        h = int(parts[0])
        m = int(parts[1]) if len(parts) > 1 else 0
    except (ValueError, IndexError):
        return None
    if not (0 <= h < 24 and 0 <= m < 60):
        return None
    return h * 60 + m


def _clean(text):
    return " ".join(str(text or "").split()).strip()


# ------------------------------------------------------------- normalization

def normalize_sheet(sheet):
    """Coerce a dict into a clean call-sheet header. Never raises."""
    x = dict(sheet or {})
    return {
        "id": x.get("id"),
        "title": _clean(x.get("title")),
        "date": (str(x.get("date")).strip() if x.get("date") else ""),
        "call_time": _clean(x.get("call_time")),
        "location": _clean(x.get("location")),
        "note": str(x.get("note") or ""),
    }


def normalize_block(block):
    """Coerce a dict into a clean schedule block. Unknown kind → other."""
    x = dict(block or {})
    kind = x.get("kind")
    if kind not in BLOCK_KINDS:
        kind = BLK_OTHER
    return {
        "id": x.get("id"),
        "sheet_id": x.get("sheet_id"),
        "kind": kind,
        "label": _clean(x.get("label")),
        "start": _clean(x.get("start")),  # HH:MM the PA typed
        "end": _clean(x.get("end")),
        "note": str(x.get("note") or ""),
    }


def normalize_contact(contact):
    """Coerce a dict into a clean crew/cast contact."""
    x = dict(contact or {})
    return {
        "id": x.get("id"),
        "sheet_id": x.get("sheet_id"),
        "name": _clean(x.get("name")),
        "role": _clean(x.get("role")),
        "phone": _clean(x.get("phone")),
    }


def normalize_check(item):
    """Coerce a dict into a clean wardrobe / equipment / prep checklist item.
    `kind` tags which list it belongs to (free string; UI groups by it)."""
    x = dict(item or {})
    return {
        "id": x.get("id"),
        "sheet_id": x.get("sheet_id"),
        "kind": _clean(x.get("kind")) or "equipment",
        "label": _clean(x.get("label")),
        "checked": bool(x.get("checked")),
    }


# ------------------------------------------------------------------- validate

def validate_sheet(sheet):
    """A call-sheet needs a title; date must parse if present."""
    x = normalize_sheet(sheet)
    problems = []
    if not x["title"]:
        problems.append("title_required")
    if x["date"] and _parse(x["date"]) is None:
        problems.append("bad_date")
    return problems


def validate_block(block):
    """A block needs a label; start must parse as HH:MM if present; end must
    not be before start when both parse."""
    x = normalize_block(block)
    problems = []
    if not x["label"]:
        problems.append("label_required")
    s = _parse_time(x["start"]) if x["start"] else None
    e = _parse_time(x["end"]) if x["end"] else None
    if x["start"] and s is None:
        problems.append("bad_start")
    if x["end"] and e is None:
        problems.append("bad_end")
    if s is not None and e is not None and e < s:
        problems.append("end_before_start")
    return problems


# ------------------------------------------------------------------ ordering

def order_blocks(blocks):
    """Schedule in chronological (start) order; untimed blocks last. Stable
    (ties → label, id)."""
    normed = [normalize_block(x) for x in (blocks or [])]

    def key(b):
        m = _parse_time(b["start"])
        return (m is None, m if m is not None else 0, b["label"].lower(),
                str(b.get("id") or ""))
    return sorted(normed, key=key)


# ---------------------------------------------------------------- derived

def checklist_progress(items, kind=None):
    """{"total","checked","percent"} for checklist items, optionally filtered to
    one `kind`. percent is floor(checked/total*100), 0 on empty. Deterministic."""
    normed = [normalize_check(x) for x in (items or [])]
    if kind is not None:
        normed = [x for x in normed if x["kind"] == kind]
    total = len(normed)
    checked = sum(1 for x in normed if x["checked"])
    percent = (checked * 100 // total) if total else 0
    return {"total": total, "checked": checked, "percent": percent}


# ---------------------------------------------------------------- summary

def callsheet_summary(sheet, blocks=None, contacts=None, checks=None):
    """A deterministic, printable call-sheet roll-up — pure structure the UI
    renders (no prose generated here). Ordered schedule + counts + overall
    checklist progress, identical every time. Nothing is fetched or invented."""
    s = normalize_sheet(sheet)
    ob = order_blocks(blocks)
    oc = [normalize_contact(x) for x in (contacts or [])]
    prog = checklist_progress(checks)
    return {
        "sheet": s,
        "schedule": ob,
        "contacts": oc,
        "checklist": prog,
        "counts": {
            "blocks": len(ob),
            "contacts": len(oc),
            "checks": prog["total"],
        },
        "mock": False,
    }
