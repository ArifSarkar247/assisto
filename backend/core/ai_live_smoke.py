"""
aibar — the ONE live AI smoke the integrator runs after the owner adds the
provider keys (anthropic / openai / gemini). Logic lives here (testable with
mocked provider seams); the command is core/management/commands/ai_live_smoke.py.

  manage.py ai_live_smoke --estimate                  # free: plan + worst-case cost
  manage.py ai_live_smoke --confirm --budget-usd 1    # real calls, once

What it does (tiny prompts, bn + en, no user, so no credits are charged):
  * per configured provider, pinned with ai.only_provider(): one MAIN-class
    Bangla + one MAIN-class English call, one CHEAP-class Bangla call;
  * when the owner's pricing-40 credit_model block is ON: one Bangla call per
    chat mode (quick / smart / pro) on the exact model + caps the chat uses;
  * per call: ok / error kind, latency ms, tokens, real cost (the router's
    own price table), the model that answered, Bangla script check, and a
    one-word correctness check ("বাংলাদেশ" / "Dhaka");
  * the BUDGET is enforced BEFORE each call with that call's worst case
    (max input estimate + max output incl. thinking headroom at the model's
    price): a call that could push the run over --budget-usd is skipped;
  * a 40 % rule line: is the chat on the capped pricing-40 path, or on the
    legacy path (MAIN model at 1 credit = a loss per message)?
Keys are never printed; provider names only.
"""
import time

from . import ai
from . import ai_config as C
from . import ai_prompt as P

PROMPTS = {
    "bn": ("এক বাক্যে উত্তর দিন: ঢাকা কোন দেশের রাজধানী?", ("বাংলাদেশ",)),
    "en": ("Answer in one short sentence: Dhaka is the capital of which country?",
           ("bangladesh",)),
}
MAX_OUT = 80               # visible answer tokens asked for
DEFAULT_BUDGET_USD = 1.0


def _bn_script(text):
    return any("ঀ" <= ch <= "৿" for ch in text or "")


def _est_in_tokens(prompt):
    """Conservative input estimate: the shared system prompt + the prompt,
    Bangla letters at 1.3 tokens, everything else at 0.35."""
    system = P.system_prompt("")
    t = 0.0
    for ch in system + prompt:
        t += 1.3 if "ঀ" <= ch <= "৿" else 0.35
    return int(t) + 50


def _worst_out(model, effort):
    """max output tokens the call can bill (thinking headroom included)."""
    if model in C.EFFORT_MODELS:
        return min(ai._MAX_TOKENS_CAP, MAX_OUT + ai._THINK_HEADROOM.get(effort, 1024))
    if model.startswith("gemini-2.5"):
        return MAX_OUT + 1024        # thinking tokens bill as output on main class
    return MAX_OUT


def _credit_model():
    try:
        from . import billing
        return billing.cfg().get("credit_model") or {}
    except Exception:  # noqa: BLE001
        return {}


def plan():
    """[{name, provider, klass, mode, lang, model, effort, worst_usd}] — the
    calls a --confirm run would make, in order. Pure reads (DB config only)."""
    from . import ai_router as R
    conf = R.cfg()
    names = [n for n, _k in ai._providers()]
    calls = []
    for prov in names:
        for klass, lang in (("main", "bn"), ("main", "en"), ("cheap", "bn")):
            model = C.model_for(conf, prov, "cheap", klass)
            eff = C.effort_for(conf, "cheap", klass)
            calls.append({"name": "%s.%s.%s" % (prov, klass, lang), "provider": prov,
                          "klass": klass, "mode": None, "lang": lang,
                          "model": model, "effort": eff})
    cm = _credit_model()
    if cm.get("enabled") and "anthropic" in names:
        from .logic import pricing_40 as P40
        for m in P40.MODE_IDS:
            spec = P40.mode_spec(cm, m)
            calls.append({"name": "anthropic.mode_%s.bn" % m, "provider": "anthropic",
                          "klass": "main", "mode": m, "lang": "bn",
                          "model": spec["model"], "effort": spec["effort"],
                          "out_cap": spec["out_cap"]})
    for c in calls:
        in_tok = _est_in_tokens(PROMPTS[c["lang"]][0])
        out_tok = c.get("out_cap") or _worst_out(c["model"], c["effort"])
        c["worst_usd"] = round(C.cost_usd(conf, c["model"], in_tok, out_tok), 6)
    return calls


def profit_line():
    """(ok, text) — which chat path a user message takes and whether the
    owner's 40 % rule holds on it (owner_actions/PRICING_40PCT_BN.md)."""
    cm = _credit_model()
    if cm.get("enabled"):
        return True, ("credit_model ON: chat runs the capped quick/smart/pro modes "
                      "(PRICING_40PCT_BN.md §5-6: >= 40 % worst case).")
    from . import ai_router as R
    conf = R.cfg()
    model = C.model_for(conf, "anthropic", "cheap", "main")
    return False, ("WARNING credit_model OFF: chat uses the legacy path — %s at "
                   "ai_msg_cheap credits. A typical Bangla chat turn on Opus costs ~৳2.2 "
                   "for 1 credit (PRICING_40PCT_BN.md §3) = a LOSS per message. Apply the "
                   "owner-approved preset (manage.py apply_pricing_preset pricing_27oct "
                   "--dry-run, then --apply --backup-done) BEFORE opening AI to users."
                   % model)


def estimate(budget_usd=DEFAULT_BUDGET_USD):
    calls = plan()
    total = round(sum(c["worst_usd"] for c in calls), 6)
    ok, line = profit_line()
    return {"providers": sorted({c["provider"] for c in calls}), "calls": calls,
            "worst_total_usd": total, "budget_usd": float(budget_usd),
            "fits_budget": total <= float(budget_usd), "pricing_40_ok": ok,
            "pricing_line": line, "available": ai.available()}


def _last_usage(t0):
    from .models import AIUsage
    return (AIUsage.objects.filter(feature="smoke", created_at__gte=t0)
            .order_by("-id").first())


def run(budget_usd=DEFAULT_BUDGET_USD, log=None):
    """Make the planned calls (REAL provider calls outside tests). Returns
    {"results": [...], "spent_usd", "skipped", "passed", "failed"}."""
    from django.utils import timezone
    log = log or (lambda s: None)
    budget = float(budget_usd)
    spent = 0.0
    results, skipped = [], []
    for c in plan():
        if spent + c["worst_usd"] > budget:
            skipped.append(c["name"])
            log("SKIP %s (worst case $%.4f would pass the $%.2f budget)"
                % (c["name"], c["worst_usd"], budget))
            continue
        prompt, expect = PROMPTS[c["lang"]]
        t_db = timezone.now()
        t0 = time.monotonic()
        row = {"name": c["name"], "provider": c["provider"], "lang": c["lang"],
               "mode": c["mode"] or ""}
        try:
            with ai.only_provider(c["provider"]):
                text, cost = ai.generate(
                    task=prompt, tier="cheap", feature="smoke", max_tokens=MAX_OUT,
                    user=None, task_class=c["klass"], mode=c["mode"],
                    digits="bn" if c["lang"] == "bn" else None)
            row.update(ok=True, cost_usd=round(cost, 6), chars=len(text),
                       bangla=_bn_script(text) if c["lang"] == "bn" else None,
                       correct=any(w in text.lower() for w in expect),
                       sample=text.strip().replace("\n", " ")[:80])
            spent += cost
        except ai.AIUnavailable as e:
            row.update(ok=False, error=e.reason, cost_usd=0.0)
        row["latency_ms"] = int((time.monotonic() - t0) * 1000)
        u = _last_usage(t_db)
        if u is not None:
            row.update(model=u.model, in_tok=u.input_tokens, out_tok=u.output_tokens,
                       attempts=u.attempts, provider_latency_ms=u.latency_ms)
        results.append(row)
        log(_fmt(row))
    passed = [r["name"] for r in results if r.get("ok") and r.get("correct")
              and r.get("bangla") is not False]
    failed = [r["name"] for r in results if r["name"] not in passed]
    return {"results": results, "spent_usd": round(spent, 6), "skipped": skipped,
            "passed": passed, "failed": failed, "budget_usd": budget}


def _fmt(r):
    if not r.get("ok"):
        return "FAIL %-28s error=%s latency=%dms attempts=%s" % (
            r["name"], r.get("error"), r["latency_ms"], r.get("attempts", "-"))
    flag = "PASS" if r.get("correct") and r.get("bangla") is not False else "WARN"
    return ("%s %-28s %5dms  $%.5f  in=%s out=%s  model=%s  bangla=%s correct=%s  | %s"
            % (flag, r["name"], r["latency_ms"], r["cost_usd"], r.get("in_tok", "?"),
               r.get("out_tok", "?"), r.get("model", "?"), r.get("bangla"),
               r.get("correct"), r.get("sample", "")))
