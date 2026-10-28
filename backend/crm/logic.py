"""
CRM business logic — the AI-driven process from CRM_SPEC.pdf, kept honest.

Hard rules enforced here:
  - Untrusted message text ALWAYS goes to ai.generate via `data=`, never the task.
  - Anything needing an external key degrades to a clean bilingual needs-key /
    needs-integration state — never a fabricated result.
  - Lead scoring is deterministic (scoring.py); AI only refines within a band.
"""
from django.utils import timezone

from . import scoring
from .models import Lead, Conversation, Message, Proposal


# Bilingual "available when ___" helper — keeps all states consistent.
def _needs(what_bn, what_en, reason="integration"):
    return {
        "ok": False,
        "needs_key": reason == "no_key",
        "needs_integration": reason == "integration",
        "reason": reason,
        "message": f"চালু হবে যখন {what_bn} / Available when {what_en}",
    }


def _payer(org):
    """credit-leak fix (plans-v2): every CRM AI call is charged to the CRM
    ORG OWNER's credits through billing (ai.generate user=...), like every
    other AI call — never free. Out of credits -> the honest rule-based
    fallback below (sentiment / recap / template), never a fake AI answer."""
    return getattr(org, "owner", None) if org is not None else None


# --------------------------------------------------------------- lead capture
def _inbound_texts(lead):
    """All inbound message text for a lead — the real signal for scoring."""
    return list(
        Message.objects.filter(conversation__lead=lead, direction=Message.IN)
        .values_list("text", flat=True)
    )


def score_lead(lead, use_ai=True):
    """(Re)compute a lead's score deterministically from its inbound messages,
    then optionally let AI nudge it within a tight band. Persists score /
    priority / reason. Returns the lead."""
    texts = _inbound_texts(lead)
    result = scoring.base_score(industry=lead.industry,
                                company_size=lead.company_size,
                                inbound_texts=texts)
    if use_ai:
        result, _summary = scoring.refine_with_ai(result, texts,
                                                  user=_payer(lead.org))
    lead.score = result["score"]
    lead.priority = result["priority"]
    lead.score_reason = result["reason"]
    lead.save(update_fields=["score", "priority", "score_reason", "updated_at"])
    return lead


def capture_lead(org, source, contact, first_message, name="", company="",
                 industry="other", company_size=0, assigned_to=None):
    """Omnichannel capture (spec §1): create Lead + Conversation + first inbound
    Message, run deterministic scoring, return the Lead.

    `contact` is a dict like {"phone": "...", "email": "..."}.
    `first_message` is UNTRUSTED text — stored as data, never run as a command.
    """
    contact = contact or {}
    lead = Lead.objects.create(
        org=org,
        name=name or "",
        company=company or "",
        industry=industry if industry in dict(Lead.INDUSTRIES) else "other",
        company_size=company_size or 0,
        source=source if source in dict(Lead.SOURCES) else "manual",
        phone=contact.get("phone", "") or "",
        email=contact.get("email", "") or "",
        assigned_to=assigned_to,
    )
    conv = Conversation.objects.create(lead=lead, channel=lead.source)
    if first_message:
        add_message(conv, Message.IN, first_message, rescore=False)
    # Score once off the real captured text.
    score_lead(lead)
    return lead


# --------------------------------------------------------------- messaging
def add_message(conversation, direction, text, rescore=True):
    """Store a message with sentiment (rule-based; AI-refined if available) and
    refresh the conversation insight summary. Re-scores the lead when an inbound
    message arrives (new buying signals may raise priority)."""
    sentiment = scoring.rule_sentiment(text)
    sentiment = _refine_sentiment(text, sentiment,
                                  user=_payer(conversation.lead.org))
    msg = Message.objects.create(
        conversation=conversation, direction=direction,
        text=text or "", sentiment=sentiment,
    )
    _update_insight(conversation)
    if rescore and direction == Message.IN:
        score_lead(conversation.lead)
    return msg


def _refine_sentiment(text, fallback, user=None):
    """Ask AI for sentiment only if available; otherwise keep the rule result.
    Never fabricates — on any error returns the deterministic fallback."""
    try:
        from core import ai
    except Exception:
        return fallback
    if not ai.available():
        return fallback
    task = ("Classify the buyer message in <data> as exactly one token: "
            "POS, NEU, or NEG (buying sentiment). Reply with the token only.")
    try:
        out, _ = ai.generate(task=task, data=text or "", tier="cheap",
                             max_tokens=5, feature="crm.sentiment", user=user, pii=True)
    except Exception:
        return fallback
    tok = (out or "").strip().upper()
    if "POS" in tok:
        return "pos"
    if "NEG" in tok:
        return "neg"
    if "NEU" in tok:
        return "neu"
    return fallback


def _update_insight(conversation):
    """Refresh the conversation's running summary (spec §3). AI summary when
    available; otherwise a clean rule-based recap (counts + last message)."""
    msgs = list(conversation.messages.all())
    inbound = [m.text for m in msgs if m.direction == Message.IN and m.text]
    last = msgs[-1] if msgs else None

    summary = ""
    try:
        from core import ai
        if ai.available() and inbound:
            task = ("Summarize this sales chat in ONE Bangla sentence: what the "
                    "buyer wants and how interested they seem. Only use <data>.")
            summary, _ = ai.generate(task=task, data="\n".join(inbound),
                                     tier="cheap", max_tokens=120,
                                     feature="crm.insight", pii=True,
                                     user=_payer(conversation.lead.org))
    except Exception:
        summary = ""

    if not summary:
        # Honest rule-based recap — no invented content.
        n_in = sum(1 for m in msgs if m.direction == Message.IN)
        n_out = sum(1 for m in msgs if m.direction == Message.OUT)
        tone = last.sentiment if last else "neu"
        summary = (f"{n_in} inbound / {n_out} outbound বার্তা; "
                   f"সর্বশেষ টোন: {tone}।")
    conversation.insight = summary
    conversation.save(update_fields=["insight"])
    return summary


# --------------------------------------------------------------- follow-up
def suggest_followup(lead):
    """Predictive next-contact suggestion + a draft message (spec §4).

    AI drafts when available (analysing recent inbound text); otherwise a clean
    bilingual template keyed off priority. Always returns a usable, honest
    result — the "when" is a suggestion, never presented as a fact."""
    texts = _inbound_texts(lead)[-5:]  # last few inbound messages
    # Simple, honest timing heuristic from pipeline stage + priority.
    days = 1 if lead.priority == Lead.HIGH else 3
    when = timezone.now() + timezone.timedelta(days=days)
    suggested_at = when.date().isoformat()

    draft = ""
    source = "template"
    credits_out = False
    try:
        from core import ai
        if ai.available() and texts:
            task = ("Write a short, polite Bangla follow-up message to a sales "
                    "lead, based only on the buyer's messages in <data>. 2–3 "
                    "sentences. Do not invent prices or claims. Sign as a sales "
                    "assistant, not a human.")
            draft, _ = ai.generate(task=task, data="\n".join(texts),
                                   tier="cheap", max_tokens=200,
                                   feature="crm.followup", pii=True,
                                   user=_payer(lead.org))
            source = "ai" if draft else "template"
    except Exception as e:
        draft = ""
        credits_out = getattr(e, "reason", "") == "credits"

    if not draft:
        name = lead.name or "স্যার/ম্যাডাম"
        draft = (f"{name}, আমরা Axon ERP নিয়ে আপনার সাথে কথা বলতে আগ্রহী। "
                 f"সুবিধাজনক সময়ে জানাবেন কখন বিস্তারিত আলোচনা করা যায়? "
                 f"(We'd love to continue our conversation about Axon ERP.)")

    return {
        "ok": True,
        "suggested_contact_date": suggested_at,
        "note": "এটি একটি পরামর্শ, নিশ্চিত নয় / This is a suggestion, not a guarantee",
        "draft": draft,
        "draft_source": source,
        # out of AI credits: the honest template above, never a fake AI draft
        "credits_out": credits_out,
    }


# --------------------------------------------------------------- proposal
def generate_proposal(lead, requirements=""):
    """Generate an original proposal (spec §5). Requires AI — with no key it
    returns a clean needs-key state and stores NOTHING fabricated.

    `requirements` is untrusted buyer-derived text → passed as data."""
    try:
        from core import ai
    except Exception:
        return _needs("AI key যোগ হবে", "an AI key is added", reason="no_key")
    if not ai.available():
        return _needs("AI key যোগ হবে", "an AI key is added", reason="no_key")

    # Build the data payload from REAL lead data + captured requirements only.
    texts = _inbound_texts(lead)
    data = (
        f"Company: {lead.company or 'N/A'}\n"
        f"Industry: {lead.get_industry_display()}\n"
        f"Company size: {lead.company_size or 'unknown'}\n"
        f"Stated requirements: {requirements or '(derive from chat)'}\n"
        f"Buyer messages:\n" + "\n".join(texts)
    )
    task = (
        "Write an original, professional Axon ERP proposal in Bangla for the "
        "prospect described in <data>. Include: understanding of their need, "
        "recommended modules, a high-level implementation outline, and next "
        "steps. Do NOT invent specific prices, discounts, or numbers that are "
        "not present in the data. You are an AI sales assistant, not a human."
    )
    try:
        body, _ = ai.generate(task=task, data=data, tier="medium",
                             max_tokens=1200, feature="crm.proposal", pii=True,
                             user=_payer(lead.org))
    except Exception as e:
        reason = getattr(e, "reason", "queued")
        if reason == "credits":
            return {"ok": False, "reason": "credits", "code": "out_of_credits",
                    "message": "AI ক্রেডিট শেষ — ক্রেডিট যোগ করে আবার চেষ্টা করুন। কোনো ক্রেডিট কাটা হয়নি। / "
                               "Out of AI credits — add credits and try again. No credits were used."}
        return _needs("AI key যোগ হবে", "an AI key is added",
                      reason="no_key" if reason == "no_key" else "queued")

    if not body:
        return _needs("AI key যোগ হবে", "an AI key is added", reason="queued")

    proposal = Proposal.objects.create(lead=lead, body=body)
    # Move the lead forward in the pipeline on proposal generation.
    if lead.status in ("new", "contacted", "demo"):
        lead.status = "proposal"
        lead.save(update_fields=["status", "updated_at"])
    return {"ok": True, "proposal_id": proposal.id, "body": body}


# --------------------------------------------------------------- ERP onboarding
def onboard_to_erp(lead):
    """One-click Axon ERP onboarding on deal Won (spec §6). Gated on the
    axon_erp integration: if not connected, return a clean needs-integration
    state. If connected, POST the chat history + requirements + latest proposal
    to the ERP base_url with the configured token."""
    try:
        from core import integrations
    except Exception:
        return _needs("Axon ERP কানেক্ট হবে", "Axon ERP is connected")
    if not integrations.is_enabled("axon_erp"):
        return _needs("Axon ERP কানেক্ট হবে", "Axon ERP is connected")

    cfg = integrations.get("axon_erp")
    base_url = (cfg.get("base_url") or "").rstrip("/")
    token = cfg.get("token") or ""
    if not base_url or not token:
        return _needs("Axon ERP কানেক্ট হবে", "Axon ERP is connected")

    # Assemble the real deal data to hand off to the implementation team.
    chat = [
        {"direction": m.direction, "text": m.text, "sentiment": m.sentiment,
         "at": m.at.isoformat()}
        for m in Message.objects.filter(conversation__lead=lead).order_by("at")
    ]
    latest_proposal = lead.proposals.first()
    payload = {
        "lead": {
            "name": lead.name, "company": lead.company,
            "industry": lead.industry, "company_size": lead.company_size,
            "phone": lead.phone, "email": lead.email,
            "score": lead.score, "priority": lead.priority,
        },
        "chat_history": chat,
        "proposal": latest_proposal.body if latest_proposal else "",
    }

    import json as _j
    import urllib.request
    import urllib.error
    url = base_url + "/implementation/onboard"
    body = _j.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"content-type": "application/json",
                 "authorization": f"Bearer {token}"},
    )
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        out = resp.read().decode()
        return {"ok": True, "status_code": resp.getcode(), "response": out[:2000]}
    except urllib.error.HTTPError as e:
        return {"ok": False, "reason": "erp_error", "status_code": e.code,
                "message": f"Axon ERP error {e.code}"}
    except Exception as e:  # noqa: BLE001 — network/DNS failure, stay honest
        return {"ok": False, "reason": "erp_unreachable",
                "message": "Axon ERP-এ পৌঁছানো যায়নি / Could not reach Axon ERP"}
