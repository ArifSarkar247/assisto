# up_msggroup — Messenger group chat + media share → Section-21 "advanced"

Reviewer-pass elevation of two messenger surfaces (#84 group create/edit/manage,
#85 media share). The screens were already rated "good"; this pass adds the §21
honest-state layer (loading / empty / error+retry), destructive-action confirm
gates, failed-send/retry, and honest download/offline-cache indication. No
screens were rebuilt. E2E stays ciphertext-only; media remains key-gated where
storage isn't provisioned (no fake pickers, no weakened crypto).

## Files changed

### Flutter (app/lib)
- `screens/circle_group_info_screen.dart` (#84)
  - `_load()` now sets/clears a `_loadFailed` flag → honest **error + Retry**
    body (`_errorRetry`) instead of a silent blank list.
  - New `_run()` busy-gate wrapper: every mutating action (edit info, size
    limit, announcements, add/remove/promote/demote, invite, leave, report) runs
    through it, shows a blocking busy overlay, and toasts `grpActionFailed` on
    failure instead of swallowing the exception.
  - **Confirm gates** added for destructive member actions: `_memberAction`
    now confirms `remove` and `demote` via `_confirmDestructive(...)` (promote is
    additive, no gate). Leave already had a confirm — kept.
  - Add-members reports an **honest result** (`grpAddMembersResult(added,failed)`)
    instead of assuming every add succeeded.
  - Announcements toggle is optimistic + **reverts on failure**.
  - **Empty-member** state (`grpRosterEmpty`) rendered when the roster is empty.
  - Edit-info success toasts `grpGroupSaved`; invite/report give honest
    success/fail feedback (no empty catches left).
- `screens/circle_group_chat_screen.dart` (#84)
  - `_load()` sets `_loadFailed` (only when no messages are already shown) →
    `_errorRetry()` body with Retry.
  - `_send({resendText})`: **honest failed-send** — keeps the text in
    `_failedText`, renders a `_failedSendBanner()` above the composer with
    **Resend** + dismiss; guards the no-recipients case (`grpNoRecipients`).
  - `_deleteSelected()`: **confirm gate** (`grpConfirmDeleteMsgs*`) before
    deleting selected messages; counts failures and toasts `grpActionFailed`.
- `widgets/group_menu_media.dart` (#85)
  - Distinguishes a **transient fetch error** (`_loadFailed` → `_errorRetry` +
    Retry) from the key-gated pending-empty (`backend_ready:false`).
  - Per-cell **download/cache affordance** (`_cacheLabel`): cached / download /
    download-again / gated, with a matching icon — mirrors
    `circle_media.cache_status`.
- `widgets/circle_media_viewer.dart` (#85)
  - `MediaViewerItem` gains `onDownload`, `cachedLocally`, and `needsDownload`.
  - Full-screen viewer now shows a **Download** affordance when a blob is on the
    relay but not yet on-device, and an **honest disabled-reason** snackbar
    (`circleMediaSavingSoon`) when Save is tapped on a still-gated item (was a
    dead-disabled icon). 1:1 call sites unaffected (new params default).

### Backend (backend/core/logic) — pure helpers + self-tests
- `circle_media.py` (#85): added an outgoing-media **send-state machine** and
  pre-send guards + offline-cache classifier:
  - `SEND_STATES`, `RETRYABLE_STATES`, `TERMINAL_STATES`, `can_transition_send`,
    `is_retryable_send`, `next_send_state(current,event,attempts,max_attempts)`,
    `send_state_label`, `upload_progress_pct(sent,total)` (clamped 0..100).
  - `precheck_media_send(kind,nbytes,hd,ext,duration_sec,lang)` → (ok, reason):
    one call enforcing gate + size cap + supported-doc + voice/video duration.
  - `cache_status(blob)` → gated|cached|expired|downloadable; `cache_status_label`.
- `circle_groups.py` (#84): added §21 copy + state helpers:
  - `confirm_copy(action,name,lang)` → {title,body,confirm} for
    leave/remove/demote/delete_messages/clear_chat/report (keeps server-side and
    client confirm copy consistent).
  - `roster_state(members,loaded,failed)` → loading|error|empty|ready
    (precedence error>loading>empty>ready); `roster_empty_notice`,
    `roster_error_notice`.
- `circle_media_tests_snippets.py`: +10 tests (send-state happy/error/retry/
  exhaust/cancel/illegal, labels, progress clamp, precheck gate/type, cache).
- `circle_groups_tests_snippets.py`: +5 tests (confirm copy ×3, roster state ×2).

## New ARB keys (emit: `.phaseB/up_msggroup_arb.json`, 23 keys)

`grpRetry`, `grpRosterEmpty`, `grpInfoLoadError`, `grpConfirmRemoveTitle`,
`grpConfirmRemoveBody` {name}, `grpConfirmRemove`, `grpConfirmDemoteTitle`,
`grpConfirmDemoteBody` {name}, `grpConfirmDemote`, `grpConfirmDeleteMsgsTitle`,
`grpConfirmDeleteMsgsBody` {n}, `grpConfirmDelete`, `grpActionFailed`,
`grpGroupSaved`, `grpAddMembersResult` {added}{failed}, `grpSendFailed`,
`grpSendRetry`, `grpNoRecipients`, `grpMediaLoadFailed`, `grpMediaDownload`,
`grpMediaCached`, `grpMediaDownloadAgain`, `circleActionDownload`,
`circleMediaSavingSoon`.

`_params`: `grpConfirmRemoveBody{name}`, `grpConfirmDemoteBody{name}`,
`grpConfirmDeleteMsgsBody{n}`, `grpAddMembersResult{added,failed}`.

Reused existing getters: `circleBackendPending`, `circleReported`,
`circleLinkCopied`, `cancel`, `close`, `grpMediaGated`, `grpMediaEmpty`,
`circleMediaGenericGated`, `circleActionSave`, `circleActionForward`,
`circleGroupMemberCount`, etc.

## New endpoints
None. All UI uses already-documented seams in the screen headers
(`/circle/groups/<id>` + `/members`, `/messages`, `/media`, `/leave`, `/report`,
`/invite`, `/size-limit`, `/announcements`). Suggested (optional) response field:
the group-media endpoint may return `backend_ready:false` (key-gated pending) and
per-item `cached_locally` / `cache_expired` so the UI renders `cache_status`
honestly; absent, the UI falls back to the gated label.

## Model needed
None new. (Media blob storage is still key-gated; when the encrypted bucket is
provisioned, wire the real picker/upload to drive `next_send_state` and populate
`MediaViewerItem.bytes`/`onDownload`.)

## Tests added
15 new snippet tests (10 circle_media, 5 circle_groups), already wired via the
existing `_make_snippet_case` entries `CircleMediaSnippetTests` /
`CircleGroupsSnippetTests` in `core/tests.py` — no new registration needed.
Verified locally: `circle_media: 32 tests passed`, `circle_groups: 60 tests passed`.

## Wiring steps (integrator)
1. Merge `.phaseB/up_msggroup_arb.json` into `app_en.arb` / `app_bn.arb` and
   regenerate `app_localizations*.dart` (the 23 new getters resolve then).
2. No migrations, no new endpoints, no model changes.
3. When encrypted media storage flips on: have the chat pass real
   `MediaViewerItem.bytes` / `onDownload` and drive outgoing media through
   `circle_media.next_send_state` for live upload progress + failed/retry.
