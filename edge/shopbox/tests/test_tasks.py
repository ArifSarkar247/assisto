"""Gateway task runner: poll, secret saved locally (never posted), result
posted as multipart with one JPEG, retries, camera added to the config."""
import json

from shopbox import compat
from shopbox.config import AppConfig, ConfigStore
from shopbox.device import DeviceClient, DeviceSync
from shopbox.secure_store import SITE_TOKEN, SecretStore, _FernetCipher
from shopbox.tasks import GatewayTasks, secret_key, upsert_camera, user_key

BASE = "https://api.lifeassisto.com/api/v1/"
SECRET = "LabelCode77"
JPEG = b"\xff\xd8\xff\xe0fakejpeg"


class Resp:
    def __init__(self, status, data=None):
        self.status_code, self._d = status, data or {}

    def json(self):
        return self._d


class Session:
    def __init__(self, routes):
        self.routes, self.calls, self.headers = routes, [], {}

    def _hit(self, method, url, kw):
        self.calls.append((method, url, kw))
        for suffix, resp in self.routes.items():
            if url.endswith(suffix):
                r = resp(kw) if callable(resp) else resp
                if isinstance(r, Exception):
                    raise r
                return r
        return Resp(404)

    def post(self, url, **kw):
        return self._hit("POST", url, kw)

    def get(self, url, **kw):
        return self._hit("GET", url, kw)


def make_store(tmp_path):
    store = SecretStore(str(tmp_path / "s"), cipher=_FernetCipher(str(tmp_path / "k")))
    store.set(SITE_TOKEN, "SITE")
    return store


TASKS = {"tasks": [{"id": 12, "action": "check", "camera_id": 5, "request": {
    "vendor": "imou", "host": "192.168.1.20", "port": 554, "channel": 1,
    "stream": "sub", "username": "admin", "secret": SECRET}}]}


def fake_check_ok(req):
    assert req["secret"] == SECRET            # taken from the local store
    res = {"ok": True, "steps": [{"key": "reachable", "ok": True, "code": None,
                                  "detail": "used secret %s" % req["secret"]}],
           "info": {"rtsp_path": "/cam/realmonitor?channel=1&subtype=1"}}
    return compat.CheckOutcome(res, JPEG,
                               "rtsp://192.168.1.20:554/cam/realmonitor?channel=1&subtype=1",
                               "admin", SECRET)


def test_poll_saves_secret_runs_check_posts_without_secret(tmp_path):
    seen_secret_before_check = {}
    store = make_store(tmp_path)

    def check(req):
        seen_secret_before_check["v"] = store.get(secret_key(5))
        return fake_check_ok(req)

    s = Session({"shop/gateway/tasks": Resp(200, TASKS),
                 "shop/gateway/tasks/12/result": Resp(200, {"ok": True})})
    added = []
    gt = GatewayTasks(DeviceClient(BASE, session=s), lambda: store.get(SITE_TOKEN),
                      store, on_checked=lambda t, o: added.append((t, o)),
                      check=check, threaded=False, sleep=lambda s: None)
    assert gt.maybe_poll(1) == 1
    assert seen_secret_before_check["v"] == SECRET
    assert store.get(user_key(5)) == "admin"
    post = [c for c in s.calls if c[1].endswith("/result")][0]
    kw = post[2]
    assert kw["headers"]["X-Shop-Token"] == "SITE"
    files = kw["files"]
    assert files["snapshot"] == ("snapshot.jpg", JPEG, "image/jpeg")
    result_json = files["result"][1]
    assert SECRET not in result_json and json.loads(result_json)["ok"] is True
    assert SECRET not in json.dumps(kw.get("data") or {})
    assert added and added[0][0]["camera_id"] == 5
    assert "_secret" not in added[0][0] or added[0][0]["_secret"] is None
    # same task listed again -> not re-run
    assert gt.poll() == 0
    assert gt.last["ok"] is True


def test_poll_interval_and_retry_then_give_up(tmp_path):
    store = make_store(tmp_path)
    t = {"now": 0.0}
    posts = {"n": 0}

    def result(kw):
        posts["n"] += 1
        import requests
        return requests.ConnectionError()

    s = Session({"shop/gateway/tasks": Resp(200, TASKS),
                 "shop/gateway/tasks/12/result": result})
    sleeps = []
    gt = GatewayTasks(DeviceClient(BASE, session=s), lambda: "SITE", store,
                      check=fake_check_ok, threaded=False, clock=lambda: t["now"],
                      sleep=sleeps.append)
    gt.maybe_poll(0)                       # first call always polls
    assert posts["n"] == 4 and len(sleeps) == 3      # 1 try + 3 retries
    t["now"] = 30.0
    assert gt.maybe_poll(0) == 0           # not yet 60 s, nothing pending
    t["now"] = 61.0
    assert gt.maybe_poll(0) == 1           # failed post -> picked up again
    assert store.get(secret_key(5)) == SECRET   # secret survived (server wiped it)


def test_discover_task_and_crash_never_escapes(tmp_path):
    store = make_store(tmp_path)
    s = Session({"shop/gateway/tasks": Resp(200, {"tasks": [
        {"id": 1, "action": "discover", "camera_id": None, "request": {"timeout_s": 1}},
        {"id": 2, "action": "check", "camera_id": 9, "request": {"vendor": "tapo",
                                                                  "secret": "zzzz9"}},
        {"id": 3, "action": "reboot", "camera_id": None, "request": {}}]}),
        "/result": Resp(201)})

    def boom(req):
        raise RuntimeError("zzzz9 leaked?")

    gt = GatewayTasks(DeviceClient(BASE, session=s), lambda: "SITE", store,
                      check=boom, discover=lambda r: {"ok": True, "discovered": [
                          {"host": "192.168.1.5"}]}, threaded=False,
                      sleep=lambda s: None)
    assert gt.poll() == 3
    posted = {c[1].rsplit("/", 2)[-2]: json.loads(c[2]["files"]["result"][1])
              for c in s.calls if c[1].endswith("/result")}
    assert posted["1"]["discovered"][0]["host"] == "192.168.1.5"
    assert posted["2"]["ok"] is False and posted["2"]["code"] == "internal_error"
    assert "zzzz9" not in json.dumps(posted)
    assert posted["3"]["code"] == "not_supported"


def test_sync_tick_triggers_task_poll_on_tasks_pending(tmp_path):
    polled = []

    class T:
        def maybe_poll(self, n):
            polled.append(n)

    s = Session({"shop/heartbeat": Resp(200, {"config_version": "v", "tasks_pending": 2}),
                 "shop/config": Resp(200, {})})
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"": "SITE"}, ["gateway"],
                      lambda *a: None, tasks=T(), camera_ids=lambda: [5, 7])
    sync.tick()
    assert polled == [2]
    hb = [c for c in s.calls if c[1].endswith("shop/heartbeat")][0]
    assert hb[2]["json"]["camera_ids"] == [5, 7]


def test_upsert_camera_and_engine_capture_url(tmp_path):
    from shopbox.engine import Engine, EventLog
    from shopbox.person import NullDetector

    store = make_store(tmp_path)
    store.set(secret_key(5), SECRET)
    store.set(user_key(5), "admin")
    cfg = AppConfig()
    cs = ConfigStore(str(tmp_path / "config.json"))
    eng = Engine(cfg, store, detector=NullDetector(),
                 events=EventLog(str(tmp_path / "e.jsonl")), cfg_store=cs)
    task = {"id": 12, "camera_id": 5, "name": "Gate", "request": {
        "vendor": "imou", "host": "192.168.1.20", "port": 554, "channel": 1,
        "stream": "sub", "username": "admin"}}
    eng.on_camera_checked(task, fake_check_ok({"secret": SECRET}))
    cam = cfg.cameras[0]
    assert cam.server_id == 5 and cam.id == "srv5" and cam.name == "Gate"
    assert cam.source["vendor"] == "imou"
    disk = open(str(tmp_path / "config.json"), encoding="utf-8").read()
    assert SECRET not in disk and "192.168.1.20" in disk
    assert eng.rtsp_url_for("srv5") == \
        "rtsp://admin:%s@192.168.1.20:554/cam/realmonitor?channel=1&subtype=1" % SECRET
    assert eng.server_camera_ids() == [5]
    # a second good check updates, not duplicates
    upsert_camera(cfg, 5, task["request"], "rtsp://192.168.1.21:554/x")
    assert len(cfg.cameras) == 1 and cfg.cameras[0].rtsp_url.endswith("21:554/x")
    # reload: the v2 fields survive a round trip
    assert ConfigStore(str(tmp_path / "config.json")).load().cameras[0].server_id == 5
