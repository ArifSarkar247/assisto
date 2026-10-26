"""Shop opening hours, evaluated in the shop's LOCAL timezone.

Hours are "HH:MM" strings. `close` earlier than `open` means the shop is open
across midnight (e.g. 18:00 -> 02:00). `open == close` means "open all day":
after-hours detection is then off. `closed_days` lists weekdays (Mon=0..Sun=6)
on which the shop is closed for the whole day (e.g. [4] for Friday).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, time
from typing import List, Optional

DEFAULT_TZ = "Asia/Dhaka"


def parse_hhmm(s: str) -> time:
    hh, mm = str(s).strip().split(":")
    h, m = int(hh), int(mm)
    if not (0 <= h <= 23 and 0 <= m <= 59):
        raise ValueError("bad time %r" % s)
    return time(h, m)


def get_tz(name: Optional[str]):
    """ZoneInfo for `name`; falls back to the PC's local zone if unknown.
    (On Windows the IANA database comes from the bundled `tzdata` package.)"""
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name or DEFAULT_TZ)
    except Exception:
        return datetime.now().astimezone().tzinfo


@dataclass
class Hours:
    open: str = "09:00"
    close: str = "22:00"
    timezone: str = DEFAULT_TZ
    closed_days: List[int] = field(default_factory=list)

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> "Hours":
        d = d or {}
        h = cls(open=str(d.get("open", "09:00")), close=str(d.get("close", "22:00")),
                timezone=str(d.get("timezone", DEFAULT_TZ)),
                closed_days=[int(x) for x in d.get("closed_days", []) or []
                             if str(x).lstrip("-").isdigit() and 0 <= int(x) <= 6])
        parse_hhmm(h.open)    # validate early: a typo must not silently
        parse_hhmm(h.close)   # disable after-hours detection
        return h

    def to_dict(self) -> dict:
        return {"open": self.open, "close": self.close,
                "timezone": self.timezone, "closed_days": list(self.closed_days)}

    def is_open(self, when: Optional[datetime] = None) -> bool:
        """True when the shop is open at `when` (aware datetime; default now)."""
        tz = get_tz(self.timezone)
        local = (when or datetime.now(tz=tz)).astimezone(tz)
        o, c = parse_hhmm(self.open), parse_hhmm(self.close)
        t = local.time().replace(second=0, microsecond=0)
        if o == c:
            return local.weekday() not in self.closed_days
        if o < c:
            return local.weekday() not in self.closed_days and o <= t < c
        # overnight: open from `o` until midnight, and from midnight until `c`
        # (the after-midnight part belongs to the PREVIOUS day's opening).
        if t >= o:
            return local.weekday() not in self.closed_days
        if t < c:
            return (local.weekday() - 1) % 7 not in self.closed_days
        return False

    def is_after_hours(self, when: Optional[datetime] = None) -> bool:
        return not self.is_open(when)


@dataclass
class Schedule:
    """The owner's ARMED schedule for one camera (zones v2): weekdays
    (Mon=0..Sun=6) and a daily window. `end` earlier than `start` is an
    overnight window (22:00 -> 06:00): the after-midnight part belongs to the
    PREVIOUS day, so days=[4] with 22:00-06:00 arms Fri 22:00 -> Sat 06:00.
    `start == end` arms the listed days all day."""
    days: List[int] = field(default_factory=lambda: list(range(7)))
    start: str = "00:00"
    end: str = "00:00"

    @classmethod
    def from_dict(cls, d) -> Optional["Schedule"]:
        """None (= always armed) for a missing/invalid schedule."""
        if not isinstance(d, dict):
            return None
        try:
            days = sorted({int(x) for x in (d.get("days") or [])
                           if str(x).lstrip("-").isdigit() and 0 <= int(x) <= 6})
            s = cls(days=days, start=str(d.get("start") or "00:00"),
                    end=str(d.get("end") or "00:00"))
            parse_hhmm(s.start)
            parse_hhmm(s.end)
        except (TypeError, ValueError):
            return None
        return s

    def to_dict(self) -> dict:
        return {"days": list(self.days), "start": self.start, "end": self.end}

    def is_armed(self, when: Optional[datetime] = None,
                 tz_name: Optional[str] = None) -> bool:
        tz = get_tz(tz_name)
        local = (when or datetime.now(tz=tz)).astimezone(tz)
        s, e = parse_hhmm(self.start), parse_hhmm(self.end)
        t = local.time().replace(second=0, microsecond=0)
        wd = local.weekday()
        if s == e:
            return wd in self.days
        if s < e:
            return wd in self.days and s <= t < e
        if t >= s:
            return wd in self.days
        if t < e:
            return (wd - 1) % 7 in self.days
        return False
