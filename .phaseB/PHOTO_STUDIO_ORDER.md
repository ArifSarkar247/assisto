
OWNER FINAL ORDER — PHOTO STUDIO (replaces ALL earlier Photo Studio messages). Queue it right after
the voice assistant. Premium "Silicon Valley" quality, bn/en, real end-to-end test on the emulator
(Reality Audit A/B/C/D). Tagline: "আপনার মুখ আপনারই — শুধু সবচেয়ে সুন্দর রূপে।"

GOAL: Remini-level "wow" enhance in one tap + ChatGPT/Gemini-style editing and generation by prompt
— and the person is ALWAYS clearly recognisable as the same person, just looking their best.

1. ONE-TAP ENHANCE (the hero feature) — Assisto's OWN on-device AI, NO API key, ~zero cost:
   deblur/sharpen, denoise, upscale 2x (4x where the phone can), restore old/scratched photos,
   colorize black-and-white, low-light fix, natural face restoration. Stunning but natural;
   before/after slider; strength control (default "Natural"). Models download inside Assisto on
   first use ("preparing the photo tool…") — never a separate install. Use ONLY models whose licence
   allows commercial use (e.g. Real-ESRGAN BSD-3; CodeFormer is NON-commercial — do NOT use it;
   verify GFPGAN and every model + weights). List them in .phaseB/MODEL_LICENSES.md.

2. EDIT / GENERATE BY PROMPT (bn / Banglish / en, typed or voice) + tickable ready options: change/
   remove/blur background, sky replace, remove objects or people in the background, scene lighting/
   colour, passport/visa photo (BD sizes, white background), product photo (studio/white background
   for business), document cleanup, crop/straighten, and BEAUTY RETOUCH. Generative work uses a
   cloud provider adapter (Gemini image editing / OpenAI image / Replicate-class), switchable in
   Integrations, key-gated with an honest "needs key X" state; add keys + cost per image to
   OWNER_UNLOCK_LIST.md.

3. FACE RULE — "same person, best version" (enhance, edits and generation):
   a) Scene edits: FACE-LOCK — detect faces on-device (ML Kit), mask them so the model edits only
      outside, composite the ORIGINAL face pixels back with seamless blending.
   b) Beauty retouch (when the user wants to look better/brighter): allowed — skin smoothing,
      blemish/acne removal, under-eye dark circles, even skin tone, glow and face lighting, teeth
      whitening, eye brightening, hair tidy, light natural makeup look; strength slider, default
      "Natural". NOT allowed: changing face shape/jaw/cheeks, eye/nose/lip size or shape, skin
      colour to a different tone, age or gender, or making the person look like someone else.
   c) IDENTITY GUARD on every result: face-embedding similarity (ArcFace-class) + facial-landmark
      geometry before vs after; below threshold → discard and redo lighter. Never show a result
      that is not clearly the same person. Original always kept; undo + version history.

4. ADS & MONETISATION (free users; Premium/Business = no ads, use the monthly pool; all numbers
   admin-editable; Profit Guard applies — a loss-making edit must be impossible, add tests):
   - ENTRY AD: when a free user opens Photo Studio, show an interstitial FIRST, then the studio
     opens. Frequency cap: max once per 30 minutes (admin-editable); never on app launch, never on
     safety screens; AdMob-policy-safe (natural transition, clear close button).
   - SAVE RULE: free users can NEVER get the result without watching the ads. Save, Share,
     Set-as-wallpaper, Copy, Open-in-another-app — EVERY way the image leaves the studio requires
     the rewarded ads first. Preview is reduced-size with a visible watermark; block screenshots /
     screen recording on the preview screen for free users (Android FLAG_SECURE) with a small honest
     note. If the ad fails to load (no fill/offline): try again or use credits — never a free bypass.
     Test every exit path.
   - ENHANCE: preview generated ON-DEVICE (no server cost); full-HD result = 2 rewarded ads. Cloud
     enhance only for heavy jobs or weak phones: ads needed = provider cost ÷ (70% of real ad value),
     taken BEFORE cloud work; if more than 3 ads would be needed → credits or Premium instead.
   - PROMPT EDIT / GENERATE: cost is incurred at generation, so ads/credits are taken BEFORE
     generating. Free users: 1 ad-funded trial per day (Profit Guard decides how many ads cover the
     real cost); beyond that credits or Premium.
   - Free users' saved images carry a small "Edited with Assisto" corner mark (free marketing);
     Premium/Business images are clean.
   - Owner dashboard: Photo Studio ad revenue vs cost, per day and per feature.

5. SAFETY: refuse sexual/undressing edits, putting a real person into a fake or compromising scene,
   and any editing of ID cards, certificates, documents' text, money or official seals (fraud);
   extra caution with children's photos; consent reminder when editing other people's photos; mark
   AI-edited images in metadata.

Ship with the 3 Bangla lines and before/after examples in the gallery.
