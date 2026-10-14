"""
birthdays.py — Assisto Birthdays & memorable days (no AI key; pure Python,
deterministic, unit-testable). Benchmarked against phone built-in reminders:
we add configurable LEAD days (remind N days before), annual recurrence with
leap-day handling, age/years-since computation, and ready-to-send wish /
greeting-card DRAFTS in bn + en.

SAFETY: we NEVER auto-send. Drafts are produced for the user to copy/send.

A "memorable day" is any yearly occasion: birthday, anniversary, death
anniversary (sraddho/punnotithi), first-day, etc. `kind` drives the draft tone.

Run self-tests:
    python3 -c "import core.logic.birthdays_tests_snippets as t; t.run_all()"
"""
from datetime import date, timedelta


def pick(lang, bn, en):
    return en if lang == "en" else bn


# occasion kinds -> localized label + whether age/years is meaningful
KINDS = [
    {"id": "birthday", "bn": "জন্মদিন", "en": "Birthday", "shows_age": True},
    {"id": "anniversary", "bn": "বিবাহবার্ষিকী", "en": "Anniversary", "shows_age": True},
    {"id": "death_anniversary", "bn": "মৃত্যুবার্ষিকী", "en": "Remembrance day", "shows_age": False},
    {"id": "memorable", "bn": "স্মরণীয় দিন", "en": "Memorable day", "shows_age": False},
]

LEAD_DAYS_DEFAULT = 1          # remind 1 day before by default
LEAD_DAYS_MAX = 60


def kinds(lang="bn"):
    return [{"id": k["id"], "label": pick(lang, k["bn"], k["en"]),
             "shows_age": k["shows_age"]} for k in KINDS]


def _kind(kind_id):
    for k in KINDS:
        if k["id"] == kind_id:
            return k
    return KINDS[0]


# ---------------------------------------------------------------------------
# dates & recurrence
# ---------------------------------------------------------------------------

def parse_date(v):
    """Accept an ISO 'YYYY-MM-DD' string or a date; return date or None.
    Year is optional for occasions where the year is unknown — callers may pass
    a sentinel year; we keep whatever is given."""
    if v is None:
        return None
    if isinstance(v, date):
        return v
    try:
        parts = str(v).split("-")
        return date(int(parts[0]), int(parts[1]), int(parts[2]))
    except (ValueError, IndexError, TypeError):
        return None


def _this_years_occurrence(month, day, year):
    """The occasion's date in `year`, handling Feb-29 on non-leap years by
    moving it to Feb-28 (common calendar-app convention)."""
    try:
        return date(year, month, day)
    except ValueError:
        # Feb 29 on a non-leap year -> Feb 28
        if month == 2 and day == 29:
            return date(year, 2, 28)
        raise


def next_occurrence(occasion_date, today=None):
    """Next annual occurrence (today counts as the occurrence if it's today).
    `occasion_date` supplies month/day; the year is ignored for recurrence."""
    d = parse_date(occasion_date)
    if d is None:
        return None
    today = today or date.today()
    cand = _this_years_occurrence(d.month, d.day, today.year)
    if cand < today:
        cand = _this_years_occurrence(d.month, d.day, today.year + 1)
    return cand


def days_until(occasion_date, today=None):
    """Whole days from today until the next occurrence (0 == today). None if
    the date is invalid."""
    nxt = next_occurrence(occasion_date, today=today)
    if nxt is None:
        return None
    today = today or date.today()
    return (nxt - today).days


def turning_age(occasion_date, today=None):
    """Age/years the person/occasion reaches at the NEXT occurrence.
    None if the original year is unknown/sentinel (<= 1900) or date invalid."""
    d = parse_date(occasion_date)
    if d is None:
        return None
    if d.year <= 1900:
        return None
    nxt = next_occurrence(occasion_date, today=today)
    if nxt is None:
        return None
    # Clamp: a birth/start year AFTER the next occurrence (e.g. a future-dated
    # entry) would yield a negative age — never report negative, floor at 0.
    return max(0, nxt.year - d.year)


# ---------------------------------------------------------------------------
# lead-day reminders
# ---------------------------------------------------------------------------

def clamp_lead_days(n):
    try:
        v = int(n)
    except (TypeError, ValueError):
        return LEAD_DAYS_DEFAULT
    return max(0, min(LEAD_DAYS_MAX, v))


def reminder_dates(occasion_date, lead_days=LEAD_DAYS_DEFAULT, today=None):
    """Dates on which to remind for the NEXT occurrence: the lead-day(s) before
    PLUS the day itself. `lead_days` may be an int (single lead) or a list of
    ints (multiple pre-reminders, e.g. [7, 1]). Deduped, chronological, and
    never before today."""
    nxt = next_occurrence(occasion_date, today=today)
    if nxt is None:
        return []
    today = today or date.today()
    if isinstance(lead_days, (list, tuple)):
        leads = [clamp_lead_days(x) for x in lead_days]
    else:
        leads = [clamp_lead_days(lead_days)]
    out = set()
    for lead in leads:
        out.add(nxt - timedelta(days=lead))
    out.add(nxt)  # always remind on the day
    return sorted(d for d in out if d >= today)


def should_remind_today(occasion_date, lead_days=LEAD_DAYS_DEFAULT, today=None):
    """True if today is one of the reminder dates for the next occurrence."""
    today = today or date.today()
    return today in reminder_dates(occasion_date, lead_days=lead_days, today=today)


THIS_WEEK_DAYS = 7           # "this week" highlight window (inclusive)


def kind_label(kind_id, lang="bn"):
    k = _kind(kind_id)
    return pick(lang, k["bn"], k["en"])


def upcoming(occasions, within_days=30, today=None, lang="bn"):
    """Sort+filter a list of occasion dicts to those occurring within
    `within_days`. Each occasion: {name, date, kind, lead_days?, relation?,
    notes?, yearly?}.

    Returns augmented dicts with days_until / next_date / turning_age /
    kind_label / this_week (True when the occurrence is within THIS_WEEK_DAYS),
    sorted by soonest first. `yearly` defaults True; a non-yearly occasion that
    has already passed this calendar year is dropped (one-off events only fire
    once)."""
    today = today or date.today()
    out = []
    for occ in occasions or []:
        yearly = occ.get("yearly", True)
        du = days_until(occ.get("date"), today=today)
        if du is None or du > within_days:
            continue
        nxt = next_occurrence(occ.get("date"), today=today)
        if not yearly:
            # A one-off: only valid if its ORIGINAL date is today-or-future.
            d0 = parse_date(occ.get("date"))
            if d0 is None or d0 < today:
                continue
            du = (d0 - today).days
            if du > within_days:
                continue
            nxt = d0
        out.append({
            **occ,
            "days_until": du,
            "next_date": nxt.isoformat(),
            "turning_age": turning_age(occ.get("date"), today=today) if yearly else None,
            "kind_label": kind_label(occ.get("kind", "birthday"), lang),
            "this_week": du <= THIS_WEEK_DAYS,
        })
    out.sort(key=lambda o: o["days_until"])
    return out


def this_week(occasions, today=None, lang="bn"):
    """Just the occasions whose next occurrence is within THIS_WEEK_DAYS —
    the 'this week' highlight strip."""
    return [o for o in upcoming(occasions, within_days=THIS_WEEK_DAYS,
                                today=today, lang=lang)]


# ---------------------------------------------------------------------------
# wish / greeting-card DRAFTS  (never auto-sent)
# ---------------------------------------------------------------------------

def _age_clause(kind_id, age, lang):
    if age is None or not _kind(kind_id)["shows_age"]:
        return ""
    if kind_id == "anniversary":
        return pick(lang, f" {age}তম বিবাহবার্ষিকীর", f" on your {age}th anniversary")
    return pick(lang, f" {age}তম জন্মদিনের", f" on your {age}th birthday")


def _relation_prefix(relation, lang):
    """A short, warm relation-aware salutation prefix, e.g. 'প্রিয় মা' / 'Dear Mom'.
    `relation` is free text (already localised by the caller/picker); empty when
    none is set. Returns '' when no relation so drafts stay clean."""
    rel = (relation or "").strip()
    if not rel:
        return ""
    return pick(lang, f"প্রিয় {rel}, ", f"Dear {rel}, ")


def wish_drafts(name, kind_id="birthday", age=None, lang="bn", relation=None):
    """Return a list of ready-to-copy wish DRAFTS (short → warm → formal) for an
    occasion. The user picks one and sends it themselves — never auto-sent.

    `age` (optional) personalises birthday/anniversary wishes. `relation`
    (optional, free text) is woven into the FORMAL draft when provided so the
    other two stay short/shareable.
    """
    nm = (name or "").strip() or pick(lang, "প্রিয়জন", "friend")
    age_clause = _age_clause(kind_id, age, lang)
    rel_prefix = _relation_prefix(relation, lang)

    if kind_id == "anniversary":
        bn = [
            f"শুভ বিবাহবার্ষিকী, {nm}! দুজনে সুখে থাকুন।",
            f"{nm},{age_clause} অনেক অনেক শুভেচ্ছা। ভালোবাসা ও সুখে ভরে থাকুক আপনাদের জীবন।",
            f"প্রিয় {nm}, আপনাদের{age_clause} বিশেষ দিনে আন্তরিক শুভেচ্ছা ও শুভকামনা রইল।",
        ]
        en = [
            f"Happy anniversary, {nm}! Wishing you both lots of love.",
            f"{nm}, warm wishes{age_clause}. May your life stay full of love and joy.",
            f"Dear {nm}, heartfelt congratulations{age_clause}. Wishing you continued happiness.",
        ]
    elif kind_id == "death_anniversary":
        bn = [
            f"{nm}-কে আজ গভীর শ্রদ্ধায় স্মরণ করছি।",
            f"প্রিয় {nm}-এর স্মৃতির প্রতি শ্রদ্ধা। তাঁর কথা মনে পড়ছে আজ।",
            f"আজকের এই দিনে {nm}-কে শ্রদ্ধাভরে স্মরণ করছি; পরিবারের জন্য রইল সমবেদনা।",
        ]
        en = [
            f"Remembering {nm} with deep respect today.",
            f"In loving memory of {nm}. Thinking of them today.",
            f"On this day we remember {nm} with respect, and send strength to the family.",
        ]
    elif kind_id == "memorable":
        bn = [
            f"আজকের বিশেষ দিনে শুভেচ্ছা, {nm}!",
            f"{nm}, এই স্মরণীয় দিনে আন্তরিক শুভকামনা রইল।",
            f"প্রিয় {nm}, আজকের বিশেষ দিনটি আনন্দে কাটুক—শুভেচ্ছা রইল।",
        ]
        en = [
            f"Happy special day, {nm}!",
            f"{nm}, warm wishes on this memorable day.",
            f"Dear {nm}, may your special day be joyful — best wishes.",
        ]
    else:  # birthday
        bn = [
            f"শুভ জন্মদিন, {nm}! 🎂",
            f"{nm},{age_clause} অনেক অনেক শুভেচ্ছা। সুস্থ ও আনন্দে থাকুন।",
            f"প্রিয় {nm}, আপনার{age_clause} এই দিনে আন্তরিক শুভেচ্ছা ও শুভকামনা রইল।",
        ]
        en = [
            f"Happy birthday, {nm}! 🎂",
            f"{nm}, many happy returns{age_clause}. Stay healthy and happy.",
            f"Dear {nm}, warm wishes{age_clause}. Wishing you a wonderful year ahead.",
        ]

    drafts = list(bn if lang != "en" else en)
    # Weave the relation into the FORMAL (3rd) draft only, and only when it is
    # not already personalised with "প্রিয়/Dear" (avoid double "Dear Dear").
    if rel_prefix and len(drafts) >= 3:
        formal = drafts[2]
        starts_dear = formal.startswith(pick(lang, "প্রিয়", "Dear"))
        if not starts_dear:
            drafts[2] = rel_prefix + formal[:1].lower() + formal[1:] if lang == "en" \
                else rel_prefix + formal
    styles = ["short", "warm", "formal"]
    return [{"style": styles[i], "text": drafts[i]} for i in range(len(drafts))]


def greeting_card(name, kind_id="birthday", age=None, lang="bn"):
    """A single longer greeting-card DRAFT (title + body) for the card view.
    Not auto-sent — the user copies/shares it."""
    nm = (name or "").strip() or pick(lang, "প্রিয়জন", "friend")
    k = _kind(kind_id)
    title = pick(lang, k["bn"], k["en"])
    age_clause = _age_clause(kind_id, age, lang)
    if kind_id == "death_anniversary":
        body = pick(lang,
                    f"আজ {nm}-কে গভীর শ্রদ্ধা ও ভালোবাসায় স্মরণ করছি। তাঁর স্মৃতি চিরকাল আমাদের সাথে থাকবে।",
                    f"Today we remember {nm} with deep respect and love. Their memory stays with us always.")
    else:
        body = pick(lang,
                    f"প্রিয় {nm}, আপনার{age_clause} এই বিশেষ দিনে আমার আন্তরিক শুভেচ্ছা ও ভালোবাসা। "
                    f"আগামী দিনগুলো সুখ, সুস্থতা ও সাফল্যে ভরে উঠুক।",
                    f"Dear {nm}, my heartfelt wishes and love{age_clause} on your special day. "
                    f"May the days ahead be full of happiness, health and success.")
    return {"title": title, "body": body}


def reminder_payload(name, kind_id, days_until_val, lang="bn"):
    """Notification payload for a lead-day/day-of reminder (integrator pushes;
    foreground-poll today). days_until_val: 0 == today."""
    nm = (name or "").strip() or pick(lang, "প্রিয়জন", "someone")
    k = _kind(kind_id)
    label = pick(lang, k["bn"], k["en"])
    if days_until_val <= 0:
        body = pick(lang, f"আজ {nm}-এর {label}। শুভেচ্ছা পাঠাতে ভুলবেন না!",
                    f"Today is {nm}'s {label.lower()}. Don't forget to send your wishes!")
    elif days_until_val == 1:
        body = pick(lang, f"আগামীকাল {nm}-এর {label}।",
                    f"Tomorrow is {nm}'s {label.lower()}.")
    else:
        body = pick(lang, f"{days_until_val} দিন পর {nm}-এর {label}।",
                    f"{nm}'s {label.lower()} is in {days_until_val} days.")
    return {
        "kind": "birthday_reminder",
        "title": pick(lang, "স্মরণীয় দিনের মনে করিয়ে দেওয়া", "Memorable-day reminder"),
        "body": body,
    }


# ---------------------------------------------------------------------------
# AI wish — MOCK by default, KEY-GATED for a real model (never auto-sent)
# ---------------------------------------------------------------------------
# Mirrors the house pattern (business_ai.default_mock_provider / ai_inbox): the
# default provider is a deterministic MOCK that works fully offline and with no
# key. A real LLM provider is a drop-in that only runs when ai_key_available is
# True. Either way the output is a DRAFT the user copies/sends — never auto-sent.

def default_ai_wish_provider(prompt):
    """Deterministic MOCK 'AI' wish provider (the default).

    Contract for ANY provider (mock or real): receives a `prompt` dict with
      {"lang","name","kind","age","relation","style"} and returns
      {"text": str, "source": "ai_mock"|"ai"}. This mock simply picks the
      matching handcrafted draft so the pipeline proves out with no key. A real,
      key-gated provider returns source "ai" and may vary the wording."""
    lang = prompt.get("lang", "bn")
    drafts = wish_drafts(prompt.get("name"), prompt.get("kind", "birthday"),
                         age=prompt.get("age"), lang=lang,
                         relation=prompt.get("relation"))
    want = prompt.get("style", "warm")
    text = next((d["text"] for d in drafts if d["style"] == want), drafts[1]["text"])
    return {"text": text, "source": "ai_mock"}


def ai_wish(name, kind_id="birthday", age=None, lang="bn", relation=None,
            style="warm", ai_key_available=False, provider=None):
    """Produce ONE 'AI-assisted' wish DRAFT. With no key (default) this returns
    the deterministic mock, flagged source='ai_mock' and ai_required=True so the
    UI can show an honest 'AI preview (no key)' marker. When ai_key_available is
    True a real `provider` (if supplied) is used; otherwise the mock still runs.
    NEVER auto-sent."""
    prompt = {"lang": lang, "name": name, "kind": kind_id, "age": age,
              "relation": relation, "style": style}
    prov = provider if (ai_key_available and callable(provider)) else default_ai_wish_provider
    out = prov(prompt)
    text = (out or {}).get("text", "")
    real = ai_key_available and callable(provider)
    return {
        "text": text,
        "source": "ai" if real else "ai_mock",
        "ai_required": True,       # this surface is an AI feature
        "is_mock": not real,       # honest marker: true until a key+provider wired
        "auto_sent": False,
    }


# ---------------------------------------------------------------------------
# ONE-TAP SEND — URI builders (WhatsApp-share / SMS / call). Never a gateway:
# each opens the native app with text prefilled; the USER presses send.
# ---------------------------------------------------------------------------

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


def _digits(s):
    return "".join(ch for ch in (s or "") if ch.isdigit())


def send_actions(draft_text, phone=None, lang="bn"):
    """Descriptors for the one-tap send row for a chosen wish DRAFT.

    Returns only the actions that are possible: WhatsApp-share is always offered
    (share sheet works without a number); SMS/call need a phone. Each is a URI
    the UI launches — nothing is sent automatically (auto_sent=False)."""
    actions = []
    text = draft_text or ""
    if phone and _digits(phone):
        intl = phone.strip() if phone.strip().startswith("+") else "+" + _digits(phone)
        wa = "https://wa.me/" + _digits(intl) + "?text=" + _uri_encode(text)
        actions.append({"kind": "whatsapp", "uri": wa,
                        "label": pick(lang, "হোয়াটসঅ্যাপ", "WhatsApp"), "auto_sent": False})
        actions.append({"kind": "sms", "uri": "sms:" + phone.strip() + "?body=" + _uri_encode(text),
                        "label": pick(lang, "এসএমএস", "SMS"), "auto_sent": False})
        actions.append({"kind": "call", "uri": "tel:" + phone.strip(),
                        "label": pick(lang, "কল", "Call"), "auto_sent": False})
    else:
        # No linked phone: WhatsApp SHARE sheet (no recipient) + generic share.
        actions.append({"kind": "whatsapp", "uri": "https://wa.me/?text=" + _uri_encode(text),
                        "label": pick(lang, "হোয়াটসঅ্যাপ", "WhatsApp"), "auto_sent": False})
    actions.append({"kind": "share", "uri": "", "label": pick(lang, "শেয়ার", "Share"),
                    "auto_sent": False})
    return actions


# ---------------------------------------------------------------------------
# LINK to Circle / IMPORT from contacts (thin, privacy-safe pass-throughs)
# ---------------------------------------------------------------------------
# Linking a memorable day to a Circle contact lets reminders/one-tap-send reach
# the right person. Import reuses the SAME on-device hashed matcher the rest of
# the app uses — raw numbers never leave the device; only matched contacts that
# the user confirms become occasions.

def link_occasion_to_contact(occasion, *, contact_id, phone=None, relation=None):
    """Patch that links a memorable-day occasion to a phonebook/Circle contact so
    one-tap-send knows the number. Returns a dict to merge onto the occasion."""
    patch = {"linked_contact_id": int(contact_id)}
    if phone:
        patch["phone"] = str(phone).strip()
    if relation:
        patch["relation"] = str(relation).strip()
    return patch


def import_occasions_from_contacts(contacts, lang="bn"):
    """Turn a list of (already-on-device, user-confirmed) contact dicts that
    carry a `birthday` into draft occasions ready to confirm + save. Contacts
    without a birthday are skipped. PRIVACY: this operates only on contacts the
    caller already holds locally — no numbers are sent to any server here."""
    drafts = []
    for c in contacts or []:
        bday = c.get("birthday") or c.get("date")
        d = parse_date(bday)
        if d is None:
            continue
        drafts.append({
            "name": (c.get("name") or "").strip(),
            "date": d.isoformat(),
            "kind": "birthday",
            "lead_days": [7, 1, 0],
            "yearly": True,
            "relation": c.get("relation") or "",
            "phone": _best_phone(c),
            "linked_contact_id": c.get("id"),
            "source": "contacts_import",
        })
    return drafts


def _best_phone(c):
    phones = c.get("phones")
    if isinstance(phones, (list, tuple)) and phones:
        return str(phones[0]).strip()
    p = c.get("phone")
    return str(p).strip() if p else ""
