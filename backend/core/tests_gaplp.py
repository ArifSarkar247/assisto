"""gap-lp (owner order 17 Nov 10:10, feature gap sweep) — Language Partner:
a result / certificate is built only from bands the SERVER gave (a phone
cannot post 9.0 x 4 and get a certificate); a certificate only for a full
mock; the book companion never keeps the typed Cambridge key; the sheets
list applies the flag + owner guard; a cut / broken role-play answer never
reaches the learner as raw JSON and costs nothing; a bad `n` is a 400.
Sample data only; never the owner account."""
from unittest import mock

from django.test import SimpleTestCase, TestCase, override_settings

from core import ai
from core import lp_service as LS
from core import lp_views as LV
from core.models import LpAttempt, LpItem
from core.tests_lpcore import _MEDIA, _bundle, _client, _user, sample_mock

V = "/api/v1"


def _att(u, kind, sec, band, **data):
    return LpAttempt.objects.create(user=u, kind=kind, item_key="ielts-ac-t01", section=sec,
                                    band=band, data=data)


@override_settings(MEDIA_ROOT=_MEDIA)
@mock.patch("core.lp_service.flag_on", return_value=True)
class VerifiedResultTests(TestCase):
    def setUp(self):
        LS.import_bundle(_bundle([sample_mock()]))
        self.u = _user(61)
        self.c = _client(self.u)

    def _finish(self, bands):
        return self.c.post(V + "/lp/mocks/ielts-ac-t01/finish", {"bands": bands, "weak": []},
                           format="json").json()

    def test_forged_bands_are_ignored(self, _f):
        r = self._finish({"listening": 9, "reading": 9, "writing": 9, "speaking": 9})
        self.assertIsNone(r["overall"])
        self.assertEqual(r["bands"], {})
        self.assertIsNone(r["certificate_url"])
        cert = self.c.get(V + "/lp/certificate/%d" % r["result_id"])
        self.assertEqual((cert.status_code, cert.json()["reason"]), (404, "not_full"))

    def test_server_bands_win_and_writing_weights_task2(self, _f):
        _att(self.u, "mark", "listening", 6.0)
        _att(self.u, "mark", "listening", 7.0)          # the latest mark wins
        _att(self.u, "mark", "reading", 6.5)
        _att(self.u, "writing", "writing", 5.0, task=1)
        _att(self.u, "writing", "writing", 6.5, task=2)  # (5 + 2 x 6.5) / 3 = 6.0
        _att(self.u, "speaking", "speaking", 6.0, part=1)
        _att(self.u, "speaking", "speaking", 7.0, part=2)  # mean 6.5
        r = self._finish({"listening": 9, "reading": 9, "writing": 9, "speaking": 9})
        self.assertEqual(r["bands"], {"listening": 7.0, "reading": 6.5, "writing": 6.0, "speaking": 6.5})
        self.assertEqual(r["overall"], 6.5)
        self.assertTrue(r["certificate_url"].endswith("/lp/certificate/%d" % r["result_id"]))
        pdf = self.c.get(V + "/lp/certificate/%d" % r["result_id"])
        self.assertEqual(pdf["Content-Type"], "application/pdf")

    def test_other_users_and_old_attempts_do_not_count(self, _f):
        other = _user(62)
        _att(other, "mark", "listening", 8.0)
        old = _att(self.u, "mark", "reading", 8.0)
        LpAttempt.objects.filter(pk=old.pk).update(created_at=old.created_at - LS.VERIFY_WINDOW * 2)
        r = self._finish({"listening": 8, "reading": 8})
        self.assertEqual(r["bands"], {})

    def test_partial_mock_has_no_certificate(self, _f):
        _att(self.u, "mark", "reading", 6.5)
        r = self._finish({"reading": 6.5})
        self.assertEqual(r["bands"], {"reading": 6.5})
        self.assertIsNone(r["certificate_url"])
        self.assertEqual(self.c.get(V + "/lp/certificate/%d" % r["result_id"]).status_code, 404)

    def test_bad_n_is_400(self, _f):
        r = self.c.post(V + "/lp/weak/practice", {"tags": ["tfng"], "n": "ten"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "bad_n"))


@mock.patch("core.lp_service.flag_on", return_value=True)
class CompanionKeyTests(TestCase):
    def test_typed_key_is_never_stored_or_returned(self, _f):
        u = _user(63)
        c = _client(u)
        key = {str(n): "answer%d" % n for n in range(1, 41)}
        r = c.post(V + "/lp/companion/mark", {"book": 19, "test": 3, "section": "listening",
                                              "answers": {"1": "answer1", "2": "x"}, "key": key},
                   format="json").json()
        self.assertEqual(r["raw"], 1)
        row = LpAttempt.objects.get(user=u, kind="companion")
        self.assertNotIn("key", row.data)
        self.assertNotIn("answer40", str(row.data))    # nothing of the typed key is kept
        self.assertEqual(row.data["right"], [1])
        # an old row that still holds a key never sends it back
        LpAttempt.objects.create(user=u, kind="companion", section="reading",
                                 data={"book": 18, "test": 1, "key": {"1": "x"}})
        for s in c.get(V + "/lp/companion/sheets").json()["sheets"]:
            self.assertNotIn("key", s)

    def test_sheets_apply_flag(self, flag):
        flag.return_value = False
        r = _client(_user(64)).get(V + "/lp/companion/sheets")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "feature_off"))


class RoleReplyTests(SimpleTestCase):
    def test_parse(self):
        f = LV.role_reply
        self.assertEqual(f('{"reply":"Passport, please?","fix":null}'), ("Passport, please?", None))
        reply, fix = f('Sure. {"reply":"Next?","fix":{"wrong":"I go","right":"I went",'
                       '"why_en":"past","why_bn":"অতীত"}}')
        self.assertEqual((reply, fix["right"], fix["why_bn"]), ("Next?", "I went", "অতীত"))
        self.assertEqual(f('{"reply":"Welcome. Where are you trav'), ("Welcome.", None))  # whole sentences
        self.assertEqual(f('{"reply":"Where are you trav'), ("", None))
        self.assertEqual(f('{"rep'), ("", None))
        self.assertEqual(f("Plain line."), ("Plain line.", None))


@mock.patch("core.lp_service.flag_on", return_value=True)
class RoleplayCutTests(TestCase):
    def setUp(self):
        LpItem.objects.create(kind="scenario", key="scenario-bank", status="human_approved",
                              data={"id": "bank", "title_en": "Bank", "ai_role": "a bank officer",
                                    "opening": "Good morning. How can I help?"})
        self.u = _user(65)
        self.c = _client(self.u)

    def _post(self, text):
        from core import learn_views as LVW
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", return_value=(text, {})), \
                mock.patch.object(LVW, "quota_left", return_value=3), \
                mock.patch.object(LVW, "_use_quota") as use:
            r = self.c.post(V + "/lp/life/roleplay", {"scenario_id": "bank", "message": "I want open account"},
                            format="json").json()
        return r, use

    def test_cut_json_is_busy_and_free_turn_kept(self, _f):
        r, use = self._post('{"reply":"Sure, which acc')
        self.assertEqual((r["ai_state"], r["reply"]), ("busy", None))
        use.assert_not_called()

    def test_good_reply_uses_a_free_turn(self, _f):
        r, use = self._post('{"reply":"Sure. Which account?","fix":{"wrong":"want open",'
                            '"right":"want to open","why_en":"to + verb","why_bn":"to লাগে"}}')
        self.assertEqual((r["ai_state"], r["reply"], r["fix"]["right"]),
                         ("used", "Sure. Which account?", "want to open"))
        use.assert_called_once()
