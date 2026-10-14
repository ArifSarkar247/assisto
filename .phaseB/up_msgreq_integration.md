# Integration note — Message requests (#95) + Messenger message-level privacy (#96)

Reviewer-pass to the Section-21 "advanced" standard. **Not a rebuild** — the
existing stubs in `msgr_set_privacy_screen.dart` were elevated in place and the
pure backend helpers were extended, not replaced. Everything is disjoint from
the just-shipped `circle_privacy_screen.dart` (see the overlap proof at the end).

## Scope delivered
- **#95 Message requests**: a requests inbox for first messages from
  non-contacts, per-request **accept / decline / block / report (with reason)**,
  and a **conservative "who-can-message" default** (`my_circle` — a stranger's
  first message is held in a separate requests box and never notifies until the
  owner accepts). Honest loading / error-retry / empty states.
- **#96 Message-level privacy** (non-overlapping with circle_privacy):
  **who-can-message default** selector (conservative, confirm gate when
  *loosening*), **phone-number-hidden-by-default** toggle, and the **blocked
  list with unblock** (confirm gate). Honest states throughout.

## Files changed
| File | Change |
|---|---|
| `backend/core/logic/msg_contacts.py` | Added the message-request / message-privacy pure helpers (constants, routing, action resolution, labels, confirm, honest notice). No existing function touched. |
| `backend/core/logic/msg_contacts_tests_snippets.py` | Added 11 self-test functions + imports. |
| `backend/core/tests.py` | Wired `MsgContactsSnippetTests = _make_snippet_case("core.logic.msg_contacts_tests_snippets", "MsgContactsSnippetTests")` (it was not previously registered). |
| `app/lib/messenger_setapi.dart` | Extended `messageRequestAct` with `reason`/`alsoBlock`; added `messagePrivacy()` + `setMessagePrivacy()` extension methods. **api.dart untouched.** |
| `app/lib/screens/messenger/msgr_set_privacy_screen.dart` | Elevated: new `MsgrSetMessagePrivacyScreen` (who-can-message + phone-hidden, confirm gate, honest load/error/retry/save), block+report-with-reason + honest error on the requests screen, unblock confirm + honest error on the blocked list, shared `_ErrorRetry` / `_EmptyState` honest-state widgets. |

**Not touched** (per constraints): `api.dart` request helpers, `core/models.py`,
`core/urls.py`, sidebar, `app_en.arb` / `app_bn.arb`, migrations, Flutter builds,
Asalify.

## New backend logic (pure, no DB, no AI) — `msg_contacts.py`
- `WHO_MSG_CIRCLE|EVERYONE|NOBODY`, `WHO_MSG_POLICIES`
- `default_who_can_message()` → `my_circle` (conservative) · `normalize_who_can_message()` (fail-closed to safe default)
- `default_phone_hidden()` → `True` (conservative)
- `message_request_routing(is_circle_member_already, is_blocked, who_can_message)` → `{inbox, notify, accepted, reason}` — the **stranger gate**: members → `normal`+notify; strangers → `requests`+**no notify** (or `None` refused under `nobody`); blocked → dropped.
- `MSG_REQ_ACCEPT|DECLINE|BLOCK|REPORT`, `act_on_message_request()` (fail-closed validation)
- `apply_message_request_action(owner_state, sender_id, action, reason, note, lang)` → `{ok, action, blocked, directive, message}` — accept promotes (no block); decline is **silent, not a block**; block adds to the set; report reuses `block_or_report_on_request` (harsh reasons **auto-block**).
- `who_can_message_label/hint`, `who_can_message_loosening(old,new)`, `who_can_message_confirm(new,lang)` (None for the safest), `message_privacy_load_failed_notice(lang)`

## New endpoints the integrator must wire (server authoritative)
All under the existing `/circle` mount; **no new urls.py edit was made here** —
the integrator adds the routes. The client already calls these paths:
| Method · Path | Body / Returns | Backend helper to enforce with |
|---|---|---|
| `GET /circle/settings/message-privacy` | → `{who_can_message, phone_hidden}` | `default_who_can_message()` / `default_phone_hidden()` seed the row |
| `POST /circle/settings/message-privacy` | `{who_can_message, phone_hidden}` → `{ok}` | `normalize_who_can_message()` (fail-closed) |
| `GET /circle/message-requests` | → `{requests:[{id,name,phone,photo,preview,at}]}` | rows routed to `requests` inbox by `message_request_routing` |
| `POST /circle/message-requests/<id>` | `{action, reason?, also_block?}` → `{ok}` | `apply_message_request_action()` |
| `GET /circle/blocked` | → `{blocked:[{id,name,phone,photo}]}` | existing block set |
| `POST /circle/<member>/controls` `{blocked:false}` | unblock (reuses existing endpoint) | — |

**Enforcement seam (critical):** the message RELAY must call
`message_request_routing(...)` on every inbound message from a non-contact
**before** persisting or pushing, so a tampered client cannot bypass the gate.
The member payload serializer must omit `phone` to non-contacts when
`phone_hidden` is True (`default_phone_hidden()`).

## Model / migration needed (describe only — NOT added)
Add a single settings row (or two columns on the existing per-user messenger
settings model). **The integrator adds the migration — none was created here.**
```
MessengerMessagePrivacy (one-per-user, or 2 cols on existing settings model)
  user                OneToOne -> User
  who_can_message     CharField(choices=my_circle|everyone|nobody, default="my_circle")
  phone_hidden        BooleanField(default=True)
```
Message-request rows reuse the existing connection-request / thread storage with
an `inbox="requests"` discriminator (set by `message_request_routing`); no new
message model is required. The blocked set already exists (circle controls).

## Tests added
- **11 new self-test functions** in `msg_contacts_tests_snippets.py`
  (`test_conservative_message_defaults`, `test_stranger_gate_holds_in_requests_never_notifies`,
  `test_stranger_gate_refuses_nobody_and_blocked`, `test_message_request_action_validation_fail_closed`,
  `test_apply_accept_promotes_without_blocking`, `test_apply_decline_is_silent_not_block`,
  `test_apply_block_adds_to_blocked_set`, `test_apply_report_harsh_reason_autoblocks`,
  `test_apply_invalid_action_is_noop`, `test_who_can_message_loosening_confirm_gate`,
  `test_message_privacy_bilingual_labels_and_honest_notice`).
- Whole module now: **27 tests / 146 assertions, all passing**
  (`python3 -c "import core.logic.msg_contacts_tests_snippets as t; t.run_all()"`).
- Wired into `core/tests.py` as `MsgContactsSnippetTests` (discovered by Django's
  runner — 27 tests found; they are pure and need no DB).

## New ARB keys — see `.phaseB/up_msgreq_arb.json`
**32 new keys** (format `{"key":["<bn>","<en>"], ...}`), to be merged into
`app_en.arb` / `app_bn.arb` by the integrator (this task does not edit the arb).
Parameterized keys (in the file's `_params` block):
- `msgrSetRequestBlockConfirm` → placeholder `name`
- `msgrSetUnblockConfirm` → placeholder `name`
All other keys are plain. No Bangla literal appears in any `.dart`.

## §21 advanced checklist
- **Conservative defaults**: who-can-message = `my_circle`; phone hidden = True; strangers never notify.
- **Confirm gates**: loosening who-can-message (→everyone / →circle from nobody); block a requester; unblock.
- **Honest states**: load spinner, error + Retry (never shows defaults as "saved"), empty states with a reassuring hint — on the message-privacy screen, the requests inbox, and the blocked list.
- **bn/en**: every string via `AppLocalizations`; bilingual backend labels/hints.
- **No clipped text @360dp**: all titles/subtitles use `maxLines` + `TextOverflow.ellipsis`; radio rows are three-line.

## Overlap proof — what `circle_privacy_screen.dart` ALREADY has (NOT redone)
Read first. It owns, and this task did **not** touch or duplicate:
- **Who-can-SEE** visibility per field (last seen / active / profile photo / about / status): `circlePrivacyWhoCanSee`
- **Read receipts** + **Typing** toggles (reciprocal rule): `circlePrivacyReadReceipts`, `circlePrivacyTyping`
- **Who-can-CALL** policy + **DND** schedule/family-exception: `circlePrivacyIncomingCalls`, `circlePrivacyDnd*`

This task added strictly the **message layer** those controls do not cover:
who-can-**MESSAGE**, **phone-hidden**, **message-requests** inbox, and the
**blocked list** — zero duplication. The hub (`MsgrSetPrivacyScreen`) continues
to link the see/receipts/call rows to the existing `CirclePrivacyScreen` rather
than re-implementing them.
