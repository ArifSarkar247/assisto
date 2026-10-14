# Integration note — #97 In-chat AI + #5 "What AI knows about me" (§21 ADVANCED)

Two AI-transparency surfaces built to the Section-21 advanced standard. Both AI
outputs are **deterministic MOCKs** that are **clearly key-gated** and carry an
honest "AI-generated — review" marker. No model is called; no key is needed to
run them. The real-AI path is a documented seam the integrator wires later.

---

## 1. Files changed / added

### Backend (`backend/core/`)
- **ADDED** `logic/in_chat_ai.py` — pure, deterministic engine for the three
  bounded in-chat actions: `summarise_thread`, `translate_message`,
  `adjust_tone`, plus `validate(...)` and a single `run(action, ...)` dispatch
  mirroring the real-AI request shape. No Django, no DB, no network, no clock,
  **no AI**. Every result dict carries `mock=True`, `marker="ai_review"`, and an
  honest `ai_required` flag.
- **ADDED** `logic/in_chat_ai_tests_snippets.py` — 16 plain-assert hand-verified
  checks (`run_all()` runnable standalone).
- **EDITED** `core/tests.py` — one new line via the existing `_make_snippet_case`
  helper (added `InChatAiSnippetTests`, next to `SocialComposeSnippetTests`). No
  other test touched.

> #5 reuses the **existing** memory storage (`MemoryItem` model + sync) — **no
> new backend model, no new logic module, no migration.** The transparency page
> is a pure read/delete view over data the memory module already owns.

### Flutter (`app/lib/`)
- **ADDED** `widgets/in_chat_ai_engine.dart` — on-device Dart mirror of
  `in_chat_ai.py` (same deterministic output). Pure; analyzes with **zero
  issues**. Zero Bangla literals (tone skeletons are neutral English seeds; the
  only Bangla handling is a Unicode-range check U+0980–U+09FF to *guess*
  translate direction).
- **ADDED** `widgets/in_chat_ai_sheet.dart` — the ONE bounded in-chat AI helper
  UI (bottom sheet): action chooser, inputs, deterministic result card with the
  honest AI marker, **Copy** + **Insert** actions, and the honest "needs AI key"
  state for translate. Returns a String to INSERT or null. Never auto-sends.
- **ADDED** `screens/ai_knowledge_screen.dart` — the dedicated "What AI knows
  about me" transparency page (see §6 below).
- **EDITED** `screens/circle_chat_screen.dart` — minimal, disjoint:
  - one import added;
  - the existing `⋮ → Summarise` menu case now opens the bounded helper
    (`_openInChatAi()`) instead of the old `_aiExtra` dialog — **one bounded
    entry**. (The old `_aiExtra` + the `translate`/`makeReminder` cases are left
    untouched.)
  - new method `_openInChatAi()` seeds from the composer draft, passes the
    last-5 **device-decrypted** messages, and on return INSERTS the text into
    the composer (never sends).
- **EDITED** `screens/memory_screen.dart` — minimal, disjoint:
  - one import added;
  - the existing transparency app-bar icon now navigates to the dedicated
    `AiKnowledgeScreen` (one bounded entry) instead of the transient bottom
    sheet;
  - removed the now-superseded `_openTransparency` + its private `_statRow`
    helper and an unused local — no behavioural change elsewhere.

---

## 2. New ARB keys

Emitted to `/home/ubuntu/assisto/.phaseB/up_inchatai_arb.json` as
`{"keyName": ["<bangla>", "<english>"], ...}`. **33 new keys**, of which **1 is
parameterized**. `app_en.arb`/`app_bn.arb` were NOT edited — the integrator
merges these and regenerates `app_localizations.dart`.

- In-chat AI (#97): `inChatAiTitle`, `inChatAiIntro`, `inChatAiSummarise`,
  `inChatAiTranslate`, `inChatAiTone`, `inChatAiTonePolite`,
  `inChatAiToneShorter`, `inChatAiToneWarmer`, `inChatAiToneFirmer`,
  `inChatAiToneFormal`, `inChatAiTextLabel`, `inChatAiToneLabel`,
  `inChatAiGenerate`, `inChatAiThreadEmpty`, `inChatAiThreadCount`,
  `inChatAiTextMissing`, `inChatAiWhoYou`, `inChatAiWhoThem`,
  `inChatAiTranslateBnEn`, `inChatAiTranslateEnBn`, `inChatAiTranslateSource`,
  `inChatAiNeedsKey`, `inChatAiMarker`, `inChatAiCopied`, `inChatAiCopy`,
  `inChatAiInsert`, `inChatAiNeverSends`.
- AI knowledge (#5): `aiKnowTitle`, `aiKnowIntro`, `aiKnowEmptyTitle`,
  `aiKnowEmptyBody`, `aiKnowSourceAi`, `aiKnowSourceManual`.

`_params`:
```json
"_params": { "inChatAiThreadCount": { "count": { "type": "int" } } }
```
So the generated getter is `String inChatAiThreadCount(int count)` (ICU
`{count}` placeholder present in both bn + en strings).

Reused existing keys (NOT re-defined): `memClearAll`, `memClearAllBody`,
`memClearAllConfirm`, `memClearAllDone`, `memStatTotal`, `memStatAi`,
`memStatSharedAi`, `memStatExcluded`, `memTransparencyPromise`, `memoryTagAi`,
`memoryTagManual`, `memPrivacyExcludeShort`, `memPrivacySensitive`,
`memPrivacyPrivate`, `delete`, `undo`, `commonDeleted`, `cancel`.

> After merging the ARB, `dart analyze` on the touched screens/widgets is
> expected to go green. Before the merge, the only analyzer errors are the
> "undefined getter" for these 33 new keys (plus one pre-existing
> `unnecessary_import` info in `circle_chat_screen.dart` that is not mine).

---

## 3. New endpoints

**None.** Nothing new is wired into `core/urls.py`.
- #97 operates entirely on-device over already-decrypted messages (the chat is
  E2E-encrypted; the server never holds plaintext).
- #5 reuses the existing memory endpoints via `AppState.memory` /
  `AppState.removeMemory` (same path the memory editor uses).

---

## 4. The key-gated AI route seam (wire later)

The deterministic mock serves the promise **now**. When an AI key is present
(Integrations → Anthropic), the integrator routes the **same request shape**
to the real provider:

- Server route: **`core.ai.generate(task=..., data=<untrusted text>, tier=...,
  feature="in_chat_ai", user=request.user)`** (see `backend/core/ai.py`).
  - With no key, `ai.generate` raises `AIUnavailable(reason="no_key")` — the UI
    already renders the honest needs-key state for `translate`
    (`inChatAiNeedsKey`), and the mock covers `summarise`/`tone`.
  - Untrusted message text MUST go through the `data=` DATA-fence (ai.py's
    `_INJECTION_GUARD`), never the task/prompt.
- Request contract = the dict shape returned by `in_chat_ai.run(...)`:
  `action ∈ {summarise, translate, tone}`, plus `messages` (summarise) or
  `text` + `tone`/`direction` (translate/tone). A thin server view can map
  `run(...)` → `ai.generate(...)` when `ai.available()` and fall back to the
  mock otherwise. The honest `mock`/`ai_required`/`marker` flags let the caller
  stay truthful about which path produced the text.
- **Honesty guarantee:** `translate_message` returns `translated=""` and
  `ai_required=True` — it NEVER fabricates a translation. (No Bangla Academy /
  licensed-dictionary data is bundled; a real translation needs the keyed
  route, consistent with the open-license / honest-sourcing pattern.)
- **Never auto-sends:** both the engine and the sheet only produce TEXT; Insert
  drops it into the composer for the user to review and send.

---

## 5. Model needed

**None for this build.** #97 needs no model (device-only). #5 reuses the
existing `MemoryItem` storage. If the integrator later wants to *persist* a
log of in-chat AI usage, that is optional and out of scope — described here only
so it is not assumed: no table is required for the feature to work.

---

## 6. #5 — did a dedicated page already exist?

**No.** `screens/memory_screen.dart` exposed transparency only as a transient
**bottom sheet** (`_openTransparency`) layered on the memory *editor*. §21 wants
a durable, linkable transparency *surface* with per-item controls, so a new
dedicated standalone page **`screens/ai_knowledge_screen.dart`** was built. It:
- **reuses** the memory backend (`AppState.memory` + `MemPrivacy`) — no
  duplicate storage;
- lists every stored fact grouped by canonical category with per-item
  provenance (AI-learned vs you-added) + privacy badges;
- **per-item view** (expand to detail + provenance line) + **per-item delete**
  (through `AppState.removeMemory`, with undo);
- **clear-all** behind a danger confirm gate;
- honest **empty state** when nothing is stored;
- transparency stats (total / AI-learned / shared-with-AI / excluded) + the
  reused trust promise.
The old bottom-sheet path was removed; the memory screen's transparency icon now
opens this page (the single bounded entry).

---

## 7. Tests added

- `core.logic.in_chat_ai_tests_snippets` — **16 checks**, wired as
  `InChatAiSnippetTests` in `core/tests.py`. Cover: per-action validation; bad
  inputs; determinism; honest flags (`mock`, `marker`, `ai_required`);
  summarise count/cap/order/empty-skip/who-labels; translate auto-direction +
  **never-fabricated** guarantee + explicit direction; tone shorter/wrap/fallback;
  dispatch + bad-action-is-honest-not-crash.
- Verified passing both standalone (`python in_chat_ai_tests_snippets.py` →
  "16 checks passed") and via the Django harness (`django.setup()` import →
  16). Full `manage.py test` run only blocked by sandbox DB-create permission
  (unrelated to this code); test discovery found all 16.

---

## 8. Confirmations

- **Zero Bangla literals** (U+0980–U+09FF) in every `.dart` touched/created:
  `in_chat_ai_engine.dart`, `in_chat_ai_sheet.dart`, `ai_knowledge_screen.dart`,
  `circle_chat_screen.dart`, `memory_screen.dart` — all 0.
  (The sentence-split danda `।` is U+0964, Devanagari block, outside the
  forbidden range, and identical in the Python source.)
- `in_chat_ai_engine.dart` analyzes with **No issues found**.
- No edits to: `api.dart` request helpers, `core/models.py`, `core/urls.py`,
  sidebar, `app_en.arb`/`app_bn.arb`, migrations, Flutter builds, or Asalify.
- AI output always carries the honest marker; mock is deterministic + key-gated;
  nothing auto-sends; no fake data presented as real.
