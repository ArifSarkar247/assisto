"""ai-router: Owner Admin → AI. Provider status (circuit closed / open /
half-open, last health check), today's spend vs the per-provider and total
caps, calls, failovers, the model used for each job, the router settings
(bounded, bn/en labels, every save audited) and the latest offline Bangla
quality probe side by side. Owner-only — the app never sees any of this."""
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page

AUDIT_ACTION = "ai.router"


def _lang(request):
    return getattr(request, "owner_lang", "bn")


def _lbl(pair, lang):
    return pair[0] if lang == "bn" else pair[1]


def _patch_from_post(post, conf):
    """Owner form -> raw ai_router block (validated before normalize)."""
    from core import ai_config as C
    raw = {"models": {}, "effort": {}, "caps_usd": {}, "timeouts_s": {}, "slow_ms": {},
           "circuit": {}, "prices": {}}
    for slot in C.MODEL_SLOTS:
        v = post.get("m_" + slot)
        if v is not None:
            raw["models"][slot] = v.strip()
    for t in C.TIERS:
        v = post.get("eff_" + t)
        if v is not None:
            raw["effort"][t] = v.strip()
    for k in ("anthropic", "openai", "gemini", "total"):
        v = post.get("cap_" + k)
        if v is not None and v.strip() != "":
            raw["caps_usd"][k] = v.strip().replace(",", "")
    if post.get("alert_pct", "").strip():
        raw["alert_pct"] = post.get("alert_pct").strip()
    for c in C.CLASSES:
        if post.get("to_" + c, "").strip():
            raw["timeouts_s"][c] = post.get("to_" + c).strip()
        if post.get("slow_" + c, "").strip():
            raw["slow_ms"][c] = post.get("slow_" + c).strip()
    for k in conf["circuit"]:
        if post.get("cb_" + k, "").strip():
            raw["circuit"][k] = post.get("cb_" + k).strip()
    raw["server_fallback"] = post.get("server_fallback") == "on"
    if "main_features" in post:
        raw["main_features"] = post.get("main_features", "")
    for m in conf["prices"]:
        row = {}
        for k in C.PRICE_KEYS:
            v = post.get("p_%s_%s" % (m, k))
            if v is not None and v.strip() != "":
                row[k] = v.strip()
        if row:
            raw["prices"][m] = row
    nm = (post.get("new_model") or "").strip().lower()
    if nm:
        raw["prices"][nm] = {k: (post.get("new_" + k) or "0").strip() for k in C.PRICE_KEYS}
    # merge onto the current block so untouched sections keep their values
    merged = {k: (dict(v) if isinstance(v, dict) else v) for k, v in conf.items()}
    for k, v in raw.items():
        if isinstance(v, dict) and isinstance(merged.get(k), dict):
            if k == "prices":
                for m, row in v.items():
                    merged["prices"][m] = dict(merged["prices"].get(m, {}), **row)
            else:
                merged[k].update(v)
        else:
            merged[k] = v
    return raw, merged


def _jobs(conf, lang):
    """'Which model does which job' table (owner view only)."""
    from core import ai_config as C
    rows = []
    for key, tier, klass, bn, en in (
            ("chat", "cheap", "main", "চ্যাট, সহকারী, এজেন্টের উত্তর", "Chat, assistant, agent replies"),
            ("medium", "medium", "main", "লম্বা লেখা (CV, প্রস্তাব, স্টুডিও)", "Longer writing (CV, proposals, studio)"),
            ("strong", "strong", "main", "জটিল / এজেন্টের কাজ", "Complex / agent work"),
            ("cheap", "cheap", "cheap", "সস্তা কাজ: শ্রেণিবিন্যাস, ছোট উত্তর, সারাংশ, তথ্য বের করা",
             "Cheap: classify, short replies, summaries, extraction")):
        chain = []
        for p in C.ORDER[klass]:
            m = C.model_for(conf, p, tier, klass)
            eff = C.effort_for(conf, tier, klass) if p == "anthropic" else ""
            chain.append({"provider": p, "model": m, "effort": eff})
        rows.append({"key": key, "label": bn if lang == "bn" else en, "klass": klass,
                     "chain": chain})
    return rows


def _probe(lang):
    from core.models import AIQualityProbe
    last = AIQualityProbe.objects.order_by("-created_at").first()
    if not last:
        return None
    rows = {}
    for r in AIQualityProbe.objects.filter(run_id=last.run_id).order_by("prompt_no", "provider"):
        e = rows.setdefault(r.prompt_no, {"no": r.prompt_no + 1, "prompt": r.prompt, "answers": []})
        e["answers"].append(r)
    return {"run_id": last.run_id, "at": last.created_at,
            "rows": [rows[k] for k in sorted(rows)]}


@require_http_methods(["GET", "POST"])
@owner_view()
def ai_page(request):
    from core import ai_config as C
    from core import ai_router as R
    from core.models import AIProviderState
    lang = _lang(request)
    conf = R.cfg()
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        if action == "save":
            raw, merged = _patch_from_post(request.POST, conf)
            problems = C.validate(raw)
            if problems:
                S.audit(request, request.owner, AUDIT_ACTION, "ai_router",
                        after={"rejected": problems}, ok=False)
                ctx["problems"] = problems
                status = 400
            else:
                old, new = R.save_cfg(merged)
                if old == new:
                    return done("/owner/ai", "nothing")
                b, a = diff(old, new)
                S.audit(request, request.owner, AUDIT_ACTION, "ai_router", before=b, after=a)
                return done("/owner/ai")
        elif action == "reset":
            slug = request.POST.get("slug", "")
            if slug not in C.PROVIDERS:
                raise Http404
            AIProviderState.objects.filter(slug=slug).update(
                state="closed", consecutive_failures=0, window_calls=0,
                window_failures=0, opened_at=None, probe_until=None)
            S.audit(request, request.owner, "ai.circuit_reset", "ai:%s" % slug)
            return done("/owner/ai")
        else:
            raise Http404
    dash = R.dashboard(conf)
    slots = []
    for slot, (prov, dflt) in C.MODEL_SLOTS.items():
        slots.append({"slot": slot, "provider": prov, "label": _lbl(C.SLOT_LABELS[slot], lang),
                      "value": conf["models"][slot], "default": dflt,
                      "choices": C.ANTHROPIC_MODELS if prov == "anthropic" else ()})
    used = set(conf["models"].values())
    prices = [{"model": m, "vals": [(k, p.get(k, 0.0)) for k in C.PRICE_KEYS],
               "used": m in used} for m, p in sorted(conf["prices"].items())]
    missing_price = sorted(m for m in used if m not in conf["prices"])
    L = {k: _lbl(v, lang) for k, v in C.LABELS.items()}
    ctx.update({
        "dash": dash, "conf": conf, "slots": slots, "efforts": C.EFFORTS,
        "tiers": C.TIERS, "jobs": _jobs(conf, lang), "prices": prices,
        "missing_price": missing_price, "L": L, "probe": _probe(lang),
        "price_keys": C.PRICE_KEYS,
        "main_features": ", ".join(conf["main_features"]),
        "effort_rows": [(t, L["effort_" + t], conf["effort"][t]) for t in C.TIERS],
        "circuit_fields": [(k, L.get(k, k), v) for k, v in conf["circuit"].items()],
    })
    return page(request, "owner/ai.html", ctx, status=status, nav="ai")
