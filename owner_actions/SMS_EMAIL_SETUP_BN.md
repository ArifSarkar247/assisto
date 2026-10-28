# SMS ও ইমেইল সেটআপ — মালিকের জন্য (smsotp, ২৭ অক্টোবর)

কোড পুরো তৈরি। আপনি শুধু **Owner Admin → Integrations**-এ আপনার SMS প্যাকেজের তথ্য আর
কোম্পানি Gmail-এর App password বসাবেন। কোনো নতুন বিল্ড বা ফ্ল্যাগ লাগবে না —
**"Send test SMS" / "Send test email" সফল হলেই (CONNECTED) সাথে সাথে চালু।**
তথ্য না দেওয়া পর্যন্ত অ্যাপ সৎভাবে দেখায় "SMS কোড এখনো চালু হয়নি" আর পাসওয়ার্ডে সব চলে।

---

## ক) STATUS-এর জন্য ছোট টেবিল — আপনার গেটওয়ের ঘরগুলো পূরণ করুন

| গেটওয়ে | Owner Admin-এ এন্ট্রির নাম | যে ঘরগুলো লাগবে (✱ = গোপন) |
|---|---|---|
| SSL Wireless | SMS — SSL Wireless (ISMS) | ✱API Token · SID · (ঐচ্ছিক API base) · প্রতি অংশের খরচ ৳ |
| BulkSMSBD | SMS — BulkSMSBD | ✱API Key · Sender ID · (ঐচ্ছিক API URL) · প্রতি অংশের খরচ ৳ |
| Alpha SMS (sms.net.bd) | SMS — Alpha SMS (sms.net.bd) | ✱API Key · Sender ID (ঐচ্ছিক) · প্রতি অংশের খরচ ৳ |
| Infobip | SMS — Infobip | Base URL · ✱API Key · Sender · প্রতি অংশের খরচ ৳ |
| Twilio (বিদেশি ব্যাকআপ) | SMS — Twilio | Account SID · ✱Auth Token · From (নম্বর বা MG…) · প্রতি অংশের খরচ ৳ |
| অন্য যেকোনো দেশি গেটওয়ে (MiM SMS, Muthofun, Elitbuzz, Reve…) | SMS — Generic HTTP gateway | API URL টেমপ্লেট ({to} {text} {sender} {api_key}) · ✱API Key · মেথড GET/POST · সফলতা regex · Sender ID · প্রতি অংশের খরচ ৳ |
| কোম্পানি Gmail (ইমেইল OTP) | Email — SMTP (Gmail) | Host smtp.gmail.com · Port 587 · Username assistoaiagent@gmail.com · ✱App password (১৬ অক্ষর) · From name Assisto |

তিন লাইনে: (১) আপনার প্যাকেজ যে কোম্পানির, তার এন্ট্রি খুলে ঘরগুলো পেস্ট করে Save করুন।
(২) নিজের নম্বর লিখে "টেস্ট SMS পাঠান" চাপুন — ফোনে SMS এলে আর CONNECTED দেখালেই OTP, ফোন যাচাই, তাগাদা আর সেফটি SMS চালু।
(৩) Gmail-এর App password বসিয়ে "টেস্ট ইমেইল পাঠান" চাপুন — তাহলে SMS না এলে ইমেইলে কোড যাবে।

---

## খ) প্রতিটি গেটওয়ের ঘর — বিস্তারিত (কোথায় পাবেন, কোন ডকুমেন্ট থেকে)

> "নিশ্চিত নয়" লেখা জিনিসগুলো **আপনার গেটওয়ের account manager-কে জিজ্ঞেস করে নিশ্চিত করুন**
> (verify with your account manager)। টেস্ট SMS পাঠালেই বোঝা যায় ঠিক আছে কি না।

### ১. SSL Wireless (ISMS Plus) — এন্ট্রি `sms_ssl_wireless`
| ঘর | কোথায় পাবেন |
|---|---|
| API Token (গোপন) | ISMS প্যানেল (smsplus.sslwireless.com) → API / Developer সেকশন, অথবা SSL-এর account manager ইমেইলে দেন |
| SID | প্যানেলে আপনার মাস্কিং/নন-মাস্কিং SID (যেমন `ASSISTOAPI`) |
| API base (ঐচ্ছিক) | ফাঁকা রাখুন (ডিফল্ট `https://smsplus.sslwireless.com`); SSL অন্য হোস্ট দিলে সেটি |
| প্রতি অংশের খরচ ৳ | আপনার প্যাকেজের রেট |

- ডকুমেন্ট: SSL Wireless "ISMS API v3" PDF (অ্যাকাউন্টের সাথে দেয়) — `POST /api/v3/send-sms`, JSON `api_token, sid, msisdn, sms, csms_id`।
  `csms_id` (প্রতি মেসেজের ইউনিক আইডি) আমরা নিজেই বানাই — আপনাকে কিছু দিতে হবে না।
- নিশ্চিত নয়: ব্যালান্স API (`/api/v3/balance`) — না থাকলে শুধু টেস্ট নম্বর দিয়ে Test করুন। সার্ভারের IP হোয়াইটলিস্ট লাগে কিনা জিজ্ঞেস করুন (লাগলে IP: `16.4.105.173`)।

### ২. BulkSMSBD — এন্ট্রি `sms_bulksmsbd`
| ঘর | কোথায় পাবেন |
|---|---|
| API Key (গোপন) | bulksmsbd.net ড্যাশবোর্ড → Developer API / API Key |
| Sender ID | অনুমোদিত মাস্কিং নাম বা নন-মাস্কিং নম্বর (যেমন `8809617xxxxxx`) |
| API URL (ঐচ্ছিক) | ফাঁকা রাখুন (ডিফল্ট `https://bulksmsbd.net/api/smsapi`) |
| প্রতি অংশের খরচ ৳ | প্যাকেজের রেট |

- ডকুমেন্ট: bulksmsbd.net → API পেজ — `api_key, type=text, number, senderid, message`; সফল হলে `response_code: 202`; ব্যালান্স `getBalanceApi?api_key=`।
- নিশ্চিত নয়: তাদের ডকে `http://` দেখানো; আমরা `https://` ব্যবহার করি। HTTPS কাজ না করলে API URL ঘরে `http://bulksmsbd.net/api/smsapi` দিন (account manager-কে জিজ্ঞেস করুন)। বাংলা SMS-এর জন্য `type=text`-ই যথেষ্ট কিনা নিশ্চিত করুন — টেস্ট SMS বাংলায় যায়, ভাঙা অক্ষর এলে জানান।

### ৩. Alpha SMS (sms.net.bd) — এন্ট্রি `sms_alpha`
| ঘর | কোথায় পাবেন |
|---|---|
| API Key (গোপন) | sms.net.bd প্যানেল → API → API Key |
| Sender ID (ঐচ্ছিক) | শুধু অনুমোদিত Sender ID থাকলে দিন; না দিলে তাদের ডিফল্ট নম্বর থেকে যায় |
| প্রতি অংশের খরচ ৳ | প্যাকেজের রেট |

- ডকুমেন্ট: https://www.sms.net.bd/api — `POST https://api.sms.net.bd/sendsms` (`api_key, msg, to, sender_id`); সফল হলে `error: 0`; ব্যালান্স `/user/balance/?api_key=`।

### ৪. Infobip — এন্ট্রি `sms_infobip`
| ঘর | কোথায় পাবেন |
|---|---|
| Base URL | portal.infobip.com-এর হোমপেজে (যেমন `xxxxx.api.infobip.com`) |
| API Key (গোপন) | portal → Developers → API keys |
| Sender | অনুমোদিত alphanumeric নাম বা নম্বর — বাংলাদেশে sender নিবন্ধন লাগে কিনা Infobip-কে জিজ্ঞেস করুন |
| প্রতি অংশের খরচ ৳ | Infobip-এর রেট (সাধারণত দেশি গেটওয়ের চেয়ে বেশি) |

- ডকুমেন্ট: https://www.infobip.com/docs/api/channels/sms/sms-messaging/outbound-sms/send-sms-message — `POST {base}/sms/2/text/advanced`, হেডার `Authorization: App <key>`।

### ৫. Twilio (আন্তর্জাতিক ব্যাকআপ) — এন্ট্রি `sms_twilio`
| ঘর | কোথায় পাবেন |
|---|---|
| Account SID | console.twilio.com → Account Info (`AC…`) |
| Auth Token (গোপন) | একই জায়গায় |
| From | SMS-সক্ষম Twilio নম্বর (`+1…`) অথবা Messaging Service SID (`MG…`) |
| প্রতি অংশের খরচ ৳ | Twilio-র বাংলাদেশ রেট (ডলারে, টাকায় রূপান্তর করে দিন) |

- ডকুমেন্ট: https://www.twilio.com/docs/messaging/api/message-resource#create-a-message-resource — `POST /2010-04-01/Accounts/{SID}/Messages.json`, Basic auth, `To/From/Body`।
- নিশ্চিত নয়: বাংলাদেশে alphanumeric sender সমর্থিত কিনা ও ডেলিভারি হার — Twilio-কে জিজ্ঞেস করুন। শুধু ব্যাকআপ হিসেবে রাখুন।

### ৬. অন্য যেকোনো গেটওয়ে — এন্ট্রি `sms` (Generic HTTP)
- **API URL**-এ টেমপ্লেট দিন, যেমন:
  `https://api.example.com/send?user=me&key={api_key}&to={to}&msg={text}&from={sender}`
  (`{to}` `{text}` `{sender}` `{api_key}` `{username}` আমরা নিজে বসাই, URL-encode করে)।
- **মেথড**: GET বা POST। POST-এ JSON বডি লাগলে "JSON বডি টেমপ্লেট" ঘরে দিন (একই placeholder)।
- **সফলতা regex**: গেটওয়ের সফল উত্তরে যা থাকে (যেমন `^1701` বা `"status":"success"`)। না দিলে শুধু HTTP 2xx দেখা হয়।
- **নম্বর ফরম্যাট**: `880` / `+880` / `0` (গেটওয়ে যেটা চায়)।
- MiM SMS-এর জন্য Provider ঘরে `mim_sms` লিখলেই বাকিটা ভরা থাকে (Username + API Key দিন)।

---

## গ) প্রধান ও ব্যাকআপ গেটওয়ে (failover)

**Owner Admin → Pricing → sms**:
- `primary` = যে এন্ট্রি আগে চেষ্টা হবে (যেমন `sms_bulksmsbd`)। ফাঁকা = প্রথম CONNECTED এন্ট্রি।
- `secondary` = প্রধানটি ব্যর্থ হলে (নেটওয়ার্ক/HTTP ভুল/ব্যালান্স শেষ) সাথে সাথে যেটা দিয়ে আবার পাঠানো হবে (যেমন `sms_alpha` বা `sms_twilio`)। ফাঁকা = ব্যাকআপ নেই।
- শুধু CONNECTED (টেস্ট পাস) এন্ট্রিই ব্যবহার হয়। slug-গুলো: `sms_ssl_wireless`, `sms_bulksmsbd`, `sms_alpha`, `sms_infobip`, `sms_twilio`, `sms`।

## ঘ) কী চালু হয় এবং দৈনিক সীমা (Pricing → sms, বদলানো যায়; ০ = বন্ধ)

| কাজ | কে খরচ বহন করে | ডিফল্ট সীমা (প্রতিদিন, ঢাকা সময়) |
|---|---|---|
| OTP (লগইন, পাসওয়ার্ড রিসেট, অ্যাকাউন্ট ডিলিট, সেকশন ৮) | কোম্পানি (ব্যবহারকারী ফ্রি) | প্রতি নম্বর ১০ · প্রতি ব্যবহারকারী ১০ · সব মিলে ৩০০০ |
| ফোন যাচাই (সাইন-আপ, নম্বর বদল, বুকিং) | কোম্পানি | প্রতি নম্বর ৬ · প্রতি ব্যবহারকারী ৬ · সব মিলে ২০০০ |
| খাতার বাকি-রিমাইন্ডার (তাগাদা) | ব্যবসার মালিক — প্রতি SMS-অংশে ১ ক্রেডিট (ক্রেডিট না থাকলে পাঠানো হয় না; গেটওয়ে ব্যর্থ হলে ক্রেডিট ফেরত) | প্রতি গ্রাহক ১ · প্রতি ব্যবসা ২০০ · সব মিলে ৫০০০; গ্রাহক STOP দিলে বন্ধ; রাত ৯টা–সকাল ৯টা পাঠানো হয় না |
| সেফটি SMS (SOS / Safe Journey / পরিবারের সতর্কতা) | কোম্পানি (ব্যবহারকারী ফ্রি) | প্রতি কন্টাক্ট ৬ · প্রতি ব্যবহারকারী ২০ · সব মিলে ১০০০ |
| মার্কেটিং/বিজ্ঞাপন SMS | — | **কখনো পাঠানো হয় না** (কোডে নিষিদ্ধ) |

ঘণ্টাভিত্তিক OTP সীমা আগের মতো (Pricing → otp): প্রতি নম্বর ৫, প্রতি IP ২০, প্রতি ডিভাইস ১০, **প্রতি ইমেইল ৫** (নতুন); ৫ বার ভুল কোডে ৩০ মিনিট লক।

## ঙ) খরচ

- প্রতিটি এন্ট্রিতে **"প্রতি SMS-অংশের খরচ (৳)"** দিন (আপনার প্যাকেজের রেট)। না দিলে Pricing → sms → `default_cost_per_segment_bdt` (ডিফল্ট ৳০.৩৫) ধরা হয়।
- প্রতিটি SMS-এর অংশ-সংখ্যা, খরচ, গেটওয়ে, মেসেজ আইডি `SmsLog`-এ থাকে; খরচ দৈনিক কোম্পানি-খরচে (Profit Guard / P&L-এর "sms") যোগ হয়। **মেসেজের লেখা বা কোড কখনো সংরক্ষণ বা লগ হয় না।**
- বাংলা SMS ইউনিকোড: এক অংশে ৭০ অক্ষর, একাধিক অংশ হলে প্রতি অংশে ৬৭। ইংরেজি: ১৬০ / ১৫৩। আমাদের বাংলা OTP মেসেজ ১–২ অংশ, ইংরেজি ১ অংশ। ৪ অংশের বেশি লম্বা মেসেজ পাঠানো হয় না।
- আনুমানিক বাজার রেট (প্যাকেজভেদে বদলায়, নিজের রেট দিন): নন-মাস্কিং ৳০.২৫–০.৪০, মাস্কিং ৳০.৩৫–০.৬০ প্রতি অংশ।

## চ) ইমেইল OTP (Gmail) — App password যেভাবে বানাবেন

১. `assistoaiagent@gmail.com` দিয়ে myaccount.google.com-এ লগইন → **Security** → **2-Step Verification** চালু করুন (ফোন নম্বর দিয়ে)।
২. তারপর **myaccount.google.com/apppasswords** খুলুন → নাম লিখুন `Assisto` → **Create**।
৩. Google একটি **১৬ অক্ষরের App password** দেখাবে (৪টি করে ৪ ভাগে)। কপি করুন — এটা আর দেখানো হবে না। (স্পেস থাকলেও সমস্যা নেই, আমরা বাদ দিই।)
৪. Owner Admin → Integrations → **Email — SMTP (Gmail)**: Host `smtp.gmail.com`, Port `587`, Username `assistoaiagent@gmail.com`, App password পেস্ট, From name `Assisto` → **Save**।
৫. নিচে নিজের ইমেইল লিখে **"টেস্ট ইমেইল পাঠান"** → ইনবক্সে (বা Spam-এ) এলে CONNECTED।
- আসল Gmail পাসওয়ার্ড কখনো দেবেন না — শুধু App password। পাসওয়ার্ড বদলালে App password বাতিল হয়; তখন নতুন বানিয়ে আবার বসান।

**ইমেইল কখন যায়:** লগইন/পাসওয়ার্ড রিসেট/অ্যাকাউন্ট ডিলিট/সেকশন ৮-এর কোড, যখন SMS আসেনি বা ব্যবহারকারী "কোডটি বরং ইমেইলে পাঠান" চাপেন।
শুধু **যাচাই-করা ইমেইলে** কোড যায় (ব্যবহারকারী সেটিংস → "সাইন-ইন কোডের ইমেইল"-এ কোড দিয়ে যাচাই করেন)। সাইন-আপ/নম্বর বদলে ইমেইল চলে না (ইমেইল দিয়ে ফোন প্রমাণ হয় না)।
ইমেইল সাদা লেখা, বাংলা+ইংরেজি, কোনো ছবি/লিংক/ট্র্যাকিং নেই, নিচে "AXON Dynamic"। কোনো ব্যক্তির নাম থাকে না।
অ্যাকাউন্ট আছে কি নেই — উত্তর সবসময় একই (কেউ ইমেইল/নম্বর দিয়ে খুঁজে বের করতে পারবে না)।

**Gmail-এর দৈনিক সীমা:** সাধারণ Gmail-এ দিনে প্রায় ৫০০ জন প্রাপক (Google Workspace-এ প্রায় ২০০০)। আমাদের সীমা
Pricing → email → `daily_cap` = **৪০০ / ২৪ ঘণ্টা** (সীমার নিচে, যাতে Google অ্যাকাউন্ট আটকে না দেয়)।
৯০% পার হলে অ্যাপকে বলা হয় SMS-কে অগ্রাধিকার দিতে; ৪০০ হলে ইমেইল কোড বন্ধ হয়ে সৎ বার্তা দেখায় ("আজ ইমেইলে আর কোড পাঠানো যাচ্ছে না, SMS ব্যবহার করুন")।
Workspace নিলে `daily_cap` ১৫০০–১৮০০ পর্যন্ত বাড়াতে পারেন।

## ছ) বড় হলে: Amazon SES পরিকল্পনা (এখন বানানো হয়নি, শুধু পরিকল্পনা)

- কখন: দিনে ৪০০-র বেশি ইমেইল লাগলে।
- যা লাগবে: (১) AWS অ্যাকাউন্ট (কোম্পানির; Asalify-র নয়), (২) SES-এ ডোমেইন `lifeassisto.com` যাচাই — DNS-এ **DKIM** (৩টি CNAME), **SPF** (`v=spf1 include:amazonses.com ~all` — আগের SPF-এর সাথে মিলিয়ে), **DMARC** (`_dmarc` TXT, শুরুতে `p=none`), ঐচ্ছিক custom MAIL FROM (`mail.lifeassisto.com`), (৩) **sandbox থেকে বের হওয়ার আবেদন** (production access: ব্যবহার, bounce/complaint কীভাবে সামলাবেন লিখতে হয়; সাধারণত ১–২ দিন), (৪) bounce/complaint নোটিফিকেশন (SNS)।
- আনুমানিক খরচ: প্রতি ১০০০ ইমেইলে প্রায় **$০.১০** (≈ ৳১২), সাথে সামান্য ডেটা খরচ — Gmail-এর চেয়ে অনেক বেশি পাঠানো যায়।
- কোড: ইমেইল প্রেরক আলাদা করে রাখা (`core/email_sender.py` → `SENDERS`)। SES ক্লাস যোগ করে Pricing → email → `provider = ses` করলেই চলবে; OTP কোডে কিছু বদলাতে হবে না।

## জ) চালু করার ধাপ (মালিক / integrator) — কোনো ফ্ল্যাগ আমরা বদলাইনি

১. গেটওয়ে এন্ট্রি পূরণ → **টেস্ট SMS পাঠান** → CONNECTED। তখনই চালু: SMS OTP লগইন, ফোন যাচাই (সাইন-আপ/নম্বর বদল), তাগাদা SMS, সেফটি SMS।
২. (ঐচ্ছিক) দ্বিতীয় গেটওয়ে → Pricing → sms → `secondary`।
৩. Gmail App password → **টেস্ট ইমেইল পাঠান** → CONNECTED। তখন ইমেইল-ব্যাকআপ চালু।
৪. প্রকৃত ফোনে পরীক্ষা: নিজের নম্বরে OTP লগইন; সেটিংসে ইমেইল যাচাই; SMS বন্ধ রেখে "ইমেইলে কোড নিন"।
৫. **পাবলিক লঞ্চের আগে (শুধু SMS CONNECTED হওয়ার পর):**
   - Admin → Cost & feature flags → `auth_password_only_signup` → **OFF** (নতুন সাইন-আপে ফোন যাচাই বাধ্যতামূলক)।
   - Admin → Cost & feature flags → `contacts_match_unverified` → **OFF** (ফোনবুক মেলানো শুধু OTP-যাচাই করা নম্বরে)। এখন এটা ON, কারণ SMS না থাকায় কেউ যাচাই হতে পারত না।
   - ক্রম জরুরি: আগে SMS CONNECTED, তারপর এই দুই ফ্ল্যাগ OFF — উল্টো করলে কেউ সাইন-আপ করতে পারবে না।
৬. Safe Journey / SOS-এর SMS: journey এজেন্ট `core.sms_service.send_safety_sms(user, to, text)` কল করবে (ক্যাপ ও খরচ লগ এখানেই)।
৭. তাগাদা SMS (সার্ভার থেকে): `POST /api/v1/business/khata/tagada/sms/<party_id>` (মালিক)। অ্যাপের খাতা স্ক্রিনে বাটন যোগ করা integrator-এর কাজ (এখন অ্যাপ ফোনের SMS অ্যাপ খোলে)।

পুরনো নোট `owner_actions/SMS_GATEWAY_NEEDS.md` এখনো ঠিক আছে; নতুন সব কিছু এই ফাইলে।
