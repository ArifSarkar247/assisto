# ফটো স্টুডিও — GPU প্রোভাইডার সেটআপ (Replicate ও fal.ai)

**কেন:** এখন ফ্রি সার্ভার পাইপলাইন (আমাদের CPU, খরচ ০) চালু আছে। আরও ভালো মুখ/বিস্তারিত চাইলে
Replicate (GPU, প্রতি সেকেন্ডে টাকা) আর প্রিমিয়ামের Ultra HD-র জন্য fal.ai যোগ করা যায়।
অ্যাপ কখনো সরাসরি এদের সাথে কথা বলে না — ফোন ছবি পাঠায় আমাদের সার্ভারে, সার্ভার ঠিক করে কোথায় যাবে।

**নিয়ম:** key কখনো চ্যাটে, WhatsApp-এ বা git-এ দেবেন না। শুধু **Owner Admin → Integrations**-এ পেস্ট করবেন।
কোনো সব-সময়-চালু GPU নেই — শুধু ব্যবহার হলে টাকা কাটে।

## দাম (যাচাই করা হয়েছে ২৪–২৫ অক্টোবর ২০২৬)

| কী | দাম | সূত্র |
|---|---|---|
| Replicate GPU — Nvidia T4 | $0.000225 / সেকেন্ড ($0.81/ঘণ্টা) | https://replicate.com/pricing |
| Replicate GPU — L40S | $0.000975 / সেকেন্ড ($3.51/ঘণ্টা) | https://replicate.com/pricing |
| Replicate GPU — A100 80GB / H100 | $0.0014 / $0.001525 প্রতি সেকেন্ড | https://replicate.com/pricing |
| Replicate `nightmareai/real-esrgan` | পেজে দাম দেখায় না — খরচ = আসল GPU সেকেন্ড × দাম; আমাদের সার্ভার প্রতিটি ছবির আসল সেকেন্ড (`metrics.predict_time`) থেকে খরচ লগ করে। আনুমানিক ২–৮ সেকেন্ড ≈ $0.002–0.008 (অনুমান, প্রথম রানে যাচাই হবে) | https://replicate.com/nightmareai/real-esrgan |
| fal.ai `clarityai/crystal-upscaler` (Ultra HD / ফেস-আপস্কেলার "crystal") | $0.016 প্রতি মেগাপিক্সেল (আউটপুট) — ১ MP ইনপুট × ২ গুণ = ৪ MP ≈ $0.064 (২৫ অক্টো পেজে দেখা) | https://fal.ai/models/clarityai/crystal-upscaler |
| fal.ai `fal-ai/topaz/upscale/image` (ফেস-আপস্কেলার "topaz") | $0.08 প্রতি ছবি (২৪MP পর্যন্ত; ২৫ অক্টো পেজে দেখা) | https://fal.ai/models/fal-ai/topaz/upscale/image |
| fal.ai বিকল্প: `fal-ai/recraft/upscale/crisp` | $0.004 প্রতি ছবি | fal.ai মডেল পেজ |
| fal.ai বিকল্প: `fal-ai/seedvr/upscale/image` | $0.001 প্রতি মেগাপিক্সেল | fal.ai মডেল পেজ |
| RunPod Serverless (পরে, নিজস্ব মডেলের জন্য) | 24GB (L4/A5000) $0.69/ঘণ্টা ≈ $0.00019/সেকেন্ড; 4090 $1.10/ঘণ্টা | https://www.runpod.io/pricing |

**খরচের সীমা (সার্ভারে):** সব পেইড প্রোভাইডার মিলিয়ে দিনে সর্বোচ্চ **$1** (Owner Admin → Ads → `daily_spend_cap_usd`)।
সীমা পার হলে কাজ সারিতে অপেক্ষা করে (ব্যবহারকারী দেখে "সারিতে আছে"), পরদিন চলে — কোনো টাকা বাড়তি কাটে না।
একই ছবি + একই সেটিং আবার চাইলে ক্যাশ থেকে আসে — খরচ ০।

## ২৫ অক্টোবরের নিয়ম (আগে পড়ুন)
- **GFPGAN স্থায়ীভাবে বন্ধ** (আপনার সিদ্ধান্ত; FFHQ নন-কমার্শিয়াল)। সার্ভার কোডেই বন্ধ — কোনো সুইচে আর চালু হয় না। CodeFormer-ও না।
  Real-ESRGAN-এর `face_enhance` কখনো পাঠানো হয় না (ওটা ভেতরে GFPGAN চালায়)।
- **Real-ESRGAN = আপনার সিদ্ধান্ত বাকি** (weights-এর লাইসেন্স ধূসর)। Owner Admin → Ads → `realesrgan_allowed` ডিফল্ট **বন্ধ**।
  বন্ধ থাকলে: সার্ভারের ফ্রি পাইপলাইন Lanczos + unsharp (কোনো ML weights নেই) দিয়ে চলে; পুরনো-ছবি রিস্টোরও তাই;
  Replicate ও RunPod (দুটোই Real-ESRGAN চালায়) ব্যবহার হয় না; ফোনে ডাউনলোডযোগ্য AI ধাপ (Real-ESRGAN ONNX) দেওয়া হয় না —
  অ্যাপ তখন সেটা লুকিয়ে রাখে, সাধারণ এনহ্যান্স আগের মতোই কাজ করে।
- **ফেস-আপস্কেলার = আপনার সিদ্ধান্ত বাকি:** Topaz (fal, $0.08/ছবি) না Clarity Crystal (fal, $0.016/MP)। দুটোই তৈরি আছে, দুটোই বন্ধ।
  চালু করতে নিচের ৩ নম্বর অংশ দেখুন। বাছাই না করা পর্যন্ত অ্যাপে কিছু দেখায় না।
- বিস্তারিত লাইসেন্স: `owner_actions/PHOTO_FACE_PROVIDERS_BN.md`।

## ১) Replicate (HD এনহ্যান্স GPU) — শুধু `realesrgan_allowed` চালু করলে

1. https://replicate.com → **Sign in with GitHub** (বা ইমেইল)।
2. **Account → Billing** → কার্ড যোগ করুন → প্রথমে **$5** ক্রেডিট কিনুন (prepaid)। অটো-রিচার্জ **বন্ধ** রাখুন।
3. **Billing → Spend limit / Usage alerts**: মাসিক সীমা **$5** দিন, $3-এ ইমেইল অ্যালার্ট চালু করুন।
4. **Account → API tokens → Create token** → নাম দিন `assisto-photo` → কপি করুন (r8_ দিয়ে শুরু)।
5. https://replicate.com/nightmareai/real-esrgan → **Versions** ট্যাব → সবচেয়ে নতুন version ID কপি করুন।
6. **Owner Admin → Integrations → "Photo Studio HD enhance — Replicate"**:
   - API Token: (৪ নম্বর থেকে)
   - Real-ESRGAN মডেল version: (৫ নম্বর থেকে)
   - GPU দাম প্রতি সেকেন্ড: `0.000975` (L40S; পেজে অন্য হার্ডওয়্যার দেখালে সেটার দাম)
   - ছবি প্রতি আনুমানিক খরচ: `0.01`
   - **Save → Test** (সবুজ ✓ আসবে)।
7. **Owner Admin → Ads → Photo Studio** অংশে `realesrgan_allowed` টিক + `rollout_replicate` = **10** (মানে ১০% ব্যবহারকারী) → Save।
   কয়েকদিন **Owner Admin → Photo Studio → Enhance providers** লগে খরচ/সময়/ব্যর্থতা দেখুন, ঠিক থাকলে বাড়ান।
   সমস্যা হলে `rollout_replicate` = 0 → সাথে সাথে আবার ফ্রি সার্ভার পাইপলাইন।

## ২) fal.ai (প্রিমিয়ামের Ultra HD)

1. https://fal.ai → **Sign up** (GitHub/Google)।
2. **Billing** → কার্ড → **$5** ক্রেডিট। অটো-টপআপ বন্ধ।
3. **Dashboard → Keys → Add key** → নাম `assisto-ultra` → কপি করুন।
4. **Owner Admin → Integrations → "Photo Studio — fal.ai"**:
   - API Key: (৩ নম্বর থেকে)
   - Ultra HD মডেল: খালি রাখুন (= `clarityai/crystal-upscaler`) বা `fal-ai/topaz/upscale/image`
   - দাম প্রতি মেগাপিক্সেল: `0.016`
   - স্কেল: `2`, ইনপুট সর্বোচ্চ MP: `1`
   - Save।
5. কোটা নিজে থেকেই হিসাব হয়: প্ল্যানের **নেট** দামের (Play ফি বাদে) **২৫%** (`ultra_hd_budget_pct`) ÷ ছবি প্রতি খরচ।
   উদাহরণ: Premium ৳১৯৯ → নেট ≈ ৳১৬৯ → ২৫% ≈ ৳৪২ → ছবি প্রতি $0.064 × ১২২ ≈ ৳৭.৮ → **মাসে ৫টি Ultra HD**।
   তাই Ultra HD-র খরচ কখনো প্ল্যানের দামের বেশি হবে না।

## ৩) fal.ai ফেস-আপস্কেলার (HD এনহ্যান্সে মুখ — Topaz বা Crystal)
একই fal.ai key ব্যবহার হয় (২ নম্বর অংশ)।
1. **Integrations → "Photo Studio — fal.ai"**: Topaz নিলে `Topaz দাম প্রতি ছবি` = `0.08`; Crystal নিলে `Crystal দাম প্রতি মেগাপিক্সেল` = `0.016` → Save।
2. **Owner Admin → Ads → Photo Studio**: `fal_face_model` = `topaz` বা `crystal`, তারপর `rollout_fal_face` = **10** → Save।
3. সার্ভার পাঠায়: সর্বোচ্চ ২ MP, x2। Topaz: "Standard V2", face enhancement চালু, creativity **0** (চেহারা না বদলাতে)।
   Crystal: creativity Natural-এ 0, Strong-এ 1। এরপর আমাদের টোন/পোর্ট্রেট ব্লার, তারপর **Face Lock** — মুখ না মিললে আসল মুখ ফেরত।
4. প্রতি ছবির আসল খরচ লগ হয়; দৈনিক $1 সীমা এখানেও। ত্রুটি হলে আমাদের ফ্রি পাইপলাইনে ফেরে।
5. বন্ধ করতে `rollout_fal_face` = 0 বা `fal_face_model` খালি।

## ৪) কী কোথায় দেখবেন
- **Owner Admin → Photo Studio → Enhance providers**: প্রতিটি ছবির প্রোভাইডার, মডেল version, খরচ (USD), সময়, ক্যাশ হিট, ফলব্যাক।
- আজকের পেইড খরচ / দৈনিক সীমা একই জায়গায়।
- কোনো key না থাকলে অ্যাপে শুধু যা সত্যিই কাজ করে তা-ই দেখায় (ফ্রি সার্ভার পাইপলাইন) — কোনো মরা বোতাম নেই।
