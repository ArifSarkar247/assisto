# Messenger Contacts & Invites + Personal Connection Request — Integration Notes

Pure logic lives in `backend/core/logic/msg_contacts.py` (tests:
`msg_contacts_tests_snippets.py`, run with
`cd backend && python3 -c "import core.logic.msg_contacts_tests_snippets as t; t.run_all()"`).
This file lists the Django models/endpoints the integrator must add and the
CLIENT HASHING CONTRACT. The logic module builds ON TOP of `core.logic.circle`
(relationship vocab, request state machine + 2b fix, block/report) — no
duplication. No models/views/urls/app/Asalify were edited.

## Privacy confirmations (enforced in the pure layer)
- **Non-users' numbers/hashes are never stored.** `match_contacts` is a pure
  function over uploaded SALTED HASHES; non-matching hashes are dropped on
  return and the result carries `stored: False`. The server holds hashes ONLY
  for verified registered users (computed at signup/verify).
- **Explicit-permission gated (Play-compliant).** `match_contacts` refuses
  (`permission_required`) and inspects nothing unless `permission_granted=True`
  (OS contacts permission + in-app consent).
- **No SMS/WhatsApp gateway, never auto-send.** Non-user invites produce either
  a share-link descriptor (OS share sheet) or an own-SIM `sms:` URI descriptor
  (device composer, user presses Send). `requires_send_sms_permission=False`,
  `uses_gateway=False`, every descriptor has `auto_sent=False`.
- **Pre-accept lockdown.** Before acceptance: no calls, no messages except the
  single attached note (`can_send_before_accept` + `pre_accept_message_count_ok`).
- **Daily request limit** enforced + tested (the N+1 send is blocked).

## CLIENT HASHING CONTRACT (`hashing_contract()` is the machine-readable form)
1. **Normalize** each contact number to E.164 with the device SIM region
   (default country code `880`); reference impl = `normalize_e164`
   (digits-only, local `01…` → `+880…`).
2. **Hash**: `hex( HMAC-SHA256( key = SERVER_MATCH_SALT, msg = e164 ) )`
   truncated to **32 hex chars** (`hash_phone`). Algorithm id `hmac-sha256`,
   contract version `v1`.
3. **Upload** ONLY the de-duplicated hash batch + the permission flag. NEVER
   upload raw numbers or names; the client never persists non-user hashes.
4. **Salt** = a single **server-wide secret** (NOT per-user — the same number
   must hash identically on every device for the intersection to work). It
   raises the cost of an offline dictionary attack; it is not an auth key.
   Server computes the identical hash for each verified user phone at
   signup/verify using the same `normalize_e164` + `hash_phone`.

## Django MODELS to add (migrations only; not written here)
- **UserPhoneHash** — `user (OneToOne→User)`, `phone_hash (CharField 32, unique,
  indexed)`, `salt_version (CharField, default "v1")`, `created_at`. Populated
  at phone-verify. This is the ONLY place a phone hash is stored, and only for
  real users. Non-user hashes are never written anywhere.
- **ConnectionRequest** — `requester (FK→User)`, `target (FK→User)`,
  `relation (CharField)`, `custom_label (CharField, blank)`,
  `note (CharField ≤280, blank)`, `note_used (Bool)`,
  `state (CharField: pending/accepted/declined/blocked, default pending)`,
  `created_at`. Unique `(requester, target)` while pending. Reuses the circle
  request state machine (`apply_request_event`, `can_act_on_request`). On accept,
  the integrator should create the mutual CircleMember edge (circle semantics).
- **ConnectionRequestNote** (optional) — if you don't inline the note on the
  request, a single row `(request, ciphertext, created_at)` with a DB unique on
  `request` enforcing the ONE-note budget. Pre-accept, no Message rows may exist
  for this pair except this note.
- **InviteOutbound** (audit, optional) — `inviter (FK)`, `channel (in_app/
  share_link/sms_own_sim)`, `token`, `created_at`. For share-link / SMS invites
  reuse `circle.make_invite_token` for the signed token in the deep link.
- Block/report: reuse the existing circle Report/Block models;
  `block_or_report_on_request` returns the directive to persist.

## ENDPOINTS to add
- `POST /messenger/contacts/match` — body `{hashes:[...], permission_granted:bool}`.
  View: look up each hash in `UserPhoneHash`, call `match_contacts(hashes,
  {hash: public_user_descriptor}, permission_granted=...)`, return `matches`.
  MUST NOT persist the request body. Rate-limit per user.
- `POST /messenger/invite/existing` — `{to_user_id, relation, custom_label?}` →
  `invite_existing_user(...)` + create the `ConnectionRequest`; push via FCM when
  the key is configured (`fcm_available`), else it shows on next open.
- `POST /messenger/invite/share-link` — `{relation}` → mint
  `circle.make_invite_token` + `invite_non_user_share_link(from_name, link)`;
  return the descriptor for the OS share sheet.
- `POST /messenger/invite/sms` — `{relation, to_number}` →
  `invite_non_user_sms(from_name, link, to_number)`; return the `sms:` URI
  descriptor. Server does not send; client opens the composer.
- `POST /messenger/request` — `{target_id, relation, note?}`. View calls
  `can_send_request` (passing the requester's last-24h sent log) then
  `build_connection_request`; persist only on `ok`. Enforces relation-mandatory,
  no-self, daily limit.
- `POST /messenger/request/<id>/act` — `{event}` where event ∈
  {accept, decline, cancel, block}. Guard with
  `act_on_connection_request(direction, event)` (2b fix: sender can't accept
  own; outgoing=cancel-only, incoming=accept/decline). On accept → create mutual
  circle edge; optionally fire `referral.award_for_accept`.
- `POST /messenger/request/<id>/message` — the ONE pre-accept note path. Guard
  with `can_send_before_accept(state, note_used, is_note=True, is_call=False)`;
  reject a second note / any other pre-accept message. Post-accept, route
  through the normal `circle_messaging.send_precheck` instead.
- `POST /messenger/request/<id>/report` — body `{action, reason, note?}` →
  `block_or_report_on_request(...)`; persist report + block.

## UI strings
`backend/core/logic/msg_contacts_arb.json` — `{key: [bn, en]}`. `strings(lang)`
in the module mirrors the core subset for server-rendered responses.

## ADVANCED upgrade (#99 MATCH + #101 INVITE → SPEC v2.1 §21)
Contact MATCH + INVITE were raised to the §21 "advanced" bar.

NEW app files (nothing else edited on the app side):
- `app/lib/widgets/contacts_match_model.dart` — bilingual string table (Bangla
  as `\u` codepoints; **zero Bangla glyphs in any .dart**), `cmStr`/`cmNum`
  helpers, and value types (`CmStage`, `CmProgress`/`CmPhase`, `CmInviteCard`).
- `app/lib/widgets/contacts_match_widgets.dart` — reusable UI: `CmDisclosure`
  (Play disclosure: why / what's sent / never-stored / in-control + a privacy
  link), `showCmPrivacyExplainer` ("how this protects your privacy" sheet),
  `CmLoading` (hashing/match progress, not a bare spinner), `CmStateView`
  (empty/denied/offline), `CmUserRow` (connect), `CmInviteCardView` (shareable,
  **referral-code embedded**, share / own-SIM SMS / copy / see-referral).
- `app/lib/screens/messenger/contacts_screen.dart` — rewritten to orchestrate
  all §21 states: disclosure → matching (progress) → results, plus denied /
  offline / empty / re-sync. Hashing contract unchanged (HMAC-SHA256,
  E.164 cc880, 32-hex). Re-sync action in the AppBar + inline. Invite card pulls
  the user's referral link/code from `referralBalance()` and links to
  `ReferralScreen`.

ARB: apply **`.phaseB/up_contactmatch_arb.json`** (40 NEW `cm*` keys; merge into
`app_bn.arb`/`app_en.arb`). Reuses existing `msgrContacts*/msgrInvite*/
msgrConnect*/msgrRequest*/msgrCancel` getters (not re-emitted). Parameterized:
`cmResultsFoundCount{n}`, `cmHashedOnDevice{n}`, `cmInviteCardReferral{code}`.

Backend (optional, added): `msg_contacts.privacy_disclosure(lang)` — bilingual,
machine-readable permission-disclosure facts (why / sent / never-stored /
control) + the hard invariants (`uploads_raw_numbers:false`,
`uploads_names:false`, `stores_non_users:false`, `permission_gated:true`,
`auto_sends_anything:false`), so the app's disclosure copy and the server's
stated contract never drift. Test `test_privacy_disclosure_invariants` asserts
the facts and that they agree with `hashing_contract()`. Self-tests now
**89 assertions / 16 tests**.

FCM / own-SIM invite unchanged from the pure layer: existing users get an in-app
request (FCM push when a key is configured via `invite_existing_user(...,
fcm_available=...)`, else shown on next open); non-users get a share-link
descriptor (any app) OR an own-SIM `sms:` URI the USER presses send on — no
`SEND_SMS` permission, no gateway, `auto_sent:false` everywhere.
