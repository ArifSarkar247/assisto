"""Device control plane: pair check, heartbeat + config pull, live hand-off."""
from shopbox.config import AppConfig, CameraConfig
from shopbox.device import (DeviceClient, DeviceSync, apply_server_camera,
                            apply_server_site)


class Resp:
    def __init__(self, status, data):
        self.status_code, self._d = status, data

    def json(self):
        return self._d


class Session:
    def __init__(self, routes):
        self.routes, self.calls, self.headers = routes, [], {}

    def _hit(self, method, url, kw):
        self.calls.append((method, url, kw))
        for suffix, resp in self.routes.items():
            if url.endswith(suffix):
                return resp(kw) if callable(resp) else resp
        return Resp(404, {})

    def post(self, url, **kw):
        return self._hit("POST", url, kw)

    def get(self, url, **kw):
        return self._hit("GET", url, kw)


BASE = "https://api.lifeassisto.com/api/v1/"


def test_pair_check_ok_bad_unsupported_and_token_in_header_only():
    s = Session({"shop/pair/check": Resp(200, {"site": {"name": "Mirpur"}})})
    c = DeviceClient(BASE, session=s)
    assert c.pair_check("TOK") == ("ok", "Mirpur")
    method, url, kw = s.calls[0]
    assert url == BASE + "shop/pair/check"
    assert kw["headers"]["X-Shop-Token"] == "TOK"
    assert "TOK" not in url                       # never in the URL
    assert DeviceClient(BASE, session=Session(
        {"shop/pair/check": Resp(401, {})})).pair_check("x")[0] == "bad"
    assert DeviceClient(BASE, session=Session({})).pair_check("x")[0] == "unsupported"


def test_plain_http_refused():
    try:
        DeviceClient("http://example.com/api/v1/")
    except ValueError:
        return
    raise AssertionError("http must be refused")


def test_apply_server_camera_enabled_and_hours_keep_local_timezone():
    cam = CameraConfig.new("Till", "rtsp://cam/1")
    cam.hours = {"open": "09:00", "close": "22:00", "timezone": "Asia/Dhaka",
                 "closed_days": [4]}
    changed = apply_server_camera(cam, {"enabled": False,
                                        "hours": {"open": "10:00", "close": "20:00"}},
                                  site_hours={"open": "09:00", "close": "22:00"})
    assert changed and cam.enabled is False
    assert cam.hours["open"] == "10:00" and cam.hours["closed_days"] == [4]
    assert cam.hours["timezone"] == "Asia/Dhaka"
    # same as the site's hours -> not stored as a per-camera override
    cam2 = CameraConfig.new("B", "rtsp://cam/2")
    assert not apply_server_camera(cam2, {"enabled": True,
                                          "hours": {"open": "09:00", "close": "22:00"}},
                                   site_hours={"open": "09:00", "close": "22:00"})
    assert cam2.hours is None


def test_apply_server_site_hours():
    cfg = AppConfig()
    assert apply_server_site(cfg, {"hours": {"open": "08:30", "close": "21:00"}})
    assert cfg.hours["open"] == "08:30" and cfg.hours["timezone"]
    assert not apply_server_site(cfg, {"hours": {}})


def test_sync_tick_pulls_config_only_on_version_change_and_hands_off_live():
    beats = {"n": 0}

    def hb(kw):
        beats["n"] += 1
        return Resp(200, {"config_version": "v1",
                          "live_pending": [{"id": 7}] if beats["n"] == 1 else []})

    s = Session({"shop/heartbeat": hb,
                 "shop/config": Resp(200, {"site": {}, "cameras": [{"enabled": True}]})})
    got, live = [], []
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"cam1": "CAMTOK"},
                      ["live"], lambda cfg, cid: got.append(cid),
                      on_live=lambda tok, sess: live.append((tok, sess["id"])))
    sync.tick()
    sync.tick()
    assert got == ["cam1"]                       # config pulled once (v1)
    assert live == [("CAMTOK", 7)]
    hb_call = [c for c in s.calls if c[1].endswith("shop/heartbeat")][0]
    assert hb_call[2]["json"]["caps"] == ["live"]
    assert hb_call[2]["json"]["platform"] == "windows"
    assert sync.online is True


def test_sync_marks_unauthorized_on_401():
    s = Session({"shop/heartbeat": Resp(401, {})})
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"": "SITE"}, [],
                      lambda *a: None)
    sync.tick()
    assert sync.unauthorized and sync.online is False


def test_engine_device_tokens_and_server_config(tmp_path):
    from shopbox.engine import Engine
    from shopbox.secure_store import SITE_TOKEN, SecretStore, cam_key

    class NoDet:
        name = "motion_only"

        def detect(self, f):
            return []

    cfg = AppConfig()
    cam = CameraConfig.new("Till", "rtsp://cam/1")
    cfg.cameras = [cam]
    store = SecretStore(str(tmp_path / "s"))
    store.set(SITE_TOKEN, "SITE")
    eng = Engine(cfg, store, detector=NoDet())
    assert eng.device_tokens() == {"": "SITE"}
    store.set(cam_key(cam.id, "token"), "CAM")
    assert eng.device_tokens() == {cam.id: "CAM"}
    eng.latest[cam.id] = "FRAME"
    assert eng.frame_source_for("CAM")() == "FRAME"
    eng.apply_server_config({"site": {}, "cameras": [{"enabled": False}]}, cam.id)
    assert cam.enabled is False
