# up_statuscall — MESSENGER #88 Status + #91 Call settings → ADVANCED (§21)

Reviewer-pass (not a rebuild). The feature code already existed and was strong;
this pass closed the §21 honesty / confirm-gate / error-retry gaps and added
pure backend helpers + self-tests. Backend defaults left conservative; shared
`default_visibility()` / `default_call_privacy()` were NOT mutated (other screens
rely on them) — new stricter helpers were added alongside.

## Files changed

### Flutter (app/lib)
- `screens/circle_status_screen.dart` (#88 tray)
  - Added honest `_errored` state: a tray fetch failure now renders a dedicated
    error + Retry (`_ErrorRetry` widget) instead of silently showing the empty
    "no updates" state. Empty now truthfully means "genuinely nothing".
- `screens/circle_status_composer_screen.dart` (#88 composer)
  - Post-failure snackbar now uses `statusPostFailed` (honest) instead of the
    unrelated `statusNoUpdates` copy; typed text is preserved so nothing is lost.
- `screens/circle_status_viewer_screen.dart` (#88 viewer)
  - Mute now goes through a confirm gate (AlertDialog) using
    `statusMuteConfirm(name)`, honestly stating the author is not notified;
    auto-advance is paused during the dialog and resumed on cancel.
- `screens/circle_privacy_screen.dart` (#91 call settings / privacy)
  - Added honest `_errored` load state: a settings fetch failure renders an
    error + Retry (`circlePrivacyLoadFailed`) instead of silently presenting the
    safe defaults as if they were the owner's real saved policy.
  - `_save` is now honest: on failure it shows `circlePrivacySaveFailed` and
    keeps the form dirty (for retry) instead of falsely claiming "saved".
  - Added `_onCallPolicyChanged`: a confirm gate (§21) before switching INTO a
    restrictive call policy (nobody / chosen / relations) from `everyone`.
    Uses `circleCallNobodyConfirm` (explicitly mentions family) or
    `circleCallRestrictConfirm`, with `circlePrivacyConfirm` / existing `cancel`.

NOTE: api.dart, core/models.py, core/urls.py, sidebar, app_*.arb, migrations and
Asalify were NOT touched. Widgets `circle_privacy_controls.dart` /
`circle_status_audience.dart` unchanged (selector wired via existing onChanged).

### Backend (backend/core/logic)
- `circle_status.py` — added pure helpers (no DB, no model change):
  - `conservative_default_visibility()` → family-only safe default for the
    composer's pre-selection (original `default_visibility()` left as circle).
  - `tray_state()` / `tray_state_label()` → honest state machine
    (loading/error/empty/ready); error is never conflated with empty.
  - `expired_notice()` → honest viewer copy for an expired status.
  - `mute_confirm(author_name)` → confirm-gate copy (bilingual), promises the
    author is not notified.
- `circle_privacy.py` — added pure helpers:
  - `call_policy_label_hint(policy)` → honest one-line consequence per option.
  - `call_policy_is_restrictive(policy)` → true for nobody/chosen/relations.
  - `call_policy_confirm(policy)` → confirm-gate copy (None when not needed;
    the "nobody" variant explicitly names family).
  - `privacy_load_failed_notice()` → honest load-failure copy.

### Tests (wired into core/tests.py via `_make_snippet_case`)
- `circle_status_tests_snippets.py`: +5 tests (32 → **37**):
  conservative default, tray_state error≠empty, tray labels, expired notice,
  mute confirm naming + non-notification.
- `circle_privacy_tests_snippets.py`: +4 tests (37 → **41**):
  call hints bilingual, restrictive flag, confirm gate (nobody mentions family),
  load-failed notice.
- `core/tests.py`: **wired the previously-missing** `CircleStatusSnippetTests`
  (`circle_status_tests_snippets`) next to the existing
  `CirclePrivacySnippetTests`. Both now run under Django's test runner.
  Verified: 37 + 41 tests pass; `tests.py` parses.

## New ARB keys → /home/ubuntu/assisto/.phaseB/up_statuscall_arb.json

8 new keys (format `{"key":["<bn>","<en>"]}`), 1 parameterized:

| key | params |
|-----|--------|
| statusLoadFailed | — |
| statusPostFailed | — |
| statusMuteConfirm | `{name}` (in `_params`) |
| circlePrivacyLoadFailed | — |
| circlePrivacySaveFailed | — |
| circlePrivacyConfirm | — |
| circleCallNobodyConfirm | — |
| circleCallRestrictConfirm | — |

Reused existing getters: `retry`, `save`, `cancel`, plus all prior status/
privacy keys.

## New endpoints
None. All changes are UI-state + copy over existing seams
(`GET/POST /circle/privacy`, `GET /circle/status`, status view/mute endpoints).

## Model / migration needed
None. All new backend logic is pure (plain dict/value in → decision out). The
existing status/privacy JSON policy payloads already carry everything used.
(No new model is required for this pass — nothing added per the constraint.)

## Wiring steps for the integrator
1. Merge the 8 keys from `up_statuscall_arb.json` into `app_en.arb` / `app_bn.arb`
   (with the `_params` → `statusMuteConfirm: ["name"]` entry so codegen emits a
   `String statusMuteConfirm(String name)` method), then regenerate
   `app_localizations.dart` (`flutter gen-l10n`). The 4 edited screens already
   reference these getters.
2. `core/tests.py` already references `CircleStatusSnippetTests` — no further
   wiring; run `python manage.py test core` (or the two `run_all()` smokes).
3. Optional (not required for compile): the backend reviewer helpers
   (`tray_state`, `call_policy_confirm`, `conservative_default_visibility`, …)
   are available for the views to serve server-authoritative copy/state; the
   Flutter screens currently derive the same states client-side from the honest
   error flags, matching the existing per-screen pattern.

## Report summary
- Files touched: 4 Dart screens, 2 backend logic modules, 2 snippet test
  modules, `core/tests.py` (wiring) = 9 files; +2 phaseB artifacts.
- ARB keys: 8 new (1 parameterized).
- Tests: +9 (status 32→37, privacy 37→41) + newly wired status snippet case.
- Zero Bangla literals in any `.dart` (U+0980–U+09FF scan clean on all 4 files).
