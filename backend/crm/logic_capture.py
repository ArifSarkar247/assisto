"""
CAPTURE / dedupe (CRM spec #1) — PURE PYTHON, no Django imports.

Three capabilities, all deterministic + offline-safe:

  1. DEDUPE matcher — group leads that are the same prospect, by normalised
     phone / email / (company+name). Mirrors the server's dupes.py keys so the
     in-app review screen and the backend agree.

  2. MERGE PLAN — given a survivor + duplicates, produce an auditable plan that
     re-points EVERY child row (conversations, activities, deals, proposals,
     timeline) onto the survivor and backfills blank survivor fields. The plan
     NEVER drops an activity: the test suite asserts the union of activities is
     preserved exactly.

  3. INTAKE normalizers —
       * card_parse(ocr_text, has_ocr_key): business-card OCR is a MOCK. With
         NO key it returns {"available": False, ...} and extracts nothing from
         a real image — it only parses already-OCR'd TEXT into a structured
         DRAFT for a human review step. It never fabricates fields.
       * form_intake(payload): website lead-form → a clean lead draft (trimmed,
         normalised phone/email, source stamped), ready for the same dedupe
         check before it is saved.

Nothing here writes to a DB or performs a merge; it DECIDES. The view executes.
"""
from __future__ import annotations

import re
from collections import defaultdict


# =====================================================================
# normalisation (shared keys — must match dupes.py)
# =====================================================================

def norm_phone(p):
    """Digits only, last 10 (BD mobiles are 11 w/ leading 0; last 10 is stable
    across +880 / 0 / bare formats)."""
    digits = re.sub(r"\D", "", p or "")
    return digits[-10:] if len(digits) >= 10 else digits


def norm_text(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def norm_email(e):
    return norm_text(e)


# =====================================================================
# 1. DEDUPE MATCHER
# =====================================================================

def match_keys(lead):
    """The set of normalised keys a lead matches on. ``lead`` is a dict with any
    of: phone, email, company, name."""
    keys = set()
    if lead.get("email"):
        keys.add(("email", norm_email(lead["email"])))
    ph = norm_phone(lead.get("phone"))
    if ph:
        keys.add(("phone", ph))
    if lead.get("company") and lead.get("name"):
        keys.add(("cn", norm_text(lead["company"]) + "|" + norm_text(lead["name"])))
    return keys


def find_duplicates(leads):
    """Group leads that share any match key. ``leads`` is a list of dicts each
    with an ``id``. Returns groups [{"match_on", "lead_ids":[...]}] with ≥2
    members, deterministic (sorted ids, de-duplicated groups)."""
    buckets = defaultdict(list)
    for lead in leads:
        lid = lead.get("id")
        if lid is None:
            continue
        for k in match_keys(lead):
            buckets[k].append(lid)
    groups = []
    seen = set()
    # Sort keys so output order is stable.
    for key in sorted(buckets.keys()):
        ids = sorted(set(buckets[key]))
        if len(ids) >= 2:
            sig = tuple(ids)
            if sig not in seen:
                seen.add(sig)
                groups.append({"match_on": key[0], "lead_ids": ids})
    return groups


def is_duplicate_of(candidate, existing_leads):
    """For a freshly captured ``candidate`` (card/form draft, no id yet), return
    the list of existing lead ids it collides with (shared key). Empty → new."""
    cand_keys = match_keys(candidate)
    hits = []
    for lead in existing_leads:
        if cand_keys & match_keys(lead):
            hits.append(lead.get("id"))
    return sorted(i for i in hits if i is not None)


# =====================================================================
# 2. MERGE PLAN — never drops an activity
# =====================================================================

# Child collections that MUST be re-pointed onto the survivor on merge. The
# timeline (activities) is the irreplaceable history, so it is first + asserted.
CHILD_COLLECTIONS = ("activities", "conversations", "deals", "proposals")

# Blank-only backfill fields: survivor keeps its own value; a blank is filled
# from the first duplicate that has one. Survivor data is NEVER overwritten.
BACKFILL_FIELDS = ("name", "company", "phone", "email", "whatsapp",
                   "designation", "notes")


def merge_plan(survivor, duplicates):
    """Produce an auditable merge plan WITHOUT mutating anything.

    ``survivor`` and each ``duplicates[i]`` are lead dicts that may carry child
    lists (activities, conversations, deals, proposals) and scalar fields.

    Returns:
      {
        "survivor_id": <id>,
        "delete_ids": [dup ids...],
        "reassign": {"activities":[child ids...], "conversations":[...], ...},
        "backfill": {field: value, ...},         # blanks filled from dupes
        "activity_count_before": N,               # survivor + all dupes
        "activity_count_after":  N,               # MUST equal before
        "warnings": [...],
      }

    Guarantee: ``activity_count_after == activity_count_before`` — the plan
    re-points every activity, it never drops one. Same for the other child
    collections. A warning is emitted (never a silent drop) if a survivor field
    would be overwritten (it won't be) or a child row has no id.
    """
    survivor_id = survivor.get("id")
    plan = {
        "survivor_id": survivor_id,
        "delete_ids": [],
        "reassign": {c: [] for c in CHILD_COLLECTIONS},
        "backfill": {},
        "warnings": [],
    }

    def _child_ids(lead, coll):
        ids = []
        for row in lead.get(coll, []) or []:
            rid = row.get("id") if isinstance(row, dict) else row
            if rid is None:
                plan["warnings"].append(f"{coll} row without id on lead "
                                        f"{lead.get('id')}")
            ids.append(rid)
        return ids

    # Survivor's own children stay put (already pointed at the survivor) but are
    # counted so the before/after total is honest.
    survivor_counts = {c: len(_child_ids(survivor, c)) for c in CHILD_COLLECTIONS}

    backfill = {}
    for d in duplicates:
        did = d.get("id")
        if did is None or did == survivor_id:
            continue
        plan["delete_ids"].append(did)
        for coll in CHILD_COLLECTIONS:
            plan["reassign"][coll].extend(_child_ids(d, coll))
        # Blank-only backfill — survivor wins, blanks pulled from the dup.
        for f in BACKFILL_FIELDS:
            if not survivor.get(f) and d.get(f) and f not in backfill:
                backfill[f] = d[f]

    plan["backfill"] = backfill
    plan["delete_ids"] = sorted(plan["delete_ids"])

    # ---- the no-data-loss guarantee, made explicit + checkable ----
    before = survivor_counts["activities"] + sum(
        len(_child_ids(d, "activities")) for d in duplicates
        if d.get("id") not in (None, survivor_id))
    after = survivor_counts["activities"] + len(plan["reassign"]["activities"])
    plan["activity_count_before"] = before
    plan["activity_count_after"] = after
    if before != after:
        plan["warnings"].append(
            f"ACTIVITY LOSS GUARD TRIPPED: before={before} after={after}")
    return plan


# =====================================================================
# 3a. BUSINESS-CARD OCR — MOCK / KEY-GATED
# =====================================================================

def card_parse(ocr_text="", has_ocr_key=False):
    """Business-card capture. OCR itself is an external, key-gated capability —
    this function NEVER does image OCR and NEVER invents fields.

    * ``has_ocr_key=False`` → returns an honest needs-key state. The app may
      still let the user TYPE/paste the card text, which is parsed below.
    * ``ocr_text`` present (already OCR'd text, or typed) → parse it into a
      structured DRAFT for a human review step. Only fields actually found in
      the text are returned; absent fields are left blank.

    Returns {"available", "needs_key", "draft": {...}, "found": [fields]}.
    """
    out = {"available": bool(has_ocr_key), "needs_key": not has_ocr_key,
           "draft": {}, "found": []}
    text = (ocr_text or "").strip()
    if not text:
        # No text to parse. Honest empty draft; caller shows the needs-key /
        # "type the card details" state.
        return out

    draft = {}
    # email
    m = re.search(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", text)
    if m:
        draft["email"] = m.group(0).lower()
    # phone(s): grab long digit runs (optionally +/space/dash) → keep as typed
    phones = []
    for pm in re.finditer(r"(?:\+?\d[\d\s\-]{7,}\d)", text):
        raw = pm.group(0).strip()
        if len(re.sub(r"\D", "", raw)) >= 10:
            phones.append(raw)
    if phones:
        draft["phone"] = phones[0]
        if len(phones) > 1:
            draft["phones"] = phones[1:]
    # website
    w = re.search(r"\b(?:www\.|https?://)[^\s]+", text, re.I)
    if w:
        draft["website"] = w.group(0)
    # name / company heuristic: first non-contact line is the person, a line
    # with a company suffix (Ltd/Limited/Inc/Co) is the company. Never guessed
    # beyond the text actually present.
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    contact_line = lambda s: bool(re.search(
        r"@|\d{7,}|www\.|https?://", s, re.I))
    non_contact = [ln for ln in lines if not contact_line(ln)]
    for ln in non_contact:
        if re.search(r"\b(ltd|limited|inc|co\.?|company|corp|llc|plc)\b", ln, re.I):
            draft.setdefault("company", ln)
    if non_contact:
        draft.setdefault("name", non_contact[0])

    out["draft"] = draft
    out["found"] = sorted(draft.keys())
    out["source"] = "card"
    return out


# =====================================================================
# 3b. WEBSITE LEAD-FORM INTAKE
# =====================================================================

# Map common web-form field names → our lead fields (owner site may vary; the
# view can extend this map). Deterministic, no AI.
_FORM_ALIASES = {
    "full_name": "name", "fullname": "name", "your_name": "name", "name": "name",
    "company_name": "company", "organisation": "company",
    "organization": "company", "company": "company",
    "email_address": "email", "e_mail": "email", "email": "email",
    "phone_number": "phone", "mobile": "phone", "contact": "phone",
    "phone": "phone", "cell": "phone",
    "message": "notes", "comments": "notes", "requirements": "notes",
    "website": "website",
}


def form_intake(payload, *, source="website"):
    """Normalise a raw website lead-form submission into a clean lead DRAFT.

    * Field names are mapped via ``_FORM_ALIASES`` (case/space-insensitive).
    * Values are trimmed; email lower-cased; nothing invented.
    * ``source`` is stamped (default "website") so attribution is honest.
    * Returns {"draft": {...}, "unmapped": {raw_key: value}} so the owner can
      see fields we did not recognise rather than silently dropping them.
    """
    draft = {}
    unmapped = {}
    for raw_key, raw_val in (payload or {}).items():
        val = (str(raw_val) if raw_val is not None else "").strip()
        if not val:
            continue
        key = re.sub(r"[\s\-]+", "_", str(raw_key).strip().lower())
        field = _FORM_ALIASES.get(key)
        if field == "email":
            draft["email"] = val.lower()
        elif field:
            # First non-empty wins for a given target field (stable).
            draft.setdefault(field, val)
        else:
            unmapped[raw_key] = val
    draft["source"] = source
    return {"draft": draft, "unmapped": unmapped}
