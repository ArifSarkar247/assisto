"""
expense_split.py — pure, deterministic EXPENSE SPLITTING math (#183, SPEC v2.1
§20). A Splitwise-style group: people, shared expenses (who paid, split equally
or by weighted share or by exact amounts), each person's NET balance (owes /
is owed), and a "simplify debts" settle-up suggestion — the shortest list of
"X pays Y ৳Z" transfers that clears everyone.

HARD RULES (identical to money_engine / famacct_engine discipline):

  * ALL MONEY IS INTEGER POISHA.  1 taka = 100 poisha.  No float ever enters
    the ledger. Splitting N poisha among k people uses the largest-remainder
    method (leftover poisha to the biggest fractional remainders, ties -> input
    order) so the shares ALWAYS sum EXACTLY back to the expense total — zero
    drift, no paisa lost or invented. Net balances therefore sum to EXACTLY 0.
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING. Computes and returns plain dicts;
    the view layer persists the group + expenses in a flexible per-user JSON
    collection and renders what we return. The app never moves a single taka —
    settle-up is a SUGGESTION people act on outside the app.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.expense_split_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from collections import defaultdict

SPLIT_MODES = ("equal", "shares", "exact")


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only) — same discipline as the money modules
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha (see money_engine). Junk -> 0."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
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


def fmt_poisha(p):
    """Format integer poisha as a ৳ amount string (always 2 dp)."""
    p = int(p)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# splitting — the no-float-drift core
# ---------------------------------------------------------------------------

def split_equal(total_poisha, member_ids):
    """Split INTEGER poisha equally; remainder poisha one-each to the first
    members (deterministic by input order). Shares sum EXACTLY to total.
    Returns [{'member','share'}]."""
    total = int(total_poisha)
    ids = list(member_ids)
    n = len(ids)
    if n == 0:
        return []
    base, rem = divmod(abs(total), n)
    sign = -1 if total < 0 else 1
    return [{"member": mid, "share": sign * (base + (1 if i < rem else 0))}
            for i, mid in enumerate(ids)]


def split_shares(total_poisha, parts):
    """Weighted split (largest-remainder) on integer poisha. parts:
    [{'member','weight'}]. Shares sum EXACTLY to total. Returns
    [{'member','share'}]."""
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
    order = sorted(range(len(parts)), key=lambda i: (-rems[i], i))
    for k in range(leftover):
        floors[order[k]] += 1
    return [{"member": parts[i].get("member"), "share": sign * floors[i]}
            for i in range(len(parts))]


def split_exact(parts):
    """Fixed per-member amounts the user typed. parts: [{'member','amount'}].
    Returns ([{'member','share'}], total_poisha)."""
    rows = [{"member": p.get("member"), "share": to_poisha(p.get("amount"))}
            for p in parts]
    return rows, sum(r["share"] for r in rows)


# ---------------------------------------------------------------------------
# one shared expense: who paid, how it splits
# ---------------------------------------------------------------------------

def normalise_expense(exp, group_member_ids):
    """Turn a raw stored expense row into a canonical
    {'payer','total','mode','shares'} dict with exact integer shares.

    exp fields:
      payer        : member id who paid
      amount       : taka-ish total (used for equal/shares; ignored for exact)
      mode         : 'equal' | 'shares' | 'exact'  (default 'equal')
      participants : list of member ids (equal mode; default = whole group)
      parts        : [{'member','weight'}] (shares) or [{'member','amount'}] (exact)
    """
    mode = exp.get("mode", "equal")
    if mode not in SPLIT_MODES:
        mode = "equal"
    payer = exp.get("payer")
    if mode == "exact":
        shares, total = split_exact(exp.get("parts") or [])
    elif mode == "shares":
        total = to_poisha(exp.get("amount"))
        shares = split_shares(total, exp.get("parts") or [])
    else:
        total = to_poisha(exp.get("amount"))
        parts = exp.get("participants") or list(group_member_ids)
        shares = split_equal(total, parts)
    return {"payer": payer, "total": total, "mode": mode, "shares": shares}


def expense_debts(norm):
    """For a normalised expense, each participant (except the payer) owes the
    payer their share. Returns [{'from','to','amount'}]."""
    payer = norm["payer"]
    return [{"from": s["member"], "to": payer, "amount": s["share"]}
            for s in norm["shares"]
            if s["member"] != payer and s["share"] != 0]


# ---------------------------------------------------------------------------
# net balances across many expenses
# ---------------------------------------------------------------------------

def net_balances(expenses, group_member_ids):
    """Collapse many expenses into each member's NET position (poisha):
    positive = the group owes them (they overpaid); negative = they owe the
    group. Sums to EXACTLY 0 (integer poisha). Returns {member_id: poisha}
    including every group member (0 if untouched)."""
    net = defaultdict(int)
    for mid in group_member_ids:
        net[mid] += 0  # ensure present
    for exp in expenses:
        n = normalise_expense(exp, group_member_ids)
        if n["payer"] is not None:
            net[n["payer"]] += n["total"]
        for s in n["shares"]:
            net[s["member"]] -= s["share"]
    return dict(net)


def simplify_debts(expenses, group_member_ids):
    """Greedy MINIMAL-transfer settle-up. Turns net balances into the shortest
    practical list of concrete 'X pays Y ৳Z' transfers (poisha). Debtors
    (negative) matched against creditors (positive) largest-first; each step
    clears at least one person, so at most n-1 transfers. Sums reconcile exactly
    (integer poisha). Returns [{'from','to','amount'}]. This is a SUGGESTION —
    the app moves no money."""
    net = net_balances(expenses, group_member_ids)
    creditors = sorted(((m, a) for m, a in net.items() if a > 0),
                       key=lambda x: (-x[1], str(x[0])))
    debtors = sorted(((m, -a) for m, a in net.items() if a < 0),
                     key=lambda x: (-x[1], str(x[0])))
    cred = [[m, a] for m, a in creditors]
    debt = [[m, a] for m, a in debtors]
    transfers = []
    ci = di = 0
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


# ---------------------------------------------------------------------------
# the full group summary — the one function the screen calls
# ---------------------------------------------------------------------------

def group_summary(members, expenses, lang="bn"):
    """Reconcile a whole group. members: [{'id'|'name', 'name'}].

    Returns a deterministic dict:
        {
          'total_spent', 'total_spent_display',
          'members': [{'id','name','paid','share','net','net_display',
                       'state': 'owes'|'is_owed'|'clear'}],
          'settlements': [{'from','to','amount','amount_display',
                           'from_name','to_name','text':{bn,en}}],
          'reconciles': bool,
          'note': {bn,en},
        }
    """
    ids = [_mid(m) for m in members]
    name_of = {_mid(m): m.get("name", "") for m in members}
    net = net_balances(expenses, ids)

    # paid & share per member (for a transparent breakdown)
    paid = defaultdict(int)
    share = defaultdict(int)
    total_spent = 0
    for exp in expenses:
        n = normalise_expense(exp, ids)
        total_spent += n["total"]
        if n["payer"] is not None:
            paid[n["payer"]] += n["total"]
        for s in n["shares"]:
            share[s["member"]] += s["share"]

    rows = []
    for mid in ids:
        v = net.get(mid, 0)
        state = "is_owed" if v > 0 else ("owes" if v < 0 else "clear")
        rows.append({
            "id": mid,
            "name": name_of.get(mid, ""),
            "paid": paid.get(mid, 0),
            "paid_display": fmt_poisha(paid.get(mid, 0)),
            "share": share.get(mid, 0),
            "share_display": fmt_poisha(share.get(mid, 0)),
            "net": v,
            "net_display": fmt_poisha(v),
            "state": state,
        })

    settlements = []
    for tr in simplify_debts(expenses, ids):
        fn = name_of.get(tr["from"], str(tr["from"]))
        tn = name_of.get(tr["to"], str(tr["to"]))
        amt = fmt_poisha(tr["amount"])
        settlements.append({
            "from": tr["from"], "to": tr["to"], "amount": tr["amount"],
            "amount_display": amt, "from_name": fn, "to_name": tn,
            "text": {
                "bn": f"{fn} → {tn} কে দেবে {amt}",
                "en": f"{fn} pays {tn} {amt}",
            },
        })

    reconciles = (sum(net.values()) == 0)
    return {
        "total_spent": total_spent,
        "total_spent_display": fmt_poisha(total_spent),
        "members": rows,
        "settlements": settlements,
        "reconciles": reconciles,
        "note": {
            "bn": "খরচ সমানভাবে বা ভাগ অনুযায়ী ভাগ করা হয়েছে; "
                  "অ্যাপ কোনো টাকা রাখে না — এটি শুধু কে কাকে কত দেবে তা দেখায়।",
            "en": "Expenses split equally or by share; the app holds no money — "
                  "it only shows who should pay whom, to settle up yourselves.",
        },
    }


def _mid(m):
    v = m.get("id", m.get("member"))
    return v if v is not None else m.get("name")


def validate_expense(exp, group_member_ids):
    """Validation codes for an expense before it is stored."""
    problems = []
    if exp.get("payer") not in group_member_ids:
        problems.append("payer_not_in_group")
    mode = exp.get("mode", "equal")
    if mode not in SPLIT_MODES:
        problems.append("bad_mode")
    if mode in ("equal", "shares") and to_poisha(exp.get("amount")) <= 0:
        problems.append("amount_required")
    if mode == "equal":
        parts = exp.get("participants") or list(group_member_ids)
        if not parts:
            problems.append("no_participants")
    if mode == "shares":
        parts = exp.get("parts") or []
        if not parts or sum(max(0, int(p.get("weight", 0) or 0)) for p in parts) <= 0:
            problems.append("no_shares")
    if mode == "exact":
        parts = exp.get("parts") or []
        if not parts or sum(to_poisha(p.get("amount")) for p in parts) <= 0:
            problems.append("no_exact_amounts")
    return problems
