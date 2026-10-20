"""Outbound-only HTTPS client for the device ingest endpoint + the sender loop
that drains the on-disk outbox.

Nothing here listens on a port. Every request is an outbound HTTPS POST to the
configured base URL (default https://api.lifeassisto.com/api/v1/).
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Callable, Optional
from urllib.parse import urljoin

from . import __version__, payload
from .cooldown import RateBudget

log = logging.getLogger(__name__)

# Outcome classes for a send attempt.
SENT = "sent"              # 200/201: delivered (raised or logged by server)
RETRY = "retry"            # network / 5xx / 429: keep in queue, back off
DROP = "drop"              # 4xx contract error: retrying will not help
UNAUTHORIZED = "unauthorized"   # 401: token wrong/revoked — pause sending


@dataclass
class SendResult:
    outcome: str
    status: Optional[int] = None
    raised: Optional[bool] = None
    confidence: Optional[float] = None
    retry_after: Optional[float] = None
    detail: str = ""


class IngestClient:
    def __init__(self, base_url: str, timeout: float = 20.0, session=None):
        import requests

        if not base_url.lower().startswith("https://") and \
                not base_url.lower().startswith("http://127.0.0.1") and \
                not base_url.lower().startswith("http://localhost"):
            # tokens must never travel in clear text over the internet
            raise ValueError("base URL must be https://")
        self.url = urljoin(base_url, payload.INGEST_PATH)
        self.timeout = float(timeout)
        self.s = session or requests.Session()
        self.s.headers.update({"User-Agent": "AssistoShopBox/%s" % __version__,
                               "Accept": "application/json"})

    def send(self, event: dict, *, site_token: Optional[str],
             camera_token: Optional[str], snapshot: Optional[bytes],
             snapshot_mode: str = "auto") -> SendResult:
        import requests

        try:
            transport, body, files = payload.build_request(
                event, site_token=site_token, camera_token=camera_token,
                snapshot=snapshot, snapshot_mode=snapshot_mode)
        except ValueError as exc:
            return SendResult(UNAUTHORIZED, detail=str(exc))
        try:
            if transport == "json":
                r = self.s.post(self.url, json=body, timeout=self.timeout)
            else:
                r = self.s.post(self.url, data=body, files=files,
                                timeout=self.timeout)
        except requests.RequestException as exc:
            return SendResult(RETRY, detail=type(exc).__name__)
        return classify_response(r.status_code, _safe_json(r),
                                 r.headers.get("Retry-After"))

    def verify_pairing(self, site_token: str) -> SendResult:
        """Check a token WITHOUT creating any event: the server resolves the
        token before validating the type, so an empty `type` yields 401 for a
        bad token and 422 `bad_type` for a good one (nothing is stored)."""
        import requests

        try:
            r = self.s.post(self.url, json={"site_token": site_token, "type": ""},
                            timeout=self.timeout)
        except requests.RequestException as exc:
            return SendResult(RETRY, detail=type(exc).__name__)
        data = _safe_json(r)
        if r.status_code == 422 and data.get("error") == "bad_type":
            return SendResult(SENT, status=422, detail="token_ok")
        if r.status_code == 401:
            return SendResult(UNAUTHORIZED, status=401, detail="bad_token")
        return classify_response(r.status_code, data, r.headers.get("Retry-After"))


def _safe_json(r) -> dict:
    try:
        d = r.json()
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def classify_response(status: int, data: dict, retry_after=None) -> SendResult:
    if status in (200, 201):
        return SendResult(SENT, status=status, raised=bool(data.get("raised")),
                          confidence=data.get("confidence"))
    if status == 401:
        return SendResult(UNAUTHORIZED, status=status, detail="bad_token")
    if status == 429:
        try:
            ra = float(retry_after) if retry_after else 30.0
        except ValueError:
            ra = 30.0
        return SendResult(RETRY, status=status, retry_after=ra, detail="rate_limited")
    if status >= 500 or status in (408, 425):
        return SendResult(RETRY, status=status, detail="server_error")
    return SendResult(DROP, status=status, detail=str(data.get("error") or status))


class Sender(threading.Thread):
    """Drains the outbox oldest-first, respecting a global send budget, with
    exponential backoff while offline. Pauses (slow re-check) on 401."""

    def __init__(self, outbox, client: IngestClient, get_tokens: Callable,
                 budget: RateBudget, snapshot_mode: str = "auto",
                 on_result: Optional[Callable] = None):
        super().__init__(name="sender", daemon=True)
        self.outbox = outbox
        self.client = client
        self.get_tokens = get_tokens          # camera_id -> (site_tok, cam_tok)
        self.budget = budget
        self.snapshot_mode = snapshot_mode
        self.on_result = on_result or (lambda *a: None)
        self._halt = threading.Event()
        self._wake = threading.Event()
        self.backoff = 0.0
        self.online: Optional[bool] = None
        self.unauthorized = False

    def stop(self) -> None:
        self._halt.set()
        self._wake.set()

    def wake(self) -> None:
        self._wake.set()

    def _sleep(self, s: float) -> None:
        self._wake.wait(timeout=max(0.05, s))
        self._wake.clear()

    def run(self) -> None:
        while not self._halt.is_set():
            item = self.outbox.peek()
            if item is None:
                self._sleep(5.0)
                continue
            wait = self.budget.wait_time()
            if wait:
                self._sleep(wait)
                continue
            if not self.budget.try_acquire():
                continue
            item_id, rec, snap = item
            event = rec["event"]
            site_tok, cam_tok = self.get_tokens(event.get("camera_id"))
            res = self.client.send(event, site_token=site_tok, camera_token=cam_tok,
                                   snapshot=snap, snapshot_mode=self.snapshot_mode)
            self.on_result(item_id, event, res)
            if res.outcome == SENT:
                self.outbox.remove(item_id)
                self.backoff, self.online, self.unauthorized = 0.0, True, False
            elif res.outcome == DROP:
                log.warning("server rejected event %s (%s); dropped",
                            event.get("type"), res.detail)
                self.outbox.remove(item_id)
                self.online = True
            elif res.outcome == UNAUTHORIZED:
                # keep the queue: the owner may re-pair; re-check every 10 min
                self.unauthorized, self.online = True, True
                log.error("device token rejected (401) — please re-pair")
                self._sleep(600)
            else:
                self.outbox.mark_attempt(item_id)
                self.online = res.status is not None
                self.backoff = min(300.0, max(5.0, self.backoff * 2 or 5.0))
                delay = max(self.backoff, res.retry_after or 0.0)
                log.info("send deferred (%s); retry in %.0fs, %d queued",
                         res.detail or res.status, delay, len(self.outbox))
                self._sleep(delay)
        log.info("sender stopped")
