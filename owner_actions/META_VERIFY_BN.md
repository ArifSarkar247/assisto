# Meta — Assisto অ্যাপ তৈরি, App Review ও Business Verification (হালনাগাদ ১৭ নভেম্বর ২০২৬, রাত)

**এক লাইনে:** Assisto-র সার্ভারে আজ **কোনো Meta অ্যাপ যুক্ত নেই** — Owner Admin-এর `meta_app`, `messenger`, `whatsapp` তিনটি কার্ডই খালি (লাইভ সার্ভারে যাচাই, শুধু খালি/ভরা দেখা হয়েছে)। আমাদের রিপোতে কোনো Meta App ID বা Asalify-র অ্যাপের উল্লেখ নেই। তাই **Asalify-র অ্যাপ সরানো বা বদলানোর প্রশ্নই নেই — সেটা যেমন আছে থাকবে, ছোঁয়া হবে না।** Assisto-র জন্য Axon Dynamics পোর্টফোলিওতে **একদম নতুন একটি অ্যাপ** বানাবেন (নিচের ধাপ)। Meta বলেছে Business Verification এখন লাগবে না — অ্যাপ যখন Advanced Access চাইবে তখন চাইবে; তখন নিচের "যাচাই" অংশ।

> আমি Meta-র কোনো কনসোলে কিছু করিনি, করবও না — সব ধাপ আপনি নিজে করবেন। কোনো App Secret, টোকেন বা কোড আমাকে/চ্যাটে/গিটে দেবেন না; শুধু Owner Admin-এ পেস্ট করবেন।

---

## ১. নতুন অ্যাপ বানানো (developers.facebook.com)
1. **developers.facebook.com** → ওপরে ডানে **My Apps** → **Create App**।
2. **App name:** `Assisto` · **App contact email:** `assistoaiagent@gmail.com` → **Next**।
3. **Use cases** পাতায় টিক দিন (নাম Meta মাঝে মাঝে বদলায়, কাছাকাছি নামটা বাছুন):
   - **Engage with customers on Messenger from Meta** (Messenger)
   - **Manage messaging & content on Instagram** (Instagram messaging)
   - **Connect with customers through WhatsApp** (WhatsApp Business)
   → **Next**।
4. **Business portfolio:** তালিকা থেকে **Axon Dynamics** বাছুন (অন্য কোনো পোর্টফোলিও নয়) → **Next** → **Create app** → পাসওয়ার্ড চাইলে দিন।
5. অ্যাপ তৈরি হলে বাঁ মেনু **App settings → Basic**:
   - **App icon (1024×1024):** https://lifeassisto.com/site/icon-512.png ডাউনলোড করে বড় সংস্করণ লাগলে আমাকে "Meta আইকন ১০২৪ বানাও" বলুন — আমি owner_actions-এ দেব।
   - **Privacy policy URL:** `https://lifeassisto.com/privacy`
   - **Terms of Service URL:** `https://lifeassisto.com/terms`
   - **User data deletion:** **Data deletion callback URL** বাছুন → `https://api.lifeassisto.com/api/v1/bizagent/meta/data-deletion` (না চললে "Data deletion instructions URL" → `https://lifeassisto.com/delete-account`)
   - **Category:** Business and pages (বা Messaging) · **App domains:** `lifeassisto.com`
   - **Save changes**।
6. একই পাতা থেকে **App ID** ও **App Secret** (Show চাপুন) → **lifeassisto.com/owner → Integrations → "Meta app (Business AI Agent webhooks)"** কার্ডে পেস্ট → নিজের বানানো লম্বা **Verify token** দিন → **Save → Test**। (App ID-র শুধু শেষ ৪ অঙ্ক কার্ডে দেখাবে।)

## ২. Webhook বসানো
- **Messenger + Instagram:** বাঁ মেনু **Use cases → Messenger (বা Instagram) → Customize → Configure webhooks** → Callback URL `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta`, Verify token = Owner Admin-এ যেটা দিয়েছেন → **Verify and save** → Fields: `messages`, `messaging_postbacks`, `message_echoes`, `message_reads` (Instagram-এ `messages`, `comments`) → Subscribe।
- **WhatsApp:** **Use cases → WhatsApp → Configuration → Webhook** → `https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp`, একই Verify token → Fields: `messages` → Subscribe।
- স্বাক্ষর ছাড়া কেউ webhook-এ বার্তা পাঠালে সার্ভার এখন ফিরিয়ে দেয় (403, লাইভে যাচাই করা)।

## ৩. যে অনুমতিগুলো চাইবেন (Permissions — Use cases-এর ভেতরে "Add" / App Review → Permissions and features)
| অনুমতি | কেন (Meta-কে লেখার এক লাইন) |
|---|---|
| `pages_show_list` | বিক্রেতা তাঁর কোন পেজ যুক্ত করবেন তা দেখাতে |
| `pages_messaging` | পেজের গ্রাহকের Messenger বার্তার উত্তর দিতে |
| `pages_manage_metadata` | পেজকে আমাদের webhook-এ subscribe/unsubscribe করতে |
| `pages_read_engagement` | পেজের নাম, পোস্ট ও প্রাথমিক তথ্য পড়তে (পণ্য-পোস্ট থেকে উত্তর) |
| `pages_manage_engagement` | পেজের পোস্টের কমেন্টে উত্তর দিতে (বিক্রেতা চালু করলে) |
| `instagram_basic` | যুক্ত Instagram বিজনেস অ্যাকাউন্টের আইডি ও নাম জানতে |
| `instagram_manage_messages` | Instagram DM-এর উত্তর দিতে |
| `instagram_manage_comments` | Instagram পোস্টের কমেন্টে উত্তর দিতে (বিক্রেতা চালু করলে) |
| `whatsapp_business_messaging` | WhatsApp-এ গ্রাহকের বার্তার উত্তর দিতে |
| `whatsapp_business_management` | বিক্রেতার WhatsApp নম্বর ও টেমপ্লেট যুক্ত/দেখতে |
| `business_management` | বিক্রেতার Business Manager-এর পেজ/নম্বর যুক্ত করার সময় (শুধু দরকার হলে) |
| `public_profile` | লগইনের সাধারণ তথ্য (সবসময় থাকে) |

শুরুতে এগুলো **Standard Access**-এ থাকে (শুধু অ্যাপের অ্যাডমিন/টেস্টাররা ব্যবহার করতে পারেন — আপনার নিজের পেজ দিয়ে পরীক্ষা চলে)। অন্য দোকানের পেজে চালাতে **Advanced Access** লাগে — তখনই App Review ও Business Verification।

## ৪. "Start verification" কোথায় আসবে
- **developers.facebook.com → আপনার Assisto অ্যাপ → App settings → Basic** — পাতার নিচে বা ওপরের ব্যানারে **"Business verification"** অংশ, অথবা **App Review → Permissions and features**-এ কোনো অনুমতির পাশে **"Get advanced access"** চাপলে Meta বলবে "Business verification required" → **Start verification**।
- সেখান থেকে **business.facebook.com → Settings → Security Center → Business verification → Start verification**-এ নিয়ে যাবে।
- যা হুবহু লিখবেন (ট্রেড লাইসেন্স অনুযায়ী):

| ঘর | লিখবেন |
|---|---|
| Legal business name | **Axon Dynamics** |
| Address line 1 | **Cha-63/3, Uttar Badda** |
| Address line 2 / Area | **Badda** |
| City | **Dhaka** · ZIP **1212** · Country **Bangladesh** |
| Website | **https://lifeassisto.com** (ডোমেইন আগেই যাচাই করা যায়: ট্যাগ লাইভে আছে) |
| Business email | **assistoaiagent@gmail.com** |
| Business phone | আপনার ব্যবসার ফোন — গিটে/সাইটে লেখা হবে না |
| Document | ট্রেড লাইসেন্স (DNCC) — **শুধু Meta-র পাতায় নিজে আপলোড**; PDF কোথাও পাঠাবেন না |

ওয়েবসাইটের ফুটার, About, Privacy, Terms, Data deletion আর Google-এর Organization তথ্যে এখন হুবহু একই নাম-ঠিকানা (লাইভে curl দিয়ে যাচাই; পুরনো নাম ০টি পাতায়)।

## ৫. App Review-এর জন্য যা তৈরি রাখতে হবে
**আগে যা শেষ (আমাদের দিক):** ব্যবসা আলাদা রাখার P0 লাইভে ঠিক (পেজের মালিকানা Meta দিয়ে যাচাই, শুধু যাচাই-করা সংযোগে বার্তা, সব ব্যবসার তথ্য আলাদা — পরীক্ষাসহ), webhook স্বাক্ষর যাচাই, ডেটা-মোছার কলব্যাক, privacy policy-তে Business Agent অংশ।

**স্ক্রিনকাস্ট পরিকল্পনা** (প্রতিটি অনুমতির জন্য ১–২ মিনিটের ভিডিও; ইংরেজি সাবটাইটেল; ফোনের স্ক্রিন রেকর্ড):
1. Assisto খুলুন → লগইন → **My Business → Business AI Agent → Connect Facebook Page** → Facebook লগইন পপ-আপে পেজ বাছাই ও অনুমতি দেওয়া দেখান (`pages_show_list`, `pages_manage_metadata`)।
2. দ্বিতীয় ফোন থেকে (টেস্ট ব্যবহারকারী) পেজে Messenger-এ "এই শার্টের দাম কত?" পাঠান → Assisto-র ইনবক্সে বার্তা আসে → AI দোকানের পণ্য থেকে দাম দিয়ে উত্তর দেয় → গ্রাহকের ফোনে উত্তর দেখান (`pages_messaging`)।
3. একই ধাপ Instagram DM দিয়ে (`instagram_basic`, `instagram_manage_messages`)।
4. WhatsApp নম্বর যুক্ত → গ্রাহক WhatsApp-এ প্রশ্ন → উত্তর (`whatsapp_business_messaging`, `whatsapp_business_management`)।
5. AI না জানলে: গ্রাহককে "আমরা শিগগিরই জানাচ্ছি", বিক্রেতার "AI জানত না" তালিকায় প্রশ্ন — বিক্রেতা উত্তর দেন (মানুষের নিয়ন্ত্রণ দেখানো)।
6. **Disconnect** → পেজ unsubscribe হয়, আর বার্তা আসে না; ডেটা মোছার পাতা দেখান।

**টেস্ট ব্যবহারকারী (Meta রিভিউয়ারের জন্য):**
- Assisto-তে একটি রিভিউ অ্যাকাউন্ট (Play-র রিভিউয়ার অ্যাকাউন্টের মতো আলাদা; আপনার মালিক-অ্যাকাউন্ট নয়) — আমি তৈরি করে Owner Admin-এ রাখব, পাসওয়ার্ড শুধু আপনি দেখবেন।
- একটি পরীক্ষার Facebook Page ও Instagram বিজনেস অ্যাকাউন্ট (আপনার নিজের, Axon Dynamics পোর্টফোলিওতে), একটি WhatsApp পরীক্ষা নম্বর (Meta-র দেওয়া test number-ও চলে)।
- রিভিউয়ারের জন্য ধাপ (ইংরেজিতে, Review notes-এ পেস্ট করার মতো) — অ্যাপ তৈরি হলে আমি `META_APP_REVIEW_BN.md`-এ লিখে দেব।

**জমা দেওয়ার আগে চেকলিস্ট:** অ্যাপ আইকন, privacy/terms/data-deletion URL কাজ করে (✅ লাইভ), Business Verification সম্পন্ন, প্রতিটি অনুমতির ভিডিও ও "কেন লাগে" লেখা, টেস্ট ব্যবহারকারী লগইন কাজ করে।
