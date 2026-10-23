# P4 — UNSEEN WORLD: plan (agent/p4-world)

Owner order P4: "everything in one place, Bangla, voice". Written BEFORE coding,
after a survey of what already exists (2026-10-23).

## 1. What already exists (reuse, do not duplicate)

| Area | Existing | Reuse in P4 |
|---|---|---|
| Prayer times | `core/logic/ramadan.py::prayer_times()` (local astronomical calc, Karachi/MWL angles, no key); `/ramadan/times?lat&lon` | Today card computes from the user's chosen city on the server with the same function. No key. |
| Weather | Integration slug `weather` (OpenWeatherMap, never wired); daily_brief shows an honest key-gated placeholder | NEW key-less source: MET Norway Locationforecast (CC BY 4.0, commercial OK, User-Agent + cache rules). Open-Meteo REJECTED: free API is non-commercial only (Assisto has subscriptions + ads). |
| News | Integration slug `news` (newsapi.org, never wired) | NEW: official publisher RSS (headline + feed's own snippet ≤200 chars + link). newsapi not used. |
| Currency | Probashi corner logs user-entered rates only | NEW: ExchangeRate-API open endpoint (open.er-api.com, no key, commercial conversion use allowed, attribution link required, daily). |
| Gold / fuel | none (ramadan.nisab takes a user-entered gold price) | NEW: owner-entered values in Owner Admin with audit + "updated by Assisto on <date>" + official source link (BAJUS / BPC). Hidden until first entry. |
| Sports | none | NEW, key-gated (hidden until key): API-Football (api-sports.io) + CricketData.org. |
| Web search AI | none (ai.py = LLM only, no search) | NEW integration `web_search` with 2 adapters (Brave Search API, Tavily). LLM via existing `ai.generate`. |
| Jobs | `jobs_screen.dart` + `core/logic/job_hunter.py` (tracker + curated sample, never scrapes) | Jobs hub = link-out portal cards (new) + entry to the existing Job Hunter tracker. Alerts only via a lawful API (Careerjet publisher API, key-gated). |
| Expats | `probashi_screen.dart` (remittance LOG, time-zone pair, docs checklist) | Expats hub = curated visa/remittance/rules guides (new) + entry to Probashi corner. |
| Students | `student_corner_screen.dart` (routine, CGPA), `exam_result_screen.dart` (result watcher) | Students hub = result/admission links (new) + BCS MCQ practice engine (new, original bank) + entries to both. |
| Farmers | `farmer_mode_screen.dart` (ledger, crop calendar, livestock) | Farmers hub = crop-photo diagnosis via the EXISTING chat-vision path (new `purpose=crop`) + 16123 note + entry to Farmer mode. |
| Gov services | `guide_screen.dart` + `core/logic/govt_guide.py` (11 services, verify-on-portal fees) | Gov hub reuses govt_guide records (passport, NID, birth, land, DL) + adds e-mutation, last-reviewed date, and "AI help filling forms" (explains fields, drafts text; never submits). |
| Health | `medicine_db_screen.dart` (curated SAMPLE, badged), chat-vision already removes doses not on the label + "consult a doctor" | Health hub = prescription reader via chat-vision (`purpose=rx`) + medicine price ONLY when the owner has loaded a DGDA list (else hidden). |
| Vision / OCR | `chat_vision_service.py` + `chat_vision/` Flutter (funding: pool / ads / credits, Profit Guard, never stores the photo) | Reused as-is with a `purpose` hint (crop / rx) that switches the system prompt + appends the mandatory note. Same action `chat_vision_image`. |
| Voice | `widgets/voice_input.dart` (VoiceDictation + VoiceMicButton, bn-BD), `voice/va_native.dart` `VaNative.speak` (TTS) | Every P4 input gets the mic; every answer/guide gets a "listen" button (TTS bn/en). |
| Credits | `core/billing.py` charge/guard_can, `core/logic/pricing.py` action table (admin-editable) | New action `web_answer`. AI help uses `ai.generate` (ai_msg_cheap). Photos use `chat_vision_image`. |
| Owner Admin | web owner panel `/owner/*` (Django templates, OwnerAudit) | New page `/owner/world`: data-source status + gold/fuel editor (audited). |
| Existing "Unseen Bangladesh" | travel guide (`unseen_world_screen.dart`) — different feature | Untouched. P4 hub is titled "Unseen World" / "অদেখা দুনিয়া" and links to it. |

## 2. What I build

Backend (new files unless noted):
- `core/logic/world_feeds.py` — pure: tolerant RSS parser (snippet ONLY from the feed's own `description`/`summary`, HTML stripped, ≤200 chars, never `content:encoded`), freshness filter, MET Norway + ExchangeRate-API + API-Football + CricketData parsers, city list, card ids.
- `core/logic/world_search.py` — pure: Brave + Tavily request builders/parsers, grounded prompt, citation post-processing (only valid `[n]`, sources list, "no citation → honest note"), medical/legal caution.
- `core/logic/world_content.py` — pure curated bn/en content (job portals, expat, students, farmers, gov, health), every entry with official links + `reviewed` date + "verify on the official site".
- `core/logic/world_mcq.py` — ≥60 ORIGINAL MCQs (BD GK, Bangla, English, Math) written by me + scoring.
- `core/world_service.py` — fetch (urllib, UA `AssistoBot/1.0 (+https://lifeassisto.com)`), cache rows, refresh, Today assembly, web answer (charge/refund), job alerts (1/day cap).
- `core/views_world.py` + routes block `# ---- p4-world ----` in `core/urls.py`.
- Models (one migration `0072_p4_world`): `WorldFeed` (cache + status per source), `WorldAdminValue` (gold/fuel), `WorldPrefs` (per-user card on/off, city, job types, alert state), `WorldMcqAttempt` (score history), `WorldAnswer` (web-answer cache/log).
- Integrations: `web_search`, `sports_football`, `sports_cricket`, `jobs_careerjet`.
- Pricing: action `web_answer`. `ai.generate` gains optional `charge_action=`.
- chat-vision: optional `purpose` (crop / rx).
- Commands: `world_refresh` (cron */15) and `world_job_alerts` (daily) — cron file in `deploy/p4-world/`.
- Web owner: `/owner/world`.

Flutter:
- `lib/world/world_api.dart` (abstract seam + ApiClient impl; fakes in tests/gallery).
- Screens in `lib/screens/world/`: hub, Today, Ask (web answer), Jobs, guide hub (expat/students/farmers/gov/health), MCQ practice.
- Drawer: ONE entry "Unseen World" in Daily Life. Home untouched.

## 3. Data sources, terms, cost, key

| Source | Use | Licence / terms note | Cost | Key (Integrations slug → field) |
|---|---|---|---|---|
| Prayer times (local calc) | Today | own computation | 0 | none |
| MET Norway Locationforecast 2.0 compact | weather | CC BY 4.0 (attribution shown "Weather: MET Norway"), identify via User-Agent, cache, ≤20 req/s, 4-decimal coords; commercial use not restricted by ToS | 0 | none |
| ExchangeRate-API open access (open.er-api.com/v6/latest/USD) | currency | commercial conversion display allowed, no redistribution, attribution link required, updates daily | 0 | none |
| BAJUS gold price (bajus.org) | gold | no API → owner types the published value; we show "updated by Assisto on <date>" + link | 0 | none (Owner Admin) |
| BPC fuel price (bpc.gov.bd) | fuel | no API → owner-entered + link | 0 | none (Owner Admin) |
| BBC Bangla RSS feeds.bbci.co.uk/bengali/rss.xml | bn news | publisher RSS; headline + summary + link back; no full text | 0 | none |
| Prothom Alo RSS prothomalo.com/feed/ (+ en.prothomalo.com/feed/) | bn/en news | robots allow; feed `description` is empty → headline + link only (we never use `content:encoded`) | 0 | none |
| The Daily Star RSS | en BD news | feed exists but STALE (last item Jun 2026) → shipped OFF, admin can enable | 0 | none |
| BBC World RSS feeds.bbci.co.uk/news/world/rss.xml | world news | as BBC Bangla | 0 | none |
| Al Jazeera RSS aljazeera.com/xml/rss/all.xml | world news | public RSS; robots blocks only AI-training bots (GPTBot etc.), not feed readers; we never train on it | 0 | none |
| Reuters / AP | — | no public RSS (Reuters closed 2020) → NOT used | — | — |
| TBS, VOA Bangla, Dhaka Tribune, Jugantor, Kaler Kantho | — | stale or Cloudflare-blocked → not used | — | — |
| Brave Search API | web answer | paid per request ($5/1000 Search; use results for AI answers per Brave plan terms) | ≈$0.005/search | `web_search` → provider=brave, `brave_api_key` |
| Tavily Search API | web answer | built for LLM grounding; 1,000 free credits/mo then $0.008/credit | ≈$0.008/search | `web_search` → provider=tavily, `tavily_api_key` |
| LLM (existing Anthropic key) | web answer + AI help | existing | ≈$0.003–0.006/answer (Haiku) | `anthropic` (already in Admin) |
| API-Football (api-sports.io) | football live | licensed API; free 100 req/day, paid from ~$19/mo | owner enters cost/call | `sports_football` → `api_key`, `cost_per_call_usd` |
| CricketData.org (cricapi) | cricket live | licensed API; free 100 hits/day, paid plans | owner enters cost/call | `sports_cricket` → `api_key`, `cost_per_call_usd` |
| Careerjet publisher API | job alerts | official partner API (publisher key); results link to Careerjet | free for publishers | `jobs_careerjet` → `api_key` |
| bdjobs, BPSC, Teletalk alljobs, BB e-recruitment, LinkedIn, BOESL, Chakri, Careerjet site, bangladesh.gov.bd, NGO Forum | jobs hub | link-out only; no public RSS/API found → no alerts from them (documented) | 0 | none |

Sports cost control: one shared server cache, refreshed at most every N minutes (admin `interval_min`, default 5) and only while a match is live; calls/day × cost/call shown on `/owner/world`.

## 4. Credits / Profit Guard
- `web_answer`: provider_cost $0.015 (search ≤$0.008 + Haiku ≤$0.006), credits 4 (NET floor = ceil(0.015×120/0.60)=3, margin rule ceil(1.8×1.4)=3 → 4 keeps ≥40%). Admin-editable in /owner/pricing. Charged via `ai.generate(charge_action="web_answer")` → atomic, Profit Guard, refunded if every LLM provider fails. Same question+lang within 3 h is answered from cache with no charge (no provider cost). Daily cap per user (`world.web_answers_per_day`, default 30).
- AI help in hubs: `ai.generate` tier cheap → `ai_msg_cheap`.
- Crop / prescription photos: existing `chat_vision_image` funding rails.
- Feeds: no user charge (free, cached shared data).

## 5. Safety
- Web answers: only from fetched sources, numbered citations, "Not certain — verify" for medical/legal/financial, never dosage; no source → honest "couldn't find a reliable source".
- Farmers: always "Ask your Upazila Agriculture Officer or call 16123 (Krishi Call Centre, AIS, 25 paisa/min)"; pesticide only "follow the label".
- Health: "consult a doctor/pharmacist"; doses only as printed/written (existing chat-vision filter).
- Gov forms: AI explains fields + drafts text to copy; never submits, never asks for passwords/OTP.
- Expats: official channels only, Assisto never holds money; agency licence check on BMET.

## 6. Migration
`0072_p4_world` depending on `0067_a1_key_history` (newest on origin/main at survey time). Integrator re-chains.
