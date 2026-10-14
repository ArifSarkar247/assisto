"""
language_partner.py — the deterministic, key-free engine behind Assisto's
LANGUAGE-LEARNING PARTNER (#132, SPEC v2.1 §21, ADVANCED).

A bilingual (bn↔en) practice tool: a built-in DECK of real vocabulary/phrases,
FLASHCARD practice with spaced-repetition-style scheduling, text PRONUNCIATION
hints, and simple deterministic QUIZZES. Fully usable with NO key via the
built-in decks.

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. Everything is a DETERMINISTIC function —
same inputs always give the same output — so the on-device Dart mirror produces
identical results offline and the tests can pin them. Any "today / now" is
PASSED IN by the caller (no live clock), exactly like `probashi.py`.

HONEST AI, KEY-GATED
--------------------
Vocabulary, flashcards, scheduling and quizzes are all served RIGHT NOW by this
deterministic engine and need no key. A free-form LIVE CONVERSATION partner
(chat back-and-forth that reacts to what the learner says) genuinely needs a
model; `live_conversation_seam()` documents that request shape and always
returns `ai_required=True, mock=True`. The UI shows the honest "connect an AI
key for live conversation practice" state for that one feature; nothing here
calls a model.

SPACED REPETITION
-----------------
A small, honest Leitner-style scheduler: each card has a `box` (1..5). A correct
recall promotes the card one box (longer interval); a miss resets it to box 1.
`due_after_days(box)` maps a box to its review interval. `schedule_review` takes
the current box + a pass/fail + today's day-number (passed in) and returns the
next box and the day it's next due — deterministic, no clock, no DB.

CONTENT
-------
The deck below is REAL, useful everyday bn↔en vocabulary/phrases (≥20 items)
with genuine pronunciation hints (romanised, approximate — labelled as hints,
not IPA). Nothing is fabricated or presented as authoritative phonetics.

Everything is plain stdlib and hand-verified in language_partner_tests_snippets.py.
"""

# ---------------------------------------------------------------- decks
# Neutral English deck keys the UI localises. Each card is bidirectional
# (bn↔en); the "direction" chosen at practice time decides prompt vs answer.
DECKS = ("greetings", "daily", "travel", "shopping", "numbers")

# The honest marker key results carry (deck/quiz are deterministic built-ins).
MARKER_KEY = "builtin_deck"

# Leitner boxes 1..5 → review interval in days. Box 1 = review next day; each
# promotion roughly doubles the gap. Deterministic study aid, not a guarantee.
_BOX_DAYS = {1: 1, 2: 2, 3: 4, 4: 7, 5: 15}
MAX_BOX = 5
MIN_BOX = 1

# Each card:
#   id          stable id
#   deck        one of DECKS
#   bn          the Bangla word/phrase
#   en          the English word/phrase
#   hint        a ROMANISED pronunciation hint for the Bangla (approximate; a
#               study aid, not IPA). For bn→en practice the learner reads bn;
#               the hint helps a non-Bangla learner say the Bangla aloud.
DECK = [
    # ---- greetings ----
    {"id": "g_hello", "deck": "greetings", "bn": "হ্যালো", "en": "Hello",
     "hint": "hyalo"},
    {"id": "g_howareyou", "deck": "greetings", "bn": "কেমন আছেন?",
     "en": "How are you?", "hint": "kemon aachhen?"},
    {"id": "g_fine", "deck": "greetings", "bn": "আমি ভালো আছি",
     "en": "I am fine", "hint": "aami bhalo aachhi"},
    {"id": "g_thanks", "deck": "greetings", "bn": "ধন্যবাদ", "en": "Thank you",
     "hint": "dhonnobaad"},
    {"id": "g_welcome", "deck": "greetings", "bn": "স্বাগতম", "en": "Welcome",
     "hint": "shagotom"},

    # ---- daily life ----
    {"id": "d_water", "deck": "daily", "bn": "পানি", "en": "Water",
     "hint": "paani"},
    {"id": "d_food", "deck": "daily", "bn": "খাবার", "en": "Food",
     "hint": "khaabaar"},
    {"id": "d_rice", "deck": "daily", "bn": "ভাত", "en": "Rice",
     "hint": "bhaat"},
    {"id": "d_sleep", "deck": "daily", "bn": "ঘুম", "en": "Sleep",
     "hint": "ghum"},
    {"id": "d_today", "deck": "daily", "bn": "আজ", "en": "Today",
     "hint": "aaj"},

    # ---- travel ----
    {"id": "t_where", "deck": "travel", "bn": "কোথায়?", "en": "Where?",
     "hint": "kothaay?"},
    {"id": "t_howmuch", "deck": "travel", "bn": "কত দূর?", "en": "How far?",
     "hint": "koto dur?"},
    {"id": "t_left", "deck": "travel", "bn": "বাম", "en": "Left",
     "hint": "baam"},
    {"id": "t_right", "deck": "travel", "bn": "ডান", "en": "Right",
     "hint": "daan"},
    {"id": "t_stop", "deck": "travel", "bn": "থামুন", "en": "Stop",
     "hint": "thaamun"},

    # ---- shopping ----
    {"id": "s_price", "deck": "shopping", "bn": "দাম কত?", "en": "What's the price?",
     "hint": "daam koto?"},
    {"id": "s_expensive", "deck": "shopping", "bn": "অনেক দাম", "en": "Too expensive",
     "hint": "onek daam"},
    {"id": "s_buy", "deck": "shopping", "bn": "আমি কিনব", "en": "I will buy",
     "hint": "aami kinbo"},
    {"id": "s_bag", "deck": "shopping", "bn": "ব্যাগ", "en": "Bag",
     "hint": "byaag"},

    # ---- numbers ----
    {"id": "n_one", "deck": "numbers", "bn": "এক", "en": "One", "hint": "ek"},
    {"id": "n_two", "deck": "numbers", "bn": "দুই", "en": "Two", "hint": "dui"},
    {"id": "n_three", "deck": "numbers", "bn": "তিন", "en": "Three",
     "hint": "tin"},
    {"id": "n_ten", "deck": "numbers", "bn": "দশ", "en": "Ten", "hint": "dosh"},
    {"id": "n_hundred", "deck": "numbers", "bn": "একশ", "en": "Hundred",
     "hint": "eksho"},
]

# Practice directions (which side is the prompt).
DIRECTIONS = ("bn2en", "en2bn")


# ----------------------------------------------------------------- helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def decks():
    """Deck keys, in stable order (UI localises each)."""
    return list(DECKS)


def cards_for(deck):
    """All cards for a deck, stable order. Empty for unknown deck."""
    return [c for c in DECK if c["deck"] == deck]


def card(card_id):
    """One card by id, with its pronunciation hint. Empty-shaped for unknown."""
    for c in DECK:
        if c["id"] == card_id:
            return dict(c)
    return {"id": card_id, "deck": "", "bn": "", "en": "", "hint": ""}


def prompt_answer(card_id, direction="bn2en"):
    """For a card + direction, return {prompt, answer, hint}. For bn2en the
    prompt is Bangla and the answer English (hint helps pronounce the prompt);
    for en2bn the prompt is English and the answer is Bangla (+ its hint).
    Deterministic. Honest: the hint is a romanised approximation, labelled so
    in the UI — never presented as exact phonetics."""
    c = card(card_id)
    if direction == "en2bn":
        return {"id": c["id"], "direction": "en2bn", "prompt": c["en"],
                "answer": c["bn"], "hint": c["hint"]}
    return {"id": c["id"], "direction": "bn2en", "prompt": c["bn"],
            "answer": c["en"], "hint": c["hint"]}


# ----------------------------------------------------- spaced repetition (SR)

def due_after_days(box):
    """Review interval (days) for a Leitner box. Clamps to the 1..5 range."""
    b = max(MIN_BOX, min(MAX_BOX, int(box or MIN_BOX)))
    return _BOX_DAYS[b]


def schedule_review(box, passed, today_day):
    """Deterministic SR step. NO live clock — `today_day` is an integer day
    number the CALLER passes (e.g. days since an epoch, or a simple counter).

    * passed=True  → promote one box (capped at MAX_BOX), longer next interval.
    * passed=False → reset to box 1 (see it again soon).

    Returns {box, next_due_day, interval_days}. Same inputs → same output."""
    cur = max(MIN_BOX, min(MAX_BOX, int(box or MIN_BOX)))
    nxt = min(MAX_BOX, cur + 1) if passed else MIN_BOX
    interval = due_after_days(nxt)
    return {"box": nxt, "interval_days": interval,
            "next_due_day": int(today_day) + interval}


def due_cards(progress, today_day):
    """Given a list of per-card progress rows and today's day-number, return the
    card ids that are DUE (next_due_day <= today). A card with no progress row
    counts as due (never studied). Deterministic; pure filtering.

    `progress` rows look like: {"card_id": "g_hello", "box": 2,
                                "next_due_day": 120}."""
    by_id = {}
    for p in (progress or []):
        cid = p.get("card_id")
        if cid:
            by_id[cid] = p
    due = []
    for c in DECK:
        p = by_id.get(c["id"])
        if p is None:
            due.append(c["id"])  # never studied → due
        elif int(p.get("next_due_day", 0)) <= int(today_day):
            due.append(c["id"])
    return due


def deck_progress(deck, progress):
    """Deterministic roll-up for a deck header: how many of its cards have been
    started (have a progress row) and the average box (mastery proxy)."""
    pool = cards_for(deck)
    by_id = {p.get("card_id"): p for p in (progress or []) if p.get("card_id")}
    started = [c for c in pool if c["id"] in by_id]
    boxes = [max(MIN_BOX, min(MAX_BOX, int(by_id[c["id"]].get("box", 1))))
             for c in started]
    avg_box = round(sum(boxes) / len(boxes), 2) if boxes else 0
    return {"deck": deck, "started": len(started), "total": len(pool),
            "avg_box": avg_box,
            "mastered": len([b for b in boxes if b >= MAX_BOX])}


# ----------------------------------------------------------------- quiz

def quiz(deck, direction="bn2en", seed=0):
    """Build a deterministic multiple-choice quiz for a deck.

    Each question = one card's prompt + 4 options (the right answer + 3
    distractors drawn deterministically from OTHER cards in the deck, chosen by
    a fixed rotation keyed by `seed` so there is NO randomness/clock). The
    correct option index is returned so the UI can grade locally.

    Returns {deck, direction, questions:[{card_id, prompt, options[], answer_index,
             hint}], problems:[...]}. Falls back gracefully for tiny decks."""
    pool = cards_for(deck)
    if len(pool) < 2:
        return {"deck": deck, "direction": direction, "questions": [],
                "problems": ["deck_too_small"]}
    seed = int(seed or 0)

    def ans_of(c):
        return c["bn"] if direction == "en2bn" else c["en"]

    def prompt_of(c):
        return c["en"] if direction == "en2bn" else c["bn"]

    questions = []
    n = len(pool)
    for i, c in enumerate(pool):
        # three distractors: deterministic stride over the other cards
        others = [pool[(i + 1 + j + seed) % n] for j in range(n - 1)]
        distractors = [ans_of(o) for o in others
                       if ans_of(o) != ans_of(c)][:3]
        options = [ans_of(c)] + distractors
        # deterministic placement of the answer: rotate by (i+seed)
        pos = (i + seed) % len(options)
        options = options[-pos:] + options[:-pos] if pos else options
        answer_index = options.index(ans_of(c))
        questions.append({
            "card_id": c["id"],
            "prompt": prompt_of(c),
            "options": options,
            "answer_index": answer_index,
            "hint": c["hint"],
        })
    return {"deck": deck, "direction": direction, "questions": questions,
            "problems": []}


def grade_quiz(questions, answers):
    """Deterministic scoring. `answers` is a list of chosen option indices
    aligned with `questions`. Returns {correct, total, percent, wrong_card_ids}.
    Out-of-range / missing answers count as wrong."""
    total = len(questions or [])
    correct = 0
    wrong = []
    for i, q in enumerate(questions or []):
        chosen = answers[i] if (answers and i < len(answers)) else -1
        if chosen == q.get("answer_index"):
            correct += 1
        else:
            wrong.append(q.get("card_id"))
    return {"correct": correct, "total": total,
            "percent": round(100 * correct / total) if total else 0,
            "wrong_card_ids": wrong}


# -------------------------------------------------------------- AI seam (gated)

def live_conversation_seam(deck, user_message):
    """DOCUMENTED key-gated seam for LIVE CONVERSATION practice — NOT built here.

    Returns the request SHAPE the app would route to `core.ai.generate` when an
    AI key is connected (a back-and-forth partner that replies in the target
    language, corrects gently, and keeps the thread going on the deck's theme).
    With no key, the app shows the honest "connect an AI key for live
    conversation" state; the decks, flashcards, SR and quizzes all still work.
    Always `ai_required=True, mock=True`; never calls a model."""
    return {
        "action": "live_conversation",
        "deck": deck,
        "user_message": _clean(user_message),
        "reply": "",            # a real model would reply + gently correct
        "correction": "",       # a real model would note one improvement
        "ai_required": True,    # honest: live conversation needs the key
        "mock": True,
        "marker": MARKER_KEY,
    }
