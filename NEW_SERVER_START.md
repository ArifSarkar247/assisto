# নতুন সার্ভারে Claude Code চালু করা (মালিকের জন্য)

নতুন সার্ভার: **assisto-server, 16.4.105.173** (lifeassisto.com)। Assisto ব্যাকএন্ড এখানে লাইভ।

## ১. SSH দিয়ে ঢুকুন
```
ssh -i ~/.ssh/assisto-key.pem ubuntu@16.4.105.173
```

## ২. Claude Code ইনস্টল করুন
```
curl -fsSL https://claude.ai/install.sh | bash    # অথবা npm i -g @anthropic-ai/claude-code
claude --version
```

## ৩. লগইন + tmux
```
sudo apt-get install -y tmux
tmux new -s assisto
claude            # প্রথমবার: ব্রাউজারে লগইন লিংক আসবে, অনুমোদন করুন
```
(tmux থেকে বেরোতে `Ctrl-b d`; আবার ঢুকতে `tmux attach -t assisto`।)

## ৪. প্রজেক্ট
- কোড: `/home/ubuntu/assisto` (GitHub থেকে clone করা, public)।
- ব্যাকএন্ড সার্ভিস: `sudo systemctl status assisto` (gunicorn, পোর্ট 8700, nginx-এর পেছনে)।
- DB: PostgreSQL, ডেটা মাইগ্রেট-করা। সিক্রেট: `/home/ubuntu/.assisto_secrets.env` + `backend/.env` (এই সার্ভারেই জেনারেট করা — git-এ নেই)।
- crons: check_went_dark (৫ মিনিট), purge_deletions (ঘণ্টায়), storage_recompute, shop_prune_snapshots, nightly backup, cert-renew, watchdog।
- coturn: turn.lifeassisto.com (৩৪৭৮)।

## ৫. Claude-কে যা বলবেন (রিজিউম)
> "Resume from memory `server-migration` + `antitheft-module`. Migration verified; continue the 20-Oct v2 roadmap on THIS server: Part 4 CCTV app UI + Shop Box + live view → Part 3 native voice assistant → Part 5 remote support → Part 6 anti-theft native Batch 6 + GT06 Batch 7 → Part 7 Premium-QA ≥9/10."

## নোট
- আমার memory/CLAUDE.md/resume নোট এই মেশিনেও কপি করতে চাইলে বলুন (credentials কপি করা হয় না)।
- Asalify সার্ভার এখনো Assisto-র পুরনো কপি চালাচ্ছে (assisto.asalify.com) — আপনার ফোন নতুন APK-তে আপডেট + কাজ নিশ্চিত হলে ৪৮ ঘণ্টা পর ওটা পুরোপুরি মুছে দেব।
