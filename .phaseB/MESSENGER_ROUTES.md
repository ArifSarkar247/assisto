# MESSENGER_ROUTES — menu item → route → status → tests (slot m1-messenger)

Status: **works** = real backend + client wired, refusal shown honestly. **honest-disabled** = item shown disabled with the reason (or hidden), because the capability truly does not exist yet.

Backend tests: `core/tests_m1_messenger.py` (B1), `core/tests_m1_routes.py` (B2), `core/tests_route_coverage.py` (B3).
Flutter tests: `test/m1_messenger_api_test.dart` (F1: one per client method, mocked HTTP), `test/m1_messenger_menus_test.dart` (F2: taps a real screen).

## Design choices (E2E)
- Message bodies are E2E ciphertext. **Clear chat** is a per-user marker (`MsgChatPref.cleared_at`); the rows stay for the other side.
- **Export** (group): the server writes a JSON file with only what it holds: metadata, plus the caller's own ciphertext envelope per message. It is served through a signed, expiring `media_sign` link and purged after 2 h. The device decrypts the file and shares the readable `.txt`, so plaintext never goes back to the server.
- **Group AI** sends only the text the user decrypted on the device, on an explicit tap (the same consent as Report-last-5). It runs through `ai.generate`, which handles credits (`ai_msg_cheap`), the budget and the no-key state.
- **Two-step PIN** is held only on the server, as a Django hash. Verify allows 5 tries, then a 15-minute lock. The old on-device plaintext copy is wiped.
- **who_can_message**: `my_circle` (the default) now refuses strangers, as the owner asked. `everyone` holds a stranger's first message in Requests.

## 1:1 chat ⋮ + Contact info
| Item | Route | Status | Tests |
|---|---|---|---|
| Contact info | GET `circle/<id>/info` | works | B1 `ChatInfoClearTests.test_info_*`; F1 contactInfo; F2 contact info ×2 |
| Mute (until / always / off) | POST `circle/<id>/controls {muted_until}` (ISO now parsed; push skips) | works | B1 `test_mute_iso_and_always_and_unmute`, `PushEnforcementTests.test_one_to_one_iso_mute_suppresses_push`; F1 setChatMute |
| Disappearing | POST `messenger/chat/<id>/settings` (partial update, mirrored to peer, purge cron) | works | B1 `test_settings_partial_theme_keeps_timer_and_mirrors`, `PurgeOneToOneTests`; F1 setDisappearing |
| Chat theme | same, `{theme}` (no longer resets the timer) | works | B1 same; F1 setChatTheme |
| Favourite | POST `circle/<id>/controls {favourite}` (+ in members/chats/settings) | works | B1 `test_favourite_persists_and_shows_in_members`; F1 setFavourite |
| Clear chat | POST `circle/<id>/clear` | works | B1 `test_clear_hides_for_me_only`, `test_clear_denied`; F1 clearChat; F2 `1:1 ⋮ Clear chat` |
| Block | `controls {blocked}`. The blocked side's messages are dropped, its calls get `unavailable`, and no push is sent | works | B1 `test_blocked_side_cannot_message_or_call`; F1 blockContact; F2 contact info |
| Starred (contact info) | opens the Starred screen (`messenger/starred`) | works | — |
| Media/links/docs | counts only (E2E: there is no server gallery) | works (read-only) | B1 `test_info_shape_and_counts` |
| Custom notifications, Chat lock | — | hidden: nothing enforces them | F2 contact info (asserts they are gone) |
| Receiver sees peer's messages / acts on them | GET `circle/<id>/messages`, `circle/messages/<id>/<action>` | works (bug fix, same rule as m2) | B1 `test_receiver_now_sees_peer_messages`, `test_receiver_can_star_and_delete_for_me` |

## Group chat ⋮
| Item | Route | Status | Tests |
|---|---|---|---|
| Mute 8h/1w/always/**Unmute** | POST `circle/groups/<g>/mute` | works (push skips muted members) | B1 `GroupMenuTests.test_mute_*`, `PushEnforcementTests.test_group_mute_suppresses_push`; F1 groupSetMute; F2 Mute, Unmute |
| Disappearing | POST `circle/groups/<g>/disappearing` + `purge_disappearing` | works | B1 `test_disappearing_hides_and_purges`, `test_disappearing_denied_and_bad`; F1; F2 Disappearing |
| Chat theme | POST `circle/groups/<g>/theme` | works | B1 `test_theme_and_favourite`; F1; F2 server refusal |
| Favourite | POST `circle/groups/<g>/favourite` | works | B1 same; F1; F2 Favourite |
| Export chat | GET `circle/groups/<g>/export` → signed file → decrypted on the device → share | works | B1 `test_export_signed_file`; F1 groupExport + `buildGroupExportText` |
| Summarise / Translate / Make reminder | POST `circle/groups/<g>/ai/<task>` (reminder books a real `Reminder`) | works; honest no-key / credits state | B1 `test_ai_*` (4); F1 groupAiTask |
| Clear chat | POST `circle/groups/<g>/clear` | works | B1 `test_clear_group_for_me`; F1 groupClear; F2 Clear chat |
| Select → delete / star; react / pin | POST `circle/groups/<g>/messages/<m>/<action>` (nested, checks `g`) | works | B1 `test_group_message_actions_on_screen_path`; B2 `GroupShapeTests.test_nested_message_action_checks_group` |
| Polls vote | POST `circle/groups/<g>/polls/<p>/vote` (nested; old flat route kept) | works | B2 `test_nested_vote_and_group_mismatch` |
| Members promote/demote/remove | POST `circle/groups/<g>/members/<m> {event}` (nested) | works | B2 `test_nested_member_event` |
| Add member | POST `circle/groups/<g>/members {member_id}` (app's edge id now accepted) | works | B2 `test_add_member_by_member_id` |
| Group media | GET `circle/groups/<g>/media` (`backend_ready:false`: no encrypted blob store) | honest-disabled list | B2 `test_group_media_honest` |
| Exit group | POST `circle/groups/<g>/leave`: a 403 last-admin refusal now explained | works | F2 Exit group |
| Group video call | POST `circle/groups/<g>/call`: client now reads `upgrade_required` | gate works; **no group call media UI exists** (toast only) | — |

## Community ⋮
| Item | Route | Status | Tests |
|---|---|---|---|
| Notifications | POST `community/<id>/notifications` (stored, returned in `community/<id>/groups`) | **honest-disabled** in the menu: the server does not relay or push community posts yet | B1 `CommunityMenuTests.test_notifications_toggle_and_reload`; F1; F2 community |
| Leave | POST `community/<id>/leave` (refuses the last admin: 200, allowed:false) | works | B1 `test_leave_member_and_last_admin`; F1; F2 community |
| Message-request inbox | GET `community/message-requests` | works | B2 `test_community_request_inbox_recipient_only` |

## Messenger settings
| Item | Route | Status | Tests |
|---|---|---|---|
| Two-step PIN set/change/off | GET/POST `circle/account/two-step` (current PIN required) | works | B1 `TwoStepTests` (4); F1 twoStep*; F2 two-step |
| Two-step verify | POST `circle/account/two-step/verify` (rate-limited) | works (also required by change-number confirm) | B1 `test_verify_rate_limited` |
| Change number | GET `circle/account/change-number`, POST `/request`, `/confirm`, through `core.otp` (o1-otp) behind an import guard | **honest-disabled** until o1-otp lands and SMS is keyed (503 `sms_not_configured`) | B1 `ChangeNumberTests` (5, incl. full flow with a fake OTP service); F1; F2 change number ×2 |
| Blocked list / unblock | GET `circle/blocked`, controls | works | B1 `PrivacyTests.test_blocked_list`; F1 |
| Message requests list/accept/decline/block/report | GET/POST `circle/message-requests[/<id>]` (real `CommunityMessageRequest` store) | works | B1 `test_everyone_routes_to_requests_then_accept`, `test_decline_block_report`; F1 |
| Who can message | `circle/settings/message-privacy` (enforced in `community/message`) | works | B1 `test_my_circle_rejects_strangers` |
| Notifications (messages/groups/calls/preview) | GET/POST `circle/settings/notifications` (gate the push hooks) | works | B1 `SettingsPrefsTests.test_notifications_roundtrip`, `test_messages_pref_off_and_no_preview`; F2 notifications |
| In-app sound / vibrate | stored | **honest-disabled**: the app plays no in-app sounds | F2 notifications |
| Calls (incoming / silence unknown) | GET/POST `circle/settings/calls` (enforced at call placement + ring push) | works | B1 `test_incoming_calls_off_refuses`, `test_silence_unknown_callers`, `test_calls_roundtrip` |
| Storage usage | GET `circle/settings/storage` (billing meter + the same sources as storage_recompute) | works | B1 `test_storage_real_usage`; F2 storage |
| Auto-download | POST `circle/settings/storage` | **honest-disabled**: chats carry no media yet | F2 storage |
| Chat list | GET `circle/chats` (unread, last envelope, favourite, lists) | works | B2 `test_circle_chats_unread_and_last` |
| Connection requests | GET `messenger/request` (was 405) | works | B2 `test_connection_request_list_both_sides` |
| Channel discover | GET `channels/discover` | works (public channels only) | B2 `test_channel_discover_public_only` |
| Channel photo/video post | — | **hidden**: there is no channel media upload | — |

## Other areas (owner audit list)
| Area | Route | Status | Tests |
|---|---|---|---|
| Family accounting | `family/accounting/summary`, `expenses`, `expenses/delete`, `pool`, `pool/contribute`, `settle` | works. Integer poisha; settle-up runs over all shared expenses, and the server refuses a settle above what is outstanding | B2 `FamAcctTests` (6) |
| Notification centre: Done | POST `notif/reminders/<id>/done` (reminder / recurring / todo / medicine / subscription / event dismiss) | works. Snooze also accepts the app's `preset`/`until` now | B2 `test_notif_done_dispatch`, `test_snooze_accepts_app_preset` |
| Journey timeline | GET `journey/<id>/timeline` (traveller + watchers; points deleted at privacy expiry) | works | B2 `test_journey_timeline_watchers_only` |
| Disaster feed | GET `disaster/feed`: `no_key` plus flagged samples (no official feed integration exists) | honest | B2 `test_disaster_feed_honest` |
| Medicine-DB report | POST `medicine-db/report` → SupportTicket | works (the app no longer thanks the user when sending failed) | B2 `test_medicine_report_persists` |
| Route coverage | every core URL pattern resolves with seeded ids and never returns 500; the owner-audit routes return non-404 | — | B3 (2 tests) |
