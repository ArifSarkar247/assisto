# Messenger #93 (Communities) + #94 (Channels) — reviewer-pass to §21 ADVANCED

Reviewer-pass, NOT a rebuild. Both messenger surfaces were already substantially
built (including the pure backend authority in `msg_community.py` /
`msg_channel.py`, which was already advanced and invariant-correct). This pass
closes the Section-21 gaps the reviewer would flag: **confirm gates on every
destructive action, honest loading/empty/error+retry states on every list, no
raw exception strings leaked to users, a readable (not just editable) community
rules surface, bn/en for every new string, and self-tests that lock the
UI-relied server invariants** (count-only-is-default follower privacy; a forged
`verified` flag reads as NOT verified).

No edits to `api.dart`, `messenger_community_api.dart`, `messenger_channel_api.dart`,
`core/models.py`, `core/urls.py`, the sidebar, `app_en.arb` / `app_bn.arb`,
migrations, or Asalify. New ARB keys are emitted to `up_commchan_arb.json` for
the integrator's merge step (the standard pipeline that regenerates
`app_localizations*.dart`).

---

## Files changed

### Flutter (app/) — #93 Community
- `app/lib/screens/messenger/community_detail_screen.dart`
  - **Confirm gates**: admin **Approve** and **Reject** of a member join request
    now go through a shared `_confirm()` dialog (Reject is danger-styled). Both
    surface an honest `communityActionFailed` toast on failure instead of a
    silent `catch (_) {}`.
  - **Error+retry state**: `_load()` now distinguishes an `ApiException` (real
    request failed → retryable `communityLoadError` + Retry button via
    `_errorRetry`) from "no backend yet" (friendly pending). Previously any
    failure collapsed into an empty/pending list with no recourse.
  - **Readable rules**: a new `_viewRules()` dialog lets **every member read**
    the group rules (`communityRulesTitle` / `communityRulesEmpty`), with an
    admin-only "edit" shortcut. The group card trailing menu now shows
    "View rules" for everyone (`communityViewRules`) and keeps the admin-only
    edit-rules / set-size items. (Before, rules could only be *edited* by admins
    and never *read* by members — an honest-state gap.)
- `app/lib/screens/messenger/community_members_screen.dart`
  - **Confirm gate** on admin **Remove member** (danger-styled), plus an honest
    refusal toast for the server's last-admin protection
    (`communityRemoveLastAdmin`, read from `removed/allowed == false`) and a
    generic `communityActionFailed` on error.
  - **Error+retry state** (`_errorRetry`) mirroring the detail screen.
- `app/lib/screens/messenger/community_message_requests_screen.dart`
  - **Confirm gates** on **Decline** and **Block** (Block danger-styled) via a
    shared `_confirm()`; honest failure toasts.
  - **Error+retry state** (`_errorRetry`).

### Flutter (app/) — #94 Channel
- `app/lib/screens/messenger/channel_detail_screen.dart`
  - **Confirm gate** on **Unfollow** (danger-styled, names the channel).
  - **Error+retry state**: `_load()` separates `ApiException` (retryable
    `channelLoadError` via `MsgrEmptyState` + Retry) from "no backend yet".
  - **Honest errors**: every `catch (e) … Text('$e')` replaced with a localized
    `channelActionFailed` toast (`_react`, `_vote`, `_toggleMute`, `_unfollow`,
    `_share`, `_editMyVisibility`, `_requestVerify`, follow button).
  - Verified badge rendering unchanged — still driven by `is_verified` provenance
    from the server; UI never self-claims it.
- `app/lib/screens/messenger/channel_list_screen.dart`
  - **Confirm gate** on the list-row **Unfollow** branch of `_toggleFollow`.
  - **Error+retry state** at the top of `_body` when a load `ApiException`
    leaves both sections empty.
  - **Honest errors**: raw `'$e'` in the follow toggle and the create-channel
    sheet replaced with `channelActionFailed`.
- `app/lib/screens/messenger/channel_admin_screen.dart`
  - **Confirm gates**: **Unpin post** (`channelUnpinTitle`/`channelUnpinConfirm`)
    and **Remove admin** (danger-styled, `channelRemoveAdmin*`).
  - **Honest errors**: all seven `catch (e) … Text('$e')` sites replaced with
    `channelActionFailed`.
  - Analytics tab (counts-only, no PII) and owner-only verification *request*
    (never self-grant) unchanged — already correct.

### Backend (backend/core/logic/) — pure, no DB, no AI
No new production logic was needed: `msg_community.py` and `msg_channel.py`
already implement every rule the UI depends on (approve/remove gates, join &
message-request FSMs, consent routing, rate limit, phone-hidden-by-default;
follower count-only default, `serialize_follower_list` that never leaks a
count-only follower, operator-only `grant_verification`, `is_verified`
provenance check, PII-free `channel_analytics`). The pass added **self-tests**
that lock the invariants the new UI relies on and **wired the existing snippet
suites into the Django test runner** (they existed but were never registered).

- `backend/core/logic/msg_community_tests_snippets.py` — +5 reviewer-pass tests
  (`test_rp_*`): remove-self-is-leave, cannot-remove-last-admin,
  non-admin-cannot-approve-or-remove, approve-refused-when-full/not-pending,
  block-is-terminal-for-sender. (34 → 39 tests.)
- `backend/core/logic/msg_channel_tests_snippets.py` — +4 reviewer-pass tests
  (`test_rp_*`): new-follower-count-only-default (+never-listed-even-to-owner),
  unfollow-decrements-count, verified-badge-requires-recorded-operator (forged
  flag reads NOT verified), analytics-carry-no-PII. (34 → 38 tests.)
- `backend/core/tests.py` — registered both suites via the existing
  `_make_snippet_case` pattern as `MsgCommunitySnippetTests` and
  `MsgChannelSnippetTests` (the Django runner now collects all 77 as individual
  test methods).

---

## New ARB keys (23) — see `up_commchan_arb.json`

Format `{"key": ["<bn>", "<en>"]}`. Parameterized keys list placeholders in the
`_params` object; `{name}` appears in both bn and en.

Community (14): `communityApproveConfirm`{name}, `communityRejectConfirm`{name},
`communityRemoveMember`, `communityRemoveMemberTitle`,
`communityRemoveMemberConfirm`{name}, `communityRemoveLastAdmin`,
`communityLoadError`, `communityRulesTitle`, `communityRulesEmpty`,
`communityViewRules`, `communityDeclineTitle`, `communityDeclineConfirm`{name},
`communityBlockTitle`, `communityBlockConfirm`{name}.

Channel (9): `channelActionFailed`, `channelLoadError`, `channelUnfollowTitle`,
`channelUnfollowConfirm`{name}, `channelRemoveAdmin`, `channelRemoveAdminTitle`,
`channelRemoveAdminConfirm`{name}, `channelUnpinTitle`, `channelUnpinConfirm`.

`_params`: `communityApproveConfirm`, `communityRejectConfirm`,
`communityRemoveMemberConfirm`, `communityDeclineConfirm`, `communityBlockConfirm`,
`channelUnfollowConfirm`, `channelRemoveAdminConfirm` — all `["name"]`.

Reused existing keys (not re-added): `retry`, `close`, `cancel`, `save`,
`channelCancel`, `channelUnpin`, `communityActionFailed`,
`communityBackendPending`, `channelsBackendSoon`, `communityApprove`,
`communityReject`, `communityRequestDecline`, `communityRequestBlock`,
`communitySetRules`, `communitySetSizeLimit`, `channelUnfollow`.

---

## New endpoints (method + path)

**None.** This reviewer-pass adds no endpoints. All actions reuse existing
`ApiClient` helpers in the off-limits API files:
- Community: `communityGroups` (GET `/community/<id>/groups`),
  `joinRequestApprove` / `joinRequestReject`
  (POST `/community/join-request/<id>/approve|reject`), `communityMembers`
  (GET `/community/<id>/members`), `communityMemberRemove`,
  `/community/message-requests` (GET), `messageRequest{Decline,Block,...}`.
- Channel: `channelGet`, `channelList`, `channelFollow` / `channelUnfollow`,
  `channelSetMuted`, `channelMyVisibility`, `channelPinPost`, `channelSetAdmin`,
  `channelShareLink`, `channelRequestVerification`, `channelAnalytics`.

---

## Model needed

**None.** The existing community/channel/follower/join-request/message-request
rows already carry every field the UI reads (`rules`, `verified` + `verified_by`,
`verification_state`, follower `visibility` with a count-only default,
`list_visibility`). The last-admin honest toast relies on the remove endpoint
returning `removed`/`allowed == false` (already the server contract in
`can_remove_community_member`); no schema change.

---

## Tests added

- 5 new `test_rp_*` in `msg_community_tests_snippets.py` (total 39, all pass via
  `run_all()`).
- 4 new `test_rp_*` in `msg_channel_tests_snippets.py` (total 38, all pass via
  `run_all()`).
- Both suites now wired into `core/tests.py`; the Django runner collects
  **77** methods (`MsgCommunitySnippetTests` + `MsgChannelSnippetTests`). The
  sandbox cannot create the test DB (no CREATE DATABASE permission), but
  collection succeeds and the pure logic passes via the key-free `run_all()`
  smoke runners:
  `python3 -c "import core.logic.msg_community_tests_snippets as t; t.run_all()"`
  and likewise for `msg_channel_tests_snippets`.

---

## Wiring steps (integrator)

1. Merge `up_commchan_arb.json` into `app_en.arb` / `app_bn.arb` using the
   existing merge tool (e.g. `.phaseB/merge_arb.py` / `bin/arbify*.py`), then
   regenerate `app_localizations*.dart` with `flutter gen-l10n`. All 23 getters
   referenced by the six screens come from that step.
2. `flutter analyze` the six touched screens (expected clean once the keys are
   merged; before merge, the new getters resolve as "undefined" — that is the
   normal pre-merge state for an `up_*_arb.json` pass).
3. Backend tests run as part of `manage.py test core` on a DB-capable host
   (`MsgCommunitySnippetTests`, `MsgChannelSnippetTests`).

---

## Confirmations

- **Zero Bangla literals** (U+0980–U+09FF) in any of the six `.dart` files
  touched — verified by grep.
- **Zero raw exception strings** (`Text('$e')`) left in the six target screens.
- **Follower count-only is the privacy DEFAULT** — proven by
  `test_rp_new_follower_count_only_is_the_default` (new follower is count_only
  and is omitted from the listing even for the owner, while still counted).
- **Verified badge requires a recorded operator approver** — proven by
  `test_rp_verified_badge_requires_recorded_operator` (a forged
  `verified=True, verified_by=None` reads as NOT verified via `is_verified`).
- **Every destructive action confirms**: approve/reject join requests, remove
  community member, decline/block message request, unfollow channel (detail +
  list), unpin post, remove channel admin.
- Original Assisto identity throughout (brand tokens + Material icons; no Meta
  copy).
