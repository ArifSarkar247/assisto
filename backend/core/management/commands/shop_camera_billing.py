"""
shop_camera_billing — monthly renewal of EXTRA shop cameras (a2-cctv).

Business includes pricing.BUSINESS_INCLUDED_CAMERAS cameras (other plans 0).
For each owner, their ENABLED cameras across all sites are ranked oldest first;
the first N are included, the rest are "extra". An extra camera is paid through
`billed_until` (set at create time = now + 30 days). When that has passed, this
command debits `shop_extra_camera` credits for 30 more days. If the owner can't
cover it, the camera is DISABLED (never silently kept running unpaid) and the
owner gets an honest bn/en NotifEvent + push.

Also sweeps stale live-view sessions. Idempotent; safe to run daily.

Crontab (daily 04:10, low priority):

  10 4 * * *  nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py shop_camera_billing >> /home/ubuntu/assisto/backend/logs/shop_camera_billing.log 2>&1
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Renew (charge) or disable extra shop cameras whose paid period ended."

    def handle(self, *args, **options):
        res = run_billing()
        self.stdout.write("shop_camera_billing: renewed %(renewed)d, disabled "
                          "%(disabled)d, credits %(credits)d" % res)


def _notify_disabled(owner, cam, need):
    title_bn = "ক্যামেরা বন্ধ করা হয়েছে — %s" % (cam.name or "ক্যামেরা")
    title_en = "Camera turned off — %s" % (cam.name or "camera")
    body_bn = ("এই বাড়তি ক্যামেরার পরের ৩০ দিনের জন্য %d ক্রেডিট দরকার ছিল, কিন্তু "
               "যথেষ্ট ক্রেডিট নেই। তাই ক্যামেরাটি বন্ধ রাখা হয়েছে। ক্রেডিট যোগ করে "
               "শপ বক্স থেকে আবার চালু করুন।" % need)
    body_en = ("This extra camera needed %d credits for the next 30 days, but there "
               "weren't enough credits, so it has been turned off. Add credits and "
               "turn it back on in Shop Box." % need)
    try:
        from core.models import NotifEvent
        NotifEvent.objects.create(
            user=owner, type="business", title_bn=title_bn[:200],
            title_en=title_en[:200], body_bn=body_bn, body_en=body_en,
            route="business",
            meta={"source": "shop_camera_billing", "camera_id": cam.id,
                  "site_id": cam.site_id, "credits_needed": need})
    except Exception:
        pass
    try:
        from core import push
        push.safe_push(owner, "shop_alert", title_bn, title_en, body_bn, body_en,
                       data={"camera_id": cam.id, "site_id": cam.site_id,
                             "route": "business/shop-box"})
    except Exception:
        pass


def run_billing(now=None):
    from core.models import ShopCamera, User
    from core import shop_views as SV
    from core import shop_ops_views as OPS
    now = now or timezone.now()
    out = {"renewed": 0, "disabled": 0, "credits": 0}
    owner_ids = (ShopCamera.objects.filter(enabled=True)
                 .values_list("site__owner_id", flat=True).distinct())
    period = timedelta(days=SV.BILLING_PERIOD_DAYS)
    for oid in list(owner_ids):
        owner = User.objects.filter(pk=oid).first()
        if owner is None:
            continue
        included = SV._included_cameras(owner)
        cams = list(SV.owner_enabled_cameras(owner))
        for cam in cams[included:]:
            due = cam.billed_until or (cam.created + period)
            if due > now:
                continue
            need = SV._extra_camera_credits()
            if need <= 0:
                ShopCamera.objects.filter(pk=cam.pk).update(billed_until=now + period)
                out["renewed"] += 1
                continue
            got = SV._debit_camera_credits(owner, need,
                                           note="shop camera #%d monthly" % cam.id)
            if got >= need:
                ShopCamera.objects.filter(pk=cam.pk).update(
                    billed_until=max(due, now) + period)
                out["renewed"] += 1
                out["credits"] += got
            else:
                ShopCamera.objects.filter(pk=cam.pk).update(enabled=False)
                _notify_disabled(owner, cam, need)
                out["disabled"] += 1
    try:
        OPS._sweep_live(now)
    except Exception:
        pass
    return out
