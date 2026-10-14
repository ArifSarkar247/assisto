# OWNER-ADMIN surfaces — GOOD → ADVANCED (SPEC v2.1 §21)

Raises the two owner/operator admin surfaces to the Section-21 advanced bar:

- **#174 User info (admin)** — `app/lib/screens/messenger/admin_users_screen.dart`
- **#175 Complaint & moderation queue** — `app/lib/screens/messenger/admin_moderation_screen.dart`
  (+ appeal review on the item detail, + user-facing appeal screen
  `moderation_appeal_screen.dart`)

UI-only. **No** edits to `api.dart`, core/models/urls/sidebar, backend, or
`app_*.arb`. **No** flutter/build/migrations. Asalify untouched. The existing
backend engine (`backend/core/logic/msg_moderation.py`) and client surface
(`app/lib/messenger_admin_api.dart`) are reused as-is — every advanced behaviour
is built on the endpoints already documented in `msg_moderation_integration.md`.

## Files

Edited (allowed surface only):
- `app/lib/screens/messenger/admin_users_screen.dart` — rewritten to advanced.
- `app/lib/screens/messenger/admin_moderation_screen.dart` — rewritten to advanced.
- `app/lib/screens/messenger/moderation_appeal_screen.dart` — added the
  "records kept for legally-required reporting" note (reuses the new widget).

New (allowed `widgets/admin_*`):
- `app/lib/widgets/admin_filter_bar.dart` — `AdminFilterRail`, `AdminListHeader`
  (result-count + sort button), `AdminSortSheet` (bottom-sheet sort picker),
  `AdminChoice`.
- `app/lib/widgets/admin_notes.dart` — `AdminPrivacyNote` (never-sees-content/
  contacts), `AdminLegalNote` (records-kept), `AdminTimelineEntry`
  (reviewer-grade append-only audit rail).

## l10n

Merge `up_admin_arb.json` via `merge_arb.py`: copy its 20 `key: [bn, en]`
entries into the `K` dict, then add the two parameterized keys to `PARAMS`:

```python
PARAMS["msgrModResultsCount"] = ["count"]
PARAMS["msgrModActionDone"]   = ["action"]
```

(The JSON carries a `_params` block documenting exactly this.) All existing
`msgrMod*` keys are reused untouched. **Zero Bangla in any `.dart`** — every
human string resolves through `AppLocalizations`; Bengali digits are rendered
from code points.

## Advanced — what changed vs. before

**#174 Users (admin)**
- Search now has a clear button; a `tune` filter button carries an active-filter
  badge.
- Server-side **status** filter rail (all / active / suspended / banned) with
  icons; **client-side** plan filter + "reported users only" toggle in a filter
  sheet (plans discovered from the loaded set — no guessed values).
- **Sort** picker: most recent (last-active) / most reported / name.
- Honest **result-count header** ("N results") + current sort label.
- **Pagination**: client-side "Show more" in pages of 20 so large result sets
  stay responsive (the API returns a projection list; no private over-fetch).
- Reported users get a subtle warning-tinted card border in the list.
- Per-user detail: public projection + the user's **public channels/communities**
  with its own loading / **error+retry** / empty states; privacy note repeated.
- Actions suspend / unsuspend / reset-sessions / ban — mandatory reason +
  confirm (unchanged dialog) **+ a success snackbar** naming the action.

**#175 Moderation queue**
- **Severity grouping**: in the default "By severity" sort the queue renders a
  **"Severe — auto-hidden"** group FIRST (visible subheader), then "Other
  reports"; severe cards also get a thicker danger border. Alternate sorts:
  most reported / most recent.
- Honest **result-count header** + sort picker.
- Filters gain icons (severe / legal / appeals).
- Item detail: **legal-retention note** ("records kept for legally-required
  reporting") shown when the item is flagged; an **appeal banner** when the item
  is `under_appeal`, prompting re-decide/reopen; **Reopen** is offered for both
  resolved and under-appeal items (the appeals-review loop).
- Actions Remove / Restore / Warn / Suspend / Ban — mandatory reason + confirm
  **+ success snackbar**; audit reloads after each.
- **Audit trail** upgraded to a connected **timeline** with a per-action
  icon/colour and an explicit "append-only — can't be edited or deleted" note.

## Section-21 acceptance (all 10, each screen)

1. **Equal-or-better** than a category-leading admin/trust-&-safety console:
   severity-first queue, mandatory-reason audit, appeals loop, public-only
   projection.
2. **Full task flow** end to end: search / filter / sort / paginate / open /
   act / reopen — not view-only.
3. **Both rails**: reports arrive automatically (severe→auto-hide, mass→auto-hide
   via the backend engine) and admins act manually; auto-hidden items are
   surfaced and labelled as such (the "AI/auto-captured" analogue for a mod queue).
4. **Empty / loading / error / admins-only** states all designed; the public-
   channels panel has its own loading/error/empty; offline → honest error+retry.
5. **bn/en** strict (zero Bangla in source, Bengali digits via code points),
   light/dark via `ColorScheme`, small & large screens (wrap/scroll/paginate).
6. Reached from the Settings admin section, gated by `moderationWhoAmI`;
   actions flow through the audited endpoints (wired into the moderation engine).
7. Backend logic has server tests (`msg_moderation_tests_snippets.py`, 34
   passing incl. scenario tests); UI states are deterministic from API shapes.
8. **Result cards**: each user/queue entry is a self-contained status card with
   pills (status / severe / legal / report-count).
9. **Privacy + consent honoured**: `AdminPrivacyNote` on every surface; backend
   `admin_user_projection` strips contents/contacts via an allow-list; every
   action writes an append-only audit row shown in the timeline.
10. **Reviewer-ready**: honest states, no dead ends, mandatory reasons enforced
    in the dialog (confirm disabled until a reason is typed), 403 → admins-only.

## Privacy / safety guarantees (reinforced)

- **Admin NEVER sees message contents or contact lists.** The UI shows only the
  allow-listed public fields; the backend (`ADMIN_USER_PUBLIC_FIELDS` /
  `ADMIN_FORBIDDEN_FIELDS`) builds the projection from an allow-list, so no code
  path can leak private data. The standing `AdminPrivacyNote` states this on the
  users list, the user detail, the queue, and each item.
- **Mandatory reason** on every destructive/moderation action — `MsgrModActionDialog`
  keeps confirm disabled until a non-blank reason is typed; the backend also
  rejects a blank reason (`apply_admin_action` / `admin_user_action`).
- **Severe-first**: severe + auto-hidden items render at the top of the queue.
- **Appeals**: user-facing appeal screen + reviewer appeal banner + reopen.
- **Operator/owner-gated**: entry points hidden unless `moderationWhoAmI`; both
  screens render a dedicated admins-only / owner-only state on a 403.

## No backend wiring required

Everything degrades gracefully on today's endpoints. Optional niceties the
integrator MAY add later (not needed for advanced): server-side pagination/sort
params on `/admin/users` (the UI already paginates client-side), and a
`can_appeal`-aware "appeal expired" hint on the appeal screen (the server
already enforces the window and the UI surfaces its error honestly).
