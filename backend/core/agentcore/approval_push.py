"""WP-APP: tell the phone an agent step waits for a one-tap approval.

push kind `agent_approval` (core/push.py, channel "alerts"). The push carries
NO details of what will be done — only that an approval is waiting, the tool's
generic label ("Delete a note") and the risk — because a notification can be
read on a locked phone. The app shows the full card (what, to whom, cost,
expiry) only inside the signed-in app.

Notification actions (app/lib/screens/agent_core/agent_core_push.dart):
  * Reject  -> POST agent-core/approvals/<id> {decision: reject} right from the
               notification with the app's own auth token (safe: rejecting
               never sends, pays or deletes anything).
  * Approve -> opens the app (Android asks to unlock first) on that approval
               card; the user confirms there, seeing exactly what will happen.
Never raises: a push failure must not break a run (the foreground poll of
GET agent-core/approvals still finds it).
"""
import logging

log = logging.getLogger(__name__)

ROUTE = "agent/approval"

_TITLE = ("অনুমোদন দরকার", "Approval needed")
_BODY = {
    "external": ("Assisto এজেন্ট আপনার হয়ে বাইরে কিছু পাঠাতে চায়: %s",
                 "The Assisto agent wants to send something for you: %s"),
    "money": ("Assisto এজেন্ট টাকা-সংক্রান্ত একটি কাজ করতে চায়: %s",
              "The Assisto agent wants to do a money task: %s"),
    "delete": ("Assisto এজেন্ট কিছু মুছতে চায়: %s",
               "The Assisto agent wants to delete something: %s"),
}
_BODY_DEFAULT = ("Assisto এজেন্ট আপনার অনুমতি চায়: %s",
                 "The Assisto agent needs your OK: %s")


def payload(ap, tool):
    """(title_bn, title_en, body_bn, body_en, data) — data values are strings
    (FCM data), no PII and no step arguments."""
    bn, en = _BODY.get(ap.risk, _BODY_DEFAULT)
    label_bn = getattr(tool, "label_bn", "") or ""
    label_en = getattr(tool, "label_en", "") or ""
    data = {"approval_id": str(ap.pk), "run_id": str(ap.run_id), "risk": ap.risk,
            "expires_at": ap.expires_at.isoformat(), "route": ROUTE}
    return _TITLE[0], _TITLE[1], bn % label_bn, en % label_en, data


def notify(ap, tool):
    """Fire-and-forget push for a NEW pending approval. Never raises."""
    try:
        if ap is None or ap.status != "pending":
            return False
        from .. import push
        tbn, ten, bbn, ben, data = payload(ap, tool)
        return push.safe_push(ap.user, "agent_approval", tbn, ten, bbn, ben,
                              data=data, high_priority=True)
    except Exception as e:  # noqa: BLE001
        log.warning("agentcore: approval push failed %s", type(e).__name__)
        return False
