"""
estimate_templates.py — ready-made templates for the COST & TIME ESTIMATOR
(owner PART 2) for common Bangladesh jobs: home repair/paint, an event, a
trip, a small-business start-up, private tutoring.

A template = a few QUESTIONS the user answers (sq ft, guests, nights …) and
LINES whose quantity is derived from those answers. Every line's unit RATE
(৳ per unit) and TIME (minutes per unit) comes from ONE of three places, and
the result always says which:

  * "owner" — a rate the OWNER typed in Owner Admin with its SOURCE and DATE
              (e.g. "PWD Schedule of Rates 2022, rev. Feb 2023");
  * "user"  — the user's own number (edited in the app);
  * "none"  — no rate yet: shown as "enter your rate", NEVER a made-up price.

There are NO built-in market prices in this file on purpose (owner rule: never
invent "market prices"; label estimates). PURE: no Django, no DB, no clock.
"""
from __future__ import annotations

import math

RATE_PREFIX = "est"
MAX_INPUT = 1_000_000

# Rate keys are stored in core.models.WorldAdminValue (key max 40 chars):
#   "est:<template>:<line>:c" = ৳ per unit, "…:t" = minutes per unit.


def rate_key(tpl, line, kind):
    return "%s:%s:%s:%s" % (RATE_PREFIX, tpl, line, kind)


def _q(*keys, k=1, plus=0):
    """qty = (product of the answers + plus) * k, rounded up to a whole unit."""
    def f(a):
        v = 1 if keys else 0
        for key in keys:
            v *= a.get(key, 0)
        return int(math.ceil((v + plus) * k))
    return f


# template id -> (bn title, en title, icon, questions, lines)
#   question: (key, bn, en, unit_bn, unit_en, default)
#   line:     (id, bn, en, unit_bn, unit_en, qty_fn)
TEMPLATES = {
    "home": (
        "বাসা মেরামত ও রং", "Home repair & paint", "home_repair_service",
        [("paint_sqft", "কত বর্গফুট দেয়াল রং করবেন?", "Wall area to paint?", "বর্গফুট", "sq ft", 0),
         ("tile_sqft", "কত বর্গফুট মেঝেতে টাইলস?", "Floor area for tiles?", "বর্গফুট", "sq ft", 0),
         ("points", "কয়টি বৈদ্যুতিক পয়েন্ট (সুইচ/সকেট)?", "Electric points (switch/socket)?", "টি", "pcs", 0)],
        [("paint", "রং (উপকরণ + মিস্ত্রি)", "Paint (material + labour)", "বর্গফুট", "sq ft", _q("paint_sqft")),
         ("putty", "পুটিং/প্রাইমার", "Putty / primer", "বর্গফুট", "sq ft", _q("paint_sqft")),
         ("tiles", "টাইলস (উপকরণ)", "Tiles (material)", "বর্গফুট", "sq ft", _q("tile_sqft")),
         ("tilework", "টাইলস বসানো (মিস্ত্রি)", "Tile fitting (labour)", "বর্গফুট", "sq ft", _q("tile_sqft")),
         ("wiring", "বৈদ্যুতিক পয়েন্ট", "Electric points", "টি", "pcs", _q("points")),
         ("cleanup", "পরিষ্কার ও মালামাল সরানো", "Clean-up & debris removal", "বার", "job", _q(plus=1))],
    ),
    "event": (
        "অনুষ্ঠান (বিয়ে/জন্মদিন)", "Event (wedding/birthday)", "celebration",
        [("guests", "কতজন অতিথি?", "How many guests?", "জন", "guests", 0),
         ("cards", "কয়টি দাওয়াত কার্ড?", "How many invitation cards?", "টি", "cards", 0),
         ("hours", "অনুষ্ঠান কত ঘণ্টা?", "Event length?", "ঘণ্টা", "hours", 0)],
        [("food", "খাবার", "Food", "প্লেট", "plates", _q("guests")),
         ("venue", "হল/ভেন্যু", "Hall / venue", "ঘণ্টা", "hours", _q("hours")),
         ("decor", "সাজসজ্জা", "Decoration", "বার", "job", _q(plus=1)),
         ("cards", "দাওয়াত কার্ড", "Invitation cards", "টি", "cards", _q("cards")),
         ("photo", "ছবি/ভিডিও", "Photo / video", "ঘণ্টা", "hours", _q("hours")),
         ("transport", "যাতায়াত", "Transport", "বার", "job", _q(plus=1))],
    ),
    "travel": (
        "ভ্রমণ", "Trip", "luggage",
        [("people", "কতজন যাবেন?", "How many travellers?", "জন", "people", 0),
         ("nights", "কত রাত থাকবেন?", "How many nights?", "রাত", "nights", 0),
         ("rooms", "কয়টি রুম লাগবে?", "How many rooms?", "টি", "rooms", 0)],
        [("tickets", "যাওয়া-আসার টিকিট", "Return tickets", "টিকিট", "tickets", _q("people", k=2)),
         ("hotel", "হোটেল", "Hotel", "রুম-রাত", "room-nights", _q("rooms", "nights")),
         ("food", "খাবার", "Food", "জন-দিন", "person-days", lambda a: a.get("people", 0) * (a.get("nights", 0) + 1)),
         ("local", "স্থানীয় যাতায়াত", "Local transport", "দিন", "days", _q("nights", plus=1)),
         ("entry", "প্রবেশ ফি/টিকিট", "Entry fees", "জন", "people", _q("people"))],
    ),
    "business": (
        "ছোট ব্যবসা শুরু", "Small business start-up", "storefront",
        [("advance", "দোকান ভাড়ার অগ্রিম কত মাসের?", "Shop rent advance (months)?", "মাস", "months", 0),
         ("runway", "লাভ ছাড়া কত মাস চালানোর প্রস্তুতি?", "Months to run before profit?", "মাস", "months", 0),
         ("staff", "কতজন কর্মী?", "How many staff?", "জন", "staff", 0)],
        [("licence", "ট্রেড লাইসেন্স", "Trade licence", "বার", "once", _q(plus=1)),
         ("rentadv", "ভাড়ার অগ্রিম", "Rent advance", "মাস", "months", _q("advance")),
         ("fitout", "দোকান সাজানো (তাক/আলো)", "Fit-out (shelves/lights)", "বার", "job", _q(plus=1)),
         ("sign", "সাইনবোর্ড", "Signboard", "টি", "pcs", _q(plus=1)),
         ("stock", "প্রথম মাল (স্টক)", "Opening stock", "বার", "lot", _q(plus=1)),
         ("rent", "মাসিক ভাড়া", "Monthly rent", "মাস", "months", _q("runway")),
         ("salary", "কর্মীর বেতন", "Staff salary", "জন-মাস", "staff-months", _q("staff", "runway")),
         ("utility", "বিদ্যুৎ/নেট/অন্যান্য", "Power / internet / misc", "মাস", "months", _q("runway"))],
    ),
    "tutor": (
        "টিউশনি/কোচিং", "Tutoring / coaching", "school",
        [("subjects", "কয়টি বিষয়?", "How many subjects?", "টি", "subjects", 0),
         ("months", "কত মাস?", "How many months?", "মাস", "months", 0),
         ("sessions", "সপ্তাহে কয়দিন পড়বে?", "Sessions per week?", "দিন", "days/week", 0)],
        [("fee", "শিক্ষকের বেতন", "Tutor fee", "বিষয়-মাস", "subject-months", _q("subjects", "months")),
         ("books", "বই ও গাইড", "Books & guides", "বিষয়", "subjects", _q("subjects")),
         ("exam", "মডেল টেস্ট/পরীক্ষার ফি", "Model test / exam fees", "মাস", "months", _q("months")),
         ("class", "পড়ার সময় (ক্লাস)", "Study sessions", "ক্লাস", "sessions",
          lambda a: int(math.ceil(a.get("sessions", 0) * a.get("months", 0) * 52 / 12)))],
    ),
}


def ids():
    return list(TEMPLATES)


def _pick(lang, bn, en):
    return en if lang == "en" else bn


def catalog(lang="bn"):
    """Public list: [{id, title, icon, questions:[{key,label,unit,default}]}]."""
    out = []
    for tid, (tb, te, icon, qs, _lines) in TEMPLATES.items():
        out.append({"id": tid, "title": _pick(lang, tb, te), "icon": icon,
                    "questions": [{"key": k, "label": _pick(lang, b, e),
                                   "unit": _pick(lang, ub, ue), "default": d}
                                  for k, b, e, ub, ue, d in qs]})
    return out


def rate_keys():
    """Every (key, template, line, kind, bn label, en label, unit_bn, unit_en)
    the owner can fill — the Owner Admin page lists exactly these."""
    out = []
    for tid, (tb, te, _i, _q2, lines) in TEMPLATES.items():
        for lid, b, e, ub, ue, _f in lines:
            out.append((rate_key(tid, lid, "c"), tid, lid, "c",
                        "%s — %s (৳/%s)" % (tb, b, ub), "%s — %s (৳/%s)" % (te, e, ue), ub, ue))
            out.append((rate_key(tid, lid, "t"), tid, lid, "t",
                        "%s — %s (মিনিট/%s)" % (tb, b, ub), "%s — %s (min/%s)" % (te, e, ue), ub, ue))
    return out


def clean_inputs(tid, raw):
    """Answers -> {key: int 0..MAX_INPUT}; junk/blank/negative -> 0."""
    qs = TEMPLATES[tid][3]
    out = {}
    raw = raw or {}
    for k, _b, _e, _ub, _ue, d in qs:
        v = raw.get(k, d)
        try:
            n = int(float(str(v).replace(",", "").strip() or 0))
        except (TypeError, ValueError):
            n = 0
        out[k] = max(0, min(MAX_INPUT, n))
    return out


def _rate(rates, key):
    """rates: {key: {"value": number|None, "source": str, "date": "YYYY-MM-DD"}}.
    An owner rate counts ONLY with a value > 0 AND a source AND a date."""
    r = (rates or {}).get(key) or {}
    try:
        v = float(r.get("value")) if r.get("value") is not None else None
    except (TypeError, ValueError):
        v = None
    if v is None or v <= 0 or not str(r.get("source") or "").strip() or not r.get("date"):
        return None
    return {"value": v, "source": str(r["source"]).strip()[:200], "date": str(r["date"])}


def compute(tid, inputs, rates=None, lang="bn"):
    """Build the template's lines for these answers.

    Returns {template, title, inputs, lines:[{id, name, unit, qty, unit_cost,
    minutes, rate_src:{kind, source, date}, time_src:{...}}], missing_rates,
    estimate:True, note}. unit_cost/minutes are None when no rate exists — the
    app shows "enter your rate" and adds 0 to the total until the user does.
    Lines with qty 0 are dropped (the user did not ask for them)."""
    if tid not in TEMPLATES:
        raise KeyError(tid)
    tb, te, _icon, _qs, lines = TEMPLATES[tid]
    a = clean_inputs(tid, inputs)
    out, missing = [], 0
    for lid, b, e, ub, ue, f in lines:
        try:
            qty = max(0, min(MAX_INPUT, int(f(a))))
        except Exception:
            qty = 0
        if qty <= 0:
            continue
        c = _rate(rates, rate_key(tid, lid, "c"))
        t = _rate(rates, rate_key(tid, lid, "t"))
        if c is None:
            missing += 1
        out.append({
            "id": lid, "name": _pick(lang, b, e), "unit": _pick(lang, ub, ue),
            "qty": qty,
            "unit_cost": c["value"] if c else None,
            "minutes": int(round(t["value"])) if t else None,
            "rate_src": ({"kind": "owner", "source": c["source"], "date": c["date"]}
                         if c else {"kind": "none"}),
            "time_src": ({"kind": "owner", "source": t["source"], "date": t["date"]}
                         if t else {"kind": "none"}),
        })
    return {"template": tid, "title": _pick(lang, tb, te), "inputs": a,
            "lines": out, "missing_rates": missing, "estimate": True,
            "note": _pick(lang,
                          "এটি অনুমান — দরপত্র বা কোটেশন নয়। প্রতিটি রেটের উৎস পাশে লেখা; রেট না থাকলে নিজের জানা দাম দিন।",
                          "This is an estimate — not a quote. Each rate shows its source; where there is none, enter the price you know.")}
