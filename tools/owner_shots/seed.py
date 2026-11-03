# ownershots.yml only: a throwaway CI database with fictional people so the
# Owner Admin pages have something real-looking to show. Run with
#   python manage.py shell -c "exec(open('<this file>').read())"
import json
import os
import random
from datetime import timedelta

from django.utils import timezone

from core import admin_safety as AS
from core.models import (AccountAppeal, ActiveDay, AdminStaffRole, Device,
                         ModerationReport, OwnerTOTP, PushDeadMark, SupportTicket, User)
from web.owner import security as S

random.seed(7)
now = timezone.now()
today = timezone.localdate()
SECRET = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"


def totp_user(u):
    OwnerTOTP.objects.update_or_create(user=u, defaults={
        "secret_enc": S.encrypt(SECRET), "confirmed_at": now, "last_counter": 0,
        "recovery_hashes": []})


owner = User.objects.create_superuser(name="মালিক", phone="01700000001", password="shots-pass-123")
totp_user(owner)
names = ["রহিম উদ্দিন", "করিম মিয়া", "সালমা বেগম", "নাসরিন আক্তার", "জামাল হোসেন",
         "ফাতেমা খাতুন", "আরিফ হাসান", "শাহিনা পারভীন", "মাহমুদ আলী", "রুমানা ইসলাম",
         "তানভীর আহমেদ", "সুমাইয়া রহমান", "ইমরান খান", "নুসরাত জাহান", "হাবিবুর রহমান"]
users = []
for i, n in enumerate(names):
    u = User.objects.create_user(name=n, phone="0171%07d" % (2000 + i), password="x-pass-123",
                                 email="user%d@example.com" % i)
    joined = now - timedelta(days=random.randint(0, 70))
    User.objects.filter(pk=u.pk).update(date_joined=joined, app_version="1.0.%d" % (280 + i % 10))
    users.append(u)
    for d in range(30):
        if random.random() < (0.75 if i < 9 else 0.15):
            day = today - timedelta(days=d)
            if day >= timezone.localdate(joined):
                ActiveDay.objects.get_or_create(user=u, day=day, defaults={
                    "cohort_day": timezone.localdate(joined)})
    last = ActiveDay.objects.filter(user=u).order_by("-day").first()
    if last:
        User.objects.filter(pk=u.pk).update(last_active=now - timedelta(days=(today - last.day).days))
    Device.objects.create(user=u, push_token="ci-token-%d" % i, brand="realme" if i % 2 else "samsung",
                          model="RMX3491" if i % 2 else "SM-A146", sdk_int=33, app_version="1.0.290")
User.objects.filter(pk__in=[users[13].pk]).update(last_active=now - timedelta(days=40))
User.objects.filter(pk=users[2].pk).update(trial_until=now + timedelta(days=5))
Device.objects.filter(user=users[14]).delete()
PushDeadMark.objects.create(user=users[14])

target = users[0]
SupportTicket.objects.create(user=target, message="ক্রেডিট কেটে গেছে কিন্তু উত্তর আসেনি, দেখবেন?")
ModerationReport.objects.create(reporter=users[1], target_kind="person", target_id=str(target.pk),
                                categories=["harassment"], note="বারবার অচেনা মেসেজ", valid=True)
w = AS.apply_action(target, "warn", "চ্যানেলে অভদ্র মন্তব্য", owner)
AS.apply_action(target, "restrict", "অচেনা মানুষকে বারবার মেসেজ", owner,
                days="7", kinds=["stranger_msg"])
AS.create_appeal(target, w.id, "আমি অন্যের কথা উদ্ধৃত করছিলাম, দয়া করে আবার দেখুন।")
s = AS.apply_action(users[5], "suspend", "প্রতারণার রিপোর্ট যাচাই চলছে", owner, days="3")
AS.create_appeal(users[5], s.id, "আমার ফোন চুরি হয়েছিল, ওই মেসেজ আমি পাঠাইনি।")
AS.apply_action(users[9], "ban", "ভুয়া পেমেন্ট স্ক্রিনশট দিয়ে প্রতারণা", owner)

staff = User.objects.create_user(name="সাপোর্ট টিম", phone="01700000002", password="shots-pass-123")
AdminStaffRole.objects.create(user=staff, role="readonly", granted_by=owner, note="CI")
totp_user(staff)
mod = User.objects.create_user(name="মডারেটর", phone="01700000003", password="shots-pass-123")
AdminStaffRole.objects.create(user=mod, role="moderator", granted_by=owner, note="CI")

with open(os.environ.get("SHOTS_SEED_OUT", "/tmp/owner_seed.json"), "w") as f:
    json.dump({"target": target.pk, "secret": SECRET}, f)
print("seeded", User.objects.count(), "users")
