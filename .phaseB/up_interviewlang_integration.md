# Integration — #131 Mock Interview + #132 Language-Learning Partner

Two NEW standalone, ADVANCED (SPEC v2.1 §21), KEY-GATED AI features. Both ship
a full DETERMINISTIC / MOCK layer that works with NO AI key, an honest
"rule-based / built-in — not an AI grade" marker, and a documented key-gated
seam for the one genuinely-AI capability. Nothing calls a model. No live
Asalify touched; no edits to api.dart, core/models.py, core/urls.py, sidebar,
app_*.arb, migrations, or Flutter builds.

---

## 1. New files

Backend (pure, stdlib-only, no Django/DB/network/clock/AI):
- `backend/core/logic/mock_interview.py` — bilingual question bank (19 Qs ≥ 15
  across job/hr/technical/viva), rule-based feedback rubric, model-answer
  outlines, session progress, and a documented `live_interview_seam()`.
- `backend/core/logic/mock_interview_tests_snippets.py` — 17 plain-assert tests.
- `backend/core/logic/language_partner.py` — bilingual deck (24 cards ≥ 20
  across 5 decks), prompt/answer by direction, Leitner spaced-repetition
  (`schedule_review`, `due_after_days`, `due_cards`), deterministic quiz +
  grade, and a documented `live_conversation_seam()`.
- `backend/core/logic/language_partner_tests_snippets.py` — 18 plain-assert
  tests.

Flutter (ZERO Bangla literals — verified U+0980–U+09FF absent in both):
- `app/lib/screens/mock_interview_screen.dart` — screen + `_MiEngine` VERBATIM
  Dart mirror of the Python engine.
- `app/lib/screens/language_partner_screen.dart` — screen + quiz sub-screen +
  `_LpEngine` VERBATIM Dart mirror.

Phase-B artifacts:
- `.phaseB/up_interviewlang_arb.json` — 169 NEW l10n keys (`[bn, en]`) + `_params`.
- `.phaseB/up_interviewlang_integration.md` — this file.

Edited (one registration block only):
- `backend/core/tests.py` — added `MockInterviewSnippetTests` +
  `LanguagePartnerSnippetTests` via the existing `_make_snippet_case` helper
  (same pattern as `SocialComposeSnippetTests`).

---

## 2. Zero-Bangla strategy (.dart stays Bangla-free)

Both engines hold ONLY ASCII in Dart: ids, categories, keyword hints
(mock-interview) and ids, deck names, romanised pronunciation hints
(language-partner). All bilingual DISPLAY text (question prompts, model
outlines, card words) resolves through AppLocalizations getters by active
locale:
- Mock interview: `miQ_<id>` (prompt) and `miO_<id>` (outline), resolved by the
  ASCII switch helpers `_miQuestionText` / `_miOutlineText`.
- Language partner: `lpC_<id>_bn` and `lpC_<id>_en` (BOTH sides always needed
  because practice flips direction bn2en/en2bn independent of UI locale),
  resolved by `_lpCardText` and the side-key splitter `_lpSideKey` (used by the
  quiz, whose options/prompt are stored as ASCII `<id>_<side>` keys).

Confirmed: `grep -P '[\x{0980}-\x{09FF}]'` returns 0 matches in both .dart files.
(Note: the sentence-break set `.!?।` in `_MiEngine.feedback` uses U+0964
Devanagari danda, outside the Bangla block, matching the Python engine.)

---

## 3. ARB keys — `up_interviewlang_arb.json`

- 169 NEW keys total (80 `mi*`/`miQ_*`/`miO_*`, 89 `lp*`/`lpC_*`), each
  `"key": ["<bangla>", "<english>"]`. Bangla is real & natural.
- 10 parameterized keys under `_params` (form `{key: {placeholder: Type}}`):
  `miProgressLabel{done,total}`, `miWordsCount{count}`, `miCoveragePct{pct}`,
  `miSessionAsked{count}`, `lpDueCount{count}`, `lpDeckProgress{started,total}`,
  `lpQuizScore{correct,total}`, `lpNextReview{days}`, `lpBoxLabel{box}`,
  `lpMasteredCount{count}`.

Integrator merge step (`.phaseB/merge_arb.py` convention): add every non-`_`
key to `K` as `[bn, en]` (already in that exact shape here — copy straight in),
and add each `_params` entry to `PARAMS` as a LIST of placeholder names (e.g.
`"miProgressLabel": ["done", "total"]`). The merge writes `@key` metadata with
`type: Object`, matching the repo. Do NOT hand-edit app_en.arb/app_bn.arb;
re-run the merge + l10n codegen. The 10 parameterized getters and all `miQ_*`/
`miO_*`/`lpC_*` getters are the only analyzer errors until codegen runs.

---

## 4. EXACT persistence — generic REST collections (no api.dart edit)

Screens call the existing `ApiClient.listItems/createItem/updateItem/deleteItem`
(no api.dart change). Integrator adds TWO names to `GENERIC_COLLECTIONS` in
`backend/core/views.py` (PaCollectionItem precedent — NO migration):

```python
# #131 Mock interview + #132 Language-learning partner
"interview/sessions", "langlearn/progress",
```

Row shapes (each round-trips as `{id, ...data}` via the flatten serializer):

`interview/sessions` (mock interview — one row per saved practice answer):
```
{ id, category, question_id, answer, level, words, coverage, self_score, date }
```
- `category` ∈ {job, hr, technical, viva}
- `question_id` — a bank id (e.g. "job_tellme")
- `level` ∈ {too_short, ok, strong}; `words` int; `coverage` 0.0–1.0
- `self_score` int 1–5; `date` 'YYYY-MM-DD'
- created on Save, deleted from history; never updated.

`langlearn/progress` (language partner — one row per card the user studied):
```
{ id, card_id, deck, box, next_due_day, reps, last_day }
```
- `card_id` — a deck card id (e.g. "g_hello"); `deck` ∈ the 5 deck keys
- `box` int 1–5 (Leitner); `next_due_day` int day-number (days since epoch)
- `reps` int (times reviewed); `last_day` int day-number
- created on first review of a card; UPDATED in place on each subsequent
  pass/fail (the screen looks up the existing row by `card_id`).

The day-number is computed once at the UI edge (`_todayDay()` = UTC ms / 86.4M)
and passed INTO the engine; the engine itself has no clock (mirrors probashi.py).

---

## 5. Key-gated AI seam (honest)

Both features are fully usable with NO key. Exactly one capability per feature
genuinely needs a model; each is a DOCUMENTED seam that returns the request
SHAPE for `core.ai.generate` and ALWAYS reports `ai_required=True, mock=True`
with empty generated fields (never fabricates):

- Mock interview — `mock_interview.live_interview_seam(question_id, answer)`:
  a live AI interviewer that reacts with follow-ups + conversational critique.
  Rule-based `feedback()` stays `ai_required=False, mock=True` and works alone.
  UI shows `miLiveSeamTitle` / `miLiveSeamBody` ("connect an AI key …").
- Language partner — `language_partner.live_conversation_seam(deck, message)`:
  a live back-and-forth partner that replies + gently corrects. Decks,
  flashcards, SR and quizzes all work key-free. UI shows `lpLiveSeamTitle` /
  `lpLiveSeamBody`.

To wire the real path later: route the seam dict to `core.ai.generate` only
when `integrations.is_enabled("anthropic")` (or a backup AI provider); the
deterministic layer remains the honest default. The engines never call a model.

Honest markers rendered in the UI:
- `miFbMarker` = "Rule-based check — not an AI grade" (every feedback card).
- `miOutlineNote` = outline is "a study guide — not a single correct answer".
- `lpHintMarker` = pronunciation is "approximate romanised — not exact phonetics".
- Engine marker keys: `mock_interview.MARKER_KEY = "rubric_review"`,
  `language_partner.MARKER_KEY = "builtin_deck"`.

---

## 6. Tests

- `backend/core/tests.py` registration (one block, `_make_snippet_case`):
  `MockInterviewSnippetTests` (17) + `LanguagePartnerSnippetTests` (18) = 35.
- Verified standalone (`python3 *_tests_snippets.py`) → "17 tests passed" /
  "18 tests passed", and via the Django import path (`django.setup()` + direct
  invocation) → all 35 pass. (The project DB can't be created in this sandbox —
  `manage.py test` still COLLECTED all 35; the asserts are pure and ran green
  directly.)
- Coverage: bank/deck content minimums (≥15 Qs, ≥20 cards) & bilingual
  completeness, unique ids, next-unasked + wrap, rubric level/coverage/tips,
  bad-input guards, determinism, Leitner promote/reset + intervals, due filter,
  deck rollup, quiz build/answer-index/grade, and both AI seams being gated and
  never fabricating.

---

## 7. Sidebar / navigation entries (integrator wires — sidebar NOT touched here)

Both belong under the existing nav groups:
- #131 Mock interview → **Work** group (interview prep / career).
  Route to `MockInterviewScreen()`; icon `Icons.record_voice_over_outlined`;
  label `miTitle`.
- #132 Language-learning partner → **Daily Life** group (learning / self-dev).
  Route to `LanguagePartnerScreen()`; icon `Icons.translate`; label `lpTitle`.

Add a `MaterialPageRoute` entry in the drawer's group list exactly as the other
screens do (e.g. fitness/qurbani precedent). No bottom-bar (drawer-nav standard).

---

## 8. Dart mirror ↔ Python parity (determinism contract)

`_MiEngine` mirrors `mock_interview.py`: identical bank ids + keyword hints,
`minWordsOk=20`, `minWordsStrong=45`, `coverageStrong=0.5`, same tip-key order
(tip_longer → tip_cover_keywords → tip_structure → tip_strong / tip_ok), same
next-unasked-then-wrap selection, same `.!?।` structure check.

`_LpEngine` mirrors `language_partner.py`: identical deck ids + hints, Leitner
`boxDays {1:1,2:2,3:4,4:7,5:15}`, promote-on-pass / reset-to-1-on-fail, same
due-card filter (unstudied = due), same deterministic quiz rotation
(`(i+1+j+seed)%n` distractors, `(i+seed)%len` answer placement) and grading.

Same inputs → same output on device and server, so previews match offline and
the tests pin both sides.
