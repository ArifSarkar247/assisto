# IELTS mock authoring spec (how to scale to 200+ original mocks)

> বাংলায়: নতুন মক টেস্ট লেখার নিয়ম। প্রতিটি মক `blueprints/ielts_plan.json`-এর পরিকল্পনা মেনে লেখা হয়, তারপর CI-র স্বয়ংক্রিয় চেক (lpcheck) পাস করলে `ai-checked`, শেষে Owner Admin-এ মানুষ অনুমোদন দেয়। কোনো পেইড AI API CI বা সার্ভার থেকে ডাকা হয় না — লেখক (Claude এজেন্ট বা মানুষ) নিজে লেখে।

## Pipeline
1. `python3 tools/lp/blueprint.py` → `blueprints/ielts_plan.json`: for every mock 004–200 the module,
   topics, Listening contexts + accents, question-type mix and Writing/Speaking prompts. Topics never repeat.
2. An author (a Claude agent session or a human) writes `content/ielts/<id>.json` per `FORMAT.md` and this
   spec, in batches of 3–5 mocks per agent, one mock per file. No paid API is ever called from CI/server.
3. Push `ci/lpcontent` → `lp-content.yml`: unit tests + `lpcheck.py` (format, answer uniqueness, word
   limits, timing, level, duplicates, copyright fingerprints, Bangla) → `index.json` marks `ai-checked`.
   Add `[audio]` to the commit message to render Listening audio (Kokoro / MeloTTS) into `lp-audio-<run>`.
4. lpcore imports the `lp_bundle/` artifact (`manage.py lp_import`) → Owner Admin review queue →
   `human-approved`. Until then the app shows **beta**.

## Real-exam shape (every mock)
| Section | Shape | Timing |
|---|---|---|
| Listening | 4 parts × 10 Q. P1 two people, everyday transaction (form/note/table completion, names spelled, numbers); P2 one speaker, everyday/public info (MCQ, map/plan labelling, matching); P3 2–4 people, study/training (MCQ, choose-two, matching opinions); P4 academic lecture (note/summary completion, ONE WORD ONLY usually) | 30 min audio-paced + check time; scripts P1 550–700, P2 600–750, P3 700–850, P4 750–900 words |
| Reading Academic | 3 passages 750–950 words, Q 13/13/14, rising difficulty; journal/magazine/textbook register | 60 min |
| Reading GT | S1 2–3 short everyday texts (adverts, notices, timetables); S2 two work texts (policies, guides); S3 one longer general-interest text | 60 min |
| Writing | Academic T1 chart/table/process/map (≥150 words, 20 min); GT T1 letter with 3 bullets + tone; T2 essay ≥250 words, 40 min | 60 min |
| Speaking | P1 3 familiar topics × 4 Q; P2 cue card (1 min prep, 2 min talk) + 1 follow-up; P3 2 abstract themes × 3–4 Q | 11–14 min |

## Writing good items
* **Original only.** Invent places, organisations and data. No real living person quoted. Never use,
  adapt or paraphrase any published test (Cambridge or otherwise), textbook or article. Topics may be the
  same kind as the real exam; the text never is.
* **Listening distractors:** in every completion segment at least two traps — a speaker corrects a
  number/date ("the 14th — sorry, no, the 15th"), a rejected option is mentioned before the chosen one, a
  name is spelled after a wrong guess. The key must be the only answer that fits grammar + limit.
* **Paraphrase:** prompts never copy the sentence that holds the answer; the answer word itself must not be
  printed in the prompt (lpcheck blocks it). Questions follow text order (except matching/headings/global MCQ).
* **TRUE/FALSE/NOT GIVEN:** each group uses all three; NOT GIVEN items name a plausible detail the text
  touches but never settles, with a `rationale`.
* **MCQ:** Listening 3 options, Reading 4; every wrong option is mentioned or implied in the text; spread the
  keys across A–D.
* **Difficulty mix per mock (target discrimination band 5–8):** ~30% easy (direct detail), ~45% medium
  (paraphrase/synonym), ~25% hard (inference, writer's view, distractor-heavy). Reading passage 3 and
  Listening part 4 carry most hard items. Academic passages: Flesch ≈ 25–55, ≥ 18% words of 7+ letters.
* **Explanations:** `explain_en` + `explain_bn` (one short, clear Bangla sentence, why the key is right
  and the trap is wrong). `skill` tag from FORMAT.md §3.1 (drives weak-area practice).
* **Spelling variants:** list British/American spellings and number forms in `accept`; every variant must fit
  the word limit.
* **Writing:** `key_features` = what a Band 7+ answer must cover (overview, the 3–4 main comparisons…);
  model answer ≈ Band 8, 160–200 (T1) / 270–320 (T2) words, original.
* **Accents:** each mock mixes GB, US and AU; max one AU speaker per part (one licence-clean AU voice).

## Adding to the copyright guard
Reviewers who own published prep books may type the first 2–3 sentences of each passage/script into a local
text file (outside the repo) and run `python3 tools/lp/fingerprint_add.py --label "<book/test>" file.txt`.
Only 8-word shingle hashes are committed; lpcheck then rejects any mock containing such a sequence.
