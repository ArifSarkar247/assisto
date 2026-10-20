import json

from shopbox import payload
from shopbox.client import (DROP, RETRY, SENT, UNAUTHORIZED, IngestClient, Sender,
                            classify_response)
from shopbox.cooldown import RateBudget
from shopbox.outbox import Outbox


class FakeResp:
    def __init__(self, status, data, headers=None):
        self.status_code, self._d, self.headers = status, data, headers or {}

    def json(self):
        return self._d


class FakeSession:
    def __init__(self, resp):
        self.resp, self.calls, self.headers = resp, [], {}

    def post(self, url, **kw):
        self.calls.append((url, kw))
        return self.resp


def test_classify_response():
    assert classify_response(201, {"raised": True, "confidence": 0.8}).raised
    assert classify_response(200, {"raised": False}).outcome == SENT
    assert classify_response(401, {}).outcome == UNAUTHORIZED
    r = classify_response(429, {}, "12")
    assert r.outcome == RETRY and r.retry_after == 12
    assert classify_response(503, {}).outcome == RETRY
    assert classify_response(422, {"error": "bad_type"}).outcome == DROP


def test_client_posts_to_ingest_path_over_https():
    s = FakeSession(FakeResp(201, {"raised": True, "confidence": 0.7}))
    c = IngestClient("https://api.lifeassisto.com/api/v1/", session=s)
    ev = payload.build_event("after_hours", {"after_hours": True}, camera_id="c1", at=5.0)
    r = c.send(ev, site_token="T", camera_token=None, snapshot=b"\xff\xd8")
    assert r.outcome == SENT and r.raised
    url, kw = s.calls[0]
    assert url == "https://api.lifeassisto.com/api/v1/shop/ingest"
    assert "files" in kw and kw["data"]["site_token"] == "T"
    assert json.loads(kw["data"]["signals"]) == {"after_hours": True}


def test_plain_http_refused():
    try:
        IngestClient("http://api.example.com/api/v1/", session=FakeSession(None))
    except ValueError:
        return
    raise AssertionError("http:// must be refused")


def test_verify_pairing_uses_side_effect_free_probe():
    s = FakeSession(FakeResp(422, {"error": "bad_type"}))
    c = IngestClient("https://x.test/api/v1/", session=s)
    assert c.verify_pairing("T").outcome == SENT
    assert s.calls[0][1]["json"] == {"site_token": "T", "type": ""}
    s.resp = FakeResp(401, {"error": "bad_token"})
    assert c.verify_pairing("T").outcome == UNAUTHORIZED


class ScriptedClient:
    def __init__(self, results):
        self.results, self.sent = list(results), []

    def send(self, event, **kw):
        self.sent.append((event, kw))
        return self.results.pop(0)


def _drain_once(sender):
    """Run the real loop until its first sleep (after one send attempt, or
    when the queue is empty), then stop."""
    import threading
    sender._sleep = lambda s: sender._halt.set()
    sender._halt.clear()
    t = threading.Thread(target=sender.run)
    t.start()
    t.join(5)
    assert not t.is_alive()


def test_sender_keeps_item_on_retry_and_removes_on_success(tmp_path):
    from shopbox.client import SendResult
    q = Outbox(str(tmp_path / "q"))
    q.put(payload.build_event("after_hours", {"after_hours": True}, camera_id="c1"))
    client = ScriptedClient([SendResult(RETRY, detail="ConnectionError"),
                             SendResult(SENT, status=201, raised=True)])
    sender = Sender(q, client, lambda cid: ("SITE", None), RateBudget(100))
    _drain_once(sender)
    assert len(q) == 1 and sender.backoff == 5.0
    _drain_once(sender)
    assert len(q) == 0 and sender.online
    assert client.sent[0][1]["site_token"] == "SITE"
