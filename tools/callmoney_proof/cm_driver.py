#!/usr/bin/env python3
"""callmoney proof — the NATIVE money-notification listener on the CI emulator.

Board row 18 (after-call note + money from notifications), proof rule
owner_actions/E2E_PROOF_BN.md. Runs next to the API-33 emulator
(.github/workflows/callmoney-proof.yml) with the REAL app APK installed.

What happens per case — everything after the SMS is the phone's own code:
  1. the emulator's modem receives an SMS (`adb emu sms send <sender> <text>`),
  2. the phone's default SMS app posts its normal notification,
  3. Assisto's NotificationListenerService (granted like a user does in
     Settings -> Notification access) decides from the SENDER first, reads the
     text only for allow-listed wallet / bank senders, drops OTPs, keeps real
     payments in its on-phone queue and posts "bKash ৳500 — save to khata?".
The driver then reads the app-private queue (run-as, debug build) and the
notification shade. The user's switches are set the way the app's Settings
screen stores them (consent screens are covered by widget tests).

Cases
  bkash_bn      Bangla bKash "৫০০ টাকা পেয়েছেন"        -> queued, prompt ৳৫০০
  bkash_tkdot   "Tk. 750.00" (dot after Tk)             -> queued, prompt ৳৭৫০
  rocket_pin    payment + "Never share your PIN/OTP"   -> queued, prompt ৳১,২০০
  otp           bKash verification code                -> NOT queued
  personal      a person's SMS mentioning taka         -> NOT queued (not allow-listed)
  sms_switch    server switch money_notif_sms OFF       -> NOT queued
Not proven here: wallet APP notifications (bKash/Nagad apps are not on the
emulator), OEM battery killers, the Dart review screen (widget tests).
Writes $CM_OUT/callmoney_proof.json + .md (+ step summary). Exit 1 unless every
case passed. Never fakes a pass. Sample data only (no real user data).
"""
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "com.assisto.assisto"
COMP = f"{PKG}/{PKG}.notiflisten.AssistoNotifListener"
ADB = os.environ.get("ADB", "adb")
OUT = os.environ.get("CM_OUT", "cm_out")
APK = os.environ.get("CM_APK", "")


def adb(*args, timeout=60):
    try:
        r = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
        return (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def sh(cmd, timeout=60):
    return adb("shell", cmd, timeout=timeout)


def shot(name):
    try:
        r = subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True, timeout=30)
        if r.stdout:
            with open(os.path.join(OUT, f"{name}.png"), "wb") as f:
                f.write(r.stdout)
    except Exception:
        pass


def prefs_xml(money_sms):
    return ("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n"
            '    <boolean name="money" value="true" />\n'
            '    <boolean name="money_auto" value="false" />\n'
            '    <boolean name="callnote" value="false" />\n'
            f'    <boolean name="money_sms" value="{"true" if money_sms else "false"}" />\n'
            '    <string name="lang">bn</string>\n'
            "</map>\n")


def listener_live():
    out = sh("dumpsys notification", timeout=90)
    i = out.find("Live notification listeners")
    return i >= 0 and "AssistoNotifListener" in out[i:i + 4000]


def set_switches(money_sms):
    """Stores the switches as the Settings screen does, then (re)binds the listener."""
    sh(f"am force-stop {PKG}")
    local = os.path.join(OUT, "cm_prefs.xml")
    with open(local, "w", encoding="utf-8") as f:
        f.write(prefs_xml(money_sms))
    adb("push", local, "/data/local/tmp/cm_prefs.xml")
    sh("chmod 644 /data/local/tmp/cm_prefs.xml")
    sh(f"run-as {PKG} sh -c 'mkdir -p shared_prefs && cp /data/local/tmp/cm_prefs.xml shared_prefs/assisto_notif_listen.xml'")
    sh(f"cmd notification disallow_listener {COMP}")
    time.sleep(2)
    sh(f"cmd notification allow_listener {COMP}")
    end = time.time() + 60
    while time.time() < end:
        if listener_live():
            return True
        time.sleep(3)
    return False


def queue():
    raw = sh(f"run-as {PKG} cat shared_prefs/assisto_notif_listen.xml")
    try:
        root = ET.fromstring(raw[raw.find("<?xml"):] if "<?xml" in raw else raw)
    except ET.ParseError:
        return []
    for e in root:
        if e.get("name") == "money_q":
            try:
                return json.loads(e.text or "[]")
            except ValueError:
                return []
    return []


def assisto_titles():
    out = sh("dumpsys notification --noredact", timeout=90)
    titles = []
    for block in out.split("NotificationRecord(")[1:]:
        if f"pkg={PKG}" not in block[:300]:
            continue
        m = re.search(r"android\.title=\S+ \((.*?)\)\n", block)
        if m:
            titles.append(m.group(1))
    return titles


def send_sms(sender, text):
    # the emulator console takes the text as the rest of the line
    return adb("emu", "sms", "send", sender, text, timeout=30)


CASES = [
    dict(id="bkash_bn", sender="16247", keep=True, wallet="bkash", prompt="৳৫০০",
         text="আপনি ০১৭১২৩৪৫৬৭৮ নম্বর থেকে ৫০০ টাকা পেয়েছেন। ফি ০ টাকা। ব্যালেন্স ১,২৫০ টাকা। TrxID 9JK7AB12CD"),
    dict(id="bkash_tkdot", sender="16247", keep=True, wallet="bkash", prompt="৳৭৫০",
         text="You have received Tk. 750.00 from 01712345678. Fee Tk. 0.00. Balance Tk. 2,000.00. TrxID 7AB3CD9EFG"),
    dict(id="rocket_pin", sender="16216", keep=True, wallet="rocket", prompt="৳১,২০০",
         text="Tk1,200.00 sent to A/C:01812345678-3 successfully. Fee:Tk5.00, Your A/C Balance: Tk250.00 TxnId:2234567891. Never share your PIN/OTP with anyone."),
    dict(id="otp", sender="16247", keep=False,
         text="Your bKash verification code is 482913. Never share it with anyone. Balance Tk 500"),
    dict(id="personal", sender="01711111111", keep=False,
         text="Bhai 100 taka pathalam, balance Tk 100 ache. TrxID AB12CD34EF"),
]
SWITCH_CASE = dict(id="sms_switch", sender="16247", keep=False,
                   text="Cash In Tk 300.00 from 01611111111 successful. Balance Tk 2,300.00. TrxID 6CI8DD1XYZ")


def run_case(c, results):
    before = {q.get("id") for q in queue()}
    send_sms(c["sender"], c["text"])
    got, end = None, time.time() + (25 if c["keep"] else 15)
    while time.time() < end:
        new = [q for q in queue() if q.get("id") not in before]
        if new:
            got = new[-1]
            break
        time.sleep(2)
    ok, why = True, []
    if c["keep"]:
        if not got:
            ok = False
            why.append("not in the on-phone queue")
        else:
            if got.get("wallet") != c["wallet"] or got.get("kind") != "sms":
                ok = False
                why.append(f"queued as {got.get('wallet')}/{got.get('kind')}")
            time.sleep(2)
            titles = assisto_titles()
            if not any(c["prompt"] in t for t in titles):
                ok = False
                why.append(f"prompt titles {titles!r} lack {c['prompt']}")
    elif got:
        ok = False
        why.append("was queued but must be ignored")
    shot(f"case_{c['id']}")
    results.append(dict(id=c["id"], sender=c["sender"], expect="kept" if c["keep"] else "ignored",
                        ok=ok, detail="; ".join(why) or "as expected"))
    print(("PASS " if ok else "FAIL ") + c["id"] + " — " + (results[-1]["detail"]), flush=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    results, notes = [], []
    adb("wait-for-device", timeout=300)
    print(adb("install", "-r", "-g", APK, timeout=600)[-300:], flush=True)
    sms = sh("cmd role get-role-holders android.app.role.SMS").strip()
    notes.append(f"default SMS app: {sms or 'none'}")
    if sms:
        sh(f"pm grant {sms} android.permission.POST_NOTIFICATIONS")
    sh(f"pm grant {PKG} android.permission.POST_NOTIFICATIONS")
    if not set_switches(money_sms=True):
        notes.append("listener did not bind")
    shot("00_listener_on")
    for c in CASES:
        run_case(c, results)
    sh("cmd statusbar expand-notifications")
    time.sleep(2)
    shot("10_shade_prompts")
    sh("cmd statusbar collapse")
    # server switch money_notif_sms OFF (what NotifListenService.syncSmsSwitch hands over)
    if not set_switches(money_sms=False):
        notes.append("listener did not re-bind for the switch case")
    run_case(SWITCH_CASE, results)
    passed = all(r["ok"] for r in results) and len(results) == len(CASES) + 1
    doc = dict(passed=passed, cases=results, notes=notes,
               not_proven=["wallet APP notifications (bKash/Nagad apps are not on the emulator)",
                           "OEM battery killers (ColorOS/MIUI) - real phones only",
                           "Dart review / save screens - widget tests (gap_callmoney_test.dart)"])
    with open(os.path.join(OUT, "callmoney_proof.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    md = ["## callmoney native proof (API 33 emulator)", "",
          f"**{'PASS' if passed else 'FAIL'}** — {sum(r['ok'] for r in results)}/{len(results)} cases", "",
          "| case | sender | expected | result | detail |", "|---|---|---|---|---|"]
    md += [f"| {r['id']} | {r['sender']} | {r['expect']} | {'PASS' if r['ok'] else 'FAIL'} | {r['detail']} |"
           for r in results]
    md += ["", "Notes: " + "; ".join(notes), "", "Not proven here: " + "; ".join(doc["not_proven"])]
    text = "\n".join(md) + "\n"
    with open(os.path.join(OUT, "callmoney_proof.md"), "w", encoding="utf-8") as f:
        f.write(text)
    summ = os.environ.get("GITHUB_STEP_SUMMARY")
    if summ:
        with open(summ, "a", encoding="utf-8") as f:
            f.write(text)
    print(text, flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
