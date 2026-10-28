"""
Rule-feature runners: case["input"] -> a FLAT dict of the fields the eval
compares (runner.compare). Deterministic: every clock comes from input["now"].
No model, no network; the product functions are called exactly as the app
calls them.
"""
from datetime import datetime
from decimal import Decimal


def _now(inp):
    return datetime.fromisoformat(inp.get("now") or "2026-10-27T10:00")


def _s(v):
    if v is None:
        return None
    if isinstance(v, Decimal):
        return format(v.normalize(), "f") if v == v.to_integral_value() else str(v.normalize())
    return str(v)


# ------------------------------------------------------------ reminders
def reminders_nlp(inp):
    from ..logic import nlp_datetime as ND
    now = _now(inp)
    if inp.get("mode") == "expense":
        return {"expense_date": ND.expense_date(inp["text"], now=now).isoformat()}
    r = ND.parse(inp["text"], now=now)
    dt = r.get("datetime")
    rule = r.get("recurrence_rule") or {}
    return {
        "datetime": dt,
        "date": dt[:10] if dt else None,
        "time": dt[11:16] if dt else None,
        "date_only": r.get("date_only"),
        "freq": rule.get("freq"),
        "weekday": rule.get("weekday"),
        "day_of_month": rule.get("day_of_month"),
        "rule_time": rule.get("time"),
        "title": r.get("clean_title"),
        "past": r.get("past"),
        "needs_time": r.get("needs_time"),
    }


# ------------------------------------------------------------ home intent
def home_intent(inp):
    from .. import agent
    p = agent.parse(inp["text"], inp.get("ui_lang", "bn"))
    out = {k: p.get(k) for k in ("intent", "amount", "kind", "person", "name", "place",
                                  "place_type", "category", "title")}
    # `due` depends on the wall clock inside agent._time — compare only its
    # clock part (HH:MM), which is deterministic.
    due = p.get("due")
    out["due_time"] = due[11:16] if due else None
    return out


# ------------------------------------------------------------ money voice
def expense_parse(inp):
    from ..logic import money_parse as MP
    rows = MP.parse_money_voice(inp["text"])
    first = rows[0] if rows else {}
    return {
        "n": len(rows),
        "amount": _s(first.get("amount")),
        "txn_type": first.get("txn_type"),
        "counterparty": first.get("counterparty"),
        "parsed": first.get("parsed"),
        "amounts": [_s(r.get("amount")) for r in rows],
        "types": [r.get("txn_type") for r in rows],
    }


def money_sms(inp):
    from ..logic import money_parse as MP
    r = MP.parse_sms(inp["body"], inp.get("sender", ""))
    return {k: _s(r.get(k)) if k in ("amount", "fee", "balance") else r.get(k)
            for k in ("channel", "type", "amount", "fee", "balance", "ref",
                      "counterparty_number", "date", "parsed")}


# ------------------------------------------------------------ voice
def voice_commands(inp):
    from ..logic import voice_commands as VC
    r = VC.map_command(inp["text"], now=_now(inp)) or {}
    args = r.get("args") or {}
    when = args.get("when") or {}
    dt = when.get("datetime")
    return {
        "intent": r.get("intent"),
        "route": r.get("route"),
        "name": args.get("name"),
        "amount": args.get("amount"),
        "date": (dt or "")[:10] or args.get("date"),
        "time": (dt or "")[11:16] or None,
        "confirm": r.get("confirm"),
    }


# ------------------------------------------------------------ sales rules
def bizagent_rules(inp):
    from ..logic import bizagent_rules as BR
    from ..logic import bizagent as BZ
    r = BR.answer(inp["text"], inp["ctx"]) or {}
    text = BZ.norm_digits(r.get("text") or "").replace(",", "")
    mins = [str(m) for m in inp.get("min_prices") or []]
    return {
        "rule": r.get("rule"),
        "text": text,
        "min_leak": any(m in text for m in mins),
        "product_id": r.get("product_id"),
    }


def bargaining(inp):
    from ..logic import business_ai as BAI
    from ..logic import bizagent as BZ
    if inp.get("mode") == "offer":
        return {"offer": _s(BZ.find_offer(inp["text"], inp.get("list_price")))}
    r = BAI.negotiate(inp["offer"], inp["product"], inp.get("rules"),
                      lang=inp.get("ui_lang", "bn"))
    mn = Decimal(str(inp["product"].get("min_price") or inp["product"]["price"]))
    price = r.get("price")
    return {
        "action": r.get("action"),
        "price": _s(price),
        "below_min": (price is not None and price < min(mn, Decimal(str(inp["product"]["price"])))),
        "owner_notified": r.get("owner_notification") is not None,
    }


def order_capture(inp):
    from ..logic import bizagent as BZ
    d = BZ.extract_order(inp["text"], inp.get("draft") or {}, inp["catalog"])
    return {k: d.get(k) for k in ("product", "qty", "phone", "area", "name", "address",
                                  "phone_invalid", "variant_label")}


def contract_analyzer(inp):
    from ..logic import contract_analyzer as CA
    r = CA.analyze(inp["text"])
    return {"kinds": sorted(r["clause_kinds"]), "high": r["counts"]["high"],
            "problems": r.get("problems") or [], "disclaimer": r.get("disclaimer")}


def crm_extract(inp):
    from crm.views import extract_contact
    return extract_contact(inp["text"])


# ------------------------------------------------------------ AF-2 / AF-4 / AF-10 trust
def sales_pii_mask(inp):
    """AF-2: the sales agent's provider request goes through the SAME masking
    ai.generate(pii=True) applies; nothing raw may remain, every value comes
    back on unmask (also when the provider answers in Bangla digits)."""
    from .. import ai
    from ..agentcore import trust as T
    hist = inp.get("history") or None
    vault, task, data, history, extra = ai.mask_for_provider(
        inp.get("task", ""), inp.get("data", ""), hist, "", True)
    sent = "\n".join([task or "", data or ""] + [h.get("content", "") for h in history or []])
    back = vault.unmask(data or "")
    bn = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
    return {
        "raw_pii": T.has_raw_pii(sent),
        "tokens": len(vault.t2v),
        "kinds": ",".join(sorted({t.split("_")[0].strip("⟦") for t in vault.t2v})),
        "roundtrip": back == inp.get("data", ""),
        "bn_digit_tokens_ok": all(vault.unmask(t.translate(bn)) == v for t, v in vault.t2v.items()),
    }


def toxicity(inp):
    """AF-4: the deterministic abuse / hate / threat / sexual guard."""
    from .. import ai_guard as G
    r = G.toxicity(inp["text"])
    return {"toxic": r["toxic"], "category": r["category"], "severity": r["severity"]}


def handoff_card(inp):
    """AF-10: the rule-made seller handoff summary."""
    import re
    from ..agentcore import trust as T
    from ..logic import bizagent_handoff as HC
    c = HC.build(inp["messages"], inp.get("catalog") or [], inp.get("draft") or {},
                 inp.get("reason", ""))
    bn, en = c["lines"]["bn"], c["lines"]["en"]
    return {
        "want": c["want"], "sentiment": c["sentiment"], "reason": c["reason"],
        "lines": len(bn) == 3 and len(en) == 3 and all(x.strip() for x in bn + en),
        "raw_pii": T.has_raw_pii("\n".join(bn + en)),
        "bn_ascii_digits": bool(re.search(r"[0-9]", "\n".join(bn))),
        "en_bn_digits": bool(re.search(r"[০-৯]", "\n".join(en))),
        "items": " | ".join(i["name"] for i in c["items"]),
        "quoted": bool(c["last_question"]),
    }


RUNNERS = {
    "reminders_nlp": reminders_nlp,
    "home_intent": home_intent,
    "expense_parse": expense_parse,
    "money_sms": money_sms,
    "voice_commands": voice_commands,
    "bizagent_rules": bizagent_rules,
    "bargaining": bargaining,
    "order_capture": order_capture,
    "contract_analyzer": contract_analyzer,
    "crm_extract": crm_extract,
    "sales_pii_mask": sales_pii_mask,
    "toxicity": toxicity,
    "handoff_card": handoff_card,
}
