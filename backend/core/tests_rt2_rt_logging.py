"""rt2 — the real-time writes (rt_publish / touch_presence / publish_state)
stay non-fatal for the request but are never SILENT: a lost event is logged
with its traceback, and the failed insert runs in its own savepoint so the
surrounding transaction keeps working (Postgres would otherwise abort it).
"""
from unittest import mock

from django.db import DatabaseError, transaction
from django.test import TestCase

from core import views_c2_calls as C2
from core.models import CallRecord, RtEvent, RtPresence, User


class RtWritesAreLoggedTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rt Two", phone="01799990001",
                                          password="pw12345!")

    def test_rt_publish_ok_returns_seq(self):
        seq = C2.rt_publish(self.u, "call.incoming", {"call_id": 1})
        self.assertGreater(seq, 0)
        self.assertTrue(RtEvent.objects.filter(pk=seq, topic="call.incoming").exists())

    def test_rt_publish_db_error_is_logged_not_raised(self):
        with mock.patch.object(RtEvent.objects, "create",
                               side_effect=DatabaseError("database is locked")):
            with self.assertLogs("assisto.rt", level="ERROR") as cm:
                seq = C2.rt_publish(self.u, "call.incoming", {"call_id": 1})
        self.assertEqual(seq, 0)
        self.assertIn("rt_publish lost an event", cm.output[0])
        self.assertIn("call.incoming", cm.output[0])
        self.assertIn("database is locked", "\n".join(cm.output))  # traceback kept

    def test_rt_publish_none_user_is_quiet(self):
        with self.assertNoLogs("assisto.rt", level="ERROR"):
            self.assertEqual(C2.rt_publish(None, "x", {}), 0)

    def test_touch_presence_db_error_is_logged_not_raised(self):
        with mock.patch.object(RtPresence.objects, "create",
                               side_effect=DatabaseError("database is locked")):
            with self.assertLogs("assisto.rt", level="ERROR") as cm:
                C2.touch_presence(self.u)
        self.assertIn("touch_presence failed", cm.output[0])
        self.assertFalse(RtPresence.objects.filter(user=self.u).exists())

    def test_touch_presence_ok(self):
        with self.assertNoLogs("assisto.rt", level="ERROR"):
            C2.touch_presence(self.u)
        self.assertTrue(RtPresence.objects.filter(user=self.u).exists())

    def test_publish_state_db_error_is_logged(self):
        rec = mock.Mock(spec=CallRecord, pk=9, caller_id=self.u.pk, callee_id=self.u.pk)
        with mock.patch.object(C2, "status_row", return_value={"phase": "calling"}), \
                mock.patch.object(RtEvent.objects, "create",
                                  side_effect=DatabaseError("database is locked")):
            with self.assertLogs("assisto.rt", level="ERROR") as cm:
                C2.publish_state(rec)
        self.assertIn("publish_state lost call.state", cm.output[0])

    def test_failed_write_does_not_poison_the_outer_transaction(self):
        """The savepoint: after a failed rt write inside an atomic block the
        request's own queries still run (Postgres would raise
        TransactionManagementError / 'current transaction is aborted')."""
        real_create = RtEvent.objects.create

        def boom(**kw):
            real_create(user=None, topic="x", payload={})  # NOT NULL -> IntegrityError

        with transaction.atomic():
            with mock.patch.object(RtEvent.objects, "create", side_effect=boom):
                with self.assertLogs("assisto.rt", level="ERROR"):
                    self.assertEqual(C2.rt_publish(self.u, "call.incoming", {}), 0)
            # the outer transaction is still usable
            self.assertEqual(User.objects.filter(pk=self.u.pk).count(), 1)
            ok = C2.rt_publish(self.u, "call.state", {"phase": "calling"})
            self.assertGreater(ok, 0)


class CartWithoutNextIdTests(TestCase):
    """rt2: reality run 39895738392 — POST business/cart/add answered 500
    (KeyError '_next_id') for the cart the phone sent back."""

    def _prod(self):
        from core.logic import business_selling as B
        return B.make_product("Rice 1kg", variants=[B.make_variant(
            size="", colour="", sell=100, cost=80, minimum=90, stock=5,
            low_stock_at=1)])

    def test_cart_add_line_accepts_cart_without_next_id(self):
        from core.logic import business_selling as B
        for start in ({}, {"lines": []}, None, {"lines": "x"}):
            cart, line, r = B.cart_add_line(start, self._prod(), qty=1)
            self.assertEqual(r, B.R_OK, start)
            self.assertEqual(line["id"], 1)
            self.assertEqual(cart["_next_id"], 2)

    def test_next_id_moves_past_existing_lines(self):
        from core.logic import business_selling as B
        cart, line, _ = B.cart_add_line(B.new_cart(), self._prod(), qty=1)
        cart.pop("_next_id")
        cart, line2, r = B.cart_add_line(cart, self._prod(), qty=1)
        self.assertEqual(r, B.R_OK)
        self.assertEqual(line2["id"], 2)
