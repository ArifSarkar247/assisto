# Assisto — OWNER UNLOCK LIST (কোন key কী খোলে, অগ্রাধিকার ক্রমে)

সব ফিচার **key ছাড়াই** চলে — key নেই মানে ঐ ফিচার সৎ "mock / connect a key" অবস্থায়
থাকে, অ্যাপ ভাঙে না। key পেস্ট করুন **Settings → Owner → Integrations** পেজে (এনক্রিপ্ট
হয়ে সংরক্ষিত হয়)। নিচে অগ্রাধিকার ক্রম — উপরেরগুলো আগে দিলে সবচেয়ে বেশি কাজে লাগবে।

## 🔴 টিয়ার ১ — লঞ্চের আগে (সবচেয়ে বেশি ফিচার খোলে)
| Key (slug) | কী খোলে |
|---|---|
| **anthropic** (AI) | পুরো AI স্তর: চ্যাট এজেন্ট, ইন-চ্যাট AI, কুইক টুলস, মর্নিং ব্রিফ, কন্ট্রাক্ট/ইন্টারভিউ/ব্লগ/খরচ-পরামর্শ, CRM AI, রোলপ্লে, মানসিক সাপোর্ট, বিল/স্ক্যান AI। **সবচেয়ে বেশি মূল্য — আগে দিন।** |
| **firebase** (push) | অ্যাপ-বন্ধ অবস্থায় কল-রিং, ফ্যামিলি অ্যালার্ট, রিমাইন্ডার পুশ। রিমাইন্ডার/ফ্যামিলি অ্যাপের জন্য জরুরি। |
| **google_places** (maps) | কাছের রেস্তোরাঁ/ফার্মেসি/ATM/হাসপাতাল, ম্যাপ নেভিগেশন। প্রতিদিনের ব্যবহার। |
| **sms** (OTP/alerts) | OTP লগইন + ফ্যামিলি SMS অ্যালার্ট। অথ + নিরাপত্তার জন্য গুরুত্বপূর্ণ। |

## 🟠 টিয়ার ২ — আয় শুরু করার সময়
| Key | কী খোলে |
|---|---|
| **play_billing** | ইন-অ্যাপ সাবস্ক্রিপশন / ক্রেডিট কেনা। |
| **bkash**, **nagad**, **sslcommerz** | পেমেন্ট (বিল/সাবস্ক্রিপশন/টপ-আপ) — বাংলাদেশ বাজার। অ্যাপ কখনো টাকা রাখে না। |
| **admob** | নন-পার্সোনালাইজড + rewarded বিজ্ঞাপন (vault/heal-এ কখনো নয়)। |
| **ekpay** | সরকারি/ইউটিলিটি বিল। |

## 🟡 টিয়ার ৩ — বিজনেস মোড
| Key | কী খোলে |
|---|---|
| **whatsapp** / **messenger** / **instagram** | বিজনেস সেলস অ্যাসিস্ট্যান্ট + CRM lead capture (অফিশিয়াল Cloud/Graph API)। |
| **courier** | অর্ডার → কুরিয়ার বুকিং ও স্ট্যাটাস (Pathao/Steadfast/RedX)। |
| **google_oauth** | AI Inbox, ইমেইল অ্যাসিস্ট্যান্ট, জব হান্টার (ইউজারের নিজের Gmail, restricted scope)। |
| **axon_erp** | CRM deal Won → ১-ক্লিক Axon ERP অনবোর্ডিং। |

## 🟢 টিয়ার ৪ — AI বর্ধিতাংশ ও হেলথ
| Key | কী খোলে |
|---|---|
| **ocr** | ডকুমেন্ট স্ক্যানার/ফাইলিং/ভাউচার → টেক্সট (বাংলা+ইংরেজি)। |
| **transcription** | ভয়েস-নোট/মিটিং-মিনিটস/কল ট্রান্সক্রিপশন (দুই পক্ষকে জানানো হয়)। |
| **voice_clone** | মালিকের যাচাইকৃত নিজের কণ্ঠে AI উত্তর/ব্রিফ (#১৪, সম্মতি-নির্ভর)। |
| **weather** / **news** | মর্নিং ব্রিফে আবহাওয়া ও খবর। |
| **health_connect** | স্মার্টওয়াচ ডেটা (Android — #৭০ ইতিমধ্যে ওয়্যারড)। |

## ⚪ টিয়ার ৫ — ঐচ্ছিক
| Key | কী খোলে |
|---|---|
| **telegram** | টেলিগ্রাম বট লাইভ (BotFather টোকেন)। টোকেন ছাড়া নিষ্ক্রিয় sandbox। |
| **spotify** / **youtube** | প্রিয় শিল্পীর রিলিজ / চ্যানেল (YouTube key ছাড়াও RSS-এ চলে)। |
| **smart_home** | ভয়েসে ঘরের ডিভাইস নিয়ন্ত্রণ। |
| **ivr** | ফ্যামিলি-কেয়ার ভয়েস-কল রিমাইন্ডার। |
| **gemini** / **openai** | Anthropic ডাউন হলে ব্যাকআপ AI। |
| **price_feed** (রেজিস্ট্রিতে নেই এখনো) | #৩৪ মার্কেট প্রাইস রাডার লাইভ দাম — প্রোভাইডার বাছলে যোগ করা হবে। |

---

## ✅ সদ্য চালু (key লাগেনি — ২০২৬-১০-২০)
এই ফিচারগুলো আগে কোড-এ ছিল কিন্তু নেভিগেশনে পৌঁছানো যেত না / audit-এ "off" লেখা ছিল। এখন চালু, **কোনো key লাগে না**:
- **Bargaining rules** (দরদামের নিয়ম — Premium) ও **Business plans** (ফ্রি বনাম প্রিমিয়াম) — আগে orphan স্ক্রিন ছিল, এখন **Business Hub**-এ টাইল + চ্যাট-নেভ রুট (`bargain_rules`, `business_plans`) যোগ করা হয়েছে। Bargaining Premium-gated (স্ক্রিন নিজে gate দেখায়); Plans সবার জন্য খোলা।
- **Action Center — Pending approvals তালিকা**: audit বলেছিল backend endpoint deploy হয়নি — যাচাই করে দেখা গেছে `GET /actions/pending` + approve/reject + `PendingAction` মডেল সবই কোড-এ আছে ও কাজ করে (smoke-test পাস)। স্ক্রিন Settings → Audit log ও চ্যাট-নেভ (`action_center`) থেকে পৌঁছানো যায়। **কিছু করার নেই — ইতিমধ্যে চালু।**
- **Rule-based ফিচার (daily brief / social draft / mock interview / blog / spending advice / travel / contract / letters / language partner / research)**: সবগুলো আগে থেকেই আসল rule-based ফলাফল ডিফল্ট দেখায়; "AI key যোগ করুন" শুধু অতিরিক্ত upsell কার্ড, gate নয়। **কোনো পরিবর্তন লাগেনি।**

**এখনো key লাগবে (অপরিবর্তিত):** Dictionary পূর্ণ ডেটাসেট (ওপেন-লাইসেন্স bn↔en dataset এখনো bundle হয়নি → সৎ "offline dictionary data not bundled yet" state বহাল; কোনো ভুয়া অর্থ দেখানো হয় না), এবং §B-এর সব key-gated ফিচার (anthropic/weather/news/sms/firebase/…)।

**ইচ্ছাকৃতভাবে বাদ (এই রাউন্ডে):** Moderation appeal স্ক্রিন — এটির জন্য একটি নির্দিষ্ট `itemId` দরকার যা শুধু "আপনার কনটেন্টে ব্যবস্থা নেওয়া হয়েছে" ধরনের ইউজার-মুখী সারফেস থেকে আসে, যা এখনো তৈরি হয়নি; তাই static nav টাইল করা সম্ভব নয় (ভুয়া id দিলে ভাঙবে)। নেটিভ ফিচার (voice SOS, Health Connect, home widget, fall detection, camera) এই রাউন্ডে ছোঁয়া হয়নি — আলাদা smoke-build লাগবে।

---

## 🛟 অফ-সার্ভার ব্যাকআপ (জরুরি — এখন সব ব্যাকআপ শুধু এই সার্ভারেই আছে)
প্রতি রাত ২:১৫-এ এনক্রিপ্টেড ব্যাকআপ হয় (DB + মিডিয়া + সিক্রেট; AES-256; ১৪টা রাখা হয়; restore পরীক্ষিত ২০ অক্টোবর)।
কিন্তু সার্ভার নষ্ট হলে ব্যাকআপও যাবে — তাই বাইরে একটা কপি দরকার। আপনাকে দিতে হবে **যেকোনো একটি**:

| বিকল্প | আপনাকে যা তৈরি করতে হবে | খরচ |
|---|---|---|
| **Cloudflare R2 (সুপারিশ)** | R2-তে একটা bucket (যেমন `assisto-backups`) + "Object Read & Write" API token (শুধু ঐ bucket) → Access Key ID, Secret, Account ID | ১০GB পর্যন্ত ফ্রি |
| AWS S3 | একটা bucket (ap-south-1) + শুধু ঐ bucket-এ PutObject/GetObject/ListBucket অনুমতির IAM user → Access Key ID + Secret | ~৳৫/মাস |
| Backblaze B2 | একটা private bucket + ঐ bucket-এর Application Key → keyID + applicationKey | ১০GB পর্যন্ত ফ্রি |

**কীভাবে দেবেন (key চ্যাটে পেস্ট করবেন না):** সার্ভারে `migration/offsite.env.template` কপি করে পূরণ করুন:
```
cp ~/assisto/migration/offsite.env.template ~/.assisto_offsite.env && chmod 600 ~/.assisto_offsite.env && nano ~/.assisto_offsite.env
```
তারপর আমাকে বলুন "offsite ready" — আমি একটা টেস্ট আপলোড + সেখান থেকে restore যাচাই করব।

**ব্যাকআপ পাসফ্রেজ:** সার্ভারের `~/.assisto_backup_pass` ফাইলে আছে। এটা ছাড়া ব্যাকআপ খোলা যায় না, আর সার্ভার গেলে ফাইলটাও যাবে। একবার দেখে আপনার পাসওয়ার্ড ম্যানেজারে রাখুন: `cat ~/.assisto_backup_pass`

## 📣 আপটাইম অ্যালার্ট (api.lifeassisto.com ডাউন হলে)
- ⏳ **gh লগইনের পর push হলেই চালু (key লাগবে না):** GitHub Actions প্রতি ১০ মিনিটে সার্ভার বাইরে থেকে চেক করে; ডাউন হলে GitHub আপনার GitHub ইমেইলে "workflow failed" মেইল পাঠায়। পুরো সার্ভার বন্ধ থাকলেও কাজ করে।
- ✅ সার্ভারের ভেতরের চেক প্রতি ২ মিনিটে (API, অ্যাপ সার্ভার, SSL মেয়াদ, ডিস্ক)। Firebase দিলে ফোনে push-ও আসবে।
- ঐচ্ছিক — সার্ভার থেকে সরাসরি ইমেইল চাইলে: একটা SMTP অ্যাকাউন্ট (Gmail App Password বা Brevo ফ্রি) — `backend/.env`-এ বসাতে হবে, আমাকে বললে কোন ৪টা লাইন লিখবেন জানাব।

## এছাড়া আপনার যে অ্যাকশন বাকি (key নয়)
1. **কল সার্ভার পোর্ট** (এই সার্ভারে কল চালু করতে): `owner_actions/aws_ports.md` — 3478 udp/tcp + 49200-49300 udp খুলুন। (নতুন সার্ভারে গেলে provision.sh করে দেবে।)
2. **নেটিভ ফিচার ফোনে টেস্ট** (বিল্ড ৯৪-৯৭): ক্যামেরা, হেলথ কানেক্ট, উইজেট, ভয়েস SOS, হারানো/চুরি — চেকলিস্ট `.phaseB/up_*_integration.md` + আমার আগের বার্তায়।
3. **minSdk 26 নিশ্চিত করুন:** Health Connect-এর কারণে অ্যাপ এখন Android 8.0+ (আগে 6.0+)। ঠিক আছে কিনা জানান।
4. **সার্ভার মাইগ্রেশন:** `owner_actions/MIGRATION_DAY.md` (এক দিনের গাইড) + `migration/` স্ক্রিপ্ট — প্রমাণিত (dry-run ব্যাকআপ→restore টেস্ট পাস)।
5. **লিগ্যাল/দাম/কমিশন রিভিউ:** legal পেজ + প্ল্যান দাম + কমিশন — আপনার চূড়ান্ত অনুমোদন দরকার (code-এ "TO REVIEW BY OWNER")।
6. **নিজের ডোমেইন (সুপারিশ):** লঞ্চের আগে Assisto-র নিজস্ব ডোমেইন — `MIGRATION_DAY.md` §২।
