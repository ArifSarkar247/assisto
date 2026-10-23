#!/usr/bin/env python3
"""P1 Business AI Agent — LIVE-PROOF self-test (no owner / Meta keys needed).

What it proves on a deployed server:
  1. the webhook endpoints are reachable and refuse a wrongly signed POST (403),
  2. a correctly signed Messenger payload is accepted (200) and processed:
     price question → AI reply; order details → summary; "yes" → a real Order,
  3. the same message id posted twice is processed once (idempotent),
  4. a correctly signed WhatsApp Cloud API payload is accepted and answered.

It signs with a TEST secret that belongs ONLY to two test-mode channels of a
dedicated test business (never the Meta app secret); test-mode channels never
send anything to Meta.

Run (on the server, after deploy + migrate):

  cd /home/ubuntu/assisto/backend
  ../.venv/bin/python manage.py bizagent_selftest_setup --secret "$(openssl rand -hex 24)"
      # prints SELFTEST_SECRET / SELFTEST_PAGE_ID / SELFTEST_WA_PNID
  python3 ../tools/p1_webhook_selftest.py --base https://api.lifeassisto.com \\
      --secret <SELFTEST_SECRET> --manage ./manage.py
      # --manage: also reads the rows back (threads / replies / order) and checks them
  ../.venv/bin/python manage.py bizagent_selftest_setup --teardown   # clean up

Without --manage it only checks the HTTP side; read the rows yourself with
`manage.py bizagent_selftest_setup --report`. Exit code 0 = all checks passed.
"""
import argparse
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

PAGE_ID = "990000000000001"   # must match bizagent_selftest_setup
WA_PNID = "990000000000002"


def sign(secret, raw):
    return "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()


def post(url, payload, secret):
    raw = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=raw, method="POST", headers={
        "Content-Type": "application/json", "X-Hub-Signature-256": sign(secret, raw)})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


def messenger(text, mid, psid):
    ts = int(time.time() * 1000)
    return {"object": "page", "entry": [{"id": PAGE_ID, "time": ts, "messaging": [
        {"sender": {"id": psid}, "recipient": {"id": PAGE_ID}, "timestamp": ts,
         "message": {"mid": mid, "text": text}}]}]}


def whatsapp(text, wamid, frm):
    return {"object": "whatsapp_business_account", "entry": [{"id": "SELFTEST", "changes": [
        {"field": "messages", "value": {
            "messaging_product": "whatsapp", "metadata": {"phone_number_id": WA_PNID},
            "contacts": [{"profile": {"name": "Selftest Buyer"}, "wa_id": frm}],
            "messages": [{"from": frm, "id": wamid, "timestamp": str(int(time.time())),
                          "type": "text", "text": {"body": text}}]}}]}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="e.g. https://api.lifeassisto.com")
    ap.add_argument("--secret", required=True, help="SELFTEST_SECRET from bizagent_selftest_setup")
    ap.add_argument("--manage", default="", help="path to manage.py to read the rows back")
    ap.add_argument("--python", default=sys.executable)
    a = ap.parse_args()
    meta = a.base.rstrip("/") + "/api/v1/bizagent/webhook/meta"
    wa = a.base.rstrip("/") + "/api/v1/bizagent/webhook/whatsapp"
    run = os.urandom(4).hex()
    psid = "selftest-" + run
    fails = []

    def check(name, ok, extra=""):
        print(("PASS " if ok else "FAIL ") + name + (("  " + extra) if extra else ""))
        if not ok:
            fails.append(name)

    st, _ = post(meta, messenger("hello", "st-bad-" + run, psid), "wrong-secret")
    check("wrong signature refused (403)", st == 403, "got %s" % st)

    st, js = post(meta, messenger("Selftest Panjabi er dam koto?", "st-1-" + run, psid), a.secret)
    check("signed Messenger message accepted", st == 200 and js.get("queued") == 1, str(js))
    st, js = post(meta, messenger("Selftest Panjabi er dam koto?", "st-1-" + run, psid), a.secret)
    check("same message id is a no-op (idempotent)", st == 200 and js.get("queued") == 0, str(js))
    time.sleep(2)
    # placeholder number pattern (not a real person): 019 + eight zeros
    st, js = post(meta, messenger("Selftest Panjabi 2 ta order korbo. Name: Selftest Buyer, "
                                  "phone 01900000000, address: House 1, Road 2, Mirpur, Dhaka",
                                  "st-2-" + run, psid), a.secret)
    check("order details accepted", st == 200 and js.get("queued") == 1, str(js))
    time.sleep(2)
    st, js = post(meta, messenger("yes", "st-3-" + run, psid), a.secret)
    check("order confirmation accepted", st == 200 and js.get("queued") == 1, str(js))
    st, js = post(wa, whatsapp("Selftest Panjabi ache?", "wamid.st-" + run, "selftest" + run),
                  a.secret)
    check("signed WhatsApp message accepted", st == 200 and js.get("queued") == 1, str(js))

    if a.manage:
        time.sleep(3)
        out = subprocess.run([a.python, a.manage, "bizagent_selftest_setup", "--report"],
                             capture_output=True, text=True, cwd=os.path.dirname(os.path.abspath(a.manage)))
        try:
            rep = json.loads(out.stdout[out.stdout.index("{"):])
        except ValueError:
            rep = {}
            print(out.stdout[-500:], out.stderr[-500:])
        threads = rep.get("threads") or []
        msgs = [m for t in threads for m in t["messages"]]
        ai = [m for m in msgs if m["dir"] == "out" and m["is_ai"] and m["status"] == "sent"]
        check("threads created (messenger + whatsapp)",
              {t["channel"] for t in threads} >= {"messenger", "whatsapp_cloud"})
        check("AI replies recorded as sent (test mode, nothing sent to Meta)", len(ai) >= 3,
              "%d AI replies" % len(ai))
        check("price reply uses the catalog price (1200)", any("1200" in m["text"] for m in ai))
        orders = rep.get("orders") or []
        check("real Order created from the chat (2 × 1200 + 60 = 2460, COD)",
              any(o["total"] in ("2460.00", "2460") for o in orders), str(orders[-1:]))
    print("\nRESULT: %s" % ("ALL PASSED" if not fails else "FAILED: " + ", ".join(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
