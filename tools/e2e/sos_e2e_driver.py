"""Family SOS end-to-end driver (run by tools/e2e/sos_e2e.sh) — fcsos.

    python sos_e2e_driver.py seed     # before runserver: 5 users, circle, devices
    python sos_e2e_driver.py run      # the checks (exit 1 on any FAIL)

Accounts: Rina (sender), Ammu + Bhai (My Circle), Abbu (My Circle, bn),
Stranger (no link — must get nothing). Three simulated phones watch the mock
FCM and ack each SOS the moment it arrives (POST /family/alerts/received, the
same receipt the real app sends from any isolate).

What is timed (honest): t0 = just before the sender's POST /family/sos;
  fcm   = the push for that phone accepted by (mock) FCM
  phone = the simulated phone saw it (polls every 50 ms) and acked it
The real Google FCM -> phone hop is NOT in this number (it is measured on real
phones from FamilyAlertDelivery.received_at - pushed_at, family_alerts_report).
"""
import json
import os
import statistics
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path[:0] = [os.path.join(ROOT, "backend")]
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "assisto_backend.settings_e2e")

E2E_DIR = os.environ.get("E2E_DIR", "/tmp/assisto-sos-e2e")
SEED_FILE = os.path.join(E2E_DIR, "seed.json")
BASE = os.environ.get("E2E_BASE_URL", "http://127.0.0.1:18800") + "/api/v1"
FCM = os.environ.get("E2E_FCM_URL", "http://127.0.0.1:18890")
ROUNDS = int(os.environ.get("SOS_E2E_ROUNDS", "20"))
TARGET_S = 10.0
USERS = (("rina", "01710008001", "en"), ("ammu", "01710008002", "bn"),
         ("bhai", "01710008003", "en"), ("abbu", "01710008004", "bn"),
         ("stranger", "01710008005", "en"))
FAMILY = ("ammu", "bhai", "abbu")
RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), str(detail)[:300]))
    print("%s  %s %s" % ("PASS" if cond else "FAIL", name,
                         "" if cond else "-- " + str(detail)[:300]), flush=True)
    return bool(cond)


class Abort(Exception):
    pass


def need(name, cond, detail=""):
    if not check(name, cond, detail):
        raise Abort(name)


def wait_for(fn, timeout, every=0.05):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:  # noqa: BLE001
            pass
        time.sleep(every)
    return None


# ------------------------------------------------------------------ seed
def seed():
    import django
    django.setup()
    from rest_framework.authtoken.models import Token
    from core.models import CircleMember, Device, User
    out, users = {}, {}
    for role, phone, lang in USERS:
        u = User.objects.filter(phone=phone).first() or User.objects.create_user(
            name=role.title(), phone=phone, password="e2e-pass-123")
        u.language = lang
        u.save()
        users[role] = u
        Device.objects.get_or_create(user=u, push_token="e2e-fcm-%s" % role)
        out[role] = Token.objects.get_or_create(user=u)[0].key
    r = users["rina"]
    for role in FAMILY:
        f = users[role]
        CircleMember.objects.get_or_create(user=r, peer_user=f, defaults=dict(
            name=f.name, phone=f.phone, state="accepted"))
        CircleMember.objects.get_or_create(user=f, peer_user=r, defaults=dict(
            name=r.name, phone=r.phone, state="accepted", direction="incoming"))
    with open(SEED_FILE, "w") as fh:
        json.dump(out, fh)
    print("seeded", list(out))


# ------------------------------------------------------------------ helpers
def session(token):
    import requests
    s = requests.Session()
    s.headers.update({"Authorization": "Token " + token, "Accept-Language": "en"})
    return s


def fcm_calls():
    import requests
    return requests.get(FCM + "/calls", timeout=5).json()["calls"]


def data_of(m):
    return m.get("data") or {}


class Phone(threading.Thread):
    """A family phone: sees its FCM pushes and acks SOS receipts at once."""

    def __init__(self, role, sess):
        super().__init__(daemon=True)
        self.role, self.s = role, sess
        self.token = "e2e-fcm-%s" % role
        self.seen = {}          # delivery_id -> (fcm_t, seen_t, data)
        self.stop = False
        self._done = 0

    def run(self):
        while not self.stop:
            try:
                calls = fcm_calls()
                for m in calls[self._done:]:
                    if m.get("token") != self.token:
                        continue
                    d = data_of(m)
                    if d.get("kind") == "sos" and d.get("delivery_id"):
                        did = int(d["delivery_id"])
                        if did not in self.seen:
                            self.seen[did] = (m.get("_t"), time.time(), d)
                            self.s.post(BASE + "/family/alerts/received",
                                        json={"ids": [did]}, timeout=5)
                self._done = len(calls)
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.05)


def pct(v, p):
    v = sorted(v)
    if not v:
        return None
    k = max(0, min(len(v) - 1, int(round(p / 100.0 * len(v) + 0.5)) - 1))
    return v[k]


# ------------------------------------------------------------------ run
def run():
    with open(SEED_FILE) as fh:
        tok = json.load(fh)
    s = {k: session(v) for k, v in tok.items()}
    phones = {r: Phone(r, s[r]) for r in FAMILY}
    for p in phones.values():
        p.start()
    metrics = {"rounds": 0, "fcm_s": [], "phone_s": [], "all_phones_s": []}
    try:
        # 1. the countdown: the app posts NOTHING until it ends / Send now
        before = len([m for m in fcm_calls() if data_of(m).get("kind") == "sos"])
        check("countdown: no SOS push before the app sends", before == 0, before)

        # 2. SOS to 3 accounts, timed, ROUNDS times (each ended "by mistake")
        stranger_tok = "e2e-fcm-stranger"
        first_ids = {}
        for i in range(ROUNDS):
            t0 = time.time()
            r = s["rina"].post(BASE + "/family/sos", json={
                "lat": 23.7461, "lng": 90.3742, "source": "family_v3",
                "client_id": "e2e-%d-%d" % (i, int(t0 * 1000))}, timeout=15)
            need("round %d: POST /family/sos 200" % i, r.status_code == 200, r.text)
            body = r.json()
            check("round %d: 3 recipients, 3 sent" % i,
                  body.get("recipients") == 3 and body.get("sent") == 3, body)

            def all_seen():
                got = {}
                for role, p in phones.items():
                    new = [(did, v) for did, v in p.seen.items() if v[1] >= t0]
                    if not new:
                        return None
                    got[role] = max(new)
                return got
            got = wait_for(all_seen, 15)
            need("round %d: all 3 family phones got the SOS" % i, got, {r: len(p.seen) for r, p in phones.items()})
            fcm_lat = [v[1][0] - t0 for v in got.values() if v[1][0]]
            ph_lat = [v[1][1] - t0 for v in got.values()]
            metrics["fcm_s"] += fcm_lat
            metrics["phone_s"] += ph_lat
            metrics["all_phones_s"].append(max(ph_lat))
            metrics["rounds"] += 1
            if i == 0:
                first_ids = {role: v[0] for role, v in got.items()}
                d = got["ammu"][1][2]
                check("push is the full-screen SOS kind with location",
                      d.get("kind") == "sos" and d.get("alert_kind") == "sos" and d.get("lat"), d)
                stranger = [m for m in fcm_calls() if m.get("token") == stranger_tok]
                check("stranger got nothing", not stranger, len(stranger))
                # 3. receiver page
                ev = s["ammu"].get(BASE + "/family/sos/event/%d" % first_ids["ammu"], timeout=10).json()
                check("receiver: who / when / where",
                      ev.get("sender", {}).get("name") and ev.get("sent_at") and
                      (ev.get("location") or {}).get("lat") == 23.7461, ev)
                check("receiver: state active", ev.get("state") == "active", ev.get("state"))
                rr = s["stranger"].get(BASE + "/family/sos/event/%d" % first_ids["ammu"], timeout=10)
                check("stranger cannot open the alarm page", rr.status_code == 404, rr.status_code)
                # live location
                lr = s["rina"].post(BASE + "/family/sos/location",
                                    json={"lat": 23.7501, "lng": 90.3801}, timeout=10)
                check("live location accepted", lr.status_code == 200 and lr.json().get("updated") == 3, lr.text)
                ev = s["bhai"].get(BASE + "/family/sos/event/%d" % first_ids["bhai"], timeout=10).json()
                check("receiver sees the live location",
                      (ev.get("location") or {}).get("lat") == 23.7501 and ev["location"].get("live"), ev.get("location"))
                # 30 s sound
                import base64
                clip = base64.b64encode(b"\x00\x00\x00\x18ftypM4A " + b"\x01" * 4000).decode()
                ar = s["rina"].post(BASE + "/family/sos/audio", json={"audio_b64": clip, "sec": 30}, timeout=10)
                check("sender uploads the 30 s sound", ar.status_code == 200, ar.text)
                au = s["abbu"].get(BASE + "/family/sos/event/%d/audio" % first_ids["abbu"], timeout=10)
                check("family plays the sound", au.status_code == 200 and len(au.content) > 4000, au.status_code)
                # who is going
                g = s["bhai"].post(BASE + "/family/alerts/%d/responding" % first_ids["bhai"], timeout=10)
                check("Bhai taps I am going", g.status_code == 200, g.text)
                ev = s["ammu"].get(BASE + "/family/sos/event/%d" % first_ids["ammu"], timeout=10).json()
                check("Ammu sees Bhai in who-is-going", len(ev.get("going") or []) == 1, ev.get("going"))
                st = s["rina"].get(BASE + "/family/sos/status", timeout=10).json()
                check("sender sees who is going", len(st.get("going") or []) == 1, st)
            # 4. cancel after sending = "sent by mistake" to all 3
            n0 = len(fcm_calls())
            m = s["rina"].post(BASE + "/family/sos/resolve", json={"reason": "mistake"}, timeout=15)
            check("round %d: mistake resolve 200" % i, m.status_code == 200 and m.json().get("recipients") == 3, m.text)
            if i == 0:
                def mistakes():
                    c = [x for x in fcm_calls()[n0:] if data_of(x).get("event") == "sos_mistake"]
                    return c if len({x.get("token") for x in c}) == 3 else None
                c = wait_for(mistakes, 10)
                check("everyone is told it was a mistake (3 pushes)", c, len(c or []))
                ev = s["ammu"].get(BASE + "/family/sos/event/%d" % first_ids["ammu"], timeout=10).json()
                check("receiver page turns to 'mistake'", ev.get("state") == "mistake", ev.get("state"))
            time.sleep(1.1)  # next SOS = a new event (and a new minute bucket is not needed: client ids)
    except Abort:
        pass
    except Exception as e:  # noqa: BLE001
        check("driver crashed", False, "%s: %s" % (type(e).__name__, traceback.format_exc()[-300:]))
    finally:
        for p in phones.values():
            p.stop = True

    allp = metrics["all_phones_s"]
    summary = {
        "rounds": metrics["rounds"], "recipients_per_round": 3, "target_s": TARGET_S,
        "fcm_p50_ms": round(1000 * statistics.median(metrics["fcm_s"])) if metrics["fcm_s"] else None,
        "fcm_p95_ms": round(1000 * pct(metrics["fcm_s"], 95)) if metrics["fcm_s"] else None,
        "all_phones_p50_ms": round(1000 * statistics.median(allp)) if allp else None,
        "all_phones_p95_ms": round(1000 * pct(allp, 95)) if allp else None,
        "all_phones_max_ms": round(1000 * max(allp)) if allp else None,
        "note": "mock FCM on localhost; the Google FCM -> phone hop is measured on real phones",
    }
    if allp:
        check("SOS on all 3 family phones within %ds (p95 of %d rounds)" % (TARGET_S, len(allp)),
              pct(allp, 95) < TARGET_S, summary)
    print("FCSOS_LATENCY " + json.dumps(summary), flush=True)
    with open(os.path.join(E2E_DIR, "sos_results.json"), "w") as fh:
        json.dump({"summary": summary, "checks": RESULTS}, fh, indent=1)
    gs = os.environ.get("GITHUB_STEP_SUMMARY")
    if gs:
        with open(gs, "a") as fh:
            fh.write("### Family SOS e2e (fcsos)\n\n| metric | value |\n|---|---|\n")
            for k, v in summary.items():
                fh.write("| %s | %s |\n" % (k, v))
            fh.write("\n%d checks, %d failed\n" % (len(RESULTS), sum(1 for r in RESULTS if not r[1])))
    failed = [r for r in RESULTS if not r[1]]
    print("%d checks, %d failed" % (len(RESULTS), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "seed":
        seed()
    else:
        sys.exit(run())
