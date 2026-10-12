# Assisto — অগ্রগতি রিপোর্ট

## 🔖 লাইভ চেকলিস্ট (resume এখান থেকে)
লেজেন্ড: ✅ done · 🔨 in progress · ⏳ todo · 🔑 needs owner (key/account) · ⛔ blocked

**Phase 0**
- ✅ 0.2 লোগো · 0.3 নাম+আইকন+স্প্ল্যাশ+লগইন · 0.4 সাইনিং কি · 0.5 ইন-অ্যাপ আপডেট · 0.6 arm64 APK
- 🔑 0.1 Asalify CI fix — **needs owner** (ready patch: `owner_actions/asalify_ci_fix.md`). আমি live Asalify রিপোতে commit করিনি (সেফটি রুল + গার্ডরেইল)। কারণ (বাংলা): `ci.yml` প্রতি push+PR-এ চলে, `concurrency` নেই (দ্রুত একাধিক push একসাথে পুরো জব চালায়, একটাও ক্যানসেল হয় না), আর `timeout-minutes` নেই (আটকে গেলে ডিফল্ট ৬ ঘণ্টা চলে) → একদিনেই ২০০০ মিনিট শেষ। ফিক্স: `concurrency(cancel-in-progress)` + `timeout-minutes:15` (শুধু ওই ২টা লাইন)।
- ✅ 0.7 সিদ্ধান্ত: লোকাল Flutter বসানো হয়নি (ডিস্ক ≥9GB রাখতে); বদলে CI-তে `flutter analyze`+`test` ধাপ

**Step A — ভাইরাল ওয়েব টুল (assisto.asalify.com, লগইন ছাড়া)**
- ⏳ W1 CV স্কোর · ⏳ W2 স্ক্যাম চেকার · ⏳ W3 পাসপোর্ট/ভিসা ছবি · ⏳ W4 উৎসবের কার্ড

**V1 — অ্যাপ + ব্যাকএন্ড (ফিচার ১–২১)**
- ⏳ Part 2: (3) রিমাইন্ডার/নোট/To-Do · (2) Memory + "ভুলে যাও" · (20) autonomy/audit/undo · (21) sync/export/support
- ⏳ Part 3: (6) ভল্ট + এক্সপায়ারি · (14) ইমার্জেন্সি কার্ড + SOS
- ⏳ Part 4: (7) অ্যাকাউন্ট · (8) স্টেটমেন্ট/বাজেট · (9) ধার · (10) সঞ্চয়/সাবস্ক্রিপশন · (11) বিল গাইড
- ⏳ Part 5: (12) ফ্যামিলি/ওষুধ · (13) স্ক্যাম অ্যালার্ট · (15) বাচ্চার স্কুল
- ⏳ Part 6: (1) Life Scanner · (4) proactive · (5) planner/briefing · (16) বাংলা ভয়েস · (17) role-play · (18) মানসিক সাপোর্ট
- ⏳ Part 7: (19) Wrapped/ব্যাজ/ফ্যামিলি কার্ড/invite
- 🔨 AI layer (multi-provider, needs-key state) · Accessibility

**Owner-blocked (এগুলো আপনি দিলে চালু হবে):** ANTHROPIC_API_KEY (AI ফিচার) · GitHub billing (Nov 1 পর্যন্ত private বিল্ড বন্ধ) · Firebase (ক্রস-ডিভাইস push) · SMS/voice provider (কল/এসএমএস) · payment partner (বিল পে)

## 🧭 Decisions I made (unattended run)
- **0.7 Flutter লোকাল বসাইনি:** ডিস্ক ১১GB ফ্রি; Flutter ~২GB → ৯GB-র নিচে নামার ঝুঁকি (হার্ড রুল ≥9GB)। বদলে CI-তে `flutter analyze`/`test` ফেল-ফাস্ট ধাপ যোগ করছি।
- **secrets ফাইল:** `/home/ubuntu/.assisto_secrets.env` (chmod 600) canonical; backend/.env ও GitHub secrets এর সাথে সিঙ্ক।

---

## বাংলা সারসংক্ষেপ (সর্বশেষ: Part 1 ✅ সম্পন্ন)

Assisto V1 অ্যাপ বানানো শুরু হয়েছে — Asalify থেকে **সম্পূর্ণ আলাদা**, লাইভ Asalify-তে কোনো প্রভাব ছাড়াই।

### 📱 সর্বশেষ টেস্ট APK (লোগো + আইকন + ইন-অ্যাপ আপডেট)
**লিংক (build 3):** https://assisto.asalify.com/dl/qojkImV7OzDmJwK9jw8vex6D/assisto-part2-build3.apk
- Android ফোনে লিংকটা খুলুন → APK ডাউনলোড → "এই উৎস থেকে ইনস্টল" অনুমতি দিন → ইনস্টল। অ্যাপের নাম **Assisto**, নতুন লোগো আইকন।
- **এখন থেকে লিংক খুঁজতে হবে না:** অ্যাপ খুললে নিজেই চেক করে — নতুন ভার্সন থাকলে "নতুন আপডেট আছে" দেখায়, এক ট্যাপে ডাউনলোড + ইনস্টল।
- **সাইজ ~১৯ MB** (arm64, রিলিজ, সাইনড — আগের ১৬০MB থেকে অনেক ছোট)।
- **স্থায়ী সাইনিং কি:** সব ভার্সন একই কি দিয়ে সাইন হয় → আন-ইনস্টল না করেই আপডেট বসে। কি-র ব্যাকআপ সার্ভারে `~/assisto/secrets/` (git-এ নেই) + GitHub Actions secrets-এ। **এই কি হারালে Play Store-এ আপডেট দেওয়া যাবে না — নিরাপদে রাখুন।**

**লোগো:** নেভি-ব্লু গ্রেডিয়েন্ট রাউন্ডেড আইকন; সোনালি দুই হাত একটা জ্বলন্ত সায়ান মস্তিষ্ক (AI, ভেতরে সার্কিট লাইন) আলতো করে ধরে আছে — মানে "AI যে আপনার যত্ন নেয়"। অ্যাডাপ্টিভ আইকন (fg/bg আলাদা) + স্প্ল্যাশ স্ক্রিন।

**রিপো পাবলিক/প্রাইভেট (এই বিল্ড):** পাবলিক `2026-10-12 12:37:39 UTC` → বিল্ড → প্রাইভেট `2026-10-12 12:45:24 UTC` (~৮ মিনিট)। পুরো git হিস্ট্রি সিক্রেট-মুক্ত (DB পাসওয়ার্ড/SECRET_KEY/keystore পাসওয়ার্ড/PEM কি/টোকেন = ০)। রিপো এখন **PRIVATE**।

**এখন পর্যন্ত যা হয়েছে (Part 1 — অ্যাপ শেল):**
- ✅ **ব্যাকএন্ড (Django + PostgreSQL)** তৈরি, টেস্ট ও চালু — আলাদা DB (`assisto`), আলাদা DB ইউজার, আলাদা venv, আলাদা systemd সার্ভিস `assisto.service` (পোর্ট ৮৭০০, **CPUQuota=50%, MemoryMax=1G**)।
  - কাজ করছে: রেজিস্টার, লগইন (ফোন/ইমেইল + পাসওয়ার্ড), প্রোফাইল, "AI কী জানে" মেমোরি (যোগ/এডিট/মুছে), অডিট লগ, ডাটা এক্সপোর্ট, অ্যাকাউন্ট ডিলিট।
  - OTP ডিজাইন করা আছে কিন্তু **বন্ধ** (SMS প্রোভাইডার নেই — নকল SMS পাঠানো হয় না)।
- ✅ **HTTPS চালু:** `https://assisto.asalify.com` — আসল Let's Encrypt সার্টিফিকেট (certbot, অটো-রিনিউ)। Caddy-তে শুধু assisto-র ব্লক যোগ হয়েছে; **১২টি Asalify টেন্যান্ট আগের মতোই ঠিক আছে** (প্রতিবার যাচাই করা হয়েছে)।
- ✅ **Flutter অ্যাপ (Android)** কোড তৈরি — বাংলা-প্রথম UI, বাংলা ফন্ট বান্ডেল করা, অফলাইন-ফার্স্ট লোকাল স্টোরেজ (sqflite), লগইন, হোম, "AI কী জানে" পেজ, সেটিংস (অটোনমি ডায়াল, এক্সপোর্ট, ডিলিট, অডিট লগ)।
- ✅ **ক্লাউড APK বিল্ড** (GitHub Actions) সেটআপ — এই সার্ভারে Android SDK/Flutter বসানো হয়নি (Asalify ধীর হবে না)।

**এখন আপনার কাছ থেকে যা দরকার:**
1. **GitHub device-code অনুমোদন** — কোড দেখানো হয়েছে, github.com/login/device-এ বসান। (এটা হলেই প্রাইভেট রিপো বানিয়ে প্রথম APK বিল্ড হবে, আর আপনাকে গোপন ডাউনলোড লিংক দেব।)
2. **AI API key** — শুধু Part 5 (Life Scanner/ব্রিফিং) আর Part 4-এর প্রেসক্রিপশন OCR-এর জন্য। বাকি সব key ছাড়াই হচ্ছে।

**পরের ধাপ:** GitHub অনুমোদনের পর — প্রাইভেট রিপো → পুশ → APK বিল্ড → গোপন লিংক। তারপর Part 2 (রিমাইন্ডার + ভল্ট)।

---

## English details

### Separation (Asalify never touched)
| Item | Asalify | Assisto |
|---|---|---|
| Code | `~/asalify` | `~/assisto/backend`, `~/assisto/app` |
| Git | its own | new private repo (pending GitHub auth) |
| DB | PG16 `main`@5432 | DB `assisto` + role `assisto` (same cluster, isolated) |
| Port | 8000 | **8700** (127.0.0.1 only) |
| venv | its own | `~/assisto/.venv` |
| Service | its own | `assisto.service` — `CPUQuota=50%`, `MemoryMax=1G` |
| Web | Caddy blocks | one added `assisto.asalify.com` block |

Disk: Assisto footprint well under the 3 GB budget.

### TLS note (important for later)
Caddy on this box uses a global `on_demand_tls` with a `*.asalify.com` wildcard whose ask-endpoint (Asalify's app) denies `assisto`. That makes Caddy refuse to *proactively* issue a managed cert for `assisto.asalify.com`. Per your instruction we did **not** touch the global config. Instead the cert is issued **out-of-band by certbot** (HTTP-01 webroot served only inside the assisto block) and **pinned** in the assisto block (`tls <fullchain> <privkey>`). Auto-renewal: `certbot.timer` → deploy-hook `~/assisto/bin/caddy-deploy-hook.sh` (copies cert to a Caddy-readable path, `caddy validate`, `caddy reload` — never restart). `certbot renew --dry-run` passes.

### API (v1, token auth)
`/api/v1/`: `health`, `version`, `auth/register`, `auth/login`, `auth/logout`, `auth/otp/request` (503 until SMS), `me` (GET/PATCH), `memory/` (CRUD), `audit`, `export`, `account` (DELETE).

### App build / APK delivery
- Cloud build: `.github/workflows/android.yml` → debug-signed APK, `--dart-define=API_BASE=https://assisto.asalify.com`.
- Delivery (no GitHub login on your phone): `~/assisto/bin/publish-apk.sh` downloads the artifact to the server and serves it at a secret `https://assisto.asalify.com/dl/<token>/assisto-partN-<build>.apk`. Keeps only the last 3 APKs.

### Move plan (to Assisto's own server, zero user change)
All URLs come from ONE setting: backend `ASSISTO_BASE_URL`, app `--dart-define=API_BASE`. To move:
1. Provision new server; install the same stack; `git clone` the repo; create its own `.venv`, DB `assisto` + role.
2. `pg_dump` the `assisto` DB here → restore on the new server.
3. Point `assisto.asalify.com` DNS to the new server (**same hostname → users need zero change**; the pinned API URL in installed apps keeps working).
4. Move the certbot setup (or re-issue). Keep `ASSISTO_BASE_URL` identical.
5. Decommission here. (If a *new* domain/name is chosen later, that is a one-line setting change + one APK rebuild.)

### Pending (blocking next steps)
- **GitHub device-code authorization** (for private repo + APK build).
- **AI API key** — only for Part 4 (prescription OCR) & Part 5 (Life Scanner, briefing, proactive). Everything else proceeds without it.

### Signing (for later, before Play Store)
V1 test APKs are **debug-signed** (installable now). Before Play Store we will generate a **release keystore**, back it up safely (you hold it), and add it to CI as encrypted secrets.
