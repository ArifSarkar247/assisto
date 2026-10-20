"""Shared test setup: import the package from the source tree and keep every
file the client writes inside a per-test temp dir (SHOPBOX_HOME)."""
import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


@pytest.fixture(autouse=True)
def shopbox_home(tmp_path, monkeypatch):
    monkeypatch.setenv("SHOPBOX_HOME", str(tmp_path / "home"))
    return tmp_path / "home"


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = float(t)

    def __call__(self):
        return self.t

    def advance(self, s):
        self.t += s


@pytest.fixture
def clock():
    return FakeClock()


def blank_frame(w=640, h=360, value=60):
    return np.full((h, w, 3), value, dtype=np.uint8)


def frame_with_square(x, y, size=80, w=640, h=360, bg=60, fg=230):
    f = blank_frame(w, h, bg)
    f[y:y + size, x:x + size] = fg
    return f
