"""buyinside (owner order 10 Nov): WHERE each purchase started.

The app sends `origin` = the feature key of the in-place buy screen
("cctv", "crm_write", "ai_chat", "photo_studio", "plans_page", ...) with
precheck / verify / checkout / trial start. We count it as an AnalyticsEvent
with NO personal data: the uid hash is the fixed anonymous hash (never the
user's), the props are only the origin key, the product sku and the stage.
Owner Admin reads the counts (origin_counts)."""
import logging
import re

log = logging.getLogger("assisto.buyorigin")

_KEY_RE = re.compile(r"^[a-z0-9_]{1,40}$")
STAGES = {"started": "upgrade_started", "completed": "upgrade_completed"}


def clean(v):
    s = str(v or "").strip().lower()[:40]
    return s if _KEY_RE.match(s) else ""


def record(origin, sku="", stage="started"):
    """Never raises. Returns True when one event was stored."""
    o = clean(origin)
    name = STAGES.get(stage)
    if not o or not name:
        return False
    try:
        from . import analytics
        from .models import AnalyticsEvent
        row = analytics.normalize_event(None, name, {
            "source": o, "feature": o, "plan": clean(sku) or "-", "step": stage})
        if not row:
            return False
        AnalyticsEvent.objects.create(uid_hash=row["uid_hash"], name=row["name"],
                                      day=row["day"], props=row["props"])
        return True
    except Exception:
        log.exception("buy origin: record failed")
        return False


def origin_counts(days=30):
    """{origin: {"started": n, "completed": n}} for the last `days` days."""
    from datetime import date, timedelta
    from .models import AnalyticsEvent
    since = date.today() - timedelta(days=days)
    out = {}
    rev = {v: k for k, v in STAGES.items()}
    for name, props in AnalyticsEvent.objects.filter(
            name__in=list(STAGES.values()), day__gte=since).values_list("name", "props"):
        o = (props or {}).get("source")
        if not o or (props or {}).get("step") not in STAGES:
            continue
        d = out.setdefault(o, {"started": 0, "completed": 0})
        d[rev[name]] += 1
    return out
