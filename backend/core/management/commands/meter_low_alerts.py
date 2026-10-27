"""
remmeter — push "your prepaid meter is running low" (FCM, key-gated).

For every user's prepaid meters (generic collections meter/meters +
meter/recharges) the PURE projection in core.logic.prepaid_meter.low_alert
decides whether the balance is estimated to run out within the meter's
alert window (default 3 days, user 1..7). We never read a meter remotely —
every number is an estimate from the user's own entries, and the push says
so ("by our estimate" / "আনুমানিক").

Limits (owner rule for proactive alerts):
  * quiet hours 21:00-09:00 Dhaka: nothing is sent (the next run after
    09:00 sends it);
  * at most MAX_ALERTS_PER_DAY meter pushes per user per day;
  * once per meter per (level, run-out date): a new recharge / reading moves
    the run-out date, so a later low gets its own alert.

Idempotent WITHOUT a migration: a JSON sent-marker file outside the repo
(env METER_ALERT_STATE_FILE, default /home/ubuntu/.assisto_meter_alerts.json),
flock-ed, pruned after 10 days. Hourly from cron, e.g.:
  15 * * * *  cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 \
      /home/ubuntu/assisto/.venv/bin/python manage.py meter_low_alerts \
      >> /home/ubuntu/assisto/backend/logs/meter_low_alerts.log 2>&1
"""
import fcntl
import json
import os
from collections import defaultdict
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from core import push
from core.logic import prepaid_meter as PM
from core.models import PaCollectionItem

DEFAULT_STATE_FILE = "/home/ubuntu/.assisto_meter_alerts.json"
KEEP_DAYS = 10


def _state_path():
    return os.getenv("METER_ALERT_STATE_FILE", DEFAULT_STATE_FILE)


def plan_alerts(now, state):
    """[(user, meter_id, alert, marker_key)] to send now. Pure over the DB
    rows + `state` (marker -> ts, plus 'day:<uid>:<date>' counters)."""
    local = timezone.localtime(now)
    if PM.in_quiet_hours(local.hour):
        return []
    today = local.date().isoformat()
    meters = (PaCollectionItem.objects.filter(collection="meter/meters")
              .select_related("user"))
    by_user = defaultdict(list)
    for m in meters:
        by_user[m.user_id].append(m)
    if not by_user:
        return []
    recharges = defaultdict(list)
    for r in PaCollectionItem.objects.filter(collection="meter/recharges",
                                             user_id__in=list(by_user)):
        recharges[(r.user_id, (r.data or {}).get("meter"))].append(r.data or {})
    out = []
    for uid, rows in by_user.items():
        sent_today = int(state.get("day:%s:%s" % (uid, today), 0))
        for m in rows:
            if sent_today >= PM.MAX_ALERTS_PER_DAY:
                break
            data = dict(m.data or {})
            a = PM.low_alert(data, recharges.get((uid, m.id), []),
                             as_of=local.date())
            if a is None:
                continue
            key = "%s:%s:%s" % (m.id, a["level"], a["runout_date"])
            if key in state:
                continue
            out.append((m.user, m.id, a, key))
            sent_today += 1
    return out


class Command(BaseCommand):
    help = "Push prepaid-meter low-balance alerts (estimates; capped; quiet hours)."

    def add_arguments(self, parser):
        parser.add_argument("--state-file", default=None)

    def handle(self, *args, **opts):
        if not push.is_available():
            self.stdout.write("meter_low_alerts: push unavailable (no key) - skipped")
            return
        now = timezone.now()
        path = opts.get("state_file") or _state_path()
        sent = 0
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(fd, "r+", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                state = json.loads(fh.read() or "{}")
                if not isinstance(state, dict):
                    state = {}
            except ValueError:
                state = {}
            cutoff = (now - timedelta(days=KEEP_DAYS)).timestamp()
            state = {k: v for k, v in state.items()
                     if k.startswith("day:")
                     or (isinstance(v, (int, float)) and v >= cutoff)}
            today = timezone.localtime(now).date().isoformat()
            state = {k: v for k, v in state.items()
                     if not k.startswith("day:") or k.endswith(":" + today)}
            for user, meter_id, a, key in plan_alerts(now, state):
                n = push.push_to_user(
                    user, "meter_low", a["title"]["bn"], a["title"]["en"],
                    a["body"]["bn"], a["body"]["en"],
                    data={"meter_id": meter_id, "level": a["level"],
                          "runout_date": a["runout_date"] or "",
                          "route": "prepaid_meter"})
                state[key] = now.timestamp()
                dk = "day:%s:%s" % (user.id, today)
                state[dk] = int(state.get(dk, 0)) + 1
                sent += 1 if n else 0
            fh.seek(0)
            fh.truncate()
            json.dump(state, fh)
            fcntl.flock(fh, fcntl.LOCK_UN)
        self.stdout.write(self.style.SUCCESS("meter_low_alerts: pushed=%d" % sent))
