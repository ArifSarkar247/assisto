"""Trigger decision — threshold + patience + cooldown. This is the SAME logic
as OwwEngine.kt (WakeDecider) and app/lib/voice/va_wake_logic.dart; keep the
three in sync (tests in each language pin the same cases)."""
from __future__ import annotations

from dataclasses import dataclass

FRAME_MS = 80
LEVELS = ("low", "normal", "high")
# "low" sensitivity = fewer false wakes (higher threshold, 2 frames in a row)
PATIENCE = {"low": 2, "normal": 1, "high": 1}
COOLDOWN_MS = 2000


@dataclass
class Decider:
    threshold: float
    patience: int = 1
    cooldown_ms: int = COOLDOWN_MS
    _run: int = 0
    _last: int = -10 ** 12
    _t: int = 0

    @staticmethod
    def for_level(level: str, thresholds: dict) -> "Decider":
        lv = level if level in LEVELS else "normal"
        return Decider(threshold=float(thresholds[lv]), patience=PATIENCE[lv])

    def reset(self):
        self._run, self._last, self._t = 0, -10 ** 12, 0

    def feed(self, score: float, now_ms: int | None = None) -> bool:
        """One classifier score per 80 ms frame. True = wake word heard."""
        self._t = now_ms if now_ms is not None else self._t + FRAME_MS
        if score >= self.threshold:
            self._run += 1
        else:
            self._run = 0
        if self._run >= self.patience and self._t - self._last >= self.cooldown_ms:
            self._last = self._t
            self._run = 0
            return True
        return False


def count_triggers(scores, decider: Decider) -> int:
    decider.reset()
    return sum(1 for s in scores if decider.feed(float(s)))
