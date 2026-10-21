# Assisto tracker server — install steps (for the integrator / owner)

Nothing here is installed by the v1-vehicle agent. Run these on the
lifeassisto box (16.4.105.173) only after the branch is merged and migration
`00NN_v1_vehicle_tracking` has been applied (take a DB backup first).

## 1. Migrate (after merge)
```
cd /home/ubuntu/assisto/backend
pg_dump ... > ../db_backups/pre_v1_vehicle_$(date +%F).sql   # usual backup step
/home/ubuntu/assisto/.venv/bin/python manage.py migrate core
```

## 2. Smoke the server on a spare port first (no firewall change needed)
```
cd /home/ubuntu/assisto/backend
/home/ubuntu/assisto/.venv/bin/python -m tracker --host 127.0.0.1 --port 15023 &
/home/ubuntu/assisto/.venv/bin/python -m tracker.sim gt06 --imei 359339077003915 --port 15023
#   -> "login acked: False" (IMEI not paired = correctly refused + logged)
kill %1
```

## 3. Install the systemd unit
```
sudo cp /home/ubuntu/assisto/deploy/tracker/assisto-tracker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now assisto-tracker
systemctl status assisto-tracker --no-pager
journalctl -u assisto-tracker -n 50 --no-pager     # "tracker listening on 0.0.0.0:5023"
```
Caps: MemoryMax=256M, CPUQuota=25%, TasksMax=64. It never touches
assisto.service, nginx or coturn. It is NOT behind Caddy/nginx (raw TCP).

## 4. Firewall / DNS
* DNS: `track.lifeassisto.com` A -> 16.4.105.173 (already done).
* AWS security group: add inbound **TCP 5023** from `0.0.0.0/0` (trackers
  come from carrier CGNAT IPs, so it cannot be narrowed). Owner action.
* If ufw is enabled on the box: `sudo ufw allow 5023/tcp`.
* Check from outside: `nc -vz track.lifeassisto.com 5023`.

## 5. Daily billing cron (crontab -e, as ubuntu)
```
20 4 * * *  nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py vehicle_tracking_billing >> /home/ubuntu/assisto/backend/logs/vehicle_tracking_billing.log 2>&1
```
(The server itself also prunes old positions hourly and fails stale commands
every 30 s; the cron renews/pauses paid months.)

## 6. Point a real tracker at the server (SMS to the tracker's SIM)
* Concox GT06 / GT06N / GT800: `SERVER,1,track.lifeassisto.com,5023,0#`
* Teltonika FMB: `  setparam 2004:track.lifeassisto.com;2005:5023;2006:0`
  (two leading spaces = empty SMS login/password)
Then in the app: My Vehicles -> Live tracking -> Pair tracker, enter the IMEI;
the tracker must connect within the pairing window (default 10 min).

## Transport security (honest)
GT06 and Teltonika trackers speak plain TCP and cannot do TLS, so the
device -> server leg is unencrypted. Mitigations: IMEI allowlist pairing with a
time window, per-device rate limits + frame caps, unknown IMEIs refused and
logged, devices can never issue commands to the server. App <-> server is HTTPS.
