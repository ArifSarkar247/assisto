"""cctvx (CCTV extras): the Hikvision LAN siren (ISAPI audio alarm test, then
alarm output 1, honest not_supported), the `siren` gateway task using the
locally stored password (never posted), heartbeat extras (live_ids /
motion_at), and the owner's clip re-wrap for a Circle member."""
import base64
import hashlib

from shopbox import clip as EC
from shopbox import siren as S
from shopbox.device import DeviceClient, DeviceSync
from shopbox.tasks import GatewayTasks, secret_key, user_key

from test_tasks import BASE, Resp, Session, make_store


class Put:
    def __init__(self, answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, url, body, headers, timeout, auth):
        self.calls.append((url, body, auth))
        return self.answers.pop(0) if self.answers else 200


def test_audio_alarm_repeats_until_seconds():
    put = Put([200, 200, 200])
    r = S.hikvision_siren("192.168.1.64", 80, "admin", "pw", 15, put=put,
                          sleep=lambda s: None)
    assert r == {"ok": True, "code": "ok", "method": "audio_alarm", "seconds": 15}
    assert all("/AudioAlarm/1/test" in c[0] for c in put.calls)
    assert len(put.calls) == 3 and put.calls[0][2] == ("admin", "pw")


def test_falls_back_to_alarm_output_then_low():
    put = Put([403, 200, 200])
    slept = []
    r = S.hikvision_siren("192.168.1.64", 8080, None, "pw", 10, put=put,
                          sleep=slept.append)
    assert r["method"] == "alarm_output" and r["ok"]
    assert put.calls[1][0] == "http://192.168.1.64:8080/ISAPI/System/IO/outputs/1/trigger"
    assert b"<outputState>high</outputState>" in put.calls[1][1]
    assert b"<outputState>low</outputState>" in put.calls[2][1]
    assert slept == [10]


def test_honest_failures():
    assert S.hikvision_siren("192.168.1.64", 80, "a", "pw", 5, put=Put([403, 400]),
                             sleep=lambda s: None)["code"] == "not_supported"
    assert S.hikvision_siren("192.168.1.64", 80, "a", "pw", 5, put=Put([401]),
                             sleep=lambda s: None)["code"] == "auth_failed"
    assert S.hikvision_siren("192.168.1.64", 80, "a", "pw", 5, put=Put([0]),
                             sleep=lambda s: None)["code"] == "unreachable"
    assert S.hikvision_siren("192.168.1.64", 80, "a", None, 5)["code"] == "no_password"
    assert S.hikvision_siren("bad host!", 80, "a", "pw", 5)["code"] == "bad_host"


def test_siren_task_uses_the_local_secret_and_never_posts_it(tmp_path):
    store = make_store(tmp_path)
    store.set(secret_key(9), "Secret99")
    store.set(user_key(9), "admin")
    seen = {}

    def siren(host, port, user, secret, seconds, channel):
        seen.update(host=host, port=port, user=user, secret=secret, seconds=seconds)
        return {"ok": True, "code": "ok", "method": "audio_alarm", "seconds": seconds,
                "detail": "used Secret99"}
    tasks = {"tasks": [{"id": 31, "action": "siren", "camera_id": 9, "request": {
        "vendor": "hikvision", "host": "192.168.1.64", "http_port": 80, "seconds": 15}}]}
    s = Session({"shop/gateway/tasks": Resp(200, tasks),
                 "shop/gateway/tasks/31/result": Resp(200, {"ok": True})})
    from shopbox.device import DeviceClient as DC
    gt = GatewayTasks(DC(BASE, session=s), lambda: "SITE", store, siren=siren,
                      threaded=False, sleep=lambda x: None)
    assert gt.poll() == 1
    assert seen == {"host": "192.168.1.64", "port": 80, "user": "admin",
                    "secret": "Secret99", "seconds": 15}
    posted = [c for c in s.calls if c[1].endswith("/result")][0]
    assert "Secret99" not in repr(posted)


def test_heartbeat_extras():
    s = Session({"shop/heartbeat": Resp(200, {"config_version": ""})})
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"": "SITE"}, [],
                      lambda *a: None, camera_ids=lambda: [5, 6],
                      extra=lambda: {"live_ids": [5], "motion_at": 1793080800.5})
    sync.tick()
    body = [c for c in s.calls if c[1].endswith("shop/heartbeat")][0][2]["json"]
    assert body["camera_ids"] == [5, 6]
    assert body["live_ids"] == [5]
    assert body["motion_at"] == 1793080800.5


def test_owner_rewrap_opens_for_the_member_only():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    def kp():
        k = X25519PrivateKey.generate()
        return (k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                serialization.NoEncryption()),
                k.public_key().public_bytes(serialization.Encoding.Raw,
                                            serialization.PublicFormat.Raw))
    owner_priv, owner_pub = kp()
    mem_priv, mem_pub = kp()
    plain = b"ACG1" + b"\x00" * 64
    ct, meta = EC.seal(plain, [{"uid": 1, "pub": base64.b64encode(owner_pub).decode()}])
    w = EC.rewrap_for(meta, 1, owner_priv, base64.b64encode(mem_pub).decode())
    assert set(w) == {"key_id", "nonce", "ct", "sender_pub", "sender_key_id"}
    member_meta = {k: v for k, v in meta.items() if k != "wraps"}
    member_meta["wrap"] = w
    assert EC.open_clip(ct, member_meta, 2, mem_priv) == plain
    stranger_priv, _ = kp()
    try:
        EC.open_clip(ct, member_meta, 2, stranger_priv)
        assert False, "a stranger must not open it"
    except Exception:
        pass
    assert hashlib.sha256(ct).hexdigest() == meta["sha256"]
