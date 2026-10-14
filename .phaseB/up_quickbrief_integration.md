# Quick tools (#17, §6) + Morning brief & night summary (#7, §6): integration notes

Two **new** AI-core features, built to Section-21 **advanced**. Both ship the
DETERMINISTIC / MOCK layer that works with **no key**, carry honest
"AI-generated — review" markers, and expose honest **key-gated** states/seams.
No fabricated AI/weather/news output anywhere. Scope stayed inside the allowed
edit set: **new** screens + **new** engine widgets + **new** pure backend
engines + their tests + **one** `core/tests.py` registration line. **Not
touched**: `api.dart`, `core/models.py`, `core/urls.py`, sidebar, `app_*.arb`,
migrations, Flutter builds, Asalify.

---

## 1. Files created

### Backend (pure, deterministic — no Django / DB / network / AI / clock)
- `backend/core/logic/quick_tools.py` — toolbox engine: `summarise` (extractive,
  scored, original-order), `fix_grammar` (rule-based spacing/punct/caps only —
  NOT a rewrite), `translate` (honest: direction + tiny built-in common-phrase
  table, else `ai_required=True` with empty `translated` — never fabricates),
  `change_tone` (template reframing), `make_shareable` (tidy + word-boundary
  clamp). `run()` dispatch + `ai_plan()` documented key-gated seam.
- `backend/core/logic/quick_tools_tests_snippets.py` — **19** plain-assert tests.
- `backend/core/logic/daily_brief.py` — `morning_brief()` (overdue-first + today),
  `night_summary()` (done / open / tomorrow + honest `completion_pct`),
  `normalise()`, `build()` dispatch, `share_text()`, `weather_slot()` /
  `news_slot()` honest key-gated placeholders, `ai_brief_plan()` seam.
- `backend/core/logic/daily_brief_tests_snippets.py` — **18** plain-assert tests.

### Flutter (on-device mirrors of the Python engines; zero Bangla literals)
- `app/lib/widgets/quick_tools_engine.dart` — mirror of `quick_tools.py`
  (`runQuick`, `summariseQuick`, `fixGrammarQuick`, `translateQuick`,
  `changeToneQuick`, `makeShareableQuick`, `validateQuick`, `QuickResult`,
  `QuickStore` local save). The common-phrase bn renderings are **not** in the
  .dart — `translateQuick(phraseTable:)` receives them from the screen (ARB), so
  the file stays Bangla-free while matching the Python source of truth.
- `app/lib/screens/quick_tools_screen.dart` — the toolbox UI: text input, tool
  chips, tone/direction choosers, honest AI marker + "never sends for you",
  result card (SelectableText), copy / share / optional save, and the honest
  "connect an AI key for a real translation" state.
- `app/lib/widgets/daily_brief_engine.dart` — mirror of `daily_brief.py`
  (`buildBrief`, `normaliseBrief`, `shareBriefText`, `DailyBrief`, `BriefItem`).
- `app/lib/screens/daily_brief_screen.dart` — two tabs (Morning / Night),
  §21 states (loading skeleton / error+retry / honest empty), grouped item
  tiles, completion bar, honest weather/news key-gated chips, share.

### Deliverables
- `.phaseB/up_quickbrief_arb.json` — **60 keys** + **1** `_params` entry
  (`dbCompletion: [pct, done, total]`), `{key:[bn,en]}`. Bangla real + natural.
- `.phaseB/up_quickbrief_integration.md` — this file.

### Edited (one line region)
- `backend/core/tests.py` — one `_make_snippet_case` registration block adding
  `QuickToolsSnippetTests` + `DailyBriefSnippetTests` (comment + 4 lines).

---

## 2. ARB keys + params

60 keys. Prefixes: `qt*` (quick tools, incl. `qtPhrase*` offline-fallback
lookup data) and `db*` (daily brief). The screens also reuse existing common
keys **not** in this file: `copy`, `copied`, `share`, `save`, `saved`, `retry`.

`_params`:
- `dbCompletion` → `["pct", "done", "total"]` (e.g. "3 of 5 done (60%)").

The `qtPhrase_*` keys carry the bn rendering of each known common phrase; the
screen passes them to `translateQuick(phraseTable:)` so the offline fallback
produces a real (tiny) translation with no Bangla literal in any `.dart`.

**Integrator ARB merge** (same as every prior `up_*` wave): merge
`up_quickbrief_arb.json` into `app_bn.arb` / `app_en.arb`, add the `@_params`
placeholder metadata for `dbCompletion`, and regenerate `app_localizations.dart`.
Until then the two screens reference keys that resolve after the merge
(identical pattern to the social composer).

---

## 3. Collection paths + shapes

### #17 Quick tools — mostly STATELESS
Results are transient. An **optional** local save keeps a short history in
SharedPreferences (`quick_tools_v1`, newest-first, capped 30) via `QuickStore`.

Optional CROSS-DEVICE save seam (documented, not wired to avoid touching
`api.dart` beyond the existing generic helpers): generic collection
**`quicktools/saved`** via `listItems/createItem/deleteItem`. Row shape:
```
{ "action": "summarise|fix_grammar|translate|change_tone|make_shareable",
  "source": "<input text>", "result": "<output text>",
  "savedAt": "<ISO-8601>" }
```
**Integrator:** add `"quicktools/saved"` to `GENERIC_COLLECTIONS` in
`backend/core/views.py` (PaCollectionItem flexible store — **no migration**).

### #7 Daily brief — READS existing data; may persist prefs
The brief **aggregates existing data only** (no fabrication). It reads, all
best-effort (one source failing never blanks the card), via helpers that already
exist (no `api.dart` edit):
- `api.listItems('reminders')`   → `{title|text, due_at|when (ISO), done}`
- `api.listItems('subscriptions')` → mapped to payments
  `{name|title, due_date|next_due|due_at, amount, paid|done}`
- `api.listItems('appointments')` → events (meetings screen stores `{items:[…]}`
  or flat rows; the screen handles both) `{title|name, start|when, place}`
- `api.birthdaysList()` (existing **`HealthApi` extension** on `ApiClient`,
  `GET /birthdays`) → `{upcoming:[{name, next_date, days_until}]}`

Optional brief PREFERENCES seam (documented, not wired): generic collection
**`brief/prefs`**. Row shape:
```
{ "morning_hour": 7, "night_hour": 21,
  "sources": ["reminder","payment","birthday","event"] }
```
**Integrator:** add `"brief/prefs"` to `GENERIC_COLLECTIONS` if prefs are wanted
(no migration). The screen works fully without it (sensible defaults).

> If a real server-side AGGREGATION endpoint is later preferred over the four
> client reads, document it as `GET /brief?mode=morning|night` returning the
> `daily_brief.build()` dict; the screen then calls that instead and the pure
> engine moves server-side unchanged. Until then the screen degrades honestly
> per-source and shows the "nothing scheduled" empty state when all are empty.

---

## 4. Key-gated seams (which Integrations keys)

All honest: the engines NEVER call a model/feed and NEVER fabricate output.

| Seam | Integrations key | Mock/offline behaviour | Live behaviour (integrator) |
|---|---|---|---|
| Quick-tools richer result (true translation, fuller rewrite, abstractive summary) | **`anthropic`** | deterministic mock result; translate shows honest "needs key" state for non-phrase input | route `quick_tools.ai_plan(...)` shape to `core.ai.generate` |
| Brief AI narration (warm NL of the same items) | **`anthropic`** | deterministic card from own data | route `daily_brief.ai_brief_plan(...)` to `core.ai.generate` |
| Morning weather | **`weather`** (already in `integrations.REGISTRY`) | honest "add a weather key" chip; `weather_slot(connected=False)` → `needs_key:True, data:None` | call `weather_slot(connected=True, data={...})` from the real feed |
| Night headlines | **`news`** (already in `integrations.REGISTRY`) | honest "add a news key" chip; `news_slot()` → `needs_key:True, items:[]` | call `news_slot(connected=True, items=[{title,url}])` from the real feed |

`anthropic`, `weather`, `news` all already exist in
`backend/core/integrations.py::REGISTRY` — no registry edit needed. The real-AI
route (`core/ai.py`) wraps the user's own text in a DATA fence; the seam
functions only describe the request SHAPE.

---

## 5. Tests

- Registered in `core/tests.py` via the existing `_make_snippet_case` factory as
  `QuickToolsSnippetTests` (19) and `DailyBriefSnippetTests` (18) — **37** new
  tests. Both suites also run standalone (`python <file>`), all green.
- They pin: validation, determinism, honest mock flags on every result,
  extractive-only summarise (every output word came from input), rule-based
  grammar (incl. clean-input no-op), translate honesty (phrase hit offline vs
  `ai_required` + empty `translated` for unknowns), tone presets, word-boundary
  share clamp; brief bucketing (overdue/today/tomorrow, birthdays never
  "overdue"), honest `completion_pct`, empty states, deterministic `build`, and
  weather/news slots never fabricating.

---

## 6. Sidebar entries + wiring (integrator)

Neither screen is wired into navigation yet (sidebar is out of the edit set).

- **Quick tools → Work section** (or a top "tools" spot). Suggested drawer item
  under **Work**: label `qtTitle`, icon `Icons.build_circle_outlined`, pushes
  `const QuickToolsScreen()`. (A bounded AppBar entry from Agent Studio — as the
  social composer does — is an equally clean alternative.)
- **Morning brief & night summary → Daily Life section** (or Home). Suggested
  drawer item under **Daily Life**: label `dbTitle`, icon
  `Icons.wb_twilight_outlined`, pushes `const DailyBriefScreen()`. A Home
  shortcut card is a natural second entry point.

Both `import`s: `screens/quick_tools_screen.dart`, `screens/daily_brief_screen.dart`.

---

## 7. Honesty / identity guarantees

- Every quick-tools result and brief carries `mock:true` + the `ai_review`
  marker; the UI renders the localised "AI-generated — review" chip.
- Translate never invents a sentence translation; weather/news are never
  fabricated — only honest "add a key" placeholders until connected.
- The brief is assembled from the user's OWN entered data only; empty sources
  contribute nothing (no filler), and completion % is never rounded up past open
  items.
- Original Assisto identity; deterministic mock clearly labelled; nothing is
  ever auto-sent/posted — the user copies/shares themselves.
