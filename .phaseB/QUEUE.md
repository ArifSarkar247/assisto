# Owner work queue (newest order wins)

0. (old) Final order 21 Oct: 1 → 2 (+contract test) → 4 (FCM) → 3 (reality audit) → 5 (voice assistant) → 6 (vehicle) → 7.
1. 21-Oct NIGHT order (replaces the order above): 1 broken links + contract CI → 2 sidebar/auto voice → 2b DISCOVER MANAGER → 3 FCM + un-park workflows → 4 OTP → 5 reality audit → 6 voice assistant → 7 Photo Studio → 8 vehicle → 9 remote support → Batch 6 → CCTV live + Shop Box → Premium QA. Max 3 agents.
1b. DISCOVER MANAGER + SPONSORED CARDS (owner, 21 Oct night; right after priority 2):
   - Link fix axonerp.com → https://axonerpsoftware.com: DONE in build 148.
   - Admin panel: cards CRUD + reorder + enable; image/icon; bn+en title/desc; action = in-app route (picker) or external URL; start/end datetime; audience all/Free/Premium/Business; optional min app version.
   - Types: FEATURE, OUR PRODUCT (Asalify https://asalify.com, AXON ERP https://axonerpsoftware.com, label "Our products"), SPONSORED (always labelled "Sponsored"), ADMOB slot (free only, fills when no sponsored booked).
   - Rules: Premium/Business never see SPONSORED/AdMob; never on safety screens; content safety check (no scams/gambling/adult/fake claims).
   - Sponsor reporting: impressions/clicks/CTR per card per day; CSV/PDF export; sponsor revenue per card → owner P&L dashboard.
   - App: server fetch + offline cache (last set), auto-rotate as now, tap tracking; hard-coded list only as first-run fallback.
   - Real E2E test: admin adds card → appears without update; expires on end date; audience respected. 3 Bangla lines.
2. PHOTO STUDIO — queued right AFTER the voice assistant ships (owner order 21 Oct, replaces all earlier Photo Studio messages).
   Full text of the order is in the session; key constraints:
   - One-tap on-device enhance, no API key; commercially-licensed models only (Real-ESRGAN BSD-3 ok; CodeFormer NON-commercial → never; verify GFPGAN + every weight) → .phaseB/MODEL_LICENSES.md.
   - Prompt edit/generate via switchable, key-gated cloud adapter (Gemini / OpenAI image / Replicate-class); keys + cost/image in OWNER_UNLOCK_LIST.md.
   - Face-lock compositing for scene edits; beauty retouch only within allowed list; identity guard (ArcFace-class + landmarks) on every result; original kept, undo + history.
   - Ads: entry interstitial (≤1 per 30 min, admin-editable); every export path gated by rewarded ads for free users; watermarked reduced preview + FLAG_SECURE; no free bypass on no-fill; Profit Guard makes loss-making edits impossible (tests); owner dashboard.
   - Safety refusals (sexual/undressing, fake compromising scenes, ID/document/money/seal edits), child caution, consent reminder, AI-edit metadata.
   - Ship with 3 Bangla lines + before/after gallery examples; Reality Audit A/B/C/D on emulator.
