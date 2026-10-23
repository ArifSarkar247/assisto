#!/usr/bin/env python3
"""G1 Business AI Agent ("Night Salesman") — LIVE-PROOF self-test.

Runs against a deployed server WITHOUT any Meta / vision / courier key, on a
dedicated TEST business whose single TEST-MODE Messenger channel signs
webhooks with its own secret and never sends anything to Meta. It proves:

  1. a wrongly signed POST is refused (403);
  2. RULE-FIRST: a price question and an FAQ are answered with NO AI and
     0 credits (reply source = rule, plan replies used = 0);
  3. HUMAN TAKEOVER: a Page-inbox echo (a person replied) pauses the AI in that
     chat; the customer's next message gets no AI reply; after the seller's
     timeout (1 minute on the test business) the sweep makes the AI answer the
     waiting customer — once;
  4. PER-CHAT TOGGLE: "I will reply" silences the AI in that chat, "Let AI
     reply" brings it back;
  5. IMAGE → MATCH → ORDER → COURIER: a phone screenshot of the catalog photo
     is matched for free (perceptual hash), the order is collected, the summary
     shows the bundle price + delivery, "yes" creates a real Order (via agent,
     COD, stock reduced) and the courier is booked as a clearly labelled TEST
     MOCK (tracking TEST-…, courier_live = false);
  6. PAYMENT SCREENSHOT → the order becomes payment-PENDING (never paid).

Run on the server (after deploy + migrate):

  cd /home/ubuntu/assisto/backend
  ../.venv/bin/python manage.py bizagent_g1_selftest_setup --secret "$(openssl rand -hex 24)"
      # prints G1_SELFTEST_SECRET
  python3 ../tools/g1_selftest.py --base https://api.lifeassisto.com \\
      --secret <G1_SELFTEST_SECRET> --manage ./manage.py --python ../.venv/bin/python \\
      [--html /tmp/g1_proof.html]
  ../.venv/bin/python manage.py bizagent_g1_selftest_setup --teardown

--manage is required (the image asset, the per-chat toggle, the sweep and the
row checks go through manage.py). --html writes a chat-style proof page of the
whole run (for the STATUS screenshot). Exit code 0 = all checks passed. Takes
about 80 seconds (it waits out the 1-minute human pause).
"""
import argparse
import hashlib
import hmac
import html
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

PAGE_ID = "990000000000011"   # must match bizagent_g1_selftest_setup


def sign(secret, raw):
    return "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()


def post(url, payload, secret):
    raw = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=raw, method="POST", headers={
        "Content-Type": "application/json", "X-Hub-Signature-256": sign(secret, raw)})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


def _entry(psid, message):
    ts = int(time.time() * 1000)
    return {"object": "page", "entry": [{"id": PAGE_ID, "time": ts, "messaging": [
        {"sender": {"id": psid}, "recipient": {"id": PAGE_ID}, "timestamp": ts,
         "message": message}]}]}


def text(psid, mid, body):
    return _entry(psid, {"mid": mid, "text": body})


def image(psid, mid, url, caption=""):
    m = {"mid": mid, "attachments": [{"type": "image", "payload": {"url": url}}]}
    if caption:
        m["text"] = caption
    return _entry(psid, m)


def echo(psid, mid, body):
    return {"object": "page", "entry": [{"id": PAGE_ID, "messaging": [
        {"sender": {"id": PAGE_ID}, "recipient": {"id": psid}, "timestamp": int(time.time() * 1000),
         "message": {"mid": mid, "text": body, "is_echo": True, "app_id": 1}}]}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--secret", required=True)
    ap.add_argument("--manage", required=True, help="path to manage.py")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--html", default="", help="write a chat-style proof page here")
    ap.add_argument("--pause-wait", type=int, default=65)
    a = ap.parse_args()
    url = a.base.rstrip("/") + "/api/v1/bizagent/webhook/meta"
    cwd = os.path.dirname(os.path.abspath(a.manage))
    run = os.urandom(3).hex()
    fails = []

    def check(name, ok, extra=""):
        print(("PASS " if ok else "FAIL ") + name + (("  " + extra) if extra else ""))
        if not ok:
            fails.append(name)

    def manage(*args):
        out = subprocess.run([a.python, a.manage, "bizagent_g1_selftest_setup"] + list(args),
                             capture_output=True, text=True, cwd=cwd)
        return out.stdout.strip()

    def report():
        s = manage("--report")
        try:
            return json.loads(s[s.index("{"):])
        except ValueError:
            print(s[-500:])
            return {"threads": [], "orders": [], "agent": {}}

    def thread(rep, psid):
        return next((t for t in rep["threads"] if t["psid"] == psid), {"messages": []})

    def outs(rep, psid):
        return [m for m in thread(rep, psid)["messages"] if m["dir"] == "out"]

    def send(payload, label):
        st, js = post(url, payload, a.secret)
        if st != 200:
            check(label + " accepted", False, "HTTP %s" % st)
        time.sleep(1.5)
        return st

    # 1 ---------------------------------------------------------------- signature
    st, _ = post(url, text("x-" + run, "g1-bad-" + run, "hi"), "wrong-secret")
    check("wrong signature refused (403)", st == 403, "got %s" % st)

    # 2 ---------------------------------------------------------------- rule-first
    p_rule = "g1-rule-" + run
    before = report()["agent"].get("replies_used", 0)
    send(text(p_rule, "g1-r1-" + run, "Selftest Panjabi dam koto?"), "price question")
    send(text(p_rule, "g1-r2-" + run, "apnader dokan kothay?"), "faq question")
    rep = report()
    o = outs(rep, p_rule)
    check("price answered by RULE (no AI) with the catalog price 1200",
          any(m["source"] == "rule" and "1200" in m["text"] for m in o), str(o[:1]))
    check("FAQ answered by RULE", any(m["rule"] == "faq" for m in o))
    check("rule replies cost 0 credits / 0 plan replies",
          all(m["credits"] == 0 for m in o) and rep["agent"].get("replies_used", 0) == before)

    # 3 ---------------------------------------------------------------- takeover
    p_h = "g1-human-" + run
    send(text(p_h, "g1-h1-" + run, "hello"), "hello")
    send(echo(p_h, "g1-echo-" + run, "Ami owner, dekhchi"), "page inbox echo")
    send(text(p_h, "g1-h2-" + run, "delivery charge koto?"), "question during pause")
    rep = report()
    th = thread(rep, p_h)
    n_paused = len(outs(rep, p_h))
    last = th["messages"][-1] if th["messages"] else {}
    check("human echo PAUSES the AI in this chat", bool(th.get("paused_until")))
    check("no AI reply while paused (customer waits)", last.get("dir") == "in", str(last))
    print("  … waiting %ss for the 1-minute resume timeout" % a.pause_wait)
    time.sleep(a.pause_wait)
    manage("--sweep")
    rep = report()
    o = outs(rep, p_h)
    check("AI RESUMES after the timeout and answers the waiting customer once",
          len(o) == n_paused + 1 and o[-1]["is_ai"] and o[-1]["rule"] == "delivery", str(o[-1:]))
    manage("--sweep")
    check("…and only once", len(outs(report(), p_h)) == n_paused + 1)

    # 4 ---------------------------------------------------------------- per-chat toggle
    p_t = "g1-toggle-" + run
    send(text(p_t, "g1-t1-" + run, "hello"), "hello")
    manage("--mode", "human", "--psid", p_t)
    send(text(p_t, "g1-t2-" + run, "Selftest Panjabi dam koto?"), "message in human mode")
    n = len(outs(report(), p_t))
    last = thread(report(), p_t)["messages"][-1]
    check("'I will reply' → the AI stays silent", last["dir"] == "in")
    manage("--mode", "ai", "--psid", p_t)
    send(text(p_t, "g1-t3-" + run, "Selftest Panjabi dam koto?"), "message after Let AI reply")
    check("'Let AI reply' → the AI answers again", len(outs(report(), p_t)) == n + 1)

    # 5 ---------------------------------------------------------------- image → order → courier
    p_o = "g1-order-" + run
    shot = manage("--asset", "screenshot")
    send(image(p_o, "g1-i1-" + run, shot), "product screenshot")
    rep = report()
    o = outs(rep, p_o)
    check("photo MATCHED to the catalog for free (Selftest Panjabi ৳1200)",
          any(m["rule"] == "image_match" and "1200" in m["text"] and m["credits"] == 0
              for m in o), str(o[-1:]))
    stock0 = rep["agent"].get("stock", {}).get("Selftest Panjabi")
    # placeholder number pattern (not a real person): 019 + eight zeros
    send(text(p_o, "g1-o1-" + run, "2 ta nibo. Name: Selftest Buyer, phone 01900000000, "
                                    "address: House 1, Road 2, Mirpur, Dhaka"), "order details")
    o = outs(report(), p_o)
    check("summary shows bundle price + delivery + COD total (2 × 1140 + 60 = 2340)",
          bool(o) and "2340" in o[-1]["text"] and "1140" in o[-1]["text"], o[-1]["text"][:200] if o else "")
    send(text(p_o, "g1-o2-" + run, "yes"), "confirm")
    rep = report()
    orders = [x for x in rep["orders"] if x["total"] in ("2340.00", "2340")]
    od = orders[-1] if orders else {}
    check("real Order created by the agent (COD, 2340)",
          bool(od) and od["via_agent"] and od["payment"] == "cod", str(od)[:200])
    check("stock reduced by 2",
          stock0 is not None and rep["agent"]["stock"].get("Selftest Panjabi") == stock0 - 2)
    check("courier booked as TEST MOCK (labelled, never live)",
          bool(od) and od["tracking"].startswith("TEST-STEADFAST-") and od["courier_live"] is False)
    o = outs(rep, p_o)
    check("customer got the order number", bool(od) and any(("#%s" % od["id"]) in m["text"]
                                                             for m in o))

    # 6 ---------------------------------------------------------------- payment screenshot
    pay = manage("--asset", "payment")
    send(image(p_o, "g1-p1-" + run, pay, caption="bkash e advance diyechi"), "payment screenshot")
    rep = report()
    od2 = next((x for x in rep["orders"] if od and x["id"] == od["id"]), {})
    check("payment screenshot → payment PENDING (never marked paid)",
          od2.get("payment_status") == "pending_verification" and od2.get("payment") == "cod",
          str(od2.get("payment_status")))

    if a.html:
        write_html(a.html, rep, [p_rule, p_h, p_t, p_o], fails)
        print("proof page: %s" % a.html)
    print("\nRESULT: %s" % ("ALL PASSED" if not fails else "FAILED: " + ", ".join(fails)))
    return 1 if fails else 0


def write_html(path, rep, psids, fails):
    titles = {0: "1. Rule-first (no AI, 0 credits)", 1: "2. Human reply pauses AI, resumes",
              2: "3. Per-chat toggle", 3: "4. Photo → match → order → TEST courier → payment pending"}
    parts = ["<!doctype html><meta charset=utf-8><title>G1 self-test proof</title><style>"
             "body{font:15px/1.5 'Noto Sans Bengali',system-ui,sans-serif;max-width:720px;margin:24px auto;"
             "padding:0 16px;background:#f5f7fb;color:#111}h2{margin-top:28px}.m{max-width:80%;padding:8px 12px;"
             "border-radius:12px;margin:6px 0;white-space:pre-wrap}.in{background:#fff;border:1px solid #dde}"
             ".out{background:#2347D9;color:#fff;margin-left:auto}.meta{font-size:12px;opacity:.8}"
             ".ok{color:#1E7A50}.bad{color:#C62839}</style>",
             "<h1>Assisto G1 self-test — %s</h1>" % (
                 "<span class=ok>ALL PASSED</span>" if not fails else
                 "<span class=bad>FAILED: %s</span>" % html.escape(", ".join(fails)))]
    for i, ps in enumerate(psids):
        t = next((x for x in rep["threads"] if x["psid"] == ps), None)
        if not t:
            continue
        parts.append("<h2>%s</h2>" % titles.get(i, ps))
        for m in t["messages"]:
            meta = []
            if m["dir"] == "out":
                meta.append(m["source"] or ("human" if not m["is_ai"] else "ai"))
                if m["rule"]:
                    meta.append(m["rule"])
                meta.append("%s credits" % m["credits"])
            else:
                meta.append(m["kind"])
            parts.append("<div class='m %s'>%s<div class=meta>%s</div></div>" % (
                m["dir"], html.escape(m["text"] or "[%s]" % m["kind"]), html.escape(" · ".join(meta))))
    parts.append("<h2>Orders</h2><pre>%s</pre>" % html.escape(json.dumps(rep["orders"], indent=1,
                                                                          ensure_ascii=False)))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))


if __name__ == "__main__":
    sys.exit(main())
