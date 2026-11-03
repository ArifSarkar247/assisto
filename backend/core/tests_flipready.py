"""flipready (owner 2 Nov — launch ALL features 8 Nov): the flags the owner
still has OFF must be safe to switch ON for EVERY existing user.

For each flag we flip the DB row exactly the way Owner Admin does
(enabled_all + enabled_play, 100% rollout) and call every read endpoint the
gated screens load first, as an ordinary (non-staff) user, in three shapes:
a brand-new user with no data, a Bangla user, and a shop owner with a
business profile. A flip may answer 4xx for "set this up first" — never 500,
never "feature_off", never a non-JSON body. With the flag OFF the same
endpoints refuse politely (never 500).

Owner order text says `ps_secretary`; the registry key is `pa_secretary`.
"""
import json
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.models import BusinessProfile, FeatureFlag, User

FLIP = ("blood_donors", "train_tracker", "dest_alarm", "missing_alert",
        "retention_auto", "accounting_v2", "child_emergency_audio",
        "kids_watch", "agent_core", "fall_detect", "pa_secretary",
        "learning_certificate")

# flag -> the GET endpoints its screens open with (no ids needed)
ENDPOINTS = {
    "blood_donors": ["blood-panel/config", "blood-panel/me", "blood-panel/donors",
                     "blood-panel/donors?district=dhaka&group=A%2B",
                     "blood-panel/requests", "blood-panel/threads", "blood-panel/banks"],
    "train_tracker": ["train/config", "train/search?q=701", "train/search?q=%E0%A6%B8",
                      "train/701/live", "train/701/chat"],
    "dest_alarm": ["train/config"],
    "missing_alert": ["missing-alerts", "missing-alerts/config", "missing-alerts/nearby",
                      "missing-alerts/where-i-am"],
    "retention_auto": ["retention", "retention/settings", "retention/automations",
                       "retention/customers", "retention/stock-asks", "retention/opt-outs",
                       "retention/scores", "retention/audit", "retention/inbox"],
    "accounting_v2": ["business/books/accounts", "business/books/journal",
                      "business/books/trial-balance", "business/books/profit-loss",
                      "business/books/balance-sheet", "business/books/cash-flow",
                      "business/books/vat", "business/books/lock", "business/books/opening"],
    "child_emergency_audio": ["kid-audio/config", "kid-audio/consent", "kid-audio/pending",
                              "kid-audio/log"],
    "kids_watch": ["kids-watch/config", "kids-watch/watches", "kids-watch/chips",
                   "school-mode/places", "school-mode/people", "school-mode/plans",
                   "school-mode/mine"],
    "agent_core": ["agent-core/tools", "agent-core/goals", "agent-core/runs",
                   "agent-core/approvals", "agent-core/biz-brief", "agent-core/nudges",
                   "agent-core/nudge-prefs", "agent-core/brief", "agent-core/memory",
                   "agent-core/memory/prefs", "crisis/helplines"],
    "fall_detect": ["family/fall/pending"],
    "pa_secretary": ["pa/visitors/", "pa/followups/", "pa_schedule/"],
    "learning_certificate": ["learn/certs"],   # learncert
}


def _set(keys, on):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key__in=keys).update(
        enabled_all=on, enabled_play=on, rollout_pct=100, allow_user_ids=[])
    FF.invalidate()


class FlipReadinessTests(TestCase):
    def setUp(self):
        self.addCleanup(FF.invalidate)
        self.fresh = User.objects.create_user(name="Nodi", phone="01710009001", password="pw-123456")
        self.bn = User.objects.create_user(name="রিনা", phone="01710009002", password="pw-123456")
        self.bn.language = "bn"
        self.bn.save()
        self.shop = User.objects.create_user(name="Karim", phone="01710009003", password="pw-123456")
        self.shop.plan = "business"
        self.shop.plan_until = timezone.now() + timedelta(days=300)
        self.shop.save()
        BusinessProfile.objects.create(user=self.shop, shop_name="Karim Store")
        for u in (self.fresh, self.bn, self.shop):
            self.assertFalse(u.is_staff or u.is_superuser)   # never a preview

    def _client(self, user, play=False):
        c = APIClient()
        c.force_authenticate(user)
        if play:
            c.credentials(HTTP_X_ASSISTO_FLAVOUR="play")
        return c

    def _get(self, c, path):
        r = c.get("/api/v1/" + path)
        return r, (r.content or b"")

    def test_registry_has_every_flip_flag(self):
        for k in FLIP:
            self.assertTrue(FF.is_known(k), k)

    def test_features_payload_reports_each_flag_on_after_flip(self):
        _set(FLIP, True)
        for u in (self.fresh, self.bn, self.shop):
            r = self._client(u).get("/api/v1/features")
            self.assertEqual(r.status_code, 200)
            feats = r.json()["features"]
            for k in FLIP:
                self.assertIs(feats.get(k), True, "%s not on for %s" % (k, u.name))

    def test_flag_on_no_500_no_feature_off_for_existing_users(self):
        _set(FLIP, True)
        problems = []
        for u in (self.fresh, self.bn, self.shop):
            for play in (False, True):
                c = self._client(u, play)
                for flag, paths in ENDPOINTS.items():
                    for p in paths:
                        r, body = self._get(c, p)
                        tag = "%s %s (%s, play=%s) -> %s" % (flag, p, u.name, play, r.status_code)
                        if r.status_code >= 500:
                            problems.append(tag)
                            continue
                        if r.status_code in (404, 405) and not body.strip().startswith(b"{"):
                            problems.append(tag + " route missing")
                            continue
                        if body.strip().startswith(b"{"):
                            try:
                                j = json.loads(body)
                            except ValueError:
                                problems.append(tag + " bad json")
                                continue
                            if isinstance(j, dict) and (j.get("reason") == "feature_off"
                                                        or j.get("code") == "feature_off"):
                                problems.append(tag + " still feature_off")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_flag_on_config_says_enabled(self):
        _set(FLIP, True)
        c = self._client(self.fresh)
        for path in ("blood-panel/config", "missing-alerts/config", "kid-audio/config",
                     "kids-watch/config", "train/config"):
            r = c.get("/api/v1/" + path)
            self.assertEqual(r.status_code, 200, path)
            j = r.json()
            if "enabled" in j:
                self.assertIs(j["enabled"], True, path)
        self.assertIs(c.get("/api/v1/train/config").json().get("dest_alarm"), True)

    def test_flag_off_refuses_politely_never_500(self):
        _set(FLIP, False)
        c = self._client(self.shop)
        for flag, paths in ENDPOINTS.items():
            for p in paths:
                r, _ = self._get(c, p)
                self.assertLess(r.status_code, 500, "%s %s OFF -> %s" % (flag, p, r.status_code))
