# Onboarding + parent-linking — GOOD → ADVANCED (integration notes)

SPEC v2.1 §21. Turns the 5-slide first-run into a **<60s "wow"** interactive
flow that teaches the main features, then links a loved one honestly.

## The flow (skippable + resumable, progress dots + "Step N of M")
0. **Welcome + LANGUAGE** — pick bn/en up front; sets the app locale via
   `AppState.setLocale`.
1. **WHO ARE YOU** — self / elderly parent / family / business. The choice
   tailors steps 3–4.
2. **PERMISSIONS, HONESTLY** — every permission (notifications, mic, camera,
   location, contacts) + exactly WHY. **Nothing is requested here** — the real
   OS prompt still fires lazily from the feature that needs it
   (`permission_reason.dart`), reusing the SAME reason strings so the promise
   matches the ask.
3. **FIRST WIN** — one REAL task, **recommended per role** (parent/family →
   medicine reminder, business → scan a bill, self → safe-journey; expense
   always offered). Tapping opens the **live screen** (`FamilyScreen` /
   `VaultScreen` / `JourneyStartScreen` / `MoneyScreen`) — a genuine win, not a
   demo.
4. **LINK A PARENT** — phone + relation → invite by **call** (`tel:`), **SMS**
   (own-SIM prefilled composer, user presses Send — no SEND_SMS perm, no
   gateway), or **QR** (signed deep link). **IVR for feature phones is
   🔑 key-gated** and shown as an honest "Available when ___" locked row.

## Files

### Edited
- `app/lib/screens/onboarding_screen.dart` — rewritten as the 5-step orchestrator
  (PageView). Adds resume (persists step in `Settings` key `onb_step`, offers
  Continue vs Start-over on relaunch), progress dots + "Step N of M", role-gated
  Next, and the first-win → real-screen routing. `onboarded` is set on
  finish/skip. **Zero Bangla** (all strings via `AppLocalizations`).

### New widgets
- `app/lib/widgets/onb_common.dart` — shared `OnbDots` (resumable progress),
  `OnbHeader` (gradient hero), `OnbChoiceTile` (big WCAG tile: 44px icon, min
  64 height, Semantics `button`/`selected`, "recommended" badge). No strings.
- `app/lib/widgets/onb_role.dart` — "who are you" step + `OnbRole` enum whose
  `.code` mirrors backend `parent_link.ROLE_*`.
- `app/lib/widgets/onb_first_win.dart` — role-tailored first-win picker;
  `_recommended` mirrors `parent_link.first_win_for_role`. Emits an `OnbWin`
  intent (screen-agnostic; the screen owns Navigator).
- `app/lib/widgets/onb_permissions.dart` — the honest why-each step; reuses
  `permMic` / `permLocation` / `permCamera`.
- `app/lib/widgets/onb_link_parent.dart` — phone + relation + invite channels.
  Mirrors `parent_link.py` on-device (normalize/validate phone, invite message,
  tel/sms URIs, QR deep link). Empty/loading("preparing invite")/error(invalid
  / self number via `errorText`) states. IVR row honestly locked when
  `ivrEnabled == false`.

### Backend (taken — logic + tests only)
- `backend/core/logic/parent_link.py` — composes the "link a parent" result:
  phone validate (rejects empty / <6 digits / own number), signed single-use
  expiring invite token (**reuses** `circle.make_invite_token` / `qr_payload`),
  own-SIM SMS descriptor (**reuses** `msg_contacts.invite_non_user_sms`), and
  the 4 channels each with explicit `available` (CALL/SMS/QR = true; **IVR =
  `ivr_enabled`** with a bilingual `reason` when locked → no dead taps). Also
  role → first-win / should-prompt-parent-link helpers. No AI key, no gateway,
  never auto-sends.
- `backend/core/logic/parent_link_tests_snippets.py` — 17 plain-assert tests
  (`run_all()` passes). Covers phone rules, token parse/sign, all 4 channels,
  IVR honest gating (locked vs unlocked), bilingual strings, role mapping.
- `backend/core/tests.py` — registered `ParentLinkSnippetTests` next to
  `CircleSnippetTests` (one added block, nothing else touched).

### Strings
- `.phaseB/up_onb_arb.json` — **61 new keys** (en + bn). Merge into
  `app/lib/l10n/app_en.arb` + `app_bn.arb`, then `flutter gen-l10n`. Reuses
  existing: `chooseLanguage`, `languageBangla`, `languageEnglish`, `permMic`,
  `permLocation`, `permCamera`, `continueWord`, `notNow`, `skip`, `next`,
  `onbTry*`, `onbInvite*`, `onbLinkParent*`, `onbManageFamily`,
  `onbAvailableWhenIvr`, `justStartChatting`, `onbMaybeLater`.

## Untouched (as required)
`api.dart`, `app_*.arb` (strings emitted to `up_onb_arb.json` instead),
`models`, `urls`, `sidebar`, `main.dart`, every other screen. No flutter /
build / migrations. No Asalify.

## Integrator wiring
1. Merge `up_onb_arb.json` → both ARB files → `flutter gen-l10n`.
2. `OnboardingScreen` gained an optional `ivrEnabled` param (default **false** =
   honest locked). To light up IVR once a provider is connected, pass
   `ivrEnabled: integrations.isEnabled('ivr')` from the caller in `main.dart`
   (the one spot that builds `OnboardingScreen`). No other caller change needed;
   the existing `onDone` contract is unchanged.
3. Server side, endpoints can call `parent_link.build_parent_link(...)` to return
   the same channel descriptors (incl. the signed token + QR payload) if/when the
   invite is minted server-side instead of on-device.

## Section-21 (all 10)
1. **Best-in-class**: role-tailored first win + honest multi-channel invite beats
   a passive slide deck (Duolingo/WhatsApp "aha" bar). 2. **Full flow**:
   language → role → perms → win → link, resumable, skippable, finishable.
   3. **Auto+manual**: role auto-recommends a win; user can pick any.
   4. **Empty/loading/error/offline**: resume-check spinner, "preparing invite",
   invalid/self-number errors, IVR offline/locked state — all designed.
   5. **bn/en, light/dark, small/large**: ListView steps, Wrap chips, min-64
   tiles, `onSurfaceVariant` contrast. 6. **Reminders/watch/chat/voice**: first
   win opens the real reminder/money/journey screens; "just start chatting"
   drops into chat. 7. **Tests**: 17 server scenario tests (incl. IVR-gated).
   8. **Share/result card**: QR + copy-link invite card. 9. **Privacy+consent**:
   permissions explained before any ask; nothing granted during onboarding;
   contacts matched on-device only. 10. **Reviewer**: screenshot-review gate
   per design standards before ship.
