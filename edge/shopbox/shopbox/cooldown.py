"""Local anti-spam: per-(camera, type) cooldown + a global send budget.

The server also rate-limits (ShopIngestView: 10 raised events per site+type per
2 s, and DRF's anonymous throttle of 30 requests/min per IP applies to this
token-authenticated, login-less endpoint). We stay far below both so a busy
camera can never get the shop's IP throttled.
"""
from __future__ import annotations

import threading
import time
from collections import deque
from typing import Callable, Dict, Hashable, Optional


class Cooldown:
    """Allow one event per key per `seconds`. Thread-safe."""

    def __init__(self, seconds: float, clock: Callable[[], float] = time.monotonic):
        self.seconds = float(seconds)
        self._clock = clock
        self._last: Dict[Hashable, float] = {}
        self._lock = threading.Lock()

    def allow(self, key: Hashable) -> bool:
        """True (and start the cooldown) if `key` is not cooling down."""
        now = self._clock()
        with self._lock:
            last = self._last.get(key)
            if last is not None and now - last < self.seconds:
                return False
            self._last[key] = now
            return True

    def remaining(self, key: Hashable) -> float:
        with self._lock:
            last = self._last.get(key)
        if last is None:
            return 0.0
        return max(0.0, self.seconds - (self._clock() - last))


class RateBudget:
    """Sliding-window limit: at most `max_events` per `window_s` seconds."""

    def __init__(self, max_events: int, window_s: float = 60.0,
                 clock: Callable[[], float] = time.monotonic):
        self.max_events = int(max_events)
        self.window_s = float(window_s)
        self._clock = clock
        self._stamps: deque = deque()
        self._lock = threading.Lock()

    def _trim(self, now: float) -> None:
        while self._stamps and now - self._stamps[0] >= self.window_s:
            self._stamps.popleft()

    def try_acquire(self) -> bool:
        now = self._clock()
        with self._lock:
            self._trim(now)
            if len(self._stamps) >= self.max_events:
                return False
            self._stamps.append(now)
            return True

    def wait_time(self) -> Optional[float]:
        """Seconds until a slot frees up (0 if one is free now)."""
        now = self._clock()
        with self._lock:
            self._trim(now)
            if len(self._stamps) < self.max_events:
                return 0.0
            return max(0.0, self.window_s - (now - self._stamps[0]))
