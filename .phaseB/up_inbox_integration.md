# AI Inbox (feature 22) — BASIC -> ADVANCED upgrade · integration notes

SPEC v2.1 Section 21. Scope of THIS change (already done, in-repo):

- `app/lib/screens/inbox_screen.dart` — rewritten (advanced; was a static legend).
- `app/lib/widgets/inbox_mock.dart` — NEW (InboxItem model + a Dart mirror of the
  backend triage rules + a small MOCK dataset; Bangla as `\u` escapes only).
- `app/lib/widgets/inbox_item_card.dart` — NEW (triage card: category stripe +
  icon + label, needs-reply pill, per-item actions, bulk-select checkbox).
- `app/lib/widgets/inbox_filter_bar.dart` — NEW (InboxFilter + category/source/
  needs-reply filter chips with counts).
- `app/lib/widgets/inbox_reply_sheet.dart` — NEW (quick-reply sheet, MOCK labels
  + honest key-gated "draft only / connect to send" banner).
- `backend/core/logic/ai_inbox.py` — NEW (pure logic, no Django, no AI, no net).
- `backend/core/logic/ai_inbox_tests_snippets.py` — NEW, `run_all()` = **30 asserts**.
- `backend/core/tests.py` — ONE added line registering `AiInboxSnippetTests`
  (folds the snippet into the Django `run_all` suite, same pattern as the others).
- `.phaseB/up_inbox_arb.json` — **49** NEW bilingual keys `{key:[bn,en]}`.

Nothing in `api.dart`, `app_*.arb`, `models.py`, `urls.py`, `serializers.py`,
`sidebar`/`chatnav`, or any other screen was edited. No migrations, no builds,
no Asalify/CRM.

`flutter analyze` on the five Dart files: the ONLY findings are `undefined_getter`
/ `undefined_method` for the 49 new keys (expected — they live in the ARB until
gen-l10n runs). No other errors/warnings. Zero Bangla codepoints in any `.dart`
(verified `grep -P '[^\x00-\x7F]'` is empty across all five files; the Bangla
keyword banks + the one Bangla mock message are written as `\u09xx` escapes).

---

## (a) l10n — REQUIRED to compile

Merge `up_inbox_arb.json` into `app/lib/l10n/app_en.arb` (index `[1]`) and
`app_bn.arb` (index `[0]`), then `flutter gen-l10n`. Keys are camelCase and map
1:1 to the `tr.*` getters used by the screen/widgets.

REUSED existing getters (already generated; do NOT re-add): `aiInbox`,
`checkInternetRetry`, `retry`.

ONE parameterized key — needs `@`-metadata in BOTH `.arb` files:

```
"inboxSelectedCount": "{count} selected"
"@inboxSelectedCount": { "placeholders": { "count": { "type": "Object" } } }
```

(Same `"type":"Object"` convention the repo already uses for `aiCreditsCount`
etc. The count is an `int`; Bangla digits are rendered at runtime by intl from
codepoints, so no Bangla literal is introduced in `.dart`.)

---

## (b) models.py — NONE required for this change

The advanced UI runs today entirely on MOCK items (`inbox_mock.mockInbox`),
because real inbox items can only come from a connected account (see (e)). No
model is added or changed here.

When real email lands (key-gated, below), the recommended persistence is a thin
`InboxItem`-style row ONLY for user-set state that must survive a refetch —
`snoozed_until`, `done`, `read`, and the source message id — keyed by
`(user, source, source_id)`. Triage itself (`category`, `priority`,
`needs_reply`, `summary`, `replies`) is DERIVED by `core.logic.ai_inbox` on read
and need not be stored. This is a future additive migration (NOT run here).

---

## (c) endpoints

Existing, already wired (unchanged):

- `GET /api/v1/inbox` (`views.InboxView.get`) → `{connected, msg, legend}`.
  `connected = integrations.is_enabled("google_oauth")`. The screen calls this
  via the EXISTING `api.inboxStatus()` and uses `connected` to pick the live vs
  mock banner. No api.dart change.
- `POST /api/v1/inbox` (`views.InboxView.post`) → classifies passed-in items
  (`classify_inbox_item`, the BASIC red/yellow/green). Still works; the advanced
  logic below supersedes it.

Recommended (NOT added here — would need urls/views edits that are out of scope):
re-point `InboxView` at `core.logic.ai_inbox`:

- `GET /inbox` stays the connect-state probe.
- `POST /inbox/triage` → `ai_inbox.triage_list(items, now, ai_key_available=ai.available())`
  returns each item enriched with `category|priority|needs_reply|summary|replies`.
- `POST /inbox/action` → `ai_inbox.apply_bulk(items, ids, action, hours=)` for
  done/snooze/read/unsnooze (validates duration; `ValueError` → 400).
- `POST /inbox/convert` → `ai_inbox.to_task_payload` / `to_reminder_payload`,
  then forward to the EXISTING task/reminder create endpoints (owner confirms).

The Dart mirror in `inbox_mock.dart` reproduces `triage_list` / `sort_by_priority`
/ `active_items` exactly, so swapping mock for a real `/inbox/triage` response is
a drop-in: parse server items into `InboxItem` and skip the local `triage()` call.

---

## (d) the triage engine — deterministic, no AI key

`core.logic.ai_inbox` is pure Python, fully unit-tested (30 asserts via
`ai_inbox_tests_snippets.run_all()`), and is the single source of truth:

- `categorize(item)` → `urgent|action|fyi|promo` (promo detected first so a
  "SALE, reply to claim" is promo not action; then urgent > action > fyi).
  Bilingual keyword banks (EN + Bangla) live in the backend only.
- `needs_reply`, `priority` (0..100 = category base + recency + unread +
  needs-reply, clamped), `_summary` (deterministic sender: subject gist — NOT
  generative), `category_counts`, `filter_items`, `needs_reply_view`,
  `sort_by_priority`, `apply_bulk`, `snooze_until` (valid: 1/3/24/72h),
  `active_items`, `to_task_payload`, `to_reminder_payload`.

No network, no provider call anywhere in this module.

---

## (e) real email + AI drafting — KEY-GATED / mock (honest states)

Two things are gated behind a key the owner has not added; the UI says so plainly
and never fakes them:

1. **Connecting a real account (Gmail OAuth / IMAP).** `GET /inbox.connected`
   is driven by `integrations.is_enabled("google_oauth")`. Until connected the
   screen shows `inboxMockConnectAccount` ("sample inbox … connect an account in
   Integrations") and runs on `mockInbox`. When connected it shows
   `inboxConnectedLive`. No real mailbox is ever read in this module.

2. **AI-DRAFTED replies.** `suggest_replies()` returns canned quick-reply *label
   keys* only (MOCK, deterministic, bilingual via l10n). It takes an
   `ai_key_available` flag but NEVER drafts prose — turning a tapped label into a
   real drafted reply would call the key-gated AI layer (`core.ai`), which the
   logic module deliberately does not touch. In the reply sheet:
   - account connected → `inboxReplyKeyGatedDraftOnly` ("prepared as a draft;
     sending directly needs an AI key").
   - not connected → `inboxReplyConnectToSend` ("connect an email account first").
   Choosing a quick reply only produces a local draft toast (`inboxReplyDraftReady`).

This keeps the FLOW real end-to-end (categorise, filter, needs-reply, snooze,
done, bulk, convert, priority sort) while the two sensitive capabilities stay
key-gated and honestly labelled.

---

## Section-21 states (all 10) — coverage

- **Empty**: `_EmptyState` — two honest variants ("Inbox zero" + hint when truly
  empty; "Nothing in this filter" + "pick another filter" when a filter hides all).
- **Loading**: `SkeletonList` on first load and on pull-to-refresh.
- **Error**: `_ErrorState` (cloud-off icon, `inboxLoadFailed`, `checkInternetRetry`,
  Retry button that re-runs `_load`).
- **Bilingual**: every visible string is a `tr.*` getter present in
  `up_inbox_arb.json` as `[bn, en]`; zero Bangla literals in `.dart`.
- **WCAG**: category is ALWAYS shown as colour + icon + text label (never colour
  alone); tap targets ≥ 44px; snooze/done/convert via tooltipped icon buttons
  with text labels in the sheet; contrast uses theme `on*` colours.
- **Scenario / honest**: connect-account mock state, key-gated reply draft state,
  undo on mark-done, snooze returns items after the window — all explicit.

---

## advanced-vs-before

```
before = a single STATIC screen: a non-interactive red/yellow/green legend + a
         "Available when Gmail is connected" card. No items, no list, no actions,
         no filters, no summaries, no replies, no priority, no bulk — nothing to do
         until an account was connected. Backend = one 3-way keyword classifier.

after  = a unified smart inbox (email + notifications + messages) that WORKS today
         on mock data: AI-style deterministic categorise (urgent/action/FYI/promo)
         with per-item summary, priority 0..100 sort, a "needs reply" view, filter
         chips by category/source with live counts, per-item quick-reply (mock) +
         snooze (1h/3h/1d/3d) + mark-done (with undo) + convert-to-task/reminder,
         multi-select BULK done/snooze, full empty/loading/error states, bilingual
         + WCAG, an honest key-gated "connect account" + "draft only" posture, and
         a pure, 30-assert-tested backend triage engine (core.logic.ai_inbox) ready
         to serve real items the moment an account/key is added.
```
