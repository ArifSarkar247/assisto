# Google Search Console — lifeassisto.com (১৭ নভেম্বর)

## কী ঠিক করা হলো
- একটাই আসল ঠিকানা: **https://lifeassisto.com** । www আর http থেকে নিজে নিজে এখানে চলে আসে (301)।
- প্রতিটা পাবলিক পাতায় নিজের "canonical" ট্যাগ (বাংলা = সাধারণ ঠিকানা, ইংরেজি = `?lang=en`)।
- পাবলিক পাতায় কোথাও noindex নেই: হোম, ফিচার (+৭টা ফিচার পাতা), দাম, নিরাপত্তা, সাহায্য, **নতুন "আমাদের সম্পর্কে" (/about)**, গোপনীয়তা, শর্তাবলি, রিফান্ড, অ্যাকাউন্ট মুছুন, ফ্রি টুল (খাতা, CV, স্ক্যাম, ছবি, উৎসব, made30), /get।
- noindex থাকে শুধু ব্যক্তিগত পাতায়: owner প্যানেল, /preview, /premium (পেমেন্ট), শেয়ার-লিংক (যাত্রা, CCTV, খাতার বাকি, ইনভয়েস, কোটেশন, ডকুমেন্ট, গাড়ি, বুকিং, আমন্ত্রণ ইত্যাদি), CV/স্ক্যাম ফলাফল লিংক।
- api.lifeassisto.com আর track.lifeassisto.com-এ ওয়েব পাতা এখন "noindex" — Google আর এগুলোকে ডুপ্লিকেট ধরবে না। অ্যাপ (/api/) আর ডাউনলোড (/dl/) আগের মতোই চলে।
- sitemap.xml: সব পাবলিক পাতা বাংলা + ইংরেজি, hreflang (bn, en, x-default)। robots.txt sitemap দেখায়।
- ১৩ নভেম্বরের Google যাচাই (meta ট্যাগ + googlece9fd85bfb550cfb.html) যেমন ছিল তেমনই আছে।

## আপনার কাজ (৫ মিনিট, ডেপ্লয়ের পরে)
1. search.google.com/search-console খুলুন → উপরে property **lifeassisto.com** বাছুন।
2. বাঁ মেনু → **Sitemaps** → "Add a new sitemap" ঘরে লিখুন `sitemap.xml` → **Submit**। কিছুক্ষণ পর Status "Success" দেখাবে।
3. উপরের সার্চ ঘরে (URL Inspection) একটা একটা করে দিন → **Request indexing**:
   `https://lifeassisto.com/` · `https://lifeassisto.com/features` · `https://lifeassisto.com/pricing` · `https://lifeassisto.com/about`
   (দিনে কয়েকটার বেশি দেওয়া যায় না — বাকিগুলো sitemap থেকে Google নিজেই নেবে।)
4. বাঁ মেনু → **Pages** → প্রতিটা সমস্যার ভেতরে ঢুকে **Validate fix** চাপুন। Google ২–৪ সপ্তাহ ধরে আবার দেখে।

## ৩টা রিপোর্টের মানে (এই ঠিকের পরে)
- **Duplicate without user-selected canonical** — আগে কিছু পাতায় canonical ছিল না, আর api./track. ঠিকানায় একই পাতা দেখা যেত। এখন সব পাতায় canonical আছে, ওই ঠিকানাগুলো noindex। Validate fix-এর পরে এটা কমে শূন্যের দিকে যাবে।
- **Excluded by noindex** — এখানে শুধু ব্যক্তিগত পাতা থাকা উচিত (owner, preview, premium, শেয়ার-লিংক, api./track. ঠিকানা)। এটা **ঠিক আছে, ইচ্ছা করেই**। কোনো পাবলিক পাতা (উপরের তালিকার) এখানে দেখলে আমাদের জানান।
- **Alternative page with proper canonical** — যেমন `http://`, `www.` বা `?ref=...` লাগানো ঠিকানা, যেগুলো আসল পাতার দিকে দেখায়। এটা **স্বাভাবিক ও ঠিক আছে** — কিছু করতে হবে না। বাংলা ও ইংরেজি (`?lang=en`) দুটোই আলাদা আসল পাতা, দুটোই index হবে।
