"""AF-18 — "undo that": take back what the PREVIOUS turn of the conversation
did, deterministically (no AI call, 0 credits).

Only a short undo phrase that is a follow-up of the user's own run finished
in the last runner.FOLLOW_UP_WINDOW counts ("undo that", "ওটা বাতিল করো",
"undo kore dao" ...). It reverses exactly that run's own-data writes — the
records the agent itself made, matched by the step's idempotency key:

  reminders.create -> the reminder it created is deleted
  notes.create     -> the note it created (source agent) is deleted
  money.log        -> the transaction it logged (source agent, ref) is deleted
  stock.adjust     -> the stock change is reversed (never below zero)
  reminders.complete -> the reminder is open again
  memory.remember  -> the still-pending suggestion is rejected

Anything that left the app (a due reminder, a COD confirmation, a chat
reply) or a delete the user approved can NOT be taken back: the answer says
so honestly. A run is undone once (audit undo.done on that run).
"""
import re

from django.db import transaction
from django.db.models import F
from django.utils import timezone

from . import trust as T

UNDO_RX = re.compile(
    r"^\s*(?:(?:please|plz|দয়া করে)\s+)?(?:"
    r"undo(?: (?:that|it|this|the last one))?|cancel (?:that|it)|take (?:that|it) back|revert (?:that|it)|"
    r"ওটা বাতিল করো|ওটা বাতিল করুন|এটা বাতিল করো|আগেরটা বাতিল করো|আগেরটা ফিরিয়ে নাও|ওটা ফিরিয়ে নাও|"
    r"ফিরিয়ে নাও|আনডু করো|"
    r"undo kore dao|undo koro|ota batil koro|agerta batil koro|firiye nao"
    r")\s*[.!।]*\s*$", re.I)
REVERSIBLE = ("reminders.create", "notes.create", "money.log", "stock.adjust", "reminders.complete",
              "memory.remember")
_READ = ("read",)


def is_undo(text):
    return bool(UNDO_RX.match(text or ""))


def _pick(lang, bn, en):
    return bn if lang == "bn" else en


def _one(user, step, out):
    """Reverse one done step. -> (kind, title) or None when nothing changed."""
    from ..models import AuditLog, Note, Product, Reminder, Transaction
    t = step.tool
    if t == "reminders.create" and out.get("created"):
        n = Reminder.objects.filter(pk=out.get("id"), user=user, link__id=step.idem_key).delete()[0]
        return ("reminder", out.get("title") or "") if n else None
    if t == "notes.create" and out.get("created"):
        n = Note.objects.filter(pk=out.get("id"), user=user, source="agent").delete()[0]
        return ("note", out.get("title") or "") if n else None
    if t == "money.log" and out.get("created"):
        n = Transaction.objects.filter(pk=out.get("id"), user=user, source="agent",
                                       ref=step.idem_key[:40]).delete()[0]
        return ("money", str(out.get("amount") or "")) if n else None
    if t == "stock.adjust" and out.get("adjusted") and out.get("delta"):
        with transaction.atomic():
            p = Product.objects.select_for_update().filter(user=user, name=out.get("product")).first()
            if p is None or p.stock - int(out["delta"]) < 0:
                return None
            Product.objects.filter(pk=p.pk).update(stock=F("stock") - int(out["delta"]))
            p.refresh_from_db()
            AuditLog.objects.create(user=user, action="agent.stock_undo",
                                    detail={"idem": step.idem_key, "product": p.name, "product_id": p.id,
                                            "delta": -int(out["delta"]), "after": p.stock})
        return ("stock", p.name)
    if t == "reminders.complete" and out.get("changed"):
        n = Reminder.objects.filter(pk=out.get("id"), user=user, done=True).update(done=False)
        return ("reopened", out.get("title") or "") if n else None
    if t == "memory.remember" and out.get("suggested") and out.get("id"):
        from . import memory as MEM
        try:
            MEM.reject(user, out["id"])
        except Exception:  # noqa: BLE001 — already approved / gone: not undoable here
            return None
        return ("memory", "")
    return None


_DONE = {
    "reminder": ("রিমাইন্ডার “%s” মুছে ফেলা হয়েছে", "deleted the reminder “%s”"),
    "note": ("নোট “%s” মুছে ফেলা হয়েছে", "deleted the note “%s”"),
    "money": ("লেখা হিসাবটি (%s) মুছে ফেলা হয়েছে", "removed the logged entry (%s)"),
    "stock": ("%s-এর স্টক আগের মতো করা হয়েছে", "put %s's stock back"),
    "reopened": ("রিমাইন্ডার “%s” আবার খোলা হয়েছে", "reopened the reminder “%s”"),
    "memory": ("মনে রাখার প্রস্তাবটি বাতিল হয়েছে%s", "dropped the suggestion to remember it%s"),
}


def undo_run(user, text, prev, channel, client_id, lang, lim, now):
    """A finished run whose answer says what was taken back."""
    from ..models import AgentGoal, AgentRun
    from . import runner as RN
    from . import tools as TL
    from .contract import APPROVAL_RISKS
    pair = RN.topics_of(prev)
    vault = T.Vault()
    masked = vault.mask(text)
    with transaction.atomic():
        goal = AgentGoal.objects.create(
            user=user, topic=prev.topic, channel=channel if channel in AgentGoal.CHANNELS else "chat",
            text_sealed=T.seal({"t": text}), text_masked=masked[:600], client_id=client_id)
        run = AgentRun(goal=goal, user=user, topic=prev.topic, max_steps=lim["steps"],
                       max_llm_calls=RN.MAX_LLM_CALLS, max_credits=lim["credits"],
                       deadline_at=now + RN.RUN_TTL)
        T.save_vault(run, vault)
        run.save()
        extra = {"topics": pair, "secondary": pair[1]} if len(pair) > 1 else {}
        T.audit(run, "run.created", topic=prev.topic or "general", channel=goal.channel,
                goal=masked[:300], follow_up=prev.pk, undo=True, **extra)
    run._topics = pair
    run._lang = lang
    done, cannot = [], []
    already = prev.audit.filter(event="undo.done").exists()
    if not already:
        with transaction.atomic():
            for s in prev.steps.filter(kind="tool", state="done").order_by("-no"):
                tool = TL.get(s.tool)
                if s.tool in REVERSIBLE:
                    out = (T.unseal(s.result_sealed) or {}).get("r") or {}
                    r = _one(user, s, out)
                    if r:
                        done.append(r)
                elif s.risk in APPROVAL_RISKS:
                    cannot.append(_pick(lang, tool.label_bn, tool.label_en) if tool else s.tool)
            if done:
                T.audit(prev, "undo.done", by_run=run.pk, kinds=[k for k, _ in done])
    T.audit(run, "undo.result", undone=len(done), cannot=len(cannot), already=already)
    lines = []
    if done:
        parts = [(_DONE[k][0] if lang == "bn" else _DONE[k][1]) % (v if k != "memory" else "")
                 for k, v in done]
        lines.append(_pick(lang, "ফিরিয়ে নেওয়া হয়েছে: ", "Undone: ") + "; ".join(parts) + ".")
    for c in cannot:
        lines.append(_pick(lang, "“%s” আর ফেরানো যায় না — এটি আগেই করা হয়ে গেছে (মেসেজ পাঠানো/তৈরি বা মুছে ফেলা)।" % c,
                           "“%s” cannot be undone — it already happened (a message prepared/sent or a delete)." % c))
    if not lines:
        lines.append(_pick(lang, "আগের কাজটি আগেই ফিরিয়ে নেওয়া হয়েছে।", "The last task was already undone.")
                     if already else
                     _pick(lang, "ফিরিয়ে নেওয়ার মতো কিছু নেই — আগের কাজে শুধু তথ্য দেখা হয়েছিল।",
                           "Nothing to undo — the last task only looked things up."))
    RN._finish(run, "done", answer="\n".join(lines))
    return run
