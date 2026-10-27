"""
Eval runner. Two modes:

  replay (CI, default) — NEVER calls a provider. LLM features: each case's
      RECORDED model output (recorded/<feature>.jsonl) goes through the
      product's own post-processing + guards (llm_specs.post) and is graded.
      Each recorded row also carries NEGATIVE CONTROLS ("bad" outputs with a
      known fault: invented price, provider name, refund promise, action
      claim, medical claim, wrong language…) — the product guard must block
      them or the grader must catch them, so a weakened guard or grader fails
      CI. Rule features: exact expected outputs.
      Cost per answer is ESTIMATED from the real prompt the product builds
      (token estimate × the router's price table for the model the router
      would pick); latency is the pipeline's own time.

  live (owner only) — real calls through core.ai.generate with feature
      "eval.<id>" (so they show apart in the router usage log), a hard USD
      budget checked against the router's AIUsage cost log before every call,
      latency/cost read back from AIUsage. Never runs in CI.
"""
import json
import os
import time
from decimal import Decimal

from .. import ai_config as C
from .. import ai_prompt as P
from . import graders as GR
from . import registry as REG

HERE = os.path.dirname(os.path.abspath(__file__))
REC_DIR = os.path.join(HERE, "recorded")
THRESHOLDS = os.path.join(HERE, "thresholds.json")


# ------------------------------------------------------------------ io
def set_path(fid):
    return os.path.join(HERE, fid + ".jsonl")


def load_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def load_cases(fid):
    return load_jsonl(set_path(fid))


def load_recorded(fid):
    return {r["id"]: r for r in load_jsonl(os.path.join(REC_DIR, fid + ".jsonl"))}


def thresholds():
    with open(THRESHOLDS, encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------------ cost estimate
def est_tokens(text):
    """Conservative token estimate: Bangla script tokenizes ~1 token per
    1.5 characters on current tokenizers, Latin text ~4 characters a token."""
    t = text or ""
    bn = sum(1 for ch in t if "ঀ" <= ch <= "৿")
    other = len(t) - bn
    return int(bn / 1.5 + other / 4) + 1


def primary_model(klass, cfg=None):
    """The model the router tries FIRST for this class (default config)."""
    cfg = cfg or C.normalize({})
    prov = C.ORDER[klass][0]
    return C.model_for(cfg, prov, "medium" if klass == "main" else "cheap", klass)


def est_cost(klass, prompt_in, answer_out, cfg=None):
    cfg = cfg or C.normalize({})
    if klass not in C.CLASSES:
        return 0.0, "", 0, 0
    model = primary_model(klass, cfg)
    tin, tout = est_tokens(prompt_in), est_tokens(answer_out)
    return C.cost_usd(cfg, model, tin, tout), model, tin, tout


def worst_case_cost(klass, prompt_in, max_tokens, cfg=None):
    """Upper bound for ONE live call: input estimate x1.5, the full max_tokens
    plus the router's thinking headroom as output, at the most expensive model
    the class could fail over to. Used before every live call so the budget
    is a hard cap, never an average."""
    cfg = cfg or C.normalize({})
    if klass not in C.CLASSES:
        return 0.0
    tin = int(est_tokens(prompt_in) * 1.5) + 50
    tout = int(max_tokens) + 1024
    worst = 0.0
    for prov in C.ORDER[klass]:
        tier = "medium" if klass == "main" else "cheap"
        model = C.model_for(cfg, prov, tier, klass)
        worst = max(worst, C.cost_usd(cfg, model, tin, tout))
    return worst


def realistic_cost(klass, prompt_in, out_text, max_tokens, cfg=None, reference=True):
    """Expected USD for one answer. A reference answer is shorter than a real
    one, so it is costed at max(its length, 40% of max_tokens) plus ~300
    thinking tokens on MAIN (effort) models; a live-recorded answer at its
    own length."""
    cfg = cfg or C.normalize({})
    if klass not in C.CLASSES:
        return 0.0, "", 0, 0
    tin = est_tokens(prompt_in)
    tout = est_tokens(out_text)
    if reference:
        tout = max(tout, int(0.4 * max_tokens)) + (300 if klass == "main" else 0)
    model = primary_model(klass, cfg)
    return C.cost_usd(cfg, model, tin, tout), model, tin, tout


# ------------------------------------------------------------------ rule features
def _jsonable(v):
    if isinstance(v, Decimal):
        return format(v.normalize(), "f") if v == v.to_integral_value() else str(v)
    if isinstance(v, dict):
        return {k: _jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_jsonable(x) for x in v]
    return v


def compare(expect, actual):
    """expect: {key: value} exact (after JSON-normalizing Decimals);
    'key__contains': substring; 'key__in': one of; 'key__not': not equal;
    'key__has': list/str contains item; 'key__len': length."""
    bad = []
    actual = _jsonable(actual or {})
    for k, want in expect.items():
        key, _, op = k.partition("__")
        got = actual.get(key) if isinstance(actual, dict) else None
        if op == "":
            ok = got == want
        elif op == "contains":
            ok = isinstance(got, str) and str(want) in got
        elif op == "in":
            ok = got in want
        elif op == "not":
            ok = got != want
        elif op == "has":
            ok = got is not None and want in got
        elif op == "len":
            ok = got is not None and len(got) == want
        else:
            ok = False
        if not ok:
            bad.append({"key": k, "want": want, "got": got})
    return bad


def run_rule(fid):
    from . import rule_runners as RR
    fn = RR.RUNNERS[fid]
    cases = load_cases(fid)
    rows = []
    for c in cases:
        t0 = time.perf_counter()
        try:
            actual = fn(c["input"])
            err = ""
        except Exception as e:  # noqa: BLE001
            actual, err = {}, "%s: %s" % (type(e).__name__, e)
        ms = (time.perf_counter() - t0) * 1000
        diff = compare(c.get("expect") or {}, actual) if not err else [{"error": err}]
        rows.append({"id": c["id"], "lang": c.get("lang", ""), "pass": not diff,
                     "known_gap": c.get("known_gap", ""), "diff": diff, "ms": ms})
    must = [r for r in rows if not r["known_gap"]]
    gaps = [r for r in rows if r["known_gap"]]
    return {
        "feature": fid, "kind": "rule", "cases": len(rows),
        "langs": _lang_counts(cases),
        "accuracy": _rate([r["pass"] for r in rows]),
        "must_pass": _rate([r["pass"] for r in must]),
        "must_cases": len(must),
        "known_gaps": len(gaps),
        "gaps_fixed": sum(1 for r in gaps if r["pass"]),
        "failures": [r for r in must if not r["pass"]][:25],
        "gap_list": [{"id": r["id"], "why": r["known_gap"], "pass": r["pass"]} for r in gaps][:60],
        "p95_ms": _p95([r["ms"] for r in rows]),
        "cost_per_answer_usd": 0.0,
    }


# ------------------------------------------------------------------ llm features
def run_llm_replay(fid, cfg=None):
    from . import llm_specs as S
    cfg = cfg or C.normalize({})
    feat = REG.BY_ID[fid]
    cases = load_cases(fid)
    rec = load_recorded(fid)
    rows, neg = [], []
    costs, toks_in, toks_out, ms_all = [], [], [], []
    for c in cases:
        r = rec.get(c["id"])
        if r is None:
            rows.append({"id": c["id"], "pass": False, "missing": True})
            continue
        klass = REG.model_class_for_case(feat, c, cfg)
        req = S.build(fid, c)
        t0 = time.perf_counter()
        final = S.post(fid, c, r["text"])
        ms_all.append((time.perf_counter() - t0) * 1000)
        g = GR.grade(c, final, S.sources(fid, c))
        prompt_in = P.system_prompt(req.get("extra_system", "")) + req["task"] + req.get("data", "") \
            + "".join(h.get("content", "") for h in req.get("history") or [])
        usd, model, tin, tout = realistic_cost(klass, prompt_in, r["text"], req.get("max_tokens", 600),
                                               cfg, reference=r.get("source") == "reference")
        costs.append(usd)
        toks_in.append(tin)
        toks_out.append(tout)
        rows.append({"id": c["id"], "lang": c.get("lang", ""), "class": klass, **g,
                     "blocked": bool(final.get("blocked")), "answer": final.get("answer", "")[:300],
                     "source": r.get("source", "")})
        for b in r.get("bad") or []:
            fb = S.post(fid, c, b["text"])
            gb = GR.grade(c, fb, S.sources(fid, c))
            guarded = bool(fb.get("blocked") or fb.get("flagged") or fb.get("scrubbed"))
            neg.append({"id": c["id"], "kind": b["kind"], "guard": guarded,
                        "caught": guarded or not gb["pass"],
                        "guard_expected": b["kind"] in S.GUARDED.get(fid, ())})
    return _llm_summary(fid, feat, cases, rows, neg, costs, toks_in, toks_out, ms_all,
                        mode="replay")


def _llm_summary(fid, feat, cases, rows, neg, costs, toks_in, toks_out, ms_all, mode,
                 live_ms=None, models=None):
    def rate(metric):
        vals = [r.get(metric) for r in rows if r.get(metric) is not None]
        return _rate(vals)
    ge = [n for n in neg if n["guard_expected"]]
    by_kind = {}
    for n in neg:
        k = by_kind.setdefault(n["kind"], {"n": 0, "product_guard": 0, "caught": 0})
        k["n"] += 1
        k["product_guard"] += int(n["guard"])
        k["caught"] += int(n["caught"])
    sources = sorted({r.get("source", "") for r in rows if r.get("source")})
    return {
        "feature": fid, "kind": "llm", "mode": mode, "cases": len(cases),
        "langs": _lang_counts(cases),
        "recorded_from": sources,
        "model_class": sorted({r.get("class", "") for r in rows if r.get("class")}),
        "pass": _rate([r.get("pass") for r in rows]),
        "accuracy": rate("accuracy"), "grounding": rate("grounding"),
        "safety": rate("safety"), "language": rate("language"),
        "length": rate("length"), "action": rate("action"),
        "blocked_good": sum(1 for r in rows if r.get("blocked")),
        "negatives": len(neg),
        "negatives_caught": _rate([n["caught"] for n in neg]),
        "guard_block_rate": _rate([n["guard"] for n in ge]),
        "guard_cases": len(ge),
        "negatives_by_kind": by_kind,
        "missed_negatives": [n for n in neg if not n["caught"]][:20],
        "guard_misses": [n for n in ge if not n["guard"]][:20],
        "failures": [r for r in rows if not r.get("pass")][:20],
        "cost_per_answer_usd": round(sum(costs) / len(costs), 6) if costs else 0.0,
        "cost_per_1000_usd": round(1000 * sum(costs) / len(costs), 3) if costs else 0.0,
        "tokens_in_avg": int(sum(toks_in) / len(toks_in)) if toks_in else 0,
        "tokens_out_avg": int(sum(toks_out) / len(toks_out)) if toks_out else 0,
        "full_run_usd": round(sum(costs), 4),
        "pipeline_p95_ms": _p95(ms_all),
        "live_p95_ms": _p95(live_ms) if live_ms else None,
        "models": models or [],
    }


def estimate_live(fid, cfg=None):
    """USD a live run of `fid` would cost (estimate; used to refuse a budget
    that is too small BEFORE any call)."""
    from . import llm_specs as S
    cfg = cfg or C.normalize({})
    feat = REG.BY_ID[fid]
    total = 0.0
    recs = load_recorded(fid)
    for c in load_cases(fid):
        klass = REG.model_class_for_case(feat, c, cfg)
        if klass not in C.CLASSES:
            continue
        req = S.build(fid, c)
        rec = recs.get(c["id"]) or {}
        prompt_in = P.system_prompt(req.get("extra_system", "")) + req["task"] + req.get("data", "")
        total += realistic_cost(klass, prompt_in, rec.get("text", ""), req.get("max_tokens", 600),
                                cfg, reference=True)[0]
    return round(total, 4)


def run_llm_live(fid, budget_usd, limit=None, record=False, out=print):
    """Real provider calls. Caller MUST have confirmed. Budget is enforced
    against the router's own AIUsage cost log for feature eval.<fid>."""
    from django.db.models import Sum
    from django.utils import timezone
    from .. import ai
    from ..models import AIUsage
    from . import llm_specs as S
    feat = REG.BY_ID[fid]
    if not S.live_supported(fid):
        return {"feature": fid, "kind": "llm", "mode": "live", "skipped": S.live_note(fid)}
    cfg = C.normalize({})
    try:
        from .. import ai_router
        cfg = ai_router.cfg()
    except Exception:
        pass
    cases = load_cases(fid)[: limit or None]
    started = timezone.now()
    tag = ("eval." + fid)[:40]
    rows, neg, costs, tin_l, tout_l, ms_l, live_ms, models = [], [], [], [], [], [], [], set()
    recorded = []

    def spent():
        return float(AIUsage.objects.filter(feature=tag, created_at__gte=started)
                     .aggregate(s=Sum("cost_usd"))["s"] or 0.0)

    for c in cases:
        klass = REG.model_class_for_case(feat, c, cfg)
        req = S.build(fid, c)
        prompt_in = P.system_prompt(req.get("extra_system", "")) + req["task"] + req.get("data", "")
        est_next = worst_case_cost(klass, prompt_in, req.get("max_tokens", 600), cfg)
        if spent() + est_next > budget_usd:
            out("budget reached: spent $%.4f of $%.2f — stopping" % (spent(), budget_usd))
            break
        try:
            text, _cost = ai.generate(req["task"], data=req.get("data", ""),
                                      tier=feat["tier"] if feat["tier"] in C.TIERS else "cheap",
                                      max_tokens=req.get("max_tokens", 600), feature=tag,
                                      user=None, extra_system=req.get("extra_system", ""),
                                      history=req.get("history"), task_class=klass)
        except ai.AIUnavailable as e:
            out("AI unavailable (%s) — stopping" % e.reason)
            break
        u = AIUsage.objects.filter(feature=tag, ok=True).order_by("-id").first()
        if u:
            live_ms.append(u.latency_ms or 0)
            models.add(u.model)
            costs.append(float(u.cost_usd or 0))
            tin_l.append(u.input_tokens or 0)
            tout_l.append(u.output_tokens or 0)
        t0 = time.perf_counter()
        final = S.post(fid, c, text)
        ms_l.append((time.perf_counter() - t0) * 1000)
        g = GR.grade(c, final, S.sources(fid, c))
        rows.append({"id": c["id"], "lang": c.get("lang", ""), "class": klass, **g,
                     "blocked": bool(final.get("blocked")), "answer": final.get("answer", "")[:300],
                     "source": "live"})
        if record:
            recorded.append({"id": c["id"], "source": "live:%s" % (u.model if u else "?"),
                             "text": text})
    if record and recorded:
        old = load_recorded(fid)
        for r in recorded:
            r["bad"] = (old.get(r["id"]) or {}).get("bad") or []
            old[r["id"]] = r
        os.makedirs(REC_DIR, exist_ok=True)
        with open(os.path.join(REC_DIR, fid + ".jsonl"), "w", encoding="utf-8") as f:
            for c in load_cases(fid):
                if c["id"] in old:
                    f.write(json.dumps(old[c["id"]], ensure_ascii=False) + "\n")
    res = _llm_summary(fid, feat, cases, rows, neg, costs, tin_l, tout_l, ms_l, mode="live",
                       live_ms=live_ms, models=sorted(models))
    res["answered"] = len(rows)
    res["spent_usd"] = round(spent(), 4)
    return res


# ------------------------------------------------------------------ all
def run_feature(fid, cfg=None):
    feat = REG.BY_ID[fid]
    if feat["kind"] == REG.RULE:
        return run_rule(fid)
    return run_llm_replay(fid, cfg)


def check(result, th):
    """-> list of threshold violations for one feature result."""
    fid = result["feature"]
    t = dict(th.get("default_" + result["kind"], {}))
    t.update(th.get("features", {}).get(fid, {}))
    bad = []
    if result["cases"] < t.get("min_cases", REG.MIN_CASES):
        bad.append("%s: only %d cases (< %d)" % (fid, result["cases"], t.get("min_cases", 200)))
    for k, v in t.items():
        if k in ("min_cases",):
            continue
        if k.startswith("max_"):
            key = k[4:]
            got = result.get(key) or 0
            if got > v:
                bad.append("%s: %s %s > max %s%s" % (
                    fid, key, got, v, " (new failures must be fixed, not listed)"
                    if key == "known_gaps" else ""))
            continue
        got = result.get(k)
        if got is None:
            continue
        if got + 1e-9 < v:
            bad.append("%s: %s %.4f < threshold %.4f" % (fid, k, got, v))
    return bad


def run_all(features=None, cfg=None):
    th = thresholds()
    results, problems = [], []
    for f in REG.FEATURES:
        if features and f["id"] not in features:
            continue
        r = run_feature(f["id"], cfg)
        results.append(r)
        problems += check(r, th)
    return results, problems


# ------------------------------------------------------------------ helpers
def _rate(vals):
    vals = [bool(v) for v in vals if v is not None]
    return round(sum(vals) / len(vals), 4) if vals else None


def _p95(xs):
    xs = sorted(x for x in (xs or []) if x is not None)
    if not xs:
        return None
    return round(xs[min(len(xs) - 1, int(0.95 * len(xs)))], 2)


def _lang_counts(cases):
    out = {}
    for c in cases:
        k = c.get("lang", "?")
        out[k] = out.get(k, 0) + 1
    return out


def scorecard_md(results, problems):
    lines = ["# AI eval scorecard", "",
             "| feature | kind | cases | pass | grounding | safety | language | action | negatives caught | guard block | est. $/answer |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]

    def f(v):
        return "-" if v is None else ("%.1f%%" % (100 * v))
    for r in results:
        if r["kind"] == "rule":
            lines.append("| %s | rule | %d | %s (must %s, gaps %d) | - | - | - | - | - | - | 0 |" % (
                r["feature"], r["cases"], f(r["accuracy"]), f(r["must_pass"]), r["known_gaps"]))
        else:
            lines.append("| %s | llm/%s | %d | %s | %s | %s | %s | %s | %s | %s | $%.5f |" % (
                r["feature"], ",".join(r["model_class"]), r["cases"], f(r["pass"]),
                f(r["grounding"]), f(r["safety"]), f(r["language"]), f(r["action"]),
                f(r["negatives_caught"]), f(r["guard_block_rate"]), r["cost_per_answer_usd"]))
    lines += ["", "## Threshold problems", ""] + (["- " + p for p in problems] or ["none"])
    return "\n".join(lines) + "\n"
