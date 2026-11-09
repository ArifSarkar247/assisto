# Play ঘোষণা (খসড়া) — কলের পরে নোট + নোটিফিকেশন থেকে টাকা

শাখা `agent/callmoney` · ৪ নভেম্বর। **এটা খসড়া — Play Console-এ মালিক নিজে বসাবেন।** কোনো টাকা লাগে না।

## ১. আমরা কোন অনুমতি নিচ্ছি, কোনটা নিচ্ছি না

| বিষয় | অবস্থা | কেন |
|---|---|---|
| নোটিফিকেশন অ্যাক্সেস (NotificationListenerService) | **নেওয়া হচ্ছে** — ব্যবহারকারী নিজে Android সেটিংসে চালু করেন | কল শেষ বোঝা + অনুমোদিত টাকার বার্তা পড়া |
| READ_PHONE_STATE | **নেওয়া হচ্ছে না** | কল শেষ বোঝা যায় নোটিফিকেশনের ধরন আর অডিও মোড দিয়ে (অনুমতি লাগে না)। Play গেট এটা নিষেধ করে রেখেছে। |
| READ_SMS / RECEIVE_SMS | **নেওয়া হচ্ছে না** | Play-তে এটা SMS/কল-লগ নীতির আওতায়, আমাদের দরকার নেই |
| READ_CALL_LOG | **নেওয়া হচ্ছে না** | — |
| মাইক্রোফোন (কলের সময়) | **ব্যবহার হয় না** | কল কখনো রেকর্ড হয় না |

ফলে **Permissions declaration form-এ নতুন কিছু জমা দিতে হবে না** (SMS/Call log ফর্ম লাগবে না)। নোটিফিকেশন অ্যাক্সেসের জন্য Play-এর আলাদা ফর্ম নেই, কিন্তু **User Data policy** মানতে হবে — অ্যাপের ভেতরে স্পষ্ট প্রকাশ (prominent disclosure) + সম্মতি, যেটা বানানো হয়েছে (সেটিংস → কলের নোট ও টাকার হিসাব → সুইচ চালু করলে আগে প্রকাশ-পাতা)।

## ২. Data safety ফর্মে যা বদলাবে (মালিক বসাবেন)

* **Financial info → Other financial info:** Collected = Yes · Shared = No · Optional (ব্যবহারকারী চালু করলে) · Purpose = App functionality · Encrypted in transit = Yes · Delete request = Yes (অ্যাকাউন্ট মুছলে)।
  * কারণ: ব্যবহারকারী নিশ্চিত করলে খাতায় লেনদেন (টাকা, ধরন, ওয়ালেট, TrxID) সার্ভারে যায়।
* **Messages (SMS):** Collected = **No** — বার্তা শুধু ফোনেই পড়া হয়, সার্ভারে যায় না (Google-এর সংজ্ঞায় "on-device only" = collected নয়)।
* **App activity / Phone calls:** Collected = No — কে কল করেছে বা কলের কিছুই সংগ্রহ হয় না।
* **Audio:** আগের মতোই (ভয়েস ইনপুট) — কলের নোট বলার সময় স্পিচ-টু-টেক্সট ফোনের ইঞ্জিনে; লেখা হওয়া কথা AI-তে যায় (Personal info নয়, "App interactions / Other user-generated content" — আগের AI চ্যাটের ঘোষণাতেই আছে)।

## ৩. অ্যাপের ভেতরের প্রকাশ-লেখা (ARB-এ আছে; কপি)

**টাকা (EN):** "Only notifications from bKash, Nagad, Rocket, Upay and bank apps, and SMS from those senders in your messages app. Every other notification is ignored without being read. Assisto does not ask for SMS permission. The amount, the other party and income or expense are worked out on this phone. Only entries you confirm (or that auto-save keeps, if you turn it on) go to your Assisto account. The message itself never leaves the phone, and nothing is sold or shared. Turn it off any time here, or remove access in Android Settings."

**কল (EN):** "Assisto only notices that a phone, WhatsApp or Messenger call ended. It does not read who called or any message text. Calls are never recorded. What you say or type after the call is sent to Assisto AI to make a reminder, note or khata due. Nothing is saved until you tap Confirm."

বাটন: "Agree and turn on" / "Not now" — "Not now" চাপলে কিছুই চালু হয় না (টেস্টে প্রমাণ)।

## ৪. Google রিভিউয়ারের জন্য নোট (App access → Instructions, ইংরেজিতে কপি)

> Notification access is optional and off by default. Settings → "Call notes & money alerts". Each switch first shows a prominent disclosure and asks for consent; only then Android's Notification access page opens. The listener ignores every notification except (a) the call-type notification of the phone/WhatsApp/Messenger call screen, used only to know a call ended (no caller name, number or audio), and (b) bKash/Nagad/Rocket/Upay/bank apps and those senders' SMS notifications, parsed on the device. No READ_SMS, READ_PHONE_STATE or READ_CALL_LOG permission is requested. Calls are never recorded. "Turn both off now" disables the listener component immediately.

## ৫. প্রাইভেসি পলিসিতে যোগ করার লাইন (lifeassisto.com/privacy)

* "If you turn on Money from notifications, Assisto reads only notifications from bKash, Nagad, Rocket, Upay, bank apps and those senders' SMS, on your phone, and saves only the transactions you confirm."
* "If you turn on After-call note, Assisto detects that a call ended. It never records calls."

(ওয়েবসাইট অর্ডার অনুযায়ী পলিসি বদল প্রিভিউ → মালিকের OK → লাইভ।)
