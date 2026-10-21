# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec: ONE onedir bundle with two executables sharing the same
# libraries:
#   AssistoShopBox.exe     windowed — the config UI, and `--run` (headless)
#   AssistoShopBoxCLI.exe  console  — --pair / --verify / --list / --self-test
# Build:  pyinstaller --noconfirm --clean AssistoShopBox.spec
import os

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs

here = SPECPATH  # noqa: F821 (provided by PyInstaller)
datas = collect_data_files("tzdata")
model = os.path.join(here, "models", "yolox_nano.onnx")
if os.path.exists(model):
    datas.append((model, "models"))
elif os.environ.get("SHOPBOX_REQUIRE_MODEL") == "1":
    raise SystemExit("models/yolox_nano.onnx missing — run: python -m shopbox.model_fetch models/yolox_nano.onnx")

# OPTIONAL live view (requirements-live.txt): bundle aiortc + PyAV when they
# are installed in the build env; otherwise the exe simply has no live view.
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
    hiddenimports=["tkinter", "tkinter.ttk"] + live_hidden,
    excludes=["matplotlib", "PIL", "pytest", "IPython"],
    noarchive=False,
)
pyz = PYZ(a.pure)  # noqa: F821

gui = EXE(pyz, a.scripts, [], exclude_binaries=True, name="AssistoShopBox",  # noqa: F821
          console=False, upx=False)
cli = EXE(pyz, a.scripts, [], exclude_binaries=True, name="AssistoShopBoxCLI",  # noqa: F821
          console=True, upx=False)
coll = COLLECT(gui, cli, a.binaries, a.datas, name="AssistoShopBox", upx=False)  # noqa: F821
