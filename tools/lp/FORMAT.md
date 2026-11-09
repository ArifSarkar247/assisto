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
| CI artifact `lp-check-<run>` → `index.json` | every bundle with check result, `status`, `content_sha256` |
| CI artifact `lp-audio-<run>` → `lp_bundle/` | **lpcore imports this** (`manage.py lp_import`), see §9 |
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

## 9. lpcore import (LANGUAGE_PARTNER_API.md §6)
`export_bundle.py` turns every `ai-checked` bundle into lpcore's import dir (`lp_bundle/bundle.json` with
`{"schema":1,"bundle","source":"ai","items":[mock…, question…]}` + `audio/*.mp3` + `img/*.png`):
completion answers become lists (`[answer, *accept]`), option answers stay letters, `mcq_multi` questions
carry the letter set + `choose`, `skill` → `tag`, Listening parts carry `audio`, `accent` (uk|us|au,
dominant speaker), `speakers`, `transcript`, `cues`. CI artifact `lp-audio-<run>` holds the full dir;
`lp-check-<run>` holds it without audio. Server: `manage.py lp_import <dir>`.
