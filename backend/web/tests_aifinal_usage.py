"""aifinal PART 2: Owner Admin -> AI usage log (no message text, pseudonymous
user ids, per-provider totals, filters, 90-day retention)."""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core import ai_usage_log as UL
from core import ops_health as H
from core.models import AIUsage
from web.tests_o2_owner_admin import OwnerBase


def _row(user=None, **kw):
    d = dict(user=user, feature="chat.quick", model="gemini-2.5-flash-lite", provider="gemini",
             input_tokens=900, output_tokens=200, cost_usd=0.0002, latency_ms=800, ok=True)
    d.update(kw)
    return AIUsage.objects.create(**d)


class UsageLogLogicTests(TestCase):
    def setUp(self):
        self.u = get_user_model().objects.create_user(name="aiu1", phone="+8801700000010", password="pw12345!")

    def test_pseudonym_is_stable_and_hides_the_id(self):
        p = UL.pseudo_id(self.u.pk)
        self.assertEqual(p, UL.pseudo_id(self.u.pk))
        self.assertTrue(p.startswith("u-"))
        self.assertNotIn(str(self.u.pk), p[2:4])
        self.assertNotEqual(p, UL.pseudo_id(self.u.pk + 1))
        self.assertEqual(UL.pseudo_id(None), "")

    def test_results_success_fallback_error_refunded(self):
        rows = [_row(self.u), _row(self.u, hops=1, attempts="anthropic:timeout|gemini:ok"),
                _row(self.u, ok=False, error_kind="all_failed", attempts="gemini:server"),
                _row(self.u, ok=False, error_kind="all_failed", credits_charged=3, refunded=3)]
        got = [UL.result_of(r) for r in rows]
        self.assertEqual(got[0], ("success", ""))
        self.assertEqual(got[1], ("fallback", "anthropic timeout"))
        self.assertEqual(got[2][0], "error")
        self.assertEqual(got[3][0], "refunded")
        self.assertEqual([r["result"] for r in UL.recent({"days": 1, "result": "refunded"})],
                         ["refunded"])

    def test_totals_per_provider_today_and_month(self):
        _row(self.u)
        _row(self.u, provider="anthropic", model="claude-haiku-5-5", cost_usd=0.002)
        t = UL.totals(period="today")
        provs = {r["provider"]: r for r in t["rows"]}
        self.assertEqual(set(provs), {"gemini", "anthropic"})
        self.assertEqual(t["total"]["requests"], 2)
        self.assertAlmostEqual(t["total"]["usd"], 0.0022, places=4)
        self.assertGreater(t["total"]["bdt"], 0)
        self.assertEqual(UL.totals(period="month")["total"]["requests"], 2)

    def test_user_filter_by_pseudonym(self):
        other = get_user_model().objects.create_user(name="aiu2", phone="+8801700000011", password="pw12345!")
        _row(self.u)
        _row(other)
        rows = UL.recent({"days": 1, "user": UL.pseudo_id(other.pk)})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["user"], UL.pseudo_id(other.pk))

    def test_rows_never_carry_text(self):
        self.assertFalse(any(f.name in ("text", "prompt", "message", "content", "reply")
                             for f in AIUsage._meta.get_fields()))
        _row(self.u)
        self.assertFalse({"text", "prompt", "message"} & set(UL.recent({"days": 1})[0]))

    def test_retention_90_days_rides_minute_jobs(self):
        old = _row(self.u)
        AIUsage.objects.filter(pk=old.pk).update(created_at=timezone.now() - timedelta(days=91))
        keep = _row(self.u)
        call_command("ai_usage_purge", quiet=True)
        self.assertEqual(list(AIUsage.objects.values_list("pk", flat=True)), [keep.pk])
        self.assertIn("ai_usage_purge", H.MINUTE_JOB_NAMES)

    def test_failed_generate_row_books_the_refund(self):
        from unittest import mock
        from core import ai
        from core import billing
        with mock.patch.object(ai, "_providers", return_value=[("gemini", "k")]), \
                mock.patch.object(ai, "_call_gemini", side_effect=ai.ProviderError("server")), \
                mock.patch.object(billing, "charge",
                                  return_value={"ok": True, "charged": 2, "balance": 5}), \
                mock.patch.object(billing, "credit") as credit:
            with self.assertRaises(ai.AIUnavailable):
                ai.generate("hi", user=self.u, feature="chat", level="normal")
        credit.assert_called_once()
        row = AIUsage.objects.filter(user=self.u).latest("id")
        self.assertEqual((row.ok, row.refunded, row.level), (False, 2, "normal"))
        self.assertEqual(UL.result_of(row)[0], "refunded")


class UsageLogPageTests(OwnerBase):
    def test_page_shows_totals_rows_and_filters(self):
        u = get_user_model().objects.create_user(name="aiu3", phone="+8801700000012", password="pw12345!")
        _row(u, level="normal")
        self.ready()
        r = self.c.get("/owner/ai-usage?lang=en")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        for s in ('id="aiu-today"', 'id="aiu-month"', 'id="aiu-filter"', "gemini-2.5-flash-lite",
                  UL.pseudo_id(u.pk), "success"):
            self.assertIn(s, html)
        self.assertNotIn("aiu3", html)            # never the username
        r = self.c.get("/owner/ai-usage?provider=anthropic")
        self.assertEqual(r.status_code, 200)
        self.assertNotIn("gemini-2.5-flash-lite</code></td><td>900", r.content.decode())
