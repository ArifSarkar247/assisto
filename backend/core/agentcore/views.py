"""Agent Core API (/api/v1/agent-core/...), flag `agent_core` (default OFF:
every endpoint answers 403 feature_off). Token auth; a user only ever sees
their own goals, runs, steps and approvals.

  GET  agent-core/tools                  tool contracts per topic (versioned)
  POST agent-core/goals                  {text, topic?, channel?, client_id?} -> run
  GET  agent-core/runs                   my last 20 runs
  GET  agent-core/runs/<id>              run + steps + readable audit trail
  POST agent-core/runs/<id>/cancel
  POST agent-core/runs/<id>/feedback     {value: 1|-1, note?}
  GET  agent-core/approvals              my pending approvals (foreground poll)
  POST agent-core/approvals/<id>         {decision: approve|reject}
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..i18n import is_play_flavour, pick, req_lang
from . import runner as RN
from . import tools as TL
from . import topics as TP
from . import trust as T

_ERR = {
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
    "bad_goal": ("কী করতে হবে লিখুন (১০০০ অক্ষরের মধ্যে)।", "Write what to do (up to 1000 characters)."),
    "daily_cap": ("আজকের এজেন্ট-কাজের সীমা পূর্ণ — কাল আবার চেষ্টা করুন।",
                  "Today's agent task limit is reached — please try tomorrow."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "bad_decision": ("অনুমোদন বা বাতিল বেছে নিন।", "Choose approve or reject."),
    "bad_input": ("তথ্যগুলো ঠিক নেই।", "Some details are not right."),
}

_ERROR_TEXT = {
    "credits": ("ক্রেডিট শেষ — ক্রেডিট নিয়ে আবার চেষ্টা করুন।", "Out of credits — top up and try again."),
    "guard_over": ("আজ AI কাজ সাময়িক বন্ধ — কাল আবার চেষ্টা করুন।", "AI tasks are paused today — try tomorrow."),
    "ai_no_key": ("এজেন্ট এখনো চালু হয়নি।", "The agent is not switched on yet."),
    "ai_budget": ("AI এখন ব্যস্ত — একটু পরে চেষ্টা করুন।", "AI is busy right now — try a little later."),
    "ai_queued": ("AI এখন সাড়া দিচ্ছে না — একটু পরে চেষ্টা করুন।", "AI is not answering — try a little later."),
    "ai_credits": ("ক্রেডিট শেষ — ক্রেডিট নিয়ে আবার চেষ্টা করুন।", "Out of credits — top up and try again."),
    "ai_user_limit": ("আজকের AI সীমা পূর্ণ।", "Today's AI limit is reached."),
    "invalid_plan": ("কাজটি বুঝতে পারিনি — একটু অন্যভাবে লিখুন।", "I could not plan that — please rephrase."),
    "steps": ("কাজটি অনেক বড় — ছোট করে দিন।", "The task is too big — please split it."),
    "credits_cap": ("এই কাজের ক্রেডিট-সীমা পূর্ণ।", "This task reached its credit limit."),
    "llm_calls": ("কাজটি অনেক বড় — ছোট করে দিন।", "The task is too big — please split it."),
    "deadline": ("সময় শেষ হয়ে গেছে।", "The task timed out."),
}


def _err(lang, code, status=400):
    bn, en = _ERR.get(code, _ERR["bad_input"])
    return Response({"error": code, "detail": pick(lang, bn, en)}, status=status)


class _Gated(APIView):
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not RN.flag_on(request.user, is_play_flavour(request)):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied(detail={"error": "feature_off",
                                           "detail": pick(req_lang(request), *_ERR["feature_off"])})

    def handle_exception(self, exc):
        if isinstance(exc, RN.AgentError):
            return _err(req_lang(self.request), exc.code, exc.status)
        return super().handle_exception(exc)


def _run_out(run, lang, detail=False):
    vault = T.vault_of(run)
    code = run.error_code
    if run.state == "budget" and code == "credits":
        code = "credits_cap"
    msg = _ERROR_TEXT.get(code)
    pair = RN.topics_of(run)
    d = {"id": run.id, "state": run.state, "topic": run.topic or "general",
         "topic_label": " + ".join(TP.label(k, lang) for k in pair),
         # AF-11: one or two topics, each with its explicit may / may-not line
         "topics": RN.topic_scopes(run, lang),
         "scope_title": TP.SCOPE_TITLE["bn" if lang == "bn" else "en"],
         "goal": vault.unmask(run.goal.text_masked),
         "answer": RN.answer_of(run) if run.state == "done" else "",
         # AF-1: what the answer stands on + whether its numbers were checked
         "sources": RN.answer_sources(run, lang) if run.state == "done" else [],
         "answer_check": RN.answer_check(run),
         "error": code, "error_text": pick(lang, *msg) if msg else "",
         "credits": run.credits_spent, "steps": run.steps_used,
         "created_at": run.created_at.isoformat(),
         "finished_at": run.finished_at.isoformat() if run.finished_at else None,
         "feedback": run.feedback,
         "approvals": [_ap_out(a, lang) for a in run.approvals.filter(status="pending")]}
    cr = RN.crisis_of(run)
    if cr:
        # AF-3: the helpline card + the (never automatic) "tell my family" offer
        from . import crisis_guard as CG
        d["crisis"] = CG.respond(run.user, cr, lang, surface="agent", event_id="run:%d" % run.id)[1]
    if detail:
        d["trail"] = [{"no": s.no, "kind": s.kind, "tool": s.tool, "state": s.state,
                       "risk": s.risk, "summary": vault.unmask(s.summary),
                       "credits": s.credits, "error": s.error_code}
                      for s in run.steps.order_by("no")]
    return d


def _partial(kind, value):
    """WP-APP: an approval card names WHO/WHAT, but a number is shown partly
    hidden (017•••••678, ••••4321, a•••@mail.com) — enough to recognise."""
    v = str(value)
    if kind == "EMAIL" and "@" in v:
        name, dom = v.split("@", 1)
        return (name[:1] + "•••@" + dom) if name else v
    digits = [c for c in v if c.isdigit()]
    if kind == "PHONE" and len(digits) >= 6:
        return "".join(digits[:3]) + "•••••" + "".join(digits[-3:])
    if len(digits) >= 4:
        return "••••" + "".join(digits[-4:])
    return "••••"


def _ap_details(a, vault):
    """What exactly the step will do: its arguments as [{key, value}], with
    phone / NID / account / e-mail tokens shown partly hidden."""
    try:
        args = T.unseal(a.step.args_sealed).get("a") or {}
    except Exception:
        return []
    out = []
    for k, v in list(args.items())[:12]:
        if not isinstance(v, str):
            import json as _json
            v = _json.dumps(v, ensure_ascii=False)
        v = T.TOKEN_RX.sub(lambda m: _partial(m.group(1), vault.t2v.get(m.group(0), "")), v)
        out.append({"key": str(k)[:40], "value": v[:300]})
    return out


def _ap_out(a, lang):
    vault = T.vault_of(a.run)
    tool = TL.get(a.step.tool) if a.step_id else None
    return {"id": a.id, "run": a.run_id, "risk": a.risk, "status": a.status,
            "title": vault.unmask(pick(lang, a.title_bn, a.title_en)),
            "expires_at": a.expires_at.isoformat(),
            # WP-APP: the card shows what will be done and what it costs
            "tool": a.step.tool if a.step_id else "",
            "tool_label": pick(lang, tool.label_bn, tool.label_en) if tool else "",
            "credits": int(tool.credits) if tool else 0,
            "details": _ap_details(a, vault),
            "goal": vault.unmask(a.run.goal.text_masked) if a.run.goal_id else ""}


def _estimate(user):
    """WP-APP: the credit cost shown BEFORE a goal runs (owner rule). One
    planner call is the usual task; the run's credit cap is the hard ceiling."""
    from .. import billing
    from ..logic import pricing
    from ..models import AgentRun
    from django.utils import timezone
    from . import planner as PL
    lim = RN.limits_for(user)
    try:
        plan = int(pricing.credit_cost(PL.CHARGE_ACTION, billing.cfg()))
    except Exception:
        plan = 0
    day0 = timezone.localtime().replace(hour=0, minute=0, second=0, microsecond=0)
    used = AgentRun.objects.filter(user=user, created_at__gte=day0).count()
    return {"plan_credits": plan, "typical_credits": plan,
            "max_credits": int(lim["credits"]),
            "runs_per_day": int(lim["runs_per_day"]),
            "runs_left_today": max(0, int(lim["runs_per_day"]) - used)}


class ToolsView(_Gated):
    def get(self, request):
        return Response({"version": 1, "estimate": _estimate(request.user),
                         "topics": {k: {"label": TP.label(k, req_lang(request)),
                                        "tools": list(v["tools"])} for k, v in TP.TOPICS.items()},
                         "tools": [t.spec() for t in TL.TOOLS]})


class GoalsView(_Gated):
    def post(self, request):
        lang = req_lang(request)
        b = request.data if isinstance(request.data, dict) else {}
        run = RN.start(request.user, str(b.get("text") or ""), topic=str(b.get("topic") or ""),
                       channel=str(b.get("channel") or "chat"),
                       client_id=str(b.get("client_id") or ""), lang=lang,
                       play=is_play_flavour(request))
        return Response(_run_out(run, lang, detail=True), status=201)


class RunsView(_Gated):
    def get(self, request):
        from ..models import AgentRun
        lang = req_lang(request)
        rows = AgentRun.objects.filter(user=request.user).select_related("goal")[:20]
        return Response({"runs": [_run_out(r, lang) for r in rows]})


def _my_run(request, pk):
    from ..models import AgentRun
    run = AgentRun.objects.filter(pk=pk, user=request.user).select_related("goal").first()
    if run is None:
        raise RN.AgentError("not_found", 404)
    return run


class RunView(_Gated):
    def get(self, request, pk):
        return Response(_run_out(_my_run(request, pk), req_lang(request), detail=True))


class RunCancelView(_Gated):
    def post(self, request, pk):
        _my_run(request, pk)
        run = RN.cancel(request.user, pk)
        return Response(_run_out(run, req_lang(request), detail=True))


class RunFeedbackView(_Gated):
    def post(self, request, pk):
        run = _my_run(request, pk)
        b = request.data if isinstance(request.data, dict) else {}
        try:
            v = int(b.get("value"))
        except (TypeError, ValueError):
            v = 0
        if v not in (1, -1):
            raise RN.AgentError("bad_input")
        run.feedback = v
        run.feedback_note = T.vault_of(run).mask(str(b.get("note") or ""))[:300]
        run.save(update_fields=["feedback", "feedback_note", "updated_at"])
        T.audit(run, "run.feedback", value=v)
        try:
            # AF-12: a thumbs-down becomes a candidate eval case (masked) for
            # the owner's review queue; a thumbs-up withdraws a pending one
            from . import feedback_cases as FB
            FB.on_feedback(run, v, run.feedback_note)
        except Exception:  # noqa: BLE001 — feedback is never refused for this
            import logging
            logging.getLogger(__name__).exception("agentcore: feedback case for run %s", run.pk)
        return Response({"ok": True, "feedback": v})


class ApprovalsView(_Gated):
    def get(self, request):
        from ..models import AgentApproval
        lang = req_lang(request)
        rows = (AgentApproval.objects.filter(user=request.user, status="pending")
                .select_related("run", "run__goal", "step")[:20])
        return Response({"approvals": [_ap_out(a, lang) for a in rows]})


class ApprovalView(_Gated):
    def post(self, request, pk):
        lang = req_lang(request)
        b = request.data if isinstance(request.data, dict) else {}
        ap, run = RN.decide(request.user, pk, str(b.get("decision") or ""), lang=lang,
                            play=is_play_flavour(request))
        return Response({"approval": _ap_out(ap, lang), "run": _run_out(run, lang, detail=True)})
