# ফেস-রিস্টোর / আপস্কেল প্রোভাইডার — লাইসেন্স ও দাম যাচাই (২৫ অক্টোবর ২০২৬)

**মালিকের সিদ্ধান্ত (২৫ অক্টো):** GFPGAN বন্ধই থাকবে। ফেস-রিস্টোরের জন্য শুধু সেই প্রোভাইডার নেওয়া হবে যাদের শর্তে আউটপুটের বাণিজ্যিক ব্যবহারের অনুমতি স্পষ্ট লেখা আছে। Real-ESRGAN নেওয়া হবে শুধু তখনই, যদি তার weights-এর লাইসেন্স সত্যিই পরিষ্কার হয়।

**এই রিপোর্ট কীভাবে করা:** শুধু প্রাথমিক উৎস দেখা হয়েছে: মডেল পেজ, LICENSE ফাইল, প্রোভাইডারের Terms আর pricing পেজ। কোনো সাইনআপ বা খরচ করা হয়নি। সব দাম **২৫-১০-২০২৬** তারিখে পেজে যা দেখা গেছে তা-ই, আর পরে বদলাতে পারে। যেখানে নিশ্চিত হওয়া যায়নি, সেখানে **অনিশ্চিত** লেখা আছে।

চিহ্নের মানে: ✅ = শর্তে স্পষ্ট লেখা আছে · ⚠️ = ধূসর বা অনিশ্চিত · ❌ = অনুমতি নেই, বা নন-কমার্শিয়াল

---

## ১. সবচেয়ে জরুরি কথা (আগে পড়ুন)

1. **fal.ai-এর মূল Terms আউটপুটের মালিকানা দেয় না।** মডেল পেজের "Commercial use" ট্যাগটাই একমাত্র সংকেত।
   - Terms §4(c)-তে আছে: fal কোনো আউটপুটের *"Intellectual Property Rights"* দেয় না। আউটপুট ব্যবহার *"AT CUSTOMER'S SOLE RISK"* (§16)। থার্ড-পার্টি মডেলের ব্যবহার *"may be subject to additional terms"* (§14(b))।
   - API Supplemental Terms §2-এও একই কথা: আউটপুট *"[does not] entitle Client to any Intellectual Property Rights"*।
   - সূত্র: https://fal.ai/terms , https://fal.ai/legal/api-services
   - **উদাহরণ:** fal CodeFormer-এ "Commercial use" ট্যাগ লাগিয়েছে, অথচ CodeFormer-এর নিজের লাইসেন্স নন-কমার্শিয়াল (নিচে দেখুন)। তাই **শুধু fal-এর ট্যাগ দেখে ভরসা করা যায় না।** আসল মডেলের লাইসেন্সও দেখতে হবে।
2. **Replicate আউটপুটের মালিকানা দেয়, কিন্তু সেটা মডেলের লাইসেন্সের শর্ত মেনে।**
   - §5.1: *"Customer owns and will continue to own all rights, title, and interest"* (Customer Data, যার মধ্যে Output-ও পড়ে)। তবে এই অধিকার *"subject to any Third Party Terms (as determined by the Models you use to generate the Output)"*।
   - §2.5: *"You are solely responsible for complying with all Third Party Terms."*
   - §3.1: *"You must review and agree to comply with such Third-Party Terms, including the applicable Model licenses."*
   - সূত্র: https://replicate.com/terms
3. **GFPGAN আর CodeFormer দুটোই নন-কমার্শিয়াল।** দুটোই FFHQ ডেটাসেটে ট্রেন করা।
   - FFHQ: *"made available under Creative Commons BY-NC-SA 4.0 license by NVIDIA Corporation"* (https://github.com/NVlabs/ffhq-dataset)
   - CodeFormer-এর কোড লাইসেন্স "S-Lab License 1.0"। বাণিজ্যিক ব্যবহারের জন্য *"please contact the contributor(s)"* (https://github.com/sczhou/CodeFormer/blob/master/LICENSE)। Replicate-এর CodeFormer পেজে সরাসরি লেখা: API *"cannot be used commercially"*।
   - **সতর্কতা:** Real-ESRGAN-এর `face_enhance` / `face=true` অপশন আসলে GFPGAN চালায়। README-তে আছে: *"Whether to use GFPGAN to enhance face"*। তাই এই অপশন **সবসময় বন্ধ রাখতে হবে।**

---

## ২. টেবিল — fal.ai

| প্রোভাইডার | মডেল (endpoint) | আউটপুটের বাণিজ্যিক ব্যবহার | প্রতি ছবির দাম (USD, ২৫-১০-২০২৬) | চেহারা ঠিক থাকে কি না / মান |
|---|---|---|---|---|
| fal | **Topaz Upscale** `fal-ai/topaz/upscale/image` (Topaz-এর নিজস্ব মডেল, Partner) | ✅/⚠️ পেজে "Commercial use" + "Partner" ট্যাগ আছে। কিন্তু Topaz-এর নিজের EULA-তে API আউটপুটের ধারা আমি পড়তে পারিনি (PDF এনকোডেড), তাই **অনিশ্চিত**। https://fal.ai/models/fal-ai/topaz/upscale/image | *"$0.08 for up to 24MP, $0.16 for up to 48MP"* (১টা সাধারণ ফোন-ছবি = $0.08) | **আলাদা ফেস-এনহ্যান্স প্যারামিটার আছে:** `face_enhancement` (default true), `face_enhancement_strength` (0.8), `face_enhancement_creativity` (0–1)। Creativity 0 রাখলে চেহারা বদলানোর ঝুঁকি সবচেয়ে কম। মডেল: Standard V2, High Fidelity V2, Low Resolution V2, Recovery V2 (খুব ছোট বা পুরনো ছবি), Wonder/Redefine (generative, চেহারা বদলাতে পারে, **ব্যবহার করবেন না**)। পেজে identity নিয়ে কোনো দাবি নেই। |
| fal | **Crystal Upscaler** `clarityai/crystal-upscaler` (Clarity AI, মালিকানা-মডেল) | ✅ পেজে লেখা: *"Commercial use permitted"*। Clarity AI-এর নিজের terms পড়া যায়নি (**অনিশ্চিত**)। https://fal.ai/models/clarityai/crystal-upscaler | *"$0.016 per megapixel"* → 4MP আউটপুট $0.064, 16MP $0.256 | পোর্ট্রেটের জন্য বানানো: *"prioritizes skin texture, eye clarity, and facial feature sharpness"*। "creativity" স্লাইডার = *"hallucination vs preservation tradeoff"*। কম রাখুন। |
| fal | **Recraft Crisp Upscale** `fal-ai/recraft/upscale/crisp` | ✅ ট্যাগ "Commercial use"। Recraft-এর docs: *"Images generated under a paid plan grant you full ownership and commercial rights"*। fal-এর মাধ্যমে নিলে এটা প্রযোজ্য কি না, স্পষ্ট লেখা নেই (⚠️)। https://www.recraft.ai/docs/plans-and-billing/commercial-rights-and-ownership | *"$0.004 per image"* (সবচেয়ে সস্তা) | *"refining small details and faces"*। এটা ফেস-রিস্টোর নয়, শুধু শার্প করে। নতুন ডিটেইল কম বানায়। |
| fal | **Bria Increase Resolution** `bria/increase-resolution` | ✅ ট্যাগ "Commercial use", *"Commercial-safe"*। Bria *"Trained exclusively on licensed data"* (ট্রেনিং ডেটা দিক থেকে সবচেয়ে পরিষ্কার)। | *"$0.04 per image"* | *"Preserves the original content — no regeneration, no altered details"*। ফেস-রিস্টোর নয়, শুধু রেজোলিউশন বাড়ায়। |
| fal | Bria Creative Upscale `bria/upscale/creative` | ✅ একই (licensed data) | $0.04 / ছবি | *"cleaner faces"*, কিন্তু "creative" মানে ছবি নতুন করে আঁকে, তাই চেহারা বদলাতে পারে ⚠️ |
| fal | **SeedVR2** `fal-ai/seedvr/upscale/image` (ByteDance) | ✅ কোড ও weights দুটোই Apache-2.0। HF মেটাডেটা: *"License: apache-2.0"*, README: *"SeedVR and SeedVR2 are licensed under the Apache 2.0"*। ট্রেনিং ডেটার তথ্য প্রকাশ করা হয়নি (⚠️)। https://huggingface.co/ByteDance-Seed/SeedVR2-3B | *"$0.001 per megapixel"* (খুবই সস্তা) | সাধারণ রিস্টোর ও আপস্কেল। ফেসের জন্য আলাদা কিছু নেই। পেজে মানের কোনো নোট নেই। |
| fal | Face Enhancement `fal-ai/image-editing/face-enhancement` | ⚠️ ট্যাগ "Commercial use", কিন্তু **ভেতরে কোন মডেল তা লেখা নেই** | $0.04 / ছবি | *"professional retouching"*। এটা রিটাচ (স্কিন স্মুথ করা), রিস্টোর নয়। ভেতরে সম্ভবত image-edit মডেল, তাই চেহারা বদলাতে পারে। **সুপারিশ করছি না।** |
| fal | Clarity Upscaler `fal-ai/clarity-upscaler` | ⚠️ ট্যাগ "Commercial use"। ভেতরে সম্ভবত SD-1.5 + ControlNet (পেজে লেখা নেই) | *"$0.03 per megapixel"* | Diffusion-ভিত্তিক। creativity বেশি দিলে চেহারা বদলায়। |
| fal | ESRGAN `fal-ai/esrgan` (Real-ESRGAN x4plus ইত্যাদি) | ⚠️ ট্যাগ "Commercial use", কিন্তু weights-এর অবস্থা ধূসর (§৪ দেখুন) | *"$0.00111 per compute second"* (সাধারণত ১–৩ সেকেন্ড; **অনুমান**) | `face=true` = GFPGAN, **কখনো চালু করবেন না** ❌ |
| fal | CodeFormer `fal-ai/codeformer` | ❌ fal ট্যাগ দিয়েছে "Commercial use", কিন্তু আসল লাইসেন্স S-Lab (নন-কমার্শিয়াল) + FFHQ (BY-NC-SA) | $0.0021 / MP | চেহারা ভালো রাখে, কিন্তু **লাইসেন্সের কারণে বাদ** |

## ৩. টেবিল — Replicate

| প্রোভাইডার | মডেল | আউটপুটের বাণিজ্যিক ব্যবহার | দাম (USD, ২৫-১০-২০২৬) | চেহারা / মান |
|---|---|---|---|---|
| Replicate | **topazlabs/image-upscale** (official) | ⚠️ Replicate আউটপুটের মালিকানা দেয়, তবে মডেলের শর্ত মেনে। মডেল পেজে কোনো লাইসেন্স দেখানো নেই, তাই Topaz-এর শর্ত **অনিশ্চিত** | 12/24MP = **$0.05**, 48MP = $0.10 | পেজে লেখা: *"adjust facial enhancement parameters if your photo includes a face"*। fal-এর মতো একই Topaz মডেল। |
| Replicate | philz1337x/crystal-upscaler | ⚠️ পেজে কোনো লাইসেন্স নেই | পেজে দাম দেখা যায়নি (**অনিশ্চিত**; fal-এ $0.016/MP) | মার্কেটিং দাবি *"No identity changes"*, যাচাই করা হয়নি |
| Replicate | recraft-ai/recraft-crisp-upscale | ⚠️ পেজে লাইসেন্স নেই (Recraft-এর paid-plan শর্ত, §২ দেখুন) | পেজে দেখা যায়নি (**অনিশ্চিত**) | শার্প করে, নতুন ডিটেইল বানায় না |
| Replicate | bria/increase-resolution | ⚠️ পেজে লাইসেন্স নেই। Bria-র নিজের শর্তে বাণিজ্যিক অধিকার শুধু *"users with active paid subscriptions or valid licensing agreements"*-এর জন্য (https://bria.ai/terms-of-use) | পেজে দেখা যায়নি | *"preserves the original content without regeneration"* |
| Replicate | google/upscaler | ⚠️ পেজে লাইসেন্স নেই | পেজে দেখা যায়নি | 2x/4x, কোনো সেটিং নেই |
| Replicate | zsxkib/seedvr2 | ✅ Apache-2.0 (SeedVR2) | per-second হার (**অনিশ্চিত**) | উপরের SeedVR2-এর মতো |
| Replicate | nightmareai/real-esrgan | ⚠️ weights ধূসর। পেজে লাইসেন্স বা দাম কিছুই নেই | **অনিশ্চিত** | *"with GFPGAN ... exposed"*, face অপশন বন্ধ রাখতে হবে |
| Replicate | tencentarc/gfpgan | ❌ FFHQ BY-NC-SA | ~$0.0034/run | **বাদ (মালিকের সিদ্ধান্ত)** |
| Replicate | sczhou/codeformer | ❌ পেজে নিজেই লেখা: *"cannot be used commercially"* | ~$0.0043/run | বাদ |
| Replicate | lucataco/pasd-magnify | ❌ *"Academic and non-commercial use only"* | — | বাদ |

## ৪. অন্য প্রোভাইডার

| প্রোভাইডার | মডেল | আউটপুটের বাণিজ্যিক ব্যবহার | দাম (USD, ২৫-১০-২০২৬) | মন্তব্য |
|---|---|---|---|---|
| **Stability AI API** | Fast / Conservative / Creative Upscaler | ✅ **সবচেয়ে স্পষ্ট ভাষা:** *"we assign to you all of our right, title, and interest (if any) in the Outputs ... you own the Output"* (ToS §4(a), https://stability.ai/terms-of-service) | Fast = 2 credit = **$0.02**, Conservative = $0.40, Creative = $0.60 (*"1 credit = $0.01"*, https://docs.stability.ai/pricing) | কোনো ফেস-রিস্টোর এন্ডপয়েন্ট নেই। Conservative চেহারা ধরে রাখার জন্য বানানো, কিন্তু দামি। |
| Topaz Labs (সরাসরি API) | Enhance / Faces | ⚠️ **অনিশ্চিত।** EULA (Sep 2025) API-ও কভার করে, কিন্তু আউটপুট-মালিকানার ধারা আমি পড়তে পারিনি। ফোরামে পুরনো শর্তের উল্লেখ আছে: বছরে $1M-এর বেশি আয় হলে commercial license লাগে (যাচাই করা হয়নি) | ক্রেডিট: Developer $50/মাস = 500 credit ($0.10/credit), Scale $0.08/credit। ১ credit = 24MP পর্যন্ত। https://www.topazlabs.com/api | fal বা Replicate দিয়ে নিলে মাসিক প্ল্যান লাগে না |
| Picsart API | picsart-enhance (upscale + face enhance) | ⚠️ pricing পেজে বাণিজ্যিক ব্যবহার নিয়ে কোনো কথা নেই। API terms পড়া হয়নি | মডেল পেজে *"$0.044 / generation"*। আরেক পেজে 2 credit (~$0.01)। **দুই জায়গায় দুই রকম, অনিশ্চিত** | ভেতরে কোন মডেল তা লেখা নেই |
| Claid.ai (Let's Enhance) | restorations: "faces" | ⚠️ terms পড়া যায়নি | ক্রেডিট-ভিত্তিক, আনুমানিক $0.06–0.35/ছবি (তৃতীয় পক্ষের সূত্র, **অনিশ্চিত**) | পোর্ট্রেট মোড আছে |
| Google Vertex | imagen-4.0-upscale-preview | ⚠️ Preview মডেল। Google Cloud-এর শর্ত সাধারণত গ্রাহককে আউটপুট দেয়, কিন্তু এখানে যাচাই করা হয়নি | দাম পাওয়া যায়নি (**অনিশ্চিত**) | সর্বোচ্চ 17MP। ফেস-রিস্টোর নয়। |
| Clipdrop | Image Upscaler | ⚠️ API-এর বাণিজ্যিক শর্ত প্রাথমিক উৎসে পাওয়া যায়নি | **অনিশ্চিত** | বাদ দেওয়ার পরামর্শ |

---

## ৫. Real-ESRGAN — weights কি বাণিজ্যিকভাবে পরিষ্কার? → **না, পুরোপুরি পরিষ্কার নয় (ধূসর)**

আমাদের সার্ভারের `old_restore` এখন **Real-ESRGAN general x4v3** চালায় (`backend/core/photo_restore.py`)। তাই এই অংশটা সরাসরি আমাদের অ্যাপের সাথে জড়িত।

| বিষয় | যা পাওয়া গেছে | অবস্থা |
|---|---|---|
| কোড | LICENSE: *"BSD 3-Clause License — Copyright (c) 2021, Xintao Wang"* (https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE) | ✅ পরিষ্কার |
| weights (.pth) | LICENSE-এ শুধু *"source and binary forms"* লেখা, **মডেল বা weights-এর আলাদা উল্লেখ নেই**। README-তেও নেই। একই রিপোর release-এ দেওয়া, তাই সাধারণত ধরে নেওয়া হয় BSD-3 এগুলোকেও কভার করে, কিন্তু **কোথাও স্পষ্ট লেখা নেই** | ⚠️ ধূসর |
| ট্রেনিং ডেটা | Training.md: *"We use DF2K (DIV2K and Flickr2K) + OST datasets"* | — |
| DIV2K | *"this dataset is made available for academic research purpose only"*, *"the copyright belongs to the original owners"* (https://data.vision.ee.ethz.ch/cvl/DIV2K/) | ⚠️ শুধু গবেষণার জন্য |
| Flickr2K / OST | প্রকাশিত কোনো লাইসেন্স পাওয়া যায়নি। ছবিগুলো Flickr বা ইন্টারনেট থেকে সংগ্রহ করা | ⚠️ অজানা |
| face_enhance | GFPGAN চালায় | ❌ বন্ধ রাখতে হবে |

**সৎ মূল্যায়ন:**
- কোড পরিষ্কার।
- Weights-এর ক্ষেত্রে লেখক BSD-3 রিপোতে প্রকাশ করেছেন, আর বাস্তবে অনেক বাণিজ্যিক পণ্য এগুলো ব্যবহার করে। কিন্তু ট্রেনিং ডেটা (DIV2K) "academic research only"।
- "Research-only ডেটায় ট্রেন করা weights বাণিজ্যিকভাবে ব্যবহার করা যায় কি না", এই আইনি প্রশ্নের উত্তর এখনো মীমাংসিত নয়।
- তাই "commercially clean, verified" বলা **যাবে না**। বড়জোর "কম ঝুঁকির ধূসর" বলা যায়।
- মালিকের শর্ত ছিল "শুধু যদি clean হয়"। সেই শর্ত কঠোরভাবে মানলে Real-ESRGAN **পাস করে না।**

**বিকল্প:**
- (ক) মালিক লিখিতভাবে এই ধূসর ঝুঁকি মেনে নিয়ে Real-ESRGAN রাখবেন, অথবা
- (খ) সার্ভারের ধাপটা **SeedVR2-এ (Apache-2.0 কোড + weights)** নেওয়া হবে, অথবা fal/Replicate-এর বাণিজ্যিক-ট্যাগওয়ালা আপস্কেলারে।
- SeedVR2 3B আমাদের ২-vCPU CPU-তে চলবে না, তাই শুধু GPU API দিয়ে নিতে হবে। SeedVR2-এর ট্রেনিং ডেটাও প্রকাশিত নয়, তবে লাইসেন্স স্পষ্ট Apache-2.0।

**পার্শ্ব-নোট (অনিশ্চিত, যাচাই করা হয়নি):** DDColor সাধারণত ImageNet-এ ট্রেন করা হয়, আর ImageNet-এর শর্ত "non-commercial research"। এর অবস্থাও Real-ESRGAN-এর মতো ধূসর হতে পারে। আলাদাভাবে যাচাই করা দরকার।

---

## ৬. সুপারিশ

**প্রথম পছন্দ (ফেস-রিস্টোর): Topaz, fal.ai দিয়ে** (`fal-ai/topaz/upscale/image`)
- সেটিং: `model="Standard V2"` (খুব খারাপ বা ছোট ছবির জন্য "Low Resolution V2" / "Recovery V2"), `face_enhancement=true`, `face_enhancement_creativity=0`, `face_enhancement_strength` প্রায় 0.5–0.8।
- দাম **$0.08/ছবি** (24MP পর্যন্ত)।
- কারণ: আসল ফেস-রিকভারি প্যারামিটার আছে (এগুলোর কোনোটাই GFPGAN বা CodeFormer নয়, Topaz-এর নিজস্ব মডেল)। fal পেজে "Commercial use" + "Partner" ট্যাগ আছে।
- একই মডেল Replicate-এ **$0.05**-এ পাওয়া যায়, আর আমাদের কোডে Replicate ইন্টিগ্রেশন আগে থেকেই আছে। কিন্তু Replicate পেজে কোনো বাণিজ্যিক ট্যাগ বা লাইসেন্স নেই, তাই আমি fal রাখছি প্রথমে।
- মালিক Replicate নিতে চাইলে Topaz-এর শর্ত (নিচের চেকলিস্ট) নিশ্চিত করে নিতে হবে।
- আমাদের নিজের **FACE LOCK** চেক (চেহারা না মিললে ফল বাতিল) আগের মতোই চালু থাকবে। Topaz আউটপুটেও এটা চালাতে হবে।

**ব্যাকআপ:** Clarity **Crystal Upscaler, fal দিয়ে** (`clarityai/crystal-upscaler`)
- পেজে সরাসরি লেখা *"Commercial use permitted"*, পোর্ট্রেটের জন্য বানানো।
- দাম $0.016/MP, অর্থাৎ ৪MP আউটপুটে প্রায় $0.064।
- creativity কম রাখতে হবে।

**শুধু শার্প বা বড় করার (ফেস-রিস্টোর নয়) সস্তা ও পরিষ্কার বিকল্প:**
- Recraft Crisp: $0.004/ছবি
- SeedVR2: $0.001/MP, Apache-2.0
- Bria Increase Resolution: $0.04, licensed data

**বাদ:** GFPGAN, CodeFormer (fal-এর ট্যাগ থাকলেও), PASD, যেকোনো `face_enhance` অপশন (= GFPGAN), এবং "creative"/"Wonder"/"Redefine" মোড (চেহারা বদলায়)।

---

## ৭. মালিককে নিজে যা দেখে নিশ্চিত বা মেনে নিতে হবে (সাইনআপের আগে)

1. **fal.ai:**
   - Terms (§4(c), §14, §16) আর API Supplemental Terms পড়ে মেনে নিন: fal আউটপুটের IP *দেয় না*, আর ঝুঁকি আমাদের।
   - প্রতিটি মডেলের পেজে "Commercial use" ট্যাগ আছে কি না, সাইনআপের দিন আবার দেখুন।
   - fal সাপোর্টকে লিখিতভাবে জিজ্ঞেস করুন: "Partner মডেল (Topaz, Clarity)-এর আউটপুট কি আমাদের অ্যাপের পেইং ইউজারকে বাণিজ্যিকভাবে দেওয়া যাবে?" উত্তরটা সংরক্ষণ করুন।
2. **Topaz:**
   - EULA (Sep 2025, https://downloads.topazlabs.com/web-assets/Topaz%20-%20EULA%20Updated%20September%202025-fl2nr.pdf) খুলে আউটপুট-মালিকানা আর $1M রেভিনিউ সীমার ধারা নিজে পড়ুন। আমি এটা যাচাই করতে পারিনি।
   - দরকার হলে enterprise টিমকে জিজ্ঞেস করুন।
3. **Clarity AI:** clarityai.co-এর terms পড়ুন। আমি পড়তে পারিনি।
4. **Recraft / Bria:** তাদের বাণিজ্যিক অধিকার শর্ত হলো "paid plan / licensing agreement"। fal বা Replicate দিয়ে নিলে এটা প্রযোজ্য কি না নিশ্চিত হোন।
5. সব প্রোভাইডারের শর্তে **আউটপুট দিয়ে AI মডেল ট্রেন করা নিষেধ** (fal §14(c), Recraft, Stability §8(b))। আমরা ট্রেন করব না, এটা মেনে নিতে হবে।
6. **ইউজারের ছবি থার্ড-পার্টির কাছে যায়।** fal-এ Partner মডেলে Client Content *"will be transferred to such a third party"*। আমাদের প্রাইভেসি পলিসিতে এটা লেখা থাকতে হবে।
7. **Real-ESRGAN:** (ক) ধূসর ঝুঁকি লিখিতভাবে মেনে নিয়ে রাখবেন, নাকি (খ) GPU-API আপস্কেলারে সরাবেন। সিদ্ধান্ত মালিকের।
8. দাম চূড়ান্ত করার আগে সাইনআপের দিনে pricing পেজ আবার দেখুন। Profit Guard-এ খরচ সেট করতে হবে।
