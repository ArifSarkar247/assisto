"""
CRM ⇆ WhatsApp Business Cloud API integration — PURE LOGIC layer.

HARD RULES (enforced here, verified by crm/tests.py):
  * OFFICIAL WhatsApp Business Cloud API ONLY (Meta Graph). Automating a
    PERSONAL WhatsApp number or the WhatsApp Business *app* is a Meta ToS
    violation and a ban risk — it is refused outright (guard_channel).
  * LIVE SEND IS MOCKED + KEY-GATED. Nothing here opens a socket. We assemble
    the exact Graph request descriptor the integrator will POST once the Meta
    key is connected, and return a drafted/queued state otherwise. We NEVER
    fabricate a "delivered" result.
  * 24h customer-service window: free-form text is allowed only within 24h of
    the lead's last INBOUND message; outside it ONLY a pre-approved PAID
    template may go out.
  * TEMPLATE CONTENT IS OWNER-DEFINED. render_template only substitutes
    {{1}}-style params into text the owner already wrote — it never invents
    body copy.
  * Opt-in is respected: a lead that has not opted in is skipped in bulk sends.

This module reuses the proven guards/window from core.logic.business_ai so the
CRM and Business-mode surfaces share ONE definition of "allowed channel" and
"24h window" (DRY, single source of truth).
"""
import re

# Single source of truth for channel guard + 24h window (official-only).
from core.logic.business_ai import (
    CHANNEL_WA_CLOUD,
    PersonalWhatsAppBanned,
    guard_channel,
    within_service_window,
    assemble_webhook_send,
    SERVICE_WINDOW_HOURS,
)

__all__ = [
    "CHANNEL_WA_CLOUD", "PersonalWhatsAppBanned", "guard_channel",
    "within_service_window", "SERVICE_WINDOW_HOURS", "render_template",
    "plan_send", "bulk_fanout_plan", "normalize_wa_number",
]

_PARAM_RE = re.compile(r"\{\{\s*(\d+)\s*\}\}")


def normalize_wa_number(raw):
    """Keep only digits (E.164-ish). Returns '' for empties. Pure/arithmetic —
    never mutates or dials; just the destination string the Graph API wants."""
    return re.sub(r"\D", "", raw or "")


def render_template(body, params=None):
    """Substitute {{1}}, {{2}}… in OWNER-WRITTEN template `body` with `params`.

    We ONLY fill placeholders the owner put in their own text; we never generate
    body copy. A missing param is left as its placeholder so the gap is visible
    (honest) rather than silently blanked. Returns the rendered string.
    """
    params = params or []
    def _sub(m):
        idx = int(m.group(1)) - 1
        if 0 <= idx < len(params) and params[idx] not in (None, ""):
            return str(params[idx])
        return m.group(0)  # leave the placeholder visible if unfilled
    return _PARAM_RE.sub(_sub, body or "")


def plan_send(*, last_inbound_ts, now_ts, has_key, opted_in=True,
              text=None, template_name=None, template_body=None,
              template_params=None, to=""):
    """Decide the state of ONE outbound WhatsApp send from the CRM.

    Returns a dict describing exactly what will happen — NO network here:
      state ∈ {blocked_optout, needs_template, needs_key, draft, queued}
        * blocked_optout  — lead hasn't opted in → never send
        * needs_template  — outside 24h window and no approved template given
        * needs_key       — allowed, but no Meta key → honest drafted state
        * queued          — allowed AND key present → MOCK queued (integrator
                            posts `send.body` to `send.endpoint`; still not sent
                            live here, so we never claim delivery)
      mode     ∈ {freeform, template}
      paid_template: bool (billable template send, outside window)
      rendered: the exact text/body that would go out (owner content only)
      send: the Graph request descriptor (endpoint+body) when assemble-able
    """
    guard_channel(CHANNEL_WA_CLOUD)  # refuse personal WhatsApp — official only

    if not opted_in:
        return {"state": "blocked_optout", "allowed": False,
                "reason": "lead_not_opted_in"}

    in_window = within_service_window(last_inbound_ts, now_ts)
    # Resolve the text we'd actually send (owner content only).
    if in_window and template_name is None:
        mode = "freeform"
        rendered = text or ""
    else:
        # Outside the window (or an explicit template) → PAID template required.
        if not template_name:
            return {"state": "needs_template", "allowed": False,
                    "mode": "template", "paid_template": True,
                    "reason": "outside_24h_window_requires_approved_template"}
        mode = "template"
        rendered = render_template(template_body or "", template_params)

    descriptor = assemble_webhook_send(
        CHANNEL_WA_CLOUD, normalize_wa_number(to),
        text=rendered if mode == "freeform" else None,
        template_name=template_name if mode == "template" else None,
        last_inbound_ts=last_inbound_ts, now_ts=now_ts)

    base = {
        "allowed": True, "mode": mode,
        "paid_template": mode == "template",
        "rendered": rendered,
        "in_window": in_window,
        "send": descriptor,
    }
    base["state"] = "queued" if has_key else "needs_key"
    return base


def bulk_fanout_plan(*, leads, now_ts, has_key, template_name=None,
                     template_body=None, template_params=None, text=None):
    """Fan a campaign out to INDIVIDUAL 1:1 sends — NEVER a WhatsApp group.

    `leads` is a list of plain dicts: {id, to, opted_in, last_inbound_ts}. For
    each we run plan_send and bucket the outcome. Opt-out leads are skipped;
    outside-window leads require the paid template (same rule as 1:1). Returns a
    per-lead plan plus a summary the UI/integrator can act on. No network.
    """
    results = []
    counts = {"queued": 0, "needs_key": 0, "needs_template": 0,
              "blocked_optout": 0}
    for ld in leads:
        p = plan_send(
            last_inbound_ts=ld.get("last_inbound_ts"), now_ts=now_ts,
            has_key=has_key, opted_in=bool(ld.get("opted_in")),
            text=text, template_name=template_name,
            template_body=template_body, template_params=template_params,
            to=ld.get("to", ""))
        counts[p["state"]] = counts.get(p["state"], 0) + 1
        results.append({"lead": ld.get("id"), "to": ld.get("to", ""),
                        "state": p["state"], "allowed": p.get("allowed", False),
                        "mode": p.get("mode"), "rendered": p.get("rendered")})
    return {
        "fanout": "individual",   # explicit: 1:1 sends, never a group broadcast
        "total": len(leads),
        "counts": counts,
        "results": results,
        "note": ("প্রতিটি লিডকে আলাদা করে পাঠানো হয় — কোনো গ্রুপ নয় / "
                 "each lead is messaged 1:1 — never a group"),
    }
