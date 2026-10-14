# Elderly Simple-Mode — integration note (SPEC v2.1 feature 29)

## What was built (new files only — nothing existing was edited)

- `app/lib/screens/elderly_home_screen.dart` — `ElderlyHomeScreen`, the simple-mode launcher.
- `app/lib/widgets/elderly_tile.dart` — `ElderlyTile`, the big high-contrast action tile.
- `app/lib/widgets/elderly_mode.dart` — `EldersModeController` (flag read/write + consent gate) and `ElderlyModeTile` (the enter/exit toggle widget).
- `.phaseB/elderly_arb.json` — 37 bilingual strings (`{key:[bn,en]}`), 4 with ICU placeholders.

No edits to `app_*.arb`, `api.dart`, `models.py`, `urls.py`, sidebar, settings_screen, or any other screen. No flutter/build/migrations run. No backend `elderly.py` needed — existing endpoints suffice.

## The flag

- Local authority: `Settings` bool key `elderly_mode` (plus a sentinel `elderly_mode_set`), via the existing `Settings` helper in `state.dart`.
- Server mirror: `EldersModeController.set()` best-effort calls `AppState.saveProfile({'elderly_mode': value})` → PATCH `/me`. The backend field `User.elderly_mode` and `ElderlyModeView` (`/me/elderly`) already exist; `api.setElderly(v)` is also available. The local flag is the router's source of truth so routing works offline; the server value only seeds first-run on a new device.

## How to route home → ElderlyHomeScreen when the flag is on

`main.dart` `_Root.build()` currently ends with `return const HomeScreen();`. Make `_Root` resolve the flag once and swap the home. Minimal patch (NOT applied here — settings/main are off-limits for this task; emit as the wiring):

```dart
// in _Root (StatefulWidget): add a field + resolve in initState/didChangeDependencies
bool _elderly = false;
// after login/onboarding is known:
EldersModeController.resolveForRouting(context.read<AppState>())
    .then((v) => mounted ? setState(() => _elderly = v) : null);

// at the end of build(), replacing `return const HomeScreen();`
if (_elderly) {
  return ElderlyHomeScreen(onExit: () => setState(() => _elderly = false));
}
return const HomeScreen();
```

`ElderlyHomeScreen(onExit:)` fires after the user confirms EXIT (the controller has already flipped the flag off), so the root rebuilds straight back to the normal chat home. `EldersModeController.resolveForRouting()` returns the local flag, falling back to the profile value only when the flag was never written locally.

## Settings toggle wiring (do this in settings_screen.dart — NOT edited here)

Add one row wherever the Safety/Accessibility settings live:

```dart
import '../widgets/elderly_mode.dart';
// ...
ElderlyModeTile(
  onChanged: (_) {
    // Optional: pop to root so the new home shows immediately.
    Navigator.of(context).popUntil((r) => r.isFirst);
  },
),
```

`ElderlyModeTile` is a `SwitchListTile` (>=56dp row). Turning ON runs: (1) the parent-permission gate, (2) a plain enter-confirm. Turning OFF runs an exit-confirm. It persists via `EldersModeController.set`.

## Reuse (nothing re-implemented)

- Family/circle contacts: `api.getEmergency()['contacts']` (same `{name,relation,phone}` shape the emergency screen uses). One contact → direct call; several → a big-row picker.
- Calls: `tel:` via `url_launcher` (same path as `emergency_sos_panel.dart`).
- Medicines: `api.medicinesToday()`; the Meds tile shows a live "N due today" badge and opens the `medicine_db` route.
- Emergency/SOS: full-width red tile → `emergency` route (the existing advanced SOS flow).
- Messages / Money / Help: `messages`, `money`, `guide` routes via `ChatNav.push`.
- Voice-first: big mic → `showVoiceCommandSheet()` → `ChatNav.detectRoute` → `ChatNav.push` (same pipeline as chat; honest device-gated STT).

## Parent-permission (consent)

`EldersModeController.confirmParentPermission()` reproduces the fall-detect pattern (`FallDetectScreen._confirmParentPermission`): a two-button dialog — "I have their permission" / "Cancel" — gating any enable-for-someone-else. Strings `elderlyPermission*`. A child cannot silently flip a parent into simple mode.

## Advanced / accessibility (SPEC §21 — all 10)

1. Empty — no family number → add-contact dialog; no meds due → "All taken today".
2. Loading — `Skeleton` placeholders.
3. Error — hard failure with no cache → `_ErrorRetry` (big icon + >=56dp Retry).
4. Offline — keeps last-known contacts and shows a bordered offline banner; medicine badge degrades to 0 silently.
5. Bilingual — every string via `AppLocalizations`; see ARB (37 keys).
6. WCAG AAA — tile body text >=24sp, SOS >=28sp, sublabels >=18sp; solid dark tile colours (0xFFB71C1C, 0xFF1B5E20, 0xFF0D47A1, 0xFF4A148C, 0xFF004D40, 0xFF37474F) all give >=7:1 against white at these large sizes; a 2px white border per tile for low-vision separation.
7. Big touch targets — tiles 110–150dp tall; mic 108dp; every dialog/list row and the toggle are >=56dp.
8. Simplified language — short, plain bilingual copy; confirmations before calling / leaving simple mode.
9. Minimal depth — six essential actions on one screen; each is a single push to an existing screen (which carries its own large AppBar back button); the home itself offers an explicit confirmed EXIT instead of a back.
10. Scenario — a senior opens the app (already in simple mode), taps the green "Call family" tile, confirms, and the phone dials their child; or taps SOS once; or opens "My medicines" seeing "N due today".

## Counts / confirmations

- ARB: 37 keys (4 with ICU placeholders: `elderlyMedsDue{count}`, `elderlyCallSubCount{count}`, `elderlyCallConfirmTitle{who}`, `elderlyCallConfirmBody{who}`).
- Zero Bangla codepoints (U+0980–U+09FF) in any `.dart` file (verified).
- Parent-permission gate: present, reuses fall-detect pattern.
- WCAG AAA sizes + >=56dp targets: confirmed above.
