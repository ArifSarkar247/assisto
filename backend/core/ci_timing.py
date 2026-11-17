"""speedproof — CI-only per-request server timing (never used on the live box).

settings_ci adds :class:`CiTimingMiddleware` ONLY when the env var
``ASSISTO_CI_TIMING_LOG`` names a file (perf2gb.yml sets it for the throw-away
Django inside the runner). One line per /api/ request:

    CITIMING <epoch_ms> <method> <path> <status> <server_ms> <queries>

``queries`` = SQL statements the request ran (django ``execute_wrapper``), so
an N+1 shows up as a big number next to a slow endpoint.
tools/perf2gb/collect.py turns the file into per-endpoint p50/p95 + max
queries. Paths keep their numeric ids here; the collector collapses them.
"""
import threading
import time

from django.db import connection

_lock = threading.Lock()


class _Counter:
    def __init__(self):
        self.n = 0

    def __call__(self, execute, sql, params, many, context):
        self.n += 1
        return execute(sql, params, many, context)


def timing_line(method, path, status, ms, queries, now_ms=None):
    """One log line (also used by the tests)."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    path = (path or "/").split("?")[0].replace(" ", "%20")[:200]
    return "CITIMING %d %s %s %d %.1f %d\n" % (now_ms, method, path, status, ms, queries)


class CiTimingMiddleware:
    def __init__(self, get_response):
        from django.conf import settings
        self.get_response = get_response
        self.path = getattr(settings, "CI_TIMING_LOG", "") or ""

    def __call__(self, request):
        if not self.path or not request.path.startswith("/api/"):
            return self.get_response(request)
        c = _Counter()
        t0 = time.perf_counter()
        with connection.execute_wrapper(c):
            response = self.get_response(request)
        ms = (time.perf_counter() - t0) * 1000
        try:
            line = timing_line(request.method, request.path, response.status_code, ms, c.n)
            with _lock, open(self.path, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass  # timing is evidence only; never fail a request for it
        return response
