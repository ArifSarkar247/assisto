"""pricing-40: EXACT input-token counts per AI path — FREE (owner-run).

Builds the exact requests the code sends (shared system prompt, the chat
instruction, data wrapper, history window, the 10 Bangla eval prompts as user
messages; the proposed quick/smart/pro caps after trimming) and asks
Anthropic's free `messages.count_tokens` endpoint how many input tokens each
one is, per model. count_tokens generates nothing and is not billed; it needs
the Anthropic key and refuses to run in tests / CI.

  cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ai_token_audit
  ... ai_token_audit --offline      # no key / no network: the char-based estimate

Output tokens are not counted here (only real answers have them) — after the
key is live, Owner Admin -> AI "recent calls" shows real output tokens.
"""
import os
import sys

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

# A typical brief Bangla assistant reply (used to fill history turns).
SAMPLE_REPLY_BN = (
    "ঠিক আছে, আপনার জন্য তিনটি সহজ পরামর্শ: ১) মাসের শুরুতেই আয়ের একটা অংশ আলাদা "
    "সঞ্চয় হিসাবে রাখুন। ২) বাজারের তালিকা করে কিনুন, হঠাৎ কেনাকাটা কমান। ৩) প্রতি "
    "সপ্তাহে খরচ একবার মিলিয়ে দেখুন। চাইলে আমি একটা মাসিক বাজেট বানিয়ে দিতে পারি।")
SUMMARY_BN = ("আপনার Assisto-তে যা আছে:\n• রিমাইন্ডার: 4\n• টাকা: ব্যালেন্স ৳12500, "
              "এ মাসে খরচ ৳8300, আয় ৳35000\n• নোট: 12\n• টুডু (বাকি): 3")
MODELS = ("claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5")


def _in_tests_or_ci():
    return (os.environ.get("CI") or "test" in sys.argv[1:2]
            or "settings_test" in (os.environ.get("DJANGO_SETTINGS_MODULE") or "")
            or "settings_ci" in (os.environ.get("DJANGO_SETTINGS_MODULE") or "")
            or getattr(settings, "TESTING", False))


def build_paths():
    """[(name, system, messages)] — the exact request inputs per path."""
    from core import ai, ai_prompt as P
    from core.logic import pricing_40 as P40
    from core.views_chat import CHAT_TASK, CHAT_DATA, _HISTORY_TURNS
    system = P.system_prompt()
    q = P.QUALITY_PROMPTS
    hist = []
    for i in range(_HISTORY_TURNS // 2):
        hist += [{"role": "user", "content": q[i % len(q)]},
                 {"role": "assistant", "content": SAMPLE_REPLY_BN}]

    def turn(task, text, summary):
        return task + "\n\n<data>\n" + CHAT_DATA.format(text=text, summary=summary) + "\n</data>"

    bn = turn(CHAT_TASK[0], q[0], SUMMARY_BN)
    en = turn(CHAT_TASK[1], "How can I save 5,000 taka a month? Give 3 tips.",
              "Here's what's in your Assisto:\n• Reminders: 4")
    paths = [
        ("chat_bn_first_turn", system, ai._messages([], bn)),
        ("chat_bn_3_exchanges", system, ai._messages(hist[-6:], bn)),
        ("chat_bn_full_window", system, ai._messages(hist, bn)),
        ("chat_en_first_turn", system, ai._messages([], en)),
        ("home_agent_qa_bn", system, ai._messages([], (
            "ব্যবহারকারীর প্রশ্নের উত্তর দাও বাংলায়, সংক্ষেপে ও সত্যভাবে। নিচের DATA-তে তার "
            "নিজের তথ্যের সারাংশ আছে — শুধু এটাই সত্য।\n\n<data>\nQuestion: " + q[0]
            + "\n\n" + SUMMARY_BN + "\n</data>"))),
    ]
    for p in q:
        paths.append(("eval_prompt_%02d" % (q.index(p) + 1), system,
                      ai._messages([], turn(CHAT_TASK[0], p, SUMMARY_BN))))
    cm = P40.normalize_credit_model(P40.PRESETS["pricing_27oct"]["credit_model"])
    for m in P40.MODE_IDS:
        spec = P40.mode_spec(cm, m)
        prompt, h = P40.fit_input(system, bn, hist, spec["in_cap"], spec["history_turns"])
        paths.append(("mode_%s_full_window_capped" % m, system, ai._messages(h, prompt)))
    return paths


def offline_estimate(system, messages):
    from core.logic import pricing_40 as P40
    return P40.est_tokens(system) + sum(P40.est_tokens(m["content"]) for m in messages)


class Command(BaseCommand):
    help = "Exact input tokens per AI path via Anthropic's FREE count_tokens (owner-run)."

    def add_arguments(self, parser):
        parser.add_argument("--offline", action="store_true",
                            help="No key / no network: print the conservative char estimate.")
        parser.add_argument("--model", choices=MODELS)

    def handle(self, *a, **o):
        paths = build_paths()
        if o.get("offline"):
            self.stdout.write("OFFLINE estimate (Bangla 1.3 / other 0.3 tokens per char):")
            for name, system, msgs in paths:
                self.stdout.write("%-32s ~%d" % (name, offline_estimate(system, msgs)))
            return
        if _in_tests_or_ci():
            raise CommandError("ai_token_audit never calls Anthropic in tests or CI "
                               "(use --offline).")
        from core import ai
        key = ai.active_api_key()
        if not key:
            raise CommandError("No Anthropic key configured — use --offline for the estimate.")
        import anthropic
        client = anthropic.Anthropic(api_key=key, timeout=30, max_retries=1)
        models = (o["model"],) if o.get("model") else MODELS
        self.stdout.write("%-32s %s" % ("path", "  ".join("%18s" % m for m in models)))
        for name, system, msgs in paths:
            cells = []
            for m in models:
                try:
                    r = client.messages.count_tokens(model=m, system=system, messages=msgs)
                    cells.append("%18d" % r.input_tokens)
                except Exception as e:  # noqa: BLE001
                    cells.append("%18s" % ("ERR " + type(e).__name__)[:18])
            self.stdout.write("%-32s %s" % (name, "  ".join(cells)))
        self.stdout.write("count_tokens is free; nothing was generated or billed.")
