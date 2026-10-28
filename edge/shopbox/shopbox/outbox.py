"""Bounded on-disk store-and-forward queue.

When the internet is down, events are written here and sent later, oldest
first. The queue is bounded three ways so it can never fill the shop PC's disk:
max item count, max total bytes, max age (a stale alert is not useful, and the
server correlates hand-in-zone events with RECENT POS rows only). When a bound
is hit the OLDEST items are dropped.

Each item is `<id>.json` (event, no credentials) plus optional `<id>.jpg`
(the single snapshot). Writes are atomic (temp file + os.replace) so a power
cut never leaves a half-written item that blocks the queue.
"""
from __future__ import annotations

import itertools
import json
import logging
import os
import threading
import time
from typing import Callable, List, Optional, Tuple

log = logging.getLogger(__name__)


class Outbox:
    def __init__(self, directory: str, max_items: int = 200,
                 max_bytes: int = 40 * 1024 * 1024, max_age_s: float = 12 * 3600,
                 clock: Callable[[], float] = time.time, ext: str = ".jpg"):
        self.dir = directory
        self.ext = ext            # attachment file: snapshot (.jpg) / clip (.bin)
        self.max_items = int(max_items)
        self.max_bytes = int(max_bytes)
        self.max_age_s = float(max_age_s)
        self._clock = clock
        self._lock = threading.Lock()
        self._seq = itertools.count()
        os.makedirs(self.dir, exist_ok=True)
        self.dropped = 0          # count of items discarded by the bounds

    # ---------------------------------------------------------------- helpers
    def _ids(self) -> List[str]:
        """Item ids, oldest first (ids sort chronologically by construction)."""
        try:
            names = os.listdir(self.dir)
        except FileNotFoundError:
            return []
        return sorted(n[:-5] for n in names if n.endswith(".json"))

    def _paths(self, item_id: str) -> Tuple[str, str]:
        return (os.path.join(self.dir, item_id + ".json"),
                os.path.join(self.dir, item_id + self.ext))

    def _size(self, item_id: str) -> int:
        total = 0
        for p in self._paths(item_id):
            try:
                total += os.path.getsize(p)
            except OSError:
                pass
        return total

    def _delete(self, item_id: str) -> None:
        for p in self._paths(item_id):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
            except OSError as exc:
                log.warning("outbox: could not remove %s: %s", p, exc)

    @staticmethod
    def _atomic_write(path: str, data: bytes) -> None:
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)

    # ------------------------------------------------------------------- API
    def put(self, event: dict, snapshot: Optional[bytes] = None) -> str:
        """Persist one event (+ optional snapshot); enforce the bounds."""
        now = self._clock()
        item_id = "%016d_%06d" % (int(now * 1000), next(self._seq) % 1_000_000)
        jpath, ipath = self._paths(item_id)
        record = {"event": event, "queued_at": now, "attempts": 0,
                  "has_snapshot": bool(snapshot)}
        with self._lock:
            if snapshot:
                self._atomic_write(ipath, snapshot)
            # JSON last: an item "exists" only once its .json is in place.
            self._atomic_write(jpath, json.dumps(record).encode("utf-8"))
            self._enforce_bounds_locked()
        return item_id

    def _enforce_bounds_locked(self) -> None:
        ids = self._ids()
        now = self._clock()
        # 1) age
        keep = []
        for i in ids:
            rec = self._read_locked(i)
            if rec is None or now - float(rec.get("queued_at", now)) > self.max_age_s:
                self._delete(i)
                self.dropped += 1
            else:
                keep.append(i)
        ids = keep
        # 2) count
        while len(ids) > self.max_items:
            self._delete(ids.pop(0))
            self.dropped += 1
        # 3) bytes
        sizes = {i: self._size(i) for i in ids}
        total = sum(sizes.values())
        while ids and total > self.max_bytes:
            victim = ids.pop(0)
            total -= sizes[victim]
            self._delete(victim)
            self.dropped += 1

    def _read_locked(self, item_id: str) -> Optional[dict]:
        jpath, _ = self._paths(item_id)
        try:
            with open(jpath, "rb") as f:
                return json.loads(f.read().decode("utf-8"))
        except (OSError, ValueError):
            return None

    def peek(self) -> Optional[Tuple[str, dict, Optional[bytes]]]:
        """The oldest (id, record, snapshot_bytes_or_None), or None if empty."""
        with self._lock:
            self._enforce_bounds_locked()
            for item_id in self._ids():
                rec = self._read_locked(item_id)
                if rec is None:          # corrupt: drop it, never block on it
                    self._delete(item_id)
                    continue
                snap = None
                if rec.get("has_snapshot"):
                    try:
                        with open(self._paths(item_id)[1], "rb") as f:
                            snap = f.read()
                    except OSError:
                        snap = None
                return item_id, rec, snap
        return None

    def mark_attempt(self, item_id: str) -> None:
        with self._lock:
            rec = self._read_locked(item_id)
            if rec is None:
                return
            rec["attempts"] = int(rec.get("attempts", 0)) + 1
            self._atomic_write(self._paths(item_id)[0],
                               json.dumps(rec).encode("utf-8"))

    def remove(self, item_id: str) -> None:
        with self._lock:
            self._delete(item_id)

    def __len__(self) -> int:
        with self._lock:
            return len(self._ids())

    def total_bytes(self) -> int:
        with self._lock:
            return sum(self._size(i) for i in self._ids())
