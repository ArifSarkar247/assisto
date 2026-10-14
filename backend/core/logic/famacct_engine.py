"""
famacct_engine.py — pure, unit-testable FAMILY ACCOUNTING math (#61, SPEC v2.1
§21).  Shared family money: who-paid-what, split expenses among family members,
a family budget pool with contributions, and settle-up ("Dad owes Mom ৳500").

DESIGN (mirrors money_engine.py's pure-function style, but with ONE hard rule):

    ALL MONEY IS INTEGER POISHA.  Never a float, never a Decimal here.
    1 taka = 100 poisha.  Every amount in / out of this module is an int.
    Splitting N poisha among k members distributes the remainder poisha
    one-each to the first `r` members, so the shares ALWAYS sum EXACTLY
    back to the input — zero drift, no lost/created paisa, ever.

No Django, no AI key, no I/O.  The views layer feeds it plain dicts (member
rows come straight from the existing `family` / Connected-Circle contacts — this
module READS them, it defines no new contact store) and renders what it returns.
All human-facing copy is returned as bilingual {bn,en} pairs so the Dart layer
shows them directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.famacct_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from collections import defaultdict


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only; display helpers)
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. Accepts int poisha already,
    '12.50' taka strings, ints/floats of taka — but the result is an int of
    poisha, so no float ever survives into the ledger. Junk -> 0."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):  # guard: bool is an int subclass
        return 0
    if isinstance(v, int):
        return v  # already poisha
    # taka string/float -> poisha, rounded to the nearest paisa (half-up),
    # computed on the decimal STRING so binary-float noise never leaks in.
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]  # 3 digits lets us round the 3rd
    try:
        taka = int(whole)
        milli = int(frac)  # thousandths of a taka
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def fmt_poisha(p, lang="bn"):
    """Format integer poisha as a ৳ amount string (always 2 dp). The ৳ sign +
    Bangla copy live here, not in .dart."""
    p = int(p)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    grp = _group(taka)
    body = f"{grp}.{paisa:02d}"
    s = ("-" if neg else "") + "৳" + body  # ৳
    return s


def _group(n):
    """Group an integer with the South-Asian lakh/crore comma style."""
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


# ---------------------------------------------------------------------------
# splitting — the no-float-drift core
# ---------------------------------------------------------------------------

def split_equal(total_poisha, member_ids):
    """Split INTEGER poisha equally among members. Remainder poisha is handed
    out one-each to the first members (deterministic by given order), so the
    returned shares sum EXACTLY to total_poisha. Returns
    [{'member': id, 'share': poisha}, ...]."""
    total = int(total_poisha)
    ids = list(member_ids)
    n = len(ids)
    if n == 0:
        return []
    base, rem = divmod(abs(total), n)
    sign = -1 if total < 0 else 1
    rows = []
    for i, mid in enumerate(ids):
        share = base + (1 if i < rem else 0)
        rows.append({"member": mid, "share": sign * share})
    return rows


def split_shares(total_poisha, parts):
    """Weighted split. parts: [{'member', 'weight'}]. Largest-remainder method
    on integer poisha: each gets floor(total*w/W); the leftover poisha go to
    the members with the biggest fractional remainders (ties -> input order),
    so shares sum EXACTLY to total. Returns [{'member','share'}]."""
    total = int(total_poisha)
    parts = list(parts)
    if not parts:
        return []
    weights = [max(0, int(p.get("weight", 1))) for p in parts]
    W = sum(weights)
    if W == 0:
        return split_equal(total, [p.get("member") for p in parts])
    sign = -1 if total < 0 else 1
    t = abs(total)
    floors, rems = [], []
    for w in weights:
        num = t * w
        floors.append(num // W)
        rems.append(num % W)
    leftover = t - sum(floors)
    # distribute leftover poisha to the largest remainders
    order = sorted(range(len(parts)), key=lambda i: (-rems[i], i))
    for k in range(leftover):
        floors[order[k]] += 1
    return [{"member": parts[i].get("member"), "share": sign * floors[i]}
            for i in range(len(parts))]


def split_exact(parts):
    """Fixed per-member amounts the user typed. parts: [{'member','amount'}]
    where amount is taka-ish -> coerced to poisha. The total is simply the sum
    (there is no residue to absorb — the user specified every share).
    Returns ([{'member','share'}], total_poisha)."""
    rows = [{"member": p.get("member"), "share": to_poisha(p.get("amount"))}
            for p in parts]
    return rows, sum(r["share"] for r in rows)


# ---------------------------------------------------------------------------
# a shared expense: who paid, how it splits, what each person owes the payer
# ---------------------------------------------------------------------------

def shared_expense(payer_id, total_poisha, member_ids, mode="equal",
                   parts=None):
    """One family expense. Returns the split + each non-payer's debt TO the
    payer. mode: 'equal' | 'shares' | 'exact'.
      - equal:  member_ids split total_poisha evenly.
      - shares: parts=[{'member','weight'}].
      - exact:  parts=[{'member','amount'}]; total is their sum.
    'debts' are {'from': member, 'to': payer, 'amount': poisha} for everyone
    except the payer's own share (you don't owe yourself)."""
    if mode == "exact":
        shares, total = split_exact(parts or [])
    elif mode == "shares":
        total = int(total_poisha)
        shares = split_shares(total, parts or [])
    else:
        total = int(total_poisha)
        shares = split_equal(total, member_ids)
    debts = [{"from": s["member"], "to": payer_id, "amount": s["share"]}
             for s in shares if s["member"] != payer_id and s["share"] != 0]
    return {"payer": payer_id, "total": total, "mode": mode,
            "shares": shares, "debts": debts}


# ---------------------------------------------------------------------------
# settle-up — net who-owes-whom across many expenses, minimised
# ---------------------------------------------------------------------------

def net_balances(expenses):
    """Collapse many shared expenses into each member's NET position (poisha):
    positive = the family owes them (they overpaid); negative = they owe the
    family. Sums to 0 exactly (integer poisha). Each expense is the dict from
    shared_expense(). Returns {member_id: net_poisha}."""
    net = defaultdict(int)
    for e in expenses:
        payer = e["payer"]
        net[payer] += e["total"]
        for s in e["shares"]:
            net[s["member"]] -= s["share"]
    return {k: v for k, v in net.items()}


def settle_up(expenses):
    """Greedy minimal-transfer settlement. Turns net balances into a short list
    of concrete 'X pays Y ৳Z' transfers (poisha). Debtors (negative) are
    matched against creditors (positive) largest-first; each step clears at
    least one person, so at most n-1 transfers. Sums reconcile exactly because
    it's all integer poisha. Returns [{'from','to','amount'}]."""
    net = net_balances(expenses)
    creditors = sorted(((m, a) for m, a in net.items() if a > 0),
                       key=lambda x: (-x[1], x[0]))
    debtors = sorted(((m, -a) for m, a in net.items() if a < 0),
                     key=lambda x: (-x[1], x[0]))
    transfers = []
    ci = di = 0
    cred = [[m, a] for m, a in creditors]
    debt = [[m, a] for m, a in debtors]
    while ci < len(cred) and di < len(debt):
        cm, ca = cred[ci]
        dm, da = debt[di]
        pay = min(ca, da)
        if pay > 0:
            transfers.append({"from": dm, "to": cm, "amount": pay})
        cred[ci][1] -= pay
        debt[di][1] -= pay
        if cred[ci][1] == 0:
            ci += 1
        if debt[di][1] == 0:
            di += 1
    return transfers


def settle_message(from_name, to_name, amount_poisha, lang="bn"):
    """Bilingual 'Dad owes Mom ৳500' style line for one transfer."""
    amt = fmt_poisha(amount_poisha, lang)
    return pick(
        lang,
        f"{from_name} {to_name}-কে {amt} দেবেন",
        f"{from_name} owes {to_name} {amt}",
    )


# ---------------------------------------------------------------------------
# family budget pool — a shared monthly target everyone contributes to
# ---------------------------------------------------------------------------

def pool_status(target_poisha, contributions, lang="bn"):
    """Family budget pool. contributions: [{'member','amount'(poisha)}].
    Returns collected / target / remaining (poisha), a 0-100 pct, a state, and
    a per-member contribution breakdown. All integer poisha."""
    target = int(target_poisha)
    collected = sum(int(c.get("amount", 0)) for c in contributions)
    remaining = target - collected
    if target > 0:
        pct = collected * 100 // target
        pct = min(100, pct)
        state = "met" if collected >= target else ("near" if pct >= 80 else "open")
    else:
        pct, state = (100 if collected > 0 else 0), "none"
    per = defaultdict(int)
    for c in contributions:
        per[c.get("member")] += int(c.get("amount", 0))
    breakdown = [{"member": m, "amount": a} for m, a in per.items()]
    return {
        "target": target,
        "collected": collected,
        "remaining": remaining,
        "pct": pct,
        "state": state,
        "breakdown": breakdown,
        "label": pool_state_label(state, lang),
    }


def pool_state_label(state, lang="bn"):
    labels = {
        "met":  ("লক্ষ্য পূরণ", "Target met"),
        "near": ("প্রায় পূরণ", "Almost there"),
        "open": ("চলমান", "In progress"),
        "none": ("কোনো লক্ষ্য নেই", "No target set"),
    }
    bn, en = labels.get(state, ("", ""))
    return {"bn": bn, "en": en}


# ---------------------------------------------------------------------------
# shared-bill categories (rent / utilities / groceries …) — bilingual labels
# ---------------------------------------------------------------------------

BILL_CATEGORIES = {
    "rent":      ("বাসা ভাড়া", "Rent"),
    "utility":   ("ইউটিলিটি বিল", "Utilities"),
    "groceries": ("বাজার", "Groceries"),
    "internet":  ("ইন্টারনেট", "Internet"),
    "transport": ("যাতায়াত", "Transport"),
    "health":    ("স্বাস্থ্য", "Health"),
    "education": ("শিক্ষা", "Education"),
    "other":     ("অন্যান্য", "Other"),
}


def bill_category_label(slug, lang="bn"):
    bn, en = BILL_CATEGORIES.get(slug, (slug, slug))
    return pick(lang, bn, en)


def bill_catalog(lang="bn"):
    """Ordered list for the category picker (slug + localized label)."""
    order = ["rent", "utility", "groceries", "internet", "transport",
             "health", "education", "other"]
    return [{"slug": c, "label": bill_category_label(c, lang)} for c in order]


# ---------------------------------------------------------------------------
# per-member view + monthly family summary
# ---------------------------------------------------------------------------

def member_view(member_id, expenses):
    """One member's slice: total they paid, total their share came to, and the
    net (paid - owed). All integer poisha."""
    paid = sum(e["total"] for e in expenses if e["payer"] == member_id)
    owed = 0
    for e in expenses:
        for s in e["shares"]:
            if s["member"] == member_id:
                owed += s["share"]
    return {"member": member_id, "paid": paid, "share_total": owed,
            "net": paid - owed}


def category_totals(expenses):
    """{category_slug: total_poisha} across the given expenses. Reads each
    expense's optional 'category' (defaults to 'other')."""
    out = defaultdict(int)
    for e in expenses:
        out[e.get("category") or "other"] += e["total"]
    return dict(out)


def monthly_summary(expenses, member_ids=None):
    """Whole-family month roll-up: grand total spent, per-category totals,
    per-member paid/share/net, and the minimal settle-up transfers. Integer
    poisha throughout; the per-member nets sum to 0."""
    grand = sum(e["total"] for e in expenses)
    members = member_ids
    if members is None:
        seen = []
        for e in expenses:
            for s in e["shares"]:
                if s["member"] not in seen:
                    seen.append(s["member"])
            if e["payer"] not in seen:
                seen.append(e["payer"])
        members = seen
    return {
        "total": grand,
        "expense_count": len(expenses),
        "by_category": category_totals(expenses),
        "members": [member_view(m, expenses) for m in members],
        "settlements": settle_up(expenses),
    }


# ---------------------------------------------------------------------------
# privacy — members see SHARED only, never anyone's private money
# ---------------------------------------------------------------------------

def visible_to_member(expense, viewer_id):
    """Privacy gate for the family ledger. A member may see an expense ONLY if
    it is a SHARED family item (shared=True) AND they are a participant (payer
    or in the split). Private (shared=False) items — personal spending that
    happens to be logged — are NEVER shown to other family members. Returns a
    bool; the view filters the ledger through this before serializing."""
    if not expense.get("shared", True):
        # private item: only its own owner/payer sees it
        return expense.get("payer") == viewer_id
    participants = {s["member"] for s in expense.get("shares", [])}
    participants.add(expense.get("payer"))
    return viewer_id in participants


def filter_shared(expenses, viewer_id):
    """The ledger a given member is allowed to load."""
    return [e for e in expenses if visible_to_member(e, viewer_id)]
