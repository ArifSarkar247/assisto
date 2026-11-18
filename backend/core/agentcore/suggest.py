"""agentcore: proactive AGENT CARDS (flag `agent_core`) + number checks.

A proactive trigger may PROPOSE one own-data action on its card. v1: a bill /
loan due (bill_due, today .. in 2 days, no phone reminder yet) -> "Set a
reminder?". The proposal is a code-planned run (0 credits, no AI) whose single
step ALWAYS waits for the user's one tap, even though a reminder is an
own-data write — the agent started it, not the user. Nothing happens on its
own: Approve -> the reminder is created; Not now -> nothing is done; no
decision -> the card expires at the time the reminder would have rung.

NUMBER CHECKS: every amount / date a card shows is re-derived from the user's
real rows before it is shown (verify_nudges) and again right before an
approved action runs (still_true). A bill paid, settled or changed since the
nudge -> the card is hidden and its proposal expires (audit guard.stale);
the action never runs on an old number.
"""
from datetime import datetime, time, timedelta

from django.db import transaction
from django.utils import timezone

from ..ai_prompt import to_bn_digits
from . import trust as T

log = T.logger(__name__)

TOOL = "reminders.create"
TOPIC = "money"
CLIENT_PREFIX = "proactive:"      # AgentGoal.client_id of a proactive run (not user-settable)
REMIND_AT = time(9, 0)            # due day, 09:00 local
LATEST_HOUR = 22                  # a "today" reminder is never proposed for the night
# triggers whose cards are re-checked against the live rows before showing
# (child_not_home = safety: its own sweep owns it, it is never hidden here)
VERIFIED = ("bill_due", "remit_missing", "stock_low", "order_unpaid", "meter_low", "camera_alert")


def bill_ref(key):
    """'loan:ab12:2026-11-19:tomorrow' -> 'loan:ab12:2026-11-19' (the bill, any stage)."""
    return ":".join(str(key or "").split(":")[:3])


def _pick(lang, bn, en):
    return bn if lang == "bn" else en


def _money(v, lang):
    from . import proactive as P
    return P._money(v, lang)


def _lang(user):
    la = getattr(user, "language", "bn")
    return la if la in ("bn", "en") else "bn"


def fresh_bills(user, now):
    """{bill ref: amount left} from the user's REAL rows right now."""
    from . import proactive as P
    today = timezone.localdate(now)
    return {"%s:%s:%s" % (kind, P._hash(rid), due.isoformat()): round(float(amount), 2)
            for kind, rid, _name, amount, due, _rem in P._bill_rows(user, today, _lang(user))}


def still_true(user, verify, now):
    """The bill a proposal was made for is still unpaid with the same amount."""
    if not isinstance(verify, dict) or not verify.get("ref"):
        return False
    try:
        amt = fresh_bills(user, now).get(verify["ref"])
    except Exception as e:  # noqa: BLE001 — unverifiable = never act
        log.warning("agentcore: verify failed %s", type(e).__name__)
        return False
    return amt is not None and abs(amt - float(verify.get("amount") or 0)) < 0.01


# ------------------------------------------------------------------ proposal
def _remind_at(due_iso, days, now):
    local = timezone.localtime(now)
    due = datetime.strptime(due_iso, "%Y-%m-%d").date()
    if days == 0:
        at = (local + timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)
        if at.date() != due or at.hour >= LATEST_HOUR:
            return None
        return at
    at = timezone.make_aware(datetime.combine(due, REMIND_AT), timezone.get_current_timezone())
    return at if at > local + timedelta(minutes=30) else None


def _texts(kind, name, amount, at, lang):
    amt = _money(amount, lang)
    if kind == "loan":
        title = _pick(lang, "ধার শোধ: %s — %s" % (name, amt), "Repay loan: %s — %s" % (name, amt))
    else:
        title = _pick(lang, "বিল দিন: %s — %s" % (name, amt), "Pay bill: %s — %s" % (name, amt))
    when = at.strftime("%d/%m %H:%M")
    ask_bn = "রিমাইন্ডার সেট করব? “%s” — %s" % (title, to_bn_digits(when))
    ask_en = "Set a reminder? “%s” — %s" % (title, when)
    return title, ask_bn, ask_en


def propose(user, nudge, cand, now=None):
    """bill_due nudge -> a pending approval for ONE reminder (or None).
    Idempotent per bill: a bill already proposed at an earlier stage is not
    proposed again. Never raises (a nudge is never lost to this)."""
    try:
        return _propose(user, nudge, cand, now or timezone.now())
    except Exception as e:  # noqa: BLE001
        log.warning("agentcore: proposal failed for nudge %s: %s", getattr(nudge, "pk", None),
                    type(e).__name__)
        return None


def _propose(user, nudge, cand, now):
    from ..models import AgentGoal, AgentNudge, AgentRun, AgentStep
    from . import runner as RN
    from . import tools as TL
    if nudge is None or cand.trigger != "bill_due":
        return None
    d = cand.data or {}
    if d.get("phone_reminder") or int(d.get("days", -1)) < 0 or "amount" not in d:
        return None
    ctx = RN.Ctx(user=user, now=now, lang=_lang(user))
    if TOOL not in {t.name for t in TL.available(ctx, (TOOL,))}:
        return None
    ref = bill_ref(cand.key)
    if AgentNudge.objects.filter(user=user, trigger="bill_due", dedupe_key__startswith=ref + ":",
                                 data__has_key="approval").exclude(pk=nudge.pk).exists():
        return None
    at = _remind_at(d["due"], int(d["days"]), now)
    if at is None:
        return None
    lang = _lang(user)
    title, ask_bn, ask_en = _texts(d.get("kind"), d.get("name") or "", d["amount"], at, lang)
    args = {"title": title, "due_at": at.isoformat(),
            "notes": _pick(lang, cand.why_bn, cand.why_en)[:500]}
    tool = TL.get(TOOL)
    from .contract import validate
    validate(args, tool.input_schema)
    vault = T.Vault()
    with transaction.atomic():
        goal = AgentGoal.objects.create(
            user=user, topic=TOPIC, channel="notification",
            text_sealed=T.seal({"t": ask_en}), text_masked=vault.mask(ask_en)[:600],
            client_id=(CLIENT_PREFIX + str(nudge.pk))[:64])
        run = AgentRun(goal=goal, user=user, topic=TOPIC, max_steps=1, max_llm_calls=0,
                       max_credits=0, deadline_at=at + timedelta(hours=1))
        T.save_vault(run, vault)
        run.save()
        T.audit(run, "run.created", topic=TOPIC, channel="notification",
                goal=vault.mask(ask_en)[:300], proactive=nudge.trigger, nudge=nudge.pk)
        plan = {"v": 1, "steps": [{"tool": TOOL}], "done": True, "answer": None, "pre": "proactive"}
        p = AgentStep.objects.create(run=run, no=1, kind="plan", idem_key="ac:%d:1" % run.pk,
                                     state="done", result_sealed=T.seal({"plan": plan}),
                                     summary=TOOL, finished_at=now)
        AgentStep.objects.create(
            run=run, no=2, kind="tool", tool=tool.name, tool_version=tool.version, risk=tool.risk,
            idem_key="ac:%d:2" % run.pk, summary=tool.label_en,
            args_sealed=T.seal({"a": vault.mask_obj(args), "ask": True,
                                "ask_title": [vault.mask(ask_bn), vault.mask(ask_en)],
                                "expires": at.isoformat(),
                                "verify": {"ref": ref, "amount": round(float(d["amount"]), 2)}}))
        T.audit(run, "plan.ok", step=p, credits=0, tools=[TOOL], done=True, preplanned="proactive")
        T.save_vault(run, vault)
        run.save(update_fields=["vault_sealed", "updated_at"])
    RN.advance(run, lang=lang)
    ap = run.approvals.first()
    nudge.data = dict(nudge.data or {}, approval=ap.pk if ap else None, run=run.pk)
    if ap is not None:
        nudge.route = "agent"           # the push opens the card, not the Money page
    nudge.save(update_fields=["data", "route"])
    return ap


# ------------------------------------------------------------------ card checks
def _expire_proposal(nudge, why):
    from ..models import AgentApproval
    apid = (nudge.data or {}).get("approval")
    if not apid:
        return
    ap = AgentApproval.objects.filter(pk=apid, user_id=nudge.user_id, status="pending").first()
    if ap is None:
        return
    ap.status, ap.decided_at = "expired", timezone.now()
    ap.save(update_fields=["status", "decided_at"])
    T.audit(ap.run, "guard.stale", step=ap.step, why=why)
    T.audit(ap.run, "approval.expired", step=ap.step)
    from ..models import AgentRun
    if ap.run.state in AgentRun.OPEN_STATES:
        ap.step.state, ap.step.error_code = "rejected", "stale_data"
        ap.step.finished_at = timezone.now()
        ap.step.save(update_fields=["state", "error_code", "finished_at"])
        from . import runner as RN
        RN._finish(ap.run, "done", "stale_data", answer=_pick(
            _lang(ap.run.user), "তথ্য বদলে গেছে — কিছু করা হয়নি।", "The data changed — nothing was done."))


def verify_nudges(user, rows, now=None):
    """-> the rows that still match the user's real data, their texts
    refreshed from a fresh evaluation. A stale card is left out and its
    proposal expires. Sets n._verified for nudge_out."""
    from . import proactive as P
    now = now or timezone.now()
    lang = _lang(user)
    fresh = {}
    out = []
    for n in rows:
        if n.trigger not in VERIFIED:
            n._verified = None              # safety / brief: not a number card
            out.append(n)
            continue
        if n.trigger not in fresh:
            try:
                fresh[n.trigger] = P.EVALUATORS[n.trigger](user, now, lang)
            except Exception as e:  # noqa: BLE001 — unverifiable: shown, marked unchecked
                log.warning("agentcore: verify %s failed %s", n.trigger, type(e).__name__)
                fresh[n.trigger] = None
        cands = fresh[n.trigger]
        if cands is None:
            n._verified = False
            out.append(n)
            continue
        if n.trigger == "bill_due":
            ref = bill_ref(n.dedupe_key)
            match = next((c for c in cands if bill_ref(c.key) == ref and abs(
                float((c.data or {}).get("amount", -1)) - float((n.data or {}).get("amount", -2))) < 0.01),
                None)
            if match is None and "amount" not in (n.data or {}):
                match = next((c for c in cands if bill_ref(c.key) == ref), None)   # older row
        else:
            match = next((c for c in cands if c.key[:120] == n.dedupe_key), None)
        if match is None:
            # not shown (not "dismissed": that is the user's own action in the
            # owner stats); a newer card for the new numbers comes with the next pass
            _expire_proposal(n, "changed")
            continue
        n.title_bn, n.title_en = match.title_bn[:200], match.title_en[:200]
        n.body_bn, n.body_en = match.body_bn, match.body_en
        n._verified = True
        out.append(n)
    return out


def card_action(n, lang):
    """The proposal block of a nudge card, or None."""
    from ..models import AgentApproval
    apid = (n.data or {}).get("approval")
    if not apid:
        return None
    ap = AgentApproval.objects.filter(pk=apid, user_id=n.user_id).select_related("run", "step").first()
    if ap is None:
        return None
    status = ap.status
    if status == "pending" and ap.expires_at <= timezone.now():
        status = "expired"
    vault = T.vault_of(ap.run)
    args = vault.unmask_obj(T.unseal(ap.step.args_sealed).get("a") or {})
    from . import runner as RN
    st = ap.step.state
    done = status == "approved" and st == "done"
    return {"approval_id": ap.pk, "run": ap.run_id, "status": status,
            "title": vault.unmask(_pick(lang, ap.title_bn, ap.title_en)),
            "reminder_title": args.get("title") or "", "due_at": args.get("due_at") or "",
            "expires_at": ap.expires_at.isoformat(),
            "done": done, "result": RN.answer_of(ap.run) if ap.run.state == "done" else "",
            "error": ap.step.error_code or ""}
