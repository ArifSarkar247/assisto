# Voice commands — BASIC → ADVANCED upgrade (integration notes)

SPEC v2.1 §21. Upgrades the chat mic from a plain dictation button (words
dropped straight into the text field) to an **advanced voice-command** flow:
transcribe → map to intent/route → show *what it understood* → **confirm before
acting**, with proper listening / error / unavailable / permission states.

## Where voice lives
- **Before:** `app/lib/screens/agent_thread_screen.dart` had an inline
  `SpeechToText` mic button (`_toggleMic`) that just streamed recognised words
  into the input field — no intent, no confirm, no honest "unavailable" state.
- **Now:**
  - **Edited:** `app/lib/screens/agent_thread_screen.dart` — removed the inline
    STT dictation; the mic button opens the new voice-command sheet via
    `_openVoice()`. The confirmed transcript is fed back through the existing
    `_send(text)` pipeline (local route → backend `route` → `/agent`), so no new
    API surface and Bangla/Banglish still resolve server-side.
  - **New widget:** `app/lib/widgets/voice_command_sheet.dart` — the advanced
    listening sheet (animated mic orb, live partial transcript, understood-intent
    chip, confirm/retry, unavailable/error/permission states, Semantics labels).
  - **New widget:** `app/lib/widgets/voice_intent.dart` — on-device
    English/ASCII intent mapper (`VoiceMapper.map`), mirrors the backend and
    reuses `ChatNav`'s English synonym map / `detectRoute` for routing.
  - **Backend (taken):** `backend/core/logic/voice_commands.py` — deterministic
    text→intent mapper (bn + Banglish + en) + tests
    `backend/core/logic/voice_commands_tests_snippets.py` (`run_all()` → 49
    checks pass).

## Untouched (as required)
`api.dart`, `app_*.arb` (strings emitted to `up_voice_arb.json` instead),
`models.py`, `urls.py`, sidebar / unrelated screens, migrations. No
`flutter`/`build` run. No Asalify.

## Intent model (deterministic, no AI)
`voice_commands.map_command(text, now=None)` returns
`{intent, route, title, args, confirm}` or `None` for empty input.

| intent     | triggers (bn / Banglish / en)                 | route       | reuses                         |
|------------|-----------------------------------------------|-------------|--------------------------------|
| `sos`      | sos / bachao / বিপদ / বাঁচাও (checked FIRST)   | `emergency` | —                              |
| `call`     | call / phone koro / কল করো                    | `circle`    | strips name from utterance     |
| `reminder` | remind me / reminder dao / মনে করিয়ে          | `reminders` | **`nlp_datetime.parse`** (when)|
| `expense`  | i spent / khoroch korechi / খরচ করেছি         | `money`     | **`money_parse.normalize_digits`** (amount) |
| `open`     | open/show + known subject                     | *(resolved)*| **`screen_synonyms.resolve`**  |
| `unknown`  | speech understood, nothing actionable         | `null`      | —                              |

`confirm` is **always True** for every intent — the app shows the understood
intent + a Confirm button and only acts after an explicit tap. SOS deliberately
still routes to the emergency screen (which has its own guarded trigger) rather
than auto-dialling.

On-device (Dart `VoiceMapper`) handles the English/ASCII fast-path with zero
latency; anything it can't resolve (notably Bangla) returns `null` and the
confirmed transcript is sent to the backend, where `screen_synonyms` +
`voice_commands` understand the full bilingual vocabulary.

## STT key / device gate (honest — no fabricated transcription)
Speech-to-text is **device/engine gated** through the `speech_to_text` plugin:
- The sheet asks mic permission via the existing `showPermissionReason(…mic)`
  dialog, then calls `SpeechToText.initialize()`.
- If `initialize()` returns **false** (no on-device engine / unsupported device),
  the sheet shows an explicit **"Voice isn’t available on this device"** state
  (`voiceUnavailableBody`) and offers typing instead. It **never invents a
  transcript** — the understood-intent step only ever runs on words the device
  actually recognised (`onResult.recognizedWords`).
- `onError` → honest error state with Retry (`voiceErrorBody`).
- There is no cloud STT and no AI key involved in transcription; the only
  network call is the existing `/agent` send that happens *after* the user
  confirms.

## §21 ten-point coverage
1. **Empty** — `map_command("")`→`None`; empty transcript returns to idle (no
   action). 2. **Loading/listening** — animated pulsing mic orb + live partial
   transcript + "Listening…". 3. **Error** — `onError` → error card + Retry.
   4. **Permission** — `showPermissionReason(mic)` before init; decline =
   no-op. 5. **Unavailable (key/device gate)** — honest mic-off state, no fake
   transcript. 6. **Bilingual** — all strings in `up_voice_arb.json` (bn+en);
   backend mapper + synonyms are bilingual. 7. **WCAG** — gradient orb uses
   white glyph on Brand gradient; chips/cards use scheme container pairs;
   `Semantics(button, label)` on the orb; large tap target (96px). 8. **Confirm
   before action** — mandatory understood-intent step. 9. **Scenario** — "open
   my money", "i spent 500 on groceries", "remind me at 9pm", "call mom", "sos"
   all mapped + tested. 10. **Retry** — from both error and understood states.

## ARB codegen (required before the app builds)
The 15 keys in `up_voice_arb.json` must be merged into
`app/lib/l10n/app_en.arb` (en = index 1) and `app_bn.arb` (bn = index 0), then
`flutter gen-l10n` run — same deferred pattern as the other `.phaseB/*_arb.json`
drops. Until then the `t.voice*` getters won't exist. Reused existing keys:
`t.cancel`, `t.retry`, `t.open`, `t.call`. No placeholder keys in this drop.

## Backend tests
```
cd backend && python3 -c "import core.logic.voice_commands_tests_snippets as t; t.run_all()"
# voice_commands: 49 checks passed
```
Optional: `/agent` can attach `voice_commands.map_command(text)` metadata to its
reply if a richer confirm card is wanted later — not required for this upgrade,
since the app already shows the understood intent on-device before sending.
