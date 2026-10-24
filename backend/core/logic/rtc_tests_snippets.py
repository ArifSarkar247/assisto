"""Pure self-tests for core.logic.rtc (Step 6 M3 TURN creds + throttle)."""
from . import rtc


def test_turn_credentials_shape_and_expiry():
    c = rtc.turn_credentials("secret123", 42, now_ts=1000, ttl=3600)
    assert c["username"] == "4600:42", c
    assert c["expiry"] == 4600
    assert c["ttl"] == 3600
    assert isinstance(c["credential"], str) and len(c["credential"]) > 0


def test_turn_credentials_hmac_is_deterministic_and_secret_bound():
    a = rtc.turn_credentials("s1", 1, now_ts=0, ttl=60)
    b = rtc.turn_credentials("s1", 1, now_ts=0, ttl=60)
    c = rtc.turn_credentials("s2", 1, now_ts=0, ttl=60)
    assert a["credential"] == b["credential"]          # deterministic
    assert a["credential"] != c["credential"]          # bound to the secret


def test_ice_servers_has_stun_and_turn_udp_tcp():
    creds = rtc.turn_credentials("s", 7, now_ts=0)
    ice = rtc.ice_servers("turn.example.com", 3478, creds)
    assert ice[0]["urls"] == ["stun:turn.example.com:3478"]
    turn = ice[1]
    assert "turn:turn.example.com:3478?transport=udp" in turn["urls"]
    assert "turn:turn.example.com:3478?transport=tcp" in turn["urls"]
    assert turn["username"] == creds["username"]
    assert turn["credential"] == creds["credential"]


def test_throttle_on_high_load():
    # build/test load (load 6 on 2 cpus) must NOT refuse calls any more
    assert not rtc.throttle_decision(loadavg1=6.3, cpus=2, mem_avail_mb=2000)["throttled"]
    d = rtc.throttle_decision(loadavg1=17.0, cpus=2, mem_avail_mb=2000)
    assert d["throttled"] and d["reason"] == "load"


def test_throttle_on_low_memory():
    d = rtc.throttle_decision(loadavg1=0.1, cpus=2, mem_avail_mb=100)
    assert d["throttled"] and d["reason"] == "memory"


def test_no_throttle_when_healthy():
    d = rtc.throttle_decision(loadavg1=0.5, cpus=2, mem_avail_mb=2000)
    assert not d["throttled"] and d["reason"] == ""


def run_all():
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            n += 1
    print(f"rtc: {n} tests passed")
    return n


if __name__ == "__main__":
    run_all()
