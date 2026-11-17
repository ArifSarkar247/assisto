"""cctvact — CCTV GUARD V3 parts D, E, F, G (owner order 9 Nov 15:15).

Pure: POS webhook signature (HMAC-SHA256 "v1:<ts>:<body>", clock window,
key rotation), partner event cleaning (no names kept), CSV import, sales
match (review-only, never an accusation), "Wrong alert" learning (safety
never quiet), nearest thana from map rows (never an invented number),
closing report numbers, the Bangla / English question parser, Tuya signing.
API on the real views: per-shop key shown once, signed webhook + replay =
duplicate + stale / bad signature refused, CSV de-dupe, sales match,
wrong-alert learning through the real ingest, live / thana / play actions,
Tuya automations (lights on at once, off by the tick, a LOCK only after the
owner's Yes), closing report + its push once a day, box daily stats, Ask
answers from stored events with no identity."""
import json
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.test import SimpleTestCase, override_settings
from django.utils import timezone

from core.logic import cash_guard as CG
from core.logic import cctv_act as A
from core.logic import tuya as T
from core.tests_cashguard import _MEDIA
from core.tests_cctvx import _X


def _clear_of_midnight():
    """Now, or 01:00 local when the real clock is in the first hour after
    Dhaka midnight (these tests look at "today" and at minutes before now;
    CI runs that cross 00:00 Dhaka failed, 16 Nov)."""
    n = timezone.localtime(timezone.now())
    return n.replace(hour=1, minute=0, second=0, microsecond=0) if n.hour < 1 else n


def _midnight_safe(fn):
    """Run the test with the clock frozen at _clear_of_midnight() (computed
    when the test starts)."""
    import functools

    @functools.wraps(fn)
    def run(*a, **k):
        n = _clear_of_midnight()
        with mock.patch("django.utils.timezone.now", return_value=n):
            return fn(*a, **k)
    return run


NOW = datetime(2026, 11, 9, 10, 0, tzinfo=dtz.utc)


# ===================================================================== pure
class SignatureTests(SimpleTestCase):
    def test_sign_verify_and_window(self):
        body = b'{"event_id":"s1","type":"sale","amount":"120.00"}'
        ts = 1_800_000_000
        sig = A.signature_header("ask_secret", ts, body)
        self.assertTrue(sig.startswith("v1="))
        self.assertEqual(A.verify(["ask_secret"], str(ts), sig, body, ts + 10), (True, ""))
        self.assertEqual(A.verify(["ask_secret"], str(ts), sig, body, ts + 301), (False, "stale"))
        self.assertEqual(A.verify(["other"], str(ts), sig, body, ts), (False, "bad_signature"))
        self.assertEqual(A.verify(["ask_secret"], str(ts), sig, body + b" ", ts),
                         (False, "bad_signature"))           # body changed
        self.assertEqual(A.verify(["ask_secret"], "x", sig, body, ts), (False, "bad_timestamp"))
        self.assertEqual(A.verify(["ask_secret"], str(ts), "", body, ts), (False, "no_signature"))
        self.assertEqual(A.verify(["ask_secret"], str(ts), "v0=" + "a" * 64, body, ts),
                         (False, "bad_signature"))
        # rotation: a header with two signatures, either key works
        two = A.signature_header("old", ts, body) + "," + A.signature_header("new", ts, body)
        self.assertTrue(A.verify(["new"], str(ts), two, body, ts)[0])

    def test_kid_names_the_site(self):
        self.assertEqual(A.kid_site("ak_42_ab12cd34ef"), 42)
        self.assertIsNone(A.kid_site("ak_x_ab12cd34ef"))
        self.assertIsNone(A.kid_site(""))


class PosEventTests(SimpleTestCase):
    def test_clean_event_keeps_no_names(self):
        row, err = A.normalize_pos({"event_id": "INV-77", "type": "sale", "amount": "1,250.75",
                                    "at": "2026-11-09T15:30:00+06:00", "cashier_name": "Karim",
                                    "customer_phone": "01711111111", "payment_method": "bkash",
                                    "register": "Till 1"}, NOW, "asalify")
        self.assertEqual(err, "")
        self.assertEqual((row["kind"], row["amount_taka"], row["meta"]["poisha"]),
                         ("sale", 1251, 125075))
        self.assertEqual(row["meta"]["pay"], "bkash")
        flat = json.dumps(row["meta"])
        self.assertNotIn("Karim", flat)
        self.assertNotIn("01711111111", flat)

    def test_types_and_errors(self):
        self.assertEqual(A.normalize_pos({"event_id": "d1", "type": "cash_drawer"}, NOW, "pos")[0]
                         ["kind"], "drawer_open")
        self.assertEqual(A.normalize_pos({"event_id": "d1", "type": "x"}, NOW, "pos")[1], "bad_type")
        self.assertEqual(A.normalize_pos({"event_id": "", "type": "sale"}, NOW, "pos")[1],
                         "bad_event_id")
        self.assertEqual(A.normalize_pos({"event_id": "a", "type": "sale", "amount": "1x"}, NOW,
                                         "pos")[1], "bad_amount")
        self.assertEqual(A.normalize_pos({"event_id": "a", "type": "sale", "currency": "USD"},
                                         NOW, "pos")[1], "bad_currency")
        self.assertEqual(A.normalize_pos({"event_id": "a", "type": "sale",
                                          "at": "2026-12-30T10:00:00+06:00"}, NOW, "pos")[1],
                         "bad_time")                          # far future

    def test_csv_bangla_header_and_stable_ids(self):
        text = "সময়,ধরন,টাকা\n09/11/2026 14:05,sale,৩৫০\n09/11/2026 14:06,refund,50\n,,\nbad,sale,1\n"
        rows, errs = A.parse_csv(text, NOW)
        self.assertEqual([r["kind"] for r in rows], ["sale", "refund"])
        self.assertEqual(rows[0]["amount_taka"], 350)
        self.assertEqual(errs, [{"line": 5, "code": "bad_time"}])
        again, _ = A.parse_csv(text, NOW)
        self.assertEqual([r["ext_id"] for r in rows], [r["ext_id"] for r in again])
        self.assertEqual(A.parse_csv("a,b\n1,2", NOW)[1][0]["code"], "no_header")


class SalesMatchTests(SimpleTestCase):
    def test_drawer_without_sale_and_pocket_after_sale(self):
        t = 1_800_000_000
        drawers = [{"id": 1, "at": t, "source": "pos"},             # no sale near
                   {"id": 2, "at": t + 1000, "source": "pos"}]       # sale 60 s later
        sales = [{"at": t + 1060, "kind": "sale"}, {"at": t + 2000, "kind": "khata"}]
        cams = [{"id": 10, "at": t + 5, "type": "hand_in_cash_zone", "signals": {},
                 "camera": "Till", "has_clip": True},
                {"id": 11, "at": t + 2030, "type": "pose_possible",
                 "signals": {"inputs": {"pose": "hand_to_pocket"}}, "camera": "Till",
                 "has_clip": True},
                {"id": 12, "at": t + 2500, "type": "pose_possible",
                 "signals": {"inputs": {"pose": "hand_to_pocket"}}, "camera": "Till"}]
        items = A.sales_match(drawers, sales, cams)
        kinds = [(i["kind"], i["event_id"]) for i in items]
        self.assertEqual(kinds, [("after_sale_check", 11), ("drawer_no_sale", 10)])
        self.assertEqual(items[0]["after_sale_s"], 30)
        for it in items:
            for lang in ("bn", "en"):
                txt = A.review_text(it, lang, "14:05")
                self.assertFalse(CG.accuses(txt), txt)
        self.assertFalse(CG.accuses(A.REVIEW_NOTE[0]) or CG.accuses(A.REVIEW_NOTE[1]))


class LearnTests(SimpleTestCase):
    def test_wrong_answers_lower_then_quiet_correct_weighs_double(self):
        ts = 1_800_000_000
        k = A.pattern_key("motion", 3, None, 23)
        self.assertEqual(k, "motion|c3|-|night")
        learn = {}
        A.learn_record(learn, k, "wrong", ts, "animal")
        self.assertEqual(A.learn_factor(learn[k], ts), 1.0)          # one answer: nothing
        A.learn_record(learn, k, "wrong", ts)
        self.assertEqual(A.learn_factor(learn[k], ts), 0.88)
        for _ in range(2):
            A.learn_record(learn, k, "wrong", ts)
        conf, quiet, f = A.learn_apply(learn[k], ts, 0.8, "motion", None, False)
        self.assertTrue(quiet)
        self.assertLess(conf, 0.8)
        # safety and away mode never go quiet
        self.assertFalse(A.learn_apply(learn[k], ts, 0.8, "motion", "fire", False)[1])
        self.assertFalse(A.learn_apply(learn[k], ts, 0.8, "motion", None, True)[1])
        self.assertFalse(A.learn_apply(learn[k], ts, 0.8, "camera_health", None, False)[1])
        A.learn_record(learn, k, "correct", ts)
        self.assertFalse(A.learn_apply(learn[k], ts, 0.8, "motion", None, False)[1])
        # old answers fade out
        self.assertEqual(A.learn_factor(learn[k], ts + 61 * 86400), 1.0)
        self.assertEqual(learn[k]["r"], {"animal": 1})


class GapCctvLearnNoteTests(SimpleTestCase):
    def test_no_answer_yet_invites_instead_of_thanking(self):
        # gap-cctv: before any answer the tile must not say "Thanks"
        for row in (None, {}, {"w": 0, "c": 0, "at": 1.0}):
            self.assertIn("Tell us", A.learn_summary(row, 1_800_000_000, "en"))
            self.assertNotIn("ধন্যবাদ", A.learn_summary(row, 1_800_000_000, "bn"))
        self.assertIn("Thanks", A.learn_summary({"w": 1, "at": 1_800_000_000.0},
                                                1_800_000_000, "en"))


class ThanaTests(SimpleTestCase):
    def test_nearest_thana_real_rows_only(self):
        rows = [{"name": "Traffic Police Box", "lat": 23.8101, "lng": 90.4101, "phone": "999"},
                {"name": "Sample Model Thana", "lat": 23.83, "lng": 90.42,
                 "phone": "+880 1711-000000; 02-9000000"},
                {"name": "Sample Police Station", "lat": 23.811, "lon": 90.411},
                {"name": "No coords"}]
        out = A.pick_thana(rows, 23.81, 90.41)
        self.assertEqual([r["name"] for r in out], ["Sample Police Station", "Sample Model Thana"])
        self.assertEqual(out[1]["phone"], "01711000000")
        self.assertEqual(out[0]["phone"], "")                # no number: never invented
        self.assertEqual(A.clean_bd_phone("৯৯৯"), "")
        self.assertIsNone(A.valid_latlon("x", 1))


class ReportTests(SimpleTestCase):
    def test_closing_numbers(self):
        hourly = [0] * 24
        hourly[11], hourly[18], hourly[19] = 12, 30, 25
        inp = {"hours": {"open": "09:00", "close": "21:00"}, "open_at": "09:40",
               "close_at": "20:30", "visitors": 67, "hourly": hourly,
               "alerts": {"total": 3, "wrong": 1}, "counter_empty_min": 95,
               "vehicles": {"in": 14, "out": 12},
               "tables": {"avg_pct": 46, "peak_pct": 90, "peak_hour": 19},
               "health": [{"name": "Gate", "offline_min": 0, "sd": "ok"},
                          {"name": "Till", "offline_min": 35, "sd": "ok"}],
               "sales": {"count": 41, "taka": 18250}, "review_items": [{}]}
        en = A.closing_report(inp, "en")
        s = en["sections"]
        self.assertEqual(s["open_close"]["late_min"], 40)
        self.assertEqual(s["open_close"]["early_min"], 30)
        self.assertEqual(s["people"]["peak_hours"], [18, 19])
        self.assertIn("Counter left empty for 1 h 35 min while open", en["lines"])
        self.assertIn("Vehicles in 14, out 12", en["lines"])
        self.assertIn("Till: offline for 35 min", en["lines"])
        self.assertFalse(en["ok"])
        bn = A.closing_report(inp, "bn")
        self.assertIn("খুলেছে ০৯:৪০ — নির্ধারিত সময়ের ৪০ মিনিট পরে", bn["lines"])
        self.assertTrue(any("৬৭" in x for x in bn["lines"]))
        self.assertFalse(any(CG.accuses(x) for x in bn["lines"] + en["lines"]))
        # not measured -> said honestly, never zero
        quiet = A.closing_report({"hours": {}, "visitors": 0, "hourly": [], "alerts": {},
                                  "counter_empty_min": None, "vehicles": None, "tables": None,
                                  "health": []}, "en")
        self.assertIn("No people counted today (no entry line drawn, or cameras were quiet)",
                      quiet["lines"])
        self.assertFalse(any("Counter" in x for x in quiet["lines"]))

    def test_dvr_card_from_cctvconnect(self):
        r = A.closing_report({"hours": {}, "visitors": 5, "hourly": [], "alerts": {},
                              "health": [], "dvr": {"status": "red", "recorded_days": 3,
                                                    "target_days": 30,
                                                    "lines": [{"sev": "red", "what": "HDD failed"}]}},
                             "en")
        self.assertIn("The DVR holds 3 days of recording (target 30 days)", r["lines"])
        self.assertIn("HDD failed", r["lines"])
        self.assertFalse(r["ok"])
        self.assertEqual(r["sections"]["dvr"]["recorded_days"], 3)

    def test_report_due_once_after_closing(self):
        h = {"close": "21:00"}
        self.assertFalse(A.report_due(h, 21 * 60 + 10, None, "d"))
        self.assertTrue(A.report_due(h, 21 * 60 + 15, None, "d"))
        self.assertFalse(A.report_due(h, 21 * 60 + 30, "d", "d"))
        self.assertTrue(A.report_due({}, 22 * 60 + 15, None, "d"))   # default 22:00
        self.assertTrue(A.report_due({"close": "23:55"}, 23 * 60 + 59, None, "d"))


class AskParseTests(SimpleTestCase):
    def setUp(self):
        self.today = datetime(2026, 11, 9).date()

    def test_bangla_cash_between_two_and_three(self):
        f = A.parse_question("২টা থেকে ৩টার মধ্যে ক্যাশে কে গিয়েছিল?", self.today)
        self.assertEqual((f["from_min"], f["to_min"], f["zone"], f["kind"]),
                         (14 * 60, 15 * 60, "cash", "person"))

    def test_english_and_red_car(self):
        f = A.parse_question("who went to the cash between 2 and 3 pm", self.today)
        self.assertEqual((f["from_min"], f["to_min"], f["zone"]), (840, 900, "cash"))
        g = A.parse_question("show the red car at the gate", self.today)
        self.assertEqual((g["colour"], g["kind"], g["zone"]), ("red", "vehicle", "gate"))
        s = A.parse_question("শাটার কখন খুলেছে?", self.today)
        self.assertEqual(s["intent"], "shutter_open")
        y = A.parse_question("গতকাল রাতে গেটে কেউ এসেছিল?", self.today)
        self.assertEqual((y["date"], y["from_min"], y["zone"]), ("2026-11-08", 1320, "gate"))
        self.assertEqual(A.parse_question("সকাল ১০টায়", self.today)["from_min"], 600)

    def test_ai_filter_is_cleaned_and_matching(self):
        base = A.parse_question("anything", self.today)
        f = A.clean_ai_filter({"kind": "vehicle", "colour": "purple-ish", "zone": "gate",
                               "from_min": 99999, "who": "Karim"}, base)
        self.assertEqual((f["kind"], f["colour"], f["zone"], f["from_min"]),
                         ("vehicle", None, "gate", None))
        self.assertNotIn("who", f)
        ev = {"type": "line_crossing", "at_min": 600, "camera_name": "Front Gate",
              "signals": {"inputs": {"kind": "vehicle", "colour": "red"}}}
        g = A.parse_question("show the red car at the gate", self.today)
        self.assertTrue(A.event_matches(ev, g))
        ev["signals"]["inputs"]["colour"] = "white"
        self.assertFalse(A.event_matches(ev, g))
        lines = A.answer_lines(A.parse_question("who was at the cash", self.today),
                               [{"hhmm": "14:20", "camera_name": "Till", "what": "x"}], "en")
        self.assertIn("no face recognition", lines[-1])


class TuyaSignTests(SimpleTestCase):
    def test_string_to_sign_and_commands(self):
        sts = T.string_to_sign("GET", "/v1.0/token", {"grant_type": "1"})
        self.assertEqual(sts, "GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                              "\n\n/v1.0/token?grant_type=1")
        s1 = T.calc_sign("sec", "cid", 1700000000000, "n", sts)
        self.assertEqual(len(s1), 64)
        self.assertTrue(s1.isupper() or s1.isdigit())
        self.assertNotEqual(s1, T.calc_sign("sec", "cid", 1700000000000, "n", sts, "tok"))
        self.assertEqual(T.pick_code("light", [{"code": "switch_led"}]), "switch_led")
        self.assertEqual(T.pick_code("plug", [{"code": "countdown_1"}]), None)
        self.assertEqual(T.kind_of("cz"), "plug")
        self.assertIsNone(T.kind_of("wsdcg"))                 # a sensor: not ours


def tuya_http(calls, devices=None, fail=None):
    devices = devices if devices is not None else [
        {"id": "plug1", "name": "Front light", "category": "cz", "online": True},
        {"id": "lock1", "name": "Shutter lock", "category": "ms", "online": True},
        {"id": "th1", "name": "Thermo", "category": "wsdcg", "online": True}]

    def http(method, url, headers, body, timeout):
        path = url.split("openapi.tuyain.com")[-1].split("?")[0]
        calls.append((method, path, json.loads(body) if body else None))
        if fail and fail in path:
            return 200, json.dumps({"success": False, "code": 2008, "msg": "offline"})
        if path == "/v1.0/token":
            return 200, json.dumps({"success": True, "result": {"access_token": "tok",
                                                                 "expire_time": 7200}})
        if path.endswith("/devices") and "/users/" in path:
            return 200, json.dumps({"success": True, "result": devices})
        if path.endswith("/functions"):
            return 200, json.dumps({"success": True, "result": {"functions": [
                {"code": "switch_1"}]}})
        if path.endswith("/password-ticket"):
            return 200, json.dumps({"success": True, "result": {"ticket_id": "T1"}})
        return 200, json.dumps({"success": True, "result": True})
    return http


# ===================================================================== API
def _signed(client, kid, secret, body, ts=None):
    raw = json.dumps(body).encode()
    ts = int(ts if ts is not None else timezone.now().timestamp())
    return client.post("/api/v1/shop/pos/webhook", raw, content_type="application/json",
                       HTTP_X_ASSISTO_KEY_ID=kid, HTTP_X_ASSISTO_TIMESTAMP=str(ts),
                       HTTP_X_ASSISTO_SIGNATURE=A.signature_header(secret, ts, raw))


@override_settings(MEDIA_ROOT=_MEDIA)
class PosWebhookApiTests(_X):
    def _key(self, partner="asalify"):
        r = self.client.post("/api/v1/shop/sites/%d/pos-key" % self.site["id"],
                             {"partner": partner}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data

    def test_key_once_signed_events_replay_and_refusals(self):
        from rest_framework.test import APIClient
        from core.models import ShopPosEvent
        k = self._key()
        self.assertTrue(k["secret"].startswith("ask_"))
        g = self.client.get("/api/v1/shop/sites/%d/pos-key" % self.site["id"]).data
        self.assertNotIn("secret", g)
        self.assertEqual(g["partner"], "asalify")
        self.assertTrue(g["url"].endswith("/api/v1/shop/pos/webhook"))
        anon = APIClient()
        ev = {"event_id": "A-1", "type": "sale", "amount": "450.00", "cashier": "Karim"}
        r = _signed(anon, k["key_id"], k["secret"], ev)
        self.assertEqual((r.status_code, r.data["accepted"]), (200, 1), r.data)
        row = ShopPosEvent.objects.get(ext_id="A-1")
        self.assertEqual((row.source, row.kind, row.amount), ("asalify", "sale", 450))
        self.assertNotIn("Karim", json.dumps(row.meta))
        # replay (same event, fresh signature) -> duplicate, never a 2nd row
        r = _signed(anon, k["key_id"], k["secret"], ev)
        self.assertEqual((r.status_code, r.data["duplicates"]), (200, 1))
        self.assertEqual(ShopPosEvent.objects.filter(ext_id="A-1").count(), 1)
        # stale timestamp, wrong secret, unknown key, no signature
        old = int(timezone.now().timestamp()) - 400
        self.assertEqual(_signed(anon, k["key_id"], k["secret"], ev, ts=old).data["error"], "stale")
        self.assertEqual(_signed(anon, k["key_id"], "nope", ev).status_code, 401)
        self.assertEqual(_signed(anon, "ak_999999_abcdef12", k["secret"], ev).status_code, 401)
        r = anon.post("/api/v1/shop/pos/webhook", json.dumps(ev), content_type="application/json",
                      HTTP_X_ASSISTO_KEY_ID=k["key_id"],
                      HTTP_X_ASSISTO_TIMESTAMP=str(int(timezone.now().timestamp())))
        self.assertEqual(r.data["error"], "no_signature")
        # batch with one bad event -> 207 with the index
        r = _signed(anon, k["key_id"], k["secret"], {"events": [
            {"event_id": "A-2", "type": "cash_drawer"}, {"event_id": "A-3", "type": "??"}]})
        self.assertEqual((r.status_code, r.data["accepted"], r.data["errors"][0]["index"]),
                         (207, 1, 1))
        # rotation: the old key still works for a day; revoke kills both
        k2 = self._key()
        self.assertEqual(_signed(anon, k["key_id"], k["secret"],
                                 {"event_id": "A-4", "type": "sale"}).status_code, 200)
        self.assertEqual(_signed(anon, k2["key_id"], k2["secret"],
                                 {"event_id": "A-5", "type": "sale"}).status_code, 200)
        self.client.delete("/api/v1/shop/sites/%d/pos-key" % self.site["id"])
        self.assertEqual(_signed(anon, k2["key_id"], k2["secret"],
                                 {"event_id": "A-6", "type": "sale"}).status_code, 401)
        # another owner's key never opens this site
        self.assertEqual(self.m.get("/api/v1/shop/sites/%d/pos-key" % self.site["id"])
                         .status_code, 404)

    @_midnight_safe
    def test_csv_import_dedupes_and_sales_match_review_only(self):
        from core.models import ShopPosEvent
        now = timezone.localtime(timezone.now())
        # stay inside today's local day (the match reads today only; CI may run just after midnight)
        back = max(1, min(30, now.hour * 60 + now.minute - 1))
        t1 = (now - timedelta(minutes=back)).strftime("%Y-%m-%d %H:%M")
        csv = "time,type,amount,id\n%s,cash_drawer,0,D1\n%s,sale,200,S1\n" % (t1, t1)
        r = self.client.post("/api/v1/shop/sites/%d/pos-csv" % self.site["id"], {"csv": csv},
                             format="json")
        self.assertEqual((r.data["accepted"], r.data["duplicates"]), (2, 0), r.data)
        r = self.client.post("/api/v1/shop/sites/%d/pos-csv" % self.site["id"], {"csv": csv},
                             format="json")
        self.assertEqual((r.data["accepted"], r.data["duplicates"]), (0, 2))
        m = self.client.get("/api/v1/shop/sites/%d/sales-match" % self.site["id"]).data
        self.assertEqual(m["items"], [])                     # the sale explains the drawer
        ShopPosEvent.objects.create(site=self.sobj, kind="drawer_open", amount=0,
                                    at=timezone.now() - timedelta(minutes=5))
        m = self.client.get("/api/v1/shop/sites/%d/sales-match" % self.site["id"]).data
        self.assertEqual([i["kind"] for i in m["items"]], ["drawer_no_sale"])
        self.assertIn("not an accusation", m["note"])
        self.assertFalse(CG.accuses(m["items"][0]["text"]))
        self.assertIn("csv", m["feeds"])


@override_settings(MEDIA_ROOT=_MEDIA)
class ActApiTests(_X):
    def test_wrong_alert_learns_per_site_then_saves_quietly(self):
        from core.models import ShopEvent
        for i in range(4):
            ev = self.ingest().data["event_id"]
            r = self.client.post("/api/v1/shop/events/%d/mark" % ev,
                                 {"status": "wrong", "reason": "staff"}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
        d = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]
        self.assertTrue(d["wrong"]["quiet"])
        self.assertIn("saved quietly", d["wrong"]["note_en"])
        self.pushes.clear()
        r = self.ingest()
        self.assertEqual(r.status_code, 201, r.data)          # still saved
        self.assertLess(ShopEvent.objects.get(pk=r.data["event_id"]).confidence, 0.9)
        self.assertEqual([k for a, k in self.pushes if k.get("data", {}).get("event_id")], [])

    def test_gapcctv_live_tile_only_for_people_live_start_admits(self):
        # gap-cctv: a manager the alert was passed to (no live permission) must
        # not get a Live tile that ends in "Not found"
        self.guard(escalation=[self.mgr.id])
        ev = self.ingest().data["event_id"]
        self.tick(minutes=1)
        self.tick(minutes=4)
        own = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]
        self.assertEqual(own["live"]["path"], "webrtc")
        d = self.m.get("/api/v1/shop/events/%d" % ev)
        self.assertEqual((d.status_code, d.data["role"]), (200, "escalated"))
        live = d.data["actions"]["act"]["live"]
        self.assertIsNone(live["path"])
        self.assertEqual(live["reason"], "owner_only")
        # and indeed the live start refuses them
        cam = own["live"]["camera_id"]
        r = self.m.post("/api/v1/shop/live/start", {"camera": cam}, format="json")
        self.assertIn(r.status_code, (403, 404))

    def test_gapcctv_reason_after_card_wrong_is_kept_not_double_counted(self):
        from core.models import ShopSite
        ev = self.ingest().data["event_id"]
        url = "/api/v1/shop/events/%d/mark" % ev
        self.assertEqual(self.client.post(url, {"status": "wrong"}, format="json").status_code, 200)
        r = self.client.post(url, {"status": "wrong", "reason": "staff"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        learn = (ShopSite.objects.get(pk=self.site["id"]).guard or {}).get(A.LEARN_KEY) or {}
        rows = list(learn.values())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["w"], 1)                 # one wrong, not two
        self.assertEqual(rows[0]["r"], {"staff": 1})      # the reason is kept

    def test_gapcctv_actions_say_warning_missing_and_thana_lookup_failed(self):
        ev = self.ingest().data["event_id"]
        act = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]
        self.assertIs(act["has_warn"], False)             # tile: "record first"
        self.assertEqual(act["thana"]["state"], "no_location")
        with mock.patch("core.nearby.search", return_value=([], "unavailable")):
            r = self.client.put("/api/v1/shop/sites/%d/location" % self.site["id"],
                                {"lat": 23.81, "lon": 90.41}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
        act = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]
        self.assertTrue(act["thana"]["has_location"])
        self.assertEqual(act["thana"]["state"], "unavailable")   # not "none nearby"

    def test_live_thana_and_play_actions(self):
        from core.models import ShopGatewayTask
        ev = self.ingest().data["event_id"]
        act = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]
        self.assertEqual(act["live"]["path"], "webrtc")     # the site has a gateway
        self.assertFalse(act["thana"]["has_location"])
        self.assertEqual(act["thana"]["emergency"], "999")
        rows = [{"name": "Sample Model Thana", "lat": 23.8105, "lng": 90.4105,
                 "phone": "01711000000"}]
        with mock.patch("core.nearby.search", return_value=(rows, "osm")) as s:
            r = self.client.put("/api/v1/shop/sites/%d/location" % self.site["id"],
                                {"lat": 23.81, "lon": 90.41}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
            self.assertEqual(r.data["stations"][0]["phone"], "01711000000")
            self.client.get("/api/v1/shop/sites/%d/thana" % self.site["id"])
            self.assertEqual(s.call_count, 1)                # cached
        with mock.patch("core.nearby.search", return_value=([], "unavailable")):
            r = self.client.get("/api/v1/shop/sites/%d/thana?refresh=1" % self.site["id"])
            self.assertEqual((r.data["state"], r.data["emergency"]), ("unavailable", "999"))
        # play on the box: confirm first; the warning needs a recorded clip
        url = "/api/v1/shop/events/%d/play" % ev
        self.assertEqual(self.client.post(url, {"sound": "siren"}, format="json").status_code, 428)
        self.assertEqual(self.client.post(url, {"sound": "warn", "confirm": True},
                                          format="json").data["error"], "no_clip")
        r = self.client.post(url, {"sound": "siren", "confirm": True}, format="json")
        self.assertEqual((r.status_code, r.data["queued"]), (200, 1), r.data)
        t = ShopGatewayTask.objects.get(action="play")
        self.assertEqual((t.request["sound"], t.request["target"]), ("siren", "box"))
        self.assertEqual(t.camera_id, self.camobj.id)       # the box picks it per camera
        # a family viewer cannot sound it
        self.assertEqual(self.m.post(url, {"sound": "siren", "confirm": True},
                                     format="json").status_code, 404)

    def test_automations_lights_now_lock_only_after_yes(self):
        calls = []
        http = tuya_http(calls)
        mk = lambda aid, sec, rg: T.TuyaClient(aid, sec, rg, http=http)    # noqa: E731
        base = "/api/v1/shop/sites/%d/automations" % self.site["id"]
        with mock.patch("core.cctv_act_views._tuya_factory", side_effect=mk), \
                mock.patch("core.logic.tuya._default_http", side_effect=http):
            r = self.client.post(base + "/link", {"mode": "own", "uid": "ay1234567890",
                                                  "access_id": "cid", "access_secret": "S3cretXYZ",
                                                  "region": "in"}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
            self.assertEqual([d["kind"] for d in r.data["devices"]], ["plug", "lock"])
            self.assertNotIn("S3cretXYZ", json.dumps(r.data))
            g = self.sobj.__class__.objects.get(pk=self.sobj.pk).guard["_auto"]["link"]
            self.assertNotIn("S3cretXYZ", json.dumps(g))
            r = self.client.put(base, {"rules": [{
                "trigger": "any_alert", "window": {"start": "00:00", "end": "23:59"},
                "actions": [{"device_id": "plug1", "seconds": 60},
                            {"device_id": "lock1"}, {"device_id": "ghost"}]}]}, format="json")
            self.assertEqual(len(r.data["rules"][0]["actions"]), 2)
            self.pushes.clear()
            ev = self.ingest().data["event_id"]
            cmds = [b for m, p, b in calls if p.endswith("/commands")]
            self.assertEqual(cmds[-1], {"commands": [{"code": "switch_1", "value": True}]})
            self.assertFalse(any("door-operate" in p for m, p, b in calls))   # never by itself
            self.assertTrue(any("Lock the door?" in str(a) for a, k in self.pushes))
            st = self.client.get(base).data
            pid = st["pending"][0]["id"]
            self.assertEqual(self.client.post(base + "/lock", {"pending_id": pid},
                                              format="json").status_code, 428)
            r = self.client.post(base + "/lock", {"pending_id": pid, "confirm": True},
                                 format="json")
            self.assertEqual(r.status_code, 200, r.data)
            op = [b for m, p, b in calls if "door-operate" in p]
            self.assertEqual(op, [{"ticket_id": "T1", "open": False}])
            ran = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]["act"]["auto"]
            self.assertEqual({x["state"] for x in ran}, {"on", "asked"})
            self.tick(minutes=2)
            offs = [b for m, p, b in calls if p.endswith("/commands")]
            self.assertEqual(offs[-1], {"commands": [{"code": "switch_1", "value": False}]})


@override_settings(MEDIA_ROOT=_MEDIA)
class ReportAskApiTests(_X):
    keep_closing_report = True   # gap-cctv: this class tests the report itself

    def test_closing_report_and_box_stats_and_push_once(self):
        from rest_framework.test import APIClient
        from core.models import ShopSite
        self.ingest()
        dev = APIClient()
        dev.credentials(HTTP_X_SHOP_TOKEN=self.sobj.enrollment_token)
        today = timezone.localtime(timezone.now()).date().isoformat()
        r = dev.post("/api/v1/shop/device/daily-stats",
                     {"date": today, "counter_empty_min": 42,
                      "tables": {"avg_pct": 40, "peak_pct": 85, "peak_hour": 20}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.client.put("/api/v1/shop/sites/%d/closing-report" % self.site["id"],
                        {"use": "cafe"}, format="json")
        rep = self.client.get("/api/v1/shop/sites/%d/closing-report" % self.site["id"]).data
        self.assertEqual(rep["sections"]["counter_empty_min"], 42)
        self.assertTrue(rep["measured"]["tables"])
        self.assertEqual(rep["sections"]["alerts"]["total"], 1)
        self.assertEqual(rep["cfg"]["use"], "cafe")
        self.assertIn("no identity", rep["privacy"])
        # the push goes once after closing
        ShopSite.objects.filter(pk=self.sobj.pk).update(hours={"open": "00:00", "close": "00:01"})
        self.pushes.clear()
        from core import cctv_act_views as V
        late = timezone.localtime(timezone.now()).replace(hour=23, minute=50)
        site = ShopSite.objects.get(pk=self.sobj.pk)
        with mock.patch("core.cctv_act_views.build_report", wraps=V.build_report):
            self.assertTrue(V.run_closing(site, late))
            self.assertFalse(V.run_closing(site, late + timedelta(minutes=1)))
        self.assertEqual(len([1 for a, k in self.pushes
                              if (k.get("data") or {}).get("notice") == "closing_report"]), 1)

    def test_ask_answers_from_stored_events_no_identity(self):
        from core.models import ShopEvent
        lo = timezone.localtime(timezone.now()).replace(hour=14, minute=20, second=0, microsecond=0)
        e1 = ShopEvent.objects.create(site=self.sobj, camera=self.camobj, type="hand_in_cash_zone",
                                      signals={"inputs": {"zone": "cash"}}, confidence=0.8)
        e2 = ShopEvent.objects.create(site=self.sobj, camera=self.camobj, type="line_crossing",
                                      signals={"inputs": {"kind": "vehicle", "colour": "red",
                                                          "zone": "gate"}}, confidence=0.7)
        ShopEvent.objects.filter(pk=e1.pk).update(created=lo)
        ShopEvent.objects.filter(pk=e2.pk).update(created=lo.replace(hour=10))
        url = "/api/v1/shop/sites/%d/ask" % self.site["id"]
        with mock.patch("core.ai.generate", side_effect=RuntimeError("off")):
            r = self.client.post(url, {"q": "২টা থেকে ৩টার মধ্যে ক্যাশে কে গিয়েছিল?"}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
            self.assertEqual([x["event_id"] for x in r.data["results"]], [e1.id])
            self.assertIn("মুখ চেনা নেই", " ".join(r.data["answer"]))
            r = self.client.post(url, {"q": "show the red car at the gate"}, format="json")
            self.assertEqual([x["event_id"] for x in r.data["results"]], [e2.id])
            self.assertEqual(r.data["results"][0]["colour"], "red")
            r = self.client.post(url, {"q": "anything at all"}, format="json")
            self.assertFalse(r.data["used_ai"])
        # the AI may read a vague question (Claude via the router)
        with mock.patch("core.ai.generate",
                        return_value=('{"kind": "vehicle", "colour": "red"}', 0.0)):
            r = self.client.post(url, {"q": "lal gari kokhon ashlo"}, format="json")
            self.assertTrue(r.data["used_ai"])
            self.assertEqual([x["event_id"] for x in r.data["results"]], [e2.id])
        self.assertEqual(self.client.post(url, {"q": " "}, format="json").status_code, 422)
