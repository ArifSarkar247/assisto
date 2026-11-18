#!/usr/bin/env python3
"""antitheft-nine: the anti-theft engine's battery cost over the battery hour.

usage: at_battery.py <reality_out> <package> <seconds_measured>

Input: <out>/batterystats_checkin.txt (`dumpsys batterystats --checkin`, taken
after `--reset` + unplug + screen off for the whole hour; see run_flows.sh
batt_start / batt_end). Output: <out>/at_battery.json + a short text summary.

HONEST LIMITS (written into the JSON):
  * An emulator has no real battery or power rails. Its own mAh estimate uses
    the emulator's placeholder power profile, so it is reported but NOT used.
  * We measure what the app really did (CPU time, wake locks, sensor time,
    wake-up alarms, network) and price it with a typical Bangladesh mid-range
    phone profile (constants below, generous on purpose).
  * The app uid also contains the idle Flutter test runner (same process), so
    the CPU number is an UPPER bound for the engine.
  * The emulator CPU never suspends, so the 50 Hz motion sensor is delivered
    and processed the whole hour: the "worst case" line prices it as if the
    phone could never sleep (no sensor hub). A real phone with a sensor hub
    is between "expected" and "worst case".
"""
import json
import re
import subprocess
import sys
from pathlib import Path

BATTERY_MAH = 4000.0      # conservative (BD mid-range phones are 5000-6000)
CPU_MA = 150.0            # one busy core, mid cluster, at typical frequency
AWAKE_MA = 8.0            # CPU held awake (wake lock) but idle, above suspend
SENSOR_MA = 0.6           # accelerometer/linear-accel at 50 Hz via sensor hub
NO_HUB_AWAKE_MA = 12.0    # worst case: 50 Hz delivery keeps the AP awake all hour
CHECKIN_MAH = 0.35        # one HTTPS check-in incl. ~10 s radio tail at ~120 mA
LIMIT_PCT_H = 2.0


def uid_of(pkg):
    try:
        out = subprocess.run(["adb", "shell", "dumpsys", "package", pkg],
                             capture_output=True, text=True, timeout=30).stdout
        m = re.search(r"userId=(\d+)", out)
        return m.group(1) if m else None
    except Exception:
        return None


def parse(checkin, uid):
    r = {"cpu_ms": 0, "wakelock_ms": 0, "wakelocks": {}, "sensor_ms": 0,
         "sensors": {}, "wakeup_alarms": 0, "net_rx_bytes": 0, "net_tx_bytes": 0,
         "emulator_mah": None, "jobs": 0, "rows": 0}
    for line in checkin.splitlines():
        p = line.strip().split(",")
        if len(p) < 4 or p[2] != "l":
            continue
        row_uid, kind = p[1], p[3]
        if kind == "pwi" and len(p) > 5 and p[4] == "uid" and row_uid == uid:
            try:
                r["emulator_mah"] = float(p[5])
            except ValueError:
                pass
        if row_uid != uid:
            continue
        r["rows"] += 1
        try:
            if kind == "cpu" and len(p) >= 6:
                r["cpu_ms"] += int(float(p[4])) + int(float(p[5]))
            elif kind == "wl" and len(p) >= 10:
                # wl,<name>,<full_ms>,f,<n>,<partial_ms>,p,<n>,...
                ms = int(float(p[8])) if p[9] == "p" else 0
                r["wakelock_ms"] += ms
                if ms:
                    r["wakelocks"][p[4]] = r["wakelocks"].get(p[4], 0) + ms
            elif kind == "sr" and len(p) >= 6:
                ms = int(float(p[5]))
                r["sensor_ms"] += ms
                r["sensors"][p[4]] = r["sensors"].get(p[4], 0) + ms
            elif kind == "wua" and len(p) >= 6:
                r["wakeup_alarms"] += int(float(p[5]))
            elif kind == "nt" and len(p) >= 6:
                r["net_rx_bytes"] += int(float(p[4])) + (int(float(p[6])) if len(p) > 6 else 0)
                r["net_tx_bytes"] += int(float(p[5])) + (int(float(p[7])) if len(p) > 7 else 0)
            elif kind == "jb" and len(p) >= 7:
                r["jobs"] += int(float(p[6]))
        except (ValueError, IndexError):
            continue
    return r


def main():
    out, pkg, secs = Path(sys.argv[1]), sys.argv[2], max(1, int(sys.argv[3]))
    ck = (out / "batterystats_checkin.txt")
    text = ck.read_text(errors="replace") if ck.exists() else ""
    uid = uid_of(pkg)
    r = parse(text, uid) if uid else {"rows": 0}
    hours = secs / 3600.0
    res = {"uid": uid, "seconds": secs, "measured": r, "limit_pct_per_h": LIMIT_PCT_H,
           "model": {"battery_mah": BATTERY_MAH, "cpu_ma": CPU_MA, "awake_ma": AWAKE_MA,
                     "sensor_ma": SENSOR_MA, "no_hub_awake_ma": NO_HUB_AWAKE_MA,
                     "checkin_mah": CHECKIN_MAH},
           "limits": __doc__.split("HONEST LIMITS (written into the JSON):")[1].strip()}
    if not r.get("rows"):
        res["verdict"] = "NO_DATA"
        (out / "at_battery.json").write_text(json.dumps(res, indent=1))
        print("at_battery: NO_DATA (uid=%s, checkin %d bytes)" % (uid, len(text)))
        return 0
    cpu_mah = r["cpu_ms"] / 1000.0 * CPU_MA / 3600.0
    awake_mah = max(0, r["wakelock_ms"] - r["cpu_ms"]) / 1000.0 * AWAKE_MA / 3600.0
    sensor_mah = r["sensor_ms"] / 1000.0 * SENSOR_MA / 3600.0
    checkins = max(int(round(4 * hours)) + 1, r["wakeup_alarms"])
    net_mah = checkins * CHECKIN_MAH
    expected = cpu_mah + awake_mah + sensor_mah + net_mah
    worst = expected + NO_HUB_AWAKE_MA * hours
    exp_pct_h = expected / BATTERY_MAH * 100.0 / hours
    worst_pct_h = worst / BATTERY_MAH * 100.0 / hours
    res.update({
        "mah": {"cpu": round(cpu_mah, 3), "awake": round(awake_mah, 3),
                "sensor": round(sensor_mah, 3), "network": round(net_mah, 3),
                "expected": round(expected, 3), "worst_case": round(worst, 3)},
        "checkins_assumed": checkins,
        "pct_per_hour": {"expected": round(exp_pct_h, 3), "worst_case": round(worst_pct_h, 3)},
        "verdict": "PASS" if worst_pct_h < LIMIT_PCT_H else "FAIL",
    })
    (out / "at_battery.json").write_text(json.dumps(res, indent=1))
    print("at_battery %s: %.0f min, cpu %d ms, wakelock %d ms, sensor %d ms, "
          "wakeup alarms %d, net %d/%d B" % (res["verdict"], secs / 60.0, r["cpu_ms"],
                                             r["wakelock_ms"], r["sensor_ms"],
                                             r["wakeup_alarms"], r["net_rx_bytes"],
                                             r["net_tx_bytes"]))
    print("expected %.3f %%/h, worst case %.3f %%/h (limit %.1f %%/h; emulator's own "
          "estimate %s mAh, not used)" % (exp_pct_h, worst_pct_h, LIMIT_PCT_H,
                                          r.get("emulator_mah")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
