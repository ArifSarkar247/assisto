"""gboxlinux — the Guard Box on Linux / Raspberry Pi / Windows: shared
thresholds with the phone, machine info, power-cut + internet-down events,
the speaker ("play" tasks), the 2 GB Pi profile, pairing by code, DVR health
scheduling. Made-up sample data only."""
import io
import json
import os
import re
import sys
import wave

import numpy as np
import pytest

from conftest import REPO_ROOT


# ------------------------------------------------------------ thresholds
def _dart(path):
    p = os.path.join(REPO_ROOT, "app", "lib", path)
    if not os.path.exists(p):
        pytest.skip("app sources not in this checkout")
    with open(p, encoding="utf-8") as f:
        return f.read()


def test_shared_thresholds_match_json_defaults_and_the_phone():
    from shopbox import thresholds
    from shopbox.config import DetectionConfig

    here = os.path.join(REPO_ROOT, "edge", "shopbox", "shopbox", "guard_thresholds.json")
    with open(here, encoding="utf-8") as f:
        js = json.load(f)
    for k, v in thresholds.DEFAULTS.items():
        assert js[k] == v, k
    assert thresholds.load() == thresholds.DEFAULTS
    assert DetectionConfig().person_score == js["person_score"]
    assert DetectionConfig().confirm_frames == js["confirm_frames"]

    model = _dart("cashguard/guard_box_model.dart")
    assert float(re.search(r"guardPersonDetector\(\{double threshold = ([0-9.]+)\}",
                           model).group(1)) == js["person_score"]
    logic = _dart("ipcam/ipcam_logic.dart")
    assert int(re.search(r"personCooldown = const Duration\(seconds: (\d+)\)",
                         logic).group(1)) == js["person_cooldown_s"]
    assert int(re.search(r"motionCooldown = const Duration\(minutes: (\d+)\)",
                         logic).group(1)) * 60 == js["motion_cooldown_s"]
    assert int(re.search(r"checkEvery = const Duration\(seconds: (\d+)\)",
                         logic).group(1)) == js["check_every_s"]
    assert int(re.search(r"lostFor = const Duration\(minutes: (\d+)\)",
                         logic).group(1)) * 60 == js["cam_lost_s"]
    assert int(re.search(r"LivePace\(\{this\.fps = (\d+)\}", logic).group(1)) == js["live_fps"]
    assert int(re.search(r"OfflineQueue\(\{this\.max = (\d+)\}", logic).group(1)) == \
        js["offline_queue_max"]
    motion = _dart("shop_motion.dart")
    assert int(re.search(r"this\.confirmFrames = (\d+)", motion).group(1)) == js["confirm_frames"]


# ------------------------------------------------------------ sysinfo
def _fake_sys(tmp_path, monkeypatch, files):
    for rel, content in files.items():
        p = tmp_path / rel.lstrip("/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    monkeypatch.setenv("SHOPBOX_SYSROOT", str(tmp_path))


@pytest.mark.skipif(sys.platform == "win32", reason="fake /sys tree uses ':' in names")
def test_sysinfo_pi_model_memory_and_undervoltage(tmp_path, monkeypatch):
    from shopbox import sysinfo
    _fake_sys(tmp_path, monkeypatch, {
        "/proc/device-tree/model": "Raspberry Pi 4 Model B Rev 1.4\x00",
        "/proc/meminfo": "MemTotal:        1912312 kB\nMemFree: 1 kB\n",
        "/sys/devices/platform/soc/soc:firmware/get_throttled": "50005",
        "/proc/sys/kernel/random/boot_id": "11111111-2222",
        "/proc/stat": "cpu 1 2 3\nbtime 1800000000\n"})
    assert sysinfo.device_model() == "Raspberry Pi 4 Model B Rev 1.4"
    assert sysinfo.is_raspberry_pi()
    assert sysinfo.mem_total_mb() == 1867
    assert sysinfo.boot_id() == "11111111-2222"
    assert sysinfo.boot_time() == 1800000000.0
    p = sysinfo.power_source()
    assert p["undervoltage"] is True and p["ac"] is None
    monkeypatch.setenv("SHOPBOX_BOOT_ID", "ci-reboot")
    assert sysinfo.boot_id() == "ci-reboot"


@pytest.mark.skipif(sys.platform == "win32", reason="Windows reads GetSystemPowerStatus")
def test_sysinfo_power_mains_and_battery(tmp_path, monkeypatch):
    from shopbox import sysinfo
    _fake_sys(tmp_path, monkeypatch, {
        "/sys/class/power_supply/AC/type": "Mains", "/sys/class/power_supply/AC/online": "0",
        "/sys/class/power_supply/BAT0/type": "Battery",
        "/sys/class/power_supply/BAT0/capacity": "64",
        "/sys/class/power_supply/BAT0/status": "Discharging",
        "/sys/class/dmi/id/sys_vendor": "Sample Vendor",
        "/sys/class/dmi/id/product_name": "Mini PC N100"})
    assert sysinfo.power_source() == {"ac": False, "battery_pct": 64, "undervoltage": None}
    assert sysinfo.device_model() == "Sample Vendor Mini PC N100"
    (tmp_path / "sys/class/power_supply/AC/online").write_text("1")
    assert sysinfo.power_source()["ac"] is True


def test_sd_notify_outside_systemd_is_a_noop(monkeypatch):
    from shopbox import sysinfo
    monkeypatch.delenv("NOTIFY_SOCKET", raising=False)
    assert sysinfo.sd_notify("READY=1") is False


# ------------------------------------------------------------ power / internet
class Clock:
    def __init__(self, t):
        self.t = float(t)

    def __call__(self):
        return self.t


def _queue(tmp_path, clock, boot_id="B1", boot_time=None):
    from shopbox.boxstate import BoxEventQueue
    return BoxEventQueue(str(tmp_path / "ev.json"), clock=clock,
                         boot_time=lambda: boot_time, boot_id=lambda: boot_id)


def test_power_cut_detected_after_reboot_with_off_time(tmp_path):
    from shopbox.boxstate import RunMarker
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    m = RunMarker(q, str(tmp_path / "run.json"), clock=clock, boot_id=lambda: "B1",
                  boot_time=lambda: 1_799_990_000.0, power=lambda: {"ac": None})
    assert m.start() is None                       # first run ever
    clock.t += 600
    m.touch(force=True)                            # alive at +600, then the power dies
    clock.t += 3000
    q2 = _queue(tmp_path, clock, boot_id="B2", boot_time=1_800_003_000.0)
    m2 = RunMarker(q2, str(tmp_path / "run.json"), clock=clock, boot_id=lambda: "B2",
                   boot_time=lambda: 1_800_003_000.0, power=lambda: {"ac": None})
    ev = m2.start()
    assert ev and ev["kind"] == "power_back" and ev["after_reboot"] is True
    pend = q2.pending()
    assert len(pend) == 1
    assert pend[0]["from"] == 1_800_000_600.0
    assert pend[0]["to"] == 1_800_003_000.0        # from the boot clock, at send time
    assert "to_boot" not in pend[0]
    q2.ack([pend[0]["id"]])
    assert q2.pending() == []


def test_restart_or_clean_reboot_is_not_a_power_cut(tmp_path):
    from shopbox.boxstate import RunMarker
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    path = str(tmp_path / "run.json")
    mk = lambda bid: RunMarker(q, path, clock=clock, boot_id=lambda: bid,
                               boot_time=lambda: None, power=lambda: {"ac": True})
    mk("B1").start()
    clock.t += 100
    assert mk("B1").start() is None                # crash + watchdog restart, same boot
    m = mk("B1")
    m.start()
    m.stop()                                       # clean stop
    clock.t += 100
    assert mk("B2").start() is None                # the owner rebooted it
    assert len(q) == 0


def test_ups_shutdown_on_battery_counts_as_power_cut(tmp_path):
    from shopbox.boxstate import RunMarker
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    path = str(tmp_path / "run.json")
    m = RunMarker(q, path, clock=clock, boot_id=lambda: "B1", boot_time=lambda: None,
                  power=lambda: {"ac": False})
    m.start()
    m.stop()                                       # stopped while on battery
    clock.t += 900
    m2 = RunMarker(q, path, clock=clock, boot_id=lambda: "B2", boot_time=lambda: None,
                   power=lambda: {"ac": True})
    ev = m2.start()
    assert ev and ev["low_power_stop"] is True
    assert q.pending()[0]["to"] == clock.t        # no boot clock: "back by the start"


def test_internet_down_event_only_after_three_minutes(tmp_path):
    from shopbox.boxstate import NetWatch
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    n = NetWatch(q, str(tmp_path / "net.json"), clock=clock)
    n.update(True)
    clock.t += 20
    n.update(False)
    clock.t += 60
    assert n.update(True) is None                  # an 80 s blip: not worth a push
    clock.t += 20
    n.update(False)
    clock.t += 1800
    n.update(False)
    # the box restarts while offline: the outage start survives
    n2 = NetWatch(q, str(tmp_path / "net.json"), clock=clock)
    assert n2.down_since == 1_800_000_080.0
    clock.t += 5
    ev = n2.update(True, queued=3)
    assert ev["kind"] == "net_back" and ev["queued_alerts"] == 3
    assert ev["from"] == 1_800_000_080.0 and ev["to"] == clock.t
    assert n2.update(None) is None


def test_power_watch_live_cut_and_return_on_ups(tmp_path):
    from shopbox.boxstate import PowerWatch
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    state = {"ac": True}
    pw = PowerWatch(q, clock=clock, power=lambda: dict(state, battery_pct=80), every_s=10)
    assert pw.poll() is None
    state["ac"] = False
    clock.t += 5
    assert pw.poll() is None                       # polled at most every 10 s
    clock.t += 10
    cut = pw.poll()
    assert cut["kind"] == "power_cut" and cut["battery_pct"] == 80
    state["ac"] = True
    clock.t += 600
    back = pw.poll()
    assert back["kind"] == "power_back" and back["on_battery"] is True
    assert back["to"] - back["from"] == 600
    # a box that cannot tell (ac None) never invents a power cut
    from shopbox.boxstate import BoxEventQueue
    q2 = BoxEventQueue(str(tmp_path / "q2.json"), clock=clock)
    pw2 = PowerWatch(q2, clock=clock, power=lambda: {"ac": None}, every_s=0)
    assert pw2.poll() is None and len(q2) == 0


def test_event_queue_is_bounded_and_survives_restart(tmp_path):
    from shopbox.boxstate import MAX_EVENTS
    clock = Clock(1_800_000_000)
    q = _queue(tmp_path, clock)
    for i in range(MAX_EVENTS + 5):
        q.add("net_back", clock.t - 1000 + i, clock.t)
    assert len(_queue(tmp_path, clock)) == MAX_EVENTS


# ------------------------------------------------------------ device sync
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


class FakeBox:
    def __init__(self, events):
        self.events, self.acked, self.ticks = list(events), [], []

    def pending(self):
        return list(self.events)

    def ack(self, ids):
        self.acked += list(ids)
        self.events = [e for e in self.events if e["id"] not in ids]

    def tick(self, online):
        self.ticks.append(online)


def test_sync_sends_box_events_once_health_and_play(tmp_path):
    from shopbox.device import DeviceClient, DeviceSync
    answers = {"n": 0}

    def hb(kw):
        answers["n"] += 1
        body = {"config_version": "", "play": [{"id": 9, "sound": "siren", "seconds": 5}]}
        if "box_events" in kw["json"]:
            body["box_events_ok"] = len(kw["json"]["box_events"])
        return Resp(200, body)

    s = Session({"shop/heartbeat": hb})
    box = FakeBox([{"id": "e1", "kind": "net_back", "from": 1.0, "to": 2.0}])
    played = []
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"c1": "T1", "c2": "T2"},
                      ["gateway"], lambda *a: None,
                      health=lambda cid: {"box_cam_lost": cid == "c2"}, box=box,
                      on_play=lambda tok, cid, tasks: played.append((tok, cid, tasks[0]["id"])))
    sync.tick()
    bodies = [c[2]["json"] for c in s.calls if c[1].endswith("shop/heartbeat")]
    assert [("box_events" in b) for b in bodies] == [True, False]   # one heartbeat carries them
    assert bodies[0]["health"] == {"box_cam_lost": False}
    assert bodies[1]["health"] == {"box_cam_lost": True}
    assert box.acked == ["e1"] and box.ticks == [True]
    assert played == [("T1", "c1", 9), ("T2", "c2", 9)]
    sync.tick()
    bodies = [c[2]["json"] for c in s.calls if c[1].endswith("shop/heartbeat")]
    assert not any("box_events" in b for b in bodies[2:])


def test_old_server_without_ack_keeps_events_waiting(tmp_path):
    from shopbox.device import DeviceClient, DeviceSync
    s = Session({"shop/heartbeat": Resp(200, {"config_version": ""})})
    box = FakeBox([{"id": "e1", "kind": "power_back", "from": 1.0, "to": 2.0}])
    sync = DeviceSync(DeviceClient(BASE, session=s), lambda: {"": "SITE"}, [],
                      lambda *a: None, box=box)
    sync.tick()
    assert box.acked == [] and box.events
    s2 = Session({"shop/heartbeat": Resp(0, {})})
    sync2 = DeviceSync(DeviceClient(BASE, session=s2), lambda: {"": "SITE"}, [],
                       lambda *a: None, box=box)
    sync2.tick()
    assert box.ticks[-1] is False                  # offline round reported to the watch


# ------------------------------------------------------------ speaker
def _wav(seconds=0.5):
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(b"\x00\x00" * int(8000 * seconds))
    return out.getvalue()


def test_clean_task_bounds_and_only_server_paths():
    from shopbox.speaker import clean_task
    assert clean_task({"id": 1, "sound": "warn", "seconds": 999,
                       "warn_url": "/api/v1/shop/device/warn-clip"}) == {
        "id": 1, "sound": "warn", "seconds": 60, "warn_url": "/api/v1/shop/device/warn-clip"}
    assert clean_task({"id": 2, "request": {"sound": "boom", "seconds": 1,
                                            "warn_url": "https://evil.example/x"}}) == {
        "id": 2, "sound": "siren", "seconds": 3, "warn_url": ""}
    assert clean_task({"id": 3, "warn_url": "/api/v1/shop/device/../../admin"})["warn_url"] == ""
    assert clean_task({"sound": "siren"}) is None


def test_siren_is_valid_wav():
    from shopbox.speaker import siren_wav, wav_seconds
    w = siren_wav(1.0)
    assert w[:4] == b"RIFF" and abs(wav_seconds(w) - 1.0) < 0.01


def _speaker(fetch, played):
    from shopbox.speaker import Speaker
    clock = Clock(0)

    def play_file(player, path, secs):
        with open(path, "rb") as f:
            played.append(f.read()[:4])
        clock.t += secs
        return True
    return Speaker(fetch, player=["aplay", "-q"], play_file=play_file, clock=clock)


def test_warning_clip_plays_for_the_asked_time_then_temp_file_is_gone(tmp_path):
    played = []
    sp = _speaker(lambda path: _wav(2.0), played)
    r = sp.play({"id": 5, "sound": "warn", "seconds": 7,
                 "warn_url": "/api/v1/shop/device/warn-clip"})
    assert r == {"ok": True, "code": "ok", "played": "warn", "seconds": 7}
    assert len(played) == 4                        # 2 s clip repeated to cover 7 s
    assert sp.play({"id": 5, "sound": "warn"})["code"] == "duplicate"


def test_warning_falls_back_to_siren_honestly():
    played = []
    sp = _speaker(lambda path: None, played)
    r = sp.play({"id": 6, "sound": "warn", "seconds": 3,
                 "warn_url": "/api/v1/shop/device/warn-clip"})
    assert r["played"] == "siren" and r["fallback"] == "clip_unavailable"
    r = _speaker(lambda path: b"not audio", []).play(
        {"id": 7, "sound": "warn", "seconds": 3, "warn_url": "/api/v1/shop/device/warn-clip"})
    assert r["played"] == "siren" and r["fallback"] in ("clip_unplayable",)


def test_no_player_is_reported_not_faked():
    from shopbox.speaker import Speaker
    sp = Speaker(lambda p: None, player=[])
    sp.player = None
    assert sp.play({"id": 1, "sound": "siren"})["code"] == "no_player"


def test_gateway_play_task_uses_the_speaker(tmp_path):
    from shopbox.device import DeviceClient
    from shopbox.secure_store import SITE_TOKEN, SecretStore, _FernetCipher
    from shopbox.tasks import GatewayTasks
    store = SecretStore(str(tmp_path / "s"), cipher=_FernetCipher(str(tmp_path / "k")))
    store.set(SITE_TOKEN, "SITE")
    s = Session({"shop/gateway/tasks": Resp(200, {"tasks": [
        {"id": 31, "action": "play", "camera_id": 4,
         "request": {"sound": "siren", "seconds": 4}}]}),
        "shop/gateway/tasks/31/result": Resp(200, {"ok": True})})

    class Spk:
        calls = []

        def play(self, t):
            self.calls.append(t)
            return {"ok": True, "code": "ok", "played": "siren", "seconds": 4}
    spk = Spk()
    gt = GatewayTasks(DeviceClient(BASE, session=s), lambda: store.get(SITE_TOKEN), store,
                      speaker=spk, threaded=False, sleep=lambda s: None)
    assert gt.poll() == 1
    assert spk.calls[0]["id"] == 31 and spk.calls[0]["request"]["seconds"] == 4
    post = [c for c in s.calls if c[1].endswith("/result")][0]
    assert json.loads(post[2]["files"]["result"][1])["played"] == "siren"


# ------------------------------------------------------------ 2 GB Pi profile
def test_sub_stream_rewrites():
    from shopbox.vendors import sub_stream_url
    assert sub_stream_url("rtsp://h:554/Streaming/Channels/101") == \
        "rtsp://h:554/Streaming/Channels/102"
    assert sub_stream_url("rtsp://h/Streaming/Channels/1001") == \
        "rtsp://h/Streaming/Channels/1002"
    assert sub_stream_url("rtsp://h/cam/realmonitor?channel=3&subtype=0") == \
        "rtsp://h/cam/realmonitor?channel=3&subtype=1"
    assert sub_stream_url("rtsp://h:554/stream1") == "rtsp://h:554/stream2"
    assert sub_stream_url("rtsp://127.0.0.1:18554/cam1") == "rtsp://127.0.0.1:18554/cam1"


def test_profile_lite_on_pi_and_small_ram(monkeypatch):
    from shopbox import resprofile
    from shopbox.config import AppConfig
    monkeypatch.delenv("SHOPBOX_PROFILE", raising=False)
    assert resprofile.choose(mem_mb=1900, arch="arm64") == "lite"
    assert resprofile.choose(mem_mb=8000, arch="arm64") == "lite"
    assert resprofile.choose(mem_mb=3000, arch="x64") == "lite"
    assert resprofile.choose(mem_mb=8000, arch="x64") == "full"
    monkeypatch.setenv("SHOPBOX_PROFILE", "full")
    assert resprofile.choose(mem_mb=1900, arch="arm64") == "full"
    cfg = AppConfig()
    assert resprofile.apply(cfg, "lite") == "lite"
    d = cfg.detection
    assert (d.sample_fps, d.frame_width, d.detector_threads, d.prefer_substream,
            d.low_memory) == (1.5, 512, 1, True, True)
    cfg2 = AppConfig()
    resprofile.apply(cfg2, "full")
    assert cfg2.detection.prefer_substream is False


def _engine(tmp_path, cams):
    from shopbox.config import AppConfig
    from shopbox.engine import Engine, EventLog
    from shopbox.person import NullDetector
    from shopbox.secure_store import SecretStore, _FernetCipher
    cfg = AppConfig()
    cfg.cameras = cams
    store = SecretStore(str(tmp_path / "s"), cipher=_FernetCipher(str(tmp_path / "k")))
    return Engine(cfg, store, detector=NullDetector(),
                  events=EventLog(str(tmp_path / "ev.jsonl"))), cfg, store


def test_engine_substream_falls_back_to_main_when_it_never_works(tmp_path):
    from shopbox.config import CameraConfig
    cam = CameraConfig(id="c1", name="Gate", rtsp_url="rtsp://10.0.0.5/Streaming/Channels/101")
    eng, cfg, _ = _engine(tmp_path, [cam])
    cfg.detection.prefer_substream = True
    urls = [eng.rtsp_url_for("c1") for _ in range(5)]
    assert urls[:3] == ["rtsp://10.0.0.5/Streaming/Channels/102"] * 3
    assert urls[3:] == ["rtsp://10.0.0.5/Streaming/Channels/101"] * 2


def test_guard_camera_uses_phone_cooldowns_source_and_no_after_hours(tmp_path):
    from shopbox.analyzer import Trigger
    from shopbox.config import CameraConfig
    cam = CameraConfig(id="g1", name="Gate", rtsp_url="rtsp://x", guard=True)
    eng, cfg, _ = _engine(tmp_path, [cam])
    assert cfg.hours_for(cam).open == cfg.hours_for(cam).close     # after-hours rule off
    frame = np.full((360, 640, 3), 90, np.uint8)
    t0 = 1_800_000_000.0
    trig = Trigger("person_detected", {"detector": "yolox_nano", "conf": 0.8}, frame, t0)
    assert eng.handle_trigger("g1", trig) is True
    assert eng.handle_trigger("g1", trig) is False
    eng.cooldown._last[("g1", "person_detected")] -= 61            # the phone's 60 s
    assert eng.handle_trigger("g1", trig) is True
    _, rec, _snap = eng.outbox.peek()
    assert rec["event"]["signals"]["source"].startswith("guard_box_")


def test_camera_health_reports_lost_camera(tmp_path, monkeypatch):
    import time as _t
    from shopbox.config import CameraConfig
    cam = CameraConfig(id="g1", name="Gate", rtsp_url="rtsp://x", guard=True)
    other = CameraConfig(id="o1", name="Till", rtsp_url="rtsp://y")
    eng, _cfg, _ = _engine(tmp_path, [cam, other])
    assert eng.camera_health("g1") is None                         # not running
    eng.running = True
    eng.started_at = _t.time() - 30
    assert eng.camera_health("g1") == {"box_cam_lost": False}
    eng.started_at = _t.time() - 500
    assert eng.camera_health("g1") == {"box_cam_lost": True}
    assert eng.camera_health("o1") is None                         # site-token camera


# ------------------------------------------------------------ pairing
class ClaimSession:
    def __init__(self, status, data):
        self.status, self.data, self.calls = status, data, []

    def post(self, url, **kw):
        self.calls.append((url, kw))
        return Resp(self.status, self.data)


def test_pair_by_code_stores_camera_token_encrypted(tmp_path):
    from shopbox import pairing
    from shopbox.config import AppConfig
    from shopbox.secure_store import SecretStore, _FernetCipher, cam_key
    cfg = AppConfig()
    store = SecretStore(str(tmp_path / "s"), cipher=_FernetCipher(str(tmp_path / "k")))
    cam = pairing.add_camera(cfg, store, "Gate",
                             "rtsp://admin:S3cret!@192.168.1.64:554/Streaming/Channels/101")
    assert cam.rtsp_url == "rtsp://192.168.1.64:554/Streaming/Channels/101"
    assert store.get(cam_key(cam.id, "pass")) == "S3cret!"
    assert cam.source == {"vendor": "hikvision", "host": "192.168.1.64", "port": 554,
                          "channel": 1}
    s = ClaimSession(201, {"ok": True, "camera_token": "CAMTOK",
                           "camera": {"id": 77, "name": "Gate"},
                           "site": {"id": 3, "name": "Sample Shop"}})
    assert pairing.pair_camera(cfg, store, cam, " https://lifeassisto.com/pc/12-ab3cd ",
                               session=s) == "ok"
    url, kw = s.calls[0]
    assert url.endswith("shop/phonecam/claim")
    assert kw["json"]["code"] == "https://lifeassisto.com/pc/12-ab3cd"
    assert kw["json"]["platform"]
    assert "S3cret" not in json.dumps(kw["json"])                  # password never sent
    assert store.get(cam_key(cam.id, "token")) == "CAMTOK"
    assert cam.guard is True and cam.server_id == 77 and cfg.site_name == "Sample Shop"
    with open(str(tmp_path / "cfg.json"), "w") as f:
        json.dump(cfg.to_dict(), f)
    assert "S3cret" not in open(str(tmp_path / "cfg.json")).read()


@pytest.mark.parametrize("status,data,want", [
    (400, {"code": "bad_code"}, "bad_code"), (409, {"code": "code_used"}, "code_used"),
    (402, {"code": "camera_cap"}, "camera_cap"), (429, {}, "rate_limited"),
    (403, {"code": "feature_off"}, "feature_off"), (502, {}, "offline")])
def test_pair_errors_are_plain_messages(status, data, want, tmp_path):
    from shopbox import pairing
    out, _ = pairing.claim("https://x.example/api/v1/", "12-AB", "Gate",
                           session=ClaimSession(status, data))
    assert out == want
    assert pairing.message(out, "bn") and pairing.message(out, "en")


def test_claim_refuses_plain_http_to_the_internet():
    from shopbox import pairing
    with pytest.raises(ValueError):
        pairing.claim("http://api.example.com/api/v1/", "1-A", "x")


# ------------------------------------------------------------ DVR health
def test_dvr_health_one_report_per_recorder_without_passwords(tmp_path):
    from shopbox.config import AppConfig, CameraConfig
    from shopbox.dvrhealth import DvrHealth, recorders
    cfg = AppConfig()
    a = CameraConfig(id="a", name="A", rtsp_url="rtsp://x", server_id=1,
                     source={"vendor": "hikvision", "host": "192.168.1.64"})
    b = CameraConfig(id="b", name="B", rtsp_url="rtsp://x", server_id=2,
                     source={"vendor": "hikvision", "host": "192.168.1.64", "channel": 2})
    c = CameraConfig(id="c", name="C", rtsp_url="rtsp://x",
                     source={"vendor": "tapo", "host": "192.168.1.70"})
    cfg.cameras = [a, b, c]
    creds = lambda cam: ("admin", "PW-%s" % cam.id)
    recs = recorders(cfg, creds)
    assert [(r["vendor"], r["host"], r["cameras"]) for r in recs] == [
        ("hikvision", "192.168.1.64", [1, 2])]
    probed, posted = [], []
    dh = DvrHealth(cfg, creds, "https://api.lifeassisto.com/api/v1/", lambda: "TOK",
                   probe=lambda *a: probed.append(a) or {"source": "isapi", "device": "D1",
                                                       "disks": [{"state": "ok"}],
                                                       "password": "leak"},
                   post=lambda url, body, h: posted.append((url, body, h)) or 200)
    assert dh.run_once()["posted_status"] == 200
    url, body, headers = posted[0]
    assert url.endswith("shop/gateway/dvr-health") and headers == {"X-Shop-Token": "TOK"}
    assert "PW-a" not in json.dumps(body) and "leak" not in json.dumps(body)
    assert body["reports"][0]["device"] == "D1"


def test_dvr_health_says_off_without_camlink():
    from shopbox.config import AppConfig
    from shopbox.dvrhealth import DvrHealth
    dh = DvrHealth(AppConfig(), lambda c: (None, None), "https://x/api/v1/", lambda: None,
                   probe=None)
    dh.probe = None
    assert dh.available is False


def test_profile_is_never_saved_to_config_json():
    from shopbox import resprofile
    from shopbox.config import AppConfig
    cfg = AppConfig()
    resprofile.apply(cfg, "lite")
    assert cfg.detection.sample_fps == 1.5
    d = cfg.to_dict()
    assert d["detection"]["sample_fps"] == AppConfig().detection.sample_fps
    assert d["detection"]["prefer_substream"] is False
