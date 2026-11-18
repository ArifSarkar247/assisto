#!/usr/bin/env python3
"""notifproof — CLOSED-APP notification proof on the CI emulator.

Board rows 6 (Notifications) and 10 (Family SOS). Runs on the GitHub runner
next to the API-34 Google-APIs emulator (.github/workflows/notif-closed.yml):

  throw-away Django (settings_e2eproof + E2E_REAL_FCM=1: the REAL
  core/push.py FCM v1 code -> tools/e2e/mock_fcm.py, JWT verified)
  emulator: the real app (app/integration_test/notifproof_app.dart =
  lib/main.dart + a one-time sign-in of CI account A)

For every case the app process is KILLED first (home, `am kill`, then
`kill -9` as root = what a swipe-away / low-memory kill leaves: process gone,
package NOT in the stopped state). The event is triggered from the SECOND CI
account (B) through the backend API, the backend's real push code builds the
FCM v1 message and sends it to the mock FCM, and this driver hands that exact
message to the phone the way Google Play services does: a
com.google.android.c2dm.intent.RECEIVE broadcast to the app's package
(adb root, so the c2dm SEND permission check passes). From there everything
is the app's own code: Firebase SDK + FlutterFire background isolate +
flutter_local_notifications, channels, full-screen intent, routing.

Cases
  message   B -> A encrypted text (app crypto, tools/ticks_proof) -> the killed
            app decrypts ON DEVICE and shows it; tap -> that chat.
  reminder  A's reminder falls due (server job, fake clock) -> shade; tap ->
            reminders.
  sos_dnd   Do Not Disturb ON + screen OFF + app killed; B presses SOS -> full-
            screen alarm wakes the screen over the lock screen and rings
            (alarm usage, insistent, not intercepted by DND); the alarm page
            marks it SEEN on the server; delivery receipt from the killed app.
  family    B taps "I'm safe" -> family alert in the shade; tap -> the app opens
            and marks it SEEN on the server.
  alarm     (proof-notif) the phone's OWN reminder alarm, app killed: rings at
            the set minute (exact); Snooze / Done from the shade; the next
            start applies them; the snoozed one rings again in DOZE.
  reboot    (proof-notif) emulator restart: the boot receiver puts a future
            alarm back and it rings without the app being opened.

NOT proven here (stated in the proof file): Google's FCM servers carrying
the message to a real phone, and OEM battery killers (ColorOS / MIUI) that
block delivery — those need real phones (Test Lab / two-phone test).
A FORCE-STOPPED app gets no push at all on Android (any app, by design).

Writes $NP_OUT/notifproof.json + notifproof.md (+ GITHUB_STEP_SUMMARY) and
screenshots / dumps. Exit 1 unless every case passed. Never fakes a pass.
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, os.path.join(ROOT, "tools", "ticks_proof"))
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "assisto_backend.settings_e2eproof")

PKG = "com.assisto.assisto"
API = os.environ.get("NP_API", "http://127.0.0.1:8700/api/v1")
FCM = os.environ.get("NP_FCM", "http://127.0.0.1:18890")
OUT = os.environ.get("NP_OUT") or os.path.join(os.environ.get("REALITY_OUT", "/tmp"), "notifproof")
ADB = os.environ.get("ADB", "adb")
PHONE_A, PHONE_B = "01700000001", "01700000002"
PASSWORD = "Reality#2026"
NAME_B = "Reality Karim"
os.makedirs(OUT, exist_ok=True)

RESULT = {"cases": [], "setup": {}, "not_proven": [
    "Google's FCM servers delivering to a real phone (the runner has no FCM "
    "server key; the backend's real FCM v1 code is sent to a local mock FCM "
    "and that exact message is handed to the phone as the Play-services "
    "broadcast)",
    "OEM battery killers (ColorOS / MIUI / Funtouch) — real phones only "
    "(Firebase Test Lab + the owner's two-phone test)",
    "a FORCE-STOPPED app (Settings > Force stop) gets no push on Android at "
    "all, for every app — by design, not testable as a pass",
    # proof-notif (np6-np8)
    "the alarm cases run the DEBUG APK: the reboot reschedule in the R8-shrunk "
    "release build is guarded by android.yml's R8 keep-rule gate, not run here",
    "Android 14+: exact alarms are OFF for new installs until the user allows "
    "'Alarms & reminders' — the driver turns it on for np1-np9 so they "
    "measure the exact path; np10 proves the app's flow with it OFF",
]}


def log(*a):
    print("[notifproof]", *a, flush=True)


# --------------------------------------------------------------------- adb
def adb(*args, timeout=60):
    try:
        r = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
        return (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def sh(cmd, timeout=60):
    return adb("shell", cmd, timeout=timeout)


def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def save(name, text):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(text)


def shot(name):
    try:
        r = subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True, timeout=30)
        if r.stdout:
            with open(os.path.join(OUT, name + ".png"), "wb") as f:
                f.write(r.stdout)
    except Exception:
        pass


def pid():
    return sh("pidof " + PKG).strip()


def kill_app():
    """Swipe-away / low-memory kill: the process is gone, the package is NOT
    force-stopped (stopped=false), exactly like Recents -> swipe on stock
    Android. Push delivery must start the app from cold."""
    sh("input keyevent KEYCODE_HOME")
    time.sleep(2)
    sh("am kill " + PKG)
    time.sleep(1)
    p = pid()
    if p:
        sh("kill -9 " + p)
        time.sleep(1)
    gone = not pid()
    stopped = re.search(r"stopped=(true|false)", sh("dumpsys package " + PKG + " | grep -m1 stopped="))
    return gone, (stopped.group(1) if stopped else "?")


def wake_unlocked():
    sh("input keyevent KEYCODE_WAKEUP")
    time.sleep(1)
    sh("wm dismiss-keyguard")
    time.sleep(1)


def ui_dump():
    for _ in range(4):
        out = sh("uiautomator dump /sdcard/np_ui.xml >/dev/null 2>&1; cat /sdcard/np_ui.xml", timeout=60)
        i = out.find("<?xml")
        if i >= 0:
            try:
                return ET.fromstring(out[i:].strip())
            except ET.ParseError:
                pass
        time.sleep(2)
    return None


def ui_nodes(root):
    if root is None:
        return []
    return [n for n in root.iter("node")]


def ui_find(root, needle, pkg=None):
    for n in ui_nodes(root):
        if pkg and n.get("package") != pkg:
            continue
        t = (n.get("text") or "") + " | " + (n.get("content-desc") or "")
        if needle in t:
            return n
    return None


def ui_texts(root, pkg=None):
    out = []
    for n in ui_nodes(root):
        if pkg and n.get("package") != pkg:
            continue
        for k in ("text", "content-desc"):
            v = (n.get(k) or "").strip()
            if v:
                out.append(v)
    return out


def tap_node(n):
    m = re.findall(r"\d+", n.get("bounds") or "")
    if len(m) != 4:
        return False
    x1, y1, x2, y2 = map(int, m)
    sh("input tap %d %d" % ((x1 + x2) // 2, (y1 + y2) // 2))
    return True


# --------------------------------------------------------------- notifications
def notif_records():
    out = sh("dumpsys notification --noredact", timeout=90)
    head = out.split("mArchive", 1)[0]
    recs = []
    for part in re.split(r"\n\s*NotificationRecord\(", head)[1:]:
        first = part.split("\n", 1)[0]
        if "pkg=" + PKG not in first:
            continue
        key = re.search(r"key=(.*?): Notification\(", first)
        ch = re.search(r"Notification\(channel=(\S+)", first)
        fl = re.search(r"\n\s*flags=(0x[0-9a-fA-F]+)", part)
        icp = re.search(r"mIntercept=(true|false)", part)
        fsi = re.search(r"fullscreenIntent=(\S+)", part)
        recs.append({"key": key.group(1) if key else "", "channel": ch.group(1) if ch else "",
                     "flags": int(fl.group(1), 16) if fl else 0,
                     "intercept": icp.group(1) if icp else "?",
                     "fsi": bool(fsi and fsi.group(1) != "null"),
                     # proof-notif: local reminder alarms are matched by title
                     "title": (re.search(r"android\.title=\S+ \((.*?)\)\n", part) or [None, ""])[1],
                     "raw": part[:4000]})
    snd = re.search(r"mSoundNotificationKey=(\S*)", out)
    return recs, (snd.group(1) if snd else "?"), out


def wait_notif(pred, timeout=45):
    end = time.time() + timeout
    last = ([], "?", "")
    while time.time() < end:
        last = notif_records()
        for r in last[0]:
            if pred(r):
                return r, last
        time.sleep(1.5)
    return None, last


def shade_find(needle, timeout=20):
    sh("cmd statusbar expand-notifications")
    end = time.time() + timeout
    root = None
    while time.time() < end:
        time.sleep(2)
        root = ui_dump()
        n = ui_find(root, needle, pkg="com.android.systemui")
        if n is not None:
            return n, root
    return None, root


def app_shows(needles, timeout=90):
    """The app is in front and shows every needle (Flutter semantics)."""
    end = time.time() + timeout
    texts = []
    while time.time() < end:
        time.sleep(3)
        root = ui_dump()
        texts = ui_texts(root, pkg=PKG)
        blob = "\n".join(texts)
        if texts and all(n in blob for n in needles):
            return True, texts
    return False, texts


def resumed_activity():
    out = sh("dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -2")
    return out.strip()


# ------------------------------------------------------------------- FCM
def fcm_calls():
    with urllib.request.urlopen(FCM + "/calls", timeout=10) as r:
        return json.loads(r.read())["calls"]


def wait_fcm(tokens, kind, n0, timeout=30, pred=None):
    end = time.time() + timeout
    while time.time() < end:
        for m in fcm_calls()[n0:]:
            d = m.get("data") or {}
            if m.get("token") in tokens and d.get("kind") == kind and (pred is None or pred(d)):
                return m
        time.sleep(0.5)
    return None


_MSG_N = [0]


def to_extras(msg):
    """FCM v1 message -> the extras Google Play services puts on the
    c2dm RECEIVE intent (what FirebaseMessaging / FlutterFire read)."""
    _MSG_N[0] += 1
    ex = {k: str(v) for k, v in (msg.get("data") or {}).items()}
    a = msg.get("android") or {}
    pr = "high" if a.get("priority") == "HIGH" else "normal"
    ms = int(time.time() * 1000)
    ex.update({"google.delivered_priority": pr, "google.original_priority": pr,
               "google.priority": pr,
               "google.message_id": "0:%d%%np%d" % (ms, _MSG_N[0]),
               "google.sent_time": str(ms), "from": "notifproof"})
    ttl = str(a.get("ttl") or "").rstrip("s")
    if ttl.isdigit():
        ex["google.ttl"] = ttl
    if a.get("collapse_key"):
        ex["collapse_key"] = a["collapse_key"]
    n = msg.get("notification")
    if n:
        ex["gcm.n.e"] = "1"
        if n.get("title"):
            ex["gcm.notification.title"] = n["title"]
        if n.get("body"):
            ex["gcm.notification.body"] = n["body"]
        ch = (a.get("notification") or {}).get("channel_id")
        if ch:
            ex["gcm.notification.android_channel_id"] = ch
    return ex


def deliver(msg):
    ex = to_extras(msg)
    parts = ["am broadcast -p", PKG, "-a com.google.android.c2dm.intent.RECEIVE"]
    for k, v in ex.items():
        parts += ["--es", q(k), q(v)]
    out = sh(" ".join(parts), timeout=60)
    return ex, out.strip()[-300:]


# ------------------------------------------------------------------- API
class Client:
    def __init__(self, name, device):
        self.name, self.device, self.token = name, device, None

    def req(self, method, path, body=None, timeout=30):
        data = None if body is None else json.dumps(body).encode()
        r = urllib.request.Request(API + path, data=data, method=method)
        r.add_header("Content-Type", "application/json")
        r.add_header("Accept-Language", "en")
        r.add_header("X-Device-Id", self.device)   # never the app's own session
        if self.token:
            r.add_header("Authorization", "Token " + self.token)
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, {"raw": raw[:300].decode("utf-8", "replace")}

    def login(self, phone):
        st, j = self.req("POST", "/auth/login", {"identifier": phone, "password": PASSWORD})
        if st != 200 or "token" not in j:
            raise SystemExit("%s: login failed HTTP %s %s" % (self.name, st, j))
        self.token = j["token"]
        return j.get("user") or {}


# ------------------------------------------------------------------- cases
class Case:
    def __init__(self, cid, rows, what):
        self.r = {"id": cid, "board_rows": rows, "what": what, "checks": [], "status": "running"}
        RESULT["cases"].append(self.r)

    def check(self, name, ok, detail=""):
        self.r["checks"].append({"check": name, "ok": bool(ok), "detail": str(detail)[:600]})
        log(("PASS " if ok else "FAIL ") + self.r["id"] + ": " + name + ("" if ok else "  -> " + str(detail)[:300]))
        return bool(ok)

    def done(self):
        self.r["status"] = "pass" if self.r["checks"] and all(c["ok"] for c in self.r["checks"]) else "fail"


def a_tokens(A):
    from core.models import Device
    return list(Device.objects.filter(user=A).exclude(push_token="").values_list("push_token", flat=True))


def closed_precheck(c):
    gone, stopped = kill_app()
    c.check("app process killed before the event (no pid)", gone, pid())
    c.check("package not force-stopped (swipe-away state, stopped=false)", stopped == "false", stopped)
    return gone


def case_message(A, B, tokens, edge_b):
    c = Case("np1_message_closed", [6, 2], "B sends an encrypted text while A's app is killed")
    import ticks_proof as TP
    closed_precheck(c)
    st, kj = B.req("GET", "/circle/keys/peer/%d" % edge_b)
    a_pub = base64.b64decode(kj.get("public_key") or "") if st == 200 else b""
    if not c.check("A's E2E public key on the server (published by the app at sign-in)", len(a_pub) == 32, kj):
        return c.done()
    kb = TP.Identity()
    B.req("POST", "/circle/keys", {"public_key": base64.b64encode(kb.pub).decode(),
                                   "key_id": kb.kid, "scheme": TP.SCHEME})
    text = "notifproof msg %d" % (int(time.time()) % 100000)
    env = TP.encrypt(kb, a_pub, text)
    env.update(content_type="text", client_msg_id="np-%d" % int(time.time() * 1000))
    n0 = len(fcm_calls())
    t0 = time.time()
    st, j = B.req("POST", "/circle/%d/messages" % edge_b, env)
    c.check("B's message accepted by the server (201)", st == 201, (st, j))
    m = wait_fcm(tokens, "message", n0)
    if not c.check("backend sent a data-only high-priority FCM 'message' to A's device", m is not None
                   and not m.get("notification") and (m.get("android") or {}).get("priority") == "HIGH", m):
        return c.done()
    c.check("the push carries no plaintext (server never sees the text)", text not in json.dumps(m, ensure_ascii=False), "")
    ex, out = deliver(m)
    c.r["broadcast"] = out
    t_inj = time.time()
    rec, _ = wait_notif(lambda r: r["channel"] in ("chat_msg_v2", "messages"), timeout=60)
    c.check("a message notification is on screen (chat channel)", rec is not None, [r["channel"] for r in notif_records()[0]])
    if rec is not None:
        c.r["inject_to_notification_ms"] = int((time.time() - t_inj) * 1000)
    wake_unlocked()
    node, root = shade_find(text, timeout=25)
    shot("np1_shade")
    c.check("the shade shows the DECRYPTED text (decrypted on the phone while closed)", node is not None,
            ui_texts(root, pkg="com.android.systemui")[:30])
    if node is None:
        node, _ = shade_find(NAME_B, timeout=8)
    if node is None or not tap_node(node):
        c.check("tap the notification", False, "no node to tap")
        sh("cmd statusbar collapse")
        return c.done()
    ok, texts = app_shows([text])
    shot("np1_after_tap")
    c.check("tap opens THAT chat (the message text is on screen)", ok, texts[:40])
    c.r["resumed"] = resumed_activity()
    return c.done()


def case_reminder(A, Ah, tokens):
    c = Case("np2_reminder_closed", [6, 13], "A's reminder falls due while the app is killed")
    closed_precheck(c)
    from django.utils import timezone
    from datetime import timedelta
    title = "notifproof medicine %d" % (int(time.time()) % 100000)
    due = (timezone.now() + timedelta(minutes=2)).isoformat()
    st, j = Ah.req("POST", "/reminders/", {"title": title, "due_at": due})
    if st == 404:
        st, j = Ah.req("POST", "/reminders", {"title": title, "due_at": due})
    c.check("reminder saved on the server", st in (200, 201), (st, j))
    n0 = len(fcm_calls())
    st, tj = Ah.req("POST", "/ci-e2e/tick", {"job": "push_due_reminders", "advance_min": 3})
    c.check("server reminder job ran (fake clock +3 min)", st == 200 and tj.get("ok"), (st, tj))
    m = wait_fcm(tokens, "reminder", n0, pred=lambda d: title in (d.get("title", "") + d.get("body", "")))
    if m is None:
        m = wait_fcm(tokens, "reminder", n0, timeout=5)
    # remmeter: the reminder push is DATA-ONLY + high priority — the app's own
    # background isolate draws it (and stays silent when its local alarm rang)
    if not c.check("backend sent a high-priority FCM 'reminder' (reminders channel, app draws it)",
                   m is not None and (m.get("data") or {}).get("channel") == "reminders"
                   and (m.get("android") or {}).get("priority") == "HIGH", m):
        return c.done()
    ex, out = deliver(m)
    c.r["broadcast"] = out
    t_inj = time.time()
    rec, _ = wait_notif(lambda r: r["channel"] == "reminders", timeout=45)
    c.check("the reminder notification is shown on the 'reminders' channel", rec is not None,
            [r["channel"] for r in notif_records()[0]])
    if rec is not None:
        c.r["inject_to_notification_ms"] = int((time.time() - t_inj) * 1000)
    wake_unlocked()
    node, root = shade_find(title, timeout=25)
    shot("np2_shade")
    c.check("the shade shows the reminder title", node is not None, ui_texts(root, pkg="com.android.systemui")[:30])
    if node is None or not tap_node(node):
        sh("cmd statusbar collapse")
        return c.done()
    ok, texts = app_shows([title])
    shot("np2_after_tap")
    c.check("tap opens the reminders screen with that reminder", ok, texts[:40])
    return c.done()


def _delivery(A, kind, t0):
    from django.db import close_old_connections
    from django.utils import timezone
    from datetime import datetime, timezone as dtz
    from core.models import FamilyAlertDelivery
    close_old_connections()
    since = datetime.fromtimestamp(t0 - 5, tz=dtz.utc)
    return (FamilyAlertDelivery.objects.filter(recipient=A, kind=kind, created_at__gte=since)
            .order_by("-created_at").first())


def wait_delivery_field(A, kind, t0, field, timeout=60):
    end = time.time() + timeout
    d = None
    while time.time() < end:
        d = _delivery(A, kind, t0)
        if d is not None and getattr(d, field, None) is not None:
            return d
        time.sleep(2)
    return None


def case_sos(A, B, tokens):
    c = Case("np3_sos_dnd_closed", [10, 6],
             "B presses SOS; A's phone: app killed, screen off, Do Not Disturb ON")
    closed_precheck(c)
    # `set_dnd on` gave zen_mode=2 (TOTAL silence) on API 33 (run
    # 43996012933): there Android blocks every sound, alarms included, for
    # every app. The normal DND a user switches on is "priority only" (1).
    sh("cmd notification set_dnd priority")
    time.sleep(1)
    zen = sh("settings get global zen_mode").strip()
    c.check("Do Not Disturb is ON (zen_mode=1, priority only — the phone's normal DND)", zen == "1", zen)
    sh("input keyevent KEYCODE_SLEEP")
    time.sleep(3)
    wk = sh("dumpsys power | grep mWakefulness= | head -1").strip()
    c.check("screen is OFF before the SOS", "Awake" not in wk, wk)
    if pid():
        kill_app()
        sh("input keyevent KEYCODE_SLEEP")
        time.sleep(2)
    c.check("app still killed with the screen off", not pid(), pid())
    n0 = len(fcm_calls())
    t0 = time.time()
    st, j = B.req("POST", "/family/sos", {"lat": 23.7461, "lng": 90.3742, "source": "notifproof",
                                          "client_id": "np-%d" % int(t0 * 1000)})
    c.check("B's SOS accepted, A addressed", st == 200 and int(j.get("sent") or 0) >= 1, (st, j))
    m = wait_fcm(tokens, "sos", n0)
    if not c.check("backend sent a data-only HIGH-priority FCM 'sos' to A", m is not None and not m.get("notification")
                   and (m.get("android") or {}).get("priority") == "HIGH", m):
        sh("cmd notification set_dnd off")
        return c.done()
    ex, out = deliver(m)
    c.r["broadcast"] = out
    t_inj = time.time()
    rec, (recs, snd, raw) = wait_notif(lambda r: r["channel"] in ("sos", "sos_dnd_v1"), timeout=60)
    save("np3_dumpsys_notification.txt", raw)
    c.check("SOS notification posted on the SOS channel", rec is not None, [r["channel"] for r in recs])
    if rec is not None:
        c.r["inject_to_notification_ms"] = int((time.time() - t_inj) * 1000)
        c.r["sos_record"] = {k: rec[k] for k in ("key", "channel", "flags", "intercept", "fsi")}
        c.check("it carries a FULL-SCREEN intent", rec["fsi"], rec["raw"][:400])
        c.check("Do Not Disturb did NOT intercept it (mIntercept=false)", rec["intercept"] == "false", rec["intercept"])
        c.check("insistent alarm (keeps ringing, FLAG_INSISTENT)", bool(rec["flags"] & 0x4), hex(rec["flags"]))
        snd_now = notif_records()[1]
        c.check("the system is PLAYING its sound (mSoundNotificationKey = the SOS)", rec["key"] and
                (snd == rec["key"] or snd_now == rec["key"]), "sound=%s / %s key=%s" % (snd, snd_now, rec["key"]))
    au = sh("dumpsys audio | grep -iE 'USAGE_ALARM' | head -8")
    save("np3_dumpsys_audio.txt", au)
    c.r["audio_alarm_players"] = au.strip()[:600]
    time.sleep(4)
    wk = sh("dumpsys power | grep mWakefulness= | head -1").strip()
    c.check("the full-screen alarm WOKE the screen", "Awake" in wk, wk)
    ra = resumed_activity()
    c.r["resumed"] = ra
    c.check("Assisto's alarm activity is in front over the lock screen", PKG in ra, ra)
    ok, texts = app_shows([NAME_B], timeout=90)
    shot("np3_fullscreen_alarm")
    c.check("the SOS alarm page shows who needs help", ok, texts[:40])
    d = wait_delivery_field(A, "sos", t0, "received_at", timeout=30)
    c.check("delivery receipt sent by the KILLED app's background isolate (received_at)", d is not None, "")
    d = wait_delivery_field(A, "sos", t0, "seen_at", timeout=60)
    c.check("the alarm page marked it SEEN on the server (B sees 'seen')", d is not None, "")
    sh("cmd notification set_dnd off")
    return c.done()


def case_family(A, B, tokens):
    c = Case("np4_family_alert_closed", [10, 6], "B taps 'I'm safe' while A's app is killed")
    wake_unlocked()
    closed_precheck(c)
    n0 = len(fcm_calls())
    t0 = time.time()
    st, j = B.req("POST", "/family/sos/resolve", {"reason": "safe"})
    c.check("B's 'I'm safe' accepted", st == 200, (st, j))
    m = wait_fcm(tokens, "family_alert", n0)
    if not c.check("backend sent the FCM 'family_alert' (notification, alerts channel)", m is not None
                   and m.get("notification"), m):
        return c.done()
    ex, out = deliver(m)
    c.r["broadcast"] = out
    t_inj = time.time()
    rec, _ = wait_notif(lambda r: r["channel"] == "alerts" and "FCM" in r["key"], timeout=45)
    if rec is None:
        rec, _ = wait_notif(lambda r: r["channel"] == "alerts", timeout=10)
    c.check("the family alert notification is shown (alerts channel)", rec is not None,
            [r["channel"] for r in notif_records()[0]])
    if rec is not None:
        c.r["inject_to_notification_ms"] = int((time.time() - t_inj) * 1000)
    title = (m.get("notification") or {}).get("title") or NAME_B
    wake_unlocked()
    node, root = shade_find(title[:30], timeout=25)
    shot("np4_shade")
    c.check("the shade shows the family alert", node is not None, ui_texts(root, pkg="com.android.systemui")[:30])
    if node is None or not tap_node(node):
        sh("cmd statusbar collapse")
        return c.done()
    time.sleep(3)
    ra = resumed_activity()
    c.r["resumed"] = ra
    c.check("tap opens Assisto", PKG in ra, ra)
    d = wait_delivery_field(A, "sos_resolved", t0, "seen_at", timeout=90)
    shot("np4_after_tap")
    c.check("the tap marked THAT alert SEEN on the server (the app routed the payload)", d is not None, "")
    ok, texts = app_shows([NAME_B], timeout=30)
    c.check("the screen names who sent it", ok, texts[:40])
    return c.done()


# ------------------------------------------------------------------- main
def setup():
    import django
    django.setup()
    from core.models import CircleMember, Device, User
    from core import e2_keys
    from core.phone import find_user
    A, Bu = find_user(PHONE_A), find_user(PHONE_B)
    s = RESULT["setup"]
    log("root:", adb("root").strip())
    time.sleep(3)
    adb("wait-for-device", timeout=120)
    apk = os.environ["NP_APK"]
    s["install"] = adb("install", "-r", "-g", apk, timeout=300).strip()[-200:]
    sh("appops set %s USE_FULL_SCREEN_INTENT allow" % PKG)
    # notif-nine: API 34 new install = exact alarms OFF; on for np1-np9 (np10
    # turns it off again and proves the app's explainer -> Settings -> re-arm)
    sh("appops set %s SCHEDULE_EXACT_ALARM allow" % PKG)
    s["exact_alarm_default"] = "API 34 new install: off; driver: allow for np1-np9"
    sh("cmd notification set_dnd off")
    sh("svc power stayon false")
    sh("settings put system screen_off_timeout 600000")
    wake_unlocked()
    adb("logcat", "-c")
    t0 = time.time()
    sh("am start -W -n %s/.MainActivity" % PKG, timeout=120)
    tok, key = None, None
    end = time.time() + 240
    while time.time() < end:
        from django.db import close_old_connections
        close_old_connections()
        tok = Device.objects.filter(user=A).exclude(push_token="").order_by("-last_seen", "-id").first()
        key = e2_keys.key_row(A)
        if tok is not None and key is not None:
            break
        time.sleep(5)
    s["sign_in_s"] = round(time.time() - t0, 1)
    shot("np0_home")
    lc = adb("logcat", "-d", "-s", "flutter:I", timeout=60)
    s["login_log"] = [ln for ln in lc.splitlines() if "NOTIFPROOF_LOGIN" in ln][-2:]
    s["e2e_key_published"] = key is not None
    if tok is None:
        # honest fallback: the app got no FCM token (Play services on the
        # runner could not register). The proof still runs the SAME delivery,
        # addressed to a synthetic token, and says so.
        Device.objects.get_or_create(user=A, push_token="notifproof-synthetic-token")
        s["fcm_token"] = "synthetic (the emulator's Play services returned no FCM token)"
    else:
        s["fcm_token"] = "real FCM registration token from the app (%d chars%s)" % (
            len(tok.push_token), ", APA91 format" if ":APA91" in tok.push_token else "")
        s["app_version"] = tok.app_version
    tokens = a_tokens(A)
    eb = CircleMember.objects.filter(user=Bu, peer_user=A).first()
    log("setup:", json.dumps(s))
    return A, Bu, tokens, eb.id if eb else None


# ------------------------------------------------------- local reminder alarms
# proof-notif (board rows 13 + 6): the phone's OWN reminder alarm (no push at
# all — the server reminder job never runs here) with the app process KILLED:
#   np6  rings at the set minute (exact alarm); Snooze + Done buttons work
#        from the shade with the app closed (background isolate); the next
#        app start applies them (server: Done = done, Snooze = +10 min)
#   np7  Doze (screen off, unplugged, `deviceidle force-idle`): the snoozed
#        reminder still rings while the phone stays in deep idle
#   np8  emulator REBOOT: a future reminder is put back by the boot receiver
#        and rings without the app ever being opened after the reboot
REM_CH = "assisto_reminders"
BTN_DONE = ("Done", "হয়ে গেছে")
BTN_SNOOZE = ("Snooze 10 min", "১০ মিনিট পরে")


def _next_minute(after_s):
    t = time.time() + after_s
    return int(t // 60 + 1) * 60


def _iso(ts):
    from datetime import datetime, timezone as dtz
    return datetime.fromtimestamp(ts, dtz.utc).isoformat()


def make_reminder(Ah, title, due_ts):
    st, j = Ah.req("POST", "/reminders/", {"title": title, "due_at": _iso(due_ts)})
    return st, j


def reminder_row(rid):
    from django.db import close_old_connections
    from core.models import Reminder
    close_old_connections()
    return Reminder.objects.filter(id=rid).first()


def alarm_entries():
    """Our pending flutter_local_notifications alarms from `dumpsys alarm`
    (tag ...ScheduledNotificationReceiver): when (epoch ms), window, flags."""
    out = sh("dumpsys alarm", timeout=90)
    lines = out.splitlines()
    hdr = re.compile(r"^\s*(RTC_WAKEUP|RTC|ELAPSED_WAKEUP|ELAPSED) #\d+: Alarm\{\S+ type (\d+) origWhen (-?\d+)")
    res = []
    for i, ln in enumerate(lines):
        m = hdr.match(ln)
        if not m or PKG not in ln:
            continue
        blk = "\n".join(lines[i:i + 12])
        nxt = [k for k in range(i + 1, min(i + 12, len(lines))) if hdr.match(lines[k])]
        if nxt:
            blk = "\n".join(lines[i:nxt[0]])
        if "ScheduledNotificationReceiver" not in blk:
            continue
        w = re.search(r"window=(-?\d+)", blk)
        fl = re.search(r"flags=(0x[0-9a-fA-F]+)", blk)
        ex = re.search(r"exactAllowReason=(\S+)", blk)
        res.append({"type": m.group(1), "when_ms": int(m.group(3)),
                    "window": int(w.group(1)) if w else None,
                    "flags": fl.group(1) if fl else "?",
                    "exact_reason": ex.group(1) if ex else "?",
                    "alarm_clock": "alarmClock" in blk or "AlarmClockInfo" in blk})
    return res, out


def wait_alarm_at(ts, timeout=90, tol_s=2):
    end = time.time() + timeout
    last = ([], "")
    while time.time() < end:
        last = alarm_entries()
        for a in last[0]:
            if a["type"].startswith("RTC") and abs(a["when_ms"] / 1000.0 - ts) <= tol_s:
                return a, last
        time.sleep(4)
    return None, last


def is_exact(a):
    return a is not None and (a["window"] == 0 or a["alarm_clock"])


def _rem_rec(title):
    for r in notif_records()[0]:
        if r["channel"] == REM_CH and (r["title"] == title or title in r["raw"]):
            return r
    return None


def wait_ring(title, due_ts, late_s=75, idle_probe=False):
    """Poll the shade until the reminder is posted; returns (seen_ts, rec,
    deep-idle state right after it was seen)."""
    end = due_ts + late_s
    while time.time() < end:
        r = _rem_rec(title)
        if r is not None:
            seen = time.time()
            st = sh("dumpsys deviceidle get deep").strip() if idle_probe else ""
            return seen, r, st
        time.sleep(1.0 if time.time() > due_ts - 3 else 3.0)
    return None, None, ""


def open_app(wait_s=30, cold=False):
    # cold: the reminder list syncs on app START / resume — a reminder made
    # on the server while the app sits in front is not fetched until then
    if cold:
        kill_app()
    wake_unlocked()
    sh("am start -W -n %s/.MainActivity" % PKG, timeout=120)
    time.sleep(wait_s)


def stash_old_notifications():
    """Old Assisto notifications (earlier cases) are snoozed away so the
    reminder is the first, expanded row in the shade (its buttons visible)."""
    n = 0
    for r in notif_records()[0]:
        if r["key"] and r["channel"] != REM_CH:
            sh("cmd notification snooze --for 36000000 %s" % q(r["key"]))
            n += 1
    return n


def tap_action(title, labels, timeout=25):
    """Expand the shade, find the reminder row and tap one of its buttons."""
    sh("cmd statusbar expand-notifications")
    end = time.time() + timeout
    root = None
    tried_expand = False
    while time.time() < end:
        time.sleep(2)
        root = ui_dump()
        for lb in labels:
            n = ui_find(root, lb, pkg="com.android.systemui")
            if n is not None:
                return lb, tap_node(n), root
        row = ui_find(root, title, pkg="com.android.systemui")
        if row is not None and not tried_expand:
            # a collapsed row: swipe down on it to show its buttons
            m = re.findall(r"\d+", row.get("bounds") or "")
            if len(m) == 4:
                x1, y1, x2, y2 = map(int, m)
                x, y = (x1 + x2) // 2, (y1 + y2) // 2
                sh("input swipe %d %d %d %d 300" % (x, y, x, y + 350))
            tried_expand = True
    return None, False, root


def case_alarm_ring_actions(A, Ah):
    c = Case("np6_alarm_closed_actions", [13, 6],
             "the phone's own reminder alarm rings at the set minute with the app killed; Snooze / Done from the shade")
    tag = int(time.time()) % 100000
    t1, t2 = "notifproof pill %d" % tag, "notifproof water %d" % tag
    due1 = _next_minute(150)
    due2 = due1 + 60
    c.r["exact_alarm_appop"] = sh("appops get %s SCHEDULE_EXACT_ALARM" % PKG).strip()[:200]
    st1, j1 = make_reminder(Ah, t1, due1)
    st2, j2 = make_reminder(Ah, t2, due2)
    c.check("two reminders saved on the server (no server job runs: only the phone can ring)",
            st1 in (200, 201) and st2 in (200, 201), (st1, j1, st2, j2))
    r1, r2 = j1.get("id"), j2.get("id")
    open_app(25, cold=True)
    a1, (_, adump) = wait_alarm_at(due1, timeout=90)
    save("np6_alarm_dump_before.txt", adump)
    c.check("the app set a phone alarm for reminder 1 at its exact minute", a1 is not None,
            alarm_entries()[0][:6])
    c.r["alarm1"] = a1
    c.check("it is an EXACT alarm (window=0 / alarm clock), not an inexact batch", is_exact(a1), a1)
    a2, _ = wait_alarm_at(due2, timeout=30)
    c.check("the app set a phone alarm for reminder 2", a2 is not None, "")
    closed_precheck(c)
    stash_old_notifications()
    wake_unlocked()
    # ---- reminder 1 rings with the app killed
    seen, rec, _ = wait_ring(t1, due1)
    shot("np6_ring1")
    c.r["ring1_late_s"] = None if seen is None else round(seen - due1, 1)
    c.check("reminder 1 RANG (posted on the reminders channel) with the app killed", rec is not None,
            [(r["channel"], r["title"]) for r in notif_records()[0]])
    if rec is None:
        return c.done(), None
    c.check("at the set minute (posted 0-60 s after the due time)", -2 <= seen - due1 <= 60, c.r["ring1_late_s"])
    # ---- Snooze 10 min from the shade (app stays closed)
    lb, ok, root = tap_action(t1, BTN_SNOOZE)
    t_snz = time.time()
    shot("np6_after_snooze")
    c.check("the shade shows a 'Snooze 10 min' button and it was tapped", ok,
            ui_texts(root, pkg="com.android.systemui")[:30])
    time.sleep(6)
    sh("cmd statusbar collapse")
    c.check("Snooze dismissed the reminder", _rem_rec(t1) is None, "")
    snz, (_, sdump) = wait_alarm_at(t_snz + 600, timeout=40, tol_s=20)
    save("np6_alarm_dump_snooze.txt", sdump)
    c.r["snooze_alarm"] = snz
    c.check("Snooze set a new phone alarm 10 minutes later (app still closed)", snz is not None,
            alarm_entries()[0][:6])
    c.check("Snooze did NOT open the app", PKG not in resumed_activity(), resumed_activity())
    # ---- reminder 2 rings; Done from the shade
    seen2, rec2, _ = wait_ring(t2, due2)
    shot("np6_ring2")
    c.r["ring2_late_s"] = None if seen2 is None else round(seen2 - due2, 1)
    c.check("reminder 2 rang at its minute too", rec2 is not None and -2 <= seen2 - due2 <= 60, c.r["ring2_late_s"])
    if rec2 is not None:
        lb, ok, root = tap_action(t2, BTN_DONE)
        shot("np6_after_done")
        c.check("the shade shows a 'Done' button and it was tapped", ok,
                ui_texts(root, pkg="com.android.systemui")[:30])
        time.sleep(6)
        sh("cmd statusbar collapse")
        c.check("Done dismissed reminder 2", _rem_rec(t2) is None, "")
        # notif-nine: Done on a one-off reaches the server with the app CLOSED
        end_d = time.time() + 30
        d2c = None
        while time.time() < end_d:
            d2c = reminder_row(r2)
            if d2c is not None and d2c.done:
                break
            time.sleep(3)
        c.check("'Done' reached the server with the app still CLOSED (no app start)",
                d2c is not None and d2c.done and PKG not in resumed_activity(),
                d2c and d2c.done)
    # ---- the next app start applies both buttons
    open_app(10)
    end = time.time() + 90
    d1 = d2 = None
    while time.time() < end:
        d1, d2 = reminder_row(r1), reminder_row(r2)
        if d2 is not None and d2.done and d1 is not None and d1.due_at \
                and d1.due_at.timestamp() > due1 + 300:
            break
        time.sleep(4)
    c.check("next app start: 'Done' reached the server (reminder 2 done)", d2 is not None and d2.done,
            d2 and (d2.done, d2.due_at))
    c.check("next app start: 'Snooze' moved reminder 1 by 10 minutes on the server",
            d1 is not None and d1.due_at is not None and abs(d1.due_at.timestamp() - (t_snz + 600)) < 90,
            d1 and str(d1.due_at))
    # the race fixed in reminder_alarms.dart (SerialRerun): after the start-up
    # reconcile the snoozed reminder must STILL have its alarm
    time.sleep(8)
    snz_at = d1.due_at.timestamp() if d1 is not None and d1.due_at else t_snz + 600
    a_after, (_, adump2) = wait_alarm_at(snz_at, timeout=40, tol_s=60)
    save("np6_alarm_dump_after_open.txt", adump2)
    c.check("after the app applied Snooze, reminder 1 still has its phone alarm (+10 min)",
            a_after is not None, alarm_entries()[0][:6])
    c.done()
    return c, (t1, a_after["when_ms"] / 1000.0 if a_after else snz_at)


def case_alarm_doze(snoozed):
    c = Case("np7_alarm_doze", [13, 6], "the snoozed reminder rings while the phone is in Doze (deep idle), app killed")
    if not snoozed:
        c.check("needs the snoozed reminder from np6", False, "np6 did not leave a snoozed alarm")
        return c.done()
    title, at = snoozed
    closed_precheck(c)
    if at - time.time() < 45:
        c.check("enough time left to enter Doze before the alarm", False, round(at - time.time()))
        return c.done()
    sh("input keyevent KEYCODE_SLEEP")
    time.sleep(2)
    sh("dumpsys battery unplug")
    out = sh("dumpsys deviceidle force-idle")
    time.sleep(3)
    st = sh("dumpsys deviceidle get deep").strip()
    c.r["force_idle"] = out.strip()[:200]
    c.check("phone in Doze (deep state IDLE, screen off, unplugged) before the alarm", st == "IDLE", st)
    seen, rec, st_after = wait_ring(title, at, late_s=90, idle_probe=True)
    c.r["late_s"] = None if seen is None else round(seen - at, 1)
    c.r["deep_state_at_ring"] = st_after
    c.check("the reminder RANG in Doze (posted, app killed)", rec is not None,
            [(r["channel"], r["title"]) for r in notif_records()[0]])
    if rec is not None:
        c.check("on time in Doze (0-60 s after its minute)", -2 <= seen - at <= 60, c.r["late_s"])
        c.check("the phone was still in deep idle when it rang (alarm allowed while idle)",
                st_after == "IDLE", st_after)
    sh("dumpsys deviceidle unforce")
    sh("dumpsys battery reset")
    wake_unlocked()
    shot("np7_after_doze")
    if rec is not None:
        sh("cmd notification snooze --for 36000000 %s" % q(rec["key"]))
    return c.done()


def _wait_boot(timeout=420):
    adb("wait-for-device", timeout=timeout)
    end = time.time() + timeout
    while time.time() < end:
        if sh("getprop sys.boot_completed", timeout=20).strip() == "1":
            return True
        time.sleep(5)
    return False


def case_alarm_reboot(A, Ah):
    c = Case("np8_alarm_after_reboot", [13], "a future reminder still rings after the phone restarts (app never opened)")
    title = "notifproof after reboot %d" % (int(time.time()) % 100000)
    due = _next_minute(420)
    st, j = make_reminder(Ah, title, due)
    c.check("reminder saved on the server", st in (200, 201), (st, j))
    open_app(25, cold=True)
    a, _ = wait_alarm_at(due, timeout=90)
    c.check("phone alarm set before the restart", a is not None, alarm_entries()[0][:6])
    closed_precheck(c)
    t0 = time.time()
    adb("reboot", timeout=60)
    booted = _wait_boot()
    c.r["reboot_s"] = round(time.time() - t0)
    c.check("emulator rebooted and finished booting", booted, c.r["reboot_s"])
    log("root after reboot:", adb("root").strip())
    time.sleep(4)
    adb("wait-for-device", timeout=120)
    if not c.check("the reboot finished before the reminder's minute", time.time() < due - 20,
                   round(due - time.time())):
        return c.done()
    up = sh("cat /proc/uptime").split()
    c.r["uptime_s"] = up[0] if up else "?"
    time.sleep(20)  # BOOT_COMPLETED -> ScheduledNotificationBootReceiver
    a2, (_, dump) = wait_alarm_at(due, timeout=120)
    save("np8_alarm_dump_after_boot.txt", dump)
    c.r["alarm_after_boot"] = a2
    c.check("the boot receiver put the alarm back after the restart (app not opened)", a2 is not None,
            alarm_entries()[0][:6])
    c.check("still exact after the restart", is_exact(a2), a2)
    c.r["resumed_before_ring"] = resumed_activity()
    c.check("Assisto was never opened after the restart", PKG not in c.r["resumed_before_ring"],
            c.r["resumed_before_ring"])
    wake_unlocked()
    seen, rec, _ = wait_ring(title, due)
    shot("np8_ring_after_reboot")
    c.r["late_s"] = None if seen is None else round(seen - due, 1)
    c.check("the reminder RANG after the restart", rec is not None,
            [(r["channel"], r["title"]) for r in notif_records()[0]])
    if rec is not None:
        c.check("at its minute (0-60 s)", -2 <= seen - due <= 60, c.r["late_s"])
    return c.done()


def case_alarm_made_while_open(A, Ah, Bu, B, tokens):
    """proof-notif (app fix, reminder_freshness.dart): a reminder made
    ELSEWHERE while A's app is OPEN in front gets its phone alarm without a
    restart — (1) a family member's task (push -> foreground handler ->
    list sync), (2) a reminder made on the server + A comes back to the app
    (resume sync) — and then rings with the app killed."""
    c = Case("np9_alarm_made_while_open", [13, 6],
             "reminders made elsewhere while A's app is in front get a phone alarm without a restart")
    from core.models import FamilyMember
    from core import famcare as FC
    open_app(30, cold=True)
    p0 = pid()
    c.check("app open in front (one process)", bool(p0) and PKG in resumed_activity(), resumed_activity())
    fm = None
    for f in FamilyMember.objects.filter(user=Bu):
        u = FC.linked_user(f)
        if u is not None and u.pk == A.pk:
            fm = f
            break
    if fm is None:
        # the CI seed links A and B in My Circle only; B adds A to B's family
        # list through that Circle link (what "Add from My Circle" saves) —
        # throw-away CI database, seed accounts only
        from core.models import CircleMember
        edge = CircleMember.objects.filter(user=Bu, peer_user=A).first()
        if edge is not None:
            f = FamilyMember.objects.create(user=Bu, name="Reality A", relation="mother",
                                            circle_member=edge)
            u = FC.linked_user(f)
            fm = f if (u is not None and u.pk == A.pk) else None
            c.r["family_link"] = "created from the Circle link" if fm else "Circle link not accepted"
    tag = int(time.time()) % 100000
    t1, t2 = "notifproof family task %d" % tag, "notifproof web reminder %d" % tag
    due1 = _next_minute(170)
    due2 = due1 + 60
    t_open = time.time()
    if c.check("B and A are family (B can give A a task)", fm is not None, ""):
        n0 = len(fcm_calls())
        st, j = B.req("POST", "/family/reminders", {"member_id": fm.id, "title": t1, "due_at": _iso(due1)})
        c.check("B gave A a task with a time (server)", st == 201, (st, j))
        m = wait_fcm(tokens, "family_task", n0, timeout=20) or wait_fcm(tokens, "reminder", n0, timeout=10)
        if c.check("backend pushed it to A's phone", m is not None, ""):
            ex, out = deliver(m)
            c.r["broadcast"] = out
            t_open = time.time()   # the push sync starts the resume throttle
        a1, _ = wait_alarm_at(due1, timeout=60)
        c.r["alarm1"] = a1
        c.check("A's phone alarm for the task was set WHILE the app stayed open (no restart)",
                a1 is not None and pid() == p0, (a1, pid(), p0))
    # the resume sync is throttled to one per 30 s (the push above synced)
    time.sleep(max(0, t_open + 40 - time.time()))
    st, j = Ah.req("POST", "/reminders/", {"title": t2, "due_at": _iso(due2)})
    c.check("a reminder made on the server (e.g. AI chat on another device / website)", st in (200, 201), (st, j))
    sh("input keyevent KEYCODE_HOME")
    time.sleep(4)
    sh("am start -n %s/.MainActivity" % PKG)   # back to the app: resume, same process
    a2, (_, dump) = wait_alarm_at(due2, timeout=60)
    save("np9_alarm_dump.txt", dump)
    c.check("coming back to the app set its phone alarm (resume sync, no restart)",
            a2 is not None and pid() == p0, (a2, pid(), p0))
    closed_precheck(c)
    if fm is not None:
        seen, rec, _ = wait_ring(t1, due1)
        shot("np9_ring_task")
        c.check("the family task RANG at its minute with the app killed",
                rec is not None and -2 <= seen - due1 <= 60, None if seen is None else round(seen - due1, 1))
    seen, rec, _ = wait_ring(t2, due2)
    c.check("the server-made reminder RANG at its minute with the app killed",
            rec is not None and -2 <= seen - due2 <= 60, None if seen is None else round(seen - due2, 1))
    return c.done()


# ------------------------------------------------------- notif-nine cases
EXACT_TITLE = ("রিমাইন্ডার কি ঠিক মিনিটে বাজবে?", "Ring reminders on the exact minute?")
EXACT_ALLOW = ("অনুমতি দিন", "Allow")


def _app_find(labels, timeout=60):
    end = time.time() + timeout
    root = None
    while time.time() < end:
        root = ui_dump()
        for lb in labels:
            n = ui_find(root, lb, pkg=PKG)
            if n is not None:
                return n, root
        time.sleep(3)
    return None, root


def case_exact_off(A, Ah):
    """notif-nine (row 13): Android 14 — exact alarms OFF (the default for a
    new install). The reminder still gets a phone alarm (honest inexact),
    the app explains, "Allow" opens Android's "Alarms & reminders" page, the
    user turns it on and comes back -> the app re-arms it EXACT -> it rings
    on its minute with the app killed."""
    c = Case("np10_exact_off_android14", [13],
             "Android 14 exact alarms OFF: explainer -> Alarms & reminders -> re-armed exact -> rings closed")
    kill_app()
    sh("appops set %s SCHEDULE_EXACT_ALARM default" % PKG)
    sh("appops set %s SCHEDULE_EXACT_ALARM deny" % PKG)
    time.sleep(2)
    c.r["appop_off"] = sh("appops get %s SCHEDULE_EXACT_ALARM" % PKG).strip()[:160]
    c.check("exact alarms are OFF for Assisto (Android 14 new-install state)",
            "deny" in c.r["appop_off"] or "ignore" in c.r["appop_off"], c.r["appop_off"])
    title = "notifproof exact off %d" % (int(time.time()) % 100000)
    due = _next_minute(300)
    st, j = make_reminder(Ah, title, due)
    c.check("reminder saved on the server", st in (200, 201), (st, j))
    open_app(15, cold=True)
    a0, _ = wait_alarm_at(due, timeout=60, tol_s=5)
    c.r["alarm_off"] = a0
    c.check("with exact alarms OFF the reminder still gets a phone alarm (fallback)", a0 is not None,
            alarm_entries()[0][:6])
    c.check("... honestly INEXACT (Android may batch it a few minutes)", a0 is not None and not is_exact(a0), a0)
    node, root = _app_find(EXACT_TITLE, timeout=45)
    shot("np10_explainer")
    if not c.check("the app explains why exact alarms matter (one sheet)", node is not None,
                   ui_texts(root, pkg=PKG)[:30]):
        return c.done()
    btn, _ = _app_find(EXACT_ALLOW, timeout=10)
    c.check("the sheet has an 'Allow' button", btn is not None, "")
    if btn is None:
        return c.done()
    tap_node(btn)
    time.sleep(5)
    ra = resumed_activity()
    shot("np10_alarms_reminders_page")
    c.r["settings_activity"] = ra
    c.check("'Allow' opened Android's 'Alarms & reminders' page for Assisto",
            "com.android.settings" in ra, ra)
    # the user turns it on: tap the page's switch (fallback: the same appop)
    root = ui_dump()
    sw = None
    for n in ui_nodes(root):
        if n.get("class", "").endswith("Switch") or n.get("checkable") == "true":
            sw = n
            break
    if sw is not None:
        tap_node(sw)
        time.sleep(2)
    if "allow" not in sh("appops get %s SCHEDULE_EXACT_ALARM" % PKG):
        sh("appops set %s SCHEDULE_EXACT_ALARM allow" % PKG)
        c.r["toggle"] = "appops fallback (switch not found on this Settings build)"
    else:
        c.r["toggle"] = "the page's switch"
    sh("input keyevent KEYCODE_BACK")
    time.sleep(6)
    c.check("back in Assisto after the Settings page", PKG in resumed_activity(), resumed_activity())
    a1, (_, dump) = wait_alarm_at(due, timeout=60, tol_s=2)
    save("np10_alarm_dump_after_allow.txt", dump)
    c.r["alarm_after"] = a1
    c.check("on return the app RE-ARMED the reminder EXACT (no restart)", is_exact(a1), a1)
    closed_precheck(c)
    wake_unlocked()
    seen, rec, _ = wait_ring(title, due)
    shot("np10_ring")
    c.check("it rang at its minute with the app killed",
            rec is not None and -2 <= seen - due <= 60, None if seen is None else round(seen - due, 1))
    return c.done()


def _stash_all():
    for r in notif_records()[0]:
        if r["key"]:
            sh("cmd notification snooze --for 36000000 %s" % q(r["key"]))


def case_shade_shots(A, B, Ah, tokens, edge_b):
    """notif-nine (row 6): the shade itself in Bangla and in English — two
    My Circle messages in ONE conversation (MessagingStyle lines, Reply /
    Mark as read buttons) + a reminder — screenshots + every shade text."""
    c = Case("np11_shade_bn_en", [6], "the notification shade in Bangla and English (screenshots)")
    import ticks_proof as TP
    from core.models import User
    from django.utils import timezone
    from datetime import timedelta
    st, kj = B.req("GET", "/circle/keys/peer/%d" % edge_b)
    a_pub = base64.b64decode(kj.get("public_key") or "") if st == 200 else b""
    kb = TP.Identity()
    B.req("POST", "/circle/keys", {"public_key": base64.b64encode(kb.pub).decode(),
                                   "key_id": kb.kid, "scheme": TP.SCHEME})
    labels = {"bn": ("উত্তর দিন", "পড়া হয়েছে"), "en": ("Reply", "Mark as read")}
    for lang in ("bn", "en"):
        User.objects.filter(pk=A.pk).update(language=lang)
        kill_app()
        _stash_all()
        title = ("ওষুধ খান %d" if lang == "bn" else "take medicine %d") % (int(time.time()) % 1000)
        Ah.req("POST", "/reminders/", {"title": title,
                                       "due_at": (timezone.now() + timedelta(minutes=2)).isoformat()})
        n0 = len(fcm_calls())
        Ah.req("POST", "/ci-e2e/tick", {"job": "push_due_reminders", "advance_min": 3})
        m = wait_fcm(tokens, "reminder", n0, pred=lambda d: title in (d.get("title", "") + d.get("body", "")))
        if m is not None:
            deliver(m)
        texts_sent = []
        for i in range(2):
            text = ("দুপুরে আসছি %d" if lang == "bn" else "coming at noon %d") % (i + 1)
            env = TP.encrypt(kb, a_pub, text)
            env.update(content_type="text", client_msg_id="np11-%s-%d-%d" % (lang, i, int(time.time() * 1000)))
            n0 = len(fcm_calls())
            st, _ = B.req("POST", "/circle/%d/messages" % edge_b, env)
            m = wait_fcm(tokens, "message", n0)
            if m is not None:
                deliver(m)
                texts_sent.append(text)
            time.sleep(6)
        time.sleep(8)
        wake_unlocked()
        sh("cmd statusbar expand-notifications")
        time.sleep(4)
        root = ui_dump()
        shot("np11_shade_%s" % lang)
        tx = ui_texts(root, pkg="com.android.systemui")
        save("np11_shade_%s.txt" % lang, "\n".join(tx))
        blob = "\n".join(tx)
        c.check("[%s] both messages are in the shade (one conversation)" % lang,
                len(texts_sent) == 2 and all(t in blob for t in texts_sent), tx[:30])
        c.check("[%s] message buttons in %s (%s / %s)" % (lang, lang, labels[lang][0], labels[lang][1]),
                any(labels[lang][0] in t for t in tx) and any(labels[lang][1] in t for t in tx), tx[:40])
        c.check("[%s] the reminder is in the shade" % lang, title in blob, tx[:40])
        if lang == "bn":
            ours = [t for t in tx if t in labels["bn"] or t.startswith("দুপুরে")]
            c.check("[bn] no English on Assisto's message lines / buttons",
                    all(not re.search(r"[A-Za-z]", t) for t in ours), ours)
        sh("cmd statusbar collapse")
    User.objects.filter(pk=A.pk).update(language="bn")
    # channel names as Android shows them in Settings (evidence)
    save("np11_channels.txt", sh("dumpsys notification --noredact | grep -E 'NotificationChannel\\{mId=' | grep -i assisto -n || "
                                 "cmd notification list_channels %s 0" % PKG, timeout=90))
    return c.done()


def report():
    cases = RESULT["cases"]
    ok = bool(cases) and all(c["status"] == "pass" for c in cases)
    RESULT["status"] = "pass" if ok else "fail"
    RESULT["run_url"] = "%s/%s/actions/runs/%s" % (os.environ.get("GITHUB_SERVER_URL", ""),
                                                   os.environ.get("GITHUB_REPOSITORY", ""),
                                                   os.environ.get("GITHUB_RUN_ID", ""))
    with open(os.path.join(OUT, "notifproof.json"), "w", encoding="utf-8") as f:
        json.dump(RESULT, f, ensure_ascii=False, indent=1)
    L = ["### Closed-app notification proof (notifproof) — %s" % ("PASS" if ok else "FAIL"), "",
         "Emulator API 34 Google APIs, app process KILLED before every event; event from the 2nd CI account "
         "via the backend; backend's real FCM v1 code -> mock FCM -> the same message as the Play-services "
         "broadcast. FCM token: %s." % RESULT["setup"].get("fcm_token", "?"), "",
         "| case | rows | result | inject->shown | failed checks |", "|---|---|---|---|---|"]
    for c in cases:
        bad = "; ".join(x["check"] for x in c["checks"] if not x["ok"]) or "—"
        L.append("| %s | %s | %s | %s | %s |" % (c["id"], ",".join(map(str, c["board_rows"])),
                                                 c["status"].upper(), c.get("inject_to_notification_ms", "—"), bad))
    L += ["", "**Not proven here:** " + " · ".join(RESULT["not_proven"])]
    md = "\n".join(L) + "\n"
    save("notifproof.md", md)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(md)
    print(md)
    return ok


def _alarm_pair(A, Ah):
    _, snoozed = case_alarm_ring_actions(A, Ah)
    case_alarm_doze(snoozed)


def _run_alarm_cases(A, Ah, only, Bu=None, B=None, tokens=(), edge_b=None):
    for name, fn in (("alarm", lambda: _alarm_pair(A, Ah)),
                     ("front", lambda: case_alarm_made_while_open(A, Ah, Bu, B, tokens)),
                     ("exactoff", lambda: case_exact_off(A, Ah)),             # notif-nine
                     ("shade", lambda: case_shade_shots(A, B, Ah, tokens, edge_b)),  # notif-nine
                     ("reboot", lambda: case_alarm_reboot(A, Ah))):
        if only and name not in only:
            continue
        try:
            fn()
        except Exception as e:
            RESULT["cases"].append({"id": name, "board_rows": [13], "status": "fail",
                                    "checks": [{"check": "case crashed", "ok": False, "detail": repr(e)[:400]}]})
            log("case", name, "crashed:", repr(e))


def main():
    try:
        A, Bu, tokens, edge_b = setup()
        if not tokens:
            raise RuntimeError("A has no push token row")
        B = Client("B", "notifproof-host-b")
        B.login(PHONE_B)
        Ah = Client("A-host", "notifproof-host-a")
        Ah.login(PHONE_A)
        only = set(filter(None, os.environ.get("NP_ONLY", "").split(",")))
        for name, fn in (("message", lambda: case_message(A, B, tokens, edge_b)),
                         ("reminder", lambda: case_reminder(A, Ah, tokens)),
                         ("sos", lambda: case_sos(A, B, tokens)),
                         ("family", lambda: case_family(A, B, tokens))):
            if only and name not in only:
                continue
            try:
                fn()
            except Exception as e:
                RESULT["cases"].append({"id": name, "board_rows": [], "status": "fail",
                                        "checks": [{"check": "case crashed", "ok": False, "detail": repr(e)[:400]}]})
                log("case", name, "crashed:", repr(e))
        # proof-notif: the phone's OWN reminder alarms (rows 13 + 6), after
        # the push cases; reboot last (it restarts the emulator)
        _run_alarm_cases(A, Ah, only, Bu, B, tokens, edge_b)
    except Exception as e:
        RESULT["setup"]["error"] = repr(e)[:400]
        log("setup failed:", repr(e))
    finally:
        save("logcat.txt", adb("logcat", "-d", "-v", "time", timeout=120))
    sys.exit(0 if report() else 1)


if __name__ == "__main__":
    main()
