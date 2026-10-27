"""
Push reminders that just fell due (FCM, key-gated). Without Firebase
credentials this is a clean no-op ("push unavailable").

Window: a reminder fires when its fire time (due_at - remind_before_min) lies
in the last WINDOW_MIN minutes (default 5) and it is not done. Recurring
reminders (remmeter) fire at EVERY occurrence. All-day
(date_only) reminders are skipped — they have no specific time and the app's
morning briefing already covers them.

Idempotent WITHOUT a migration: a small JSON sent-marker file outside the repo
(env PUSH_REMINDER_STATE_FILE, default /home/ubuntu/.assisto_push_reminders.json)
records "<reminder_id>@<fire_time_iso>" keys; entries older than 2 days are
pruned. Editing a reminder's time produces a new key, so the new time fires
once too. The file is locked (fcntl) so overlapping cron runs cannot double-send.

The push carries the reminder title (it is the user's own data, sent only to
their own devices) + ids. Run every minute from cron, e.g.:
  * * * * *  cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 \
      /home/ubuntu/assisto/.venv/bin/python manage.py push_due_reminders \
      >> /home/ubuntu/assisto/backend/logs/push_reminders.log 2>&1
"""
import fcntl
import json
import os
from datetime import timedelta

from zoneinfo import ZoneInfo

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db.models import Q
from django.utils import timezone

from core import push
from core.models import Reminder

DEFAULT_STATE_FILE = "/home/ubuntu/.assisto_push_reminders.json"
KEEP_DAYS = 2
MAX_LEAD_MIN = 60 * 24 * 7          # remind_before_min is clamped to a week


def _state_path():
    return os.getenv("PUSH_REMINDER_STATE_FILE", DEFAULT_STATE_FILE)


def _lead(r):
    return timedelta(minutes=max(0, min(int(r.remind_before_min or 0),
                                        MAX_LEAD_MIN)))


def _rule(r):
    """The reminder's recurrence rule (dict) or None for a one-off. Mirrors
    the app (reminders_screen.ruleFromData): a rich recurrence_rule wins,
    else the simple `recurrence` enum at the due time of day."""
    rule = r.recurrence_rule if isinstance(r.recurrence_rule, dict) else {}
    if rule.get("freq"):
        return rule
    if r.recurrence and r.recurrence != "none":
        return {"freq": r.recurrence}
    return None


def _fire_at(r, now=None, window_min=5):
    """The fire instant to push for. One-off: due_at - lead. Recurring
    (remmeter): the occurrence whose (occurrence - lead) falls in the
    window; occurrences are computed in Dhaka wall-clock time like the app.
    None when nothing is due."""
    if _rule(r) is None:
        return r.due_at - _lead(r)
    if now is None:
        return None
    from core.logic import reminders_engine
    tz = ZoneInfo(settings.TIME_ZONE or "Asia/Dhaka")
    anchor = r.due_at.astimezone(tz).replace(tzinfo=None)
    start = (now - timedelta(minutes=window_min) + _lead(r)).astimezone(tz)
    try:
        occ = reminders_engine.next_occurrence(
            anchor, _rule(r), after=start.replace(tzinfo=None))
    except Exception:
        return None
    if occ is None:
        return None
    return occ.replace(tzinfo=tz) - _lead(r)


def due_reminders(now, window_min=5):
    """Not-done, timed reminders with a fire time in (now-window, now].
    Returns [(reminder, fire_at)]."""
    start = now - timedelta(minutes=window_min)
    qs = (Reminder.objects.filter(done=False, date_only=False,
                                  due_at__isnull=False)
          .filter(Q(due_at__gt=start, due_at__lte=now)
                  | Q(remind_before_min__gt=0, due_at__gt=start,
                      due_at__lte=now + timedelta(minutes=MAX_LEAD_MIN)))
          .select_related("user"))
    out = [(r, _fire_at(r)) for r in qs if _rule(r) is None]
    # remmeter: recurring reminders fire every occurrence, not only once at
    # the original due_at (their anchor stays in the past until acknowledged)
    rec = (Reminder.objects.filter(done=False, date_only=False,
                                   due_at__isnull=False, due_at__lte=now
                                   + timedelta(minutes=MAX_LEAD_MIN))
           .exclude(Q(recurrence="none") & Q(recurrence_rule={}))
           .select_related("user"))
    for r in rec:
        if _rule(r) is None:
            continue
        f = _fire_at(r, now, window_min)
        if f is not None:
            out.append((r, f))
    return [(r, f) for r, f in out if f is not None and start < f <= now]


def marker_key(r, fire_at=None):
    return "%s@%s" % (r.id, (fire_at or _fire_at(r)).isoformat())


class Command(BaseCommand):
    help = "Push reminders due in the last few minutes (FCM; no-op without key)."

    def add_arguments(self, parser):
        parser.add_argument("--window", type=int, default=5,
                            help="look-back window in minutes (default 5)")
        parser.add_argument("--state-file", default=None)

    def handle(self, *args, **opts):
        if not push.is_available():
            self.stdout.write("push_due_reminders: push unavailable (no key) - skipped")
            return
        now = timezone.now()
        path = opts.get("state_file") or _state_path()
        sent = skipped = 0
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
                     if isinstance(v, (int, float)) and v >= cutoff}
            for r, fire in due_reminders(now, opts.get("window") or 5):
                key = marker_key(r, fire)
                if key in state:
                    skipped += 1
                    continue
                n = push.push_to_user(
                    r.user, "reminder", "⏰ রিমাইন্ডার", "⏰ Reminder",
                    r.title, r.title,
                    data={"reminder_id": r.id,
                          "due_at": r.due_at.isoformat(),
                          # remmeter: the phone dedupes against its own
                          # alarm by reminder id + this fire time
                          "fire_at": fire.isoformat(),
                          "route": "reminders"},
                    high_priority=True,
                    # remmeter: DATA-ONLY so the app decides: silent when its
                    # own (exact) alarm already rang for this fire, ring now
                    # (and cancel the waiting alarm) when the alarm is late.
                    data_only=True)
                # mark even when 0 devices accepted: no device = nothing to
                # retry, and a failing send must not re-fire every minute.
                state[key] = now.timestamp()
                sent += 1 if n else 0
            fh.seek(0)
            fh.truncate()
            json.dump(state, fh)
            fcntl.flock(fh, fcntl.LOCK_UN)
        self.stdout.write(self.style.SUCCESS(
            "push_due_reminders: pushed=%d already_sent=%d" % (sent, skipped)))
