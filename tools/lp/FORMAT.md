# Language Partner content bundle format — `assisto.lp.bundle/1`

> বাংলায় এক লাইনে: প্রতিটি IELTS মক টেস্ট একটা JSON ফাইল (`tools/lp/content/ielts/<id>.json`)। CI-তে স্বয়ংক্রিয় চেক পাস করলে সেটা `ai-checked` হয়; মানুষ (Owner Admin) অনুমোদন দিলে `human-approved`। অডিও কখনো git-এ থাকে না — CI artifact হিসেবে তৈরি হয়।

Owner: **lpcontent** agent (content + pipeline). Consumer: **lpcore** (DB model, review queue,
signed media). Until `owner_actions/LANGUAGE_PARTNER_API.md` exists, THIS file is the contract.
Everything here is plain JSON, original, licence-clean, no secrets.

## 1. Files

| Path | What |
|---|---|
| `tools/lp/content/ielts/<bundle_id>.json` | one full mock test (all 4 sections) |
| `tools/lp/content/ielts/band_tables.json` | public raw-score → band tables (Listening, Academic Reading, GT Reading) with source |
| `tools/lp/fingerprints/known_hashes.json` | hashed 8-word shingles of known published texts (copyright guard; no text stored) |
| `tools/lp/blueprints/ielts_plan.json` | generated plan for mocks 004–200 (topics, accents, question-type mix) |
| CI artifact `lp-check-<run>` → `index.json` | every bundle with check result, `status`, `content_sha256` — **lpcore imports this** |
| CI artifact `lp-audio-<run>` → `audio/*.mp3` + `audio_manifest.json` | Listening audio (never in git) |
| CI artifact `lp-check-<run>` → `visuals/*.svg` | rendered Writing Task 1 charts / Listening maps |

## 2. Bundle (top level)

```json
{
  "format": "assisto.lp.bundle/1",
  "bundle_id": "ielts-ac-001",          // ^ielts-(ac|gt)-\d{3}$ ; equals file name
  "exam": "ielts",
  "module": "academic",                 // "academic" | "general"
  "version": 1,                         // bump on any content change
  "status": "draft",                    // in git always "draft"; CI index promotes to "ai-checked"
  "title": {"en": "IELTS Academic Practice Test 1", "bn": "IELTS অ্যাকাডেমিক প্র্যাকটিস টেস্ট ১"},
  "practice_label": {"en": "Practice test written by Assisto. Not an official IELTS paper.",
                     "bn": "Assisto-র নিজের লেখা প্র্যাকটিস টেস্ট। এটি অফিসিয়াল IELTS প্রশ্ন নয়।"},
  "authoring": {"source": "original", "author": "assisto-lpcontent", "created": "2026-11-09",
                "notes": "…"},
  "listening": {…}, "reading": {…}, "writing": {…}, "speaking": {…}
}
```

Status lifecycle (lpcore owns the DB field): `draft` (in git) → `ai-checked` (all automatic checks
in `lpcheck.py` pass, set in CI `index.json`) → `human-approved` (Owner Admin review queue only).
Anything not `human-approved` is shown with a **beta** label.

## 3. Questions — common rules

* Numbers `n` are 1–40 per section (Listening 1–40, Reading 1–40), contiguous, each exactly once.
* Questions sit in **groups** (one instruction block). Group fields:

```json
{"range": [1, 6], "type": "form_completion",
 "instructions": "Complete the form below. Write ONE WORD AND/OR A NUMBER for each answer.",
 "word_limit": {"max_words": 1, "numbers": true},   // completion types only
 "title": "Booking form",                           // optional heading shown above the items
 "options": [{"key": "A", "text": "…"}],            // option types only
 "options_reusable": false,                         // matching: may a letter be used twice?
 "visual": {…},                                     // map / plan / diagram / chart spec (§7)
 "questions": [ … ]}
```

* Question fields:

```json
{"n": 3, "prompt": "Day of first lesson: {gap}",   // {gap} marks the blank (completion types)
 "answer": "Tuesday",                              // canonical key
 "accept": ["Tues"],                               // other strings that are also correct (optional)
 "evidence": "the first one is on Tuesday",        // verbatim quote from script/passage (see below)
 "rationale": "…",                                 // required for NOT GIVEN; optional otherwise
 "skill": "detail",                                // weak-area tag (§3.1)
 "explain_en": "…", "explain_bn": "…"}            // shown after marking
```

* **Marking** (lpcore must implement exactly this): compare after normalising both sides —
  lowercase, trim, curly quotes → straight, collapse internal whitespace, treat `-` and space as
  equal, drop a final full stop. Correct if it equals `answer` or any `accept` entry. Spelling
  must be exact (IELTS rule) — British and American spellings are listed in `accept` explicitly.
  Option questions: compare the letter only. `mcq_multi`: see §4.
* `evidence` must be found in the section text (Listening: the part's script; Reading: the passage)
  after normalisation (lowercase, all non-alphanumerics → single space). Required for every
  question except `NOT GIVEN` answers, which need `rationale`.

### 3.1 `skill` tags (for weak-area practice)
`detail`, `number`, `spelling`, `paraphrase`, `gist`, `inference`, `opinion`, `main_idea`,
`map_direction`, `matching_info`, `vocabulary`, `writer_view`, `signpost`.

## 4. Question group `type` values

| type | where | answer format |
|---|---|---|
| `form_completion`, `note_completion`, `table_completion`, `flow_chart_completion`, `sentence_completion`, `summary_completion`, `short_answer`, `diagram_label` | L + R | free text within `word_limit` |
| `summary_completion_box` | R (+L) | letter from `options` (word box) |
| `mcq_single` | L + R | one letter (`options` A–C in Listening, A–D in Reading) |
| `mcq_multi` | L + R | group has `choose` (2 or 3) and `answers` (set of letters); each question in the range scores one distinct letter from the set, **any order**; questions carry no `answer` |
| `matching` | L + R | letter from group `options` (features / people / places) |
| `map_labelling` | L | letter from `options`; `visual` is a map/plan (§7) |
| `matching_headings` | R | roman numeral key from `options` (i, ii, …); prompt = "Paragraph B" |
| `matching_information` | R | paragraph letter; `options_reusable` normally true |
| `matching_sentence_endings` | R | letter from `options` |
| `tfng` | R | `TRUE` / `FALSE` / `NOT GIVEN` |
| `ynng` | R | `YES` / `NO` / `NOT GIVEN` |

`word_limit`: `{"max_words": N, "numbers": true|false}` — "ONE WORD ONLY" = `{1,false}`, "ONE WORD
AND/OR A NUMBER" = `{1,true}`, "NO MORE THAN TWO WORDS AND/OR A NUMBER" = `{2,true}`, etc. The
instructions text must state the same limit (validator checks). A number written in digits
(`45`, `7.30`, `£45`, `2,500`) counts as one number, not a word.

## 5. Sections

### 5.1 Listening (`"listening"`)
```json
{"minutes": 30, "check_s": 30,
 "parts": [
  {"part": 1, "context": "everyday_dialogue",      // everyday_dialogue | everyday_monologue | academic_discussion | academic_lecture
   "intro": "You will hear a woman phoning a community sports centre to ask about swimming lessons.",
   "speakers": {"A": {"name": "Receptionist", "gender": "M", "accent": "GB", "role": "centre receptionist"},
                "B": {"name": "Ms Rahman", "gender": "F", "accent": "AU", "role": "caller"}},
   "segments": [
     {"questions": [1, 6], "preview_s": 30,
      "turns": [{"spk": "A", "text": "Good morning, …"}, {"pause": 1.5}, {"spk": "B", "text": "…"}]},
     {"questions": [7, 10], "preview_s": 30, "turns": [ … ]}],
   "groups": [ … ]}]}
```
* 4 parts × 10 questions. Part 1 = two people, everyday; Part 2 = one speaker, everyday;
  Part 3 = 2–4 people, education/training; Part 4 = one speaker, academic lecture
  (Part 4 has one segment, no mid-part pause, like the real exam).
* `accent` ∈ `GB`, `US`, `AU`; `gender` ∈ `F`, `M`. At most ONE `AU` speaker per part (only one
  licence-clean Australian voice exists — see `tools/lp/tts/VOICES.md`).
* The narrator lines ("Part 1. You will hear… You now have some time to look at questions 1 to 6…",
  the preview silences, the check time) are generated by `tools/lp/tts/plan.py` from this structure
  — authors never write them.
* `{"pause": s}` inserts a natural silence (0.3–4 s). Spelling of names is written as in speech
  ("That's H-A-L-L-O-R-A-N").

### 5.2 Reading (`"reading"`)
```json
{"minutes": 60,
 "parts": [{"part": 1,
   "texts": [{"title": "…", "subtitle": "…",
              "paragraphs": [{"label": "A", "text": "…"}, …]}],   // label "" when unlabelled
   "groups": [ … ]}]}
```
* 3 parts, 40 questions. Academic: one long text per part (≈700–1000 words), rising difficulty.
  General Training: Part 1 = 2–3 short everyday texts, Part 2 = 2 work-related texts,
  Part 3 = one longer general-interest text.

### 5.3 Writing (`"writing"`)
```json
{"minutes": 60,
 "tasks": [
  {"task": 1, "minutes": 20, "min_words": 150, "kind": "chart",   // chart | letter
   "prompt": "The graph below shows … Summarise the information by selecting and reporting the main features, and make comparisons where relevant.",
   "visual": {…},                     // §7 (Academic only)
   "letter": {"tone": "formal", "bullets": ["…","…","…"], "opening": "Dear Sir or Madam,"},  // GT only
   "key_features": ["…"],             // what a Band 7+ answer must mention (for the AI scorer)
   "model_answer": {"band_estimate": "8", "text": "…"}},
  {"task": 2, "minutes": 40, "min_words": 250, "kind": "essay",
   "essay_type": "opinion",           // opinion | discussion | problem_solution | advantages | two_part
   "prompt": "…", "key_features": ["…"], "model_answer": {…}}]}
```
The AI scorer (lpcore, Haiku) uses the public band descriptors (Task 1: TA, CC, LR, GRA;
Task 2: TR, CC, LR, GRA); `key_features` and `model_answer` are reference material only.

### 5.4 Speaking (`"speaking"`)
```json
{"minutes": 14,
 "part1": [{"topic": "Your hometown", "questions": ["…", "…", "…", "…"]}, …],   // 3 topics
 "part2": {"cue_card": {"topic": "Describe a time when …", "bullets": ["…","…","…"], "final": "and explain …"},
           "prep_s": 60, "talk_s": 120, "follow_up": ["…"]},
 "part3": [{"theme": "…", "questions": ["…","…","…"]}, …]}                        // 2 themes
```

## 6. Band tables (`band_tables.json`)
Raw score (0–40) → band for `listening`, `reading_academic`, `reading_general`. The official
public page gives anchor points only; the full table interpolates between them and labels every
score a **practice estimate** (never official). See the file's `source` block.

## 7. Visual specs (`visual`)
Rendered to SVG by `tools/lp/render_visuals.py` (CI artifact); the app may render natively.
* `{"kind": "line"|"bar", "title", "x_label", "y_label", "unit", "categories": [...],
   "series": [{"name", "values": [...]}]}`
* `{"kind": "pie", "title", "charts": [{"label", "slices": [{"name", "value"}]}]}`
* `{"kind": "table", "title", "columns": [...], "rows": [[...]]}`
* `{"kind": "process", "title", "steps": ["…"]}`
* `{"kind": "map", "title", "width": 100, "height": 70, "areas": [{"name","x","y","w","h"}],
   "labels": [{"key": "A", "x", "y"}], "compass": true}` — Listening map/plan labelling, or
  Academic Task 1 map (`"maps": [{…before…}, {…after…}]`).

## 8. Checks (`tools/lp/lpcheck.py`, CI workflow `lp-content.yml`)
Errors block `ai-checked`; warnings are listed for the human reviewer.
1. **format** — schema, numbering 1–40, group ranges, 10 per Listening part, types, required fields.
2. **answer uniqueness** — option answers exist; one key per question; `mcq_multi` set size =
   `choose`; non-reusable matching letters distinct; completion answers distinct within a group,
   present in `evidence`, evidence found in the text, answer not already printed in the prompt;
   TRUE/FALSE/NOT GIVEN mix not degenerate.
3. **word limits** — every `answer`/`accept` fits `word_limit`; instructions state the same limit.
4. **timing** — Listening script length per part (spoken at ≈150 wpm) and total audio length incl.
   previews; Reading word counts per part/total; Writing 20/40 min, 150/250 words; Speaking times.
5. **level** — Flesch Reading Ease, sentence length, lexical density per part; Academic passages
   must get harder from Part 1 → Part 3 (warning).
6. **duplicates** — 8-word shingles across all bundles (Jaccard + any 12-word overlap = error),
   repeated prompts/topics.
7. **copyright** — banned markers (publisher names, "©", "Cambridge IELTS", "UCLES"), and every
   8-word shingle hashed against `fingerprints/known_hashes.json` (add texts with
   `fingerprint_add.py`; only hashes are stored).
8. **bilingual** — `title`, `practice_label` have `en` + `bn`; every `explain_bn` is Bangla script.

## 9. RESUME (paused 9 Nov 21:55 — owner: LP V2 is backlog)
Done: this format + `lpcheck.py` (stdlib validator, not yet run in CI). lpcore's import contract is
`owner_actions/LANGUAGE_PARTNER_API.md` §6 (`bundle.json` {schema:1, bundle, source, items[]} + `audio/` +
`img/`; answers as lists; `tag` = our `skill`; accent uk|au|us). TODO: `export_bundle.py` (this format → §6),
mocks ielts-ac-001/002 + gt-001 (forks may have left partial ac-002/gt-001 drafts, uncommitted), fingerprints +
`fingerprint_add.py`, `render_visuals.py` (SVG→PNG via rsvg-convert), `band_tables.json` (ielts.org
"IELTS scoring in detail" anchors: L 16/23/30/35 → 5/6/7/8; AR 15/23/30/35; GT-R 15/23/30/35 → 4/5/6/7;
rest interpolated = practice estimate), TTS in CI: Kokoro-82M 0.9.4 Apache-2.0 (GB bf_emma/bm_george…, US
af_heart/am_michael…) + MeloTTS EN-AU (MIT, commit 209145371cff) for Australian (Piper vctk/libritts excluded:
lessac non-commercial lineage, see .phaseB/MODEL_LICENSES.md), workflow `lp-content.yml`, unit tests.

## 10. Stage 2 — going-abroad tracks (`assisto.lp.track/1`) — owner: **lpstage2**

> বাংলায়: জাপানি (JLPT N5, JFT-Basic), কোরিয়ান (EPS-TOPIK), জার্মান (A1 ভিসা লেভেল) — বাংলা থেকে শেখানো।
> প্রতি ট্র্যাকে সিলেবাস, সপ্তাহ ১–৪-এর পাঠ, আর আসল পরীক্ষার ফরম্যাটে ২টি প্র্যাকটিস টেস্ট। সব Assisto-র নিজের লেখা।
> প্রতিটি স্কোর "প্র্যাকটিস স্কোর", অফিসিয়াল ফল নয়।

Validator: `tools/lp/lpcheck_tracks.py` (stdlib; CI `lp-content.yml`). Export to lpcore §6:
`tools/lp/export_tracks.py <out_dir>` → `bundle.json` (ITEM kinds `syllabus`, `lesson`, `mock`; see 10.6).
TTS job list: `tools/lp/tts/plan_tracks.py` + voices in `tools/lp/tts/VOICES_TRACKS.json`. No audio in git.

### 10.1 Files (`tools/lp/content/<lang>/`, lang ∈ `ja`, `ko`, `de`)
| File | `format` | What |
|---|---|---|
| `syllabus-<track>.json` | `assisto.lp.syllabus/1` | level syllabus in Bangla + exam format + weekly plan + Probashi link |
| `lessons-<lang>-w<NN>.json` | `assisto.lp.lessons/1` | one week = 5 lessons (shared by tracks of the same language) |
| `<track-id>-<NNN>.json` | `assisto.lp.test/1` | one full practice test in the real exam's public format |

Tracks (`track`): `jlpt_n5`, `jft_basic` (lang `ja`), `eps_topik` (`ko`), `de_a1` (`de`).
Test ids: `jlpt-n5-001`, `jft-basic-001`, `eps-topik-001`, `de-a1-001` (= file name).

### 10.2 Common fields
* Every top-level file: `format`, `lang`, `version` (int, bump on change), `status` (`"draft"` in git; CI
  index → `ai-checked`; Owner Admin → `human-approved`; not human-approved = **beta**), `authoring`
  `{source:"original", author:"assisto-lpstage2", created, format_source}` — `format_source` names the
  PUBLIC exam-format description that the structure follows (never a textbook or past paper).
* `title` and `practice_label` = `{en, bn}`. The label says practice / not official in both languages.
* Target-language text is `target` (Japanese in kanji+kana, Korean in hangul, German).
  `kana` (ja: full reading in hiragana/katakana), `roman` (ja Hepburn, ko Revised Romanization; de omitted),
  `bn` = Bangla meaning/explanation (Bangla script), `en` = optional English bridge only where useful.
* LISTENING SCRIPT (`script`) — read by TTS, never shown before marking:
  `{"speakers": {"A": {"gender": "F"|"M", "role": "shop clerk"}}, "turns": [{"spk":"A","text":"…"}, {"pause":1.0}], "repeat": 1|2}`
  `text` is in the target language only (no romanization). `repeat` = times played (exam rule).

### 10.3 Syllabus (`syllabus-<track>.json`)
```json
{"format":"assisto.lp.syllabus/1","lang":"ja","track":"jlpt_n5","exam":"JLPT","level":"N5","version":1,"status":"draft",
 "title":{"en":"Japanese for JLPT N5","bn":"JLPT N5-এর জন্য জাপানি"}, "practice_label":{…}, "authoring":{…},
 "summary_bn":"…", "who_for_bn":"…", "can_do_bn":["…"],
 "exam_format":{"total_minutes":90,"sections":[{"id":"vocab","title":{"en","bn"},"minutes":20,"questions":21}],
                "scoring_bn":"…","official_info_bn":"…"},
 "weeks":[{"week":1,"goal_bn":"…","lessons":["ja-w01-l1", …]}, {"week":5,"goal_bn":"…","lessons":[],"planned":true}],
 "probashi":{"country":"JP","work_path_lang":"ja","note_bn":"…"}}
```
`weeks` 1–4 must list existing lesson ids; later weeks may be `planned` (goal only).
`probashi.country` ∈ `JP`, `KR`, `DE`, `ME` (Middle East); `work_path_lang` = the existing
`backend/core/data/langpacks/<lang>.json` pack whose `work_path` the Probashi tile already opens (null if none).

### 10.4 Lessons (`lessons-<lang>-w<NN>.json`)
```json
{"format":"assisto.lp.lessons/1","lang":"ko","week":1,"version":1,"status":"draft","tracks":["eps_topik"],
 "title":{…},"practice_label":{…},"authoring":{…},
 "lessons":[{"id":"ko-w01-l1","day":1,"minutes":20,"title":{"en","bn"},"goal_bn":"…",
   "vocab":[{"target":"사장님","roman":"sajangnim","bn":"মালিক/বস","pos":"noun",
             "example":{"target":"사장님, 안녕하세요?","roman":"sajangnim, annyeonghaseyo?","bn":"বস, আসসালামু আলাইকুম/শুভ দিন।"}}],
   "grammar":[{"pattern":"N은/는 N이에요/예요","explain_bn":"…","examples":[{"target","roman","bn"}]}],
   "practice":{
     "listening":[{"id":"ko-w01-l1-p1","script":{…},"prompt_bn":"…","options":["…","…","…","…"],"answer":"B","explain_bn":"…","skill":"…"}],
     "reading":[{"id":"…","passage":"…","prompt_bn":"…","options":[…],"answer":"A","explain_bn":"…","skill":"…"}],
     "writing":[{"id":"…","prompt_bn":"…","model":{"target","roman","bn"},"check":"ai"|"self"}],
     "speaking":[{"id":"…","prompt_bn":"…","model":{"target","roman","bn"}}]}}]}
```
* ≥6 vocab, ≥1 grammar point, ≥1 item in each of the 4 practice skills per lesson. ja vocab also has `kana`.
* `options` are target-language (or Bangla when the question tests meaning); `answer` = letter A–D.
* `skill` ∈ `vocab`, `kanji`, `grammar`, `expression`, `detail`, `gist`, `info_search`, `response`,
  `number`, `time`, `place`, `safety`, `workplace`, `culture`, `spelling`, `form`, `message`, `speaking`.

### 10.5 Practice test (`<track-id>-<NNN>.json`)
```json
{"format":"assisto.lp.test/1","bundle_id":"eps-topik-001","lang":"ko","track":"eps_topik","exam":"EPS-TOPIK",
 "version":1,"status":"draft","title":{…},"practice_label":{…},"authoring":{…},
 "scoring":{"max":200,"per_question":4,"pass_hint_bn":"…","note_bn":"প্র্যাকটিস স্কোর — অফিসিয়াল ফল নয়"},
 "sections":[{"id":"reading","kind":"reading","title":{"en","bn"},"minutes":40,
   "parts":[{"part":"r1","type":"vocab_choice","instructions":{"target":"…","bn":"…"},
     "passage":"…",                                    // optional shared text for the part
     "questions":[{"n":1,"prompt":"…","options":["…","…","…","…"],"answer":"C","explain_bn":"…","skill":"vocab",
                   "script":{…},"passage":"…"}]}]}]}  // script: listening only (required there)
```
* `n` runs 1..N contiguously across the WHOLE test (marking sheet numbering); each section's count,
  minutes and option count must match the blueprint in `lpcheck_tracks.py` (`BLUEPRINTS`, built from
  the public format pages: jlpt.jp test-section summary, Japan Foundation JFT-Basic overview, HRD Korea
  EPS-TOPIK overview, public Start Deutsch 1 format description).
* Non-auto-marked parts (`kind` `writing`/`speaking`, e.g. German A1 Schreiben/Sprechen): `tasks`
  `[{"id","prompt":{"target","bn"},"points":…, "model":{"target","bn"}, "fields":[{"label","answer"}]?}]` —
  `fields` = auto-marked form gaps; free text is scored by the AI scorer (lpcore) or self-checked.
* Picture questions of the real exams are written as text options (no images in stage 2).

### 10.6 Export (lpcore §6 ITEMs)
`syllabus` → `{"kind":"syllabus","key":"syl-<track>","track":<track>,"level":<level>,"data":<file>}`;
each lesson → `{"kind":"lesson","key":<lesson id>,"track":<first track>,"level":<level>,"data":<lesson + lang, week, tracks>}`;
each test → `{"kind":"mock","key":<bundle_id>,"track":<track>,"level":<level>,"data":{title_en,title_bn,exam,lang,
scoring, sections}}` (questions keep `answer` + `explain_bn`; lpcore strips them before sending to the phone,
same rule as IELTS). `status` comes from the CI index. **lpcore TODO**: accept kinds `syllabus`/`lesson` and
tracks `jlpt_n5|jft_basic|eps_topik|de_a1`; mock marking = letter compare; sections without `questions` are AI/self scored.

## 11. Stage 3 — Chinese, French, Arabic (`assisto.lp.track/1`, same files as §10) — owner: **lpstage3**

> বাংলায়: চাইনিজ (HSK ১), ফরাসি (A1, DELF-A1 ধাঁচ), মধ্যপ্রাচ্যে কাজের আরবি (A1) — বাংলা থেকে শেখানো।
> সব Assisto-র নিজের লেখা; প্রতিটি স্কোর "প্র্যাকটিস স্কোর", অফিসিয়াল ফল নয়। আইটেম স্ট্যাটাস draft → ai-checked, বেটা লেবেল।

Same file kinds, fields and export as §10 (§10.1–10.6). Differences:

| lang | track | level | test id | sections (blueprint in `lpcheck_tracks.py`) |
|---|---|---|---|---|
| `zh` | `hsk1` | `HSK1` | `hsk1-NNN` | `listening` 15 min (picture_judge 5×2 opt, picture_choice 5×3, dialogue_picture 5×6, short_question 5×3; heard twice) · `reading` 17 min (picture_judge 5×2, picture_match 5×6, qa_match 5×6, word_bank 5×6) — 40 items, 200 points (5 each), 120 = pass hint |
| `fr` | `fr_a1` | `A1` | `fr-a1-NNN` | `oral` 20 min (ex1–ex3 4×3 opt, ex4 5×6; heard twice) · `ecrit` 30 min (ex1–ex3 4×3, ex4 5×3) · `production_ecrite` 30 min (2 tasks: form + message) · `production_orale` 17 min (3 tasks: 10 min prep + 5–7 min) — 4×25 = 100 |
| `ar` | `ar_work` | `A1` | `ar-work-NNN` | `listening` 20 min (phrase 6×4, dialogue 8×4, instruction 6×4; heard twice) · `reading` 25 min (letters 6×4, signs 6×4, messages 8×4) · `writing` 15 min (2 tasks) · `speaking` 10 min (3 tasks) — listening 30 + reading 30 + writing 20 + speaking 20 = 100 |

* **Options A–F**: `LETTERS` is now `ABCDEF`. Matching parts (HSK dialogue_picture / picture_match / qa_match /
  word_bank, DELF ex4 oral) give every question the SAME shared bank of 6 options; each answer letter is used
  at most once per part (one bank entry is an unused distractor). Pictures of the real exam are written as
  Bangla picture descriptions (`"ছবি: …"`) or as target-language words.
* **Chinese (`zh`)** — simplified characters only (traditional forms are an error). `target` = hanzi only (no Latin).
  `roman` = Hanyu Pinyin with tone marks (ā á ǎ à; neutral tone unmarked; citation tones, 一/不 may show
  their tone change) on every vocab, vocab example, grammar example and writing/speaking model.
  Vocab also has `tones`: list of 0–4 per character (0 = neutral) that must equal the pinyin's tone marks.
  Tests (HSK 1 prints pinyin): every Chinese `prompt` / `passage` has `prompt_roman` / `passage_roman`, and
  questions with Chinese options have `options_roman` (one per option, Bangla options → `""`).
  Lessons: same `_roman` keys on reading practice. Listening `script` text is hanzi only.
* **French (`fr`)** — `target` in French; no `roman`. Optional `bn_pron` (Bangla-script pronunciation help).
  Free-text writing tasks in tests carry `min_words`/`max_words` (DELF A1 message: about 40–50 words) and the
  `model` answer must fit them; form tasks use `fields`.
* **Arabic (`ar`)** — `target` in Arabic script (harakat welcome on new words), right-to-left, no Latin inside.
  `roman` = simple Latin transliteration (required where §10 asks `roman` for ja/ko, plus grammar examples
  and models). Vocab also has `bn_pron` (Bangla-script pronunciation, e.g. "শুকরান") and `register` ∈
  `gulf` (spoken Gulf: Saudi/UAE/Qatar/Kuwait/Oman/Bahrain), `msa` (written/formal: signs, forms, contracts)
  or `both`. Writing tasks carry `min_words`/`max_words`. Probashi: `country: "ME"`, `work_path_lang: null`
  (Probashi's "Learn for work" tile opens Arabic for Gulf time zones; no langpack `work_path` yet).
* Word limits (any lang): a writing item may carry `min_words`/`max_words` (`max_chars` for zh); the model must fit.
* `probashi.country` may also be `CN` or `FR` (no Probashi work path: `work_path_lang: null`, honest note).
* TTS: `tools/lp/tts/VOICES_TRACKS.json` — zh 4 Kokoro voices; fr Kokoro ff_siwis (+ pitch-lowered male);
  ar **blocked** (no licence-cleared natural voice; app uses the phone's own TTS). Licence rows:
  `.phaseB/MODEL_LICENSES.md` "Language Partner stage 3 TTS voices".
* **lpcore**: accept tracks `hsk1|fr_a1|ar_work`, levels `HSK1|A1`, answer letters A–F, and the extra keys
  `prompt_roman`, `passage_roman`, `options_roman`, `tones`, `bn_pron`, `register`, `min_words`, `max_words`,
  `max_chars` (display only; strip `answer`/`explain_bn` before sending to the phone as for §10).
