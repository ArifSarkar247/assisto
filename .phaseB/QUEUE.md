# Owner work queue (newest order wins)

## MASTER ORDER 22 Oct (single source of truth; earlier orders below are history)
Rules: max parallel agents (own worktree each), heavy cmds via lock, ship each part immediately, deploy each backend after checks (standing approval), max 1 h on CI problems (gate = release cold start + backend tests + route_check; note missing proof), commit hourly, never idle, blockers in Bangla at top of STATUS, 3 Bangla lines per build.

0. [TOP PRIORITY — agents c2-calls, c3-msg, q1-seams] MY CIRCLE WhatsApp standard (owner two-phone test of build 176; spec .phaseB/MYCIRCLE2_ORDER.md on agent branches): REAL WebRTC calls (calls were a facade), call sounds generated in code + default/picked ringtones, ticks sent/delivered/seen, chat-list preview/unread, MessagingStyle notifications + inline reply + hide-content, Android Bubbles, repo-wide seam/fake-path audit. One build; ships after a two-account proof. Calls = C until a real two-device test.
1. [SHIPPED build 176 + backend deployed] My Circle like WhatsApp (add any format/phonebook/QR/link, requests, messages, voice+video calls, FCM ringing closed app) + settings-store release fix + Phone Safety spinner fix. MISSING PROOF: native tour + two-account emulator audit (hosted emulator wedges adb) — re-run when CI stable.
2. [DONE 22 Oct] Owner account: owner confirmed id 3 (Arif, 01784056199) → superuser + staff (backup first, AuditLog entry). Superusers: Owner (13) + id 3.
3. [BUILT, in builds] OTP flow (provider-agnostic, key-gated) + owner_actions/SMS_GATEWAY_NEEDS.md (Bangla). Needs SMS gateway keys.
4. [SHIPPED build 177] Voice assistant: default assistant (long-press power), optional Hey Assisto (needs Picovoice key), YouTube/YT Music, hands-free, TTS, bn/Banglish/en.
5. [LIVE 22 Oct] Web Owner Admin Panel https://api.lifeassisto.com/owner/ (migration 0051_o2; login steps in STATUS, Bangla).
6. [SHIPPED build 178: Photo Studio; home hero + image in chat merged, next] Photo Studio + home ad hero (remove suggestions, muted hero) + image in chat.
7. [vehicle OBD SHIPPED build 179; webphoto next] Vehicle app part (live map, 24h playback, engine cut-off rules, geofence/over-speed, OBD, Car Mode) — verify completeness; website passport funnel.
8. [NOT IN THIS SESSION] Remote support — owner's full spec saved in .phaseB/REMOTE_SUPPORT_SPEC.md; the first launch here was stopped by a safety system before it ran, so it must be built in a separate session.
9. [CCTV live + Shop Box mode SHIPPED build 180] [AGENT b6-antitheft, spec .phaseB/BATCH6_ORDER.md] Batch 6 native lost/stolen engine (opt-in, own phone: heartbeat, snatch, SIM/airplane/battery/shutdown guards, intruder photo, store-and-forward) + [READY cctv] CCTV live view + Android Shop Box mode.
10. Premium QA every screen >=9/10, full reality audit with real runs, owner phone checklist.
L. LAUNCH TRACK [AGENT]: Privacy Policy / Terms / Data Deletion pages on lifeassisto.com (bn+en, Play + AdMob compliant, every permission explained); app-ads.txt ready for the AdMob publisher ID; owner_actions/PLAY_STORE_PACK.md (name, short/full description bn+en, feature graphic, 8 screenshots, content rating + Data Safety, permission declarations); signed release AAB per release in CI + upload key + Play App Signing plan.
L2. [AGENT f1-founders] FOUNDING TESTERS: owner admin action grants "Founding Member" (free Premium N months, admin-editable default 12, + badge) to a pasted list of accounts (first 12–20 Play closed testers); in-app "Send feedback / report a problem" (screenshot + note) landing in the owner admin panel.
Also queued: Health Connect plugin fails to register (MainActivity must become FlutterFragmentActivity) — own native build.

## History

0. (old) Final order 21 Oct: 1 → 2 (+contract test) → 4 (FCM) → 3 (reality audit) → 5 (voice assistant) → 6 (vehicle) → 7.
1. 21-Oct NIGHT order (replaces the order above): 1 broken links + contract CI → 2 sidebar/auto voice → 2b DISCOVER MANAGER → 3 FCM + un-park workflows → 4 OTP → 5 reality audit → 6 voice assistant → 7 Photo Studio → 8 vehicle → 9 remote support → Batch 6 → CCTV live + Shop Box → Premium QA. Max 3 agents.
0a. MY CIRCLE LIKE WHATSAPP (top priority, current build): FCM + contacts + New chat / Add to My Circle / requests / no silent failures / Phone Safety Check-up loading fix; ships only after the two-account emulator proof (agent m3-circle).
0b. WEB OWNER ADMIN PANEL at https://api.lifeassisto.com/owner/ — RIGHT AFTER the My Circle build (agent o2-admin building). Owner tried the URL: Not Found (expected — not deployed yet). Superuser login + mandatory TOTP 2FA + recovery codes, HTTPS only, rate-limited, audit log; sections: Discover manager (cards, sponsors, images, schedule, audience, CTR reports, CSV/PDF), Pricing & plans & credits, Profit Guard + P&L, Ads settings (caps, hero ad, sound), Integrations/API keys, Users (search, plan, credits, block), Reports; bn + en. Needs nginx /owner/ location → :8700. When live: tell the owner in Bangla (URL + login steps, owner_actions/OWNER_ADMIN_PANEL.md).
   Decision done 21 Oct: SPONSORED cards reach every plan (always labelled), AdMob Free-only — LIVE.
1a. OWNER BUG — CONTACTS ON ASSISTO IS A FACADE (top priority right after the current build): agent c1-contacts.
   - Root causes: permission stub always true + phonebook never read (no plugin); UserPhoneHash never created; no phone normalisation (exact-string match).
   - Fix: E.164 canonical phone everywhere + data migration; UserPhoneHash on register/phone change + backfill; admin flag allow-unverified-matching (ON test, OFF at launch); contacts plugin + READ_CONTACTS + prominent disclosure (native build, needs workflow scope); WhatsApp-style On Assisto / Invite; search any format.
   - Stays C in the Reality Audit until the two-phone test passes (01865052200 searched as +880 1865-052200 / 8801865052200 / 01865052200).
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
