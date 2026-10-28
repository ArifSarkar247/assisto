"""ai-router: periodic provider health check (cron, every 5 minutes).

For every provider with a key: a FREE reachability + auth check (the
list-models endpoint — no tokens, no cost). A failure counts against that
provider's circuit breaker; a success moves an OPEN circuit to half-open so
the next real call can close it. Also re-checks the 80% / 100% spend alerts.

  */5 * * * * cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ai_health_check >> /home/ubuntu/assisto/logs/ai_health.log 2>&1
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Check AI provider health (free list-models calls) and spend alerts."

    @track_job("ai_health_check")
    def handle(self, *args, **opts):
        from core import ai, ai_router as R
        conf = R.cfg()
        provs = ai._providers()
        if not provs:
            self.stdout.write("ai_health_check: no AI keys configured — nothing to check")
            return
        for name, key in provs:
            ok, detail = ai.health_probe(name, key)
            R.mark_health(name, ok, detail, conf)
            st = R.states().get(name)
            self.stdout.write("%s: %s (%s) circuit=%s" % (
                name, "ok" if ok else "FAIL", detail, st.state if st else "closed"))
        sent = R.check_alerts(conf)
        for slug, level in sent:
            self.stdout.write("alert sent: %s %s" % (slug, level))
