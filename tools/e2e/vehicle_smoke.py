"""Vehicle tracking real-process smoke (used by tools/e2e/vehicle_e2e.sh).

Runs the REAL tracker daemon (`python -m tracker`) as a separate process on a
scratch port against a scratch SQLite DB (never Postgres, never port 5023),
drives it with tracker/sim.py over TCP as a GT06, an H02 (Sinotrack ST-901),
a Coban TK103 (veh100) and a Teltonika device, then reads the result back through the app's HTTP
API with Django's test client. Prints one JSON line per check; exit 0 only
if all pass.

    python tools/e2e/vehicle_smoke.py --dir /tmp/x --port 15026
"""
import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BACKEND = os.path.join(ROOT, "backend")

SETTINGS = '''from assisto_backend.settings_test import *  # noqa
DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3",
                         "NAME": %r, "OPTIONS": {"timeout": 20}}}
ALLOWED_HOSTS = ["testserver", "127.0.0.1", "localhost"]
'''

RESULTS = []


def check(name, ok, **detail):
    RESULTS.append({"check": name, "ok": bool(ok), **detail})
    print(json.dumps(RESULTS[-1], default=str), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=15026)
    a = ap.parse_args()
    if a.port == 5023:
        sys.exit("refusing the production tracker port")
    os.makedirs(a.dir, exist_ok=True)
    with open(os.path.join(a.dir, "e2e_vehicle_settings.py"), "w") as f:
        f.write(SETTINGS % os.path.join(a.dir, "vehicle.sqlite3"))
    sys.path[:0] = [a.dir, BACKEND]
    env = dict(os.environ, PYTHONPATH=os.pathsep.join([a.dir, BACKEND]),
               DJANGO_SETTINGS_MODULE="e2e_vehicle_settings")
    os.environ.update(DJANGO_SETTINGS_MODULE="e2e_vehicle_settings")
    import django
    django.setup()
    from django.core.management import call_command
    call_command("migrate", verbosity=0, interactive=False)

    from django.contrib.auth.hashers import make_password
    from django.utils import timezone as djtz
    from rest_framework.test import APIClient
    from core.models import User, ProtectedPhone, VehicleTracker
    from core.tests_v1_vehicle import luhn_imei
    from tracker.sim import GT06Device, H02Device, TeltonikaDevice, TK103Device, drive_path
    from tracker.protocols import teltonika

    owner = User.objects.create_user(name="Smoke", phone="01710009001", password="pw")
    owner.ai_credits = 1000
    owner.save()
    ProtectedPhone.objects.create(owner=owner, security_pin_hash=make_password("2468"))
    api = APIClient()
    api.force_authenticate(owner)
    ids = {}
    for proto, imei in (("gt06", luhn_imei("35933907700391")),
                        ("h02", "9171234567"),
                        ("tk103", luhn_imei("35958601582980")),
                        ("teltonika", luhn_imei("35630704244101"))):
        r = api.post("/api/v1/vehicle/trackers", {"imei": imei, "name": proto,
                                                  "protocol": proto}, format="json")
        check("pair_requested_" + proto, r.status_code == 201, status=r.status_code)
        tid = r.data["tracker"]["id"]
        api.patch("/api/v1/vehicle/trackers/%d" % tid, {"speed_limit_kmh": 60},
                  format="json")
        ids[proto] = (tid, imei)

    srv = subprocess.Popen([sys.executable, "-m", "tracker", "--host", "127.0.0.1",
                            "--port", str(a.port), "--settings", "e2e_vehicle_settings"],
                           cwd=BACKEND, env=env, stdout=open(os.path.join(a.dir, "tracker.log"), "w"),
                           stderr=subprocess.STDOUT)
    try:
        import socket
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", a.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.2)
        check("tracker_listening", srv.poll() is None, port=a.port)

        async def drive():
            now = datetime.now(timezone.utc)
            path = drive_path(23.7808, 90.4130, 30, 72.0, 5, t0=now - timedelta(seconds=200))
            path += [dict(path[-1], at=now - timedelta(seconds=10 - i * 3), speed_kmh=0)
                     for i in range(3)]
            g = GT06Device(ids["gt06"][1])
            await g.connect("127.0.0.1", a.port)
            check("gt06_login_ack", await g.login())
            for p in path:
                await g.fix(p["lat"], p["lng"], p["speed_kmh"], p["speed_kmh"] > 0, p["at"])
            await g.heartbeat()
            await g.alarm(path[-1]["lat"], path[-1]["lng"], "sos")
            h = H02Device(ids["h02"][1])
            await h.connect("127.0.0.1", a.port)
            for p in path:
                await h.fix(p["lat"], p["lng"], p["speed_kmh"], p["speed_kmh"] > 0, p["at"])
            await h.heartbeat()
            k = TK103Device(ids["tk103"][1])
            await k.connect("127.0.0.1", a.port)
            check("tk103_login_load", await k.login())
            for p in path:
                await k.fix(p["lat"], p["lng"], p["speed_kmh"], p["at"])
            await k.fix(path[-1]["lat"], path[-1]["lng"], 0, keyword="ac alarm")
            await k.heartbeat()
            t = TeltonikaDevice(ids["teltonika"][1])
            await t.connect("127.0.0.1", a.port)
            check("teltonika_imei_accepted", await t.handshake())
            recs = [dict(p, io={teltonika.IO_IGNITION: 1 if p["speed_kmh"] else 0})
                    for p in path]
            check("teltonika_records_acked", await t.send(recs) == len(recs))
            bad = GT06Device(luhn_imei("86123404000001"))
            await bad.connect("127.0.0.1", a.port)
            check("unknown_imei_refused", not await bad.login(timeout=1.5))
            await asyncio.sleep(4.0)          # > FLUSH_S + CMD_POLL_S
            check("gt06_status_alarm_acked", 0x13 in g.acks and 0x16 in g.acks, acks=g.acks)
            check("gt06_interval_cmd_received",
                  any(c.startswith("TIMER,") for c in g.commands), cmds=g.commands)
            check("h02_interval_cmd_received",
                  any(c.startswith("S71,") for c in h.commands), cmds=h.commands)
            check("tk103_interval_cmd_received",
                  any(c.startswith("C,") for c in k.commands), cmds=k.commands)
            for d in (g, h, k, t, bad):
                await d.close()
            return len(path)

        n = asyncio.run(drive())
        for proto, (tid, _imei) in ids.items():
            t = api.get("/api/v1/vehicle/trackers/%d" % tid).data
            r = api.get("/api/v1/vehicle/trackers/%d/route" % tid).data
            check("live_" + proto, t["state"] == "paired" and t["online"]
                  and t["live"] and t["live"]["speed_kmh"] == 0,
                  live=t["live"], state=t["state"])
            check("route_" + proto, len(r["points"]) >= n - 1
                  and abs(r["max_speed_kmh"] - 72) < 1.5 and len(r["trips"]) >= 1,
                  points=len(r["points"]), max_speed=r["max_speed_kmh"],
                  km=r["total_km"])
        from core.models import NotifEvent
        kinds = list(NotifEvent.objects.filter(user=owner).values_list("meta__alert", flat=True))
        check("overspeed_alert_all_protocols", kinds.count("overspeed") == 4, kinds=kinds)
        check("sos_alarm_alert", "device_alarm" in kinds)
        alarms = list(NotifEvent.objects.filter(user=owner, meta__alert="device_alarm")
                      .values_list("meta__alarm", flat=True))
        check("tk103_power_cut_alert", "power_cut" in alarms, alarms=alarms)
        check("tracker_still_running", srv.poll() is None)
    finally:
        srv.terminate()
        try:
            srv.wait(10)
        except subprocess.TimeoutExpired:
            srv.kill()
    ok = all(r["ok"] for r in RESULTS)
    with open(os.path.join(a.dir, "vehicle_results.json"), "w") as f:
        json.dump({"ok": ok, "checks": RESULTS}, f, indent=1, default=str)
    print("SMOKE", "PASS" if ok else "FAIL", "%d/%d" % (sum(r["ok"] for r in RESULTS),
                                                     len(RESULTS)))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
