# Memory ("AI knows about me") — GOOD → ADVANCED (integration notes)

SPEC v2.1 §21. Upgrades the Memory module from a flat searchable list into a
**categorized, privacy-controlled, transparent** memory the user fully owns:
six canonical categories, per-item privacy controls, honest provenance,
**confirm-before-the-AI-learns**, and **export / clear-all** data rights — with
a "What Assisto knows about me" transparency view so trust is earned, not
assumed.

## Files
- **Edited:** `app/lib/screens/memory_screen.dart` — the screen. Keeps the
  natural-language retrieval box + deterministic `searchMemory` ranking (exact
  mirror of backend `reminders_engine.search_memory`, same 41-token stopword
  set, verified identical). Everything else is new: category bar + counts,
  add/edit bottom sheet with category chips + inline privacy, per-item privacy
  sheet, AI-consent cards, export, clear-all, transparency sheet, and all §21
  states.
- **New:** `app/lib/widgets/mem_privacy.dart` — local privacy/provenance layer:
  `MemPrivacy` (SharedPreferences-backed via the existing `Settings` store),
  `MemFlags` (private / sensitive / excludeFromAi), `MemPending` (AI-consent
  queue), `MemCat` + `MemCategories` (six canonical buckets, icons, colors,
  and bilingual/Banglish keyword bucketing of free-text categories).
- **New:** `app/lib/widgets/mem_widgets.dart` — presentational widgets:
  `MemCategoryBar`, `MemItemCard`, `MemTag`, `MemConsentCard`, `MemSwitchRow`,
  and `memCatLabel()`.

## Untouched (as required)
`api.dart`, `app_*.arb` (strings emitted to `up_mem_arb.json` instead),
`models.dart` / `models.py`, `state.dart`, `urls.py`, serializers, sidebar,
unrelated screens, migrations. No `flutter`/`build` run. No Asalify. Backend
`core/logic` was read but **not modified** — the existing `search_memory`
already matched our needs, so no logic/test changes were necessary (the option
to touch it went unused).

## Why no model/state/API changes were needed
The backend `MemoryItem` carries only title/category/detail/source/needs_review.
The advanced **privacy + consent** data (private / sensitive / exclude-from-AI
flags, and the "AI wants to remember this" queue) is **user-private and
device-local by design**, so it is persisted through the existing `Settings`
(SharedPreferences) store, keyed by the item's stable id
(`srv-<id>` once synced, else the local id). This keeps the required surfaces
frozen and keeps privacy data off the wire entirely — the strongest possible
"excluded from AI" guarantee. Categories are written into the existing
free-text `category` field as canonical ids (`family`/`health`/… ), so they
round-trip through the untouched API and re-bucket on read.

## Advanced vs before (GOOD)
| | GOOD (before) | ADVANCED (now) |
|---|---|---|
| Categories | free-text chips from whatever strings existed | 6 canonical buckets (family / health / preferences / work / important dates / other) with icons, colors, live counts, and bilingual/Banglish auto-bucketing |
| Add/edit | 3 plain dialog fields | bottom sheet: category chips + inline privacy controls |
| Privacy | none | per-item **mark private / sensitive / exclude-from-AI**, with a "show private" reveal toggle |
| Provenance | AI / manual tag | AI / manual tag **+** AI-learned items pass through explicit consent first |
| AI learning | implicit | **confirm-before-learn** consent cards — nothing is remembered without a tap |
| Transparency | — | "What Assisto knows about me" sheet: totals, AI-learned count, shared-with-AI count, excluded count, per-category breakdown, plain-language promise |
| Data rights | — | **export** (copy full human-readable dump) + **clear everything** (confirmed, irreversible) |
| States | empty / no-results | empty / loading / error+retry / offline banner / no-results (private-aware) |

## Confirm-before-AI-learns (transparency)
AI-proposed facts are held in `MemPrivacy` as `MemPending` and surfaced at the
top of the list as `MemConsentCard`s ("The AI wants to remember this —
nothing is saved without your permission"). **Remember it** promotes the fact
into real memory; **No, discard** drops it. Until the user taps, the fact is
never written to memory and never reaches the AI. A single seeded sample
suggestion makes the flow discoverable on first run (clearly a suggestion; it
saves nothing until confirmed). When a live `/agent` capture pipeline wants to
propose facts, it only needs to append `MemPending` entries to the local queue
(`MemPrivacy.savePending`) — no screen change required.

## Privacy controls
Per item, three independent switches (editor sheet + standalone item menu):
- **Exclude from AI** — stays saved for the user, the AI never uses it. Badged
  "Not for AI" (Brand.danger) on the card.
- **Sensitive** — health/money, extra-care badge (Brand.warning).
- **Private** — hidden from the default list; revealed only via the "Show
  private" menu toggle; honest no-results copy when a search is blocked by it.

Defaults are all-off (= shared with AI, not sensitive) and a default item
stores no flag at all, so the store stays tiny and the behaviour is
predictable.

## Export / Clear-all (data rights)
- **Export** builds a readable, bilingual-labelled dump (category · title ·
  detail · provenance/privacy tags), copies it to the clipboard, and shows it
  in a selectable dialog.
- **Clear everything** confirms first (irreversible warning), then removes every
  memory item via the existing `removeMemory` (offline-safe, server-synced) and
  wipes the local flags + consent queue.

## §21 ten-point coverage
1. **Empty** — StateMessage + "Add your first note" CTA. 2. **Loading** —
`SkeletonList` while the local privacy layer loads. 3. **Error** — failed sync
with no cache → error card + Retry. 4. **Offline** — amber banner
(`memOfflineBanner`); all edits stay offline-first and sync later. 5. **Honest
unavailable** — privacy/consent data is device-local; "Exclude from AI" is a
real guarantee (never leaves the device), not a label. 6. **Bilingual** — all
new strings in `up_mem_arb.json` (bn+en, both filled); category bucketing
understands bn/Banglish/en; **zero Bangla literals in any .dart** (verified: 0
Bangla chars across all three files; stopwords/digits kept as `\u` escapes).
7. **WCAG** — selected chips use white-on-brand fills; category icons carry
color + glyph (not color alone); switch rows have title+subtitle; every item
card is a `Semantics(button, label)` summarizing title/category/provenance/
privacy; tooltips on all icon buttons. 8. **Confirm before action** — AI-learn
consent cards + irreversible clear-all confirm dialog. 9. **Scenario** —
"Dad's BP medicine at 8am" (health, sensitive), "wifi password" (private,
exclude-from-AI), AI proposing "prefers tea in the morning" → confirm →
remembered; search "ammur oshudh" still ranks via the preserved engine.
10. **Retry** — from the error state.

## ARB codegen (required before the app builds)
The **45 keys** in `up_mem_arb.json` must be merged into
`app/lib/l10n/app_bn.arb` (bn = index 0) and `app_en.arb` (en = index 1), then
`flutter gen-l10n` run — same deferred pattern as the other `.phaseB/*_arb.json`
drops. Until then the new `t.mem*` getters won't exist. Reused existing keys
(NOT re-emitted): `add, all, cancel, close, commonDeleted, delete, edit, retry,
save, undo`, and all `memory*` keys (`memoryScreenTitle`, `memorySearchHint`,
`memoryEmpty*`, `memoryNoResults*`, `memoryNewItemTitle`, `memoryEditItemTitle`,
`memoryTitleLabel`, `memoryDetailLabel`, `memoryCategoryLabel`, `memoryTagAi`,
`memoryTagManual`, `memoryTagSyncing`).
