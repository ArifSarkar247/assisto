"""
On-box uptime watcher. Checks the public API (through nginx + TLS), the app
server directly (gunicorn on 127.0.0.1:8700), the TLS certificate expiry and
free disk. Alerts the owner ONLY on a state change (down after 2 consecutive
failed runs, and again when it recovers) so a long outage never spams.

Delivery is via core.push.notify_owner: FCM push once Firebase is configured,
email once SMTP is configured. Until then the state + log line still record
every outage. The OFF-box twin is .github/workflows/uptime.yml (it alerts even
when this whole server is down).

Idempotent; state in logs/uptime_state.json. Cron (every 2 min):
  */2 * * * * ubuntu nice -n15 <venv>/python manage.py uptime_check
"""
import json
import shutil
import socket
import ssl
import time
import urllib.request
from datetime import datetime, timezone as dt_tz
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand

PUBLIC_URL = "https://api.lifeassisto.com/api/v1/health"
LOCAL_URL = "http://127.0.0.1:8700/api/v1/health"
CERT_HOST = "api.lifeassisto.com"
CERT_WARN_DAYS = 14
DISK_WARN_GB = 5
FAILS_BEFORE_ALERT = 2


def _http_ok(url, host=None):
    req = urllib.request.Request(url, headers={"Host": host} if host else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status == 200, str(r.status)
    except Exception as e:  # noqa: BLE001 — any failure is "down"
        return False, type(e).__name__


def _cert_days(host):
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as s:
            end = ssl.cert_time_to_seconds(s.getpeercert()["notAfter"])
    return int((end - time.time()) // 86400)


class Command(BaseCommand):
    help = "Check API/app/cert/disk health; alert the owner on state change."

    def handle(self, *args, **opts):
        problems = []
        ok, why = _http_ok(PUBLIC_URL)
        if not ok:
            problems.append(f"public API {PUBLIC_URL} failed ({why})")
        ok, why = _http_ok(LOCAL_URL, host=CERT_HOST)
        if not ok:
            problems.append(f"app server :8700 failed ({why})")
        try:
            days = _cert_days(CERT_HOST)
            if days < CERT_WARN_DAYS:
                problems.append(f"TLS cert expires in {days} days")
        except Exception as e:  # noqa: BLE001
            problems.append(f"TLS check failed ({type(e).__name__})")
        free_gb = shutil.disk_usage("/").free / 1e9
        if free_gb < DISK_WARN_GB:
            problems.append(f"disk free {free_gb:.1f} GB")

        state_path = Path(settings.BASE_DIR) / "logs" / "uptime_state.json"
        state_path.parent.mkdir(exist_ok=True)
        try:
            state = json.loads(state_path.read_text())
        except Exception:  # noqa: BLE001 — first run / corrupt → fresh
            state = {"fails": 0, "alerted_down": False}

        now = datetime.now(dt_tz.utc).isoformat(timespec="seconds")
        if problems:
            state["fails"] = state.get("fails", 0) + 1
            state["last_problem"] = "; ".join(problems)
            if state["fails"] >= FAILS_BEFORE_ALERT and not state.get("alerted_down"):
                self._alert("Assisto DOWN / degraded",
                            f"{now} UTC — " + "; ".join(problems))
                state["alerted_down"] = True
                state["down_since"] = now
        else:
            if state.get("alerted_down"):
                self._alert("Assisto recovered",
                            f"{now} UTC — healthy again (down since "
                            f"{state.get('down_since', '?')}).")
            state = {"fails": 0, "alerted_down": False, "last_ok": now}

        state_path.write_text(json.dumps(state))
        self.stdout.write(f"{now} {'PROBLEM: ' + '; '.join(problems) if problems else 'OK'}")

    def _alert(self, subject, body):
        try:
            from core.push import notify_owner
            sent = notify_owner(subject, body)
        except Exception as e:  # noqa: BLE001 — alerting must never crash the check
            sent = {"error": type(e).__name__}
        self.stdout.write(f"ALERT {subject}: {body} → {sent}")
