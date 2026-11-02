"""ops-watch: cron job + service health for the owner.

* ``track_job(name)`` — decorator on a management command's ``handle``: records
  start / finish / exit code / duration in ``JobHeartbeat``. Best-effort: a
  failing heartbeat write NEVER changes what the job does or returns.
* ``JOBS`` — every scheduled job with its expected interval and the exact cron
  line it should have (the /etc/cron.d/assisto-app style, user column
  ``ubuntu``). ``missing_cron()`` compares it with the installed crontab
  (``crontab -l`` + /etc/cron.d/*, read-only).
* ``job_status()`` — ok / late / failing / stuck / waiting / not_scheduled.
* ``service_status()`` — ``systemctl show`` (read-only) for the units the app
  needs; a unit that is not installed on this box is "absent", never "down".
* ``evaluate()`` — the alert state machine used by ``manage.py ops_watch``:
  alert when a check turns bad, remind once a day while it stays bad, tell the
  owner when it recovers (OpsAlertState rows = dedupe).

Owner-only delivery: core.push.notify_owner (active superusers; push + email).
"""
import functools
import glob
import logging
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from datetime import timezone as dt_tz
from pathlib import Path

from django.conf import settings
from django.utils import timezone

log = logging.getLogger(__name__)

APP = "/home/ubuntu/assisto"
PY = APP + "/.venv/bin/python"
LOGS = APP + "/backend/logs"
CRON_LOGS = LOGS   # cron lines always name the live log dir

MIN = 60
HOUR = 3600
DAY = 86400


@dataclass(frozen=True)
class Job:
    name: str
    interval: int            # seconds between runs (from the cron schedule)
    schedule: str            # the cron time fields
    nice: str = "nice -n15"
    lock: bool = False       # flock -n so a slow run never overlaps itself
    args: str = ""
    kind: str = "manage"     # manage | backup | restore_test
    grace: int = 0           # 0 = default_grace(interval)
    via: str = ""            # a wrapper command that also runs it (minute_jobs)

    @property
    def grace_s(self):
        return self.grace or default_grace(self.interval)

    def cron_line(self):
        if self.kind == "backup":
            return ("%s ubuntu %s/migration/backup.sh >>%s/backup.log 2>&1"
                    % (self.schedule, APP, CRON_LOGS))
        if self.kind == "restore_test":
            return ("%s ubuntu %s/migration/restore_test.sh >>%s/restore_test.log 2>&1"
                    % (self.schedule, APP, CRON_LOGS))
        lock = ("flock -n %s " % lock_path(self.name)) if self.lock else ""
        args = (" " + self.args) if self.args else ""
        return ("%s ubuntu cd %s/backend && %s%s %s manage.py %s%s >> %s/%s.log 2>&1"
                % (self.schedule, APP, lock, self.nice, PY, self.name, args, CRON_LOGS,
                   self.name))


def lock_path(name):
    """The flock file a job's cron line uses (minute_jobs takes the same one)."""
    return "/tmp/assisto-%s.lock" % name.replace("_", "-")


def default_grace(interval):
    """How long past its interval a job may be before it counts as late:
    one more interval, at least 5 min, at most 3 h (daily jobs: 27 h)."""
    return int(min(max(interval, 5 * MIN), 3 * HOUR))


# Every scheduled job. Order = the order of the System health page.
JOBS = (
    Job("push_due_reminders", MIN, "* * * * *", "nice -n15 ionice -c3"),
    Job("calls_sweep", MIN, "* * * * *", "nice -n10"),
    Job("turn_monitor", MIN, "* * * * *"),
    Job("bizagent_process", MIN, "* * * * *"),
    # minutejobs: both may run from their own two cron lines OR from the one
    # `manage.py minute_jobs` line (one Django start-up instead of two).
    Job("journey_sweep", MIN, "* * * * *", "nice -n10", lock=True, args="--quiet",
        via="minute_jobs"),
    Job("antitheft_escalate", MIN, "* * * * *", "nice -n10", lock=True,
        via="minute_jobs"),
    Job("tagada_sweep", 5 * MIN, "*/5 * * * *", "nice -n10", lock=True, args="--quiet"),   # ledger100
    Job("uptime_check", 2 * MIN, "*/2 * * * *"),
    Job("ops_watch", 5 * MIN, "*/5 * * * *", lock=True),
    Job("check_went_dark", 5 * MIN, "*/5 * * * *"),
    Job("booking_reminders", 5 * MIN, "*/5 * * * *", "nice -n15 ionice -c3"),
    Job("ai_health_check", 5 * MIN, "*/5 * * * *", lock=True),
    Job("purge_web_photos", 10 * MIN, "*/10 * * * *"),
    Job("purge_disappearing", 15 * MIN, "*/15 * * * *"),
    Job("retention_run", 15 * MIN, "*/15 * * * *", "nice -n15 ionice -c3"),
    Job("world_refresh", 15 * MIN, "*/15 * * * *"),
    Job("bizagent_couriers", 30 * MIN, "*/30 * * * *"),
    Job("purge_deletions", HOUR, "0 * * * *"),
    Job("payments_sweep", HOUR, "7 * * * *"),
    Job("vault_expiry_alerts", HOUR, "20 * * * *", "nice -n15 ionice -c3", lock=True,
        args="--quiet"),   # vault100
    Job("run_watchers", HOUR, "0 * * * *", "nice -n15 ionice -c3"),
    Job("vehicle_reminders", HOUR, "35 * * * *", "nice -n15 ionice -c3", lock=True,
        args="--quiet"),   # veh100
    Job("vehicle_daily_rollup", DAY, "45 3 * * *", "nice -n15 ionice -c3"),   # veh100
    # cashguard: encrypted event clips are deleted 24 h after upload
    Job("shop_clip_purge", HOUR, "17 * * * *", "nice -n15 ionice -c3"),
    # cctvx: no-sale checks, escalation steps, offline / late-opening checks
    Job("shop_guard_tick", MIN, "* * * * *", "nice -n10", lock=True),
    # kidswatch: school-mode late checks, watch battery plan, voice expiry
    Job("school_mode_tick", MIN, "* * * * *", "nice -n10", lock=True, args="--quiet"),
    Job("profit_guard_rollover", DAY, "5 0 * * *"),
    Job("backup", DAY, "15 2 * * *", kind="backup"),
    Job("generate_briefings", DAY, "0 3 * * *", "nice -n15 ionice -c3"),
    Job("storage_recompute", DAY, "15 3 * * *"),
    Job("shop_prune_snapshots", DAY, "30 3 * * *"),
    Job("purge_l1_retention", DAY, "30 3 * * *"),
    Job("world_job_alerts", DAY, "30 3 * * *"),
    Job("billing_daily", DAY, "40 3 * * *"),
    Job("shop_camera_billing", DAY, "10 4 * * *", "nice -n15 ionice -c3"),
    Job("vehicle_tracking_billing", DAY, "20 4 * * *", "nice -n15 ionice -c3"),
    Job("play_vitals_pull", DAY, "40 6 * * *"),
    Job("bizagent_daily", DAY, "0 15 * * *"),
    # AF-7: agent vault 30 days after a run, audit trail 12 months
    Job("agent_core_retention", DAY, "50 3 * * *", "nice -n15 ionice -c3", lock=True),
    # monthly backup-restore drill (owner order: "tested backup and restore")
    Job("restore_test", 31 * DAY, "30 2 1 * *", kind="restore_test", grace=3 * DAY),
)
JOB_BY_NAME = {j.name: j for j in JOBS}
# What `manage.py minute_jobs` runs, in order: (job name, call_command kwargs).
MINUTE_JOBS = (("journey_sweep", {"quiet": True}), ("antitheft_escalate", {}))


def minute_jobs_cron_line():
    """The one line that replaces the journey_sweep + antitheft_escalate lines.
    No outer flock on purpose: each job takes its own lock inside, so a slow
    journey sweep never holds back the anti-theft backstop."""
    return ("* * * * * ubuntu cd %s/backend && nice -n10 %s manage.py minute_jobs "
            "--log-dir %s >> %s/minute_jobs.log 2>&1" % (APP, PY, CRON_LOGS, CRON_LOGS))

SERVICES = ("assisto", "assisto-tracker", "coturn", "postgresql", "nginx", "caddy")


# ------------------------------------------------------------ heartbeats
def _now():
    return timezone.now()


def record_start(name):
    try:
        from .models import JobHeartbeat
        hb, _ = JobHeartbeat.objects.get_or_create(name=name[:48])
        hb.last_start = _now()
        hb.running = True
        hb.save(update_fields=["last_start", "running"])
    except Exception as e:  # noqa: BLE001 — never break the job
        log.warning("ops_health: start heartbeat %s failed (%s)", name, type(e).__name__)


def record_finish(name, rc, duration_ms, error=""):
    try:
        from django.db.models import F
        from .models import JobHeartbeat
        now = _now()
        JobHeartbeat.objects.get_or_create(name=name[:48])
        upd = dict(last_finish=now, last_rc=int(rc), running=False,
                   last_duration_ms=max(0, int(duration_ms)),
                   last_error=str(error or "")[:200])
        if int(rc) == 0:
            upd.update(last_ok=now, runs_ok=F("runs_ok") + 1, fails_in_row=0)
        else:
            upd.update(runs_failed=F("runs_failed") + 1,
                       fails_in_row=F("fails_in_row") + 1)
        JobHeartbeat.objects.filter(name=name[:48]).update(**upd)
    except Exception as e:  # noqa: BLE001
        log.warning("ops_health: finish heartbeat %s failed (%s)", name, type(e).__name__)


def track_job(name):
    """Decorator for ``Command.handle``: heartbeat around the run. The job's
    own result / exception / SystemExit pass through unchanged."""
    def deco(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            t0 = time.monotonic()
            record_start(name)
            rc, err = 0, ""
            try:
                return fn(*args, **kwargs)
            except SystemExit as e:
                code = e.code
                rc = code if isinstance(code, int) else (0 if code is None else 1)
                err = "" if rc == 0 else "exit %s" % rc
                raise
            except BaseException as e:  # noqa: BLE001 — recorded, then re-raised
                rc, err = 1, type(e).__name__
                raise
            finally:
                record_finish(name, rc, (time.monotonic() - t0) * 1000, err)
        return wrapper
    return deco


# ------------------------------------------------------------ cron
_CRON_COMMENT = re.compile(r"^\s*#")


def installed_cron_text():
    """Installed schedules, read-only: the user crontab + /etc/cron.d/*.
    Comment lines dropped. Never raises."""
    parts = []
    try:
        r = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            parts.append(r.stdout)
    except Exception:  # noqa: BLE001
        pass
    for f in sorted(glob.glob("/etc/cron.d/*")):
        try:
            parts.append(Path(f).read_text(errors="replace"))
        except Exception:  # noqa: BLE001
            pass
    lines = [ln for txt in parts for ln in txt.splitlines()
             if ln.strip() and not _CRON_COMMENT.match(ln)]
    return "\n".join(lines)


def is_scheduled(job, cron_text):
    if job.kind == "backup":
        pat = r"migration/backup\.sh"
    elif job.kind == "restore_test":
        pat = r"restore_test\.sh"
    else:
        names = [job.name] + ([job.via] if job.via else [])
        pat = r"manage\.py\s+(?:%s)(?:\s|$)" % "|".join(re.escape(n) for n in names)
    return re.search(pat, cron_text or "", re.M) is not None


def missing_cron(cron_text=None):
    """Jobs with no installed cron line -> [(job, exact line to add)]."""
    text = installed_cron_text() if cron_text is None else cron_text
    return [(j, j.cron_line()) for j in JOBS if not is_scheduled(j, text)]


# ------------------------------------------------------------ job status
def backup_files(backup_dir=None):
    d = backup_dir or getattr(settings, "OPS_BACKUP_DIR",
                              "/home/ubuntu/assisto_migration_backups")
    out = []
    try:
        for p in glob.glob(os.path.join(d, "assisto_backup_*.tar.gz.enc")):
            st = os.stat(p)
            out.append({"name": os.path.basename(p), "size": st.st_size,
                        "mtime": datetime.fromtimestamp(st.st_mtime, tz=dt_tz.utc)})
    except Exception:  # noqa: BLE001
        pass
    out.sort(key=lambda x: x["mtime"], reverse=True)
    return out


def offsite_state(log_path=None):
    """Last 'OFFSITE:' line of the backup log: uploaded / failed / not_configured / unknown."""
    p = log_path or os.path.join(LOGS, "backup.log")
    try:
        with open(p, "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 20000))
            tail = fh.read().decode(errors="replace")
    except Exception:  # noqa: BLE001
        return "unknown"
    lines = [ln for ln in tail.splitlines() if ln.startswith("OFFSITE:")]
    if not lines:
        return "unknown"
    last = lines[-1]
    if "uploaded" in last:
        return "uploaded"
    if "FAILED" in last:
        return "failed"
    if "not configured" in last:
        return "not_configured"
    return "unknown"


def restore_test_result(path=None):
    """The last restore drill's JSON result (migration/restore_test.sh), or None."""
    import json
    p = path or os.path.join(LOGS, "restore_test_last.json")
    try:
        return json.loads(Path(p).read_text())
    except Exception:  # noqa: BLE001
        return None


def job_status(job, hb=None, first_seen=None, now=None, scheduled=True,
               backups=None, restore=None):
    """-> dict(status, detail, last_run, last_ok, rc, duration_ms, next_due).

    status: ok | late | failing | stuck | waiting (no heartbeat yet, still
    inside the first grace period) | not_scheduled."""
    now = now or _now()
    last_run = getattr(hb, "last_finish", None) or getattr(hb, "last_start", None)
    last_ok = getattr(hb, "last_ok", None)
    rc = getattr(hb, "last_rc", None)
    if job.kind == "backup" and backups is not None:
        if backups:
            newest = backups[0]["mtime"]
            last_ok = max(filter(None, [last_ok, newest]))
            last_run = max(filter(None, [last_run, newest]))
            if rc is None:
                rc = 0
    if job.kind == "restore_test" and restore:
        try:
            at = datetime.fromisoformat(restore.get("finished_at"))
            if at.tzinfo is None:
                at = at.replace(tzinfo=dt_tz.utc)
            last_run = max(filter(None, [last_run, at]))
            if restore.get("ok"):
                last_ok = max(filter(None, [last_ok, at]))
                if rc is None or (getattr(hb, "last_finish", None) or at) <= at:
                    rc = 0
            elif (last_ok is None or at >= last_ok):
                rc = 1
        except Exception:  # noqa: BLE001
            pass
    out = {"status": "ok", "detail": "", "last_run": last_run, "last_ok": last_ok,
           "rc": rc, "duration_ms": getattr(hb, "last_duration_ms", None),
           "next_due": None, "fails_in_row": getattr(hb, "fails_in_row", 0) or 0}
    limit = timedelta(seconds=job.interval + job.grace_s)
    if last_run is not None:
        out["next_due"] = last_run + timedelta(seconds=job.interval)
    if not scheduled and last_run is None:
        out.update(status="not_scheduled", detail="no cron line installed")
        return out
    # a run that started long ago and never finished
    if getattr(hb, "running", False) and hb.last_start is not None:
        stuck_after = timedelta(seconds=max(2 * job.interval + job.grace_s, 30 * MIN))
        if now - hb.last_start > stuck_after:
            out.update(status="stuck", detail="running since %s"
                       % hb.last_start.strftime("%Y-%m-%d %H:%M UTC"))
            return out
    if rc not in (None, 0):
        out.update(status="failing", detail="exit code %s%s" % (
            rc, (" (%s)" % hb.last_error) if getattr(hb, "last_error", "") else ""))
        return out
    ref = last_ok or last_run
    if ref is None:
        start = first_seen or now
        if now - start > limit:
            out.update(status="late", detail="no run recorded since monitoring began %s"
                       % start.strftime("%Y-%m-%d %H:%M UTC"))
        else:
            out.update(status="waiting", detail="no run recorded yet")
        if not scheduled:
            out.update(status="not_scheduled", detail="no cron line installed")
        return out
    if now - ref > limit:
        out.update(status="late", detail="last successful run %s ago" % _ago(now - ref))
    return out


def _ago(td):
    s = int(td.total_seconds())
    if s >= 2 * DAY:
        return "%d days" % (s // DAY)
    if s >= 2 * HOUR:
        return "%d h" % (s // HOUR)
    return "%d min" % max(1, s // MIN)


BAD_JOB = ("late", "failing", "stuck", "not_scheduled")


# ------------------------------------------------------------ services
def parse_systemctl_show(text):
    """`systemctl show -p LoadState -p ActiveState -p SubState` output -> dict."""
    out = {}
    for ln in (text or "").splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def classify_service(props):
    """-> 'ok' | 'down' | 'absent' | 'unknown' from parsed systemctl props."""
    load = props.get("LoadState", "")
    active = props.get("ActiveState", "")
    if not load and not active:
        return "unknown"
    if load == "not-found":
        return "absent"
    if active in ("active", "reloading", "activating"):
        return "ok"
    return "down"


def _systemctl_show(unit):
    r = subprocess.run(["systemctl", "show", "-p", "LoadState", "-p",
                        "ActiveState", "-p", "SubState", unit],
                       capture_output=True, text=True, timeout=5)
    return r.stdout


def service_status(unit, runner=None):
    """Read-only. runner(unit) -> stdout text (tests inject one)."""
    try:
        text = (runner or _systemctl_show)(unit)
    except Exception:  # noqa: BLE001
        text = ""
    props = parse_systemctl_show(text)
    return {"unit": unit, "status": classify_service(props),
            "active": props.get("ActiveState", ""), "sub": props.get("SubState", "")}


def disk_state(path="/"):
    try:
        du = shutil.disk_usage(path)
        return {"used_pct": round(du.used * 100 / du.total, 1),
                "free_gb": round(du.free / 1e9, 1), "total_gb": round(du.total / 1e9, 1)}
    except Exception:  # noqa: BLE001
        return {"used_pct": None, "free_gb": None, "total_gb": None}


# ------------------------------------------------------------ snapshot
def snapshot(now=None, cron_text=None, service_runner=None):
    """Everything the System health page and ops_watch need. Never raises
    for an individual check."""
    from .models import JobHeartbeat, OpsAlertState
    now = now or _now()
    if cron_text is None:
        cron_text = installed_cron_text()
    cron_known = bool(cron_text.strip())
    hbs = {h.name: h for h in JobHeartbeat.objects.all()}
    seen = {s.key: s.first_seen for s in OpsAlertState.objects.filter(key__startswith="job:")}
    backups = backup_files()
    restore = restore_test_result()
    jobs = []
    for j in JOBS:
        sched = is_scheduled(j, cron_text) if cron_known else True
        st = job_status(j, hbs.get(j.name), seen.get("job:" + j.name), now,
                        scheduled=sched, backups=backups, restore=restore)
        st.update(name=j.name, interval=j.interval, scheduled=sched,
                  cron_line=j.cron_line())
        jobs.append(st)
    services = [service_status(u, service_runner) for u in SERVICES]
    return {"now": now, "jobs": jobs, "services": services, "disk": disk_state(),
            "backups": backups, "offsite": offsite_state(), "restore": restore,
            "cron_known": cron_known,
            "missing": [(j["name"], j["cron_line"]) for j in jobs if not j["scheduled"]]}


def checks_from(snap):
    """-> [(key, bad, detail, need)] — `need` = consecutive bad runs before
    the first alert (services 2, like uptime_check; jobs 1: lateness already
    has its own grace)."""
    out = []
    for j in snap["jobs"]:
        bad = j["status"] in BAD_JOB
        detail = "%s: %s%s" % (j["name"], j["status"],
                               (" — " + j["detail"]) if j["detail"] else "")
        if j["status"] == "not_scheduled":
            detail += ". Add: " + j["cron_line"]
        out.append(("job:" + j["name"], bad, detail[:300], 1))
    for s in snap["services"]:
        if s["status"] == "absent":
            continue
        out.append(("svc:" + s["unit"], s["status"] == "down",
                    "service %s is %s (%s)" % (s["unit"], s["active"] or "?", s["sub"] or "?"), 2))
    return out


REMIND_EVERY = timedelta(hours=24)


def evaluate(checks, now=None):
    """Advance OpsAlertState for each check. -> (new_bad, reminders, recovered)
    lists of detail strings. Persists state; never raises per check."""
    from .models import OpsAlertState
    now = now or _now()
    new_bad, remind, recovered = [], [], []
    for key, bad, detail, need in checks:
        try:
            st, _ = OpsAlertState.objects.get_or_create(key=key[:64],
                                                        defaults={"first_seen": now})
            if bad:
                st.bad_count += 1
                st.detail = detail[:300]
                if not st.bad and st.bad_count >= need:
                    st.bad, st.since, st.alerted_at = True, now, now
                    new_bad.append(detail)
                elif st.bad and (st.alerted_at is None or now - st.alerted_at >= REMIND_EVERY):
                    st.alerted_at = now
                    remind.append(detail)
            else:
                if st.bad:
                    recovered.append("%s — OK again (problem since %s)" % (
                        key, st.since.strftime("%Y-%m-%d %H:%M UTC") if st.since else "?"))
                st.bad, st.bad_count, st.since = False, 0, None
                st.detail = detail[:300]
            st.save()
        except Exception as e:  # noqa: BLE001
            log.warning("ops_health: evaluate %s failed (%s)", key, type(e).__name__)
    return new_bad, remind, recovered


def compose(new_bad, remind, recovered):
    """One owner message per ops_watch run, or None."""
    if not (new_bad or remind or recovered):
        return None
    n = len(new_bad) + len(remind)
    if n:
        subject = "Assisto ops: %d problem%s" % (n, "" if n == 1 else "s")
    else:
        subject = "Assisto ops: recovered"
    parts = []
    if new_bad:
        parts.append("NEW:\n" + "\n".join("- " + d for d in new_bad))
    if remind:
        parts.append("STILL BAD:\n" + "\n".join("- " + d for d in remind))
    if recovered:
        parts.append("RECOVERED:\n" + "\n".join("- " + d for d in recovered))
    parts.append("Owner Admin -> System health: https://lifeassisto.com/owner/system")
    return subject, "\n\n".join(parts)
