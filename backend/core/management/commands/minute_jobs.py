"""minutejobs — the per-minute jobs in ONE process: journey_sweep, then
antitheft_escalate (core.ops_health.MINUTE_JOBS).

Why: each `manage.py <job>` process pays the Django start-up (~0.85 s CPU:
352 model classes, psycopg, django.http) plus, unless skipped, the system
checks, which import the whole URLconf / every view (~0.7 s CPU). Two jobs
every minute paid that twice. Here it is paid once, and checks are skipped
(call_command never runs them; requires_system_checks = [] for this command).

Same behaviour as the two old cron lines:
* each job takes its OWN existing flock (/tmp/assisto-<job>.lock, the very
  file `flock -n` used), non-blocking: a job whose previous run still holds
  its lock is skipped silently, exactly like `flock -n` — the other job still
  runs. No outer lock, so a slow journey sweep never holds back the
  anti-theft backstop;
* each job's own heartbeat (@track_job on its handle) is recorded as today,
  so ops_watch keeps seeing both jobs;
* isolation: a job that raises (or exits) is logged with its traceback and the
  next job still runs; the DB connection is reset in between;
* --log-dir DIR appends each job's output to DIR/<job>.log (the same files the
  old lines wrote), otherwise everything goes to stdout;
* exit code 1 when any job failed, else 0.

Crontab (replaces the journey_sweep + antitheft_escalate lines):
    see core.ops_health.minute_jobs_cron_line()
"""
import fcntl
import os
import sys
import traceback
from contextlib import contextmanager

from django.core.management import call_command
from django.core.management.base import BaseCommand
from django.db import connections

from core import ops_health


def reset_db():
    """Each job starts on a fresh DB connection, as in its own process, so a
    broken connection / aborted transaction never leaks into the next job.
    (Inside an atomic block — only in tests — the connection is left alone.)"""
    for conn in connections.all(initialized_only=True):
        try:
            if not conn.in_atomic_block:
                conn.close()
        except Exception:
            pass


@contextmanager
def job_lock(name):
    """Non-blocking flock on the job's lock file (flock(1)-compatible).
    Yields True when taken, False when another run holds it."""
    fh = open(ops_health.lock_path(name), "a")
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    finally:
        fh.close()


class Command(BaseCommand):
    help = "Run the per-minute jobs (journey_sweep, antitheft_escalate) in one process."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--log-dir", default="",
                            help="append each job's output to <dir>/<job>.log")
        parser.add_argument("--only", action="append", default=[],
                            help="run only this job (repeatable; for manual use)")

    def handle(self, *args, **opts):
        failed = []
        for name, kwargs in ops_health.MINUTE_JOBS:
            if opts["only"] and name not in opts["only"]:
                continue
            if not self.run_one(name, kwargs, opts["log_dir"]):
                failed.append(name)
        if failed:
            self.stderr.write("minute_jobs: failed: %s" % " ".join(failed))
            sys.exit(1)

    def run_one(self, name, kwargs, log_dir):
        """-> True when the job ran OK or was skipped by its lock."""
        out = None
        try:
            if log_dir:
                out = open(os.path.join(log_dir, "%s.log" % name), "a")
            stream = out or self.stdout
            with job_lock(name) as got:
                if not got:
                    return True
                reset_db()
                try:
                    call_command(name, stdout=stream, stderr=stream, **kwargs)
                    return True
                except SystemExit as e:
                    code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
                    if code == 0:
                        return True
                    stream.write("%s: exit %s\n" % (name, code))
                    return False
                except Exception:
                    stream.write("%s: FAILED\n%s" % (name, traceback.format_exc()))
                    return False
                finally:
                    try:
                        stream.flush()
                    except Exception:
                        pass
                    reset_db()
        except Exception:
            # lock file / log file trouble: report, never skip the next job
            self.stderr.write("minute_jobs: %s not run\n%s" % (name, traceback.format_exc()))
            return False
        finally:
            if out is not None:
                out.close()
