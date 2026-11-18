"""lpcore — Language Partner V2 HTTP API (contract: owner_actions/LANGUAGE_PARTNER_API.md).
Flag `language_packs`. Every score carries the practice label; nothing here
ever claims an official IELTS / JLPT result. Logic lives in lp_service."""
from django.http import HttpResponse
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import lp_service as LS
from .logic import lp_bands as B
from .logic import lp_score as SC

R = Response
MAX_HISTORY, MAX_MSG = 12, 600


def _bad(reason, status=400, **extra):
    return R(dict({"ok": False, "reason": reason}, **extra), status=status)


class _LpView(APIView):
    """Auth + flag + the owner-account-in-tests guard on every endpoint."""
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        self.lp_refused = None
        if LS.owner_in_test(request.user):
            self.lp_refused = _bad("owner_account_in_test", 403)
        elif not LS.flag_on(request.user):
            self.lp_refused = _bad("feature_off", 403)

    def handle(self, fn, *a, **kw):
        return self.lp_refused or fn(*a, **kw)


def _mock_or_404(mid):
    m = LS.live_item(str(mid)[:80], "mock")
    return m, (None if m is not None else _bad("not_found", 404))


class LpMocksView(_LpView):
    def get(self, request):
        return self.handle(self._get, request)

    def _get(self, request):
        kind = request.query_params.get("kind") or "academic"
        track = LS.TRACKS.get(kind, "ielts_ac")
        mocks = sorted(LS.live_latest("mock", track), key=lambda m: m.key)
        g = LS.gates(request.user)
        return R({"mocks": [LS.mock_summary(m) for m in mocks],
                  "free_sections_left_week": g["free_sections_left_week"],
                  "next_free_at": g["next_free_at"], "premium": g["premium"],
                  "practice_label": B.PRACTICE_LABEL})


class LpMockView(_LpView):
    def get(self, request, mid):
        return self.handle(self._get, request, mid)

    def _get(self, request, mid):
        m, err = _mock_or_404(mid)
        if err:
            return err
        section = request.query_params.get("section") or ""
        if section and section not in LS.section_ids(m):
            return _bad("bad_section")
        if not section and not LS.is_premium(request.user):
            return _bad("premium", 402)
        if section:
            ok, why = LS.use_section_slot(request.user, m.key, section)
            if not ok and request.query_params.get("pay") == "credits":
                ok, why = LS.pay_section(request.user, m.key, section)
            if not ok:
                return _bad(why, 402, next_free_at=LS.next_free_at(request.user),
                            unlock_credits=LS.SECTION_UNLOCK_CREDITS)
        return R(LS.mock_payload(m, section or None))


class LpMarkView(_LpView):
    def post(self, request, mid):
        return self.handle(self._post, request, mid)

    def _post(self, request, mid):
        m, err = _mock_or_404(mid)
        if err:
            return err
        d = request.data or {}
        section = d.get("section")
        if section not in (LS.section_ids(m) if LS.is_track(m) else LS.OBJECTIVE):
            return _bad("bad_section")
        answers = d.get("answers")
        if not isinstance(answers, dict) or len(answers) > 60:
            return _bad("bad_answers")
        if not LS.is_premium(request.user):
            ok, why = LS.use_section_slot(request.user, m.key, section)
            if not ok:
                return _bad(why, 402, next_free_at=LS.next_free_at(request.user))
        res = LS.mark_section(request.user, m, section, answers)
        if res is None:
            return _bad("not_found", 404)
        return R(res)


class LpFinishView(_LpView):
    def post(self, request, mid):
        return self.handle(self._post, request, mid)

    def _post(self, request, mid):
        m, err = _mock_or_404(mid)
        if err:
            return err
        d = request.data or {}
        if not isinstance(d.get("bands"), dict):
            return _bad("bad_bands")
        return R(LS.finish_mock(request.user, m, d["bands"], d.get("weak") or []))


class LpWeakPracticeView(_LpView):
    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        tags = (request.data or {}).get("tags") or []
        if not isinstance(tags, list) or not tags:
            return _bad("bad_tags")
        try:
            n = max(1, min(20, int((request.data or {}).get("n") or 10)))
        except (TypeError, ValueError):   # gap-lp: a bad "n" is a 400, never a 500
            return _bad("bad_n")
        return R({"items": LS.weak_items(tags, n), "tags": tags[:10]})


class LpPracticeMarkView(_LpView):
    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        answers = (request.data or {}).get("answers")
        if not isinstance(answers, dict):
            return _bad("bad_answers")
        return R(LS.mark_practice(request.user, answers))


def _level(d):
    lv = str(d.get("level") or "normal")
    return lv if lv in SC.LEVELS else "normal"


class LpScoreWritingView(_LpView):
    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        d = request.data or {}
        try:
            task = int(d.get("task") or 2)
        except (TypeError, ValueError):
            return _bad("bad_task")
        if task not in (1, 2):
            return _bad("bad_task")
        text = str(d.get("text") or "").strip()
        if len(B.words(text)) < 20:
            return _bad("too_short")
        if len(text) > SC.MAX_WRITING_CHARS:
            return _bad("too_long")
        prompt = str(d.get("prompt") or "").strip()
        mock_id = str(d.get("mock_id") or "")[:80]
        variant = "general" if d.get("variant") == "general" else "academic"
        if mock_id:
            m = LS.live_item(mock_id, "mock")
            sec = LS.mock_sections(m).get("writing") if m else None
            for t in ((sec.data.get("body") or {}).get("tasks") or []) if sec else []:
                if t.get("n") == task:
                    prompt = t.get("prompt") or prompt
            variant = LS.variant_of(m) if m else variant
        if not prompt:
            return _bad("no_prompt")
        sys_ = SC.writing_system(task, variant)
        t, data = SC.writing_task(prompt, text)
        # a prompt the user typed (e.g. from his own book) is never stored
        meta = {"mock_id": mock_id, "section": "writing", "task": task, "variant": variant,
                "text": text, "words": len(B.words(text))}
        if mock_id:
            meta["prompt"] = prompt[:SC.MAX_PROMPT_CHARS]
        return R(LS.run_score(request.user, "writing", sys_, t, data,
                              SC.WRITING_KEYS[task], _level(d), meta))


class LpScoreSpeakingView(_LpView):
    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        d = request.data or {}
        try:
            part = int(d.get("part") or 1)
        except (TypeError, ValueError):
            return _bad("bad_part")
        if part not in (1, 2, 3):
            return _bad("bad_part")
        tr = str(d.get("transcript") or "").strip()
        if len(B.words(tr)) < 8:
            return _bad("too_short")
        if len(tr) > SC.MAX_SPEAKING_CHARS:
            return _bad("too_long")
        prompt = str(d.get("prompt") or "").strip()
        if not prompt:
            return _bad("no_prompt")
        try:
            secs = max(0, min(900, int(d.get("seconds") or 0))) or None
        except (TypeError, ValueError):
            secs = None
        conf = d.get("confidence")
        conf = float(conf) if isinstance(conf, (int, float)) else None
        mock_id = str(d.get("mock_id") or "")[:80]
        t, data = SC.speaking_task(prompt, tr, secs, conf)
        meta = {"mock_id": mock_id, "section": "speaking", "part": part, "transcript": tr,
                "seconds": secs}
        if mock_id:
            meta["prompt"] = prompt[:SC.MAX_PROMPT_CHARS]
        return R(LS.run_score(request.user, "speaking", SC.speaking_system(part), t, data,
                              SC.SPEAKING_KEYS, _level(d), meta))


class LpScorePriceView(_LpView):
    def get(self, request):
        return self.handle(lambda: R(LS.score_price()))


class LpAdTicketView(_LpView):
    """POST /lp/ads/ticket {unlock: section|score} -> AdMob SSV nonce (free users)."""

    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        st, body = LS.issue_ad_ticket(request.user, str((request.data or {}).get("unlock") or ""))
        return R(body, status=st)


class LpGatesView(_LpView):
    def get(self, request):
        return self.handle(lambda: R(LS.gates(request.user)))


class LpContentVersionView(_LpView):
    def get(self, request):
        return self.handle(lambda: R({"life": LS.content_version("scenario"),
                                      "vocab": LS.content_version("vocab"),
                                      "mocks": LS.content_version("mock")}))


class LpContentView(_LpView):
    KIND = {"life": "scenario", "vocab": "vocab", "syllabus": "syllabus", "lesson": "lesson"}

    def get(self, request, kind):
        return self.handle(self._get, request, kind)

    def _get(self, request, kind):
        k = self.KIND.get(kind)
        if k is None:
            return _bad("not_found", 404)
        track = (request.query_params.get("track") or "")[:16] or None
        rows = LS.live_latest(k, None if k == "lesson" else track)
        if k == "lesson" and track:      # a lesson is shared by the tracks of one language
            rows = [it for it in rows if track == it.track or track in (it.data.get("tracks") or [])]
        items = [dict(it.data, id=it.data.get("id") or it.key, beta=it.status != "human_approved")
                 for it in sorted(rows, key=lambda x: x.key)]
        return R({"version": LS.content_version(k), "items": items})


_ROLE_SYS = (
    "You are role-playing to help a Bangladeshi learner practise English for real life. Stay in "
    "your role: {role}. Scenario: {title}. Speak simple, natural English (one to three short "
    "sentences), ask one question at a time and keep the conversation moving. If the learner's "
    "last message has a clear English mistake, give ONE correction. Reply with JSON only: "
    '{{"reply":"<your next line in the role>","fix":null or {{"wrong":"<their words>",'
    '"right":"<correct words>","why_en":"<short reason>","why_bn":"<the reason in simple Bangla>"}}}}'
)


class LpRoleplayView(_LpView):
    """Life English role-play: the learn hub's free daily quota first (the
    same counter as before), then the user's own credits."""

    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        from . import ai
        from . import learn_views as LV
        d = request.data or {}
        sid = str(d.get("scenario_id") or "")[:80]
        it = LS.live_item(sid, "scenario") or LS.live_item("scenario-" + sid, "scenario")
        if it is None:
            return _bad("bad_scenario")
        msg = str(d.get("message") or "").strip()
        if not msg:
            return _bad("empty")
        if len(msg) > MAX_MSG:
            return _bad("too_long")
        sc = it.data or {}
        history = [{"role": h["role"], "content": str(h.get("content") or "")[:MAX_MSG]}
                   for h in (d.get("history") or [])[-MAX_HISTORY:]
                   if isinstance(h, dict) and h.get("role") in ("user", "assistant")]
        if not history and sc.get("opening"):
            history = [{"role": "assistant", "content": str(sc["opening"])[:MAX_MSG]}]
        if not ai.available():
            return R({"ai_state": "no_key", "reply": None, "fix": None})
        free = LV.quota_left(request.user) > 0
        role = str(sc.get("ai_role") or sc.get("role_en") or "a helpful officer")[:120]
        title = str(sc.get("title_en") or sc.get("title") or it.key)[:120]
        meta = {}
        try:
            text, _ = ai.generate(task=msg, tier="cheap", feature="learn.roleplay", max_tokens=400,
                                  user=None if free else request.user, history=history,
                                  extra_system=_ROLE_SYS.format(role=role, title=title),
                                  out_meta=meta, pii=True)
        except ai.AIUnavailable as e:
            st = e.reason if e.reason in ("credits", "budget", "user_limit") else "busy"
            return R({"ai_state": st, "reply": None, "fix": None})
        except Exception:  # noqa: BLE001
            return R({"ai_state": "busy", "reply": None, "fix": None})
        reply, fix = role_reply(text)
        if not reply:
            # gap-lp: never show raw / cut JSON as the officer's line, and an
            # unusable answer costs nothing (no free turn used, credits back)
            charged = 0 if free else int(meta.get("charged") or 0)
            if charged:
                from . import billing
                billing.credit(request.user, "adjust", charged, note="ai_refund learn.roleplay",
                               spend_ref=meta.get("spend_ref") or None)
            return R({"ai_state": "busy", "reply": None, "fix": None, "refunded": charged})
        if free:
            LV._use_quota(request.user)
        return R({"ai_state": "used", "reply": reply[:800], "fix": fix, "free": free,
                  "credits_used": 0 if free else int(meta.get("charged") or 0),
                  "ai_left_today": LV.quota_left(request.user)})


def role_reply(text):
    """(reply, fix) from the model's role-play answer. gap-lp: a cut or broken
    JSON answer never reaches the learner as raw '{"reply": ...' text — the
    reply string is pulled out, or ('', None) when there is none."""
    import json
    import re
    raw = (text or "").strip()
    m = re.search(r"\{.*\}", raw, re.S)
    if m:
        try:
            j = json.loads(m.group(0))
        except ValueError:
            j = None
        if isinstance(j, dict):
            reply = str(j.get("reply") or "").strip()
            f, fix = j.get("fix"), None
            if isinstance(f, dict) and f.get("wrong") and f.get("right"):
                fix = {k: str(f.get(k) or "")[:300] for k in ("wrong", "right", "why_en", "why_bn")}
            return reply, fix
    if "{" in raw or '"reply"' in raw:
        g = re.search(r'"reply"\s*:\s*"((?:[^"\\]|\\.)*)(")?', raw)
        if not g:
            return "", None
        try:
            out = json.loads('"%s"' % g.group(1)).strip()
        except ValueError:
            out = g.group(1).replace('\\"', '"').strip()
        if not g.group(2):           # cut mid-line: keep whole sentences only
            ends = [i for i, ch in enumerate(out) if ch in ".?!"]
            out = out[:ends[-1] + 1] if ends else ""
        return out, None
    return raw, None


class LpCompanionBooksView(_LpView):
    def get(self, request):
        return self.handle(lambda: R({
            "books": list(LS.COMPANION_BOOKS), "tests": list(LS.COMPANION_TESTS),
            "sections": {"listening": {"duration_sec": 1800, "questions": 40},
                         "reading": {"duration_sec": 3600, "questions": 40}},
            "no_content_line": LS.NO_CONTENT_LINE, "practice_label": B.PRACTICE_LABEL}))


class LpCompanionMarkView(_LpView):
    def post(self, request):
        return self.handle(self._post, request)

    def _post(self, request):
        d = request.data or {}
        try:
            book, test = int(d.get("book")), int(d.get("test"))
        except (TypeError, ValueError):
            return _bad("bad_book")
        if book not in LS.COMPANION_BOOKS or test not in LS.COMPANION_TESTS:
            return _bad("bad_book")
        section = d.get("section")
        if section not in LS.OBJECTIVE:
            return _bad("bad_section")
        extra = set(d.keys()) - {"book", "test", "section", "variant", "answers", "key"}
        if extra:
            # only answers + the user's own key are accepted: no question text, no passages
            return _bad("bad_field", fields=sorted(extra)[:5])
        answers, key = LS.clean_cells(d.get("answers")), LS.clean_cells(d.get("key"))
        if answers is None or key is None:
            return _bad("bad_cell")
        if not key:
            return _bad("no_key")
        variant = "general" if d.get("variant") == "general" else "academic"
        return R(LS.companion_mark(request.user, book, test, section, variant, answers, key))


class LpCompanionSheetsView(_LpView):
    def get(self, request):
        return self.handle(self._get, request)   # gap-lp: flag + owner guard here too

    def _get(self, request):
        from .models import LpAttempt
        rows = LpAttempt.objects.filter(user=request.user, kind="companion").order_by("-id")[:50]
        # an old sheet may still hold a typed key: it is never sent back
        return R({"sheets": [dict({k: v for k, v in (r.data or {}).items() if k != "key"},
                                  id=r.id, section=r.section, band=r.band,
                                  created_at=r.created_at.isoformat()) for r in rows]})


class LpCertificateView(_LpView):
    def get(self, request, pk):
        if self.lp_refused:
            return self.lp_refused
        from .models import LpAttempt
        att = LpAttempt.objects.filter(pk=pk, user=request.user, kind="result").first()
        if att is None:
            return _bad("not_found", 404)
        if not (att.data or {}).get("full"):
            # gap-lp: a certificate only for a full mock with four server-given bands
            return _bad("not_full", 404)
        pdf = LS.certificate_pdf(att, getattr(request.user, "name", "") or "")
        resp = HttpResponse(pdf, content_type="application/pdf")
        resp["Content-Disposition"] = 'inline; filename="assisto-practice-certificate-%d.pdf"' % att.id
        return resp
