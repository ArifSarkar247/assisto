"""p2lang — LANGUAGE PARTNER framework HTTP API (flag `language_packs`).

  GET  /learn/catalog                     8 language cards (owner order) + real state + today's AI allowance
  GET  /learn/pack/<lang>                 the pack without answer keys / AI role text
  POST /learn/<lang>/placement  {answers:{qid: optionIndex}}      -> level + weak areas (+ stored)
  POST /learn/<lang>/mock       {mock_id, answers, texts, seconds} -> estimated level + weak areas (+ stored)
  POST /learn/<lang>/roleplay   {scenario_id, history:[{role,content}], message}
  GET  /learn/results                     my stored results (newest first) — the certificate agent reads these

Key-free practice (lessons, placement, mock, pronunciation) is unlimited and
free. AI role-play turns: FREE_AI_PER_DAY free (PAID_AI_PER_DAY on a paid plan),
then charged in credits through the AI router (40% rule). Results are stored
server-side in PaCollectionItem(collection='learn_results') so a certificate
can only be issued for a result the server graded itself.
"""
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import langpacks as LP

R = Response
FLAG = "language_packs"
RESULTS = "learn_results"
QUOTA = "learn_aiquota"
MAX_MSG = 600
MAX_TURNS = 12


def flag_on(user, key=FLAG):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(key, user))
    except Exception:
        return False


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _bad(reason, status=400):
    return R({"ok": False, "reason": reason}, status=status)


def _today():
    return timezone.localdate().isoformat()


def _plan(user):
    try:
        from . import plans
        return plans.effective_plan(user)
    except Exception:
        return "free"


def _quota_row(user):
    from .models import PaCollectionItem
    row = PaCollectionItem.objects.filter(user=user, collection=QUOTA).first()
    if row is None:
        row = PaCollectionItem.objects.create(user=user, collection=QUOTA, data={})
    return row


def quota_left(user):
    row = _quota_row(user)
    used = int(row.data.get("n") or 0) if row.data.get("day") == _today() else 0
    return max(0, LP.ai_allowance(_plan(user)) - used)


def _use_quota(user):
    row = _quota_row(user)
    d = row.data if row.data.get("day") == _today() else {"day": _today(), "n": 0}
    d["n"] = int(d.get("n") or 0) + 1
    row.data = d
    row.save(update_fields=["data", "updated_at"])


def store_result(user, kind, lang, graded):
    """Keep the server-graded result (certificate seam)."""
    from .models import PaCollectionItem
    rec = LP.course_result(lang, graded["level"], graded["score_pct"], _today())
    rec.update({"kind": kind, "weak": graded.get("weak", []),
                "mock_id": graded.get("mock_id", "")})
    row = PaCollectionItem.objects.create(user=user, collection=RESULTS, data=rec)
    return dict(rec, id=row.id)


def cert_offer(user, lang, graded):
    """learnwire: the signed certificate offer for a server-graded result
    ({course, level, score, token}) or None. The app shows "Get my
    certificate" only when this is present AND the learning_certificate
    flag is on; the certificate itself is still issued by /learn/certs/claim."""
    from . import learn_cert
    return learn_cert.offer_for_result(user, lang, graded.get("level"), graded.get("score_pct"))


def results_for(user):
    """Public seam for agent/learncert: the user's server-graded results."""
    from .models import PaCollectionItem
    return [dict(r.data, id=r.id) for r in
            PaCollectionItem.objects.filter(user=user, collection=RESULTS).order_by("-id")[:50]]


def _pack_or_404(lang):
    p = LP.load(lang)
    return p, (None if p is not None else _bad("no_pack", 404))


class LearnCatalogView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not flag_on(request.user):
            return _off()
        return R({"languages": LP.catalog(), "estimate_label": LP.ESTIMATE_LABEL,
                  "ai_left_today": quota_left(request.user),
                  "ai_free_per_day": LP.ai_allowance(_plan(request.user))})


class LearnPackView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, lang):
        if not flag_on(request.user):
            return _off()
        p, err = _pack_or_404(lang)
        if err:
            return err
        from . import ai
        out = LP.public_pack(p)
        out["ai_ready"] = bool(ai.available())
        out["estimate_label"] = LP.ESTIMATE_LABEL
        return R(out)


class LearnPlacementView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, lang):
        if not flag_on(request.user):
            return _off()
        p, err = _pack_or_404(lang)
        if err:
            return err
        answers = (request.data or {}).get("answers")
        if not isinstance(answers, dict) or not answers:
            return _bad("no_answers")
        g = LP.grade_placement(p, answers)
        g["result"] = store_result(request.user, "placement", lang, g)
        g["cert"] = cert_offer(request.user, lang, g)
        return R(dict(g, ok=True, estimate_label=LP.ESTIMATE_LABEL))


class LearnMockView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, lang):
        if not flag_on(request.user):
            return _off()
        p, err = _pack_or_404(lang)
        if err:
            return err
        d = request.data or {}
        answers = d.get("answers") if isinstance(d.get("answers"), dict) else {}
        texts = d.get("texts") if isinstance(d.get("texts"), dict) else {}
        texts = {str(k): str(v)[:6000] for k, v in texts.items()}
        try:
            seconds = max(0, int(d.get("seconds") or 0))
        except (TypeError, ValueError):
            seconds = 0
        g = LP.grade_mock(p, str(d.get("mock_id") or ""), answers, texts, seconds)
        if g is None:
            return _bad("bad_mock")
        if not answers and not any(texts.values()):
            return _bad("no_answers")
        g["result"] = store_result(request.user, "mock", lang, g)
        g["cert"] = cert_offer(request.user, lang, g)
        return R(dict(g, ok=True, estimate_label=LP.ESTIMATE_LABEL))


_ROLE_SYS = (
    "You are a language practice partner inside a phone app. Stay in the role "
    "described below and speak ONLY in the target language ({lang}), with short, "
    "natural sentences suitable for a {level} learner. After your reply, if the "
    "learner's last message had a clear mistake, add ONE short correction. Reply "
    'with JSON only: {{"reply": "<your line in {lang}>", "fix_en": "<correction '
    'in English or empty>", "fix_bn": "<the same in simple Bangla or empty>"}}. '
    "Never ask for personal documents, money or real contact details.\nRole: {role}"
)


class LearnRoleplayView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, lang):
        if not flag_on(request.user):
            return _off()
        p, err = _pack_or_404(lang)
        if err:
            return err
        d = request.data or {}
        sc = next((s for s in p.get("scenarios") or [] if s["id"] == d.get("scenario_id")), None)
        if sc is None:
            return _bad("bad_scenario")
        msg = str(d.get("message") or "").strip()
        if not msg:
            return _bad("empty")
        if len(msg) > MAX_MSG:
            return _bad("too_long")
        history = []
        for h in (d.get("history") or [])[-MAX_TURNS:]:
            if isinstance(h, dict) and h.get("role") in ("user", "assistant"):
                history.append({"role": h["role"], "content": str(h.get("content") or "")[:MAX_MSG]})
        if not history:
            history = [{"role": "assistant", "content": sc["opening"]}]
        from . import ai
        if not ai.available():
            return R({"ok": True, "ai_state": "no_key", "reply": None})
        free = quota_left(request.user) > 0
        meta = next(l for l in LP.LANGUAGES if l["code"] == lang)
        level = str(d.get("level") or "beginner")[:12]
        out_meta = {}
        try:
            text, _ = ai.generate(
                task=msg, tier="cheap", feature="learn.roleplay", max_tokens=300,
                user=None if free else request.user, history=history,
                extra_system=_ROLE_SYS.format(lang=meta["name_en"], level=level, role=sc["ai_role"]),
                out_meta=out_meta, pii=True)
        except ai.AIUnavailable as e:
            st = e.reason if e.reason in ("credits", "budget", "user_limit") else "busy"
            return R({"ok": True, "ai_state": st, "reply": None})
        except Exception:  # noqa: BLE001
            return R({"ok": True, "ai_state": "busy", "reply": None})
        if free:
            _use_quota(request.user)
        import json
        import re
        reply, fix_en, fix_bn = text.strip(), "", ""
        m = re.search(r"\{.*\}", text or "", re.S)
        if m:
            try:
                j = json.loads(m.group(0))
                reply = str(j.get("reply") or "").strip() or reply
                fix_en = str(j.get("fix_en") or "")[:300]
                fix_bn = str(j.get("fix_bn") or "")[:300]
            except ValueError:
                pass
        return R({"ok": True, "ai_state": "used", "reply": reply[:800], "fix_en": fix_en,
                  "fix_bn": fix_bn, "free": free,
                  "credits_charged": 0 if free else int(out_meta.get("charged") or 0),
                  "ai_left_today": quota_left(request.user)})


class LearnResultsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        # reading my own results is never flag-gated (privacy / certificate)
        return R({"results": results_for(request.user)})

