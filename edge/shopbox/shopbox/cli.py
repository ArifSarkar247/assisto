"""Command line entry point.

  AssistoShopBox.exe                 open the config UI (default)
  AssistoShopBox.exe --run           headless monitoring (for auto-start)
  AssistoShopBox.exe --pair          prompt for the enrollment token (hidden)
  AssistoShopBox.exe --verify        check the stored token with the server
  AssistoShopBox.exe --list          list configured cameras (no secrets)
  AssistoShopBox.exe --test-camera ID   try to grab one frame
  AssistoShopBox.exe --fetch-model   download + verify the person model
  AssistoShopBox.exe --self-test     load the detector, run it once (used by CI)

Guard Box on Linux / Raspberry Pi (gboxlinux; the .deb wraps these as
`assisto-guardbox setup|status|pair CODE|...`, run as the service user):
  --setup                          guided setup (cameras + pairing code)
  --add-camera NAME --rtsp URL     add a camera (password: SHOPBOX_RTSP_PASSWORD
                                   or inside the URL; stored encrypted)
  --pair-code CODE [--camera ID]   pair a camera with the owner's app code
  --status                         what the running service last reported

The release ships two executables built from the same code:
AssistoShopBox.exe (windowed: UI and --run) and AssistoShopBoxCLI.exe
(console: for --pair / --verify / --list / --test-camera / --self-test).
"""
from __future__ import annotations

import argparse
import getpass
import logging
import os
import signal
import sys
import threading

from . import APP_NAME, __version__, paths
from .config import ConfigStore

log = logging.getLogger(__name__)


def pair_token(cfg, store, token: str) -> str:
    """Verify then store the enrollment token (encrypted).
    Returns "ok", "bad" (server said 401: not stored) or "offline" (stored,
    to be verified later)."""
    from .client import SENT, UNAUTHORIZED, IngestClient
    from .secure_store import SITE_TOKEN

    token = (token or "").strip()
    if not token:
        return "bad"
    from .device import DeviceClient
    try:
        verdict, site_name = DeviceClient(
            cfg.base_url, timeout=cfg.sending.timeout_s).pair_check(token)
    except Exception:
        verdict, site_name = "unsupported", ""
    if verdict == "bad":
        return "bad"
    if verdict == "ok":
        store.set(SITE_TOKEN, token)
        if site_name and not cfg.site_name:
            cfg.site_name = site_name[:120]
        return "ok"
    if verdict == "unsupported":
        # older server without shop/pair/check: the ingest-probe fallback
        res = IngestClient(cfg.base_url, timeout=cfg.sending.timeout_s).verify_pairing(token)
        if res.outcome == UNAUTHORIZED:
            return "bad"
        store.set(SITE_TOKEN, token)
        return "ok" if res.outcome == SENT else "offline"
    store.set(SITE_TOKEN, token)
    return "offline"


STATUS_FILE = "status.json"
WATCHDOG_S = 20.0


def write_status(eng) -> None:
    """status.json for `assisto-guardbox status` (no secrets, no images)."""
    import json
    import time as _t
    try:
        st = eng.status()
        st["at"] = _t.time()
        st["version"] = __version__
        st["cameras_named"] = {c.id: {"name": c.name, "paired": bool(c.guard),
                                      "enabled": c.enabled} for c in eng.cfg.cameras}
        tmp = paths.path(STATUS_FILE + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f, ensure_ascii=False, default=str)
        os.replace(tmp, paths.path(STATUS_FILE))
    except Exception:
        log.debug("status file not written", exc_info=True)


def _has_tokens(cfg, store) -> bool:
    from .secure_store import SITE_TOKEN, cam_key
    return bool(store.get(SITE_TOKEN) or any(
        store.get(cam_key(c.id, "token")) for c in cfg.cameras))


def _install_stop(done) -> None:
    def _stop(*_):
        done.set()
    signal.signal(signal.SIGINT, _stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _stop)


def run_headless(cfg, store, cstore=None) -> int:
    from . import resprofile, sysinfo
    from .engine import Engine

    done = threading.Event()
    if cstore is not None and not _has_tokens(cfg, store):
        # a fresh box: stay up (no systemd restart loop) until the owner
        # runs `assisto-guardbox setup`, then start by itself
        sysinfo.sd_notify("READY=1\nSTATUS=not paired - run: sudo assisto-guardbox setup")
        log.info("not paired yet - waiting for: sudo assisto-guardbox setup")
        _install_stop(done)
        while not done.wait(WATCHDOG_S):
            sysinfo.sd_notify("WATCHDOG=1")
            from .secure_store import SecretStore
            cfg, store = cstore.load(), SecretStore()
            if _has_tokens(cfg, store):
                break
        if done.is_set():
            return 0
    prof = resprofile.apply(cfg)
    eng = Engine(cfg, store, cfg_store=cstore)
    eng.profile = prof
    try:
        eng.start()
    except RuntimeError as exc:
        log.error("cannot start: %s", exc)
        sysinfo.sd_notify("STATUS=not paired - run: assisto-guardbox setup")
        return 2
    sysinfo.sd_notify("READY=1\nSTATUS=guarding")

    _install_stop(done)
    rounds = 0
    write_status(eng)
    while not done.wait(WATCHDOG_S):
        rounds += 1
        # systemd restarts the box when these pings stop (WatchdogSec)
        if eng.sender is None or eng.sender.is_alive():
            sysinfo.sd_notify("WATCHDOG=1")
        if rounds % 3 == 0:
            st = eng.status()
            write_status(eng)
            log.info("status: cameras=%s queued=%s online=%s detector=%s",
                     st["cameras"], st["queued"], st["online"], st["detector"])
    sysinfo.sd_notify("STOPPING=1")
    eng.stop()
    write_status(eng)
    return 0


def main(argv=None) -> int:
    from . import logutil

    # A windowed (no-console) build has no stdout/stderr; never crash on print.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w")

    p = argparse.ArgumentParser(prog=APP_NAME, description="Assisto Shop Box edge client")
    p.add_argument("--run", action="store_true", help="headless monitoring")
    p.add_argument("--pair", action="store_true", help="enter enrollment token")
    p.add_argument("--verify", action="store_true", help="check stored token")
    p.add_argument("--list", action="store_true", help="list cameras")
    p.add_argument("--test-camera", metavar="ID")
    p.add_argument("--fetch-model", action="store_true")
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--live-check", action="store_true",
                   help="exit 0 if the optional live view (aiortc) is available")
    p.add_argument("--base-url", help="override server base URL (saved)")
    p.add_argument("--setup", action="store_true", help="guided Guard Box setup")
    p.add_argument("--add-camera", metavar="NAME")
    p.add_argument("--rtsp", metavar="URL", help="with --add-camera")
    p.add_argument("--pair-code", metavar="CODE")
    p.add_argument("--camera", metavar="ID", help="with --pair-code")
    p.add_argument("--status", action="store_true")
    p.add_argument("--version", action="version", version=__version__)
    a = p.parse_args(argv)

    logutil.setup(paths.path("logs"))
    cstore = ConfigStore()
    cfg = cstore.load()
    if a.base_url:
        from .config import normalize_base_url
        cfg.base_url = normalize_base_url(a.base_url)
        cstore.save(cfg)

    if a.fetch_model:
        from .model_fetch import ensure_model
        path = ensure_model(allow_download=True)
        print(path or "model unavailable (motion_only mode)")
        return 0 if path else 1

    if a.self_test:
        import numpy as np
        from .person import load_detector
        det = load_detector()
        det.detect(np.full((360, 640, 3), 114, np.uint8))
        print("detector=%s" % det.name)
        return 0 if det.name != "motion_only" else 3

    if a.live_check:
        from . import live
        ok = live.available()
        print("live_view=%s" % ("available" if ok else "unavailable"))
        return 0 if ok else 4

    if a.status:
        import json
        try:
            with open(paths.path(STATUS_FILE), "r", encoding="utf-8") as f:
                print(json.dumps(json.load(f), ensure_ascii=False, indent=1))
            return 0
        except (OSError, ValueError):
            print("no status yet (is the service running?)")
            return 1

    needs_store = (a.run or a.pair or a.verify or a.test_camera or a.setup
                   or a.add_camera or a.pair_code)
    store = None
    if needs_store:
        from .secure_store import SecretStore
        store = SecretStore()

    if a.pair:
        tok = getpass.getpass("Enrollment token: ")
        r = pair_token(cfg, store, tok)
        print({"ok": "paired", "bad": "token rejected by server",
               "offline": "saved; server not reachable to verify"}[r])
        return 0 if r != "bad" else 1
    if a.verify:
        from .client import SENT, IngestClient
        from .secure_store import SITE_TOKEN
        tok = store.get(SITE_TOKEN)
        if not tok:
            print("not paired")
            return 1
        res = IngestClient(cfg.base_url).verify_pairing(tok)
        print("token ok" if res.outcome == SENT else "check failed: %s" % res.detail)
        return 0 if res.outcome == SENT else 1
    if a.setup:
        from . import setup_wizard
        return setup_wizard.run(cfg, store, lambda: cstore.save(cfg))
    if a.add_camera:
        from . import pairing
        if not a.rtsp:
            print("--rtsp URL is required")
            return 1
        try:
            cam = pairing.add_camera(cfg, store, a.add_camera, a.rtsp,
                                     password=os.environ.get("SHOPBOX_RTSP_PASSWORD") or None)
        except ValueError as exc:
            print(str(exc))
            return 1
        cstore.save(cfg)
        print("added %s" % cam.id)
        return 0
    if a.pair_code:
        from . import pairing
        cams = [c for c in cfg.cameras if (a.camera and c.id == a.camera)
                or (not a.camera and not c.guard)]
        if len(cams) != 1:
            print("name the camera with --camera ID (see --list)")
            return 1
        res = pairing.pair_camera(cfg, store, cams[0], a.pair_code)
        if res == "ok":
            cstore.save(cfg)
        print(pairing.message(res, cfg.language) + " / " + pairing.message(res, "en"))
        return 0 if res == "ok" else 1
    if a.list:
        for c in cfg.cameras:
            print("%s  %-20s  zone=%s  enabled=%s  %s" % (
                c.id, c.name, "yes" if c.zone else "no", c.enabled, c.rtsp_url))
        return 0
    if a.test_camera:
        from .camera import grab_one_frame
        from .engine import camera_url
        if not cfg.camera(a.test_camera):
            print("unknown camera id")
            return 1
        url = camera_url(cfg, store, a.test_camera)
        ok, _f, msg = grab_one_frame(url)
        print(("ok " if ok else "failed ") + msg)
        return 0 if ok else 1
    if a.run:
        return run_headless(cfg, store, cstore)

    try:
        from .ui import launch
    except Exception:
        # a headless Linux build has no tkinter: say what to do instead
        p.print_help()
        return 0
    return launch(cfg, cstore)


if __name__ == "__main__":
    sys.exit(main())
