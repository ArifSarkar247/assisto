# Assisto — অগ্রগতি রিপোর্ট

## বাংলা সারসংক্ষেপ (সর্বশেষ: Part 1)

Assisto V1 অ্যাপ বানানো শুরু হয়েছে — Asalify থেকে **সম্পূর্ণ আলাদা**, লাইভ Asalify-তে কোনো প্রভাব ছাড়াই।

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
