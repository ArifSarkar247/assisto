"""bizops: the business agent's NO-AI paths and the morning business card.

1. Deterministic answers (0 credits, no LLM): the shop owner's everyday
   questions ("আজ কত লাভ?", "কার কাছে সবচেয়ে বেশি বাকি?", "কোন পণ্য শেষ
   হচ্ছে?", "ক্যাশ মিলছে?") are matched by keyword to ONE read tool. Used
   when the AI is not configured (no key) and for the card's question chips,
   so the agent answers honestly without a key and no number is ever free
   text: the answer is the tool's own template.

2. Pre-planned runs: a card tap (tagada / supplier reorder / follow-up / a
   question chip) becomes a normal Agent Core run whose plan is fixed in code
   (a 'plan' step with credits 0 + the tool steps). Everything after that is
   the runner's own path: allow-list, schema, AF-5 exfil + own-recipient
   precheck, the approval card + push for external tools, rate limits, audit.
   Nothing that leaves the app runs without the owner's tap.

3. The card: GET agent-core/biz-brief -> biz.daily_brief + lines + the
   one-tap actions + the cost math (40% rule) shown on the card.
"""
import re

from django.db import transaction
from django.utils import timezone

from . import tools as TL
from . import topics as TP
from . import trust as T

TOPIC = "business"

# --------------------------------------------------------------- intents
_ACTION = re.compile(r"পাঠা|send|দাও|দিয়ে দিন|করো|করুন|বানাও|বানান|remind|create|make|\bset\b|"
                     r"order (?:from|to)|pathao|pathan|dao\b|koro\b|banao", re.I)
_INTENTS = (
    # (tool, regex, args)
    ("biz.cash_check", re.compile(r"(ক্যাশ|cash|নগদ|ক্যাশবাক্স).*(মিল|গরমিল|match|kom|কম|বেশি|ঠিক)|"
                                  r"(মিল|গরমিল|match).*(ক্যাশ|cash)", re.I), None),
    ("biz.daily_brief", re.compile(r"আজকের ব্যবসা|ব্যবসার (?:সারাংশ|খবর|অবস্থা)|business (?:brief|summary)|"
                                   r"how(?:'s| is) (?:my )?(?:shop|business)|dokan(?:er)? (?:obostha|khobor)|"
                                   r"দোকানের (?:অবস্থা|খবর)", re.I), {}),
    ("biz.profit", re.compile(r"লাভ|মুনাফা|profit|labh|lav\b|বিক্রি কত|কত বিক্রি|sales today|"
                              r"how much (?:did i )?(?:sell|sold)|koto bikri|bikri koto", re.I), "period"),
    ("khata.dues", re.compile(r"(কার|কে|কাদের|who|kar|kader).*(বাকি|due|owe|baki)|"
                              r"(বাকি|baki|due).*(সবচেয়ে|বেশি|most|top|beshi)", re.I), {"limit": 5}),
    ("stock.running_out", re.compile(r"শেষ হ(?:চ্ছে|য়ে|বে)|ফুরি|running out|run out|sesh hocche|"
                                     r"(কোন|কী|কি|which|what|kon).*(পণ্য|মাল|product|item|stock|স্টক).*"
                                     r"(কম|শেষ|low|out|kom|sesh)|reorder|আবার আনতে", re.I), {"limit": 10}),
)
_PERIOD = (("yesterday", re.compile(r"গতকাল|কাল(?!কে)|yesterday|gotokal|\bkal\b", re.I)),
           ("week", re.compile(r"সপ্তাহ|৭ দিন|week|soptah", re.I)),
           ("month", re.compile(r"মাসে|এই মাস|month|mash|mase", re.I)))


def match_intent(text):
    """-> (tool, args) for an everyday business QUESTION, else None. A goal
    that asks to DO something (send / remind / order / create) is never
    matched here — it goes to the planner (or the card's own buttons)."""
    t = (text or "").strip()
    if not t or len(t) > 200 or _ACTION.search(t):
        return None
    for tool, rx, args in _INTENTS:
        if rx.search(t):
            if args == "period":
                per = "today"
                for k, prx in _PERIOD:
                    if prx.search(t):
                        per = k
                        break
                return tool, {"period": per}
            if args is None:
                return tool, {"day": "today" if re.search(r"আজ|today|\baj\b", t, re.I) else "yesterday"}
            return tool, dict(args)
    return None


def ai_ready():
    """False when no AI provider is configured (or the daily cap is hit) and
    the production planner is in use — then the business agent answers its
    everyday questions from the tools alone."""
    from . import planner as PL
    if PL._OVERRIDE is not None:          # tests / evals bring their own planner
        return True
    try:
        from .. import ai
        return bool(ai.available())
    except Exception:  # noqa: BLE001
        return False


# --------------------------------------------------------------- pre-planned runs
def no_ai_route(run, text, pair, channel, play):
    """runner.start hook: with no AI configured, an everyday business question
    is answered by ONE read tool (0 credits) instead of failing 'ai_no_key'.
    Returns True when the run got a code-fixed plan."""
    if channel == "eval" or (pair and TOPIC not in pair) or ai_ready():
        return False
    hit = match_intent(text)
    if hit is None:
        return False
    steps = [{"tool": hit[0], "args": hit[1]}]
    try:
        check_steps(run.user, steps, play)
    except ValueError:
        return False
    if not pair:
        run.topic = TOPIC
        run.save(update_fields=["topic", "updated_at"])
        run.goal.topic = TOPIC
        run.goal.save(update_fields=["topic"])
        run._topics = [TOPIC]
    preplan(run, steps, "no_ai")
    return True


def preplan(run, steps, reason):
    """Attach a code-fixed plan to a fresh run: a done 'plan' step (0 credits,
    no LLM) + one tool step per entry. The runner then executes them exactly
    like planner steps (approvals, prechecks, audit)."""
    from ..models import AgentStep
    vault = T.vault_of(run)
    plan = {"v": 1, "steps": steps, "done": True, "answer": None, "pre": reason}
    with transaction.atomic():
        p = AgentStep.objects.create(run=run, no=1, kind="plan", idem_key="ac:%d:1" % run.pk,
                                     state="done", credits=0, cost_usd=0,
                                     result_sealed=T.seal({"plan": plan}),
                                     summary=(", ".join(s["tool"] for s in steps))[:400],
                                     finished_at=timezone.now())
        for i, s in enumerate(steps):
            t = TL.get(s["tool"])
            n = 2 + i
            AgentStep.objects.create(run=run, no=n, kind="tool", tool=t.name, tool_version=t.version,
                                     risk=t.risk, idem_key="ac:%d:%d" % (run.pk, n),
                                     args_sealed=T.seal({"a": vault.mask_obj(s["args"])}),
                                     summary=vault.mask(t.label_en)[:400])
        T.save_vault(run, vault)
        run.save(update_fields=["vault_sealed", "updated_at"])
        T.audit(run, "plan.ok", step=p, credits=0, tools=[s["tool"] for s in steps], done=True,
                preplanned=reason)


def check_steps(user, steps, play=False):
    """Code-fixed steps obey the same allow-list + schema + flag as a planner
    plan. Raises ValueError(code)."""
    from .contract import SchemaError, validate
    from .runner import Ctx
    ctx = Ctx(user=user, now=timezone.now(), play=play)
    allowed = {t.name for t in TL.available(ctx, TP.get(TOPIC)["tools"])}
    for s in steps:
        if s["tool"] not in allowed:
            raise ValueError("tool_not_allowed")
        try:
            validate(s["args"], TL.get(s["tool"]).input_schema)
        except SchemaError:
            raise ValueError("bad_input")


def start_action(user, text, steps, lang="bn", play=False, client_id="", now=None):
    """A card tap -> a pre-planned business run (channel 'widget', 0 credits).
    Not counted against the daily AI-run cap (no AI call); each tool keeps its
    own hourly rate limit and every external step still waits for approval."""
    from ..models import AgentGoal, AgentRun
    from . import runner as RN
    check_steps(user, steps, play)
    client_id = (client_id or "")[:64]
    if client_id:
        g = AgentGoal.objects.filter(user=user, client_id=client_id).first()
        if g is not None:
            return g.runs.order_by("-id").first()
    now = now or timezone.now()
    lim = RN.limits_for(user)
    vault = T.Vault()
    masked = vault.mask(text)
    with transaction.atomic():
        goal = AgentGoal.objects.create(user=user, topic=TOPIC, channel="widget",
                                        text_sealed=T.seal({"t": text}), text_masked=masked[:600],
                                        client_id=client_id)
        run = AgentRun(goal=goal, user=user, topic=TOPIC, max_steps=lim["steps"],
                       max_llm_calls=RN.MAX_LLM_CALLS, max_credits=lim["credits"],
                       deadline_at=now + RN.RUN_TTL)
        T.save_vault(run, vault)
        run.save()
        T.audit(run, "run.created", topic=TOPIC, channel="widget", goal=masked[:300])
    run._topics = [TOPIC]
    preplan(run, steps, "card")
    RN.advance(run, lang=lang, play=play)
    run.refresh_from_db()
    return run


# --------------------------------------------------------------- the card
def _price(action):
    """(credits, credit ৳ face, provider ৳ cost, margin %) from the live
    pricing config — the card shows this math (owner's 40% rule)."""
    from .. import billing
    from ..logic import pricing
    cfg = pricing.normalize(billing.cfg())
    row = cfg["action_costs"].get(action) or {}
    credits = int(row.get("credits") or 0)
    face = round(credits * cfg["credit_bdt"], 2)
    cost = round(float(row.get("provider_cost") or 0) * cfg["usd_bdt"], 2)
    margin = int(round((face - cost) * 100.0 / face)) if face else 0
    return {"credits": credits, "price_bdt": face, "cost_bdt": cost, "margin_pct": margin,
            "ok": face == 0 or margin >= 40}


def cost_block(lang):
    plan, sms = _price("agent_plan"), _price("sms")
    from .tools import _cnt, _pick, _tk

    def ln(p, bn_what, en_what):
        # launchsweep: the customer sees the price only; our cost and margin
        # (40 % rule) stay in the dict for Owner Admin / tests, never on screen.
        return _pick(lang, "%s: %s ক্রেডিট (%s)" % (
            bn_what, _cnt(p["credits"], lang), _tk(p["price_bdt"], lang)),
            "%s: %d credit%s (%s)" % (en_what, p["credits"], "" if p["credits"] == 1 else "s",
                                     _tk(p["price_bdt"], "en")))
    lines = [_pick(lang, "এই কার্ড: AI ডাকা হয়নি — ০ ক্রেডিট, খরচ ৳০ (সব সংখ্যা আপনার খাতা থেকে)",
                   "This card: no AI call — 0 credits, ৳0 cost (every number from your books)"),
             ln(plan, "নিজের ভাষায় প্রশ্ন (AI)", "A free-text question (AI)"),
             ln(sms, "SMS তাগাদা (প্রতি SMS)", "SMS due reminder (per SMS)")]
    return {"card_credits": 0, "plan": plan, "sms": sms, "rule_ok": plan["ok"] and sms["ok"],
            "lines": lines}


QUESTIONS = (
    # key, bn, en, tool, args
    ("profit_today", "আজ কত লাভ?", "Today's profit?", "biz.profit", {"period": "today"}),
    ("top_due", "কার কাছে সবচেয়ে বেশি বাকি?", "Who owes me the most?", "khata.dues", {"limit": 5}),
    ("running_out", "কোন পণ্য শেষ হচ্ছে?", "What is running out?", "stock.running_out", {"limit": 10}),
    ("cash", "কাল ক্যাশ মিলেছে?", "Did yesterday's cash match?", "biz.cash_check", {"day": "yesterday"}),
    ("profit_week", "এই সপ্তাহে কত লাভ?", "Profit this week?", "biz.profit", {"period": "week"}),
)


def card(user, lang, play=False, now=None):
    from .runner import Ctx
    from . import tools_bizops as BO
    ctx = Ctx(user=user, now=now or timezone.now(), lang=lang, play=play)
    o = BO.daily_brief(ctx, {})
    lines = [{"key": k, "text": t} for k, t in BO.brief_lines(o, lang)]
    from .tools import _cnt, _pick, _tk
    acts = []
    for a in o["actions"]:
        if a["kind"] == "tagada":
            due = next((i["due"] for i in o["dues"]["items"] if i["name"] == a["target"]), 0)
            label = _pick(lang, "%s-কে তাগাদা (%s)" % (a["target"], _tk(due, lang)),
                          "Remind %s (%s)" % (a["target"], _tk(due, lang)))
        elif a["kind"] == "reorder":
            label = _pick(lang, "সাপ্লায়ারকে অর্ডার (%sটি পণ্য)" % _cnt(len(a["args"]["items"]), lang),
                          "Reorder from a supplier (%d products)" % len(a["args"]["items"]))
        else:
            label = _pick(lang, "%s — ফলো-আপ টাস্ক" % a["target"], "%s — follow-up task" % a["target"])
        acts.append(dict(a, label=label))
    return {"date": o["date"], "has_business": o["has_business"], "shop": o["shop"],
            "empty": o["empty"], "lines": lines, "actions": acts,
            "suppliers": BO.suppliers(ctx), "ai_ready": ai_ready(),
            "questions": [{"key": k, "text": _pick(lang, bn, en)} for k, bn, en, _t, _a in QUESTIONS],
            "numbers": {"yesterday": o["yesterday"], "dues": o["dues"], "stock": o["stock"],
                        "followups": o["followups"], "cash": o["cash"],
                        "unpaid_orders": o["unpaid_orders"]},
            "cost": cost_block(lang), "ai_used": False, "credits": 0}


def action_steps(kind, b):
    """The card's tap -> (goal text, steps). Raises ValueError('bad_input')."""
    if kind == "question":
        q = next((q for q in QUESTIONS if q[0] == b.get("key")), None)
        if q is None:
            raise ValueError("bad_input")
        return q[1], [{"tool": q[3], "args": dict(q[4])}]
    if kind == "tagada":
        args = {"customer": str(b.get("customer") or "")[:120],
                "channel": "sms" if b.get("channel") == "sms" else "whatsapp"}
        return "%s-কে তাগাদা" % args["customer"], [{"tool": "khata.tagada", "args": args}]
    if kind == "reorder":
        items = [{"product": str(i.get("product") or "")[:160], "qty": int(i.get("qty") or 1)}
                 for i in (b.get("items") or [])[:15] if isinstance(i, dict)]
        args = {"supplier": str(b.get("supplier") or "")[:120]}
        if items:
            args["items"] = items
        return "%s-কে অর্ডারের খসড়া" % args["supplier"], [{"tool": "supplier.reorder", "args": args}]
    if kind == "followup":
        args = {"lead": str(b.get("lead") or "")[:160], "when": str(b.get("when") or "today")[:10]}
        return "%s — ফলো-আপ টাস্ক" % args["lead"], [{"tool": "crm.followup_task", "args": args}]
    raise ValueError("bad_input")


# --------------------------------------------------------------- pre-planned endings
_FAIL = {
    "supplier_not_found": ("এই নামে আপনার সাপ্লায়ার খাতায় কেউ নেই — আগে সাপ্লায়ার যোগ করুন।",
                           "No supplier with this name in your supplier book — add the supplier first."),
    "supplier_required": ("কোন সাপ্লায়ারকে পাঠাবেন, বেছে নিন।", "Choose the supplier first."),
    "ambiguous_supplier": ("এই নামে একাধিক সাপ্লায়ার — খাতায় নাম আলাদা করুন।",
                           "More than one supplier has this name — make the names different."),
    "product_not_found": ("একটি পণ্য আপনার ক্যাটালগে নেই।", "A product is not in your catalog."),
    "ambiguous_product": ("একই নামে একাধিক পণ্য — ক্যাটালগে নাম আলাদা করুন।",
                          "Two products share a name — make the names different in the catalog."),
    "nothing_to_reorder": ("এখন আনার মতো কোনো পণ্য নেই।", "Nothing needs reordering now."),
    "customer_not_found": ("এই নামে খাতায় কোনো গ্রাহক নেই।", "No customer with this name in your ledger."),
    "ambiguous_customer": ("একই নামে একাধিক গ্রাহক — খাতা থেকে সরাসরি তাগাদা দিন।",
                           "More than one customer has this name — send the reminder from the ledger."),
    "lead_not_found": ("এই নামে আপনার CRM-এ কোনো লিড নেই।", "No lead with this name in your CRM."),
    "ambiguous_lead": ("একই নামে একাধিক লিড — CRM থেকে টাস্ক দিন।",
                       "More than one lead has this name — add the task from the CRM."),
    "no_crm": ("আপনার CRM চালু নেই।", "You do not have a CRM yet."),
    "no_business": ("আপনার কোনো ব্যবসার খাতা নেই।", "You have no business ledger yet."),
    "rate_limited": ("এক ঘণ্টায় অনেকবার হয়েছে — একটু পরে আবার চেষ্টা করুন।",
                     "Done too often this hour — try again a little later."),
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
}


def failed_code(tool_steps):
    for s in tool_steps:
        if s.state == "failed":
            return (s.error_code or "failed")[:40]
    return ""


def pre_answer(run, tool_steps, lang):
    from . import runner as RN
    from .tools import _pick
    lines = [RN._template_answer(run, [s for s in tool_steps if s.state != "failed"], lang)]
    for s in tool_steps:
        if s.state == "failed":
            bn, en = _FAIL.get(s.error_code, ("কাজটি করা যায়নি — কিছু পাঠানো হয়নি।",
                                              "This could not be done — nothing was sent."))
            lines.append(_pick(lang, bn, en))
    return "\n".join(ln for ln in lines if ln)
