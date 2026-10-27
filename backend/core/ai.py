"""
Assisto AI layer — a production AI ROUTER over three providers (Anthropic
main, Google Gemini for cheap small tasks, OpenAI backup). Works with NO key
(callers get AIUnavailable and show a Bangla needs-key state).

  * job class: tier medium/strong (+ cheap-tier chat/assistant/agent
    features) = MAIN -> Anthropic, OpenAI, Gemini; other cheap-tier work
    (classify, short replies, summaries, extraction) = CHEAP -> Gemini,
    OpenAI, Anthropic (Haiku). Models per slot are Owner Admin settings
    (core/ai_config.py).
  * automatic failover on connection errors, timeouts, 429, 5xx, provider
    billing/auth errors, refusals, empty replies, a provider over its daily
    cap, or an open circuit. NO failover on 400/422 bad requests (our bug):
    logged, credits refunded, honest "queued" state.
  * circuit breaker + health per provider, daily caps per provider and in
    total, 80% / 100% owner alerts (core/ai_router.py, DB-shared state).
  * cost per call from the owner-editable price table, logged in AIUsage with
    provider, model, class, latency, success and failover path; booked into
    Profit Guard (billing.record_ai_cost_usd). Users are charged credits by
    TIER (billing.charge(ai_msg_<tier>)), never by provider.
  * one shared system prompt + output normalization (core/ai_prompt.py): the
    same Bangla on every provider, and the app never learns which provider
    answered (status(), replies and meta stay provider-neutral).

Prompt-injection protection: callers must pass untrusted user content via
`data` (wrapped in a DATA fence); the system prompt forbids following any
instructions found inside it. Text in user messages is DATA, never commands.

Network seams (patched in tests, never real in CI): _call_anthropic,
_call_gemini, _call_openai (same signature), _anthropic_client, _http.
"""
import contextvars
import logging
import time as _time
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from . import ai_config as C
from . import ai_prompt as P
from .models import AIUsage

log = logging.getLogger(__name__)

# PUBLIC, provider-neutral labels per tier — safe to show in the app (chat
# meta "model"). Never a provider model id; real ids live in ai_config.
TIER_MODEL = {
    "cheap": "assisto-lite",
    "medium": "assisto",
    "strong": "assisto-pro",
}
# Back-compat: USD per 1M tokens (input, output) of the shipped price table.
PRICES = {m: (p["in"], p["out"]) for m, p in C.DEFAULT_PRICES.items()}

_INJECTION_GUARD = P.INJECTION_GUARD

# thinking headroom added to the caller's max_tokens on effort models
# (adaptive thinking tokens count against max_tokens; billed only if used)
_THINK_HEADROOM = {"low": 1024, "medium": 4096, "high": 8000, "xhigh": 12000, "max": 15000}
_MAX_TOKENS_CAP = 16000          # non-streaming request ceiling


class AIUnavailable(Exception):
    """Raised when AI is off (no key), a budget/cap/limit is reached, or every
    provider failed ('no_key'|'budget'|'user_limit'|'credits'|'queued')."""
    def __init__(self, reason="no_key"):
        self.reason = reason
        super().__init__(reason)


class ProviderError(Exception):
    """One provider attempt failed. kind: timeout | connection | rate_limit |
    server | billing | auth | not_found | refusal | empty | bad_request | error."""
    NO_FAILOVER = ("bad_request",)
    NOT_CIRCUIT = ("bad_request", "refusal")

    def __init__(self, kind, detail=""):
        self.kind = kind
        self.detail = (detail or "")[:200]
        super().__init__("%s %s" % (kind, self.detail))

    @property
    def failover(self):
        return self.kind not in self.NO_FAILOVER

    @property
    def circuit(self):
        return self.kind not in self.NOT_CIRCUIT


# per-attempt options for the provider seams (keeps their 6-arg signature
# stable for existing tests that patch them)
_CALL_OPTS = contextvars.ContextVar("ai_call_opts", default=None)


def _opts():
    return _CALL_OPTS.get() or {}


# ------------------------------------------------------------------ keys
def active_api_key():
    """Prefer the owner-configured key in the Integrations store; fall back to
    the environment. Returns '' if none."""
    try:
        from . import integrations
        k = integrations.get("anthropic").get("api_key")
        if k:
            return k
    except Exception:
        pass
    return settings.AI_API_KEY or ""


def key_present():
    return bool(active_api_key())


def _providers():
    """Usable providers: [(name, key)]. Store wins over env. Gemini/OpenAI
    count only once their Integrations test passed (is_enabled)."""
    out = []
    ak = active_api_key()
    if ak:
        out.append(("anthropic", ak))
    try:
        from . import integrations
        gk = integrations.get("gemini").get("api_key")
        if gk and integrations.is_enabled("gemini"):
            out.append(("gemini", gk))
        ok = integrations.get("openai").get("api_key")
        if ok and integrations.is_enabled("openai"):
            out.append(("openai", ok))
    except Exception:
        pass
    return out


# ------------------------------------------------------------------ budgets
def _today_spend():
    """Today's (Asia/Dhaka calendar day) total AI provider spend in USD."""
    from . import ai_router as R
    return R.spend_today()


def _cfg_override(key):
    """An owner override from PricingConfig (/admin/pricing); 0/absent = use
    the server env default. Never raises."""
    try:
        from . import billing
        return float(billing.cfg().get(key) or 0)
    except Exception:
        return 0.0


def daily_budget_usd():
    """LEGACY global kill-switch: admin override, else env AI_DAILY_BUDGET_USD.
    The router's effective total cap is min(this, AI page total cap)."""
    v = _cfg_override("ai_daily_budget_usd")
    return v if v > 0 else float(settings.AI_DAILY_BUDGET_USD)


def user_daily_limit():
    """Per-user AI calls/day: admin override, else env default."""
    v = int(_cfg_override("ai_user_daily_limit"))
    return v if v > 0 else int(settings.AI_USER_DAILY_LIMIT)


def available():
    """AI usable right now: at least one provider configured AND under the
    effective total daily cap."""
    if not _providers():
        return False
    from . import ai_router as R
    return not R.total_capped()


def _user_over_limit(user):
    if not user:
        return False
    since = timezone.now() - timedelta(days=1)
    n = AIUsage.objects.filter(user=user, created_at__gte=since, ok=True).count()
    return n >= user_daily_limit()


# ------------------------------------------------------------------ messages
def _messages(history, prompt):
    """Provider-neutral messages: prior turns (role/content) then the current
    user prompt. `history` is already sanitised by the caller."""
    msgs = []
    for h in (history or []):
        role = h.get("role")
        content = (h.get("content") or "").strip()
        if role in ("user", "assistant") and content:
            msgs.append({"role": role, "content": content})
    msgs.append({"role": "user", "content": prompt})
    return msgs


def _flatten_history(history, prompt):
    """Fold prior turns into one transcript (kept for callers/tests)."""
    lines = []
    for h in (history or []):
        role = h.get("role")
        content = (h.get("content") or "").strip()
        if role in ("user", "assistant") and content:
            who = "User" if role == "user" else "Assistant"
            lines.append(f"{who}: {content}")
    lines.append(f"User: {prompt}")
    return "\n".join(lines)


# ------------------------------------------------------------------ anthropic
def _anthropic_client(key, timeout):
    import anthropic
    # max_retries=0: the ROUTER fails over instead of the SDK retrying.
    return anthropic.Anthropic(api_key=key, timeout=timeout, max_retries=0)


def anthropic_request(model, system, messages, max_tokens, effort="low"):
    """The exact Messages API body for `model`. Opus/Sonnet/Haiku 5.5: effort
    + adaptive thinking; NEVER temperature/top_p/top_k, never disabled
    thinking, never an assistant prefill (the last message is the user's)."""
    body = {"model": model, "system": system, "messages": messages,
            "max_tokens": int(max_tokens)}
    if model in C.EFFORT_MODELS:
        eff = effort if effort in C.EFFORTS else "low"
        body["output_config"] = {"effort": eff}
        body["thinking"] = {"type": "adaptive"}
        body["max_tokens"] = min(_MAX_TOKENS_CAP, int(max_tokens) + _THINK_HEADROOM[eff])
    return body


def _anthropic_error(e):
    try:
        import anthropic
    except ImportError:
        return ProviderError("error", type(e).__name__)
    if isinstance(e, anthropic.APITimeoutError):
        return ProviderError("timeout")
    if isinstance(e, anthropic.APIConnectionError):
        return ProviderError("connection")
    if isinstance(e, anthropic.RateLimitError):
        return ProviderError("rate_limit")
    if isinstance(e, (anthropic.BadRequestError, anthropic.UnprocessableEntityError)):
        return ProviderError("bad_request", getattr(e, "message", "")[:200])
    if isinstance(e, (anthropic.AuthenticationError, anthropic.PermissionDeniedError)):
        return ProviderError("auth")
    if isinstance(e, anthropic.NotFoundError):
        return ProviderError("not_found")
    if isinstance(e, anthropic.APIStatusError):
        code = getattr(e, "status_code", 0) or 0
        return _status_error(code)
    return ProviderError("error", type(e).__name__)


def _call_anthropic(key, model, system, prompt, max_tokens, history=None):
    o = _opts()
    client = _anthropic_client(key, o.get("timeout", 45))
    body = anthropic_request(model, system, _messages(history, prompt), max_tokens,
                             o.get("effort", "low"))
    try:
        if o.get("server_fallback") and model in C.SERVER_FALLBACK_MODELS:
            try:
                resp = client.beta.messages.create(
                    betas=["server-side-fallback-2026-07-01"], fallbacks="default", **body)
            except TypeError:          # SDK without the kwarg -> plain call
                resp = client.messages.create(**body)
        else:
            resp = client.messages.create(**body)
    except ProviderError:
        raise
    except Exception as e:  # noqa: BLE001 — classified for failover
        raise _anthropic_error(e) from e
    if getattr(resp, "stop_reason", "") == "refusal":
        raise ProviderError("refusal")
    text = "".join(getattr(b, "text", "") or "" for b in (resp.content or [])
                   if getattr(b, "type", "") == "text")
    u = resp.usage
    extra = {"cache_read": int(getattr(u, "cache_read_input_tokens", 0) or 0),
             "cache_write": int(getattr(u, "cache_creation_input_tokens", 0) or 0),
             "model": getattr(resp, "model", "") or model}
    return text, int(u.input_tokens or 0), int(u.output_tokens or 0), extra


# ------------------------------------------------------------------ REST providers
def _http():
    import requests
    return requests


def _status_error(code):
    if code == 429:
        return ProviderError("rate_limit", "http_429")
    if code in (400, 422):
        return ProviderError("bad_request", "http_%d" % code)
    if code == 402:
        return ProviderError("billing", "http_402")
    if code in (401, 403):
        return ProviderError("auth", "http_%d" % code)
    if code == 404:
        return ProviderError("not_found", "http_404")
    if code == 408:
        return ProviderError("timeout", "http_408")
    if code >= 500:
        return ProviderError("server", "http_%d" % code)
    return ProviderError("error", "http_%d" % code)


def _post(url, body, headers):
    rq = _http()
    o = _opts()
    try:
        r = rq.post(url, json=body, headers=headers,
                    timeout=(5, o.get("timeout", 45)))
    except Exception as e:  # noqa: BLE001
        name = type(e).__name__.lower()
        raise ProviderError("timeout" if "timeout" in name else "connection", type(e).__name__)
    if r.status_code != 200:
        raise _status_error(r.status_code)
    try:
        return r.json()
    except Exception:
        raise ProviderError("server", "bad_json")


def _call_gemini(key, model, system, prompt, max_tokens, history=None):
    contents = []
    for m in _messages(history, prompt):
        contents.append({"role": "model" if m["role"] == "assistant" else "user",
                         "parts": [{"text": m["content"]}]})
    gen = {"maxOutputTokens": int(max_tokens)}
    if model.startswith("gemini-2.5") and _opts().get("klass") == "cheap":
        gen["thinkingConfig"] = {"thinkingBudget": 0}     # cheap tasks: no thinking
    body = {"systemInstruction": {"parts": [{"text": system}]},
            "contents": contents, "generationConfig": gen}
    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
           % model)
    r = _post(url, body, {"x-goog-api-key": key, "content-type": "application/json"})
    if (r.get("promptFeedback") or {}).get("blockReason"):
        raise ProviderError("refusal", "blocked")
    cands = r.get("candidates") or []
    if cands and str(cands[0].get("finishReason", "")).upper() in (
            "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"):
        raise ProviderError("refusal", cands[0].get("finishReason", ""))
    text = ""
    if cands:
        text = "".join(p.get("text", "") for p in
                       ((cands[0].get("content") or {}).get("parts") or [])
                       if not p.get("thought"))
    u = r.get("usageMetadata") or {}
    cached = int(u.get("cachedContentTokenCount", 0) or 0)
    itok = max(0, int(u.get("promptTokenCount", 0) or 0) - cached)
    otok = int(u.get("candidatesTokenCount", 0) or 0) + int(u.get("thoughtsTokenCount", 0) or 0)
    return text, itok, otok, {"cache_read": cached, "cache_write": 0, "model": model}


def _call_openai(key, model, system, prompt, max_tokens, history=None):
    body = {"model": model,
            "messages": [{"role": "system", "content": system}] + _messages(history, prompt),
            "max_completion_tokens": int(max_tokens)}
    r = _post("https://api.openai.com/v1/chat/completions", body,
              {"authorization": "Bearer %s" % key, "content-type": "application/json"})
    choices = r.get("choices") or []
    if not choices:
        raise ProviderError("empty")
    msg = choices[0].get("message") or {}
    if msg.get("refusal") or choices[0].get("finish_reason") == "content_filter":
        raise ProviderError("refusal")
    u = r.get("usage") or {}
    cached = int(((u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)) or 0)
    itok = max(0, int(u.get("prompt_tokens", 0) or 0) - cached)
    return (msg.get("content") or ""), itok, int(u.get("completion_tokens", 0) or 0), \
        {"cache_read": cached, "cache_write": 0, "model": model}


def _classify(e):
    if isinstance(e, ProviderError):
        return e
    try:
        import anthropic
        if isinstance(e, anthropic.APIError):
            return _anthropic_error(e)
    except ImportError:
        pass
    name = type(e).__name__.lower()
    if "timeout" in name:
        return ProviderError("timeout", type(e).__name__)
    if "connection" in name:
        return ProviderError("connection", type(e).__name__)
    return ProviderError("error", type(e).__name__)


def _unpack(res, model):
    """Provider seam result -> (text, in, out, cache_read, cache_write, model).
    Accepts the legacy 3-tuple (tests) or the 4-tuple with an extras dict."""
    text, itok, otok = res[0], int(res[1] or 0), int(res[2] or 0)
    extra = res[3] if len(res) > 3 and isinstance(res[3], dict) else {}
    used = extra.get("model") or model
    return (text or ""), itok, otok, int(extra.get("cache_read", 0) or 0), \
        int(extra.get("cache_write", 0) or 0), used


# ------------------------------------------------------------------ health
def health_probe(name, key, timeout=10):
    """Free reachability + auth check (list-models endpoints; no tokens).
    Returns (ok, detail)."""
    try:
        if name == "anthropic":
            client = _anthropic_client(key, timeout)
            client.models.list(limit=1)
            return True, "ok"
        rq = _http()
        if name == "openai":
            r = rq.get("https://api.openai.com/v1/models",
                       headers={"authorization": "Bearer %s" % key}, timeout=timeout)
        else:
            r = rq.get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1",
                       headers={"x-goog-api-key": key}, timeout=timeout)
        if r.status_code == 200:
            return True, "ok"
        return False, "http_%d" % r.status_code
    except Exception as e:  # noqa: BLE001
        return False, _classify(e).kind


# ------------------------------------------------------------------ generate
def generate(task, data="", tier="cheap", max_tokens=800, feature="", user=None,
             extra_system="", history=None, charge_action=None, digits=None,
             task_class=None):
    """Run one AI job through the router. `task` is the trusted instruction;
    `data` is untrusted user content (wrapped safely). `history` is optional
    prior {"role","content"} turns. `digits='bn'` returns Bangla digits.
    `task_class` ('main'|'cheap') overrides the feature/tier mapping.
    Returns (text, cost_usd). Raises AIUnavailable('no_key'|'budget'|
    'user_limit'|'credits'|'queued') — callers show a clean Bangla state."""
    from . import ai_router as R
    providers = _providers()
    if not providers:
        raise AIUnavailable("no_key")
    conf = R.cfg()
    if R.total_capped(conf):
        raise AIUnavailable("budget")
    if _user_over_limit(user):
        raise AIUnavailable("user_limit")
    # Plan credits: config-driven, per-model-TIER cost (never per provider),
    # ATOMIC pre-charge; refunded below if no provider answers.
    charged = 0
    spend_ref = ""
    if user is not None:
        from . import billing
        from .logic import pricing
        # Profit-guard model-downgrade hook: a FREE user's action under a
        # 'near' guard drops one rung (strong->medium->cheap).
        tier = billing.effective_tier(user, tier)
        action = pricing.TIER_ACTION.get(tier, "ai_msg_cheap")
        if charge_action:      # e.g. web_answer prices search + LLM as one action
            action = charge_action
        res = billing.charge(user, action, qty=1, note=feature or action)
        if not res["ok"]:
            raise AIUnavailable("budget" if res.get("reason") == "guard_over"
                                else "credits")
        charged = res["charged"]
        spend_ref = res.get("spend_ref", "")

    klass = task_class if task_class in C.CLASSES else C.task_class(tier, feature, conf)
    keys = dict(providers)
    order = [p for p in C.ORDER[klass] if p in keys]
    system = P.system_prompt(extra_system)
    prompt = task + (f"\n\n<data>\n{data}\n</data>" if data else "")
    opts = {"timeout": conf["timeouts_s"][klass], "klass": klass,
            "effort": C.effort_for(conf, tier, klass),
            "server_fallback": conf["server_fallback"]}

    attempts = []
    skipped_cap = 0
    stop_kind = ""
    t_all = _time.monotonic()
    for name in order:
        if R.provider_capped(name, conf):
            attempts.append(name + ":cap")
            skipped_cap += 1
            continue
        if not R.allow(name, conf):
            attempts.append(name + ":circuit")
            continue
        model = C.model_for(conf, name, tier, klass)
        fn = globals()["_call_" + name]
        token = _CALL_OPTS.set(opts)
        t0 = _time.monotonic()
        try:
            out = fn(keys[name], model, system, prompt, max_tokens, history=history)
            text, itok, otok, cr, cw, used = _unpack(out, model)
            text = P.normalize_output(text, digits)
            if not text:
                raise ProviderError("empty")
        except Exception as e:  # noqa: BLE001 — classified below
            err = _classify(e)
            attempts.append("%s:%s" % (name, err.kind))
            if err.circuit:
                R.record(name, False, conf, error=err.kind)
            if not err.failover:
                log.error("ai: %s %s bad request (no failover): %s", name, model, err.detail)
                stop_kind = err.kind
                break
            continue
        finally:
            _CALL_OPTS.reset(token)
        latency = int((_time.monotonic() - t0) * 1000)
        R.record(name, True, conf, slow=latency > conf["slow_ms"][klass])
        cost = C.cost_usd(conf, used, itok, otok, cr, cw)
        hops = len(attempts)
        attempts.append(name + ":ok")
        AIUsage.objects.create(
            user=user, feature=(feature or "")[:40], model=used[:40],
            input_tokens=itok, output_tokens=otok, cost_usd=cost,
            provider=name, tier=tier, task_class=klass, latency_ms=latency,
            ok=True, hops=hops, attempts="|".join(attempts)[:240],
            cache_read_tokens=cr, cache_write_tokens=cw)
        try:
            from . import billing
            billing.record_ai_cost_usd(cost)     # Profit Guard (USD -> ৳ ledger)
        except Exception:
            pass
        R.check_alerts(conf)
        return text, cost

    # every provider failed / was skipped -> honest state, never a fake answer
    all_capped = bool(order) and skipped_cap == len(order)
    kind = "budget" if all_capped else (stop_kind or "all_failed")
    try:
        AIUsage.objects.create(
            user=user, feature=(feature or "")[:40], model="", cost_usd=0.0,
            tier=tier, task_class=klass, ok=False, hops=len(attempts),
            attempts="|".join(attempts)[:240], error_kind=kind[:30],
            latency_ms=int((_time.monotonic() - t_all) * 1000))
    except Exception:
        pass
    if user is not None and charged:
        from . import billing
        # billing-v2 rule N: back to the SAME bucket(s) the charge came from
        billing.credit(user, "adjust", charged, note="ai_refund", spend_ref=spend_ref)
    raise AIUnavailable("budget" if all_capped else "queued")


def status():
    """Public (AllowAny) AI state — provider-neutral on purpose."""
    return {
        "enabled": key_present() or bool(_providers()),
        "available": available(),
        "today_spend_usd": round(_today_spend(), 4),
        "daily_budget_usd": daily_budget_usd(),
    }
