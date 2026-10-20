from conftest import FakeClock
from shopbox.cooldown import Cooldown, RateBudget


def test_cooldown_per_key():
    c = FakeClock()
    cd = Cooldown(180, clock=c)
    assert cd.allow(("c1", "motion"))
    assert not cd.allow(("c1", "motion"))
    assert cd.allow(("c1", "after_hours"))   # different type: independent
    assert cd.allow(("c2", "motion"))        # different camera: independent
    c.advance(179)
    assert not cd.allow(("c1", "motion"))
    assert cd.remaining(("c1", "motion")) == 1
    c.advance(1)
    assert cd.allow(("c1", "motion"))


def test_rate_budget_sliding_window():
    c = FakeClock()
    rb = RateBudget(3, 60, clock=c)
    assert all(rb.try_acquire() for _ in range(3))
    assert not rb.try_acquire()
    assert rb.wait_time() == 60
    c.advance(30)
    assert not rb.try_acquire() and rb.wait_time() == 30
    c.advance(30)
    assert rb.try_acquire()
