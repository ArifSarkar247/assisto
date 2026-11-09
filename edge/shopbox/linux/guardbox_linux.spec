# -*- mode: python ; coding: utf-8 -*-
# gboxlinux — PyInstaller spec for the Linux Guard Box (amd64 + arm64): ONE
# console program `assisto-guardbox` (headless: --run / --setup / --status),
# Python + numpy + OpenCV + onnxruntime (CPU) + the person model + PyAV/aiortc
# (live view, warning clips) all inside, so it runs on any glibc >= 2.31
# distro (Debian 11+, Ubuntu 20.04+, Raspberry Pi OS bullseye+) without pip.
# Build (inside python:3.11-slim-bullseye, see build_linux.sh):
#   pyinstaller --noconfirm --clean linux/guardbox_linux.spec
import os

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs

here = os.path.dirname(SPECPATH)  # noqa: F821 (edge/shopbox)
datas = collect_data_files("tzdata")
datas.append((os.path.join(here, "shopbox", "guard_thresholds.json"), "shopbox"))
model = os.path.join(here, "models", "yolox_nano.onnx")
if not os.path.exists(model):
    raise SystemExit("models/yolox_nano.onnx missing — run: python -m shopbox.model_fetch models/yolox_nano.onnx")
datas.append((model, "models"))

try:
    import aiortc  # noqa: F401
    from PyInstaller.utils.hooks import collect_submodules
    live_hidden = (collect_submodules("aiortc") + collect_submodules("aioice")
                   + ["av", "pylibsrtp", "google_crc32c", "pyee", "OpenSSL"])
    live_bins = collect_dynamic_libs("av") + collect_dynamic_libs("aiortc")
except ImportError:
    live_hidden, live_bins = [], []

a = Analysis(  # noqa: F821
    [os.path.join(here, "run_shopbox.py")],
    pathex=[here],
    binaries=collect_dynamic_libs("onnxruntime") + live_bins,
    datas=datas,
    hiddenimports=live_hidden,
    excludes=["tkinter", "matplotlib", "PIL", "pytest", "IPython"],
    noarchive=False,
)
pyz = PYZ(a.pure)  # noqa: F821
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="assisto-guardbox",  # noqa: F821
          console=True, upx=False, strip=False)
coll = COLLECT(exe, a.binaries, a.datas, name="assisto-guardbox", upx=False)  # noqa: F821
