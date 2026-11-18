"""aiqual (owner 9 Nov 21:20, full power item 7): the AI exam OFFLINE — CI
only, no key, no network, no live data.

Every exam case (core/ai_evals/ai_exam.jsonl) runs through the SAME product
path as the nightly live exam (ai_exam.product_answer: the chat's instruction
builder, date line, answer level, router, web rule, charging, post-processing,
Continue), but the providers are fakes that replay a recorded raw model
output (core/ai_evals/recorded/ai_exam_replay.jsonl). Three things are scored
per case:

  * contract — the EXACT request the product sends: Claude Haiku for Normal /
    Better and Claude Sonnet for Best while Gemini is off (no Gemini call at
    all), the level's output cap, web search only when the chat would use it
    (+ the web note), the reply-language instruction that matches the user's
    message (romanized Bangla -> Bangla), the honest identity line while
    Gemini is off, today's date, general-info rules + safe mode for minors,
    the action (confirm card) rule, the format + length-budget rules, the
    photo context, and a correct Continue request (the cut answer as the
    user saw it + the Continue instruction, no web, nobody charged).
  * answer — ai_exam.grade on what the user would SEE (language / script,
    length, never cut mid-sentence, Continue without repeats, no tables,
    Bangla digits, refusals, safety + consult lines, internal words, facts,
    confirm cards incl. the reminder date).
  * credits — the level's credits, +web credits ONLY when a search ran,
    nothing for a Continue.

The recorded outputs are written to look like real Claude Haiku / Sonnet
answers INCLUDING their usual faults (a comparison as a table, ASCII digits
in Bangla, a long answer cut mid-word at the output cap, an identity slip,
an internal word). A fault the product must fix is a fault the product must
keep fixing — that is the regression net. Two outputs depend on the request,
as a real model's would: a reply in English when the request told the model
to reply in English (`text_en`), and a reminder date that is right only
when the request carried today's date ({due:+1d 09:00}).

Refuses to run outside a test database (it rewrites the pricing row and the
Gemini breaker of the database it runs on)."""
import json
import os
import re
from contextlib import ExitStack
from datetime import timedelta
from unittest import mock

from django.utils import timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPLAY = os.path.join(HERE, "ai_evals", "recorded", "ai_exam_replay.jsonl")
# what a model that was never told the date writes for "tomorrow"
STALE_GUESS = "2024-06-13"
WANT_MODEL = {"normal": "claude-haiku-5-5", "better": "claude-haiku-5-5",
              "best": "claude-sonnet-5-5"}
_DUE = re.compile(r"\{due:\+(\d+)d (\d\d:\d\d)\}")
_NOW = re.compile(r"Now: (\d{4}-\d\d-\d\d)")


def load_replay():
    with open(REPLAY, encoding="utf-8") as f:
        rows = [json.loads(l) for l in f if l.strip()]
    return {r["id"]: r for r in rows}


def _test_db():
    from django.db import connection
    name = str(connection.settings_dict.get("NAME") or "")
    return ":memory:" in name or "memorydb" in name or name.startswith("test")


class FakeModels:
    """The provider seams. Anthropic replays the case's recorded output;
    Gemini / OpenAI must never be called while Gemini is off."""

    def __init__(self, replay):
        self.replay = replay
        self.case_id = ""
        self.calls = []
        self.banned = []

    def anthropic(self, key, model, system, prompt, max_tokens, history=None):
        from . import ai
        o = ai._opts()
        mine = [c for c in self.calls if c["case"] == self.case_id]
        call = {"case": self.case_id, "model": model, "system": system, "prompt": prompt,
                "history": [dict(h) for h in (history or [])], "max_tokens": int(max_tokens),
                "web": bool(o.get("web"))}
        self.calls.append(call)
        rec = self.replay.get(self.case_id) or {}
        if mine:                                   # the Continue call
            text, trunc, web = rec.get("cont") or "", False, False
        else:
            text = rec.get("text") or ""
            if rec.get("text_en") and "Reply in English" in system:
                text = rec["text_en"]               # the request said English
            trunc = bool(rec.get("truncated"))
            web = bool(rec.get("web_ran")) and call["web"]
        m = _NOW.search(prompt or "")

        def due(mm):
            if not m:
                return STALE_GUESS + "T" + mm.group(2)
            from datetime import date
            d = date.fromisoformat(m.group(1)) + timedelta(days=int(mm.group(1)))
            return d.isoformat() + "T" + mm.group(2)
        text = _DUE.sub(due, text)
        return text, 900 + len(prompt or "") // 4, max(1, len(text) // 3), {
            "truncated": trunc, "web_ran": web, "model": model}

    def banned_call(self, name):
        def fn(*a, **kw):
            self.banned.append((self.case_id, name))
            from . import ai
            raise ai.ProviderError("server")
        return fn


def contract(case, calls, now, banned=(), crisis=False):
    """Fails of the request(s) the product sent for one case."""
    from . import ai_exam as AE
    from . import ai_levels_service as ALS
    from . import views_chat as VC
    e = case.get("expect") or {}
    lvl = AE.level_of(case)
    fails = []
    if banned:
        fails.append("router_not_claude")
    if crisis:
        # a crisis is answered by the fixed safety line, never by a model
        return fails + (["crisis_called_model"] if calls else [])
    if not calls:
        return fails + ["no_call"]
    first = calls[0]
    sysm, prompt = first["system"], first["prompt"]
    if first["model"] != WANT_MODEL[lvl]:
        fails.append("router_model")
    if first["max_tokens"] != int((ALS.spec(lvl) or {}).get("out_cap") or 0):
        fails.append("out_cap")
    if first["web"] != bool(e.get("web", False)):
        fails.append("web_flag")
    if e.get("web") and "Web search is on" not in sysm:
        fails.append("web_note")
    want_task = VC.CHAT_TASK[1 if e.get("answer_lang") == "en" else 0]
    if want_task not in sysm:
        fails.append("lang_directive")
    if e.get("target_script") and not ("another language" in sysm and (
            "অন্য ভাষায়" in sysm or "write that text in that language" in sysm)):
        fails.append("translate_rule")
    if "right now your answers come from Anthropic's Claude models" not in sysm:
        fails.append("identity_line")
    if "Now: " + timezone.localtime(now).date().isoformat() not in prompt:
        fails.append("date_line")
    if ("SAFE MODE" in sysm) != bool(e.get("minor")):
        fails.append("safe_mode")
    if "general information only" not in sysm:
        fails.append("general_rule")
    if "ACTION:" not in sysm:
        fails.append("action_rule")
    if "NEVER a table" not in sysm:
        fails.append("format_rule")
    if "Length budget" not in sysm:
        fails.append("length_budget")
    photo = next((h.get("photo_text") for h in case.get("history") or [] if h.get("photo_text")), "")
    if photo and (photo not in prompt or not any(n in sysm for n in VC.PHOTO_NOTE)):
        fails.append("photo_context")
    rest = calls[1:]
    if rest:
        c2 = rest[0]
        hist = c2["history"]
        if not hist or hist[-1].get("role") != "assistant" or not hist[-1].get("content"):
            fails.append("continue_history")
        if not any(n in c2["system"] for n in VC.CONTINUE_NOTE):
            fails.append("continue_note")
        if c2["web"]:
            fails.append("continue_web")
        if c2["model"] != WANT_MODEL[lvl]:
            fails.append("router_model")
    return fails


def setup_live_like():
    """The live setup of 9 Nov: pricing_v2 settings applied (Normal = Haiku,
    Better saved as Gemini Flash, Best = Sonnet, web search on, +3 credits a
    search) and the Gemini breaker OPEN (402) — so Better runs as its Claude
    twin. Test databases only."""
    if not _test_db():
        raise RuntimeError("ai_exam_offline runs on a test database only")
    from django.core.cache import cache
    from . import billing
    from . import gemini_breaker as GB
    from .logic import plan_book as BOOK, pricing as P
    row = billing.get_config()
    d = dict(P.normalize(row.data))
    for k, v in BOOK.v2_settings_patch().items():
        d[k] = BOOK.deep_merge(d.get(k) or {}, v) if isinstance(v, dict) else v
    row.data = d
    row.save()
    cache.clear()
    GB.trip("http_402", "prepayment credits are depleted")


def run(now=None, cases=None, replay=None):
    """Score every case offline -> scorecard dict. Call inside a test.
    aichat-nine: `replay` ({id: recorded output}) for another case set (the
    answer-quality eval); each row also carries what the user saw."""
    if not _test_db():
        raise RuntimeError("ai_exam_offline runs on a test database only")
    from django.contrib.auth import get_user_model
    from . import ai
    from . import ai_exam as AE
    now = now or timezone.now()
    cases = cases if cases is not None else AE.load_cases()
    fake = FakeModels(replay if replay is not None else load_replay())
    ledger = []

    def charge(user, action, qty=1, note="", min_credits=0, exact=None, paid_only=False):
        ledger.append((getattr(user, "pk", None), action, exact))
        return {"ok": True, "charged": int(exact or 0), "balance": 900,
                "spend_ref": "sp:%d" % len(ledger)}
    rows = []
    with ExitStack() as st:
        st.enter_context(mock.patch.object(
            ai, "_providers", return_value=[("anthropic", "sk-fake"), ("gemini", "g-fake")]))
        st.enter_context(mock.patch.object(ai, "_call_anthropic", side_effect=fake.anthropic))
        st.enter_context(mock.patch.object(ai, "_call_gemini",
                                           side_effect=fake.banned_call("gemini")))
        st.enter_context(mock.patch.object(ai, "_call_openai",
                                           side_effect=fake.banned_call("openai")))
        st.enter_context(mock.patch("core.billing.charge", side_effect=charge))
        U = get_user_model()
        base = U.objects.count()
        for i, case in enumerate(cases):
            fake.case_id = case["id"]
            payer = U.objects.create_user(name="Exam %d" % i,
                                          phone="+88017%08d" % (40000000 + base + i),
                                          password="pw12345!")
            payer.ai_credits = 1000
            payer.save(update_fields=["ai_credits"])
            ans, err = "", ""
            try:
                ans, _cost = AE.product_answer(case, payer=payer, now=now)
                meta = dict(getattr(AE.product_answer, "last_meta", None) or {})
            except Exception as ex:  # noqa: BLE001 — a crash is a failed case
                meta, err = {}, "error:%s" % type(ex).__name__
            g = AE.grade(case, ans, meta) if not err else {"ok": False, "fails": [err]}
            calls = [c for c in fake.calls if c["case"] == case["id"]]
            banned = [b for b in fake.banned if b[0] == case["id"]]
            cf = contract(case, calls, now, banned, crisis=meta.get("source") == "crisis")
            charge_fails = [f for f in g["fails"] if f in ("credits_mismatch", "continue_charged")]
            ans_fails = [f for f in g["fails"] if f not in charge_fails]
            rows.append({"id": case["id"], "cat": case["cat"], "level": AE.level_of(case),
                         "answer_ok": not ans_fails, "contract_ok": not cf,
                         "credits_ok": not charge_fails and not err,
                         "ok": not ans_fails and not cf and not charge_fails,
                         "fails": ans_fails + ["contract:" + f for f in cf] + charge_fails,
                         "charged": [x for x in ledger if x[0] == payer.pk],
                         "answer": ans, "continued": meta.get("continued", ""),
                         "cut": bool(meta.get("cut")), "cont_charged": meta.get("cont_charged", 0),
                         "calls": len(calls)})
    return scorecard(rows)


def scorecard(rows):
    from collections import Counter
    n = len(rows) or 1
    rate = (lambda k: round(sum(1 for r in rows if r[k]) / n, 3))
    by_cat = {}
    for r in rows:
        b = by_cat.setdefault(r["cat"], [0, 0])
        b[0] += 1
        b[1] += 1 if r["ok"] else 0
    reasons = Counter(f for r in rows for f in r["fails"])
    return {"cases": len(rows), "pass_rate": rate("ok"), "answer_rate": rate("answer_ok"),
            "contract_rate": rate("contract_ok"), "credits_rate": rate("credits_ok"),
            "by_cat": {k: "%d/%d" % (v[1], v[0]) for k, v in sorted(by_cat.items())},
            "reasons": dict(reasons.most_common(25)),
            "failed": [{"id": r["id"], "fails": r["fails"]} for r in rows if not r["ok"]],
            "rows": rows}


def line(card):
    """One grep-able CI log line."""
    return ("AIEXAM-OFFLINE cases=%d pass=%.3f answer=%.3f contract=%.3f credits=%.3f reasons=%s"
            % (card["cases"], card["pass_rate"], card["answer_rate"], card["contract_rate"],
               card["credits_rate"], json.dumps(card["reasons"], ensure_ascii=False)))
