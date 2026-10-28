"""maskall (owner order 28 Oct, Einstein-Trust-Layer parity) — PII masking on
EVERY AI text path + the guard that keeps it that way.

* MaskGuardTests (no DB): a source scan of the whole backend. Every call of
  the AI router (`ai.generate(...)`) must pass `pii=` — or be listed in
  ALLOW with the reason it is safe. Direct use of a provider seam
  (`ai._call_*`) and any file that talks to a provider API itself must be
  listed too. A new unmasked path therefore FAILS CI instead of shipping
  silently; a stale allow-list entry fails as well.
* Seam tests: each newly masked feature run end-to-end with the router's
  provider seam recorded — the provider never sees a raw phone / NID /
  account / e-mail, and the user gets the real values back.
* AF-13 retention hygiene: OpenAI requests carry store=false, the SDK
  loggers can't print prompts, an error detail is masked before logging.
No real AI call anywhere (the seams are patched).
"""
import ast
import json
import logging
import os
import re
from unittest import mock

from django.test import SimpleTestCase, TestCase

from core import ai
from core.agentcore import trust as T
from core.tests_aftrust import _P, _router, _Seam
from core.tests_h1_home import _VBase

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------- allow-lists
# "<path relative to backend>::<enclosing function>" -> why this ai.generate
# call may go without pii=. Keep reasons concrete; review on every change.
ALLOW = {
    "core/agentcore/planner.py::plan": (
        "Agent Core planner: build_task/build_data only ever carry text the "
        "runner already masked with the run's sealed Vault (goal.text_masked, "
        "observations/memory/previous turns via vault.mask); the runner "
        "unmasks before a tool runs. Re-masking here would mint a second, "
        "unrelated vault."),
}

# files that may use a provider seam of core.ai directly (not through generate)
SEAM_ALLOW = {
    "core/management/commands/ai_quality_probe.py": (
        "owner-run offline quality probe: a FIXED list of synthetic Bangla "
        "prompts (no user data) sent to each provider for side-by-side review"),
}

# files that talk to an AI provider's API themselves -> what they send and why
PROVIDER_FILES = {
    "core/ai.py": "the AI router itself (masking happens in generate(pii=...))",
    "core/vision_providers.py": (
        "image in chat / sales-agent photo: the IMAGE cannot be masked; the "
        "text that rides with it is masked by chat_vision_service (question + "
        "on-device OCR text); bizagent sends a fixed question + catalog names"),
    "core/bizagent_media.py": (
        "voice-note transcription: the AUDIO cannot be masked; nothing else "
        "is sent (no history, no contacts); the transcript then goes through "
        "the masked sales-agent path"),
    "core/photo_providers.py": (
        "Photo Studio image edit: the image + the edit instruction (<= 500 "
        "chars); masking the instruction would break 'add this text' edits"),
    "core/photo_final.py": "Photo Studio final pass: image + fixed server prompt only",
    "core/photo_restore.py": "Photo restore: image + fixed server prompt only",
    "core/integrations.py": "key tests: list-models / account endpoints only, no content",
    "core/management/commands/ai_token_audit.py": (
        "owner-only count_tokens audit of the shipped prompt templates; "
        "refuses to run in tests/CI; nothing is generated"),
}

_PROVIDER_RX = re.compile(
    r"api\.openai\.com|generativelanguage\.googleapis\.com|api\.anthropic\.com|"
    r"aiplatform\.googleapis\.com|api\.replicate\.com|fal\.run|"
    r"^\s*(?:import|from)\s+(?:anthropic|openai|google\.generativeai|google\.genai)\b",
    re.M)


def _source_files():
    for dp, dn, fn in os.walk(BACKEND):
        dn[:] = [d for d in dn if d not in ("migrations", "__pycache__", "tests", "node_modules",
                                            "static", "media", "venv", ".venv")]
        for f in fn:
            if not f.endswith(".py") or f.startswith("tests") or f.startswith("test_"):
                continue
            p = os.path.join(dp, f)
            yield os.path.relpath(p, BACKEND).replace(os.sep, "/"), p


def _ai_aliases(tree):
    """Names bound to the core.ai module / to core.ai.generate in a file."""
    mods, gens = {"ai", "_ai"}, set()
    for n in ast.walk(tree):
        if isinstance(n, ast.ImportFrom):
            m = n.module or ""
            for a in n.names:
                name = a.asname or a.name
                # from . import ai / from .. import ai as _ai / from core import ai
                if a.name == "ai" and m in ("", "core"):
                    mods.add(name)
                # from .ai import generate / from core.ai import generate
                if a.name == "generate" and (m == "core.ai" or (n.level and m == "ai")):
                    gens.add(name)
        elif isinstance(n, ast.Import):
            for a in n.names:
                if a.name == "core.ai" and a.asname:
                    mods.add(a.asname)
    return mods, gens


def _masked(call):
    """pii= present, not a literal False/None, and no **kwargs (unprovable)."""
    pii = [k for k in call.keywords if k.arg == "pii"]
    if not pii or any(k.arg is None for k in call.keywords):
        return False
    v = pii[0].value
    return not (isinstance(v, ast.Constant) and not v.value)


def calls_in(tree, rel):
    """-> (calls, seams) of one parsed file: calls = [(key, masked, lineno)]
    with key '<rel>::<function>', seams = [(rel, lineno)]."""
    mods, gens = _ai_aliases(tree)
    calls, seams, stack = [], [], []

    class V(ast.NodeVisitor):
        def visit_FunctionDef(self, n):
            stack.append(n.name)
            self.generic_visit(n)
            stack.pop()
        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Attribute(self, n):
            if isinstance(n.value, ast.Name) and n.value.id in mods \
                    and n.attr.startswith("_call_"):
                seams.append((rel, n.lineno))
            self.generic_visit(n)

        def visit_Call(self, n):
            f = n.func
            if (isinstance(f, ast.Attribute) and f.attr == "generate"
                    and isinstance(f.value, ast.Name) and f.value.id in mods) or \
                    (isinstance(f, ast.Name) and f.id in gens):
                calls.append(("%s::%s" % (rel, stack[-1] if stack else "<module>"),
                              _masked(n), n.lineno))
            # getattr(ai, "_call_" + name)
            if isinstance(f, ast.Name) and f.id == "getattr" and len(n.args) > 1 \
                    and isinstance(n.args[0], ast.Name) and n.args[0].id in mods:
                lit = n.args[1]
                if isinstance(lit, ast.BinOp):
                    lit = lit.left
                if isinstance(lit, ast.Constant) and str(lit.value).startswith("_call_"):
                    seams.append((rel, n.lineno))
            self.generic_visit(n)
    V().visit(tree)
    return calls, seams


def scan():
    calls, seams = [], []
    for rel, path in _source_files():
        if rel == "core/ai.py":
            continue
        try:
            with open(path, encoding="utf-8") as f:
                tree = ast.parse(f.read())
        except SyntaxError:
            continue
        c, s = calls_in(tree, rel)
        calls += c
        seams += s
    return calls, seams


class MaskGuardTests(SimpleTestCase):
    def test_every_router_call_masks_or_is_allow_listed(self):
        calls, _ = scan()
        self.assertGreater(len(calls), 20, "the scan found too few ai.generate calls")
        bad = ["%s (line %d)" % (k, ln) for k, ok, ln in calls if not ok and k not in ALLOW]
        self.assertEqual(bad, [], "ai.generate without pii= — mask it (pii=True / a Vault) or "
                                  "add it to ALLOW in core/tests_maskall.py with the reason: %s"
                         % bad)

    def test_allow_list_is_current_and_explained(self):
        calls, seams = scan()
        unmasked = {k for k, ok, _ in calls if not ok}
        for k, why in ALLOW.items():
            self.assertIn(k, unmasked, "stale ALLOW entry (call gone or now masked): " + k)
            self.assertGreater(len(why), 40, k)
        seam_files = {r for r, _ in seams}
        for k, why in SEAM_ALLOW.items():
            self.assertIn(k, seam_files, "stale SEAM_ALLOW entry: " + k)
            self.assertGreater(len(why), 40, k)

    def test_no_direct_provider_seam_outside_the_router(self):
        _, seams = scan()
        bad = sorted({"%s:%d" % (r, ln) for r, ln in seams if r not in SEAM_ALLOW})
        self.assertEqual(bad, [], "direct core.ai._call_* use bypasses masking: %s" % bad)

    def test_provider_api_only_in_listed_files(self):
        found = set()
        for rel, path in _source_files():
            with open(path, encoding="utf-8") as f:
                if _PROVIDER_RX.search(f.read()):
                    found.add(rel)
        extra = sorted(found - set(PROVIDER_FILES))
        self.assertEqual(extra, [], "a file talks to an AI provider directly — route it through "
                                    "ai.generate(pii=...) or list it in PROVIDER_FILES: %s" % extra)
        for rel, why in PROVIDER_FILES.items():
            self.assertIn(rel, found, "stale PROVIDER_FILES entry: " + rel)
            self.assertTrue(why)

    def test_the_scan_catches_a_new_unmasked_call(self):
        src = ("from . import ai\n"
               "def f(t):\n"
               "    return ai.generate('x', data=t)\n"
               "def g(t):\n"
               "    return ai.generate('x', data=t, pii=True)\n"
               "def h(t, **kw):\n"
               "    return ai.generate('x', data=t, pii=True, **kw)\n"
               "def k(t):\n"
               "    return ai.generate('x', data=t, pii=False)\n")
        calls, seams = calls_in(ast.parse(src + "fn = getattr(ai, '_call_' + 'x')\n"), "core/x.py")
        seen = [(k.split("::")[1], ok) for k, ok, _ in calls]
        self.assertEqual(len(seams), 1)
        self.assertEqual(seen, [("f", False), ("g", True), ("h", False), ("k", False)])


# ---------------------------------------------------------------- seam tests
PHONE, NID, EMAIL = "01711223344", "1990123456789", "karim.mask@example.com"
RAW = (PHONE, NID, EMAIL)


def _echo_tokens(prompt):
    """A provider that answers with every vault token it was given."""
    toks = re.findall(r"⟦[A-Z]+_\d+⟧", prompt)
    return "Noted: " + " ".join(dict.fromkeys(toks)) if toks else "Noted."


def _user(credits=500):
    from datetime import timedelta
    from django.utils import timezone
    from core.models import User
    u = User.objects.create_user(name="Mask Test", phone="01811000099", password="x")
    u.plan = "free"
    u.trial_until = timezone.now() - timedelta(days=1)
    u.ai_credits = credits
    u.save()
    return u


class _SeamCase(TestCase):
    def seam(self):
        s = _Seam(reply=_echo_tokens)
        p = _P(_router(s))
        p.__enter__()
        self.addCleanup(p.__exit__)
        return s

    def assert_masked(self, seam, *values):
        self.assertTrue(seam.calls, "no provider call was made")
        sent = seam.sent()
        self.assertFalse(T.has_raw_pii(sent), sent[:600])
        for v in values:
            self.assertNotIn(v, sent)


class HomeChatMaskTests(_SeamCase):
    def test_ai_chat_masks_text_and_history_and_unmasks_reply(self):
        from rest_framework.test import APIClient
        from core.models import ChatMessage, ChatSession
        u = _user()
        c = APIClient()
        c.force_authenticate(u)
        seam = self.seam()
        s = ChatSession.objects.create(user=u, source="ai")
        ChatMessage.objects.create(session=s, role="user", text="my NID is %s" % NID)
        ChatMessage.objects.create(session=s, role="assistant", text="ok, noted")
        r = c.post("/api/v1/chat/sessions/%s/send" % s.id,
                   {"text": "save Karim %s and mail %s" % (PHONE, EMAIL)}, format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        self.assertTrue(r.json()["ai_used"])
        self.assert_masked(seam, *RAW)
        self.assertIn("⟦NID_", json.dumps(seam.calls[-1]["history"], ensure_ascii=False))
        reply = ChatMessage.objects.filter(session=s, role="assistant").last().text
        self.assertIn(PHONE, reply)
        self.assertIn(EMAIL, reply)
        self.assertNotIn("⟦", reply)
        # the model is told what the tokens are
        self.assertIn("⟦PHONE_1⟧", seam.calls[-1]["system"])

    def test_same_history_turn_gets_the_same_tokens_every_time(self):
        from core.agentcore import trust as TT
        hist = [{"role": "user", "content": "earlier %s" % PHONE},
                {"role": "assistant", "content": "ok"}]
        a = TT.Vault().mask_request(history=hist)[2]
        b = TT.Vault().mask_request(history=hist)[2]
        self.assertEqual(a, b)


class AgentQaStudioBriefingMaskTests(_SeamCase):
    def test_agent_studio_letter(self):
        from rest_framework.test import APIClient
        u = _user()
        c = APIClient()
        c.force_authenticate(u)
        seam = self.seam()
        r = c.post("/api/v1/studio", {"kind": "letter",
                                      "prompt": "leave letter; reach me at %s or %s" % (PHONE, EMAIL)},
                   format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        self.assert_masked(seam, PHONE, EMAIL)
        self.assertIn(PHONE, r.json()["text"])

    def test_briefing_payload(self):
        from django.utils import timezone
        from core.models import Reminder
        from core.views import _briefing_payload
        u = _user()
        Reminder.objects.create(user=u, title="Call bank %s" % PHONE, due_at=timezone.now())
        seam = self.seam()
        out = _briefing_payload(u, "en")
        self.assert_masked(seam, PHONE)
        self.assertIn(PHONE, out["ai_text"] or "")

    def test_jobs_cv_and_cover(self):
        from core import jobs
        u = _user()
        seam = self.seam()
        out = jobs.tailor_documents(u, "Sales officer. Apply: %s" % EMAIL,
                                    extra="phone %s" % PHONE, lang="en")
        self.assertTrue(out.get("ai_used"), out)
        self.assertEqual(len(seam.calls), 2)
        self.assert_masked(seam, PHONE, EMAIL)
        self.assertIn(EMAIL, out["cv_text"] + out["cover_letter"])

    def test_world_hub(self):
        from core import world_service as WSV
        u = _user()
        seam = self.seam()
        st, body = WSV.hub_ai(u, "expat", "my passport NID %s, phone %s — visa?" % (NID, PHONE), "en")
        self.assertEqual(st, 200, body)
        self.assert_masked(seam, NID, PHONE)
        self.assertIn(NID, body["answer"])


class BillPartialMaskTests(_SeamCase):
    def test_bill_reader_keeps_account_no_masks_phone_and_email(self):
        from core import bills
        u = _user()
        seam = _Seam(reply=json.dumps({"biller": "DESCO", "account_no": "91278509123",
                                       "amount": "1436"}))
        p = _P(_router(seam))
        p.__enter__()
        self.addCleanup(p.__exit__)
        raw = ("DESCO\nAccount No: 91278509123\nCustomer phone: %s\nE-mail: %s\n"
               "Amount: 1436" % (PHONE, EMAIL))
        fields, used_ai, _c = bills.parse_bill(u, raw)
        self.assertTrue(used_ai)
        sent = seam.sent()
        self.assertIn("91278509123", sent)              # the reader needs it
        self.assertNotIn(PHONE, sent)
        self.assertNotIn(EMAIL, sent)
        self.assertFalse(T.has_raw_pii(sent, ("PHONE", "EMAIL")))
        self.assertEqual(fields["account_no"], "91278509123")


class ChatVisionMaskTests(_VBase):
    """The question + on-device OCR text are masked before the vision call;
    the image itself is the documented exception."""
    def test_question_and_device_text_masked_answer_unmasked(self):
        from core import vision_providers as VP
        self.vision()
        self.as_(self.prem)
        r = self.create()
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        seen = {}

        def ask(slug, conf, **kw):
            seen.update(kw)
            tok = re.search(r"⟦PHONE_\d+⟧", kw["question"])
            return json.dumps({"kind": "other", "label_text": "",
                               "answer": "The number on the card is %s." % (
                                   tok.group(0) if tok else "?")})
        with mock.patch.object(VP, "ask", side_effect=ask):
            r = self.answer(jid, question="what is on this card? my email %s" % EMAIL,
                            device_text="Rahim  %s  NID %s" % (PHONE, NID))
        self.assertEqual(r.status_code, 200, r.content)
        q = seen["question"]
        self.assertFalse(T.has_raw_pii(q), q)
        for v in RAW:
            self.assertNotIn(v, q)
        self.assertIn(PHONE, r.json()["job"]["answer"])


# ---------------------------------------------------------------- AF-13
class RetentionHygieneTests(SimpleTestCase):
    def test_openai_text_request_sets_store_false(self):
        seen = {}

        def post(url, body, headers):
            seen.update(body)
            return {"choices": [{"message": {"content": "ok"}}], "usage": {}}
        with mock.patch.object(ai, "_post", side_effect=post):
            ai._call_openai("k", "gpt-x", "sys", "hi", 10)
        self.assertIs(seen.get("store"), False)

    def test_openai_vision_request_sets_store_false(self):
        from core import vision_providers as VP
        r = mock.MagicMock(status_code=200)
        r.json.return_value = {"choices": [{"message": {"content": "ok"}}]}
        with mock.patch.object(VP, "_http") as h:
            h.return_value.post.return_value = r
            VP.ask("vision_openai", {"api_key": "k"}, image_bytes=b"x", question="q")
            self.assertIs(h.return_value.post.call_args.kwargs["json"]["store"], False)

    def test_sdk_loggers_never_debug(self):
        lg = logging.getLogger("anthropic")
        old = lg.level
        self.addCleanup(lambda: lg.setLevel(old))
        lg.setLevel(logging.DEBUG)
        ai.quiet_sdk_loggers()
        self.assertGreaterEqual(lg.getEffectiveLevel(), logging.WARNING)

    def test_error_detail_masked_before_logging(self):
        d = ai._safe_detail("invalid request: 'call %s' %s" % (PHONE, EMAIL))
        self.assertNotIn(PHONE, d)
        self.assertNotIn(EMAIL, d)

    def test_usage_log_has_no_prompt_field(self):
        from core.models import AIUsage
        names = {f.name for f in AIUsage._meta.get_fields()}
        for bad in ("prompt", "text", "data", "reply", "messages"):
            self.assertNotIn(bad, names)
