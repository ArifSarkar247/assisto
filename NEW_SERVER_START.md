# নতুন সার্ভারে Claude Code চালু + কাজ রিজিউম (মালিকের জন্য)

নতুন সার্ভার: **assisto-server, 16.4.105.173** (lifeassisto.com)। Assisto ব্যাকএন্ড এখানে লাইভ, আপনার ফোন এখন এই সার্ভারেই চলছে (যাচাই করা)।

## ১. SSH দিয়ে ঢুকুন
```
ssh -i ~/.ssh/assisto-key.pem ubuntu@16.4.105.173
```

## ২. Claude Code ইনস্টল + লগইন (tmux-এ)
```
sudo apt-get install -y tmux
curl -fsSL https://claude.ai/install.sh | bash    # অথবা npm i -g @anthropic-ai/claude-code
tmux new -s assisto
claude            # প্রথমবার: ব্রাউজারে লগইন লিংক আসবে, অনুমোদন করুন
```
(tmux থেকে বেরোতে `Ctrl-b d`; আবার ঢুকতে `tmux attach -t assisto`।)

## ৩. কোড আপ-টু-ডেট করুন (প্রথমবার)
```
cd /home/ubuntu/assisto
git stash -- app_latest.json 2>/dev/null; git pull --ff-only; git stash drop 2>/dev/null || true
```
(`app_latest.json` গিট-এর বাইরে publish স্ক্রিপ্ট আপডেট করে — তাই pull-এর সময় ওটা আলাদা রাখা হয়।)

## ৪. বিল্ড/পাবলিশ পাইপলাইন (এই সার্ভারে)
- `~/assisto/bin/` স্ক্রিপ্ট কপি করা আছে (publish-apk.sh, ship_watch.sh, lang_gate.py, gh, cleanup.sh …)।
- **একবার করুন:** `~/assisto/bin/gh auth login`  (GitHub Actions থেকে APK আর্টিফ্যাক্ট নামাতে দরকার)।
- Flutter লোকাল analyze চাইলে: `tools/flutter` এখানে নেই — দরকার হলে Claude-কে বলুন ইনস্টল করতে (CI বিল্ডে লাগে না)।
- publish-apk.sh এখন **এই** সার্ভারেই APK + app_latest.json লেখে (অ্যাপ এখন api.lifeassisto.com চেক করে)।

## ৫. প্রজেক্ট স্ন্যাপশট
- কোড: `/home/ubuntu/assisto` (git clone, origin = ArifSarkar247/assisto, public)।
- ব্যাকএন্ড: `sudo systemctl status assisto` (gunicorn, পোর্ট 8700, nginx-এর পেছনে)।
- DB: PostgreSQL, ডেটা মাইগ্রেট-করা (১৮৯ টেবিল, ৮ ইউজার, লগইন টোকেন সহ)।
- সিক্রেট: `/home/ubuntu/.assisto_secrets.env` + `backend/.env` (এই সার্ভারেই জেনারেট, git-এ নেই)।
- crons: check_went_dark (৫ মিনিট), purge_deletions (ঘণ্টায়), storage_recompute, shop_prune_snapshots, nightly backup, cert-renew, watchdog।
- coturn: turn.lifeassisto.com (৩৪৭৮)।

## ৬. এখন কোথায় আছি (রিজিউম পয়েন্ট — 2026-10-20)
- ✅ সার্ভার মাইগ্রেশন সম্পূর্ণ ও যাচাই (ফোন নতুন সার্ভারে লগইন + সব ডেটা ২০০)।
- ✅ **Build 144** — api.lifeassisto.com-only কাটওভার বিল্ড (CI স্মোক পাস)।
- ✅ **Build 145** — Part 4 Shop Box / CCTV লস-প্রিভেনশন **অ্যাপ UI** (Sites · Cameras · Alerts · Report; Business-গেটেড; signals-only, ভিডিও নেই)। ব্যাকএন্ড (shop_views.py, shop_guard.py) আগেই তৈরি।
- ⏳ পুরনো Asalify সার্ভার এখনো Assisto-র কপি চালাচ্ছে — ৪৮ ঘণ্টা (22 Oct ~18:17) পর, বা আপনি "clean now" বললে, ওখান থেকে Assisto পুরোপুরি মুছে ফেলা হবে।

## ৭. বাকি রোডম্যাপ (এই সার্ভারে করবেন)
1. **Part 3 — নেটিভ ভয়েস অ্যাসিস্ট্যান্ট** (default-assistant + wake word; lazy + crash-guarded; আসল স্মোক-টেস্ট)।
2. **Part 5 — রিমোট সাপোর্ট** (AnyDesk-এর মতো; পরিবারের ফোনে সাহায্য)।
3. **Part 6 — anti-theft নেটিভ Batch 6** (lost/stolen engine, smoke-gated) + **Batch 7** (GT06 গাড়ি-ট্র্যাকিং সার্ভার + Sell-my-vehicle)।
4. **Part 7 — Premium QA ≥৯/১০** (সব পারসোনা, bn/en, লেআউট, screenshot-review)।
   Part 4 লাইভ-ভিউ (WebRTC) আলাদা signaling দরকার — এই privacy-first বিল্ডে ইচ্ছাকৃতভাবে ভিডিও নেই।

## ৮. Claude-কে যা বলবেন (রিজিউম প্রম্পট)
> "Resume from memory `server-migration` + `antitheft-module`. Migration + cutover verified; builds 144 (cutover) and 145 (Part 4 Shop Box app UI) shipped. Continue on THIS server: `git pull`, then Part 3 native voice assistant → Part 5 remote support → Part 6 Batch 6 + GT06 Batch 7 → Part 7 Premium-QA ≥9/10. Publish via ~/assisto/bin/publish-apk.sh (run `gh auth login` first). Do NOT touch the old Asalify server except the agreed 48h cleanup."

## নোট
- credentials কখনো কপি করা হয় না — গিট/APK ছাড়া সিক্রেট এই সার্ভারেই জেনারেট/থাকে।
- পুরনো সার্ভারে আমি আর কোনো ডেভেলপমেন্ট করব না — শুধু আপনার কথায় ৪৮ঘণ্টা ক্লিনআপ।
