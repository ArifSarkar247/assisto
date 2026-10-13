"""Tiny helper to write CRM audit-log entries consistently (spec: audit log)."""
from .models import AuditEntry


def log(org, member, action, entity="", detail=""):
    """Append an audit entry. Never raises into the request path."""
    try:
        return AuditEntry.objects.create(
            org=org, member=member, action=action,
            entity=entity or "", detail=detail or "")
    except Exception:
        return None
