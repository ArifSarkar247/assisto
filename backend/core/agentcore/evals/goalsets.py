"""Load a topic's committed eval set (<topic>.jsonl) and resolve the
date-dependent placeholders against today's seed expectations."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TOPICS = ("family", "safety", "documents", "travel", "health", "learning", "business")
# per-topic CI pass bar (owner: CI mode 100%; .github/workflows/agent-eval.yml)
THRESHOLDS = {t: 1.0 for t in TOPICS}

_REMIT = {"missing": ("এখনো আসেনি", "has not arrived"), "waiting": ("এখনো আসার সময় আছে", "not due yet")}


def resolve(value, lang):
    from .fixtures_topics import expect
    if value == "$remit_state":
        bn, en = _REMIT[expect()["remit_status"]]
        return bn if lang == "bn" else en
    return value


def load(topic):
    out = []
    with open(os.path.join(HERE, "%s.jsonl" % topic), encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            c = json.loads(line)
            e = c["expect"]
            e["answer_has"] = [resolve(v, c["lang"]) for v in e.get("answer_has") or []]
            out.append(c)
    return out
