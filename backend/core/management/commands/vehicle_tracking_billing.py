"""
vehicle_tracking_billing — monthly renewal of paired vehicle trackers (v1-vehicle).

Each paired tracker is paid through `billed_until` (first month charged at
pairing). When that has passed, debit `vehicle_tracking_month` credits for 30
more days. If the owner can't cover it, the tracker is DISABLED (the tracker
server then refuses it — never silently kept running unpaid) and the owner
gets an honest bn/en notification. Also marks never-connected pairings as
expired and prunes old positions. Idempotent; safe to run daily.

Crontab (daily 04:20, low priority):

  20 4 * * *  nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py vehicle_tracking_billing >> /home/ubuntu/assisto/backend/logs/vehicle_tracking_billing.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone


def run_billing(now=None):
    from core.models import VehicleTracker
    from core import vehicle_service as VS
    now = now or timezone.now()
    out = {"renewed": 0, "disabled": 0, "expired": 0, "pruned": 0}
    for t in VehicleTracker.objects.filter(state="paired", billed_until__lt=now) \
            .select_related("owner"):
        if VS.charge_month(t, now):
            out["renewed"] += 1
            VS.audit(t, "renewed")
        else:
            t.state, t.disabled_reason = "disabled", "no_credits"
            t.save(update_fields=["state", "disabled_reason", "updated_at"])
            VS.audit(t, "disabled_unpaid")
            VS._send([t.owner], "ট্র্যাকিং বন্ধ হয়েছে", "Tracking paused",
                     "পরের মাসের ক্রেডিট যথেষ্ট না থাকায় %s-এর ট্র্যাকিং বন্ধ রাখা "
                     "হয়েছে। ক্রেডিট যোগ করে আবার চালু করুন।" % (VS._vehicle_name(t) or "গাড়ি"),
                     "Tracking for %s is paused because there were not enough credits "
                     "for next month. Add credits and turn it back on."
                     % (VS._vehicle_name(t) or "your vehicle"),
                     {"tracker_id": t.id, "event": "disabled_unpaid"})
            out["disabled"] += 1
    out["expired"] = VehicleTracker.objects.filter(
        state="pending", pair_expires_at__lt=now).update(state="expired")
    out["pruned"] = VS.prune(now)
    VS.expire_commands(now)
    return out


class Command(BaseCommand):
    help = "Renew (charge) or pause vehicle trackers whose paid month ended."

    def handle(self, *args, **options):
        res = run_billing()
        self.stdout.write("vehicle_tracking_billing: renewed %(renewed)d, disabled "
                          "%(disabled)d, expired %(expired)d, pruned %(pruned)d" % res)
