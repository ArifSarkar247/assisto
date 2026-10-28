# ব্যাকআপ রিস্টোর পরীক্ষা (Backup → Restore, আসলে চালিয়ে দেখা)

মালিকের নির্দেশ (২৭ Oct): "tested backup and restore"। এখানে শুধু **আসলে চালানো** ফল লেখা হয়।

## শেষ পরীক্ষা — ২৭ Oct ২০২৬, ১৮:০৪–১৮:০৫ UTC — ✅ পাস

| কী | ফল |
|---|---|
| ব্যাকআপ ফাইল | `assisto_backup_20261027_172020.tar.gz.enc` (২.৭ MB, এনক্রিপ্টেড, sha256 মিলেছে) |
| কোথায় রিস্টোর | একই সার্ভারের Postgres-এ **অস্থায়ী আলাদা ডাটাবেস** `assisto_restore_test_20261027_180456` — লাইভ ডাটাবেস ছোঁয়া হয়নি; শেষে মুছে ফেলা হয়েছে |
| রিস্টোরে সময় | **২০ সেকেন্ড** (ডিক্রিপ্ট + পুরো ডাটাবেস লোড); সব মিলিয়ে ২৫ সেকেন্ড |
| SQL ত্রুটি | ০ |
| টেবিল | ৩০৮টি ফেরত এসেছে |
| মাইগ্রেশন | `0095_billing_v2` = ব্যাকআপের MANIFEST = লাইভ ডাটাবেস |
| মূল টেবিলের সারি (রিস্টোর / লাইভ) | ইউজার ২৯/২৯ · সার্কেল সদস্য ৪১/৪১ · মেসেজ ১৪২/১৪২ · সক্রিয়-দিন ২৯/২৯ · ইনস্টল ১৮৫/১৮৫ · অডিট ১৬৩/১৬৩ · ক্র্যাশ রিপোর্ট ৫/৫ · মাইগ্রেশন ১২৩/১২৩ |
| চালানো হয়েছে | `~/assisto/bin/heavy.sh bash migration/restore_test.sh` (লাইভ অ্যাপ ব্যস্ত থাকলে অপেক্ষা করে) |

শুধু `db.sql.gz` আর `MANIFEST.txt` খোলা হয় — secrets, মিডিয়া, keystore ডিস্কে নামে না। লাইভ ডাটাবেস শুধু-পড়া (read-only) সেশনে গোনা হয়।

## ⚠️ যা এখনো ঝুঁকি
* **বাইরের কপি (off-site) চালু নেই** — `backup.log`: "OFFSITE: not configured — this backup exists ONLY on this server"। সার্ভার নষ্ট হলে ব্যাকআপও যাবে। মালিকের কাজ: `owner_actions/OWNER_UNLOCK_LIST.md` অনুযায়ী `/home/ubuntu/.assisto_offsite.env` বসানো (R2/B2/S3)।
* মিডিয়া (ছবি) ফাইলের রিস্টোর এই পরীক্ষায় নেই — শুধু ডাটাবেস।

## প্রতি মাসে (স্বয়ংক্রিয়)
এই cron লাইন `/etc/cron.d/assisto-app`-এ (root হিসেবে) যোগ করুন:
```
30 2 1 * * ubuntu /home/ubuntu/assisto/migration/restore_test.sh >>/home/ubuntu/assisto/backend/logs/restore_test.log 2>&1
```
ফল `backend/logs/restore_test_last.json`-এ আর Owner Admin → **System health** পাতায়। ৩১ দিন (+৩ দিন) পেরোলে বা পরীক্ষা ব্যর্থ হলে `ops_watch` মালিককে পুশ + ইমেইল দেয়।
