# Messenger #86 (Message actions) + #87 (Chat organise) — reviewer-pass to §21 ADVANCED

Reviewer-pass (NOT a rebuild). Both surfaces were already substantially built;
this pass closes the honest-state / confirm-gate / search-state gaps against
the Section-21 advanced standard and adds server-enforced pure helpers + tests.

## Files changed

### Flutter (app/)
- `app/lib/screens/circle_chat_screen.dart` — **#86**. Single-message delete now
  goes through a **confirm gate** (`_confirmAndDelete`): delete-for-me and
  delete-for-everyone each confirm; delete-for-everyone uses a danger-coloured
  button + its own "cannot be undone" copy, then an honest result toast. (The
  bulk-select delete path already confirmed; the long-press path did not — that
  was the gap.) Edited/deleted honest markers already render in `circle_bubble.dart`
  (`circleEdited`, `circleDeletedPlaceholder`) and are unchanged.
- `app/lib/widgets/msgr_hub_chat_list.dart` — **#87**. Added chat-list organise:
  - **Pin / unpin** via per-row long-press sheet, with a cap of 5 (mirrors
    `msg_organise.PIN_CAP_PER_USER`) and **pin ordering** (pinned float to top by
    pin time, then rest by recent activity).
  - **Archive / unarchive** with a dedicated **archived view** (back header,
    "Archived (n)" banner on the main list, archived-empty honest state).
    Archiving clears any pin (a chat can't be both).
  - **Mute** with duration options (8h / 1w / always) + unmute, honest muted glyph
    on the row.
  - **Mark as read** (shown only when unread > 0).
  - **Search no-results state** (`_noResults`) distinct from the empty-list state
    (`_empty`), mirroring the server `search_chats` 'no_results' state.
  - New `_CountPill` widget for the archived count (brand-neutral, bn/en digits).

NOTE: no edits to `api.dart`, `messenger_hub_api.dart`, `core/models.py`,
`core/urls.py`, sidebar, `app_*.arb`, or migrations. The new organise calls use
the existing public `ApiClient.postJson` directly from the widget (offline-safe:
optimistic local update, swallow failure, no dead taps).

### Backend (backend/core/logic/)
- `backend/core/logic/msg_organise.py` — **NEW** pure module (no Django, no DB,
  no AI). Server-side authority for both tickets:
  - #87: `can_pin_chat`, `order_chat_list`, `partition_archived`, `set_archived`,
    `normalize_mute_duration`, `mute_until`, `build_mute`, `is_muted`,
    `search_chats` (honest idle/results/no_results state).
  - #86: `can_edit_message`, `delete_scope_options`, `apply_delete`,
    `edited_marker`, `deleted_marker`, `normalize_forward` (hop count never goes
    backwards; "forwarded many times" at >= 5). Windows MIRROR
    `circle_messaging.py` (EDIT_WINDOW_MIN=15, DELETE_EVERYONE_WINDOW_MIN=2 days).
- `backend/core/logic/msg_organise_tests_snippets.py` — **NEW** 18 plain-assert
  tests (`run_all()` prints "msg_organise: 18 tests passed").
- `backend/core/tests.py` — **wired** the snippets via the existing
  `_make_snippet_case` pattern:
  `MsgOrganiseSnippetTests = _make_snippet_case(
      "core.logic.msg_organise_tests_snippets", "MsgOrganiseSnippetTests")`
  (added just after `AdminFlagsSnippetTests`).

## New ARB keys (19) — in `.phaseB/up_msgactions_arb.json`

Format `{"key": ["<bn>", "<en>"]}`. **No `_params`** — none are parameterized.

- Message delete (#86): `msgrMsgDeleteMeConfirm`, `msgrMsgDeleteEveryoneConfirm`,
  `msgrMsgDeletedMe`, `msgrMsgDeletedEveryone`
- Pin (#87): `msgrChatPin`, `msgrChatUnpin`, `msgrChatPinLimit`
- Archive (#87): `msgrChatArchive`, `msgrChatUnarchive`, `msgrChatArchived`,
  `msgrChatUnarchived`, `msgrChatArchivedTitle`, `msgrChatArchivedEmptyTitle`,
  `msgrChatArchivedEmptyBody`
- Mute / read (#87): `msgrChatUnmute`, `msgrChatUnmuted`, `msgrChatMarkRead`
- Search (#87): `msgrChatSearchNoResultsTitle`, `msgrChatSearchNoResultsBody`

Merge into `app_en.arb` / `app_bn.arb` with the standard merge step and regenerate
`app_localizations.dart` (the Dart already references the getters). Existing
getters reused (already present): `cancel`, `delete`, `circleActionDeleteMe`,
`circleActionDeleteEveryone`, `msgrChatMute`, `msgrChatMuted`, `msgrChatMute8h`,
`msgrChatMute1w`, `msgrChatMuteAlways`, `msgrNoMessagesYet`, `msgrChatsEmptyTitle`,
`msgrChatsEmptyBody`.

## New endpoints the client now calls (integrator to land)

All opaque to the relay; chat content stays E2E (these carry only organise flags,
never message bodies). Client already degrades to honest local state if absent.

- `POST messenger/chats/<id>/pin`      body `{ "pinned": bool }`
- `POST messenger/chats/<id>/archive`  body `{ "archived": bool }`
- `POST messenger/chats/<id>/mute`     body `{ "duration": "8h"|"1w"|"always"|"off" }`
- `POST messenger/chats/<id>/read`     (no body — mark this chat read)

For each, the view should call the matching `msg_organise` helper to ENFORCE the
rule server-side (e.g. `can_pin_chat` before setting the pin; `build_mute` /
`is_muted` for mute; `partition_archived` / `set_archived` for archive). The
chat-list GET (`/circle/chats`) should return per-chat `pinned`, `pin_at`,
`archived`, `muted` so ordering/indicators survive a reload (the client reads
these keys; they are optional and default to unset).

## Model / migration needed (DESCRIBE ONLY — not added, per constraints)

The organise flags are PER-USER PER-CHAT state. Recommended: a single
`ChatOrganiseState` model (the integrator adds the model + migration):

- `user`        FK -> User (the viewer; organise is per-user, not per-chat-global)
- `chat_kind`   CharField (member|group|community|channel; default 'member')
- `chat_id`     CharField (opaque chat ref; matches `normalize_chat_ref`)
- `pinned`      BooleanField default False
- `pin_at`      DateTimeField null=True (set when pinned; drives pin ordering)
- `archived`    BooleanField default False
- `mute_until`  DateTimeField null=True (null + a `muted` marker == "always";
                an elapsed instant == honestly un-muted, per `is_muted`)
- `muted_duration` CharField null=True ("8h"|"1w"|"always"; for display/rebuild)
- unique_together: (user, chat_kind, chat_id)

Why per-user: pin/archive/mute are the viewer's own organisation and must not
leak to or affect the peer. No message-content columns — E2E ciphertext-only is
preserved. If the integrator prefers, these columns can instead extend the
existing per-chat settings row used by `circleChatSettings` — same fields,
same `msg_organise` enforcement.

## Tests added

- 18 pure tests in `msg_organise_tests_snippets.py` (pin cap/ordering, archive
  partition + pin-clear, duration-mute expiry vs always, search idle/results/
  no-results + accent fold + "ask assisto" strip, edit gate, delete-scope gate +
  tombstone, edited/deleted markers, forward-hop increment + many-times).
- Wired into `core/tests.py` as `MsgOrganiseSnippetTests`.
- `python3 -c "import core.logic.msg_organise_tests_snippets as t; t.run_all()"`
  → `msg_organise: 18 tests passed`.

## Wiring steps (integrator)

1. Merge `.phaseB/up_msgactions_arb.json` into `app_en.arb` / `app_bn.arb`;
   regenerate `app_localizations.dart`.
2. Add the `ChatOrganiseState` model + migration (above); surface `pinned`,
   `pin_at`, `archived`, `muted` on the `/circle/chats` list payload.
3. Add the 4 endpoints; enforce each via the matching `msg_organise` helper.
4. Run `python manage.py test core` — `MsgOrganiseSnippetTests` runs the 18.

## Constraints honoured

- E2E ciphertext-only preserved (organise flags carry no bodies; no decryption).
- Honest states throughout; every destructive action confirms; no fake data.
- Original Assisto identity (own icons/wording, brand tokens; not a Meta copy).
- Zero Bangla literals in `.dart` (codepoint-scan U+0980–U+09FF clean on both
  edited files). Disjoint, compilable edits; no touched forbidden files.
