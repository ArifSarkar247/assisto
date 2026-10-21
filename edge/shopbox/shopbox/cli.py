"""Command line entry point.

  AssistoShopBox.exe                 open the config UI (default)
  AssistoShopBox.exe --run           headless monitoring (for auto-start)
  AssistoShopBox.exe --pair          prompt for the enrollment token (hidden)
  AssistoShopBox.exe --verify        check the stored token with the server
  AssistoShopBox.exe --list          list configured cameras (no secrets)
  AssistoShopBox.exe --test-camera ID   try to grab one frame
  AssistoShopBox.exe --fetch-model   download + verify the person model
  AssistoShopBox.exe --self-test     load the detector, run it once (used by CI)

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


def run_headless(cfg, store) -> int:
    from .engine import Engine

    eng = Engine(cfg, store)
    try:
        eng.start()
    except RuntimeError as exc:
        log.error("cannot start: %s", exc)
        return 2
    done = threading.Event()

    def _stop(*_):
        done.set()

    signal.signal(signal.SIGINT, _stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _stop)
    while not done.wait(60):
        st = eng.status()
        log.info("status: cameras=%s queued=%s online=%s detector=%s",
                 st["cameras"], st["queued"], st["online"], st["detector"])
    eng.stop()
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

    needs_store = a.run or a.pair or a.verify or a.test_camera
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
        return run_headless(cfg, store)

    from .ui import launch
    return launch(cfg, cstore)


if __name__ == "__main__":
    sys.exit(main())
