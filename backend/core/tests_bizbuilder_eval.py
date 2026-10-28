"""TESTING CENTER — business agent builder eval (WP-BIZBUILDER): >= 200
Bangla / Banglish / English goals (core/agentcore/evals/bizbuilder.py), graded
deterministically through the REAL pipeline inside the builder sandbox. Bar:
100% in CI mode. Report -> $AGENT_EVAL_REPORT's directory as
agent_eval_bizbuilder.json (agent-eval.yml thresholds step)."""
import json
import os
from collections import Counter
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings

from core import bizagent_graph as G
from core import bizagent_service as S
from core import bizbuilder_service as BBS
from core.agentcore.evals import bizbuilder as E
from core.logic import bizbuilder as BB
from core.models import (BizAgentCard, BusinessProfile, ChatThread, Message, Order, OwnerPolicy,
                         Product, User)


class GoalSetShape(TestCase):
    def test_big_mixed_and_adversarial(self):
        cs = E.cases()
        self.assertGreaterEqual(len(cs), 200)
        self.assertEqual(len({c["id"] for c in cs}), len(cs))
        self.assertEqual(len({c["goal"] for c in cs}), len(cs))
        src = Counter(c["src"] for c in cs)
        for lang in ("bn", "en", "bl"):
            self.assertGreaterEqual(src[lang], 30, lang)
        intents = Counter(c["intent"] for c in cs)
        for need in ("faq", "tone", "delivery", "takeover", "injection", "min_leak", "stop",
                     "human", "greeting", "refuse", "parse"):
            self.assertGreater(intents[need], 0, need)
        self.assertGreaterEqual(intents["takeover"], 30)
        self.assertGreaterEqual(intents["min_leak"], 25)
        self.assertGreaterEqual(intents["injection"], 15)


@override_settings(BIZAGENT_SYNC=True)
class BuilderEval(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="eval-shop@example.invalid", name="Eval",
                                             password="x")
        self.biz = BusinessProfile.objects.create(user=self.user, shop_name="Rupa Fashion")
        for name, price, mn, stock in E.PRODUCTS:
            Product.objects.create(user=self.user, business=self.biz, name=name, price=Decimal(price),
                                   min_price=Decimal(mn), stock=stock)
        OwnerPolicy.objects.create(user=self.user, business=self.biz,
                                   delivery_inside=Decimal(E.DELIVERY[0]),
                                   delivery_outside=Decimal(E.DELIVERY[1]))
        self.calls = []
        prev = G.set_transport(lambda *a: self.calls.append(a) or (200, {}))
        self.addCleanup(G.set_transport, prev)

    def _counts(self):
        return (Message.objects.count(), ChatThread.objects.count(), Order.objects.count(),
                BizAgentCard.objects.count(),
                tuple(Product.objects.order_by("id").values_list("min_price", flat=True)))

    def test_builder_ci_eval(self):
        catalog = S.catalog_for(self.biz)
        cards = {k: BB.build_card(v, catalog) for k, v in E.CARDS.items()}
        delivery = S.delivery_for(self.biz)
        passed, failed = [], []
        pushes = []
        before = self._counts()
        with mock.patch("core.push.safe_push", side_effect=lambda *a, **k: pushes.append(a)), \
                mock.patch("core.ai.key_present", return_value=False):
            for c in E.cases():
                if c["family"] == "parse":
                    bad = E.grade_parse(c, catalog)
                else:
                    card = cards.get(c["card"]) if c["card"] else None
                    res, _st, _ai = BBS.run_sandbox(self.biz, self.user, c["msgs"], card=card)
                    base = None
                    if c["expect"].get("same_as_none"):
                        base, _s, _a = BBS.run_sandbox(self.biz, self.user, c["msgs"], card=None)
                    dl = dict(delivery)
                    if card and card.get("delivery"):
                        dl.update(card["delivery"])
                    bad = E.grade_chat(c, res, base, catalog=catalog, card=card, delivery=dl)
                (failed if bad else passed).append({"id": c["id"], "goal": c["goal"], "why": bad})
        self.assertEqual(self.calls, [], "the sandbox reached Graph")
        self.assertEqual(pushes, [], "the sandbox pushed")
        self.assertEqual(self._counts(), before, "the sandbox left rows behind")
        cs = E.cases()
        out = os.environ.get("AGENT_EVAL_REPORT")
        if out:
            path = os.path.join(os.path.dirname(out), "agent_eval_%s.json" % E.TOPIC)
            with open(path, "w") as f:
                json.dump({"topic": E.TOPIC, "cases": len(cs), "passed": len(passed),
                           "threshold": E.THRESHOLD, "failed": failed}, f, ensure_ascii=False, indent=1)
        rate = len(passed) / float(len(cs))
        self.assertGreaterEqual(rate, E.THRESHOLD, "%d/%d failed, first: %s" % (
            len(failed), len(cs), json.dumps(failed[:8], ensure_ascii=False, indent=1)))
