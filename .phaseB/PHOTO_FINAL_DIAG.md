# Photo Studio FINAL — diagnosis: why a portrait came out "almost unchanged" (24 Oct 2026)

Owner test: his own portrait through Remini vs Assisto. Remini = sharp restored face, smooth
natural skin, warm bright tone, portrait background blur. Assisto = almost the same photo.
This file explains exactly what the code did before this branch (`agent/photo-final`), read from
`backend/core/photo_worker.py`, `core/photo_restore.py` (`enhance_rgb`, `face_detail_pass`),
`app/lib/photo_studio/ps_enhance.dart` / `ps_classic.dart` (builds 213+).

## What happened to a phone portrait (e.g. Realme 9i, 4080×3060, face ~1 000 px wide)

| step | before this branch | effect on a normal phone portrait |
|---|---|---|
| On-device "Enhance" (default card) | classical pass on the ≤ 1 024 px preview: WB, levels, guided-filter denoise, CLAHE, light unsharp; AI tiles only if the AI switch is on (off by default for big photos, see D1_ROOT_CAUSE) | small, mostly invisible change on an already well-exposed photo |
| Server "HD portrait" (`enhance_server`) | `enhance_rgb`: whole-image Real-ESRGAN **only if long edge × 1.5 ≤ output cap** (2 048 free / 4 096 premium) → a 4 080 px photo is **skipped**, it "keeps its own pixels" | no AI at all on real phone photos |
| Face detail pass | `face_detail_pass` only for faces **≤ 320 px** | a selfie/portrait face (600–1 500 px) got **nothing** |
| Face restoration | **deliberately not offered** — GFPGAN/CodeFormer/RestoreFormer weights are not licence-clean (MODEL_LICENSES.md) | no "re-imagined" crisp face like Remini |
| Tone | levels fix **only for faded photos** (1–99 % luma span < 0.8) | normal portrait: no brightness, warmth or contrast change |
| Skin | nothing on the server | no smoothing |
| Background | nothing on the server (blur was a separate on-device tool) | no portrait blur |
| CPU caps | Real-ESRGAN input ≤ 768/1 024 px, x4, 128-px tiles at ~0.6 s each on the 2-vCPU box | big photos were skipped for time, small ones got upscaled |
| FACE LOCK | YuNet + AuraFace identity check, paste-back | correct, but had almost nothing to protect against |

**Root cause in one line:** for a real phone portrait the server enhance did nothing except
(sometimes) a levels fix — every AI step was gated on SMALL photos or SMALL faces, and the steps
that make Remini look "better" (face restoration, skin, warm tone, portrait blur) did not exist on
the server. Face restoration was off for licence reasons (correctly).

## What this branch changes

1. **Local (free, CPU) pipeline now has a real "look" stage** (`core/photo_look.py`), run on every
   enhance at ≤ 2 MP: denoise only when noisy → **Real-ESRGAN face pass on every face** (crop shrunk
   to ≤ 192 px, x4, luminance detail blended in the face ellipse — works for big faces too) →
   **skin smoothing** (bilateral on a skin mask inside the face, eyes/mouth excluded, 32–40 % fine
   texture put back) → **auto tone** (under-exposed scenes lifted, levels, CLAHE, partial grey-world
   WB + a little warmth, vibrance sparing skin) → **skin-tone guard** (a face may change only as much
   as the whole scene: never whitened, never darkened) → optional **portrait blur** (U²-Net-p mask,
   faces forced in, normalised blur). **Natural / Strong** presets. FACE LOCK afterwards as before.
2. **Provider switch on the server** (`core/photo_final.py`): `local_worker` (default, free),
   `replicate` (Real-ESRGAN x2 + optional GFPGAN behind the owner's legal switch, OFF),
   `runpod_serverless`, `assisto_face` (own model, Phase 2) — % rollout, fallback to the previous
   provider, result cache, 1 USD/day global cap with an honest "in queue" wait, per-image log in
   Owner Admin → Photo Studio.
3. **Ultra HD** (Premium only, fal.ai Crystal Upscaler) with a monthly quota computed from the plan's
   NET price.
4. Free rules: 3 free enhances per account/device for life, then 2 rewarded ads each (when AdMob is
   live) or 1 free a week until then, then Premium — server-enforced per account AND device.

Baseline numbers (local provider, this CPU): `owner_actions/photo_bench/README.md`.

## বাংলা সারাংশ (STATUS-এর জন্য)

- আগে সার্ভারের "HD পোর্ট্রেট" ফোনের বড় ছবিতে প্রায় কিছুই করত না: AI ধাপ শুধু ছোট ছবি/ছোট মুখে চলত, ত্বক-আলো-রং-ব্যাকগ্রাউন্ড ব্লার সার্ভারে ছিলই না, আর মুখ রিস্টোর (GFPGAN) লাইসেন্সের কারণে বন্ধ ছিল — তাই ছবি "প্রায় একই" দেখাত।
- এখন ফ্রি সার্ভার পাইপলাইনে প্রতিটি মুখে Real-ESRGAN ডিটেইল, স্বাভাবিক ত্বক মসৃণ, উষ্ণ-উজ্জ্বল টোন (ত্বক ফর্সা করা হয় না), পোর্ট্রেট ব্লার, Natural/Strong — আর পেইড GPU প্রোভাইডার (Replicate/RunPod/নিজস্ব মডেল) সার্ভার থেকে সুইচ করা যায়, দৈনিক ১ ডলার খরচের সীমাসহ।
- GFPGAN-এর ওজন (weights) বাণিজ্যিক ব্যবহারে পরিষ্কার নয় (FFHQ নন-কমার্শিয়াল ডেটায় ট্রেইন) — তাই এটি ডিফল্ট বন্ধ; চালু করা মালিকের আইনি সিদ্ধান্ত।
