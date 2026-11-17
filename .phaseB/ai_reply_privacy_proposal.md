# AI reply — privacy policy proposal (ai-reply-core, 17 Nov)

For `backend/web/legal_content.py` PRIVACY (a new section after the AI chat
section). NOT applied: legal text changes need the owner's OK and the
integrator bumps LAST_UPDATED. Paste as one `S(...)` block:

```python
S("ai_reply", "AI উত্তর (প্রস্তাব, ব্যস্ত মোড, পুরো অটো)", "AI reply (suggestions, Busy mode, Full auto)",
  P("আপনি চালু করলে Assisto আপনার পাওয়া মেসেজের জন্য ২–৩টি ছোট উত্তর প্রস্তাব করে, আর আপনার বেছে নেওয়া মানুষের "
    "জন্য ব্যস্ত মোডে বা পুরো অটোতে আপনার হয়ে উত্তর দিতে পারে। এটি শুরুতে বন্ধ থাকে।",
    "When you turn it on, Assisto suggests 2–3 short replies to messages you receive and, for people you "
    "choose, can reply for you in Busy mode or Full auto. It is off by default."),
  UL(("উত্তর বানাতে আপনার ফোন পাওয়া মেসেজের লেখা ও আগের কয়েকটি লাইন আমাদের সার্ভারে পাঠায়। লেখাটি শুধু সেই "
      "মুহূর্তে উত্তর বানাতে ব্যবহার হয় — আমরা তা সংরক্ষণ করি না, লগ করি না, AI প্রশিক্ষণে ব্যবহার করি না, "
      "আমাদের কর্মী বা অ্যাডমিন দেখতে পারেন না।",
      "To make a reply, your phone sends the received message text and a few earlier lines to our server. "
      "The text is used only at that moment to make the reply — we do not store it, log it or use it to "
      "train AI, and our staff and admins cannot see it."),
     ("উত্তর বানাতে লেখাটি আমাদের AI সেবাদাতার (যেমন Anthropic, Google, OpenAI) কাছে যায়; ফোন নম্বর, "
      "অ্যাকাউন্ট নম্বর ও ইমেইল আগে ঢেকে দেওয়া হয়। সেবাদাতারা চুক্তি অনুযায়ী এই ডেটায় প্রশিক্ষণ দেয় না।",
      "To make a reply the text goes to our AI provider (such as Anthropic, Google or OpenAI); phone "
      "numbers, account numbers and e-mails are masked first. Under our contracts providers do not train "
      "on this data."),
     ("আপনার ঢঙ শেখা আলাদা সম্মতিতে: শুধু আপনার নিজের পাঠানো My Circle মেসেজ থেকে একটি ছোট প্রোফাইল "
      "(গড় দৈর্ঘ্য, ইমোজি, আপনি/তুমি, ভাষা, কয়েকটি সাধারণ শব্দ) রাখা হয়, আসল মেসেজ নয়। সম্মতি বন্ধ করলে "
      "প্রোফাইল সাথে সাথে মুছে যায়।",
      "Learning your style needs separate consent: from your OWN sent My Circle messages only, we keep a "
      "small profile (typical length, emoji use, formal/informal, language, a few common words), never "
      "the messages. Turning consent off deletes the profile at once."),
     ("AI কখনো টাকা-পয়সা, ঠিকানা, দেখা করা, স্বাস্থ্য-জরুরি, প্রতিশ্রুতি বা বড় সিদ্ধান্তের মেসেজের উত্তর দেয় না, "
      "OTP/ব্যাংক/SOS লেখায় কিছু প্রস্তাব করে না, এবং শিশু অ্যাকাউন্টে কাজ করে না।",
      "The AI never answers messages about money, addresses, meeting in person, health emergencies, "
      "promises or big decisions, suggests nothing for OTP/bank/SOS texts, and never works on child accounts."),
     ("AI-এর পাঠানো মেসেজের নিচে প্রাপক \"Assisto AI উত্তর\" ট্যাগ দেখেন (আপনি প্রতি মানুষে বন্ধ করতে পারেন)। "
      "কোন মেসেজ AI পাঠিয়েছে, কতগুলো উত্তর ও ক্রেডিট — শুধু এই হিসাব (লেখা ছাড়া) রাখা হয়।",
      "People see an \"Assisto AI reply\" tag under messages the AI sent (you can turn it off per person). "
      "We keep only which messages the AI sent and counts of replies and credits — never the text."),
     ("নোটিফিকেশনে প্রস্তাব (অন্য অ্যাপ): আপনি Notification access দিলে শুধু আপনার বেছে নেওয়া অ্যাপের মেসেজ "
      "নোটিফিকেশন পড়া হয়; আপনি ট্যাপ না করলে কিছুই পাঠানো হয় না। SOS, ব্যাংক, OTP ও পেমেন্ট নোটিফিকেশন কখনো নয়।",
      "Suggestions on notifications (other apps): only if you grant Notification access, only for apps you "
      "choose; nothing is ever sent unless you tap. Never for SOS, bank, OTP or payment notifications.")),
),
```

## Play Data safety (owner list — the owner edits Play himself)
See owner_actions/AI_REPLY_SPEC_BN.md → "Play Data safety ফর্ম".
- Messages / Other in-app messages: collected, **processed ephemerally**, not shared, optional, purpose App functionality.
- App activity / Other user-generated content (style profile): collected, optional, deletable, App functionality + Personalization.
- App activity / App interactions (reply counts, credits): collected, App functionality + Analytics.
- Encrypted in transit: yes. Data sold: no. Shared with third parties: no (AI providers = service providers/processors).
