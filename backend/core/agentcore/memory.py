"""Life-graph memory (WP-MEMORY, flag `agent_core`): a private, encrypted,
per-user graph of typed facts the user can view, edit, export and delete.

Storage — the existing "AI knows" table, no second store: a MemoryItem with
kind != "" is one life-graph fact. Its content is a Fernet-sealed JSON node in
`detail` (the shared finance MultiFernet, same key handling as the run vault
and remittance; honest note: the key lives on the same server, so a DB dump
is protected, a full server takeover is not). Only content-free columns stay
in clear: kind, status, sensitive, origin, confidence, timestamps and an HMAC
fingerprint used for de-duplication. MemoryItem.objects (the legacy default
manager) never returns these rows; MemoryItem.graph does.

Node (sealed):
    {"v": 1, "type": "person", "label": "আম্মু", "value": "জন্মদিন ৫ মে",
     "relation": "mother", "when": "", "use_in_ai": true,
     "prov": {"by": "user|run|learn", "run": 12, "tool": "memory.remember",
              "rule": "recurring_expense", "at": iso},
     "history": [{"at": iso, "by": "user", "what": "edited"}],
     "replaces": 7}                          # an update suggestion only

Consent — NOTHING is saved as a fact without the user:
  * the user typing a fact on the "AI knows" page (origin=user) is consent;
  * the agent ("remember that …") and the weekly learner only ever create a
    SUGGESTION (status=suggested); the planner never sees a suggestion; the
    user approves (-> active) or rejects (-> content wiped, only the HMAC
    fingerprint kept so the same thing is never proposed again);
  * passwords, PINs, OTPs, CVVs, card/account and NID numbers are refused
    outright, whoever asks;
  * health / religion / politics facts are flagged sensitive: the learner
    never proposes them and the planner never receives them.

What the AI gets — for_goal(): at most MAX_FACTS_PER_PLAN active,
non-sensitive, use_in_ai facts whose type belongs to the run's topic AND that
share a word with the goal, rendered short, size-capped and MASKED with the
run's vault. Never the whole graph.
"""
import json
import re
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from django.utils.crypto import salted_hmac

from . import trust as T

GRAPH_CATEGORY = "graph"
NODE_VERSION = 1
MAX_FACTS_PER_USER = 500
MAX_FACTS_PER_PLAN = 10
MAX_PLAN_CHARS = 1200
MAX_LEARN_PER_WEEK = 5
SUGGESTION_TTL = timedelta(days=30)
REJECTED_TTL = timedelta(days=365)
LEARN_EVERY = timedelta(days=6)          # weekly cron; a re-run inside a week is a no-op
DEFAULT_RETENTION_MONTHS = 18
STALE_ASK_BEFORE_MONTHS = 6              # "still right?" this long before deletion

TYPES = {
    "person": ("মানুষ", "People"),
    "place": ("জায়গা", "Places"),
    "routine": ("রুটিন", "Routines"),
    "preference": ("পছন্দ", "Preferences"),
    "date": ("জরুরি তারিখ", "Important dates"),
    "business": ("ব্যবসা", "Business"),
}
ORIGINS = {
    "user": ("আপনি লিখেছেন", "You added"),
    "run": ("এজেন্ট প্রস্তাব করেছে", "Suggested by the agent"),
    "learn": ("সাপ্তাহিক শেখা", "Weekly learning"),
}
STATUSES = ("active", "suggested", "rejected")

# which fact types a topic's planner may see (never the whole graph)
TOPIC_TYPES = {
    "family": ("person", "date", "place", "routine"),
    "safety": ("person", "place", "routine"),
    "money": ("routine", "date", "preference"),
    "business": ("business", "preference"),
    "documents": ("date", "person"),
    "travel": ("place", "routine", "person", "preference"),
    "health": ("routine", "preference"),
    "learning": ("date", "routine", "preference"),
    "memory": tuple(TYPES),
    "": ("person", "place", "routine", "preference", "date"),
}

LIMITS = {"label": 80, "value": 300, "relation": 40, "when": 60}


class MemoryError_(Exception):
    def __init__(self, code, status=400):
        self.code = code
        self.status = status
        super().__init__(code)


# ------------------------------------------------------------------ guards
_SECRET_RX = re.compile(
    r"password|passcode|pass ?word|passwd|\bpin\b|pin ?(?:code|number|no)|\botp\b|one[- ]time|"
    r"\bcvv\b|\bcvc\b|security code|secret code|card number|"
    r"পাসওয়ার্ড|পাসওয়ার্ড|পাসকোড|ওটিপি|গোপন (?:নম্বর|কোড|সংখ্যা)|কার্ড নম্বর|সিভিভি|"
    r"পিন(?:টা|টি|কোড|নম্বর|\s|$|[,।.?!:])|"
    r"\bpassward\b|\bpaswrd\b|\bpin ta\b|\bpinta\b|gopon (?:number|code)",
    re.I)
_KINDS_REFUSED = ("NID", "ACCT")


def secret_kind(*texts):
    """'' when fine; else why the text can never be remembered."""
    t = " ".join(x for x in texts if isinstance(x, str))
    if _SECRET_RX.search(t):
        return "secret"
    rx = dict(T._PATTERNS)
    t = rx["PHONE"].sub(" ", rx["EMAIL"].sub(" ", t))     # a phone number is fine to keep
    for kind in _KINDS_REFUSED:
        if rx[kind].search(t):
            return "id_number"
    return ""


_SENSITIVE_RX = re.compile(
    # health
    r"ডায়াবেটিস|ডায়াবেটিস|ক্যান্সার|ক্যানসার|রোগ|অসুখ|অসুস্থ|ওষুধ|ঔষধ|প্রেশার|হার্ট|কিডনি|"
    r"এইচআইভি|গর্ভ|মানসিক|ডিপ্রেশন|বিষণ্ণ|থেরাপি|ডাক্তার|হাসপাতাল|অপারেশন|ইনসুলিন|"
    r"diabet|cancer|disease|illness|\bsick\b|medicine|medication|blood pressure|\bbp\b|heart|kidney|"
    r"\bhiv\b|pregnan|mental|depress|anxiety|therapy|doctor|hospital|surgery|insulin|"
    r"oshudh|osudh|oshukh|rog\b|daktar|"
    # religion
    r"নামাজ|নামায|মসজিদ|মন্দির|গির্জা|প্যাগোডা|পূজা|ধর্ম|হিন্দু|মুসলিম|মুসলমান|খ্রিস্টান|বৌদ্ধ|রোজা|"
    r"religio|namaz|namaj|mosque|masjid|temple|church|pagoda|hindu|muslim|christian|buddhis|roza|"
    # politics
    r"রাজনীতি|রাজনৈতিক|আওয়ামী|আওয়ামী|বিএনপি|জামায়াত|জামায়াত|politic|awami|\bbnp\b|jamaat",
    re.I)


def is_sensitive(*texts):
    return bool(_SENSITIVE_RX.search(" ".join(x for x in texts if isinstance(x, str))))


# ------------------------------------------------------------------ helpers
def _now():
    return timezone.now()


def _iso(dt):
    return dt.isoformat() if dt else None


def _clean(s, n):
    s = re.sub(r"\s+", " ", str(s or "")).strip()
    return s[:n]


def _norm(s):
    return re.sub(r"[\W_]+", " ", (s or "").lower(), flags=re.U).strip()


def fingerprint(user_id, key):
    return salted_hmac("agentmem.fp", "%s|%s" % (user_id, key), algorithm="sha256").hexdigest()


def content_key(kind, label, value):
    return "c|%s|%s|%s" % (kind, _norm(label), _norm(value))


def seal_node(node):
    return T.seal(node)


def unseal_node(row):
    return T.unseal(row.detail) if row.detail else {}


def _pick(lang, bn, en):
    return bn if lang == "bn" else en


def prefs_for(user):
    from ..models import AgentMemoryPrefs
    p = AgentMemoryPrefs.objects.filter(user=user).first()
    return p or AgentMemoryPrefs(user=user)


def _history(node, by, what, now=None):
    h = list(node.get("history") or [])
    h.append({"at": _iso(now or _now()), "by": by, "what": what})
    node["history"] = h[-10:]


def _qs(user):
    from ..models import MemoryItem
    return MemoryItem.graph.filter(user=user)


def _get(user, pk):
    row = _qs(user).filter(pk=pk).first()
    if row is None:
        raise MemoryError_("not_found", 404)
    return row


def _validate_fields(d, partial=False):
    out = {}
    if not partial or "type" in d:
        kind = str(d.get("type") or "")
        if kind not in TYPES:
            raise MemoryError_("bad_type")
        out["type"] = kind
    for k, n in LIMITS.items():
        if k in d or (not partial and k in ("label", "value")):
            out[k] = _clean(d.get(k), n)
    if not partial and not (out.get("label") or out.get("value")):
        raise MemoryError_("empty")
    if partial and "label" in out and "value" in out and not (out["label"] or out["value"]):
        raise MemoryError_("empty")
    if "use_in_ai" in d:
        out["use_in_ai"] = bool(d.get("use_in_ai"))
    if "sensitive" in d:
        out["sensitive"] = bool(d.get("sensitive"))
    why = secret_kind(out.get("label"), out.get("value"), out.get("relation"), out.get("when"))
    if why:
        raise MemoryError_("secret_refused" if why == "secret" else "id_refused")
    return out


def _count_ok(user):
    return _qs(user).exclude(status="rejected").count() < MAX_FACTS_PER_USER


def _log(user, action, **detail):
    from ..models import AuditLog
    AuditLog.objects.create(user=user, action=action, detail=detail)


# ------------------------------------------------------------------ output
def fact_out(row, lang="bn", node=None):
    node = node if node is not None else unseal_node(row)
    prov = dict(node.get("prov") or {})
    return {
        "id": row.id, "type": row.kind, "type_label": _pick(lang, *TYPES.get(row.kind, ("", ""))),
        "label": node.get("label") or "", "value": node.get("value") or "",
        "relation": node.get("relation") or "", "when": node.get("when") or "",
        "status": row.status, "sensitive": bool(row.sensitive),
        "use_in_ai": bool(node.get("use_in_ai", True)) and not row.sensitive,
        "origin": row.origin, "origin_label": _pick(lang, *ORIGINS.get(row.origin, ("", ""))),
        "confidence": row.confidence,
        "provenance": {"by": prov.get("by") or row.origin, "run": prov.get("run"),
                       "tool": prov.get("tool") or "", "rule": prov.get("rule") or "",
                       "at": prov.get("at")},
        "replaces": node.get("replaces"),
        "still_right": bool(row.needs_review and row.status == "active"),
        "history": node.get("history") or [],
        "created_at": _iso(row.created_at), "updated_at": _iso(row.updated_at),
        "last_used_at": _iso(row.last_used_at),
    }


def prefs_out(p):
    return {"learning_paused": bool(p.learning_paused),
            "retention_months": int(p.retention_months or DEFAULT_RETENTION_MONTHS),
            "retention_choices": list(type(p).RETENTION_CHOICES),
            "last_learned_at": _iso(p.last_learned_at)}


def listing(user, lang="bn", kind="", status="active"):
    qs = _qs(user)
    counts = {k: 0 for k in TYPES}
    for k in qs.filter(status="active").values_list("kind", flat=True):
        if k in counts:
            counts[k] += 1
    suggested = qs.filter(status="suggested").count()
    if status not in ("active", "suggested"):
        status = "active"
    rows = qs.filter(status=status)
    if kind:
        rows = rows.filter(kind=kind)
    facts = [fact_out(r, lang) for r in rows.order_by("-updated_at")[:MAX_FACTS_PER_USER]]
    return {"facts": facts, "counts": counts, "total": sum(counts.values()),
            "suggestions": suggested, "prefs": prefs_out(prefs_for(user)),
            "types": [{"key": k, "label": _pick(lang, *v)} for k, v in TYPES.items()]}


# ------------------------------------------------------------------ user edits
def create_fact(user, data, lang="bn"):
    """The user typed it on the "AI knows" page -> an active fact (consent)."""
    from ..models import MemoryItem
    f = _validate_fields(data)
    if not _count_ok(user):
        raise MemoryError_("memory_full")
    now = _now()
    node = {"v": NODE_VERSION, "type": f["type"], "label": f.get("label", ""),
            "value": f.get("value", ""), "relation": f.get("relation", ""),
            "when": f.get("when", ""), "use_in_ai": f.get("use_in_ai", True),
            "prov": {"by": "user", "at": _iso(now)}}
    _history(node, "user", "created", now)
    sens = f["sensitive"] if "sensitive" in f else is_sensitive(node["label"], node["value"],
                                                                 node["relation"])
    row = MemoryItem.all_rows.create(
        user=user, category=GRAPH_CATEGORY, title="graph:" + f["type"], kind=f["type"],
        status="active", sensitive=sens, origin="user", source=MemoryItem.SOURCE_MANUAL,
        detail=seal_node(node),
        fingerprint=fingerprint(user.id, content_key(f["type"], node["label"], node["value"])))
    _log(user, "memory.graph.create", id=row.id, type=row.kind)
    return fact_out(row, lang, node)


def update_fact(user, pk, data, lang="bn"):
    row = _get(user, pk)
    if row.status != "active":
        raise MemoryError_("not_found", 404)
    f = _validate_fields(data, partial=True)
    node = unseal_node(row)
    for k in ("label", "value", "relation", "when", "use_in_ai"):
        if k in f:
            node[k] = f[k]
    if "type" in f:
        node["type"] = row.kind = f["type"]
        row.title = "graph:" + f["type"]
    if "sensitive" in f:
        row.sensitive = f["sensitive"]
    elif any(k in f for k in ("label", "value", "relation")) and \
            is_sensitive(node.get("label"), node.get("value"), node.get("relation")):
        row.sensitive = True
    _history(node, "user", "edited")
    row.detail = seal_node(node)
    row.needs_review = False
    row.fingerprint = fingerprint(user.id, content_key(row.kind, node.get("label"), node.get("value")))
    row.save()
    _log(user, "memory.graph.update", id=row.id)
    return fact_out(row, lang, node)


def confirm_fact(user, pk, lang="bn"):
    """'Still right?' -> yes: keeps it another retention period."""
    row = _get(user, pk)
    node = unseal_node(row)
    _history(node, "user", "confirmed")
    row.detail = seal_node(node)
    row.needs_review = False
    row.save()
    return fact_out(row, lang, node)


def delete_fact(user, pk):
    row = _get(user, pk)
    row.delete()
    _log(user, "memory.graph.delete", id=pk)
    return True


def delete_all(user):
    """Every life-graph row of this user — facts, suggestions, rejected
    fingerprints — really deleted (rows gone, not flagged)."""
    with transaction.atomic():
        n, _ = _qs(user).delete()
    _log(user, "memory.graph.delete_all", count=n)
    return n


def export(user, lang="bn"):
    """Everything the life graph holds about the user, decrypted, for the
    user's OWN download (the app saves it and opens the share sheet; nothing
    is ever e-mailed or sent anywhere by the server)."""
    qs = _qs(user).exclude(status="rejected").order_by("kind", "id")
    facts, sugg = [], []
    for r in qs:
        (facts if r.status == "active" else sugg).append(fact_out(r, lang))
    _log(user, "memory.graph.export", facts=len(facts), suggestions=len(sugg))
    return {"format": "assisto-life-graph", "version": NODE_VERSION,
            "exported_at": _iso(_now()), "user_id": user.id,
            "facts": facts, "suggestions": sugg,
            "settings": prefs_out(prefs_for(user)),
            "note": _pick(lang, "এটি আপনার নিজের ডেটা — শুধু আপনি এটি রাখবেন বা শেয়ার করবেন।",
                          "This is your own data — only you decide to keep or share it.")}


def set_prefs(user, data):
    from ..models import AgentMemoryPrefs
    p, _ = AgentMemoryPrefs.objects.get_or_create(user=user)
    if "learning_paused" in data:
        p.learning_paused = bool(data.get("learning_paused"))
    if "retention_months" in data:
        try:
            m = int(data.get("retention_months"))
        except (TypeError, ValueError):
            raise MemoryError_("bad_input")
        if m not in AgentMemoryPrefs.RETENTION_CHOICES:
            raise MemoryError_("bad_input")
        p.retention_months = m
    p.save()
    _log(user, "memory.graph.prefs", paused=p.learning_paused, retention=p.retention_months)
    return prefs_out(p)


# ------------------------------------------------------------------ suggestions
def suggest(user, kind, label, value, origin, relation="", when="", prov=None, fp_key="",
            confidence=None, replaces=None):
    """Propose a fact. Returns (row|None, reason). Never creates an active
    fact. reason: created | exists | secret | id_number | sensitive | paused |
    full | bad_type | empty."""
    from ..models import MemoryItem
    if kind not in TYPES:
        return None, "bad_type"
    label, value = _clean(label, LIMITS["label"]), _clean(value, LIMITS["value"])
    relation, when = _clean(relation, LIMITS["relation"]), _clean(when, LIMITS["when"])
    if not (label or value):
        return None, "empty"
    why = secret_kind(label, value, relation, when)
    if why:
        return None, why
    sens = is_sensitive(label, value, relation)
    if origin == "learn":
        if sens:
            return None, "sensitive"           # health / religion / politics: never by itself
        if prefs_for(user).learning_paused:
            return None, "paused"
    fp = fingerprint(user.id, fp_key or content_key(kind, label, value))
    if _qs(user).filter(fingerprint=fp).exists():
        return None, "exists"                  # incl. rejected: never proposed twice
    if not _count_ok(user):
        return None, "full"
    now = _now()
    p = {"by": origin, "at": _iso(now)}
    p.update({k: v for k, v in (prov or {}).items() if v not in (None, "")})
    node = {"v": NODE_VERSION, "type": kind, "label": label, "value": value,
            "relation": relation, "when": when, "use_in_ai": True, "prov": p}
    if replaces:
        node["replaces"] = int(replaces)
    _history(node, origin, "suggested", now)
    row = MemoryItem.all_rows.create(
        user=user, category=GRAPH_CATEGORY, title="graph:" + kind, kind=kind,
        status="suggested", needs_review=True, sensitive=sens, origin=origin,
        source=MemoryItem.SOURCE_AI, confidence=confidence, detail=seal_node(node),
        fingerprint=fp)
    return row, "created"


def approve(user, pk, lang="bn"):
    row = _get(user, pk)
    if row.status != "suggested":
        if row.status == "active":
            return fact_out(row, lang)         # idempotent second tap
        raise MemoryError_("not_found", 404)
    node = unseal_node(row)
    target_id = node.get("replaces")
    with transaction.atomic():
        if target_id:
            target = _qs(user).filter(pk=target_id, status="active").first()
            if target is not None:
                tnode = unseal_node(target)
                for k in ("label", "value", "relation", "when"):
                    if node.get(k):
                        tnode[k] = node[k]
                _history(tnode, row.origin or "run", "updated (you approved)")
                target.detail = seal_node(tnode)
                target.sensitive = target.sensitive or row.sensitive
                target.needs_review = False
                target.fingerprint = fingerprint(
                    user.id, content_key(target.kind, tnode.get("label"), tnode.get("value")))
                target.save()
                row.delete()
                _log(user, "memory.graph.approve", id=target.id, update=True)
                return fact_out(target, lang, tnode)
        _history(node, "user", "approved")
        row.detail = seal_node(node)
        row.status = "active"
        row.needs_review = False
        row.save()
    _log(user, "memory.graph.approve", id=row.id)
    return fact_out(row, lang, node)


def reject(user, pk):
    """The content is wiped at once; only the HMAC fingerprint stays so the
    same suggestion is never made again (deleted after REJECTED_TTL)."""
    row = _get(user, pk)
    if row.status == "rejected":
        return True
    if row.status != "suggested":
        raise MemoryError_("not_found", 404)
    row.status = "rejected"
    row.detail = ""
    row.needs_review = False
    row.save()
    _log(user, "memory.graph.reject", id=row.id)
    return True


# ------------------------------------------------------------------ planner scope
_STOP = set("""
আমার আমি আমাকে আমায় তুমি আপনি আপনার কি কী কে কবে কোথায় কখন কেন কত কোন কোনটা এই ওই সেই এটা ওটা
আর ও এবং বা না হবে হলো হল করো করুন করে দাও দিন বলো বলুন একটু কিছু সব জন্য থেকে মধ্যে দিয়ে নিয়ে
my me i you your the a an is are was of to in on at for and or what when where who how which do does
did please tell show give about this that it be with from amar ami ki kobe kothay koto kon ei oi bolo
dao
""".split())
_TOKEN_RX = re.compile(r"[\wঀ-৿]+", re.U)
_SUFFIX = ("দের", "য়ের", "য়ের", "ের", "এর", "র", "কে", "তে", "টা", "টি", "'s", "s")


def _tokens(text):
    out = set()
    for w in _TOKEN_RX.findall((text or "").lower()):
        if w in _STOP or len(w) < 2:
            continue
        out.add(w)
        for suf in _SUFFIX:
            if w.endswith(suf) and len(w) - len(suf) >= 2:
                out.add(w[: -len(suf)])
                break
    return out


def _overlap(goal_toks, node):
    ft = _tokens(" ".join(str(node.get(k) or "") for k in ("label", "value", "relation", "when")))
    score = 0
    for g in goal_toks:
        for f in ft:
            if g == f or (len(g) >= 3 and len(f) >= 3 and (g.startswith(f) or f.startswith(g))):
                score += 1
                break
    return score


def _render(row, node):
    s = node.get("label") or ""
    if node.get("relation"):
        s += " (%s)" % node["relation"]
    if node.get("value"):
        s += ": " + node["value"]
    if node.get("when"):
        s += "; " + node["when"]
    return s


def for_goal(user, topic, goal_text, vault, limit=MAX_FACTS_PER_PLAN, max_chars=MAX_PLAN_CHARS,
             touch=True):
    """The ONLY memory a planner call receives: <= limit active, non-
    sensitive, AI-allowed facts of the topic's types that share a word with
    the goal, masked with the run's vault, total text <= max_chars."""
    types = TOPIC_TYPES.get(topic or "", TOPIC_TYPES[""])
    rows = list(_qs(user).filter(status="active", sensitive=False, kind__in=types)
                .order_by("-updated_at")[:MAX_FACTS_PER_USER])
    if not rows:
        return []
    goal_toks = _tokens(goal_text)
    scored = []
    for r in rows:
        node = unseal_node(r)
        if not node or node.get("use_in_ai") is False:
            continue
        if is_sensitive(node.get("label"), node.get("value"), node.get("relation")):
            continue                               # belt and braces
        sc = _overlap(goal_toks, node)
        if sc > 0:
            scored.append((sc, r, node))
    scored.sort(key=lambda x: (-x[0], -(x[1].updated_at.timestamp())))
    out, used, total = [], [], 0
    for _, r, node in scored[:limit]:
        fact = vault.mask(_render(r, node))[:300]
        if total + len(fact) > max_chars:
            break
        total += len(fact)
        out.append({"id": r.id, "type": r.kind, "fact": fact})
        used.append(r.id)
    if used and touch:
        _qs(user).filter(pk__in=used).update(last_used_at=_now())
    return out


# ------------------------------------------------------------------ agent tools
def tool_recall(ctx, a):
    q = (a.get("query") or "").strip()
    kind = a.get("type") or ""
    qs = _qs(ctx.user).filter(status="active")
    if kind:
        qs = qs.filter(kind=kind)
    toks = _tokens(q)
    hits, hidden = [], 0
    for r in qs.order_by("-updated_at")[:MAX_FACTS_PER_USER]:
        node = unseal_node(r)
        if not node:
            continue
        if r.sensitive or node.get("use_in_ai") is False:
            # sensitive / "not for AI" facts never enter a run (its results
            # can reach the planner); the user sees them on the AI knows page
            if not toks or _overlap(toks, node):
                hidden += 1
            continue
        sc = _overlap(toks, node) if toks else 1
        if sc > 0:
            hits.append((sc, r, node))
    hits.sort(key=lambda x: (-x[0], -(x[1].updated_at.timestamp())))
    lim = int(a.get("limit") or 5)
    items = [{"id": r.id, "type": r.kind, "label": n.get("label") or "",
              "value": n.get("value") or "", "relation": n.get("relation") or "",
              "when": n.get("when") or ""}
             for _, r, n in hits[:lim]]
    if items:
        _qs(ctx.user).filter(pk__in=[i["id"] for i in items]).update(last_used_at=_now())
    return {"query": q, "count": len(hits), "items": items, "hidden": hidden}


_HIDDEN_LINE = ("স্পর্শকাতর বা “AI-তে নয়” চিহ্নিত তথ্য এজেন্টকে দেখানো হয় না — “AI কী জানে” পাতায় দেখুন।",
                "Facts marked sensitive or “not for AI” are never shown to the agent — see the “AI knows” page.")


def tool_recall_sum(o, lang):
    if not o["count"] and o.get("hidden"):
        return _pick(lang, *_HIDDEN_LINE)
    if not o["count"]:
        return _pick(lang, "এ বিষয়ে আমার কাছে আপনার কোনো তথ্য রাখা নেই। “AI কী জানে” পাতায় নিজে যোগ করতে পারেন।",
                     "I have nothing saved about that. You can add it on the “AI knows” page.")
    lines = []
    for i in o["items"]:
        s = i["label"] + (" (%s)" % i["relation"] if i["relation"] else "")
        if i["value"]:
            s += ": " + i["value"]
        if i["when"]:
            s += "; " + i["when"]
        lines.append("• " + s)
    head = _pick(lang, "আপনার রাখা তথ্য:", "What you have saved:")
    tail = ("\n" + _pick(lang, *_HIDDEN_LINE)) if o.get("hidden") else ""
    return head + "\n" + "\n".join(lines) + tail


def _run_prov(ctx, tool):
    run = None
    m = re.match(r"ac:(\d+):", ctx.idem_key or "")
    if m:
        run = int(m.group(1))
    return {"run": run, "tool": tool}


def tool_remember(ctx, a):
    row, why = suggest(ctx.user, a.get("type") or "", a.get("label") or "", a.get("value") or "",
                       "run", relation=a.get("relation") or "", when=a.get("when") or "",
                       prov=_run_prov(ctx, "memory.remember"),
                       fp_key="run|%s" % (ctx.idem_key or "") if ctx.idem_key else "",
                       confidence=None)
    if row is None and why == "exists" and ctx.idem_key:
        # idempotent re-run of the same step
        from ..models import MemoryItem
        prev = MemoryItem.graph.filter(user=ctx.user, fingerprint=fingerprint(
            ctx.user.id, "run|%s" % ctx.idem_key)).first()
        if prev is not None:
            return {"suggested": prev.status == "suggested", "id": prev.id, "refused": ""}
    if row is None:
        return {"suggested": False, "id": 0,
                "refused": why if why in ("secret", "id_number", "full", "bad_type", "empty") else ""}
    return {"suggested": True, "id": row.id, "refused": ""}


def tool_remember_sum(o, lang):
    r = o.get("refused")
    if r in ("secret", "id_number"):
        return _pick(lang, "পাসওয়ার্ড, পিন, OTP, কার্ড/অ্যাকাউন্ট বা NID নম্বর আমি কখনো মনে রাখি না — "
                           "এগুলো কাউকে দেবেন না, আমাকেও না।",
                     "I never remember passwords, PINs, OTPs, card/account or NID numbers — "
                     "never share them with anyone, me included.")
    if r == "full":
        return _pick(lang, "মেমরি পূর্ণ — পুরনো কিছু তথ্য মুছে আবার চেষ্টা করুন।",
                     "Memory is full — delete some old facts and try again.")
    if not o.get("suggested"):
        return _pick(lang, "এটি আগেই রাখা আছে বা প্রস্তাব করা আছে।",
                     "This is already saved or suggested.")
    return _pick(lang, "প্রস্তাব রাখা হলো — “AI কী জানে” পাতায় “রাখুন” চাপলে তবেই মনে রাখব।",
                 "Suggested — I will remember it only after you tap “Keep” on the “AI knows” page.")


def tool_update(ctx, a):
    target = _qs(ctx.user).filter(pk=a.get("id"), status="active").first()
    if target is None:
        return {"suggested": False, "id": 0, "refused": "not_found"}
    tnode = unseal_node(target)
    row, why = suggest(ctx.user, target.kind, a.get("label") or tnode.get("label") or "",
                       a.get("value") or "", "run", relation=a.get("relation") or "",
                       when=a.get("when") or "", prov=_run_prov(ctx, "memory.update"),
                       fp_key="run|%s" % (ctx.idem_key or "") if ctx.idem_key else "",
                       replaces=target.id)
    if row is None:
        return {"suggested": False, "id": 0,
                "refused": why if why in ("secret", "id_number", "full", "empty") else ""}
    return {"suggested": True, "id": row.id, "refused": ""}


def tool_update_sum(o, lang):
    if o.get("refused") == "not_found":
        return _pick(lang, "এমন কোনো তথ্য পাওয়া যায়নি — কিছু বদলানো হয়নি।",
                     "No such fact was found — nothing was changed.")
    if o.get("refused") or not o.get("suggested"):
        return tool_remember_sum(o, lang)
    return _pick(lang, "বদলের প্রস্তাব রাখা হলো — “AI কী জানে” পাতায় অনুমোদন করলে তবেই বদলাবে।",
                 "Change suggested — it changes only after you approve it on the “AI knows” page.")


def tool_forget(ctx, a):
    row = _qs(ctx.user).filter(pk=a.get("id")).exclude(status="rejected").first()
    if row is None:
        return {"id": a.get("id") or 0, "deleted": False, "label": ""}
    label = (unseal_node(row).get("label") or "")[:80]
    row.delete()
    _log(ctx.user, "memory.graph.delete", id=a.get("id"), by="agent")
    return {"id": a.get("id"), "deleted": True, "label": label}


def tool_forget_sum(o, lang):
    if not o["deleted"]:
        return _pick(lang, "তথ্যটি পাওয়া যায়নি — কিছু মোছা হয়নি।", "Fact not found — nothing was deleted.")
    return _pick(lang, "ভুলে গেছি — মুছে ফেলা হয়েছে: “%s”।" % o["label"],
                 "Forgotten — deleted: “%s”." % o["label"])


def tool_forget_title(ctx, a, lang):
    row = _qs(ctx.user).filter(pk=a.get("id")).first()
    lab = (unseal_node(row).get("label") or "") if row else "#%s" % a.get("id")
    return _pick(lang, "মেমরি থেকে মুছবেন: “%s”?" % lab, "Delete from memory: “%s”?" % lab)


# ------------------------------------------------------------------ retention
def _months(n):
    return timedelta(days=30 * int(n))


def retention_sweep(user, now=None):
    """-> {"deleted": n, "asked": n, "expired_suggestions": n, "old_rejected": n}"""
    now = now or _now()
    p = prefs_for(user)
    keep = _months(p.retention_months or DEFAULT_RETENTION_MONTHS)
    ask = keep - _months(STALE_ASK_BEFORE_MONTHS)
    st = {"deleted": 0, "asked": 0, "expired_suggestions": 0, "old_rejected": 0}
    for r in _qs(user).filter(status="active"):
        last = max(x for x in (r.updated_at, r.last_used_at, r.created_at) if x)
        if last < now - keep:
            r.delete()
            st["deleted"] += 1
        elif last < now - ask and not r.needs_review:
            type(r).all_rows.filter(pk=r.pk).update(needs_review=True)   # keep updated_at
            st["asked"] += 1
    st["expired_suggestions"], _ = _qs(user).filter(
        status="suggested", created_at__lt=now - SUGGESTION_TTL).delete()
    st["old_rejected"], _ = _qs(user).filter(
        status="rejected", updated_at__lt=now - REJECTED_TTL).delete()
    return st


# ------------------------------------------------------------------ weekly learning
def _module_on(key, user):
    try:
        from .. import feature_flags as FF
        return FF.is_on(key, user, True)
    except Exception:
        return False


def _num_bn(v, lang):
    from ..ai_prompt import to_bn_digits
    s = "{:,}".format(int(round(float(v))))
    return to_bn_digits(s) if lang == "bn" else s


def _median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]


def rule_recurring_expenses(user, now, lang):
    """Same expense category on about the same day of the month (±3 days),
    about the same amount (±15%), in >= 3 of the last 4 months."""
    from ..models import Transaction
    since = timezone.localdate(now) - timedelta(days=125)
    by_cat = {}
    for t in Transaction.objects.filter(user=user, kind="expense", date__gte=since).only(
            "category", "date", "amount"):
        cat = _clean(t.category, 60)
        if not cat or is_sensitive(cat):
            continue
        by_cat.setdefault(_norm(cat), (cat, []))[1].append(t)
    out = []
    for key, (cat, rows) in by_cat.items():
        per_month = {}
        for t in rows:
            per_month.setdefault((t.date.year, t.date.month), t)
        if len(per_month) < 3:
            continue
        days = [t.date.day for t in per_month.values()]
        amts = [float(t.amount) for t in per_month.values()]
        md, ma = _median(days), _median(amts)
        if ma <= 0:
            continue
        if all(abs(d - md) <= 3 for d in days) and all(abs(a - ma) <= 0.15 * ma for a in amts):
            if lang == "bn":
                value = "প্রতি মাসের ~%s তারিখে, প্রায় ৳%s" % (_num_bn(md, lang), _num_bn(ma, lang))
            else:
                value = "Every month around day %d, about ৳%s" % (md, _num_bn(ma, lang))
            out.append(dict(kind="routine", label=cat, value=value,
                            when=_pick(lang, "মাসিক", "monthly"),
                            fp_key="learn|recurring|" + key, rule="recurring_expense",
                            confidence=round(min(1.0, len(per_month) / 4.0), 2)))
    return out


_CIRCLE_SKIP = ("", "friend", "other", "colleague")


def rule_circle_people(user, now, lang):
    """Accepted My Circle members with a family relation — never a phone."""
    from ..models import CircleMember
    out = []
    qs = (CircleMember.objects.filter(user=user, state="accepted")
          .select_related("peer_user").order_by("-id")[:30])
    for m in qs:
        rel = _clean(m.custom_label or m.relation, 40)
        if (m.relation or "") in _CIRCLE_SKIP and not m.custom_label:
            continue
        name = _clean(m.name or (getattr(m.peer_user, "name", "") if m.peer_user_id else ""), 80)
        if not name:
            continue
        out.append(dict(kind="person", label=name, relation=rel,
                        value=_pick(lang, "আপনার My Circle-এ আছেন", "In your My Circle"),
                        fp_key="learn|circle|%d" % m.id, rule="circle_contact", confidence=0.9))
    return out


def rule_journey_routines(user, now, lang):
    """>= 3 Safe Journeys to the same named destination in 5 weeks, started
    within about an hour of the same time. Only the place NAME — never
    coordinates."""
    from ..models import Journey
    since = now - timedelta(days=35)
    by_dest = {}
    for j in Journey.objects.filter(traveller=user, created_at__gte=since).only("destination", "created_at"):
        name = _clean((j.destination or {}).get("name"), 80)
        if not name or is_sensitive(name):
            continue
        by_dest.setdefault(_norm(name), (name, []))[1].append(timezone.localtime(j.created_at))
    out = []
    for key, (name, times) in by_dest.items():
        if len(times) < 3:
            continue
        mins = [t.hour * 60 + t.minute for t in times]
        mm = _median(mins)
        if all(abs(m - mm) <= 60 for m in mins):
            hh = "%02d:%02d" % (mm // 60, (mm % 60) // 15 * 15)
            from ..ai_prompt import to_bn_digits
            value = (_pick(lang, "সাধারণত ~%s-এ নিরাপদ যাত্রা শুরু করেন" % to_bn_digits(hh),
                           "Usually starts a Safe Journey here around %s" % hh))
            out.append(dict(kind="routine", label=name, value=value, when=hh,
                            fp_key="learn|journey|" + key, rule="journey_routine",
                            confidence=round(min(1.0, len(times) / 5.0), 2)))
    return out


RULES = (
    ("money", rule_recurring_expenses),
    ("", rule_circle_people),
    ("safe_journey", rule_journey_routines),
)


def learn_for_user(user, now=None, force=False):
    """One weekly learning pass for one user. Idempotent: every proposal has a
    stable fingerprint (rule + key), so a re-run (or a rejected suggestion)
    is never proposed again; and a pass inside LEARN_EVERY is skipped."""
    from ..models import AgentMemoryPrefs
    now = now or _now()
    st = {"suggested": 0, "skipped": 0, "paused": 0, "too_soon": 0}
    p = prefs_for(user)
    if p.learning_paused:
        st["paused"] = 1
        return st
    if not force and p.last_learned_at and now - p.last_learned_at < LEARN_EVERY:
        st["too_soon"] = 1
        return st
    lang = "en" if (getattr(user, "language", "bn") or "bn") == "en" else "bn"
    budget = MAX_LEARN_PER_WEEK
    for flag, rule in RULES:
        if budget <= 0:
            break
        if flag and not _module_on(flag, user):
            continue
        try:
            props = rule(user, now, lang)
        except Exception:      # one broken rule never stops the others
            props = []
        for pr in props:
            if budget <= 0:
                break
            row, why = suggest(user, pr["kind"], pr["label"], pr.get("value", ""), "learn",
                               relation=pr.get("relation", ""), when=pr.get("when", ""),
                               prov={"rule": pr["rule"]}, fp_key=pr["fp_key"],
                               confidence=pr.get("confidence"))
            if row is not None:
                st["suggested"] += 1
                budget -= 1
            else:
                st["skipped"] += 1
    AgentMemoryPrefs.objects.update_or_create(user=user, defaults={"last_learned_at": now})
    return st


def weekly_tick(users=None, now=None, force=False):
    """Cron entry (manage.py agent_memory_learn). Flag `agent_core` OFF for a
    user -> nothing is learned or swept for them."""
    from ..models import User
    from .proactive import flag_on
    now = now or _now()
    stats = {"users": 0, "suggested": 0, "paused": 0, "too_soon": 0, "deleted": 0,
             "asked": 0, "expired_suggestions": 0, "skipped_flag": 0}
    if users is None:
        users = User.objects.filter(is_active=True).order_by("id").iterator()
    for u in users:
        if not flag_on(u):
            stats["skipped_flag"] += 1
            continue
        stats["users"] += 1
        r = retention_sweep(u, now)
        for k in ("deleted", "asked", "expired_suggestions"):
            stats[k] += r[k]
        lr = learn_for_user(u, now, force=force)
        for k in ("suggested", "paused", "too_soon"):
            stats[k] += lr[k]
    return stats


def json_bytes(data):
    return json.dumps(data, ensure_ascii=False, indent=1, default=str).encode("utf-8")
