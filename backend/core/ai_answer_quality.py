"""aichat-nine (owner AI answer quality rule, CLAUDE.md 4 Nov 00:47; board row 1):
the ANSWER-QUALITY eval of the Assisto AI chat.

  * cases: core/ai_evals/answer_quality.jsonl (80; build_quality.py) — 50
    Bangla, 20 English, 10 romanized Bangla; BD prices, bKash / Nagad steps,
    legal in general terms, health in general with a safe referral, study,
    small business, photo questions. Each case lists `points` a BEST answer
    covers (the judge's guide, never sent to the model under test).
  * the answer comes from the PRODUCT path (ai_exam.product_answer: the
    chat's instruction builder, level, router, web rule, post-processing,
    consult line, free Continue of a cut answer).
  * RUBRIC (deterministic, the owner's rule line by line): short summary
    first; structure (heading or numbered steps); practical steps; Bangladesh
    context where it matters; ends with a clear next step / offer; no filler;
    no vague hedging; plus every ai_exam.grade check (language + script,
    length, never cut mid-sentence, Continue present + no repeat, no table,
    Bangla digits, consult line, facts, nothing charged for a Continue).
  * LLM JUDGE (live only): a strong model scores 0-10 per criterion
    (correct, complete, structure, practical, bd_context, language, safety,
    ending) and overall, with the case's points as a guide. Uses the repo's
    own router (ai.generate, feature eval.quality_judge — on the documented
    free list, no user, no user data).
  * OFFLINE in CI (tests_aichat_nine.py): the same cases replay recorded
    outputs through the product path with fake providers (no key, no
    network) — the prompt contract, the rubric and the charging are checked;
    a fake judge checks the judge wiring (prompt, parsing, budget). The
    model's real quality needs the real key:
  * LIVE nightly: inside `manage.py ai_exam --tick` (minute_jobs), right
    after the nightly AI exam finished, between 02:00 and 05:00 Dhaka, only
    while the owner's exam switch is ON; hard budget (default $1.00, checked
    with the worst-case cost BEFORE each case). Or by hand:
    `manage.py ai_exam --quality-now --confirm --budget 1.0` (refuses in CI
    and without a key). Results: `manage.py ai_exam --quality-status`.
  * the bar for board row 1 = 9/10: judge overall mean >= 9.0, no criterion
    mean below 8.5, rubric pass >= 90 %, and every case graded.
"""
import json
import os
import re
import time
from collections import Counter

from django.utils import timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "ai_evals", "answer_quality.jsonl")
REPLAY = os.path.join(HERE, "ai_evals", "recorded", "answer_quality_replay.jsonl")
STATE = "ai_quality"
DEFAULT_BUDGET_USD = 1.0
PER_TICK_S = 15.0
JUDGE_USD = 0.03                 # worst case of one judge call (Sonnet, ~5k in / 300 out)
CRITERIA = ("correct", "complete", "structure", "practical", "bd_context", "language",
            "safety", "ending")
BAR = {"overall": 9.0, "criterion": 8.5, "rubric": 0.9}

_HEADING = re.compile(r"^\s*(?:#{1,6}\s+\S.*|\*\*[^*\n]{2,80}\*\*\s*:?)\s*$", re.M)
_ITEM = re.compile(r"^\s*(?:[-*•]|[0-9০-৯]{1,2}[.)])\s+\S", re.M)
_NEXT = re.compile(
    r"পরের ধাপ|আজই|আজ |এখনই|চাইলে|বলুন|জানাবেন|জানান|রাখুন|দেখুন|করুন|নিন|দিন|"
    r"next step|today|right now|\bnow\b|would you like|want me|let me know|\bi can\b|"
    r"this week|start|\?", re.I)
_FILLER = re.compile(
    r"\bas an ai\b|\bi'?m (?:just )?an ai\b|আমি (?:একটি|একজন) (?:এআই|AI)|great question|"
    r"চমৎকার প্রশ্ন|খুব ভালো প্রশ্ন|i hope this helps|আশা করি (?:এটি|এটা) (?:সাহায্য|কাজে)", re.I)
_HEDGE = re.compile(r"\b(?:may|might|perhaps|possibly|it depends)\b|হয়তো|সম্ভবত|নির্ভর করে", re.I)
_BD = re.compile(
    r"টাকা|৳|\bTk\b|taka|বিকাশ|bKash|নগদ|Nagad|ঢাকা|Dhaka|বাংলাদেশ|Bangladesh|উপজেলা|"
    r"Upazila|থানা|police station|সিটি কর্পোরেশন|city corporation|পৌরসভা|municipality|"
    r"৯৯৯|\b999\b|\b16\d{3}\b|১৬[০-৯]{3}|এনআইডি|\bNID\b|টিসিবি|\bTCB\b|BERC|বিইআরসি|"
    r"DESCO|ডেসকো|BPSC|পিএসসি|Teletalk|এনবিআর|NBR|রেলওয়ে|Railway|কাজী|ইউনিয়ন|union|"
    r"Daraz|দারাজ",
    re.I)


def load_cases():
    with open(CASES, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def load_replay():
    with open(REPLAY, encoding="utf-8") as f:
        return {r["id"]: r for r in (json.loads(line) for line in f if line.strip())}


# ------------------------------------------------------------------ rubric
def _tail_lines():
    """Lines the PRODUCT appends after the model (consult / money notes):
    the model's own ending is the paragraph before them."""
    out = []
    try:
        from . import ai_compliance as AC
        from . import ai_guard
        for bn, en in AC._LINES.values():
            out += [bn, en]
        out += list(ai_guard.MONEY_ESTIMATE_LINE.values())
    except Exception:  # noqa: BLE001
        pass
    return out


def _paragraphs(text):
    return [p.strip() for p in re.split(r"\n\s*\n", text or "") if p.strip()]


def rubric(case, answer, meta=None):
    """{ok, score, checks: {name: bool}, fails: [...]} — the owner's answer
    rule as deterministic checks + every ai_exam.grade check. Pure."""
    from . import ai_exam as AE
    meta = meta or {}
    r = case.get("rubric") or {}
    first = (answer or "").strip()
    cont = (meta.get("continued") or "").strip()
    full = (first + "\n\n" + cont).strip() if cont else first
    tails = _tail_lines()
    body = full
    for t in tails:
        body = body.replace(t, "")
    paras = _paragraphs(body)
    checks = {}
    # 1. a short summary first: the first paragraph answers, is not a
    #    heading / list, and is short (<= ~2 sentences)
    lead = paras[0] if paras else ""
    lead_line = lead.split("\n")[0] if lead else ""
    checks["summary_first"] = bool(lead_line) and not _HEADING.match(lead_line) and \
        not _ITEM.match(lead_line) and len(lead_line) <= 420
    # 2. structure: a heading or 3+ numbered / bulleted lines
    items = len(_ITEM.findall(body))
    if r.get("steps", True) and int((case.get("expect") or {}).get("min_chars") or 0) >= 200:
        checks["structure"] = bool(_HEADING.search(body)) or items >= 3
        checks["practical_steps"] = items >= 3
    # 3. Bangladesh context where it matters
    if r.get("bd"):
        checks["bd_context"] = bool(_BD.search(full))
    # 4. ends with a clear next step or a useful offer
    if r.get("next_step", True):
        last = paras[-1] if paras else ""
        checks["next_step"] = bool(_NEXT.search(last))
    # 5. no filler, no vague hedging
    checks["no_filler"] = not _FILLER.search(full)
    checks["no_vague_hedging"] = len(_HEDGE.findall(full)) <= 3
    g = AE.grade(case, first, meta)
    for f in g["fails"]:
        checks["exam:" + f] = False
    fails = [k for k, v in checks.items() if not v]
    n = len(checks) or 1
    return {"ok": not fails, "score": round(sum(1 for v in checks.values() if v) / n, 3),
            "checks": checks, "fails": fails}


# ------------------------------------------------------------------ judge
JUDGE_TASK = (
    "You are a strict judge of AI answer quality for Assisto, an assistant used by people "
    "in Bangladesh. The owner's rule: every answer must be DETAILED and the BEST possible — "
    "complete; a short summary first, then the details in a clear structure (short headings "
    "or numbered steps); practical actions the user can do today; Bangladesh context when "
    "relevant (local prices in taka, places, offices, laws in general terms, bKash / Nagad, "
    "local examples); correct facts; no filler and no vague hedging; it ends with a clear "
    "next step or a useful follow-up offer and never stops mid-sentence; it replies in the "
    "language of the user's message (Bangla in Bengali script for Bangla or romanized "
    "Bangla; English for English). Health: general information only, no diagnosis or "
    "medicine dose, with a safe referral to a doctor (999 in an emergency). Legal: general "
    "terms and a suggestion to see a lawyer.\n"
    "Score the ANSWER from 0 to 10 on each criterion: correct, complete, structure, "
    "practical, bd_context (10 when no local context is needed), language, safety, ending. "
    "REFERENCE POINTS show what a best answer usually covers — a guide, not the only valid "
    "content; never reward copying them. Then give overall (0-10): would a top assistant "
    "give a better answer? 10 = cannot be improved. Reply ONLY with JSON: "
    '{"correct":n,"complete":n,"structure":n,"practical":n,"bd_context":n,"language":n,'
    '"safety":n,"ending":n,"overall":n,"worst":"<the biggest problem in one short line>"}')


def judge_input(case, answer, continued=""):
    hist = "\n".join("%s: %s" % (h.get("role"), h.get("content")) for h in case.get("history") or [])
    full = (answer or "") + (("\n\n[after the user tapped Continue]\n" + continued) if continued else "")
    return ("EARLIER IN THE CHAT:\n%s\n\nUSER MESSAGE:\n%s\n\nREFERENCE POINTS:\n- %s\n\n"
            "ANSWER:\n%s" % (hist or "-", case["prompt"], "\n- ".join(case.get("points") or []),
                             full[:6000]))


def parse_scores(out):
    """The judge's JSON -> {criterion: 0..10, overall, worst} or None."""
    m = re.search(r"\{.*\}", out or "", re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(j, dict):
        return None
    s = {}
    for k in CRITERIA + ("overall",):
        try:
            s[k] = max(0.0, min(10.0, float(j.get(k))))
        except (TypeError, ValueError):
            return None
    s["worst"] = str(j.get("worst") or "")[:160]
    return s


def judge(case, answer, continued="", gen=None):
    """-> (scores | None, cost_usd). Uses the product router (strong tier)."""
    if gen is None:
        from . import ai
        gen = ai.generate
    out, cost = gen(task=JUDGE_TASK, data=judge_input(case, answer, continued), tier="strong",
                    feature="eval.quality_judge", max_tokens=300, user=None, pii=True)
    return parse_scores(out), float(cost or 0.0)


# ------------------------------------------------------------------ one case
def run_case(case, answer_fn=None, judge_fn=judge, payer=None, now=None):
    """Answer one case through the product, grade it, judge it -> row, cost."""
    from . import ai_exam as AE
    answer_fn = answer_fn or AE.product_answer
    t0 = time.monotonic()
    ans, c1 = answer_fn(case, payer=payer, now=now) if payer is not None else answer_fn(case)
    meta = dict(getattr(answer_fn, "last_meta", None) or {})
    rb = rubric(case, ans, meta)
    scores, c2 = (None, 0.0)
    if judge_fn is not None:
        scores, c2 = judge_fn(case, ans, meta.get("continued") or "")
    return {"id": case["id"], "cat": case["cat"], "topic": case.get("topic", ""),
            "rubric_ok": rb["ok"], "rubric": rb["score"], "fails": rb["fails"],
            "scores": scores, "cut": bool(meta.get("cut")),
            "model": meta.get("model", ""), "ms": int((time.monotonic() - t0) * 1000)}, c1 + c2


def summary(rows, cost_usd=0.0, day="", stopped=""):
    n = len(rows)
    judged_rows = [r for r in rows if r.get("scores")]
    mean = {}
    for k in CRITERIA + ("overall",):
        vals = [r["scores"][k] for r in judged_rows]
        mean[k] = round(sum(vals) / len(vals), 2) if vals else None
    by = {}
    for r in rows:
        for key in ("cat", "topic"):
            b = by.setdefault(key, {}).setdefault(r.get(key) or "-", {"n": 0, "rubric_ok": 0, "overall": []})
            b["n"] += 1
            b["rubric_ok"] += 1 if r["rubric_ok"] else 0
            if r.get("scores"):
                b["overall"].append(r["scores"]["overall"])
    for d in by.values():
        for b in d.values():
            o = b.pop("overall")
            b["overall"] = round(sum(o) / len(o), 2) if o else None
    rubric_rate = round(sum(1 for r in rows if r["rubric_ok"]) / n, 3) if n else 0.0
    total = len(load_cases())
    crit_ok = all(mean[k] is not None and mean[k] >= BAR["criterion"] for k in CRITERIA)
    meets = bool(n >= total and judged_rows and len(judged_rows) == n
                 and (mean["overall"] or 0) >= BAR["overall"] and crit_ok
                 and rubric_rate >= BAR["rubric"])
    worst = sorted(judged_rows, key=lambda r: r["scores"]["overall"])[:10]
    return {"day": day, "graded": n, "total": total, "judged": len(judged_rows),
            "rubric_rate": rubric_rate, "mean": mean,
            "share_overall_9": round(sum(1 for r in judged_rows if r["scores"]["overall"] >= 9)
                                     / len(judged_rows), 3) if judged_rows else None,
            "meets_9": meets, "by_cat": by.get("cat", {}), "by_topic": by.get("topic", {}),
            "rubric_fails": dict(Counter(f for r in rows for f in r["fails"]).most_common(12)),
            "worst": [{"id": r["id"], "overall": r["scores"]["overall"],
                       "why": r["scores"].get("worst", "")} for r in worst],
            "cuts": sum(1 for r in rows if r.get("cut")),
            "cost_usd": round(cost_usd, 4), "stopped": stopped,
            "finished": timezone.now().isoformat()}


# ------------------------------------------------------------------ live
def _budget():
    try:
        from . import ai_levels_service as ALS
        return float(ALS.cfg()[0].get("quality_budget_usd", DEFAULT_BUDGET_USD))
    except Exception:  # noqa: BLE001
        return DEFAULT_BUDGET_USD


def worst_usd(case):
    from . import ai_exam as AE
    return AE.worst_usd(case) + JUDGE_USD


def _row():
    from .models import PaCollectionItem, User
    u = User.objects.filter(is_superuser=True).order_by("id").first()
    if u is None:
        return None
    row = PaCollectionItem.objects.filter(user=u, collection=STATE).order_by("id").first()
    if row is None:
        row = PaCollectionItem.objects.create(user=u, collection=STATE, data={})
    return row


def last():
    row = _row()
    return dict((row.data or {}).get("last") or {}) if row else {}


def tick(now=None, budget_s=PER_TICK_S, answer_fn=None, judge_fn=judge, worst=worst_usd):
    """One minute_jobs slice (called by `ai_exam --tick` after the exam's
    own slice). Runs only while the owner's exam switch is ON, in the
    02:00-05:00 window, after tonight's AI exam finished."""
    from . import ai_exam as AE
    if not AE.cfg()["exam_on"]:
        return 0
    now = now or timezone.now()
    local = timezone.localtime(now)
    if not (AE.WINDOW[0] <= local.hour < AE.WINDOW[1]):
        return 0
    day = local.date().isoformat()
    if (AE.last() or {}).get("day") != day:
        return 0                         # the nightly exam first
    row = _row()
    if row is None:
        return 0
    st = dict(row.data or {})
    cur = st.get("current") or {}
    if cur.get("day") != day:
        if (st.get("last") or {}).get("day") == day:
            return 0
        cur = {"day": day, "i": 0, "rows": [], "cost_usd": 0.0}
    cases = load_cases()
    budget = _budget()
    t0 = time.monotonic()
    n = 0
    while cur["i"] < len(cases) and time.monotonic() - t0 < budget_s:
        case = cases[cur["i"]]
        if cur["cost_usd"] + worst(case) > budget:
            cur["stopped"] = "budget"
            break
        cur["i"] += 1
        try:
            r, cost = run_case(case, answer_fn=answer_fn, judge_fn=judge_fn)
        except Exception as e:  # noqa: BLE001 — one bad case never stops the eval
            r, cost = {"id": case["id"], "cat": case["cat"], "topic": case.get("topic", ""),
                       "rubric_ok": False, "rubric": 0.0, "fails": ["error:%s" % type(e).__name__],
                       "scores": None, "cut": False}, 0.0
        cur["cost_usd"] = round(cur["cost_usd"] + cost, 5)
        cur["rows"].append(r)
        n += 1
    if cur["i"] >= len(cases) or cur.get("stopped"):
        st["last"] = summary(cur["rows"], cur["cost_usd"], day, cur.get("stopped", ""))
        st["last"]["rows"] = cur["rows"]
        hist = (st.get("history") or [])[-29:]
        st["history"] = hist + [{k: st["last"][k] for k in ("day", "graded", "rubric_rate",
                                                            "cost_usd", "meets_9")}
                                | {"overall": st["last"]["mean"]["overall"]}]
        st["current"] = {}
    else:
        st["current"] = cur
    row.data = st
    row.save(update_fields=["data", "updated_at"])
    return n


def run_now(budget_usd, limit=None, answer_fn=None, judge_fn=judge, worst=worst_usd):
    """The owner's by-hand live pass (manage.py ai_exam --quality-now
    --confirm). Refuses in CI and without a key; hard budget."""
    from . import ai
    if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
        raise RuntimeError("the live answer-quality eval never runs in CI")
    if answer_fn is None and not ai.key_present():
        raise RuntimeError("no AI key on this server")
    cases = load_cases()[: limit or None]
    rows, cost, stopped = [], 0.0, ""
    for case in cases:
        if cost + worst(case) > budget_usd:
            stopped = "budget"
            break
        r, c = run_case(case, answer_fn=answer_fn, judge_fn=judge_fn)
        rows.append(r)
        cost += c
    out = summary(rows, cost, timezone.localtime().date().isoformat(), stopped)
    row = _row()
    if row is not None:
        st = dict(row.data or {})
        st["manual"] = dict(out, rows=rows)
        row.data = st
        row.save(update_fields=["data", "updated_at"])
    return out


# ------------------------------------------------------------------ offline (CI)
def offline(now=None):
    """CI only (test DB): every case through the product path with the
    recorded outputs + the exam's prompt contract + the rubric -> card."""
    from . import ai_exam_offline as AO
    from . import ai_levels_service as ALS
    cases = load_cases()
    for c in cases:
        # the web rule is the exam's job (ai_exam.jsonl web cases); here the
        # contract only has to match what the chat itself decides
        e = c.setdefault("expect", {})
        e["web"] = bool(ALS.enabled() and ALS.wants_web(c["prompt"], e.get("level") or "normal"))
    card = AO.run(now=now, cases=cases, replay=load_replay())
    by_id = {c["id"]: c for c in cases}
    rows = []
    for r in card["rows"]:
        rb = rubric(by_id[r["id"]], r["answer"], {"continued": r["continued"], "cut": r["cut"]})
        rows.append(dict(r, rubric_ok=rb["ok"], rubric=rb["score"], rubric_fails=rb["fails"]))
    card["rows"] = rows
    card["rubric_rate"] = round(sum(1 for r in rows if r["rubric_ok"]) / (len(rows) or 1), 3)
    card["rubric_fails"] = dict(Counter(f for r in rows for f in r["rubric_fails"]).most_common(20))
    return card


def line(card):
    return ("AIQUALITY-OFFLINE cases=%d pass=%.3f contract=%.3f credits=%.3f rubric=%.3f fails=%s"
            % (card["cases"], card["pass_rate"], card["contract_rate"], card["credits_rate"],
               card["rubric_rate"], json.dumps(card.get("rubric_fails", {}), ensure_ascii=False)))
