import os

from conftest import FakeClock
from shopbox.outbox import Outbox


def ev(i):
    return {"type": "after_hours", "signals": {"after_hours": True},
            "camera_id": "c1", "at": float(i)}


def test_fifo_order_and_remove(tmp_path):
    q = Outbox(str(tmp_path / "q"))
    a = q.put(ev(1))
    q.put(ev(2), b"\xff\xd8img")
    item_id, rec, snap = q.peek()
    assert item_id == a and rec["event"]["at"] == 1.0 and snap is None
    q.remove(a)
    _, rec, snap = q.peek()
    assert rec["event"]["at"] == 2.0 and snap == b"\xff\xd8img"
    assert len(q) == 1


def test_bounded_by_item_count_drops_oldest(tmp_path):
    q = Outbox(str(tmp_path / "q"), max_items=5)
    for i in range(12):
        q.put(ev(i), b"x" * 10)
    assert len(q) == 5
    assert q.peek()[1]["event"]["at"] == 7.0
    assert q.dropped == 7
    # snapshots of dropped items are gone too
    assert len([n for n in os.listdir(tmp_path / "q") if n.endswith(".jpg")]) == 5


def test_bounded_by_bytes(tmp_path):
    q = Outbox(str(tmp_path / "q"), max_items=1000, max_bytes=50_000)
    for i in range(10):
        q.put(ev(i), b"x" * 20_000)
    assert q.total_bytes() <= 50_000
    assert len(q) == 2


def test_bounded_by_age(tmp_path):
    clock = FakeClock(10_000)
    q = Outbox(str(tmp_path / "q"), max_age_s=60, clock=clock)
    q.put(ev(1))
    clock.advance(30)
    q.put(ev(2))
    clock.advance(45)                 # first item is now 75 s old
    assert q.peek()[1]["event"]["at"] == 2.0
    assert len(q) == 1


def test_corrupt_item_is_skipped_not_blocking(tmp_path):
    q = Outbox(str(tmp_path / "q"))
    bad = q.put(ev(1))
    q.put(ev(2))
    with open(os.path.join(q.dir, bad + ".json"), "w") as f:
        f.write("{not json")
    assert q.peek()[1]["event"]["at"] == 2.0


def test_survives_restart(tmp_path):
    Outbox(str(tmp_path / "q")).put(ev(5))
    assert Outbox(str(tmp_path / "q")).peek()[1]["event"]["at"] == 5.0
