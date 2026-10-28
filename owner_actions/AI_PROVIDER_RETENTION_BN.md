# AI কোম্পানিগুলো আমাদের ডেটা কতদিন রাখে — কোডে কী করা হয়েছে, মালিককে কী করতে হবে (AF-13)

তারিখ ২৮ অক্টোবর ২০২৬। শর্তগুলো কোম্পানিগুলোর নিজেদের পাতা থেকে নেওয়া।
শর্ত মাঝে মাঝে বদলায়, তাই চুক্তি সই করার আগে নিচের লিংকগুলো আবার মিলিয়ে নিন।

## ১. কে কী রাখে, আর কোডে আমরা কী সেট করেছি

| Provider | এমনিতে কতদিন রাখে | AI ট্রেনিংয়ে ব্যবহার? | কোডে আমরা যা সেট করেছি | কোড দিয়ে যা সম্ভব নয় |
|---|---|---|---|---|
| **Anthropic** (মূল AI, ছবি-চ্যাটের vision) | API-র ইনপুট আর আউটপুট ৩০ দিনের মধ্যে মুছে দেয়। Usage Policy ভাঙার সন্দেহ হলে বা আইনের দরকারে বেশিদিন রাখতে পারে | না — API ডেটায় এমনিতে ট্রেনিং হয় না | এমন কোনো request-অপশন নেই, তাই কিছু সেট করার নেই। মাস্কিং চালু আছে, আর SDK-র লগার আটকানো | "০ দিন রাখা" (Zero Data Retention, ZDR) শুধু Anthropic Sales-এর সঙ্গে চুক্তি করে পাওয়া যায় |
| **OpenAI** (ব্যাকআপ AI, vision, ভয়েস-থেকে-লেখা, Photo) | Abuse-monitoring লগ সাধারণত ৩০ দিন | না — API ডেটায় এমনিতে ট্রেনিং হয় না (ড্যাশবোর্ডে "share" opt-in বন্ধ থাকলে) | **`store: false`** — Chat Completions (টেক্সট) আর vision request দুটোতেই। ফলে OpenAI-র dashboard log, evals বা distillation-এ কিছু জমা থাকে না | ৩০ দিনের abuse লগ বন্ধ করা যায় শুধু অনুমোদিত ZDR বা Modified Abuse Monitoring দিয়ে, যা চুক্তির বিষয়। অডিও আর image endpoint-এ `store` নামে কোনো অপশন নেই |
| **Google Gemini API** (সস্তা/ছোট কাজ, Photo) | **পেইড টিয়ার:** abuse-monitoring-এর জন্য ৫৫ দিন। **ফ্রি টিয়ার:** prompt আর উত্তর Google-এর পণ্য উন্নত করতে ব্যবহার হতে পারে, মানুষও পড়ে দেখতে পারে | পেইড টিয়ারে না; **ফ্রি টিয়ারে হ্যাঁ** | এমন কোনো request-অপশন নেই। মাস্কিং চালু আছে | কোন টিয়ারের শর্ত খাটবে তা ঠিক হয় Google প্রজেক্টে billing চালু আছে কি না তা দিয়ে — কোড এটা ঠিক করতে পারে না |
| **Replicate / fal** (শুধু Photo Studio-র ছবি) | তাদের নিজেদের নীতি অনুযায়ী (ছবি + নির্দেশ) | — | — | মালিককে তাদের data policy দেখে নিতে হবে |

## ২. আমাদের সার্ভার নিজে যা করে (কোডে, এই কাজেই করা)
- কোনো ব্যবহারকারীর prompt বা উত্তর **লগে লেখা হয় না**। `AIUsage`-এ শুধু token, খরচ, সময় আর provider-এর নাম থাকে। একটা টেস্ট আছে যা `AIUsage`-এ prompt/text field যোগ হলেই ফেল করে।
- anthropic / openai / httpx / requests-এর লগার কোড থেকেই WARNING বা তার উপরে রাখা। তাই কেউ `ANTHROPIC_LOG=debug` চালু করলেও পুরো request লগে ছাপা হয় না।
- provider-এর error লেখা লগে যাওয়ার আগে তার ফোন/NID/অ্যাকাউন্ট/ইমেইল ঢাকা হয়।
- AI-তে যাওয়া প্রতিটি লেখা ঢাকা হয় (বিস্তারিত `AI_PRIVACY_PATHS_BN.md`-এ)। তাই কোম্পানিগুলো যা রাখে, তাতেও কাঁচা ফোন/NID/অ্যাকাউন্ট/ইমেইল থাকে না। ব্যতিক্রম: ছবি, অডিও আর বিলের অ্যাকাউন্ট নম্বর।

## ৩. মালিকের করণীয় (আইনি/অ্যাকাউন্টের কাজ — কোড দিয়ে করা যায় না)

1. **Gemini — সবচেয়ে জরুরি:** যে Google প্রজেক্টের Gemini key Owner Admin → Integrations-এ দেওয়া আছে, সেই প্রজেক্টে **Cloud Billing চালু আছে কি না** দেখুন। পথ: aistudio.google.com → API keys → প্রজেক্ট → Billing। billing না থাকলে ফ্রি টিয়ারের শর্ত খাটে, তখন আমাদের ব্যবহারকারীদের (ঢাকা) লেখাও Google ট্রেনিংয়ে ব্যবহার করতে পারে। AI Studio-তে "share dataset / logs with Google" কখনো চালু করবেন না। Developer logs-এর মেয়াদ সবচেয়ে কম (৭ দিন) রাখুন।
2. **OpenAI:** platform.openai.com → Settings → Organization → **Data controls** → "Share inputs and outputs with OpenAI" **বন্ধ** রাখুন। ফ্রি token-এর লোভেও চালু করবেন না। ZDR বা Modified Abuse Monitoring চাইলে OpenAI Sales-এ (openai.com/contact-sales) আবেদন করুন। অনুমোদন আর চুক্তি লাগবে।
3. **Anthropic:** console.anthropic.com → Settings → **Privacy Controls** দেখুন। কোনো feedback / Development Partner প্রোগ্রামে opt-in থাকবে না। ZDR চাইলে Anthropic Sales-এর মাধ্যমে আবেদন করুন — প্রতিটি organization আলাদা করে রিভিউ হয়। চালু হলে "Data retention period"-এ দেখা যাবে। মনে রাখবেন, beta ফিচারে (যেমন server-side fallback beta) ZDR না-ও খাটতে পারে। চুক্তির সময় এটা জিজ্ঞেস করে নিন।
4. **চুক্তি / DPA:** তিন কোম্পানির Data Processing Addendum (DPA) মালিকের নামে গ্রহণ বা সই করুন। এগুলো সাধারণত অ্যাকাউন্ট সেটিংস বা লিগ্যাল পাতায় পাওয়া যায়। Play Store-এর Data safety ফর্মে লিখুন: "AI প্রক্রিয়াকরণের জন্য তৃতীয় পক্ষের কাছে পাঠানো হয়, ব্যক্তিগত নম্বর ঢাকা অবস্থায়"।
5. **Replicate / fal:** Photo Studio চালু করার আগে তাদের data-retention নীতি পড়ে নিন। ছবি-ভিত্তিক যেকোনো কাজে ZDR পেতে হলে এদের সঙ্গেও কথা বলতে হবে।

সূত্র: privacy.claude.com ("How long do you store my data", "Zero data retention"), ai.google.dev/gemini-api/docs/usage-policies ও logs-policy, platform.openai.com-এর docs (data controls, `store` প্যারামিটার)।
