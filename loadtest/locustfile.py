"""Assisto API load test (Locust) — CI ONLY (.github/workflows/loadtest.yml).
NEVER point this at the live server: the workflow runs its own throw-away
backend + Postgres on the CI runner (host 127.0.0.1:8700).

Traffic mix = the real app's, from the live nginx timing log (27 Oct 2026,
7,830 API calls): rt/events polling ~48 %, health ~7 %, then calls, receipts
sync, group/1:1 messages, features, badges, discover, devices, alerts, ads...
Each virtual user = one seeded account (tokens.json from loadtest_seed) with
an app-like think time between requests.

Load shape (env): LT_USERS (peak virtual users), LT_RAMP_S, LT_HOLD_S.
"""
import itertools
import json
import os
import random
import threading

from locust import HttpUser, LoadTestShape, between, task

_TOKENS = json.load(open(os.environ.get("LT_TOKENS", "tokens.json")))
_next = itertools.count()
_lock = threading.Lock()


def _account():
    with _lock:
        i = next(_next)
    return _TOKENS[i % len(_TOKENS)]


class AppUser(HttpUser):
    # app-like pacing: polls every few seconds while open
    wait_time = between(float(os.environ.get("LT_WAIT_MIN", "3")),
                        float(os.environ.get("LT_WAIT_MAX", "7")))

    def on_start(self):
        a = _account()
        self.client.headers.update({"Authorization": "Token " + a["token"],
                                    "Accept-Language": "bn"})
        self.edges = a["edges"] or [0]
        self.groups = a["groups"] or [0]
        self.seq = 0
        self.n = 0

    def _get(self, path, name=None):
        return self.client.get("/api/v1/" + path, name=name or path)

    def _post(self, path, body, name=None):
        return self.client.post("/api/v1/" + path, json=body, name=name or path)

    # ---- weights ~ the live mix (per 1000 calls) --------------------------
    @task(480)
    def rt_events(self):
        r = self._get("rt/events?after=%d&online=1" % self.seq, "rt/events")
        try:
            self.seq = max(self.seq, int(r.json().get("seq") or 0))
        except Exception:
            pass

    @task(72)
    def health(self):
        self._get("health")

    @task(28)
    def calls_incoming(self):
        self._get("circle/calls/incoming")

    @task(28)
    def receipts_sync(self):
        self._post("circle/receipts/sync", {})

    @task(24)
    def group_messages(self):
        self._get("circle/groups/%d/messages" % random.choice(self.groups),
                  "circle/groups/<id>/messages")

    @task(24)
    def features(self):
        self._get("features")

    @task(20)
    def badges(self):
        self._get("home/badges")

    @task(20)
    def calls_history(self):
        self._get("circle/calls")

    @task(15)
    def rt_send_typing(self):
        self._post("rt/send", {"topic": "typing.set", "payload": {
            "chat_kind": "member", "chat_id": random.choice(self.edges),
            "state": "typing"}})

    @task(14)
    def discover_cards(self):
        self._get("discover/cards")

    @task(12)
    def chat_messages(self):
        self._get("circle/%d/messages" % random.choice(self.edges),
                  "circle/<id>/messages")

    @task(12)
    def devices_register(self):
        self._post("devices/register", {
            "push_token": "lt-token-%s" % self.client.headers[
                "Authorization"][-12:], "platform": "android",
            "app_version": "1.0.255"})

    @task(11)
    def lost_phone(self):
        self._get("security/lost-phone")

    @task(11)
    def alerts(self):
        self._get("alerts")

    @task(10)
    def missed_pending(self):
        self._get("circle/calls/missed_pending")

    @task(9)
    def e2_resend(self):
        self._get("circle/e2/resend")

    @task(10)
    def send_message(self):
        self.n += 1
        self._post("circle/%d/messages" % random.choice(self.edges), {
            "ciphertext": "Q1Q=" * 8, "nonce": "Tg==",
            "client_msg_id": "lt-%d-%d" % (id(self), self.n)},
            "circle/<id>/messages POST")

    @task(7)
    def ads_config(self):
        self._get("ads/config")

    @task(6)
    def ads_slot(self):
        self._get("ads/slot?screen=home", "ads/slot")

    @task(4)
    def chats(self):
        self._get("circle/chats")

    @task(4)
    def money(self):
        self._get("transactions/")

    @task(4)
    def reminders(self):
        self._get("reminders/")


class StepShape(LoadTestShape):
    """Ramp to LT_USERS over LT_RAMP_S, hold LT_HOLD_S, stop."""
    users = int(os.environ.get("LT_USERS", "1000"))
    ramp = int(os.environ.get("LT_RAMP_S", "120"))
    hold = int(os.environ.get("LT_HOLD_S", "180"))

    def tick(self):
        t = self.get_run_time()
        if t > self.ramp + self.hold:
            return None
        rate = max(1.0, self.users / max(1, self.ramp))
        return (self.users, rate)
