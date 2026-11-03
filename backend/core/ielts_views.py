"""p2lang — IELTS practice HTTP API (Language Partner, flag `language_packs`, OFF
until the owner's real-phone proof).

  GET  /ielts/content                 prompts, original passages, vocab, sentences, official links
  POST /ielts/writing/check  {task:'t1'|'t2', prompt_id, text, use_ai}
  POST /ielts/speaking/check {part:'p1'|'p2'|'p3', prompt_id, transcript, seconds, confidence, use_ai}
  POST /ielts/reading/grade  {passage_id, answers:{qid: answer}}

The key-free checklist (logic/ielts.py) ALWAYS comes back. The AI band
estimate runs only when the learner asked for it (`use_ai`) AND a key exists;
it goes through core.ai.generate with user=… so plan credits are charged by
the router (refunded if no provider answers). Every AI answer is labelled a
practice estimate, never an official band. Streak and vocab progress live in
the generic per-user collections ielts/practice and ielts/vocab.
"""
import json
import re

from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import ielts as IE

R = Response
FLAG = "language_packs"
MAX_TEXT = 6000


def flag_on(user, key=FLAG):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(key, user))
    except Exception:
        return False


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _bad(reason):
    return R({"ok": False, "reason": reason}, status=400)


_WRITING_TASK = {
    "t1": "General Training Writing Task 1 (a letter, at least 150 words)",
    "t2": "Writing Task 2 (an essay, at least 250 words)",
}

_WRITING_SYS = (
    "You are an experienced IELTS writing tutor. Estimate the learner's level "
    "against the PUBLIC IELTS Writing band descriptors (Task Achievement/Response, "
    "Coherence and Cohesion, Lexical Resource, Grammatical Range and Accuracy). "
    "This is practice feedback, never an official score. Reply with JSON only: "
    '{"criteria":[{"id":"task|coherence|lexical|grammar","band":<number 1-9 in '
    'steps of 0.5>,"en":"<one or two sentences>","bn":"<the same in simple Bangla>"}],'
    '"overall":<number>,"fixes":[{"en":"<concrete fix quoting the learner>",'
    '"bn":"<the same in Bangla>"}]} with at most 4 fixes. Do not rewrite the whole essay.'
)

_SPEAKING_SYS = (
    "You are an experienced IELTS speaking tutor. You only have a speech-to-text "
    "transcript (no punctuation, recogniser errors possible). Estimate against the "
    "PUBLIC IELTS Speaking band descriptors for Fluency and Coherence, Lexical "
    "Resource and Grammatical Range and Accuracy. Pronunciation cannot be judged "
    "from text: for the pronunciation criterion return band null and say that the "
    "app's pronunciation check should be used. This is practice feedback, never an "
    "official score. Reply with JSON only: "
    '{"criteria":[{"id":"fluency|lexical|grammar|pronunciation","band":<number or '
    'null>,"en":"...","bn":"<simple Bangla>"}],"overall":<number>,'
    '"fixes":[{"en":"...","bn":"..."}]} with at most 4 fixes.'
)


def _parse_ai(text, allowed):
    """Model JSON -> safe dict, or None when unusable."""
    m = re.search(r"\{.*\}", str(text or ""), re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except (ValueError, TypeError):
        return None
    crit = []
    for c in j.get("criteria") or []:
        if not isinstance(c, dict) or c.get("id") not in allowed:
            continue
        band = c.get("band")
        if isinstance(band, (int, float)) and 0 <= band <= 9:
            band = round(float(band) * 2) / 2
        else:
            band = None
        crit.append({"id": c["id"], "band": band,
                     "en": str(c.get("en") or "")[:400],
                     "bn": str(c.get("bn") or "")[:400]})
    if not crit:
        return None
    overall = j.get("overall")
    overall = round(float(overall) * 2) / 2 if isinstance(overall, (int, float)) \
        and 0 <= overall <= 9 else None
    fixes = [{"en": str(f.get("en") or "")[:300], "bn": str(f.get("bn") or "")[:300]}
             for f in (j.get("fixes") or [])[:4] if isinstance(f, dict)]
    return {"criteria": crit, "overall": overall, "fixes": fixes, "estimate": True}


def _run_ai(user, system, task, data, feature, allowed):
    """(ai_state, ai_block, credits_charged)."""
    from . import ai
    if not ai.available():
        return "no_key", None, 0
    meta = {}
    try:
        text, _ = ai.generate(task=task, data=data, tier="medium", feature=feature,
                              max_tokens=900, user=user, extra_system=system,
                              out_meta=meta, pii=True)
    except ai.AIUnavailable as e:
        return (e.reason if e.reason in ("no_key", "credits", "budget", "user_limit")
                else "busy"), None, 0
    except Exception:  # noqa: BLE001 — never a 500 for practice feedback
        return "busy", None, 0
    block = _parse_ai(text, allowed)
    if block is None:
        return "unreadable", None, int(meta.get("charged") or 0)
    return "used", block, int(meta.get("charged") or 0)


class IeltsContentView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not flag_on(request.user):
            return _off()
        from . import ai
        out = IE.content()
        out["ai_ready"] = bool(ai.available())
        return R(out)


class IeltsWritingCheckView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not flag_on(request.user):
            return _off()
        d = request.data or {}
        task = str(d.get("task") or "")
        if task not in ("t1", "t2"):
            return _bad("bad_task")
        prompt = IE.writing_prompt(task, str(d.get("prompt_id") or ""))
        if prompt is None:
            return _bad("bad_prompt")
        text = str(d.get("text") or "")
        if not IE.words(text):
            return _bad("empty")
        if len(text) > MAX_TEXT:
            return _bad("too_long")
        out = {"ok": True, "check": IE.writing_check(task, text),
               "estimate_label": IE.ESTIMATE_LABEL, "ai_state": "not_asked",
               "ai": None, "credits_charged": 0}
        if d.get("use_ai") is True:
            state, block, charged = _run_ai(
                request.user, _WRITING_SYS,
                f"Task type: {_WRITING_TASK[task]}.\nQuestion: {prompt['prompt']}\n"
                "Fill both the en and the bn fields.",
                text, "ielts.writing", IE.WRITING_CRITERIA)
            out.update({"ai_state": state, "ai": block, "credits_charged": charged})
        return R(out)


def _speaking_question(part, prompt_id):
    if part == "p1":
        return next((p for p in IE.SPEAKING_P1 if p["id"] == prompt_id), None)
    if part in ("p2", "p3"):
        return next((p for p in IE.SPEAKING_P2 if p["id"] == prompt_id), None)
    return None


class IeltsSpeakingCheckView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not flag_on(request.user):
            return _off()
        d = request.data or {}
        part = str(d.get("part") or "")
        q = _speaking_question(part, str(d.get("prompt_id") or ""))
        if q is None:
            return _bad("bad_prompt")
        transcript = str(d.get("transcript") or "")
        if not IE.words(transcript):
            return _bad("empty")
        if len(transcript) > MAX_TEXT:
            return _bad("too_long")
        try:
            seconds = max(0, min(int(d.get("seconds") or 0), 900))
        except (TypeError, ValueError):
            seconds = 0
        conf = d.get("confidence")
        conf = conf if isinstance(conf, (int, float)) else None
        out = {"ok": True, "check": IE.speaking_check(transcript, seconds, conf),
               "estimate_label": IE.ESTIMATE_LABEL, "ai_state": "not_asked",
               "ai": None, "credits_charged": 0}
        if d.get("use_ai") is True:
            if part == "p1":
                asked = q["topic_en"] + ": " + " / ".join(q["questions"])
            elif part == "p2":
                asked = q["title"] + " You should say: " + "; ".join(q["bullets"])
            else:
                asked = " / ".join(q["p3"])
            state, block, charged = _run_ai(
                request.user, _SPEAKING_SYS,
                f"IELTS Speaking Part {part[1]}. Question(s): {asked}\n"
                f"The learner spoke for about {seconds} seconds.",
                transcript, "ielts.speaking", IE.SPEAKING_CRITERIA)
            out.update({"ai_state": state, "ai": block, "credits_charged": charged})
        return R(out)


class IeltsReadingGradeView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not flag_on(request.user):
            return _off()
        d = request.data or {}
        answers = d.get("answers")
        if not isinstance(answers, dict):
            return _bad("bad_answers")
        g = IE.grade_reading(str(d.get("passage_id") or ""), answers)
        if g is None:
            return _bad("bad_passage")
        lang = req_lang(request)
        g["note"] = pick(lang, "ব্যাখ্যা পড়ে আবার অনুচ্ছেদে খুঁজে দেখুন।",
                         "Read each explanation, then find the line in the passage.")
        return R(dict(g, ok=True))
