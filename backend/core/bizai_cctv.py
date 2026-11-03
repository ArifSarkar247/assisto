"""bizai pillar 4 — CCTV accuracy, MEASURED (owner: "CCTV 90 percent").

Definitions (per alert type):
  true alert   (TP) = an alert for something that really happened
  false alarm  (FP) = an alert when nothing of that kind happened
  missed event (FN) = something happened and no alert of that type came
  precision = TP / (TP + FP)   — "when it rings, is it right?"
  recall    = TP / (TP + FN)   — "when it happens, does it ring?"
  target: both ≥ 0.90 per type, on ≥ 20 labelled events (else "not enough").

Three honest sources, never mixed into one made-up number:
  1. REVIEWS — the owner's Correct / Wrong on real alerts (precision) plus
     "it happened but no alert came" reports (missed → recall).
  2. LIVE TEST SESSIONS — on the real camera: start a test, tap what you do
     ("I walk in now"), stop; alerts are matched to the taps within a time
     window → TP / FP / FN per type.
  3. CLIP TEST SET — labelled recorded clips (testdata/cctv_clips/manifest
     format) + the alerts a run produced → `manage.py cctv_eval`.
"""
import logging
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

TARGET = 0.90
MIN_EVENTS = 20
WINDOW_S = 30          # an alert within 30 s of a tap matches it
COL_MISSED = "cctv_missed"
COL_TEST = "cctv_test"

# what the owner can label in a test → which alert types count as "that"
TRUTH = {
    "person": ("person_detected", "zone_intrusion", "line_crossing", "motion", "after_hours",
               "pose_possible", "camera_alarm"),
    "line": ("line_crossing",),
    "zone": ("zone_intrusion",),
    "loiter": ("loitering",),
    "cash": ("hand_in_cash_zone", "drawer_open"),
    "camera": ("camera_health",),
}
ALERT_TO_TRUTH = {}
for _k, _types in TRUTH.items():
    for _t in _types:
        ALERT_TO_TRUTH.setdefault(_t, _k)


# ===================================================================== pure
def ratio(a, b):
    return round(a / b, 3) if b else None


def prf(tp, fp, fn):
    p, r = ratio(tp, tp + fp), ratio(tp, tp + fn)
    f1 = round(2 * p * r / (p + r), 3) if p and r else None
    n = tp + fp + fn
    return {"tp": tp, "fp": fp, "fn": fn, "precision": p, "recall": r, "f1": f1,
            "events": n, "enough": n >= MIN_EVENTS,
            "meets_target": bool(n >= MIN_EVENTS and p is not None and r is not None
                                 and p >= TARGET and r >= TARGET)}


def match(truth, alerts, window_s=WINDOW_S):
    """truth: [{kind, at(ts)}]; alerts: [{type, at(ts)}]. Greedy nearest
    match per truth kind; each alert used once. -> {kind: prf}."""
    used = set()
    per = {}

    def bucket(k):
        return per.setdefault(k, {"tp": 0, "fp": 0, "fn": 0})
    for t in sorted(truth, key=lambda x: x["at"]):
        k = t["kind"]
        best, gap = None, None
        for i, a in enumerate(alerts):
            counts = ALERT_TO_TRUTH.get(a["type"]) == k or a["type"] in TRUTH.get(k, ())
            if i in used or not counts:
                continue
            d = abs(a["at"] - t["at"])
            if d <= window_s and (gap is None or d < gap):
                best, gap = i, d
        if best is None:
            bucket(k)["fn"] += 1
        else:
            used.add(best)
            bucket(k)["tp"] += 1
    for i, a in enumerate(alerts):
        if i not in used:
            bucket(ALERT_TO_TRUTH.get(a["type"], a["type"]))["fp"] += 1
    return {k: prf(**v) for k, v in sorted(per.items())}


def combine(*maps):
    tot = {}
    for m in maps:
        for k, v in (m or {}).items():
            b = tot.setdefault(k, {"tp": 0, "fp": 0, "fn": 0})
            for f in ("tp", "fp", "fn"):
                b[f] += int(v.get(f) or 0)
    return {k: prf(**v) for k, v in sorted(tot.items())}


# ===================================================================== reviews
def _sites(user):
    from .models import ShopSite
    return ShopSite.objects.filter(owner=user)


def review_metrics(user, days=30, now=None, site_id=None):
    """From the owner's verdicts (TP = Correct, FP = Wrong) + missed reports."""
    from .models import PaCollectionItem, ShopEvent
    now = now or timezone.now()
    since = now - timedelta(days=days)
    sites = _sites(user)
    if site_id:
        sites = sites.filter(pk=site_id)
    per = {}
    unreviewed = 0
    for typ, st in ShopEvent.objects.filter(site__in=sites, created__gte=since) \
            .values_list("type", "status")[:20000]:
        k = ALERT_TO_TRUTH.get(typ, typ)
        b = per.setdefault(k, {"tp": 0, "fp": 0, "fn": 0})
        if st == "checked":
            b["tp"] += 1
        elif st == "false_alarm":
            b["fp"] += 1
        else:
            unreviewed += 1
    ids = set(sites.values_list("pk", flat=True))
    for r in PaCollectionItem.objects.filter(user=user, collection=COL_MISSED)[:5000]:
        d = r.data or {}
        if d.get("site_id") in ids and d.get("at", "") >= since.isoformat():
            k = d.get("kind") if d.get("kind") in TRUTH else "person"
            per.setdefault(k, {"tp": 0, "fp": 0, "fn": 0})["fn"] += 1
    return {"per_type": {k: prf(**v) for k, v in sorted(per.items())},
            "unreviewed": unreviewed, "days": days}


def report_missed(user, site_id, kind, note="", at=None):
    from .models import PaCollectionItem
    if not _sites(user).filter(pk=site_id).exists():
        return None
    kind = kind if kind in TRUTH else "person"
    return PaCollectionItem.objects.create(
        user=user, collection=COL_MISSED,
        data={"site_id": site_id, "kind": kind, "note": str(note or "")[:200],
              "at": (at or timezone.now()).isoformat()})


# ===================================================================== live tests
def start_test(user, site_id):
    from .models import PaCollectionItem
    if not _sites(user).filter(pk=site_id).exists():
        return None
    return PaCollectionItem.objects.create(
        user=user, collection=COL_TEST,
        data={"site_id": site_id, "started": timezone.now().isoformat(), "truth": [],
              "stopped": None, "result": None})


def _test(user, pk):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user=user, collection=COL_TEST, pk=pk).first()


def mark_truth(user, pk, kind, at=None):
    r = _test(user, pk)
    if r is None or (r.data or {}).get("stopped") or kind not in TRUTH:
        return None
    d = dict(r.data)
    d["truth"] = list(d.get("truth") or []) + [
        {"kind": kind, "at": (at or timezone.now()).timestamp()}]
    r.data = d
    r.save(update_fields=["data", "updated_at"])
    return r


def stop_test(user, pk, now=None):
    """Match the session's taps to the site's alerts (taps window + 30 s)."""
    from datetime import datetime
    from .models import ShopEvent
    r = _test(user, pk)
    if r is None:
        return None
    d = dict(r.data)
    if d.get("stopped"):
        return r
    now = now or timezone.now()
    start = datetime.fromisoformat(d["started"])
    alerts = [{"type": t, "at": c.timestamp()} for t, c in ShopEvent.objects.filter(
        site_id=d["site_id"], created__gte=start,
        created__lte=now + timedelta(seconds=WINDOW_S)).values_list("type", "created")]
    d["stopped"] = now.isoformat()
    d["result"] = match(d.get("truth") or [], alerts)
    d["alerts"] = len(alerts)
    r.data = d
    r.save(update_fields=["data", "updated_at"])
    return r


def tests_metrics(user, site_id=None):
    from .models import PaCollectionItem
    rows = [r.data or {} for r in PaCollectionItem.objects.filter(
        user=user, collection=COL_TEST).order_by("-id")[:200]]
    rows = [d for d in rows if d.get("result") is not None and
            (not site_id or d.get("site_id") == site_id)]
    return {"sessions": len(rows), "per_type": combine(*[d["result"] for d in rows])}


def accuracy(user, site_id=None, days=30):
    return {"target": TARGET, "min_events": MIN_EVENTS, "window_s": WINDOW_S,
            "truth_kinds": list(TRUTH),
            "reviews": review_metrics(user, days=days, site_id=site_id),
            "live_tests": tests_metrics(user, site_id=site_id)}
