# Language pack format (Language Partner framework, p2lang, 3 Nov 2026)

> বাংলায় এক লাইনে: প্রতিটি ভাষা একটা JSON ফাইল — ফাইল যোগ করলেই অ্যাপে সেই ভাষার কার্ড চালু হয়; কোড বদলাতে হয় না। ফাইল না থাকলে কার্ডে লেখা থাকে "এই ভাষার পাঠ এখনো যোগ হয়নি" (কোনো প্রতিশ্রুতি নয়)।

**Where:** `backend/core/data/langpacks/<code>.json` — codes in owner order:
`en` English · `ko` Korean · `ja` Japanese · `ar` Arabic · `de` German · `fr` French · `es` Spanish · `zh` Chinese
(card names + exam names live in `backend/core/logic/langpacks.py` `LANGUAGES`; do not change them in a pack).

**How it is used:** `langpacks.load(code)` validates the file (`langpacks.validate`). Invalid → the card shows as not available and `core.tests_p2lang.PackFilesTests` fails with the reason. The app renders everything generically (`app/lib/screens/language_pack_screen.dart`); a pack never needs Dart code. Bangla lives only in the JSON (Dart has zero Bangla literals).

**Rules (owner):** ORIGINAL questions only — never copy official papers (Cambridge/IDP/BC, EPS-TOPIK/TOPIK, JLPT/JFT, Goethe, DELF, DELE, HSK); the validator refuses text with "copyright", "©", "official paper". Every score is an "Assisto practice estimate". Exam names are only for orientation. Every learner-facing string needs `_bn` + `_en` (strict bn/en). Listening sections need licensed `audio_url` (https) on every question — no licensed audio ⇒ no listening section.

## Top level
```json
{
  "format": 1, "lang": "ko", "version": 1,
  "stt_locale": "ko-KR",            // speech-to-text locale for voice + pronunciation
  "level_system": "TOPIK",          // shown next to the level (e.g. CEFR, TOPIK, JLPT, HSK, EPS)
  "levels": [{"id": "1", "en": "TOPIK 1 (estimate)", "bn": "TOPIK ১ (অনুমান)"}, ...],   // low → high
  "placement": {...}, "lessons": [...], "scenarios": [...], "pron": [...], "mock": [...],
  "extras": []                      // optional; "ielts" opens the IELTS module (English only)
}
```

## Question (placement + mock, auto-graded)
```json
{"id": "pl1", "type": "mcq", "skill": "grammar|vocab|reading|listening|writing|speaking",
 "level": "A1",                      // placement only; must be a levels[].id
 "text": "…", "options": ["…", "…"], "answer": 1,
 "explain_bn": "…", "explain_en": "…",
 "audio_url": "https://…"}           // listening only (licensed audio)
```
Answer keys and explanations never reach the app before grading (`public_pack` strips them).

## placement
`{"pass_pct": 60, "questions": [≥ 8 questions]}` — placed level = highest level where every level up to it reached `pass_pct`; weak areas = skills < 60 %.

## lessons (basic → advanced)
```json
{"id": "l_a1_greet", "level": "A1", "title_en": "…", "title_bn": "…",
 "items": [{"kind": "phrase|vocab|grammar|note", "target": "<target language>", "roman": "<optional romanisation>",
            "bn": "<Bangla meaning/explanation>", "en": "<English meaning/explanation>"}],
 "practice": ["<sentence to say — pronunciation check>"]}
```

## scenarios (AI voice role-play; ids fixed: airport, workplace, doctor, renting, shopping)
```json
{"id": "airport", "title_en": "…", "title_bn": "…",
 "ai_role": "<English instructions for the AI — server only>",
 "opening": "<first line in the target language>",
 "goals_en": ["…"], "goals_bn": ["…"],
 "useful": [{"target": "…", "bn": "…", "en": "…"}]}
```

## pron
`{"id": "pr_1", "text": "<target-language sentence>", "tip_bn": "…", "tip_en": "…"}` — scored on the phone by word alignment against speech-to-text (estimate).

## mock (timed test in the exam FORMAT)
```json
{"id": "eps_style_1", "title_en": "…", "title_bn": "…", "format_en": "…", "format_bn": "…",
 "minutes": 40,
 "sections": [
   {"id": "reading", "skill": "reading", "title_en": "…", "title_bn": "…", "passage": ["¶", "¶"], "questions": [...]},
   {"id": "writing", "skill": "writing", "title_en": "…", "title_bn": "…", "prompts": [{"id": "w1", "text": "…", "min_words": 150, "max_words": 300}]},
   {"id": "read_aloud", "skill": "speaking", "title_en": "…", "title_bn": "…", "read_aloud": ["sentence", "…"]}
 ],
 "bands": [{"min_pct": 0, "level": "1"}, {"min_pct": 50, "level": "2"}]}   // first band must start at 0
```
Question and prompt ids must be unique inside one mock (answers are keyed by id). Objective % → level from `bands`; weak areas = sections < 60 % + open prompts outside the word range.

## Server API (flag `language_packs`)
`GET /learn/catalog` · `GET /learn/pack/<lang>` · `POST /learn/<lang>/placement` · `POST /learn/<lang>/mock` · `POST /learn/<lang>/roleplay` · `GET /learn/results`.
Free: lessons, placement, mock, pronunciation (no limit). AI role-play: 3 free turns/day (30 on a paid plan), then credits (`ai_msg_cheap`, priced ≥ cost ÷ 0.60).

## Certificate seam (agent/learncert)
`core.logic.langpacks.course_result(lang, level, score, date)` → canonical record (validates lang/level/score/date).
`core.learn_views.results_for(user)` → the user's SERVER-GRADED results (placement + mock), newest first, each `{id, lang, level, level_system, score, date, kind, weak, estimate, label}`. Issue certificates only from these rows.

## Adding a pack — checklist
1. Write `<code>.json` (original content, bn + en everywhere).
2. Push to CI: `core.tests_p2lang.PackFilesTests` validates every file in the folder.
3. The card in the app turns on by itself (flag `language_packs` must be on).
