"""quranpron — the alem / qari review queue for the Bangla pronunciation.

Storage: the generic PaCollectionItem table (collection `quran_pron`, no
migration). Each review is one APPEND-ONLY row owned by the reviewer:
    {s, a, action: approve|reject|rule_request, note, suggestion, engine, h}
`h` is the hash of the engine output that was reviewed. A review only counts
while the engine still produces exactly that output — when a rule changes the
text of an ayah, its old approval stops counting and the ayah goes back to
"under review" by itself. Nothing is ever served from `suggestion`: a rule
request is work for the developers, the text shown always comes from the
deterministic engine.
"""
from . import quran_pron as QP

COLL = "quran_pron"
ACTIONS = ("approve", "reject", "rule_request")
STATUS_OF = {"approve": "approved", "reject": "rejected", "rule_request": "needs_fix"}
STATUSES = ("under_review", "approved", "rejected", "needs_fix")
NOTE_MAX = 500


def _rows(surah=None):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(collection=COLL)
    if surah is not None:
        qs = qs.filter(data__s=surah)
    return qs.order_by("-created_at", "-id")


def record(user, surah, ayah, action, note="", suggestion=""):
    """Validate and store one review. Returns (row, error_code)."""
    from .models import PaCollectionItem
    if action not in ACTIONS:
        return None, "invalid_action"
    items = {a: r for a, _, r in QP.surah_items(surah)} if 1 <= surah <= 114 else {}
    res = items.get(ayah)
    if res is None:
        return None, "unknown_ayah"
    note = (note or "").strip()[:NOTE_MAX]
    suggestion = (suggestion or "").strip()[:NOTE_MAX]
    if action != "approve" and not note:
        return None, "note_required"
    row = PaCollectionItem.objects.create(user=user, collection=COLL, data={
        "s": surah, "a": ayah, "action": action, "note": note, "suggestion": suggestion,
        "engine": QP.ENGINE_VERSION, "h": QP.output_hash(res["bn"]),
    })
    return row, None


def status_map(surah):
    """{ayah: {"status", "row", "history": [rows]}} for one surah (current
    engine output only decides the status; history shows everything)."""
    current = {a: QP.output_hash(r["bn"]) for a, _, r in QP.surah_items(surah)}
    out = {}
    for row in _rows(surah).select_related("user")[:5000]:
        a = row.data.get("a")
        if a not in current:
            continue
        e = out.setdefault(a, {"status": "under_review", "row": None, "history": []})
        e["history"].append(row)
        if e["row"] is None and row.data.get("h") == current[a]:
            e["row"] = row
            e["status"] = STATUS_OF.get(row.data.get("action"), "under_review")
    return out


def counts():
    """Totals over the whole Quran for the owner page tiles."""
    from collections import Counter
    surahs = sorted({r.data.get("s") for r in _rows().only("data")[:20000]
                     if isinstance(r.data.get("s"), int)})
    c = Counter()
    for s in surahs:
        for e in status_map(s).values():
            c[e["status"]] += 1
    c["total"] = 6236
    c["under_review"] = 6236 - c["approved"] - c["rejected"] - c["needs_fix"]
    return c
