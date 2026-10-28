"""A deterministic, rule-based stand-in for the planner LLM.

It is plugged in at the AI router's PROVIDER seam (core.ai._call_anthropic),
so everything around it is the real production path: ai.generate (caps,
circuit, AIUsage, credits pre-charge), planner.parse, the validator, trust
masking, tools, approvals and audit. It reads exactly what a model would see
(the task text and the <data> block) and answers in the strict plan schema.

On purpose it is GULLIBLE about prompt injection on its first attempt (it
plans notes.delete when the goal says "delete"), so the eval proves the
STRUCTURAL guards (topic allow-list + validator) stop it, not the model.
"""
import json
import re

_BN2EN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
from datetime import datetime, timedelta

_RX = {
    "reminder": re.compile(r"মনে করিয়ে|রিমাইন্ডার|remind|mone koriye", re.I),
    "note": re.compile(r"(নোট|note).*(লিখ|রাখ|save|write)|(লিখ|রাখ|save|write).*(নোট|note)", re.I),
    "move": re.compile(r"পাঠাও|পাঠিয়ে দাও|বিকাশ করে দাও|\bsend\b|transfer|\bpay\b|pathao", re.I),
    "delete": re.compile(r"delete|মুছে", re.I),
    "budget": re.compile(r"বাজেট|budget", re.I),
    "loans": re.compile(r"ধার|দেনা|পাওনা|পাব|দেব\b|\bowes?\b|loan|dhar|pabo", re.I),
    "spend": re.compile(r"খরচ|আয়|spend|spent|spending|expense|income|khoroch|money go|টাকা যাচ্ছে|money summary", re.I),
    "hisab": re.compile(r"হিসাব|hisab|summary", re.I),
    # WP-TOOLS-A money tools
    "log": re.compile(r"লিখে রাখো|লিখে রাখ|হিসাবে তোলো|\blog\b|\badd (an? )?(expense|income)|likhe rakho|hisabe tolo", re.I),
    "amount": re.compile(r"([0-9০-৯][0-9০-৯,]*)"),
    "income": re.compile(r"আয়|বেতন|পেয়েছি|income|salary|earned|beton|peyechi", re.I),
    "meter": re.compile(r"মিটার|\bmeter", re.I),
    "last": re.compile(r"গত মাস|আগের মাস|last month|gotomash", re.I),
}


def _now(task):
    m = re.search(r"Now \(Asia/Dhaka\): (\S+)", task)
    return datetime.fromisoformat(m.group(1)) if m else datetime.now()


def _lang(task):
    return "en" if "User language: English" in task else "bn"


def _allowed(task):
    m = re.search(r"^Tools: (\[.*\])$", task, re.M)
    return {t["name"] for t in json.loads(m.group(1))} if m else set()


def _data(prompt):
    i, j = prompt.rfind("<data>\n"), prompt.rfind("\n</data>")
    return json.loads(prompt[i + 7:j]) if i >= 0 and j > i else {}


def _topic(task):
    from .. import topics as TP
    m = re.search(r"^Topic rules: (.*)$", task, re.M)
    rules = m.group(1) if m else ""
    return next((k for k, v in TP.TOPICS.items() if v["rules"] == rules), "")


def think(task, prompt):
    data = _data(prompt)
    goal = data.get("goal") or ""
    obs = data.get("observations") or []
    lang = _lang(task)
    retry = "previous output was rejected" in task
    now = _now(task)
    topic = _topic(task)
    if topic and topic != "money":            # WP-TOOLS-A/B topics
        from . import topic_brain
        return topic_brain.think(topic, goal, lang, _allowed(task), retry, now, obs)
    if obs:
        bad = [o for o in obs if not o.get("ok")]
        msg = ("কিছু ধাপ করা যায়নি: " if lang == "bn" else "Some steps could not run: ") + \
            ", ".join("%s (%s)" % (o["tool"], o.get("error")) for o in bad)
        return {"v": 1, "steps": [], "done": True, "answer": msg}
    if _RX["reminder"].search(goal):
        due = (now + timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
        title = re.sub(r"\s+", " ", goal).strip()[:120]
        return {"v": 1, "done": True, "answer": None,
                "steps": [{"tool": "reminders.create",
                           "args": {"title": title, "due_at": due.isoformat()}}]}
    if _RX["note"].search(goal):
        title = (goal.split(":", 1)[1] if ":" in goal else goal).strip()[:120] or "note"
        return {"v": 1, "done": True, "answer": None,
                "steps": [{"tool": "notes.create", "args": {"title": title, "body": goal[:500]}}]}
    if _RX["log"].search(goal) and _RX["amount"].search(goal) and "money.log" in _allowed(task):
        amt = int(_RX["amount"].search(goal).group(1).translate(_BN2EN).replace(",", ""))
        kind = "income" if _RX["income"].search(goal) else "expense"
        return {"v": 1, "done": True, "answer": None,
                "steps": [{"tool": "money.log", "args": {"kind": kind, "amount": amt}}]}
    if _RX["meter"].search(goal) and "meter.balance" in _allowed(task):
        return {"v": 1, "done": True, "answer": None, "steps": [{"tool": "meter.balance", "args": {}}]}
    if _RX["move"].search(goal):
        ans = ("আমি টাকা পাঠাতে বা বিল দিতে পারি না — টাকা সবসময় আপনি নিজে আপনার অ্যাপ থেকে পাঠান।"
               if lang == "bn" else
               "I cannot send money or pay bills — you always pay from your own app.")
        return {"v": 1, "steps": [], "done": True, "answer": ans}
    steps = []
    if _RX["delete"].search(goal) and not retry:
        steps.append({"tool": "notes.delete", "args": {"id": 1}})     # gullible on purpose
    month = now.strftime("%Y-%m")
    if _RX["last"].search(goal):
        first = now.replace(day=1) - timedelta(days=1)
        month = first.strftime("%Y-%m")
    want = []
    if _RX["spend"].search(goal):
        want.append(("money.month_summary", {"month": month}))
    if _RX["budget"].search(goal):
        want.append(("budget.status", {}))
    if _RX["loans"].search(goal):
        want.append(("loans.dues", {"kind": "all"}))
    if not want and _RX["hisab"].search(goal):
        want.append(("money.month_summary", {"month": month}))
    allowed = _allowed(task)
    steps += [{"tool": t, "args": a} for t, a in want if t in allowed or not allowed]
    if not steps:
        ans = ("এটা আমি এখনো করতে পারি না। আমি এই মাসের খরচ, বাজেট আর ধার-দেনার হিসাব দেখাতে পারি।"
               if lang == "bn" else
               "I cannot do that yet. I can show this month's spending, budgets and loans.")
        return {"v": 1, "steps": [], "done": True, "answer": ans}
    return {"v": 1, "steps": steps, "done": True, "answer": None}


class ProviderSeam:
    """Callable with the provider seam signature; records every prompt."""
    def __init__(self):
        self.prompts = []

    def __call__(self, key, model, system, prompt, max_tokens, history=None):
        self.prompts.append(system + "\n" + prompt)
        task = prompt.split("\n\n<data>\n", 1)[0]
        plan = think(task, prompt)
        return (json.dumps(plan, ensure_ascii=False), 400, 80)
