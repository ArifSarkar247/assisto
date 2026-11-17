# Language Partner V2 — API contract (lpcore backbone)

Owner: lpcore. Consumers: lpapp (Flutter screens), lpcontent (content bundles + TTS audio).
Base: `/api/v1/` + paths below. All JSON, JWT auth like every other app endpoint.
Flag: `language_packs` (the existing Language Partner flag; old `/learn/*` and `/ielts/*` stay until lpapp swaps).
Premium for LP = plans premium, premium_pro, founder, business (`lp_service.PREMIUM_PLANS`).
Every score in every response carries `practice_label: {en, bn}` = "Practice score — not an official
IELTS result" / "অনুশীলনের স্কোর — অফিসিয়াল IELTS ফল নয়". The app shows it under every band.

Errors: `{ok:false, reason}` — `feature_off` (403), `premium` (402: needs Premium),
`week_used` (402: free weekly section used; `next_free_at` ISO), `not_found` (404), `bad_*` (400).

## 1. Mocks (A)
- `GET /lp/mocks?kind=academic|general` ->
  `{mocks:[{id, title_en, title_bn, kind, beta, sections:["listening","reading","writing","speaking"]}],
    free_sections_left_week, next_free_at, premium}`
  Only items with status ai_checked or human_approved are listed; `beta` = not human-approved.
- `GET /lp/mocks/<id>` (Premium: whole mock) or `GET /lp/mocks/<id>?section=reading` (Free: one section;
  the first open of a NEW mock section in a rolling 7 days uses the weekly slot; re-opening the same one is free) ->
  ```
  {id, kind, beta, version,
   listening:{duration_sec, parts:[{n, audio_url, questions:[Q]}]},
   reading:{duration_sec, passages:[{n, title, text, questions:[Q]}]},
   writing:{duration_sec, tasks:[{n, prompt, min_words, image_url?}]},
   speaking:{parts:[{n:1, questions:[str]}, {n:2, cue_card, prep_sec:60, talk_sec:120}, {n:3, questions:[str]}]}}
  ```
  Only the requested section is present for a section request. `audio_url`/`image_url` are signed media links (1-2 h).
- `Q = {n, type: mcq|mcq_multi|tfng|ynng|gap|matching|map|short, prompt, options?, max_words?, group?}`.
  Answer keys, explanations and listening transcripts never leave the server before marking.
- `POST /lp/mocks/<id>/mark {section:"listening"|"reading", answers:{"1":"text", ...}}` ->
  `{raw, total, band, attempt_id, items:[{n, your, key, correct, mistake, explain_en, explain_bn}], weak:[tag]}`
  `mistake` ∈ `spelling|plural|word_limit|tfng|map|matching|other|null`. Band = public raw->band table
  (Listening; Academic Reading; General Training Reading).
- `POST /lp/mocks/<id>/finish {bands:{listening, reading, writing, speaking}, weak:[tag]}` ->
  `{ai_state, overall, comment_en, comment_bn, weak_areas:[{tag, title_en, title_bn}], result_id, certificate_url}`
  The phone may compute overall itself; the server recomputes (IELTS rounding: .25 -> .5, .75 -> next whole).
  Stage 1: the comment is rule-based and free (`ai_state:"rules"`), built from the four bands.
- `POST /lp/weak/practice {tags:[tag], n?:10}` -> `{items:[Q + {answer_hidden:true}], tags}`;
  mark them with `POST /lp/practice/mark {answers:{qid:text}}` -> same item shape as mark.

## 2. AI scoring (A + B)
- `POST /lp/score/writing {mock_id?, task:1|2, variant:"academic"|"general", prompt, text, level?:"normal"|"best"}`
- `POST /lp/score/speaking {mock_id?, part:1|2|3, prompt, transcript, seconds, confidence?, level?}`
- Both -> `{ai_state, band, criteria:{TA|TR, CC, LR, GRA} | {FC, LR, GRA, P}, criteria_notes:{key:{en,bn}},
  corrected, mistakes:[{wrong, right, type, en, bn}], credits_used, level, practice_label, attempt_id}`
- `ai_state`: `used` | `no_key` | `credits` (not enough credits; `credits_needed`) | `premium` (Free plan) |
  `user_limit` (40 scores / 24 h) | `busy` | `cut`
  (answer hit the length limit — refunded, try again) | `unreadable` (refunded). Credits are charged ONLY when
  `ai_state == "used"`. `GET /lp/score/price` -> `{normal, best}` credits per score.
- Normal = Claude Haiku; Best = Claude Sonnet (Premium + credits). Prompts stay far under 90K tokens.

## 3. Cambridge companion (B) — NO Cambridge content ever stored
- `GET /lp/companion/books` -> `{books:[10..20], tests:[1,2,3,4], sections:{listening:{duration_sec:1800,
  questions:40}, reading:{duration_sec:3600, questions:40}}, no_content_line:{en,bn}}`
- `POST /lp/companion/mark {book, test, section, variant:"academic"|"general", answers:{"1":"..."}, key:{"1":"a/b"}}`
  -> `{raw, total, band, items:[{n, your, key, correct, mistake}], mistake_counts:{type:n}, sheet_id}`.
  The key is the one the USER typed from his own book (`/` separates accepted alternatives). Each answer/key
  cell is max 40 characters; anything longer (a pasted passage/question) is rejected `bad_cell`.
- `GET /lp/companion/sheets` -> the user's own past sheets (answers + typed key + score), newest first.

## 4. Life English + vocabulary content (C, D)
- `GET /lp/content/version` -> `{life, vocab, mocks}` (ints; bump when approved content changes).
- `GET /lp/content/life` / `GET /lp/content/vocab` -> `{version, items:[{id, beta, ...data}]}`. Until DB
  content exists the app's bundled `app/assets/lp/*.json` is the source; `lp_import --app-assets` seeds the DB from them.
- `POST /lp/life/roleplay {scenario_id, history:[{role,content}], message, lang}` ->
  `{ai_state, reply, fix:{wrong, right, why_en, why_bn}|null, ai_left_today}` (free daily quota, then credits).
- Progress stays in the generic collections `lp/days`, `lp/vocab`, `lp/results` (lpapp, no migration).

## 5. Gates (I) and certificate (H)
- `GET /lp/gates` -> `{premium, free_sections_left_week, next_free_at, full_mocks, ai_scoring, tracks, all_levels}`.
- `GET /lp/certificate/<result_id>` -> PDF "Assisto Practice Certificate" (owner's own results only), footer
  "Practice score — not an official IELTS or JLPT result". No ads anywhere in exams or certificates.

## 6. Content bundle format (lpcontent -> `manage.py lp_import <dir>`)
```
<dir>/bundle.json   {"schema":1, "bundle":"<id>", "source":"ai"|"human", "items":[ITEM...]}
<dir>/audio/*.mp3|*.ogg|*.m4a   <dir>/img/*.png|*.webp
ITEM = {"kind":"mock"|"section"|"question"|"scenario"|"vocab", "key":"ielts-ac-001", "track":"ielts_ac"|"ielts_gt"|"life"|"vocab",
        "level":"B2"|"band6"|..., "data":{...}}
mock.data   = {title_en, title_bn, listening:SECTION, reading:SECTION, writing:SECTION, speaking:SECTION}
              (inline sections are split into section items "<key>-listening" etc.)
listening   = {duration_sec:1800, parts:[{n, audio:"audio/x.mp3", accent:"uk|au|us", speakers:2, transcript, questions:[QK]}]}
reading     = {duration_sec:3600, passages:[{n, title, text, questions:[QK]}]}
writing     = {duration_sec:3600, tasks:[{n, prompt, min_words, image?:"img/x.png"}]}
speaking    = {parts:[{n:1, questions:[..]}, {n:2, cue_card, prep_sec:60, talk_sec:120}, {n:3, questions:[..]}]}
QK = Q + {answer:["main","alt"] | "B" | ["A","C"], explain_en, explain_bn, tag}
question.data = {section:"reading"|"listening", passage?, audio?, q:QK}   (weak-area pool, tag required)
scenario.data / vocab.data = the same shape as app/assets/lp/*.json entries
```
Import = upsert by (key): unchanged content -> no new version; changed -> new version, status back to draft,
automatic checks run -> `ai_checked` (all pass) or stays `draft` with the failures listed. Audio/images are
copied to private media `lp/<sha256>.<ext>` and served by signed URLs. A bundle containing Cambridge/UCLES
text or a known-text fingerprint hit is imported as `rejected` with the reason (never shown).

Automatic checks: format (fields per type, 40 L/R questions, 4 L parts, 3 R passages), answer uniqueness
(one key per single-answer question, options unique, key in options, T/F/NG valid), word limit vs key,
level (reading passage length by level), timing (L 30 min, R 60, W 60, S 11-14 min), copyright
(banned markers + known-text fingerprints), duplicates (same normalized text as another item).

## 7. Stage 2 tracks (lpstage2, tools/lp/FORMAT.md §10.6)
- Import accepts kinds `syllabus` and `lesson` and tracks `jlpt_n5`, `jft_basic`, `eps_topik`, `de_a1`,
  plus stage 3 (§11) `hsk1`, `fr_a1`, `ar_work`. Answer letters A–F (3-6 options); display-only keys
  (`prompt_roman`, `options_roman`, `tones`, `bn_pron`, `register`, `min_words`/`max_words`/`max_chars`) pass through.
- A track test is a `mock` whose `sections` is a LIST (kept inline). `GET /lp/mocks?kind=jlpt_n5` lists them;
  `GET /lp/mocks/<id>?section=<section id>` returns `{id, kind, exam, lang, scoring, sections:[...]}` with
  `answer`, `explain_*`, `script` and `skill` removed. `POST /lp/mocks/<id>/mark {section, answers}` compares
  letters -> `{raw, total, score, max, band:null, items}` (score = raw x scoring.per_question).
- `GET /lp/content/syllabus?track=X` and `GET /lp/content/lesson?track=X` (a lesson matches any of its `tracks`).

## 8. Free-tier ads (owner 10 Nov 00:35, PART B)
- `GET /lp/gates` -> `ads: {show, rewarded:{section:1, score:N|null}, interstitial:"natural_breaks",
  banner:["home","lists"], never_in:[timed_mock, listening_audio, speaking, certificate, exam_result_pdf],
  score_unlocks_left}`; Premium -> `{show:false}`.
- `POST /lp/ads/ticket {unlock:"section"|"score"}` -> `{nonce, custom_data, user_id, rewarded_unit, ads_needed}`
  (pass custom_data + user_id to AdMob SSV). ONLY Google's signed SSV callback verifies the ad. 1 verified ad
  = 1 extra mock section (rolling 7 days); N verified ads = 1 Normal AI score with 0 credits (N keeps >= 40 %
  profit on the conservative ad value; `score:null` = ads cannot pay for it, so no offer). Errors: `ads_not_live`,
  `premium_no_ads`, `not_offered`, `daily_cap`.
- A free `/lp/score/*` without an unlock answers `ai_state:"premium"` + `ads_needed`.
- lpapp credits path: the 402 `week_used` answer carries `unlock_credits` (1). `GET /lp/mocks/<id>?section=X&pay=credits`
  charges it and opens the section (402 `credits` when the balance is short). Re-opening it this week is free.


## 9. lpfinish — repo content seed + phone-TTS listening (10 Nov)
- `python manage.py lp_seed` imports `tools/lp/content/ielts/*.json` (format `assisto.lp.ielts/1`, original mocks),
  the 7 language tracks (`tools/lp/content/<lang>/`) and `app/assets/lp/*.json`; idempotent; exits non-zero if any item
  is not live (lists the check failures). Converter: `core/logic/lp_seed.py`.
- A listening part without `audio` may carry `turns` (script); `GET /lp/mocks/<id>?section=listening` then returns
  `parts[].tts = {lang: en-GB|en-US|en-AU, lines:[..], repeat}` for the phone's own voice (the app never displays it).
  Track tests: every listening question/part with a script gets `tts {lang: ja-JP|ko-KR|de-DE|zh-CN|fr-FR|ar-SA, lines, repeat}`.
  Recorded audio, when the CI TTS job ships it, replaces this automatically (`audio_url` wins).
- Track choice questions may have 2–6 options (true/false items of German A1 Hören and HSK 1 picture judge).

## 10. lpaudio — recorded IELTS listening (17 Nov)
- Audio: rendered in CI (`.github/workflows/lp-audio.yml`, Kokoro-82M v1.0, Apache-2.0 stock voices, narrator +
  one voice per speaker) -> release `lp-audio` (`<bundle>-p<n>-<plan12>.m4a`, AAC mono 40 kbit/s, faststart + manifest.json).
- Server: `manage.py lp_audio` (post-deploy; `--dir` for a local folder, `--dry-run`) downloads, checks sha256 and the
  PLAN HASH against the current script (`core/logic/lp_audio.py`), stores private media `lp/<sha>.m4a`, writes
  `lp/audio_index.json`, re-seeds the IELTS mocks; `lp_seed` keeps the audio via the index.
- `GET /lp/mocks/<id>?section=listening` -> `listening:{duration_sec, audio_ready, parts:[{n, audio_url (signed),
  duration_sec, accents:["en-GB"|"en-US"], bytes, preview_sec:30, check_sec:30|120 (last), questions:[Q]}]}`.
  **IELTS parts never carry `tts`, turns, intro, transcript or answers any more** (§9's phone-TTS is gone for IELTS;
  track tests keep §9 until their audio exists). A part without audio -> `audio_url:null`, the app shows "not ready".
