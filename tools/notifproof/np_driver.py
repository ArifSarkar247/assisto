#!/usr/bin/env python3
"""notifproof — CLOSED-APP notification proof on the CI emulator.

Board rows 6 (Notifications) and 10 (Family SOS). Runs on the GitHub runner
next to the API-33 Google-APIs emulator (.github/workflows/notif-closed.yml):

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
]}


# gap-carecall: opt-in cases run only when named in NP_ONLY
OPT_IN = {"carecall"}
B_ID = [None]


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


def _outbox_rows(since, user_id=None, push_kind=None):
    rows = []
    try:
        with open(os.environ.get("E2E_OUTBOX") or "", encoding="utf-8") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("kind") != "push" or float(r.get("ts") or 0) < since:
                    continue
                if user_id is not None and r.get("user_id") != user_id:
                    continue
                if push_kind and r.get("push_kind") != push_kind:
                    continue
                rows.append(r)
    except OSError:
        pass
    return rows


def case_carecall(A, B, Ah, tokens):
    """gap-carecall (board row 21): a ONE-TIME Care Call from B rings A's
    phone FULL-SCREEN with the app killed and the screen off, at the right
    time on A's clock; A taps Done on the ring screen; the server records it
    and B (family) is told. Opt-in only: NP_ONLY=carecall."""
    c = Case("np5_carecall_fullscreen_closed", [21, 6],
             "B's one-time Care Call rings A: app killed, screen off -> full-screen ring -> Done -> B told")
    from datetime import datetime, timedelta, timezone as dtz
    wake_unlocked()
    z = sh("date +%z").strip()
    m_ = re.match(r"([+-])(\d\d)(\d\d)$", z)
    off = (1 if not m_ or m_.group(1) == "+" else -1) * (int(m_.group(2)) * 60 + int(m_.group(3))) if m_ else 0
    c.r["phone_utc_offset_min"] = off
    # A's phone clock is what the server rings on (fcbrain ping, as the app sends)
    Ah.req("POST", "/family/brain/ping", {"tz_offset_min": off})
    phone_now = datetime.now(dtz.utc) + timedelta(minutes=off)
    q = phone_now + timedelta(hours=12)
    Ah.req("POST", "/carecall/quiet", {"start": q.strftime("%H:%M"),
                                       "end": (q + timedelta(minutes=1)).strftime("%H:%M")})
    at = phone_now + timedelta(minutes=2 if phone_now.second <= 40 else 3)
    text = "notifproof care call %d" % (int(time.time()) % 100000)
    st, j = B.req("POST", "/carecall", {"receiver_id": A.pk, "text": text,
                                        "time": at.strftime("%H:%M"), "repeat": "once"})
    cc = (j or {}).get("care_call") or {}
    if not c.check("B's one-time Care Call saved (no date: the next time on A's clock)", st == 201 and cc.get("id"), (st, j)):
        return c.done()
    nxt = datetime.fromisoformat(str(cc.get("next_at")).replace("Z", "+00:00"))
    ahead = (nxt - datetime.now(dtz.utc)).total_seconds()
    c.r["next_at"], c.r["ahead_s"] = cc.get("next_at"), int(ahead)
    c.check("the slot is ~2 min ahead on A's clock (not hours, not past)", 30 <= ahead <= 240, ahead)
    c.check("the server tells the app A's clock (receiver_offset_min)", cc.get("receiver_offset_min") == off,
            cc.get("receiver_offset_min"))
    st, j = Ah.req("POST", "/carecall/consent", {"setter_id": B_ID[0], "accept": True})
    c.check("A accepted Care Calls from B (consent)", st == 200, (st, j))
    closed_precheck(c)
    sh("input keyevent KEYCODE_SLEEP")
    time.sleep(3)
    wk = sh("dumpsys power | grep mWakefulness= | head -1").strip()
    c.check("screen is OFF before the ring", "Awake" not in wk, wk)
    # wait (real clock) until the slot, then the server minute job
    while datetime.now(dtz.utc) < nxt:
        time.sleep(2)
    n0 = len(fcm_calls())
    t0 = time.time()
    st, tj = Ah.req("POST", "/ci-e2e/tick", {"job": "carecall_tick", "advance_min": 1})
    c.check("server Care Call job ran at the slot", st == 200 and tj.get("ok"), (st, tj))
    m = wait_fcm(tokens, "carecall", n0, pred=lambda d: d.get("care_call_id") == str(cc["id"]))
    if not c.check("backend sent a HIGH-priority FCM 'carecall' ring to A", m is not None
                   and (m.get("android") or {}).get("priority") == "HIGH", m):
        return c.done()
    c.r["slot"] = (m.get("data") or {}).get("slot")
    ex, out = deliver(m)
    c.r["broadcast"] = out
    t_inj = time.time()
    rec, (recs, snd, raw) = wait_notif(lambda r: r["channel"] == "calls", timeout=60)
    save("np5_dumpsys_notification.txt", raw)
    c.check("the ring is posted on the call channel", rec is not None, [r["channel"] for r in recs])
    if rec is not None:
        c.r["inject_to_notification_ms"] = int((time.time() - t_inj) * 1000)
        c.r["ring_record"] = {k: rec[k] for k in ("key", "channel", "flags", "intercept", "fsi")}
        c.check("it carries a FULL-SCREEN intent", rec["fsi"], rec["raw"][:400])
        c.check("it rings like a call until answered (FLAG_INSISTENT)", bool(rec["flags"] & 0x4), hex(rec["flags"]))
    time.sleep(4)
    wk = sh("dumpsys power | grep mWakefulness= | head -1").strip()
    c.check("the full-screen ring WOKE the screen", "Awake" in wk, wk)
    ra = resumed_activity()
    c.r["resumed"] = ra
    c.check("Assisto's ring screen is in front over the lock screen", PKG in ra, ra)
    ok, texts = app_shows([text], timeout=90)
    shot("np5_fullscreen_ring")
    c.check("the ring screen shows the Care Call text exactly", ok, texts[:40])
    root = ui_dump()
    btn = ui_find(root, "Done", pkg=PKG) or ui_find(root, "হয়ে গেছে", pkg=PKG)
    if not c.check("the big Done button is on the ring screen", btn is not None, ui_texts(root, pkg=PKG)[:40]):
        return c.done()
    tap_node(btn)
    from django.db import close_old_connections
    from core.models import CareCallRing
    ring = None
    end = time.time() + 60
    while time.time() < end:
        close_old_connections()
        ring = CareCallRing.objects.filter(care_call_id=cc["id"]).order_by("-id").first()
        if ring is not None and ring.status == "done":
            break
        time.sleep(2)
    shot("np5_after_done")
    c.check("Done is recorded on the server (ring status done)", ring is not None and ring.status == "done",
            getattr(ring, "status", None))
    told = []
    end = time.time() + 30
    while time.time() < end and not told:
        told = [r for r in _outbox_rows(t0 - 5, user_id=B_ID[0], push_kind="carecall_status")
                if (r.get("data") or {}).get("status") == "done"]
        time.sleep(2)
    c.check("B (family) is told: 'confirmed' push to B", bool(told), len(told))
    st, mj = B.req("GET", "/carecall")
    c.check("B's Care Call feed shows it confirmed", st == 200 and any(
        x.get("care_call_id") == cc["id"] and x.get("kind") == "confirmed" for x in mj.get("feed") or []),
        (st, (mj.get("feed") or [])[:2]))
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
         "Emulator API 33 Google APIs, app process KILLED before every event; event from the 2nd CI account "
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
        B_ID[0] = Bu.pk
        for name, fn in (("message", lambda: case_message(A, B, tokens, edge_b)),
                         ("reminder", lambda: case_reminder(A, Ah, tokens)),
                         ("sos", lambda: case_sos(A, B, tokens)),
                         ("family", lambda: case_family(A, B, tokens)),
                         ("carecall", lambda: case_carecall(A, B, Ah, tokens))):  # gap-carecall
            if only and name not in only:
                continue
            if not only and name in OPT_IN:
                continue
            try:
                fn()
            except Exception as e:
                RESULT["cases"].append({"id": name, "board_rows": [], "status": "fail",
                                        "checks": [{"check": "case crashed", "ok": False, "detail": repr(e)[:400]}]})
                log("case", name, "crashed:", repr(e))
    except Exception as e:
        RESULT["setup"]["error"] = repr(e)[:400]
        log("setup failed:", repr(e))
    finally:
        save("logcat.txt", adb("logcat", "-d", "-v", "time", timeout=120))
    sys.exit(0 if report() else 1)


if __name__ == "__main__":
    main()
