# সার্ভারের কাজ (cron, সার্ভিস) — ১০০-র পথে (বোর্ড দল ২৩)

২ নভেম্বর ২০২৬ · শাখা `agent/moneyops` · সব পরীক্ষা CI-তে (`backend/core/tests_cronbar.py`)

## এক কথায়

সার্ভারে প্রতি মিনিট / ঘণ্টা / দিনে যে কাজগুলো নিজে চলে (রিমাইন্ডার পুশ, কল পরিষ্কার, বিলিং, ব্যাকআপ …), সেগুলোর প্রত্যেকটা এখন:

1. **হৃৎস্পন্দন (heartbeat) দেয়।** প্রতিবার চলার শুরু, শেষ, সময় ও ফল ডাটাবেসে লেখা হয়। টেস্ট প্রতিটা কাজ খুলে দেখে নেয় যে এটা আছে।
2. **ops_watch দেখে।** প্রতি ৫ মিনিটে দেখে, কোনো কাজ দেরিতে চলছে কি না, ব্যর্থ হচ্ছে কি না, আটকে আছে কি না, cron-এ নেই কি না, **বেশি সময় নিচ্ছে কি না (নতুন: "slow")**, আর **দুইবার চলছে কি না (নতুন: "double_run")**। সমস্যা হলে মালিককে push + ইমেইল যায় একবার, তারপর দিনে একবার মনে করায়, আর ঠিক হলে জানায়।
3. **দ্বিতীয়বার চালালে ক্ষতি হয় না।** একই মিনিটে বা একই দিনে আবার চালালে একই পুশ, একই চার্জ বা একই সারি দুবার হয় না (নিচের তালিকা দেখুন)।
4. **সময়ের সীমা আছে।** প্রস্তাবিত cron লাইনে `flock -n` (আগের রান শেষ না হলে নতুনটা শুরু হয় না) আর `timeout` (আটকে গেলে থামিয়ে দেয়) আছে। থামানো রান "exit 143 — stopped by the time limit" হিসেবে লেখা হয়, তাই মালিক জানতে পারেন।

## ছয়টি সারি — কী আছে, কী নেই, প্রস্তাবিত স্কোর

| সারি | আগে | এখন যা আছে (প্রমাণসহ) | এখনো যা নেই / বাগ | সেরা বিকল্প | প্রস্তাবিত স্কোর |
|---|---|---|---|---|---|
| cron.d-তে চলা কাজ | ৬১ | `JOBS`-এ ৪৮টি কাজ; প্রতিটার `handle`-এ `@track_job` (টেস্ট `EveryJobTrackedTests`); ops_watch এখন late / failing / stuck / not_scheduled / **slow** / **double_run** ধরে; প্রতিটার নিজের সময়সীমা (`max_s`, যেমন প্রতি মিনিটের কাজ ৫১ সেকেন্ড, দৈনিক কাজ ৩ ঘণ্টা); থামানো রান রেকর্ড হয় (exit 143) | লাইভ লাইনগুলোতে এখনো `timeout` নেই (মালিকের ধাপ ৩); System health পাতায় slow / double_run লাল "ব্যর্থ" ব্যাজে দেখায় (নিচের লেখায় কারণ থাকে) — আলাদা ব্যাজ পরের কাজ | Cronitor / Healthchecks.io (প্রতি কাজের ping + সময়সীমা) | **৮২** |
| ubuntu-crontab-এর কাজ ও দ্বিগুণ কাজ | ৫০ | ২ নভেম্বরের লাইভ cron পড়ে দেখা: **কোনো কাজ দুইবার চলছে না** (purge_disappearing / purge_l1_retention / uptime_check আগের দ্বিগুণ লাইন আর নেই); এখন কোনো কাজ দুই জায়গায় (ubuntu crontab + cron.d, বা পুরনো লাইন + minute_jobs) থাকলে ops_watch নিজে "double_run" সতর্কতা দেয় (টেস্ট `test_same_job_in_user_crontab_and_cron_d_is_double`) | bizagent_process / bizagent_couriers / bizagent_daily / world_refresh / world_job_alerts এখনো ubuntu crontab-এ, `flock` / `timeout` ছাড়া, লগ অন্য ফোল্ডারে (মালিকের ধাপ ৪) | Cronitor | **৭৫** |
| cron-এ নেই এমন কাজ | ২৩ | বোর্ডের ৪টি (run_watchers, generate_briefings, booking_reminders, retention_run) **এখন লাইভ cron-এ আছে**; `meter_low_alerts` cron-এ চলছিল কিন্তু কেউ দেখত না — এখন heartbeat + ops_watch; ৭টি কাজ (tcb_prices_fetch সহ) যেগুলো চলার কথা কিন্তু cron-এ নেই, সেগুলো এখন `JOBS`-এ — ops_watch "cron-এ নেই" দেখাবে ঠিক লাইনসহ (সৎ অবস্থা) | ৭টি লাইন বসানো বাকি (মালিকের ধাপ ২) | — | **৭০** |
| সার্ভিস (assisto, tracker, photo-worker) | ৫৯ | ২ নভেম্বর পড়ে দেখা: assisto, assisto-tracker, assisto-photo-worker, coturn, postgresql, nginx সব active; systemd: tracker ও photo-worker `Restart=always`, assisto ও coturn `Restart=on-failure` + ৫ মিনিটের watchdog (`/etc/cron.d/assisto-watchdog`); ops_watch এখন photo-worker-ও দেখে (আগে দেখত না); নতুন: **ops_watch নিজে বন্ধ হলে বাইরের সেবা জানাবে** (`OPS_DEADMAN_URL`) | dead-man URL বসানো বাকি (মালিকের ধাপ ৫); বাইরের uptime মনিটর নেই (GitHub uptime.yml বন্ধ) — পুরো বক্স বন্ধ হলে এখন কেউ জানায় না | UptimeRobot (ফ্রি, ৫ মিনিট) + Healthchecks.io (ফ্রি dead-man) | **৭০** |
| ব্যাকআপ ও ডিস্ক গার্ড | ৫৫ | রাতে ব্যাকআপ (০২:১৫ UTC) চলছে; **মাসিক রিস্টোর মহড়া পাস: ১ নভেম্বর, ২৮ সেকেন্ডে রিস্টোর, SQL ভুল ০** (`backend/logs/restore_test_last.json`); দৈনিক ডিস্ক গার্ড (৬৭% ব্যবহার, ৩২ GB খালি); ব্যাকআপ ও রিস্টোর দুটোরই heartbeat ও সময়সীমা (২ ঘণ্টা) | **অফসাইট কপি নেই** — "OFFSITE: not configured": সার্ভার নষ্ট হলে ব্যাকআপও যাবে (মালিকের ধাপ ৬) | Backblaze B2 / S3-সামঞ্জস্য বাকেট + restic | **৬৮** |
| Play-তে স্বয়ংক্রিয় আপলোড | ৬১ | STATUS অনুযায়ী বিল্ড ২৭৬–২৭৮ internal + closed testing-এ নিজে উঠেছে; স্ক্রিপ্ট শুধু internal ট্র্যাক ছুঁতে পারে | এটা cron নয় (বিল্ডের পরে চলে), তাই ops_watch-এ নেই; আপলোড ব্যর্থ হলে আলাদা সতর্কতা নেই | fastlane supply + Slack/ইমেইল সতর্কতা | **৬৫** |

## প্রতিটি কাজ দ্বিতীয়বার চালালে কী হয় (idempotent)

| কাজ | কেন দুবার পাঠায় / কাটে না |
|---|---|
| push_due_reminders, meter_low_alerts | ফাইল-লক + "পাঠানো হয়েছে" চিহ্ন; টেস্ট: meter ৩ বার চালালে পুশ ১টা |
| shop_camera_billing | **ঠিক করা হয়েছে:** আগে দুটো রান একসাথে চললে একই ক্যামেরার জন্য দুবার ক্রেডিট কাটতে পারত। এখন প্রতি ক্যামেরার সারি লক করে আবার দেখে, তারপর কাটে — কাটা ও নতুন তারিখ একসাথে সেভ। টেস্ট: পুরনো তালিকা নিয়ে দ্বিতীয় রান → কাটা ১ বারই |
| vehicle_tracking_billing | **ঠিক করা হয়েছে:** একই সমস্যা ও একই সমাধান (ট্র্যাকার সারি লক + আবার দেখা)। টেস্ট আছে |
| generate_briefings | যার আজকের ব্রিফ আছে তাকে বাদ দেয়; **ঠিক করা:** আগে সব ইউজার মেমরিতে তুলত, এখন প্রতি রানে সর্বোচ্চ ৫০০০ জন (`--limit`), বাকিরা পরের রানে। টেস্ট আছে |
| run_watchers | **ঠিক করা:** এক ঘণ্টার রানে সীমা ছিল না; এখন ৫০ মিনিট পর নতুন চেক শুরু করে না, বাকিগুলো পরের ঘণ্টায় আগে যায় (`--max-seconds`)। টেস্ট আছে |
| journey_sweep, antitheft_escalate, school_mode_tick, tagada_sweep, vault_expiry_alerts, vehicle_reminders, agent_nudges | ডাটাবেসে UNIQUE দাবি (claim) — একই সতর্কতা দুবার হয় না |
| booking_reminders, check_went_dark | বুকিং / ফোনে "পাঠানো হয়েছে" চিহ্ন; একসাথে দুটো রান হলে দুবার যেতে পারত — প্রস্তাবিত লাইনের `flock` এটা বন্ধ করে (মালিকের ধাপ ৩) |
| billing_daily, profit_guard_rollover, payments_sweep | রিপোর্ট / settle নিজেই দুবার চালানো নিরাপদ; মালিক-সতর্কতা get_or_create |
| world_job_alerts, bizagent_daily | ব্যবহারকারী প্রতি দিনে ১টা — কিন্তু নিচে বাগ ১ ও ২ দেখুন |
| ai_usage_monthly, probashi_daily, calls_delivery_snapshot, agent_memory_learn | মাসে একবার / প্রতি মানুষ-মাসে একটা রিপোর্ট / upsert / ৬ দিনের গার্ড |
| purge_*, shop_clip_purge, shop_prune_snapshots, retention ইত্যাদি | মুছে ফেলা কাজ — দ্বিতীয়বার কিছুই পায় না |

## পাওয়া বাগ যা এই শাখার ফাইলের বাইরে (ঠিক করতে ১ লাইন করে)

1. **world_job_alerts দিনে একবার চলে, কিন্তু "২৪ ঘণ্টা পার হয়েছে কি না" দেখে।** আজকের রান গতকালের চেয়ে কয়েক সেকেন্ড আগে পৌঁছালে বাদ পড়ে — প্রায় এক দিন পরপর চাকরির খবর যায় না। ঠিক: `core/world_service.py` `run_job_alerts`-এ `gap = timedelta(hours=24 / cap) - timedelta(minutes=30)`।
2. **bizagent_daily-র কম-স্টক সতর্কতা** — একই সমস্যা (`core/bizagent_service.py` `run_low_stock`: `timedelta(hours=24)` → `timedelta(hours=23)`)।
3. **run_watchers ঘণ্টায় চলে, কিন্তু ৬০ মিনিটের watcher "ঠিক ৬০ মিনিট হয়েছে কি না" দেখে** — দুই ঘণ্টায় একবার চেক হতে পারে। ঠিক: `core/watcher.py` `due()`-এ ৫ মিনিট ছাড়।
4. **Profit Guard-এর মালিক-সতর্কতা জীবনে একবারই যায়** (`core/billing.py` `_owner_alert` একই শিরোনামে get_or_create)। পরে আবার সীমা পেরোলে নীরব থাকবে। ঠিক: শিরোনামে তারিখ যোগ।
5. System health পাতায় "slow" ও "double_run"-এর নিজস্ব ব্যাজ নেই (`web/templates/owner/system_health.html`) — এখন লাল "ব্যর্থ" দেখায়, নিচে কারণ লেখা থাকে।

## মালিকের ধাপ (শুধু আপনি করতে পারেন) — ঠিক কমান্ড

> সব কমান্ড সার্ভারে `ubuntu` হিসেবে। প্রতিটির আগে ব্যাকআপ: `sudo cp /etc/cron.d/assisto-app /home/ubuntu/assisto-app.cron.bak.$(date +%F)`

**ধাপ ১ — পুরনো দুটো #OFF লাইন মুছুন** (এখন কমেন্ট, ক্ষতি করছে না; কিন্তু কেউ ভুল করে `#OFF` সরালে journey_sweep ও antitheft_escalate মিনিটে দুবার চলবে — যদিও এখন ops_watch সেটা "double_run" হিসেবে ধরবে):

```
sudo sed -i '/^#OFF .*manage\.py \(journey_sweep\|antitheft_escalate\)/d' /etc/cron.d/assisto-app
grep -c '^#OFF' /etc/cron.d/assisto-app            # 0 হওয়া উচিত
grep -c 'manage.py minute_jobs' /etc/cron.d/assisto-app   # 1 হওয়া উচিত
```

**ধাপ ২ — চলার কথা কিন্তু cron-এ নেই এমন ৭টি কাজ যোগ করুন** (৭ম: `tcb_prices_fetch` — TCB-র সরকারি বাজারদর দিনে একবার, moneybar শাখার সাথে আসে) (এই শাখা ডিপ্লয়ের পরে; আপনার অনুমোদন লাগে কারণ এগুলো মানুষকে / আপনাকে বার্তা পাঠায়)। agent_nudges ও agent_memory_learn `agent_core` সুইচ বন্ধ থাকলে কিছু করে না; probashi_daily `probashi_plan` বন্ধ থাকলে কিছু করে না; ezviz_poll_alarms EZVIZ চাবি না থাকলে কিছু করে না (কিন্তু প্রতি মিনিটে ~১ সেকেন্ড CPU খরচ — চাইলে চাবি দেওয়ার দিন যোগ করুন; তার আগে ops_watch দিনে একবার "cron-এ নেই" মনে করাবে):

```
sudo tee -a /etc/cron.d/assisto-app >/dev/null <<'EOF'
# cronbar 2 Nov: jobs that were meant to run
*/15 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-nudges.lock timeout -k 30 1530 nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py agent_nudges --quiet >> /home/ubuntu/assisto/backend/logs/agent_nudges.log 2>&1
0 17 * * 0 ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-memory-learn.lock timeout -k 30 14400 nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py agent_memory_learn --quiet >> /home/ubuntu/assisto/backend/logs/agent_memory_learn.log 2>&1
10 4 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-probashi-daily.lock timeout -k 30 14400 nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py probashi_daily >> /home/ubuntu/assisto/backend/logs/probashi_daily.log 2>&1
10 0 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-calls-delivery-snapshot.lock timeout -k 30 14400 nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py calls_delivery_snapshot >> /home/ubuntu/assisto/backend/logs/calls_delivery_snapshot.log 2>&1
10 4 1 * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-ai-usage-monthly.lock timeout -k 30 14400 nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py ai_usage_monthly >> /home/ubuntu/assisto/backend/logs/ai_usage_monthly.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-ezviz-poll-alarms.lock timeout -k 30 120 nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py ezviz_poll_alarms >> /home/ubuntu/assisto/backend/logs/ezviz_poll_alarms.log 2>&1
40 13 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-tcb-prices-fetch.lock timeout -k 30 600 nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py tcb_prices_fetch >> /home/ubuntu/assisto/backend/logs/tcb_prices_fetch.log 2>&1
EOF
cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ops_cron_file --diff   # MISSING (0) হওয়া উচিত
```

**ধাপ ৩ — (ঐচ্ছিক, সুপারিশকৃত) সব লাইনে flock + timeout।** প্রস্তাবিত পুরো ফাইল দেখুন ও মিলিয়ে নিন — এই কমান্ড কিছু বদলায় না:

```
cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ops_cron_file > /tmp/assisto-app.recommended
diff /etc/cron.d/assisto-app /tmp/assisto-app.recommended | less
```

পছন্দ হলে: `sudo cp /tmp/assisto-app.recommended /etc/cron.d/assisto-app` (ব্যাকআপ ও watchdog নিজেদের আলাদা ফাইলে থাকে — রেন্ডারার সেগুলো কমেন্ট হিসেবে দেখায়, দুবার বসায় না)। তারপর ৫ মিনিট পরে Owner Admin → System health-এ সব সবুজ কি না দেখুন। ফেরত যেতে: `sudo cp /home/ubuntu/assisto-app.cron.bak.<তারিখ> /etc/cron.d/assisto-app`।

**ধাপ ৪ — ubuntu crontab-এর ৫টি লাইন cron.d-তে আনা** (ধাপ ৩ করলে সেগুলো নতুন ফাইলে চলে আসে; তখন **অবশ্যই** পুরনোগুলো মুছবেন, নইলে দুবার চলবে — ops_watch "double_run" জানাবে):

```
crontab -l > /home/ubuntu/crontab.bak.$(date +%F)
crontab -l | grep -v 'manage.py \(bizagent_process\|bizagent_couriers\|bizagent_daily\|world_refresh\|world_job_alerts\)' | crontab -
crontab -l | grep -c 'manage.py'    # 0 হওয়া উচিত
```

**ধাপ ৫ — "পাহারাদারকে কে পাহারা দেয়?"** healthchecks.io-তে ফ্রি অ্যাকাউন্ট → নতুন check (period ৫ মিনিট, grace ১০ মিনিট) → ping URL কপি করুন, তারপর:

```
echo 'OPS_DEADMAN_URL=https://hc-ping.com/<আপনার-uuid>' >> /home/ubuntu/assisto/backend/.env
```

এরপর ops_watch প্রতি ৫ মিনিটে ping দেবে; cron বা পুরো সার্ভার বন্ধ হলে healthchecks.io আপনাকে ইমেইল/SMS করবে। সাথে UptimeRobot-এ (ফ্রি) `https://api.lifeassisto.com/api/v1/health` ৫ মিনিটে দেখার জন্য একটা monitor।

**ধাপ ৬ — অফসাইট ব্যাকআপ** (`owner_actions/OWNER_UNLOCK_LIST.md` অনুযায়ী বাকেটের চাবি দিন)। এটা না হওয়া পর্যন্ত ব্যাকআপ শুধু এই সার্ভারেই থাকে।

## যাচাই (নিজে দেখা যায়, কিছু বদলায় না)

- `manage.py ops_cron_file --diff` → MISSING / DOUBLE / OLD STAND-ALONE / NOT IN JOBS — চারটিই ০ হলে cron পুরোপুরি ঠিক।
- `manage.py ops_watch --dry-run` → প্রতিটি কাজের অবস্থা।
- Owner Admin → System health।

## সৎ সীমা

- `minute_jobs` লাইনে নিজের `timeout` নেই (এর ভেতরের প্রতিটা কাজ নিজের লক নেয়; একটা কাজ আটকে গেলে ওই প্রক্রিয়ার পরের কাজগুলো দেরি করবে, ops_watch "late/stuck" ধরবে)।
- `timeout` শুধু নতুন লাইনে; লাইভ লাইন বদলানো (ধাপ ৩) মালিকের কাজ।
- slow-এর সীমা হিসাব করা (ব্যবধানের ৮৫%), আসল লাইভ সময় দেখে মেলানো হয়নি — প্রথম সপ্তাহে কোনো কাজ ভুল করে "slow" হলে তার `max_s` বাড়াতে হবে।
- পুরো বক্স বন্ধ হলে বাইরের সেবা (ধাপ ৫) ছাড়া কেউ জানাবে না।
