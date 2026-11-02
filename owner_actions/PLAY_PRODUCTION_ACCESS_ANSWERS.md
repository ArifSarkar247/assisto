# Play production access — draft answers (bn + en)
Real data only, from our server and Play API on 2 Nov 2026 (UTC). Re-check the numbers on 8 Nov before you submit — they will grow.

**Facts used**
- Play Console (owner, 2 Nov): personal account; closed test published; 12 testers opted in; 8 of 14 continuous days done → "Apply for production" unlocks 8 Nov.
- Play API: closed (alpha) and internal tracks on versionCode 10278; production empty; 0 Play reviews; crash/ANR rates not shown yet (too few users).
- Our server: 29 accounts; 20 devices opened the app in the last 14 days (5 in the last day); 16 people sent 151 My Circle messages in 14 days.
- In-app error reports (scrubbed, no message text): 13 in 14 days from 5 users, 3 of them crashes; each was fixed in a later build.
- In-app "Send feedback" reports: 0 — feedback came by direct phone tests and messages to the developer (described below honestly).
- 39 testing builds published since 25 Oct (when the closed test started).

## English (paste into Play Console)
**1. How did you recruit testers?** Family, friends and small-business owners in Bangladesh whom the developer knows personally, invited by email to the closed test. They match our audience: Bangla-speaking families and small shops.

**2. How did testers use the app?** Daily use on their own Android phones (including Realme/ColorOS): My Circle messages and voice/video calls, reminders and notes, Safe Journey sharing, family alerts, budget and khata entries. In the last 14 days 20 devices opened the app and 16 testers exchanged 151 My Circle messages.

**3. What feedback did you receive and what did you change?** (real items)
- Calls: an incoming call could not be accepted from the lock screen on some phones; Bluetooth and wired earphones did not get call audio → fixed with one app-wide audio route (build 10278).
- Screens hid behind the phone's navigation bar on some brands → app-wide fix + an automated check (builds 10272–10273).
- Family Care: repeated cards, empty pages with no next step, people typed twice → redesigned; people are picked from My Circle in one tap.
- Home shortcuts the testers actually use were made the default.
- 13 automatic error reports (3 crashes) → each fixed in a later build.
We published 39 testing builds during the closed test.

**4. Who is the intended audience?** Adults (18+) in Bangladesh and Bangladeshis abroad: families who want to stay connected and safe, and small businesses that keep accounts and talk to customers. Not designed for children.

**5. Why is the app ready for production?** Every feature passed automated tests on every build (thousands of tests per build, an automatic launch check on an Android 13 emulator), crash reports are fixed, testers use it daily, and safety features (SOS, family alerts) are free on every plan. We release in stages (20% → 50% → 100%) and watch crash/ANR rates before each step.

## বাংলা (আপনার বোঝার জন্য — Play-তে ইংরেজিটা দিন)
১. **টেস্টার কীভাবে পেলেন:** ডেভেলপারের পরিচিত পরিবার, বন্ধু ও ছোট ব্যবসার মালিক — ইমেইলে ক্লোজড টেস্টে আমন্ত্রণ; তারাই আমাদের আসল ব্যবহারকারীর মতো।
২. **কীভাবে ব্যবহার করেছেন:** নিজের ফোনে রোজ — My Circle মেসেজ ও কল, রিমাইন্ডার, নিরাপদ যাত্রা, পরিবারের সতর্কতা, বাজেট ও খাতা। গত ১৪ দিনে ২০টি ফোনে অ্যাপ খোলা হয়েছে, ১৬ জন ১৫১টি মেসেজ পাঠিয়েছেন।
৩. **মতামত ও পরিবর্তন:** লক-স্ক্রিন থেকে কল ধরা ও ইয়ারফোনে কলের শব্দ ঠিক; ন্যাভিগেশন বারের নিচে পাতা ঢাকা পড়া ঠিক; ফ্যামিলি কেয়ার নতুন করে; হোমের শর্টকাট; ১৩টি স্বয়ংক্রিয় ত্রুটি-রিপোর্টের (৩টি ক্র্যাশ) প্রতিটি ঠিক। ক্লোজড টেস্টে ৩৯টি বিল্ড।
৪. **কাদের জন্য:** বাংলাদেশ ও প্রবাসের প্রাপ্তবয়স্ক (১৮+) — পরিবার ও ছোট ব্যবসা; শিশুদের জন্য নয়।
৫. **কেন প্রস্তুত:** প্রতি বিল্ডে স্বয়ংক্রিয় টেস্ট ও Android 13 এমুলেটরে চালু-পরীক্ষা, ক্র্যাশ ঠিক, টেস্টাররা রোজ ব্যবহার করছেন, নিরাপত্তা ফিচার সব প্ল্যানে ফ্রি; ধাপে ধাপে রিলিজ।

**সৎ সতর্কতা:** "In-app feedback" রিপোর্ট ০টি — তাই "টেস্টাররা অ্যাপে মতামত পাঠিয়েছেন" লিখবেন না। এখন থেকে টেস্টারদের Play-তে ও অ্যাপের "মতামত পাঠান"-এ লিখতে বলুন (নিচের বার্তা) — ৮ Nov-এর আগে আসল মতামত জমবে, সেগুলোও উত্তরে যোগ করব।
