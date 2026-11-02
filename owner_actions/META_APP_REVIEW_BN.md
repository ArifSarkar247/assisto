# Meta App Review — মালিকের ধাপে ধাপে কাজ (Facebook + Instagram কমেন্ট ও মেসেজ)

৩ নভেম্বর · শাখা `agent/bizauto`। **এটা শুধু মালিকই করতে পারেন** (Meta অ্যাকাউন্ট, ব্যবসার কাগজ, ভিডিও)। কোড তৈরি: অনুমোদন এলে Owner Admin-এ একটা টিক দিলেই কমেন্টের উত্তর চালু — নতুন বিল্ড লাগবে না।

> সৎ অবস্থা: আজ পর্যন্ত Assisto **কোনো আসল Page-এ চলেনি**। নকল Meta সার্ভার দিয়ে CI-তে প্রমাণ আছে (`core/tests_bizauto.py`, `core/tests_salesbar.py`)। Meta সাধারণত ৩–১০ কাজের দিন নেয়; প্রথমবার বাতিল হওয়া স্বাভাবিক — কারণ পড়ে আবার জমা দিন।

## ০. আগে যা তৈরি রাখবেন (১৫ মিনিট)
| জিনিস | ঠিকানা / কোথায় |
|---|---|
| গোপনীয়তা নীতি (Privacy Policy URL) | `https://lifeassisto.com/privacy` |
| শর্তাবলি (Terms URL) | `https://lifeassisto.com/terms` |
| ডেটা মোছার কলব্যাক (Data Deletion **Callback** URL) — **নতুন, এই শাখায় তৈরি** | `https://lifeassisto.com/api/v1/bizagent/meta/data-deletion` |
| (বিকল্প) ডেটা মোছার নির্দেশ পাতা | `https://lifeassisto.com/delete-account` |
| Webhook URL | `https://lifeassisto.com/api/v1/bizagent/webhook/meta` |
| Webhook Verify Token + App ID + App Secret | Owner Admin → Integrations → **meta_app** (এখানেই লিখুন; কাউকে পাঠাবেন না) |
| অ্যাপ আইকন ১০২৪×১০২৪, ক্যাটাগরি "Business and Pages" | Meta App Dashboard → App settings → Basic |
| যোগাযোগের ইমেইল | support@lifeassisto.com |

## ১. Business Verification (ব্যবসা যাচাই) — আগে এটা
1. business.facebook.com → Settings → **Security Center** → "Start verification"।
2. ট্রেড লাইসেন্স (বা Incorporation কাগজ), ব্যবসার নাম–ঠিকানা–ফোন **হুবহু** কাগজের মতো লিখুন।
3. ডোমেইন যাচাই: Business Settings → Brand safety → **Domains** → `lifeassisto.com` যোগ → DNS TXT রেকর্ড দিন (আমাদের সার্ভার-অ্যাডমিন এক লাইনে করে দেবেন)।
4. ফলাফল সাধারণত ১–৩ দিনে। যাচাই ছাড়া "Advanced Access" পাওয়া যায় না।

## ২. অ্যাপ সেটআপ (Meta App Dashboard)
1. developers.facebook.com → My Apps → আমাদের অ্যাপ (Type: **Business**) → উপরের Business Portfolio = যাচাই করা ব্যবসা।
2. App settings → Basic: Privacy Policy URL, Terms URL, **User data deletion → "Data deletion callback URL"** = উপরের কলব্যাক ঠিকানা। App Domains = `lifeassisto.com`।
3. Products → **Webhooks** → Page: Callback URL + Verify Token → Subscribe: `messages`, `messaging_postbacks`, `message_echoes`, **`feed`**। Instagram: `messages`, **`comments`**।
4. Products → **Messenger** ও **Instagram** যোগ করুন (Instagram API with Facebook Login)।

## ৩. কোন অনুমতি চাইবেন, প্রতিটির জন্য কী লিখবেন
| অনুমতি | কেন লাগে (Meta-কে ইংরেজিতে এক লাইনে) |
|---|---|
| `pages_messaging` | The shop's AI assistant answers customers who message the shop's Page (prices from the shop's own catalog, order taking) — only inside the 24-hour window, STOP honoured. |
| `pages_read_engagement` | Read the Page's posts/comments metadata so a customer's comment can be matched to the product in the post. |
| `pages_manage_engagement` | Send ONE private reply (Messenger) to a customer who asked a price in a comment on the shop's own post. |
| `instagram_basic` | Read the connected Instagram professional account's profile and media ids to match comments to products. |
| `instagram_manage_comments` | Receive comments on the shop's own Instagram posts and send one private reply to a price question. |
| (সাথে লাগবে) `pages_show_list`, `pages_manage_metadata`, `instagram_manage_messages`, `pages_read_user_content`, `business_management` | Page বাছাই, webhook সাবস্ক্রাইব, IG DM, কমেন্টের লেখা পড়া। **আমাদের কোড এগুলো ধরে নিয়েই লেখা** — Owner Admin-এর FB-কমেন্ট টিক = `pages_manage_engagement` + `pages_read_user_content`। |

প্রতিটির জন্য "Advanced Access" চাইতে হবে (শুধু Standard-এ শুধু টেস্টার পেজে চলে)।

## ৪. টেস্ট ইউজার ও টেস্ট পেজ (রিভিউয়ার যা দিয়ে দেখবেন)
1. App Roles → **Testers**-এ নিজের আর একজন সহকারীর Facebook অ্যাকাউন্ট যোগ করুন।
2. একটি **টেস্ট Facebook Page** ("Rupa Fashion Test") + তার সাথে যুক্ত **Instagram professional** অ্যাকাউন্ট বানান। ২টি পোস্ট: "Panjabi — ১২০০ টাকা", "Saree — ২৫০০ টাকা"।
3. Assisto অ্যাপে একটা টেস্ট ব্যবসা: ক্যাটালগে Panjabi ১২০০, Saree ২৫০০ → বিজনেস AI এজেন্ট → Page জুড়ুন।
4. রিভিউয়ারের জন্য লগইন: Assisto টেস্ট অ্যাকাউন্ট (ফোন + পাসওয়ার্ড) "App Review → Instructions" ঘরে লিখুন; বাংলা না জানলে অ্যাপ ইংরেজিতে রাখুন (সেটিংস → ভাষা)।

## ৫. স্ক্রিনকাস্ট — প্রতিটি অনুমতির জন্য কী রেকর্ড করবেন (ইংরেজি UI, ২–৪ মিনিট, ক্যাপশনসহ)
**ভিডিও ১ — `pages_messaging` + `pages_show_list` + `pages_manage_metadata`**
1. Assisto অ্যাপ → বিজনেস AI এজেন্ট → "Connect Facebook Page" → Facebook লগইন পপআপ → টেস্ট পেজ বাছাই → অনুমতি স্ক্রিন **পুরোটা দেখা যায়** এমনভাবে।
2. অন্য ফোন (টেস্টার অ্যাকাউন্ট) থেকে পেজে মেসেজ: "Panjabi price?" → কয়েক সেকেন্ডে উত্তর "১২০০ টাকা…" — দুই ফোন পাশাপাশি দেখান।
3. গ্রাহক লেখে "STOP" → "আর মেসেজ পাঠানো হবে না" উত্তর → অ্যাপের ইনবক্সে চ্যাটটা "বন্ধ" দেখায়।

**ভিডিও ২ — `pages_read_engagement` + `pages_manage_engagement` (+ `pages_read_user_content`)**
1. টেস্টার অ্যাকাউন্ট থেকে পোস্টে কমেন্ট: "Panjabi price?"
2. টেস্টারের Messenger-এ পেজ থেকে **একটি** প্রাইভেট রিপ্লাই আসে (দাম ক্যাটালগ থেকে)।
3. Assisto অ্যাপ → সেলার ইনবক্সে কমেন্টটি ও উত্তর দেখান; Owner Admin-এর সুইচ বন্ধ থাকলে উত্তর যায় না — এটাও এক লাইনে বলুন ("the shop owner controls this")।

**ভিডিও ৩ — `instagram_basic` + `instagram_manage_comments` (+ `instagram_manage_messages`)**
1. Assisto-তে Instagram অ্যাকাউন্ট জোড়া (অনুমতি স্ক্রিন দেখান)।
2. টেস্টার IG থেকে পোস্টে কমেন্ট "Price please?" → IG Direct-এ একটি প্রাইভেট রিপ্লাই।

**ভিডিও ৪ — ডেটা মোছা**: Facebook → Settings → Apps and websites → আমাদের অ্যাপ → Remove → "Delete data" — তারপর `…/data-deletion/status?code=…` পাতা খোলা দেখান (কলব্যাক এটাই দেয়)।

রেকর্ডিং টিপস: স্ক্রিনে বাংলা থাকলে ইংরেজি ক্যাপশন দিন; মাউস/আঙুল ধীরে; কোনো আসল গ্রাহকের নাম/নম্বর যেন না দেখা যায়।

## ৬. জমা দেওয়া
1. App Review → Permissions and Features → প্রতিটি অনুমতির পাশে "Request advanced access" → উপরের এক লাইনের কারণ + ভিডিও + ধাপের লেখা।
2. Data Use Checkup ও "Data handling questions" — উত্তর: ডেটা শুধু দোকানের নিজের গ্রাহকসেবার জন্য; বিক্রি/শেয়ার হয় না; মুছতে কলব্যাক আছে।
3. জমা দিন → Owner Admin → সেলার পাতা → "Meta অনুমোদন" = **জমা দেওয়া হয়েছে**।

## ৭. অনুমোদন এলে (১ মিনিট — এটাই "সুইচ")
Owner Admin → **সেলার পাতা (`/owner/sellers`)** → "Meta অনুমোদন":
* App Review = **অনুমোদিত**
* ☑ Facebook কমেন্টের অনুমতি পাওয়া গেছে · ☑ Instagram কমেন্টের অনুমতি পাওয়া গেছে → সংরক্ষণ।
পরের কমেন্ট থেকেই উত্তর যাবে (৭ দিনের নিয়ম, এক কমেন্টে একটাই প্রাইভেট রিপ্লাই, STOP বলা মানুষকে কখনো নয় — সব কোডে পাহারা ও টেস্ট আছে)। সমস্যা হলে টিক তুলে দিন — সাথে সাথে বন্ধ।

## ৮. বাতিল হলে সাধারণ কারণ
* ভিডিওতে অনুমতি-স্ক্রিন বা আসল ব্যবহার দেখা যায়নি → ভিডিও আবার, ধাপ ধরে।
* Privacy Policy-তে Facebook/Instagram ডেটার কথা নেই → `/privacy`-তে "Facebook ও Instagram থেকে পাওয়া মেসেজ/কমেন্ট" অংশ আছে কিনা দেখুন; না থাকলে আমাদের জানান (ওয়েবসাইট এজেন্ট যোগ করবে)।
* Business verification শেষ হয়নি।
