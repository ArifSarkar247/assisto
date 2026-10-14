# Watch Feed (ADVANCED) — integration notes

Upgrades `WatchFeedScreen` from a bare price/rate watcher list into a unified,
prioritized **"what needs me now"** digest aggregated from real module signals.
No fake data: a source with nothing contributes nothing.

## Files changed / created
| File | What |
| --- | --- |
| `app/lib/screens/watch_feed_screen.dart` | Rewritten. Composes the feed client-side, groups/prioritizes, dismiss/snooze/refresh/personalize, honest states. |
| `app/lib/widgets/watch_item.dart` | NEW. `WatchItem` model + `WatchGroup`/`WatchSeverity`/`WatchAction`/`WatchSource` enums + priority (mirrors backend helper) + severity visuals. |
| `app/lib/widgets/watch_card.dart` | NEW. Actionable card: icon/severity tint, due-chip, quick-action row, bn-number via codepoints, kind-title fallback. |
| `app/lib/widgets/watch_sources_sheet.dart` | NEW. Personalization sheet (toggle which sources feed the screen). |
| `backend/core/logic/watch_feed.py` | NEW. Pure helper: `classify_group` / `in_window` / `priority` / `normalize` / `build_feed` / `ordered` / `counts`. Deterministic, no AI. |
| `backend/core/logic/watch_feed_tests_snippets.py` | NEW. 12 plain-assert tests (`run_all`). |
| `backend/core/tests.py` | Registered `WatchFeedSnippetTests` via existing `_make_snippet_case`. |
| `.phaseB/up_watch_arb.json` | NEW. 59 ARB keys `{key:[bn,en]}`. |

## What it aggregates + how (all via EXISTING `api.dart` methods — api.dart NOT edited)
| Signal | Source method | Mapped to |
| --- | --- | --- |
| Family wellness, scam, fall/SOS | `alertsList()` (`type` in family set) | `needs_you`, action: call + open → `family` |
| Safe-journey check-in overdue | `alertsList()` `checkin_overdue` | `needs_you`, call + open → `safety` |
| Medicine refill low | `alertsList()` `refill` | open + snooze → `family` |
| Loan past due | `alertsList()` `loan_due` | pay-hint + open → `money` |
| Budget blown | `alertsList()` `budget` | `needs_you`, open → `money` |
| Document expiry | `alertsList()` `doc_expiry/doc_expired` | open → `documents` |
| Reminders due today / overdue | `listItems('reminders')` (`due_at`,`done`) | `today`, mark-done + snooze + open → `reminders` |
| Medicine doses today (untaken) | `medicinesToday()` (`slot`,`taken`) | `today`, mark-taken + open → `family` |
| Subscription renewals (≤7d) | `listItems('subscriptions')` (`next_due`) | today/upcoming, pay-hint + open + dismiss → `subscriptions` |
| Price/rate/news changes | `watchFeed()` `hits` | `upcoming`, open + dismiss → `watch_feed` |
| Active watchers | `listItems('watchers')` | kept as a management section |

Deep-links use **`ChatNav.push(context, route)`** (existing). Quick actions that
persist (mark-done → `updateItem('reminders',...)`, taken → `medicineTaken(...)`,
add rate watcher → `createItem('watchers',...)`, remove → `deleteItem`) all use
methods already in `api.dart`.

Grouping/priority on the client mirrors `backend/core/logic/watch_feed.py`
(needs_you → today → upcoming; severity then soonest-due tiebreak), so a future
server-built feed would order identically.

## Advanced vs before
| Before | After |
| --- | --- |
| Single list: watchers + price/rate "hits" only | Unified digest across 8 module sources |
| No grouping | 3 honest groups: Needs you / Today / Upcoming, each with hint + per-group empty copy |
| No priority | severity+group+due-day priority sort |
| Open-only | Per-card quick actions: open, mark-done, mark-taken, snooze, dismiss (+undo), call/pay-hint |
| One empty state | Loading (labelled), error (retry), all-clear, per-group empty, per-disabled-source "enable X" hints |
| No personalization | Sources toggle sheet (session-scoped) |
| Hardcoded strings mixed in | All strings via `AppLocalizations`; bn-numbers via codepoints |

## Needed from the integrator (api / model / l10n)

### 1. l10n (REQUIRED to compile)
Merge `.phaseB/up_watch_arb.json` (59 keys) into `app_en.arb` + `app_bn.arb`
with `.phaseB/merge_arb.py`, then regenerate `app_localizations.dart`.
Parameterized keys (placeholders typed `Object`, repo convention):
`watchSummaryLine{needs,today,soon}`, `watchDueInDays{days}`,
`watchOverdueByDays{days}`, `watchEnableToSee{source}`.
Until merged, `flutter analyze` reports only the expected missing `watch*`
getters — no structural Dart errors. (Per task: no flutter/build run here.)

### 2. API — NONE required.
Everything composes from existing `api.dart` methods (listed above). api.dart
was intentionally **not** edited (owner constraint).

### 3. Model — NONE required for the aggregation itself.
Optional future hardening (NOT needed for this feature):
- **Server-side feed endpoint.** A `GET /watch/digest` that runs
  `watch_feed.build_feed(...)` over the same signals `_build_alerts` already
  gathers (plus reminders/medicines/subscriptions `days_until`) would let the
  client drop its composition code and cut round-trips. The pure helper is
  ready for this; only the view + url (owner-owned files) remain.
- **Persisted dismiss/snooze.** Currently session-local (`Set<String>` of ids).
  A `WatchDismissal(user, item_key, until)` model would make dismiss/snooze
  survive restarts. Not added (models.py/migrations off-limits per constraint).
  Mark-done/taken already persist via their own existing endpoints.

## Verification done
- `backend`: `python3 -c "import core.logic.watch_feed_tests_snippets as t; t.run_all()"` → **12 tests passed**; registered as `WatchFeedSnippetTests` in `core/tests.py`.
- ARB: 59 keys, all `[bn,en]`, all referenced by the .dart; parameterized placeholders consistent across bn/en.
- **Zero Bangla in any `.dart`** (codepoint scan clean on screen + 3 widgets).
- Tokens: `Gap.*`, `Radii.*`, `Brand.*` only. WCAG tints from brand palette; chat-first deep-links via `ChatNav`.
