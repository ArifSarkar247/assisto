from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from shopbox.hours import Hours

DHAKA = ZoneInfo("Asia/Dhaka")


def at(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=DHAKA)


def test_daytime_hours():
    h = Hours(open="09:00", close="22:00")
    assert h.is_open(at(2026, 10, 19, 9, 0))         # Monday
    assert h.is_open(at(2026, 10, 19, 21, 59))
    assert h.is_after_hours(at(2026, 10, 19, 22, 0))
    assert h.is_after_hours(at(2026, 10, 19, 3, 0))


def test_evaluated_in_shop_timezone_not_utc():
    h = Hours(open="09:00", close="22:00", timezone="Asia/Dhaka")
    utc_0330 = datetime(2026, 10, 19, 3, 30, tzinfo=ZoneInfo("UTC"))  # 09:30 Dhaka
    assert h.is_open(utc_0330)


def test_overnight_hours_and_closed_day():
    h = Hours(open="18:00", close="02:00", closed_days=[4])   # closed Friday
    assert h.is_open(at(2026, 10, 19, 23, 0))         # Mon night
    assert h.is_open(at(2026, 10, 20, 1, 30))         # Tue 01:30 belongs to Mon
    assert h.is_after_hours(at(2026, 10, 20, 2, 30))
    assert h.is_after_hours(at(2026, 10, 23, 20, 0))  # Friday: closed all day
    assert h.is_after_hours(at(2026, 10, 24, 1, 0))   # Sat 01:00 = Friday's night
    assert h.is_open(at(2026, 10, 24, 19, 0))         # Saturday evening


def test_open_equals_close_means_always_open():
    assert Hours(open="00:00", close="00:00").is_open(at(2026, 10, 19, 3, 0))


def test_bad_times_rejected():
    with pytest.raises(ValueError):
        Hours.from_dict({"open": "25:00", "close": "22:00"})
