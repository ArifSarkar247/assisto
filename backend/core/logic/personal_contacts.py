"""
personal_contacts.py — Assisto PERSONAL CRM / phonebook logic (SPEC v2.1 §21).
Pure Python, deterministic, unit-testable.  NO Django, NO AI key, NO network.

This backs the PERSONAL contact manager (screens/crm_contacts_screen.dart) — the
"people in my life" relationship manager — which is DISTINCT from the business
Sales CRM (backend/crm/*).  It builds ON TOP of core.logic.circle for the
relationship vocabulary and ON TOP of core.logic.msg_contacts for the
PRIVACY-SAFE hashed phone-contact import (numbers of non-users never reach the
server).  It never duplicates those contracts.

WHAT LIVES HERE (logic/state only — DB models + HTTP endpoints are the
integrator's; see .phaseB/up_contacts_integration.md):

  - Rich-contact normalization: a contact may carry MANY phones/emails/addresses
    plus birthday, relationship, group labels, favourite flag, notes.  A
    deterministic `normalize_contact` makes a messy client dict safe + stable.
  - Groups / labels catalog (family / work / friends / …) — bilingual, reuses
    circle relations for the family side.
  - Search + filter + sort over a list of contacts (name/phone/email/org/label,
    favourites-first, group filter, "has-birthday", etc.) — all pure.
  - Duplicate detection + a non-destructive MERGE that unions phones/emails and
    keeps the richest field for each scalar (so merge never loses data).
  - vCard 3.0 EXPORT (single contact or a whole list) — a plain string, no I/O.
  - "Stay in touch" cadence: given a contact's cadence + last-interaction time,
    compute whether a gentle reminder is due and the human label for it.
  - Recent-interaction ranking: sort contacts by most-recent touch.
  - Quick-action descriptors (call / sms / whatsapp-share) — URI builders only,
    the client performs the action; this module NEVER sends anything.
  - Phone import = a thin, documented pass-through to msg_contacts' hashed
    matcher (raw numbers stay on the device), so import is messenger-safe.

INTEGER SAFETY: every count/id is coerced with int(); every cadence/day value is
clamped; birthday/day math tolerates missing or malformed parts and never
raises.  Bilingual strings go through circle.pick.  Returns are plain
dict/list/str so a DRF serializer can emit them directly.

Run self-tests (no DB):
    python3 -c "import core.logic.personal_contacts_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime, timezone

from core.logic.circle import (
    RELATIONS,
    normalize_relation,
    pick,
    relation_catalog,
    relation_label,
)
# PRIVACY-SAFE phone import rides entirely on the messenger contract — reused,
# never reimplemented, so "import from phone = hashed-safe like messenger" holds.
from core.logic.msg_contacts import (
    hash_contacts_clientside,
    hashing_contract,
    match_contacts,
)


# ---------------------------------------------------------------------------
# TUNABLE CONSTANTS  —  OWNER TO REVIEW (clearly marked)
# ---------------------------------------------------------------------------
# !!! POLICY — OWNER REVIEW REQUIRED !!!

NAME_MAX = 120          # OWNER REVIEW — display name cap
NOTE_MAX = 2000         # OWNER REVIEW — free notes cap
LABEL_MAX = 40          # OWNER REVIEW — a custom group/label cap
MAX_PHONES = 10         # OWNER REVIEW — multi-phone cap per contact
MAX_EMAILS = 10         # OWNER REVIEW — multi-email cap per contact
MAX_ADDRESSES = 5       # OWNER REVIEW — multi-address cap per contact
MAX_LABELS = 12         # OWNER REVIEW — group labels per contact

# "Stay in touch" cadence presets (days).  0 / absent ⇒ no reminder.
CADENCE_DAYS = {
    "weekly": 7,
    "fortnightly": 14,
    "monthly": 30,
    "quarterly": 90,
    "yearly": 365,
}
CADENCE_MAX_DAYS = 3650  # OWNER REVIEW — a custom cadence is clamped to ~10y


# ---------------------------------------------------------------------------
# GROUPS / LABELS  —  family / work / friends / …  (bilingual)
# ---------------------------------------------------------------------------
# A "group" is a built-in bucket; a contact may also carry free-text labels.
# The family group is wired to circle relations so the phonebook and the Circle
# stay consistent (link-to-Circle / family alerts).

GROUP_FAMILY = "family"
GROUP_WORK = "work"
GROUP_FRIENDS = "friends"
GROUP_ACQUAINTANCE = "acquaintance"
GROUP_OTHER = "other"

_GROUP_LABELS = {
    GROUP_FAMILY:       ("পরিবার",    "Family"),
    GROUP_WORK:         ("কর্মক্ষেত্র", "Work"),
    GROUP_FRIENDS:      ("বন্ধু",      "Friends"),
    GROUP_ACQUAINTANCE: ("পরিচিত",     "Acquaintance"),
    GROUP_OTHER:        ("অন্যান্য",    "Other"),
}
_GROUP_ORDER = [GROUP_FAMILY, GROUP_WORK, GROUP_FRIENDS,
                GROUP_ACQUAINTANCE, GROUP_OTHER]


def normalize_group(code):
    """Map a (messy) group code to a known bucket; unknown ⇒ 'other'."""
    c = (code or "").strip().lower()
    return c if c in _GROUP_LABELS else GROUP_OTHER


def group_label(code, lang="bn"):
    bn, en = _GROUP_LABELS[normalize_group(code)]
    return pick(lang, bn, en)


def group_catalog(lang="bn"):
    """Ordered list for the group picker/filter UI (code + localized label)."""
    return [{"code": c, "label": group_label(c, lang)} for c in _GROUP_ORDER]


# ---------------------------------------------------------------------------
# RICH-CONTACT NORMALIZATION
# ---------------------------------------------------------------------------

def _clean_str(v, cap=None):
    s = ("" if v is None else str(v)).strip()
    if cap is not None and len(s) > cap:
        s = s[:cap]
    return s


def _dedup_keep_order(items):
    seen = set()
    out = []
    for it in items:
        key = it.lower() if isinstance(it, str) else it
        if key in seen:
            continue
        seen.add(key)
        out.append(it)
    return out


def _as_list(v):
    """Accept a scalar, a list, or None → a flat list of non-empty strings."""
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        src = v
    else:
        src = [v]
    out = []
    for x in src:
        s = _clean_str(x)
        if s:
            out.append(s)
    return out


def _norm_birthday(v):
    """Normalize a birthday to 'YYYY-MM-DD' or 'MM-DD' (year unknown) or ''.
    Tolerant: accepts a date, a datetime, or an ISO-ish string; never raises."""
    if v is None or v == "":
        return ""
    if isinstance(v, datetime):
        v = v.date()
    if isinstance(v, date):
        return v.isoformat()
    s = str(v).strip()
    if not s:
        return ""
    # split on the first run of separators, keep up to 3 integer parts
    parts = []
    cur = ""
    for ch in s:
        if ch.isdigit():
            cur += ch
        else:
            if cur:
                parts.append(cur)
                cur = ""
    if cur:
        parts.append(cur)
    parts = [p for p in parts if p]
    try:
        if len(parts) >= 3:
            y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
            # if the first token looks like a day (YYYY last), swap heuristically
            if y <= 31 and int(parts[2]) > 31:
                y, d = int(parts[2]), y
            m = min(max(m, 1), 12)
            d = min(max(d, 1), 31)
            return f"{y:04d}-{m:02d}-{d:02d}"
        if len(parts) == 2:
            m, d = int(parts[0]), int(parts[1])
            m = min(max(m, 1), 12)
            d = min(max(d, 1), 31)
            return f"{m:02d}-{d:02d}"
    except (ValueError, TypeError):
        return ""
    return ""


def normalize_contact(raw, *, lang="bn"):
    """Turn a messy client contact dict into a STABLE, safe, serializable record.

    Accepts legacy single-field shapes ('phone', 'org', 'note') AND the new rich
    shapes ('phones'[], 'emails'[], 'addresses'[], 'birthday', 'relation',
    'groups'[], 'labels'[], 'favourite', 'cadence', 'last_interaction').  Unknown
    keys are dropped.  Everything is length-capped and de-duplicated.  Never
    raises; returns a dict the serializer can round-trip.
    """
    raw = raw or {}

    # phones: merge legacy 'phone' into 'phones', cap + dedup (keep raw strings;
    # they belong to the user's OWN contacts so storing them is fine — only
    # NON-users' numbers must never reach the server, and that path is the hashed
    # import, handled separately).
    phones = _as_list(raw.get("phones")) + _as_list(raw.get("phone"))
    phones = _dedup_keep_order(phones)[:MAX_PHONES]

    emails = _as_list(raw.get("emails")) + _as_list(raw.get("email"))
    emails = _dedup_keep_order([e.lower() for e in emails])[:MAX_EMAILS]

    addresses = _as_list(raw.get("addresses")) + _as_list(raw.get("address"))
    addresses = _dedup_keep_order(addresses)[:MAX_ADDRESSES]

    groups = [normalize_group(g) for g in _as_list(raw.get("groups"))]
    groups = _dedup_keep_order(groups)

    labels = [_clean_str(x, LABEL_MAX) for x in _as_list(raw.get("labels"))]
    labels = _dedup_keep_order([x for x in labels if x])[:MAX_LABELS]

    relation = normalize_relation(raw.get("relation")) if raw.get("relation") else ""
    # if a family relation is set but no group, surface the family group so the
    # phonebook filter and Circle stay consistent.
    if relation and relation in RELATIONS and not groups:
        if relation in ("father", "mother", "child", "parent", "husband",
                        "wife", "spouse", "brother", "sister", "sibling",
                        "relative"):
            groups = [GROUP_FAMILY]

    out = {
        "id": int(raw["id"]) if str(raw.get("id") or "").strip().isdigit() else None,
        "name": _clean_str(raw.get("name"), NAME_MAX),
        "phones": phones,
        "emails": emails,
        "addresses": addresses,
        "org": _clean_str(raw.get("org") or raw.get("organization"), NAME_MAX),
        "note": _clean_str(raw.get("note") or raw.get("notes"), NOTE_MAX),
        "birthday": _norm_birthday(raw.get("birthday")),
        "relation": relation,
        "relation_label": relation_label(relation, lang) if relation else "",
        "groups": groups,
        "labels": labels,
        "favourite": bool(raw.get("favourite") or raw.get("favorite")),
        "cadence": _norm_cadence(raw.get("cadence")),
        "last_interaction": _clean_str(raw.get("last_interaction")),
        "linked_user_id": int(raw["linked_user_id"])
        if str(raw.get("linked_user_id") or "").strip().isdigit() else None,
        "linked_circle_id": int(raw["linked_circle_id"])
        if str(raw.get("linked_circle_id") or "").strip().isdigit() else None,
    }
    # a never-blank display handle so the UI has no dead end for an unnamed row
    out["display_name"] = out["name"] or (out["phones"][0] if out["phones"] else "") \
        or (out["emails"][0] if out["emails"] else "") \
        or pick(lang, "নামহীন পরিচিতি", "Unnamed contact")
    out["initial"] = _initial(out["display_name"])
    return out


def _initial(name):
    """A safe single-character avatar initial (handles empty + non-ascii)."""
    s = (name or "").strip()
    if not s:
        return "?"
    return s[0].upper()


def _norm_cadence(v):
    """Normalize a stay-in-touch cadence to a preset key, an int #days, or ''.
    Returns a canonical string the UI stores: '' | preset-key | 'dN' (custom)."""
    if v is None or v == "":
        return ""
    s = str(v).strip().lower()
    if s in CADENCE_DAYS:
        return s
    # custom: a bare integer or 'dN' → clamp to [1, CADENCE_MAX_DAYS]
    digits = "".join(ch for ch in s if ch.isdigit())
    if not digits:
        return ""
    n = min(max(int(digits), 1), CADENCE_MAX_DAYS)
    return f"d{n}"


def cadence_days(cadence):
    """Resolve a cadence string to an integer #days (0 ⇒ no reminder)."""
    if not cadence:
        return 0
    if cadence in CADENCE_DAYS:
        return CADENCE_DAYS[cadence]
    if cadence.startswith("d"):
        digits = cadence[1:]
        if digits.isdigit():
            return min(max(int(digits), 1), CADENCE_MAX_DAYS)
    return 0


# ---------------------------------------------------------------------------
# SEARCH + FILTER + SORT
# ---------------------------------------------------------------------------

def _haystack(c):
    bits = [c.get("name", ""), c.get("org", ""), c.get("note", ""),
            c.get("relation_label", "")]
    bits += c.get("phones", []) or []
    bits += c.get("emails", []) or []
    bits += c.get("labels", []) or []
    return " ".join(str(b) for b in bits).lower()


def search_contacts(contacts, query):
    """Case-insensitive substring search across name/org/note/phone/email/label.
    Empty query ⇒ the list unchanged.  Pure; preserves input order."""
    q = (query or "").strip().lower()
    if not q:
        return list(contacts or [])
    # a phone query ignores spaces/dashes so '017 1234' matches '01712...'
    q_digits = "".join(ch for ch in q if ch.isdigit())
    out = []
    for c in (contacts or []):
        hay = _haystack(c)
        if q in hay:
            out.append(c)
            continue
        if q_digits:
            phone_blob = "".join(
                ch for ph in (c.get("phones") or []) for ch in str(ph)
                if ch.isdigit()
            )
            if q_digits in phone_blob:
                out.append(c)
    return out


def filter_contacts(contacts, *, group=None, favourites_only=False,
                    has_birthday=False, linked_only=False):
    """Filter by group bucket / favourites / has-birthday / linked-to-a-user.
    All filters are AND-combined; None/False means 'don't filter on this'."""
    out = []
    grp = normalize_group(group) if group else None
    for c in (contacts or []):
        if grp is not None and grp not in (c.get("groups") or []):
            continue
        if favourites_only and not c.get("favourite"):
            continue
        if has_birthday and not c.get("birthday"):
            continue
        if linked_only and not c.get("linked_user_id"):
            continue
        out.append(c)
    return out


def sort_contacts(contacts, *, by="name", lang="bn"):
    """Sort a contact list.  by ∈ {'name','recent','favourite'}.
      - 'name': favourites are NOT special; A→Z by display_name (case-fold).
      - 'favourite': favourites first, then A→Z.
      - 'recent': most-recent last_interaction first, undated last.
    Stable + deterministic; never raises on missing fields."""
    items = list(contacts or [])
    if by == "recent":
        def key(c):
            dt = _parse_dt(c.get("last_interaction"))
            # most-recent first ⇒ sort by negative timestamp; undated → very old
            ts = dt.timestamp() if dt else float("-inf")
            return (-ts, (c.get("display_name") or c.get("name") or "").lower())
        return sorted(items, key=key)
    if by == "favourite":
        return sorted(
            items,
            key=lambda c: (0 if c.get("favourite") else 1,
                           (c.get("display_name") or c.get("name") or "").lower()),
        )
    # default: name
    return sorted(items,
                  key=lambda c: (c.get("display_name") or c.get("name") or "").lower())


def group_counts(contacts):
    """{group_code: count} across the list (for filter-chip badges)."""
    counts = {g: 0 for g in _GROUP_ORDER}
    fav = 0
    for c in (contacts or []):
        if c.get("favourite"):
            fav += 1
        for g in (c.get("groups") or []):
            g = normalize_group(g)
            counts[g] = counts.get(g, 0) + 1
    counts["_favourites"] = fav
    counts["_all"] = len(contacts or [])
    return counts


# ---------------------------------------------------------------------------
# DUPLICATE DETECTION + NON-DESTRUCTIVE MERGE
# ---------------------------------------------------------------------------

def _digits(s):
    return "".join(ch for ch in str(s or "") if ch.isdigit())


def _match_keys(c):
    """The identity keys a contact can collide on: any shared phone (by its last
    9 digits, so +880 vs 0-prefixed still match) or any shared lowercased email,
    plus an exact case-folded name as a weak key."""
    keys = set()
    for ph in (c.get("phones") or []):
        d = _digits(ph)
        if len(d) >= 7:
            keys.add("p:" + d[-9:])
    for em in (c.get("emails") or []):
        e = str(em).strip().lower()
        if e:
            keys.add("e:" + e)
    nm = (c.get("name") or "").strip().lower()
    if nm:
        keys.add("n:" + nm)
    return keys


def find_duplicate_groups(contacts):
    """Group contacts that share a phone or email (strong) — a name-only overlap
    is NOT enough on its own (too many false positives) unless it also shares a
    phone/email.  Returns a list of lists (each inner list is a duplicate set of
    length ≥ 2), stable by first appearance.  Pure, no mutation."""
    items = list(contacts or [])
    # union-find over strong keys (phone/email); name used only to break ties.
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    strong_index = {}  # strong key -> first contact index
    for i, c in enumerate(items):
        for k in _match_keys(c):
            if k.startswith("n:"):
                continue  # name alone is not a strong key
            if k in strong_index:
                union(strong_index[k], i)
            else:
                strong_index[k] = i

    groups = {}
    for i in range(len(items)):
        r = find(i)
        groups.setdefault(r, []).append(items[i])
    # keep only true duplicate sets (≥2), ordered by first appearance
    out = [g for r, g in sorted(groups.items()) if len(g) >= 2]
    return out


def merge_contacts(primary, *others, lang="bn"):
    """NON-DESTRUCTIVE merge: union phones/emails/addresses/groups/labels, keep
    the richest value for each scalar (prefer the primary's non-empty value,
    else the first other that has one), OR favourite if any is a favourite, and
    keep the EARLIEST last_interaction loss-free by taking the MOST RECENT.
    Returns a fresh normalized contact; inputs are not mutated.  Never loses a
    phone/email/address.  `primary`'s id is preserved."""
    all_c = [primary] + list(others)
    merged = {
        "id": primary.get("id"),
        "linked_user_id": None,
        "linked_circle_id": None,
    }

    def first_nonempty(field):
        for c in all_c:
            v = c.get(field)
            if v not in (None, "", []):
                return v
        return ""

    phones, emails, addresses, groups, labels = [], [], [], [], []
    for c in all_c:
        phones += c.get("phones") or []
        emails += c.get("emails") or []
        addresses += c.get("addresses") or []
        groups += c.get("groups") or []
        labels += c.get("labels") or []

    merged["name"] = first_nonempty("name")
    merged["org"] = first_nonempty("org")
    merged["relation"] = first_nonempty("relation")
    merged["birthday"] = first_nonempty("birthday")
    merged["cadence"] = first_nonempty("cadence")
    merged["phones"] = _dedup_keep_order(phones)
    merged["emails"] = _dedup_keep_order([e.lower() for e in emails])
    merged["addresses"] = _dedup_keep_order(addresses)
    merged["groups"] = _dedup_keep_order([normalize_group(g) for g in groups])
    merged["labels"] = _dedup_keep_order(labels)
    merged["favourite"] = any(c.get("favourite") for c in all_c)
    merged["linked_user_id"] = first_nonempty("linked_user_id") or None
    merged["linked_circle_id"] = first_nonempty("linked_circle_id") or None
    # notes: concatenate distinct notes so none is lost
    notes = _dedup_keep_order(
        [n for n in (c.get("note") or "" for c in all_c) if n]
    )
    merged["note"] = ("\n".join(notes))[:NOTE_MAX]
    # last_interaction: keep the most recent
    dts = [(_parse_dt(c.get("last_interaction")), c.get("last_interaction"))
           for c in all_c]
    dts = [(d, raw) for d, raw in dts if d]
    merged["last_interaction"] = max(dts)[1] if dts else ""
    return normalize_contact(merged, lang=lang)


# ---------------------------------------------------------------------------
# vCard 3.0 EXPORT
# ---------------------------------------------------------------------------

def _vcard_escape(s):
    return (str(s or "")
            .replace("\\", "\\\\")
            .replace(";", "\\;")
            .replace(",", "\\,")
            .replace("\n", "\\n"))


def to_vcard(contact, *, lang="bn"):
    """Serialize ONE contact to a vCard 3.0 string (CRLF line endings per RFC).
    Emits N/FN, every phone, every email, every address, ORG, BDAY, NOTE, and a
    CATEGORIES line from groups+labels.  Deterministic; no I/O."""
    c = normalize_contact(contact, lang=lang)
    lines = ["BEGIN:VCARD", "VERSION:3.0"]
    name = c["name"] or c["display_name"]
    lines.append("N:" + _vcard_escape(name) + ";;;;")
    lines.append("FN:" + _vcard_escape(name))
    if c["org"]:
        lines.append("ORG:" + _vcard_escape(c["org"]))
    for ph in c["phones"]:
        lines.append("TEL;TYPE=CELL:" + _vcard_escape(ph))
    for em in c["emails"]:
        lines.append("EMAIL;TYPE=INTERNET:" + _vcard_escape(em))
    for ad in c["addresses"]:
        lines.append("ADR;TYPE=HOME:;;" + _vcard_escape(ad) + ";;;;")
    if c["birthday"]:
        bday = c["birthday"]
        # vCard BDAY wants YYYY-MM-DD; a year-less 'MM-DD' is emitted as --MM-DD
        lines.append("BDAY:" + (bday if len(bday) == 10 else "--" + bday))
    cats = [group_label(g, lang) for g in c["groups"]] + c["labels"]
    if cats:
        lines.append("CATEGORIES:" + ",".join(_vcard_escape(x) for x in cats))
    if c["relation"]:
        lines.append("X-RELATION:" + _vcard_escape(c["relation_label"]))
    if c["note"]:
        lines.append("NOTE:" + _vcard_escape(c["note"]))
    lines.append("END:VCARD")
    return "\r\n".join(lines) + "\r\n"


def to_vcard_bundle(contacts, *, lang="bn"):
    """Serialize a WHOLE list to one multi-vCard string (for 'export all')."""
    return "".join(to_vcard(c, lang=lang) for c in (contacts or []))


# ---------------------------------------------------------------------------
# STAY-IN-TOUCH CADENCE + RECENT-INTERACTION
# ---------------------------------------------------------------------------

def _parse_dt(v):
    """Lenient ISO/epoch → aware datetime (UTC) or None.  Never raises."""
    if v in (None, ""):
        return None
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    if isinstance(v, date):
        return datetime(v.year, v.month, v.day, tzinfo=timezone.utc)
    if isinstance(v, (int, float)):
        try:
            return datetime.fromtimestamp(v, tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    s = str(v).strip()
    if not s:
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        # try a bare date
        try:
            d = datetime.fromisoformat(s[:10])
            return d.replace(tzinfo=timezone.utc)
        except ValueError:
            return None


def days_since_interaction(contact, now=None):
    """Whole days since the contact's last_interaction (None if never)."""
    now = now or datetime.now(timezone.utc)
    dt = _parse_dt(contact.get("last_interaction"))
    if dt is None:
        return None
    delta = now - dt
    return max(0, delta.days)


def is_touch_due(contact, now=None):
    """True iff the stay-in-touch cadence is set AND it has been at least that
    many days since the last interaction (or there is no recorded interaction).
    A contact with no cadence is NEVER due (opt-in)."""
    days = cadence_days(contact.get("cadence"))
    if days <= 0:
        return False
    since = days_since_interaction(contact, now=now)
    if since is None:
        return True  # cadence set but never touched ⇒ reach out
    return since >= days


def touch_due_contacts(contacts, now=None):
    """Subset of contacts whose stay-in-touch reminder is due, most-overdue
    first.  Pure; for the 'reach out' surface + a daily digest."""
    now = now or datetime.now(timezone.utc)
    due = [c for c in (contacts or []) if is_touch_due(c, now=now)]

    def overdue(c):
        since = days_since_interaction(c, now=now)
        target = cadence_days(c.get("cadence"))
        if since is None:
            return float("inf")  # never touched ⇒ most urgent
        return since - target
    return sorted(due, key=lambda c: -_safe_float(overdue(c)))


def _safe_float(x):
    try:
        if x == float("inf"):
            return 1e18
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def touch_due_label(contact, now=None, lang="bn"):
    """Human, bilingual 'stay in touch' line (never Bangla glyphs in the client —
    the client renders its own; this is for a server digest / push body)."""
    since = days_since_interaction(contact, now=now)
    name = contact.get("display_name") or contact.get("name") or ""
    if since is None:
        return pick(lang,
                    f"{name}-এর সাথে যোগাযোগ করুন।",
                    f"Reach out to {name}.")
    return pick(lang,
                f"{name}-এর সাথে {since} দিন কথা হয়নি।",
                f"It's been {since} days since you talked to {name}.")


# ---------------------------------------------------------------------------
# QUICK-ACTION URI BUILDERS (call / sms / whatsapp-share)
# ---------------------------------------------------------------------------
# These return URI strings/descriptors ONLY.  The client launches them.  This
# module never dials, texts, or opens anything (Play-compliant, like
# msg_contacts' invite descriptors).

def _best_phone(contact):
    ph = (contact.get("phones") or [])
    return ph[0] if ph else ""


def quick_actions(contact, *, lang="bn", wa_text=""):
    """Descriptors for the quick-action row.  Only includes actions the contact
    supports (no phone ⇒ no call/sms/whatsapp; no email ⇒ no email), so the UI
    never shows a dead button."""
    actions = []
    phone = _best_phone(contact)
    email = (contact.get("emails") or [""])[0]
    if phone:
        digits = "+" + _digits(phone) if not phone.strip().startswith("+") \
            else phone.strip()
        actions.append({"kind": "call", "uri": "tel:" + phone.strip(),
                        "label": pick(lang, "কল", "Call")})
        actions.append({"kind": "sms", "uri": "sms:" + phone.strip(),
                        "label": pick(lang, "এসএমএস", "SMS")})
        # whatsapp "share" opens a chat/share sheet with a prefilled text; the
        # user presses send — no gateway, never auto-sent.
        wa = "https://wa.me/" + _digits(digits)
        if wa_text:
            wa += "?text=" + _uri_encode(wa_text)
        actions.append({"kind": "whatsapp", "uri": wa,
                        "label": pick(lang, "হোয়াটসঅ্যাপ", "WhatsApp"),
                        "auto_sent": False})
    if email:
        actions.append({"kind": "email", "uri": "mailto:" + email,
                        "label": pick(lang, "ইমেইল", "Email")})
    return actions


def _uri_encode(s):
    out = []
    safe = "-_.~"
    for ch in (s or ""):
        if ch.isalnum() or ch in safe:
            out.append(ch)
        else:
            for b in ch.encode("utf-8"):
                out.append(f"%{b:02X}")
    return "".join(out)


# ---------------------------------------------------------------------------
# LINK A CONTACT TO A CIRCLE / FAMILY MEMBER
# ---------------------------------------------------------------------------

def link_contact_to_circle(contact, *, user_id, circle_id=None, relation=None,
                           lang="bn"):
    """Produce the patch that links a phonebook contact to a registered Circle
    user (e.g. after the hashed import matched them).  Sets linked_user_id, an
    optional circle_id, promotes the relation (so family alerts/SOS reach),
    and ensures the family group.  Returns a dict to merge onto the contact."""
    patch = {"linked_user_id": int(user_id)}
    if circle_id is not None and str(circle_id).strip().isdigit():
        patch["linked_circle_id"] = int(circle_id)
    rel = normalize_relation(relation) if relation else (contact.get("relation") or "")
    if rel:
        patch["relation"] = rel
    groups = list(contact.get("groups") or [])
    if rel and rel != "custom" and GROUP_FAMILY not in groups:
        groups.append(GROUP_FAMILY)
        patch["groups"] = groups
    patch["linked_label"] = pick(lang, "সার্কেলে যুক্ত", "Linked in Circle")
    return patch


# ---------------------------------------------------------------------------
# PHONE IMPORT — thin, documented pass-through to the messenger hashed matcher
# ---------------------------------------------------------------------------
# "Import from phone (hashed-safe like messenger)" is satisfied by REUSING
# msg_contacts: raw numbers are hashed ON THE DEVICE, only hashes + the explicit
# permission flag reach the server, non-users' hashes are matched and dropped
# (stored: False).  We re-export those names and add a convenience that turns a
# match result into draft phonebook contacts the user can confirm-and-save.

def import_matches_to_drafts(match_result, *, lang="bn"):
    """Turn msg_contacts.match_contacts' output into draft phonebook contacts
    (one per matched registered user) ready to confirm + save, each pre-linked
    to that user.  Un-matched contacts are intentionally absent (privacy)."""
    if not (match_result or {}).get("ok"):
        return []
    drafts = []
    for m in match_result.get("matches", []):
        user = m.get("user") or {}
        drafts.append(normalize_contact({
            "name": user.get("name") or user.get("display_name") or "",
            "phones": [user.get("phone")] if user.get("phone") else [],
            "linked_user_id": user.get("id") or user.get("user_id"),
            "groups": [GROUP_FRIENDS],
            "note": pick(lang, "ফোন কন্টাক্ট থেকে যুক্ত", "Added from phone contacts"),
        }, lang=lang))
    return drafts


__all__ = [
    # groups
    "GROUP_FAMILY", "GROUP_WORK", "GROUP_FRIENDS", "GROUP_ACQUAINTANCE",
    "GROUP_OTHER", "normalize_group", "group_label", "group_catalog",
    # contact
    "normalize_contact", "cadence_days", "CADENCE_DAYS",
    # search / filter / sort
    "search_contacts", "filter_contacts", "sort_contacts", "group_counts",
    # dedupe / merge
    "find_duplicate_groups", "merge_contacts",
    # vcard
    "to_vcard", "to_vcard_bundle",
    # stay in touch
    "days_since_interaction", "is_touch_due", "touch_due_contacts",
    "touch_due_label",
    # quick actions
    "quick_actions",
    # link + import (reuse circle + msg_contacts)
    "link_contact_to_circle", "import_matches_to_drafts",
    "relation_catalog", "hash_contacts_clientside", "match_contacts",
    "hashing_contract",
]
