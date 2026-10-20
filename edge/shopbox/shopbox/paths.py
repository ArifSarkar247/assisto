"""Per-user config/data locations (no admin rights needed).

Windows: %APPDATA%\\AssistoShopBox
Linux:   $XDG_CONFIG_HOME/assisto-shopbox (default ~/.config/assisto-shopbox)
macOS:   ~/Library/Application Support/AssistoShopBox
`SHOPBOX_HOME` overrides everything (used by tests and portable installs).
"""
from __future__ import annotations

import os
import sys


def data_dir() -> str:
    override = os.environ.get("SHOPBOX_HOME")
    if override:
        base = override
    elif sys.platform == "win32":
        base = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"),
                            "AssistoShopBox")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support/AssistoShopBox")
    else:
        xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        base = os.path.join(xdg, "assisto-shopbox")
    os.makedirs(base, exist_ok=True)
    if sys.platform != "win32":
        try:
            os.chmod(base, 0o700)   # config + secrets live here: owner only
        except OSError:
            pass
    return base


def path(*parts: str) -> str:
    return os.path.join(data_dir(), *parts)
