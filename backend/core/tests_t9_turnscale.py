"""t9-turnscale: TURN server list config + fallback, managed-TURN overflow
gating (provider HTTP mocked — never called for real here), the coturn
monitor parsers / thresholds / alert de-dupe, and the relay cost math."""
import json
from datetime import timedelta
from types import SimpleNamespace
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone

from core import turn_monitor as M
from core import turn_pool as P
from core.logic import rtc as RTC
from core.models import (CallRecord, CallSession, FamilyAlert, Integration,
                         TurnConfig, TurnRelayUsage, TurnSample, User)

SECRET = "unit-test-secret"
NOW = 1_800_000_000


def _legacy(creds, host="turn.lifeassisto.com", port=3478):
    return [{"urls": ["stun:%s:%s" % (host, port)]},
            {"urls": ["turn:%s:%s?transport=udp" % (host, port),
                      "turn:%s:%s?transport=tcp" % (host, port)],
             "username": creds["username"], "credential": creds["credential"]}]


@override_settings(TURN_SERVERS="", TURN_STATIC_SECRET=SECRET)
class ListConfigTests(TestCase):
    def setUp(self):
        self.creds = RTC.turn_credentials(SECRET, 42, NOW)

    def test_no_list_is_byte_identical_to_before(self):
        out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(json.dumps(out), json.dumps(_legacy(self.creds)))

    def test_owner_list_broken_falls_back(self):
        TurnConfig.objects.create(pk=1, servers_text="bad host!!")
        out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(out, _legacy(self.creds))

    def test_parse_comma_and_json(self):
        a = P.parse_servers("turn.a.com, turn.b.com:3479|w=2|tls=0|region=sg|secret_env=TURN_B")
        self.assertEqual([s["host"] for s in a], ["turn.a.com", "turn.b.com"])
        self.assertEqual((a[1]["port"], a[1]["tls_port"], a[1]["weight"], a[1]["secret_env"]),
                         (3479, 0, 2.0, "TURN_B"))
        self.assertEqual(a[0]["tls_port"], 5349)
        j = P.parse_servers('[{"host":"turn.a.com","weight":3}]')
        self.assertEqual(j[0]["weight"], 3.0)
        for bad in ("turn.a.com|w=0", "x.com:99999", "a.com|secret_env=lower",
                    "a.com, a.com", '{"host": 5', "a.com|zzz=1"):
            with self.assertRaises(P.ConfigError, msg=bad):
                P.parse_servers(bad)

    def test_env_list_builds_udp_tcp_tls_per_host(self):
        with override_settings(TURN_SERVERS="turn.lifeassisto.com, turn2.lifeassisto.com"):
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        turns = [e for e in out if "username" in e]
        self.assertEqual(len(turns), 2)
        self.assertEqual(sorted(e["urls"][0].split(":")[1] for e in turns),
                         ["turn.lifeassisto.com", "turn2.lifeassisto.com"])
        for e in turns:
            self.assertEqual(len(e["urls"]), 3)
            self.assertTrue(e["urls"][2].startswith("turns:"))
            self.assertTrue(e["urls"][2].endswith(":5349?transport=tcp"))
            self.assertEqual(e["username"], self.creds["username"])
        self.assertEqual(len([e for e in out if "username" not in e]), 2)

    def test_owner_list_beats_env_and_off_entries_skipped(self):
        TurnConfig.objects.create(pk=1, servers_text="turn9.x.com|tls=0\nturn8.x.com|off")
        with override_settings(TURN_SERVERS="turn.lifeassisto.com"):
            servers, src, _ = P.configured_servers()
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(src, "owner")
        self.assertEqual([s["host"] for s in servers], ["turn9.x.com"])
        self.assertEqual(out[1]["urls"], ["turn:turn9.x.com:3478?transport=udp",
                                          "turn:turn9.x.com:3478?transport=tcp"])

    def test_own_secret_env(self):
        with override_settings(TURN_SERVERS="turn2.x.com|secret_env=T9_TEST_SECRET"), \
                mock.patch.dict("os.environ", {"T9_TEST_SECRET": "other"}):
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        exp = RTC.turn_credentials("other", 42, NOW)
        self.assertEqual(out[1]["credential"], exp["credential"])
        self.assertNotEqual(out[1]["credential"], self.creds["credential"])
        # secret env missing -> that host is skipped -> legacy fallback
        with override_settings(TURN_SERVERS="turn2.x.com|secret_env=T9_MISSING"):
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(out, _legacy(self.creds))

    def test_unhealthy_dropped_all_down_fail_open(self):
        import time
        now = time.time()
        TurnConfig.objects.create(pk=1, servers_text="a.x.com, b.x.com",
                                  health={"a.x.com:3478": {"fails": 3, "ts": now}})
        out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        hosts = [e["urls"][0] for e in out if "username" in e]
        self.assertEqual(hosts, ["turn:b.x.com:3478?transport=udp"])
        cfg = TurnConfig.objects.get(pk=1)
        cfg.health = {"a.x.com:3478": {"fails": 3, "ts": now},
                      "b.x.com:3478": {"fails": 2, "ts": now}}
        cfg.save()
        out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(len([e for e in out if "username" in e]), 2)
        # stale health is ignored
        cfg.health = {"a.x.com:3478": {"fails": 9, "ts": now - 3600}}
        cfg.save()
        out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(len([e for e in out if "username" in e]), 2)

    def test_rendezvous_order_stable_and_weighted(self):
        servers = P.parse_servers("a.x.com|w=1, b.x.com|w=3")
        self.assertEqual(P.order_for(servers, 7), P.order_for(servers, 7))
        firsts = [P.order_for(servers, u)[0]["host"] for u in range(2000)]
        share = firsts.count("b.x.com") / 2000.0
        self.assertTrue(0.68 < share < 0.82, share)    # ~75% for weight 3:1

    def test_max_hosts_cap(self):
        with override_settings(TURN_SERVERS="a.x.com,b.x.com,c.x.com,d.x.com",
                               TURN_MAX_ICE_HOSTS=2):
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(len([e for e in out if "username" in e]), 2)

    def test_rtc_turn_endpoint_uses_list(self):
        from rest_framework.test import APIClient
        u = User.objects.create_user(phone="01710000991", password="x", name="T")
        c = APIClient()
        c.force_authenticate(u)
        with override_settings(TURN_SERVERS="turn.lifeassisto.com, turn2.lifeassisto.com"), \
                mock.patch("core.logic.rtc.throttle_decision",
                           return_value={"throttled": False, "reason": ""}):
            r = c.get("/api/v1/rtc/turn")
        self.assertEqual(r.status_code, 200)
        urls = [x for e in r.json()["ice_servers"] for x in e["urls"]]
        self.assertIn("turns:turn2.lifeassisto.com:5349?transport=tcp", urls)


CF_BODY = {"iceServers": [{"urls": ["stun:stun.cloudflare.com:3478"]},
                          {"urls": ["turn:turn.cloudflare.com:3478?transport=udp"],
                           "username": "cfuser", "credential": "cfpass"}]}


class _Resp:
    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


@override_settings(TURN_SERVERS="", TURN_STATIC_SECRET=SECRET,
                   INTEGRATIONS_FERNET_KEY="")
class OverflowTests(TestCase):
    def setUp(self):
        from django.core.cache import cache
        cache.clear()
        self.creds = RTC.turn_credentials(SECRET, 42, NOW)

    def _save(self, status="working", **cfg):
        base = {"key_id": "k1", "api_token": "tok", "enabled": "on", "mode": "always"}
        base.update(cfg)
        Integration.objects.update_or_create(
            slug="turn_overflow", defaults={"enc_blob": json.dumps(base), "status": status})

    def _run(self):
        from core import integrations as I
        with mock.patch.object(I, "_decrypt", lambda b: json.loads(b) if b else {}), \
                mock.patch("urllib.request.urlopen", return_value=_Resp(CF_BODY)) as up:
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        return out, up

    def test_off_by_default_no_http(self):
        out, up = self._run()
        self.assertEqual(out, _legacy(self.creds))
        up.assert_not_called()
        self.assertIn("turn_overflow", __import__("core.integrations").integrations.REGISTRY)

    def test_saved_but_not_tested_or_disabled_stays_off(self):
        self._save(status="not_set")
        out, up = self._run()
        self.assertEqual(out, _legacy(self.creds))
        self._save(status="working", enabled="off")
        out, up = self._run()
        self.assertEqual(out, _legacy(self.creds))
        up.assert_not_called()

    def test_always_mode_appends_after_own_and_key_stays_server_side(self):
        self._save()
        out, up = self._run()
        self.assertEqual(out[:2], _legacy(self.creds))
        self.assertEqual(out[2], CF_BODY["iceServers"][1])     # only the TURN entry
        req = up.call_args[0][0]
        self.assertIn("/turn/keys/k1/credentials/generate-ice-servers", req.full_url)
        self.assertEqual(req.headers["Authorization"], "Bearer tok")
        self.assertNotIn("tok", json.dumps(out))
        # cached per user: a second call makes no new HTTP request
        out2, up2 = self._run()
        self.assertEqual(out2, out)
        up2.assert_not_called()

    def test_overflow_mode_only_over_threshold(self):
        self._save(mode="overflow", threshold_pct="70")
        out, up = self._run()                      # no sample -> not over
        self.assertEqual(len(out), 2)
        with override_settings(TURN_TOTAL_QUOTA=100, TURN_BPS_CAPACITY=0):
            TurnSample.objects.create(at=timezone.now(), allocations=80)
            out, up = self._run()
        self.assertEqual(len(out), 3)

    def test_provider_error_yields_nothing(self):
        self._save()
        from core import integrations as I
        with mock.patch.object(I, "_decrypt", lambda b: json.loads(b) if b else {}), \
                mock.patch("urllib.request.urlopen", side_effect=OSError("down")):
            out = RTC.ice_servers("turn.lifeassisto.com", 3478, self.creds)
        self.assertEqual(out, _legacy(self.creds))

    def test_old_response_shape_and_integration_test(self):
        from core import integrations as I
        old = {"iceServers": {"urls": ["turn:turn.cloudflare.com:3478"],
                              "username": "u", "credential": "c"}}
        with mock.patch("urllib.request.urlopen", return_value=_Resp(old)):
            self.assertEqual(P.cf_generate("k", "t", 300)[0]["username"], "u")
            ok, detail = I.test_turn_overflow({"key_id": "k", "api_token": "t"})
        self.assertTrue(ok)
        self.assertIn("enabled is off", detail)
        ok, _ = I.test_turn_overflow({"key_id": "k"})
        self.assertFalse(ok)


SS = """UNCONN 0 0 172.31.2.185:49160 0.0.0.0:*
UNCONN 0 0 172.31.2.185:65535 0.0.0.0:*
UNCONN 0 0 172.31.2.185:3478 0.0.0.0:*
ESTAB  0 0 172.31.2.185:50000 8.8.8.8:53
UNCONN 0 0 127.0.0.1:50001 0.0.0.0:*
UNCONN 0 0 172.31.2.185%ens5:55000 0.0.0.0:*
"""
CLI = """
    1) id=001000000000000001, user <1800000000:42>:
      usage: rp=10, rb=1000, sp=10, sb=1200
       rate: r=6000, s=6500, total=12500 (bytes per sec)
    2) id=001000000000000002, user <1800000000:43>:
       rate: r=100, s=200, total=300 (bytes per sec)

  Total sessions: 2
"""
LOG = """12: : session 001000000000000001: realm <turn.lifeassisto.com> user <1:probe>: incoming packet message processed, error 401: Unauthorized
13: : ERROR: check_stun_auth: Cannot find credentials of user <1:probe>
14: : session 001000000000000002: realm <x> user <1800000000:42>: incoming packet ALLOCATE processed, error 486: Allocation Quota Reached
15: : session 001000000000000003: realm <x> user <1800000000:42>: incoming packet ALLOCATE processed, error 486: Allocation Bandwidth Quota Reached
16: : ERROR: Cannot complete Allocation
17: : session 001000000000000004: usage: realm=<turn.lifeassisto.com>, username=<1800000000:42>, rp=500, rb=60000, sp=480, sb=58000
17: : session 001000000000000004: peer usage: realm=<turn.lifeassisto.com>, username=<1800000000:42>, rp=480, rb=57000, sp=500, sb=59000
18: : session 001000000000000005: usage: realm=<turn.lifeassisto.com>, username=<1800000000:43>, rp=5, rb=700, sp=5, sb=650
""".splitlines()


@override_settings(TURN_TOTAL_QUOTA=600, TURN_BPS_CAPACITY=31250000, TURN_MAX_BPS=250000,
                   TURN_RELAY_BUDGET_BYTES_S=31250000, TURN_RELAY_IP="172.31.2.185")
class MonitorTests(TestCase):
    def test_parsers(self):
        self.assertEqual(M.parse_ss_relays(SS, 49152, 65535, "172.31.2.185"), 3)
        self.assertEqual(M.parse_ss_relays(SS, 49152, 65535, ""), 4)
        ps = M.parse_cli_ps(CLI)
        self.assertEqual(ps, {"sessions": 2, "in_bps": 6100, "out_bps": 6700})
        self.assertEqual(M.parse_cli_ps("garbage")["sessions"], None)
        lg = M.parse_log_lines(LOG)
        self.assertEqual((lg["quota"], lg["bw_quota"], lg["alloc"], lg["auth"]), (1, 1, 1, 2))
        self.assertEqual(lg["usages"][0], {"user_id": 42, "bytes_in": 117000,
                                           "bytes_out": 58000 + 59000})
        self.assertEqual(lg["usages"][1]["bytes_out"], 650 + 700)   # no peer line
        name, rx, tx = M.parse_proc_net_dev(
            "Inter-|\n face |\n    lo: 1 2 0 0 0 0 0 0 3 4 0 0 0 0 0 0\n"
            "  ens5: 100 2 0 0 0 0 0 0 200 4 0 0 0 0 0 0\n")
        self.assertEqual((name, rx, tx), ("ens5", 100, 200))
        self.assertIsNone(M.rate(None, 5, 60))
        self.assertIsNone(M.rate(10, 5, 60))          # counter reset
        self.assertEqual(M.rate(0, 600, 60), 10)

    def test_effective_limit_reservation_ceiling(self):
        self.assertEqual(M.effective_alloc_limit(600, 31250000, 250000), 125)
        self.assertEqual(M.effective_alloc_limit(600, 0, 250000), 600)
        self.assertEqual(M.effective_alloc_limit(0, 0, 0), 0)
        self.assertEqual(M.limits()["alloc_limit"], 125)

    def test_thresholds(self):
        lim = M.limits()
        s = SimpleNamespace(allocations=88, relay_out_bps=None, nic_out_bps=10_000_000,
                            turn_cpu_pct=20.0, steal_pct=0.0)
        ev = M.evaluate_alerts(s, lim, 0)
        self.assertTrue(ev["alloc"][0])                       # 88/125 = 70.4%
        self.assertFalse(ev["bw"][0])                         # 32% of budget
        self.assertIn("whole-box", ev["bw"][1])
        self.assertFalse(ev["quota"][0])
        self.assertFalse(ev["cpu"][0])
        s.allocations, s.relay_out_bps = 87, 22_000_000
        ev = M.evaluate_alerts(s, lim, 1, {"turn.x.com:3478": {"fails": 2}})
        self.assertFalse(ev["alloc"][0])
        self.assertTrue(ev["bw"][0])                          # 70.4% of budget
        self.assertTrue(ev["quota"][0])
        self.assertTrue(ev["down:turn.x.com:3478"][0])
        lim2 = M.limits({"alloc_pct": 50, "bogus": 1})
        self.assertEqual(lim2["thresholds"]["alloc_pct"], 50)
        self.assertNotIn("bogus", lim2["thresholds"])

    def test_dedupe(self):
        ev = {"alloc": (True, "a"), "bw": (False, "b")}
        sends, st = M.dedupe(ev, {}, 1000, 60)
        self.assertEqual(sends, [("alloc", "fire", "a")])
        sends, st = M.dedupe(ev, st, 1060, 60)                # still active: quiet
        self.assertEqual(sends, [])
        sends, st = M.dedupe(ev, st, 1000 + 3600, 60)          # re-alert after 60 min
        self.assertEqual(sends, [("alloc", "fire", "a")])
        sends, st = M.dedupe({"alloc": (False, "a")}, st, 5000, 60)
        self.assertEqual(sends, [("alloc", "clear", "a")])
        sends, st = M.dedupe({"alloc": (False, "a")}, st, 5060, 60)
        self.assertEqual(sends, [])

    def test_run_once_records_alerts_once_and_prunes(self):
        owner = User.objects.create_superuser(phone="01710000992", password="x", name="O")
        TurnSample.objects.create(at=timezone.now() - timedelta(days=20), allocations=1)
        cpu = {"pid": 1, "ticks": 100, "total": 1000, "steal": 0, "hz": 100, "ncpu": 2}
        with mock.patch("core.push.notify_owner") as no:
            s, sends, st = M.run_once({}, probe=lambda h, p: True, ss_text=SS * 30,
                                      log_lines=LOG, cli_text=CLI, net_text="", cpu=cpu)
            self.assertEqual(s.allocations, 90)
            self.assertEqual(s.cli_sessions, 2)
            self.assertEqual(s.quota_errors, 1)
            self.assertEqual(s.relay_bytes_out, 117000 + 1350)
            keys = {k for k, kind, _ in sends if kind == "fire"}
            self.assertEqual(keys, {"alloc", "quota"})
            self.assertEqual(no.call_count, 1)
            self.assertEqual(FamilyAlert.objects.filter(user=owner, kind="turn_capacity").count(), 1)
            cpu2 = dict(cpu, ticks=160, total=13000, steal=1200)
            later = timezone.now() + timedelta(seconds=60)
            st["ts"] = later.timestamp() - 60
            s2, sends2, st = M.run_once(st, now=later, probe=lambda h, p: True,
                                        ss_text=SS * 30, log_lines=[], cli_text=CLI,
                                        net_text="", cpu=cpu2)
            self.assertEqual(sends2, [])                      # de-duplicated
            self.assertEqual(s2.turn_cpu_pct, 1.0)            # 60 ticks/100Hz/60s
            self.assertEqual(s2.steal_pct, 10.0)
        self.assertFalse(TurnSample.objects.filter(at__lt=timezone.now() - timedelta(days=15)).exists())
        self.assertEqual(TurnRelayUsage.objects.count(), 2)

    def test_log_reader_offsets(self):
        import os
        import tempfile
        d = tempfile.mkdtemp()
        p = os.path.join(d, "turn_1.log")
        open(p, "w").write("old line\n")
        lines, st = M.read_new_log(p, {})
        self.assertEqual(lines, [])                           # first run: from end
        open(p, "a").write("error 486: Allocation Quota Reached\n")
        lines, st = M.read_new_log(p, st)
        self.assertEqual(len(lines), 1)
        open(p, "w").write("x\n")                             # truncated/rotated
        lines, st = M.read_new_log(p, st)
        self.assertEqual(lines, ["x"])
        self.assertEqual(M.newest_log(os.path.join(d, "turn*.log")), p)


@override_settings(TURN_EGRESS_USD_PER_GB=0.1093, TURN_EST_VOICE_KBPS=52,
                   TURN_EST_VIDEO_KBPS=1000)
class CostTests(TestCase):
    def setUp(self):
        self.a = User.objects.create_user(phone="01710000993", password="x", name="A")
        self.b = User.objects.create_user(phone="01710000994", password="x", name="B")

    def _call(self, kind, secs, relayed=True):
        c = CallRecord.objects.create(caller=self.a, callee=self.b, kind=kind,
                                      duration_sec=secs, state="ended",
                                      ended_at=timezone.now())
        CallSession.objects.create(call=c, relayed=relayed)
        return c

    def test_estimate_math(self):
        self.assertEqual(M.bytes_per_min_estimate(52), 52000 / 8 * 2 * 60)   # 780 kB
        self.assertAlmostEqual(M.usd_for_bytes(1024 ** 3, 0.1093), 0.1093)
        with mock.patch("core.billing.cfg", return_value={"usd_bdt": 120}):
            self._call("voice", 600)
            self._call("voice", 600, relayed=False)
            r = M.relay_cost(30)
        v = r["rows"]["voice"]
        self.assertTrue(v["estimate"])
        exp_usd = 780000 / 1024 ** 3 * 0.1093
        self.assertAlmostEqual(v["usd_per_min"], round(exp_usd, 6))
        self.assertAlmostEqual(v["bdt_per_min"], round(exp_usd * 120, 4))
        self.assertEqual(v["relayed_min"], 10.0)              # P2P call not counted
        self.assertEqual(v["relayed_calls"], 1)
        vid = r["rows"]["video"]
        self.assertEqual(vid["bytes_per_min"], int(M.bytes_per_min_estimate(1052)))

    def test_measured_when_three_matched_calls(self):
        with mock.patch("core.billing.cfg", return_value={"usd_bdt": 120}):
            for _ in range(3):
                c = self._call("video", 120)
                cid, kind = M.match_usage_to_call(self.a.id, timezone.now())
                self.assertEqual((cid, kind), (c.id, "video"))
                TurnRelayUsage.objects.create(at=timezone.now(), user_id=self.a.id,
                                              bytes_out=20_000_000, call_kind=kind,
                                              call_id=cid)
            r = M.relay_cost(30)
        vid = r["rows"]["video"]
        self.assertTrue(vid["measured"])
        self.assertEqual(vid["bytes_per_min"], 10_000_000)    # 60 MB / 6 min
        self.assertAlmostEqual(vid["total_bdt"],
                               round(10_000_000 / 1024 ** 3 * 0.1093 * 120 * 6, 2), places=2)
        self.assertEqual(M.match_usage_to_call(None, timezone.now()), (None, ""))
