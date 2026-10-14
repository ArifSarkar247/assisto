# Integration — #198 Digital Security Check-up + #200 True Accessibility Mode

SPEC v2.1 §20. Built to the Section-21 ADVANCED bar: bn/en throughout, confirm
gates, honest states, premium polish, no clipped text at 360dp. NEW work, no
external AI key. Nothing in the forbidden list was touched (api.dart request
helpers, core/models.py, core/urls.py, sidebar, app_*.arb, migrations, Flutter
builds, Asalify).

---

## New files

### Flutter
| File | Purpose |
|---|---|
| `app/lib/screens/security_checkup_screen.dart` | #198 screen — checklist, deterministic score ring + grade, honest weak-areas, per-item expandable tips, self-reported banner, reset confirm. |
| `app/lib/widgets/sec_engine.dart` | Pure Dart mirror of `core/logic/security_checkup.py` — item catalogue, weights, `scoreSecurity`, `gradeFor`, `secSanitize`, row codec. No strings (all copy flows through ARB in the screen). |
| `app/lib/screens/accessibility_mode_screen.dart` | #200 screen — six real toggles + a text-scale slider with a live preview; per-toggle honesty subtitles; reset confirm; Semantics-wrapped tiles. |
| `app/lib/widgets/a11y_prefs.dart` | `A11yPrefs` (ChangeNotifier, SharedPreferences-backed) + `A11yScope` (InheritedNotifier) + `applyHighContrast(ThemeData)`. The single source of truth for the a11y prefs, read app-wide. |

### Backend
| File | Purpose |
|---|---|
| `backend/core/logic/security_checkup.py` | #198 PURE deterministic scorer. `ITEMS` (id, weight, category), `score(answers)`, `grade_for`, `top_weak`, `sanitize`. `self_reported()` is a constant True; an unanswered item always counts NOT done (never flatters). |
| `backend/core/logic/security_checkup_tests_snippets.py` | 16 plain-assert snippet tests (hand-verified against fixed weights). |

### Edited (allowed)
- `app/lib/main.dart` — build an `A11yPrefs`, `load()` it before first frame, wrap `MaterialApp` in `A11yScope`, and apply the three app-wide prefs via a `MediaQuery` override in the `builder` (textScaler, highContrast, disableAnimations) + `applyHighContrast` theme merge. This is the app-wide a11y SEAM.
- `app/lib/screens/settings_screen.dart` — two new `ListTile`s (see Sidebar/entry section). Imports for the two new screens.
- `backend/core/tests.py` — **one** registration line:
  ```python
  SecurityCheckupSnippetTests = _make_snippet_case(
      "core.logic.security_checkup_tests_snippets", "SecurityCheckupSnippetTests")
  ```

---

## ARB keys — `up_seca11y_arb.json`

- **61 new keys** total: 60 plain message keys + 1 parameterized (`_params`).
- Format `{"key": ["<bangla>", "<english>"]}`; merge first value into `app_bn.arb`, second into `app_en.arb`, then `flutter gen-l10n` (integrator runs it).
- **Reused existing keys (NOT re-added):** `cancel`, `retry`.
- `_params` (add the `@key` placeholder block in `app_en.arb` per repo convention):
  - `secDoneOfTotal(done:int, total:int)` → bn `"{total}টির মধ্যে {done}টি সম্পন্ন"`, en `"{done} of {total} done"`.
- Key prefixes: `a11y*` (25 keys) for #200, `sec*` (36 keys incl. the param) for #198.
- Parity verified: every `t.<key>` called in the three .dart files maps to an ARB key (or a reused existing one) — zero missing, zero unused.

---

## Persistence

### #198 — generic REST collection `security/checklist`  (needs registration)
A **single row per user**. The integrator adds `"security/checklist"` to
`GENERIC_COLLECTIONS` in `backend/core/views.py` (same list as `tasks_items`,
`wedding/guests`, etc. — reuses `PaCollectionItem` + `PaItemSerializer`, **no
migration**, user-scoped + audit-logged by `PaCollectionViewSet`).

- **Path:** `/api/v1/security/checklist/` (list/create) and `.../security/checklist/<id>/` (patch) — reached via the existing `listItems('security/checklist')` / `createItem` / `updateItem` helpers (api.dart untouched).
- **Row shape** (flattened by `PaItemSerializer` to `{id, ...data}`):
  ```json
  { "id": 12,
    "answers": { "screen_lock": true, "app_lock": false, "wallet_pin": true,
                 "two_factor": false, "strong_passwords": false,
                 "backup_enabled": false, "scam_awareness": true,
                 "permissions_review": false },
    "updated_at": "2026-10-14T09:00:00Z" }
  ```
  `answers` is always `secSanitize`d client-side — keyed only by known item ids,
  strict bools — so the stored row never drifts. The screen reads the first row
  on open; each toggle PATCHes it (or POSTs once if none exists). Offline edits
  stay on screen; the save is best-effort and retried on the next toggle.

### #200 — SharedPreferences (pure client prefs, no backend)
Chosen deliberately: these must apply **instantly and offline**, and they're
device-local UI prefs, so no server round-trip. **No backend needed for #200.**
Keys (all in `A11yPrefs`):

| Key | Type | Default | Applies |
|---|---|---|---|
| `a11y_text_scale` | double (1.0–1.6) | 1.0 | app-wide |
| `a11y_high_contrast` | bool | false | app-wide |
| `a11y_reduce_motion` | bool | false | app-wide |
| `a11y_simplified_layout` | bool | false | opt-in hint (partial) |
| `a11y_screen_reader_hints` | bool | false | in-app Semantics |
| `a11y_haptics` | bool | true | app-wide pref |

---

## Tests

- **Backend:** 16 new snippet tests (`SecurityCheckupSnippetTests`) — catalogue
  consistency, honesty (self-reported constant, strict-True only, missing =
  not-done), determinism, scoring math, grade thresholds + clamping, weak-area
  ordering/ties, `top_weak`, sanitize round-trip. All pass standalone
  (`python security_checkup_tests_snippets.py`) and via Django
  (`manage.py test core.tests.SecurityCheckupSnippetTests` → 16 OK).
- **#200** is client-only (SharedPreferences prefs) — no backend test added.

---

## Sidebar / entry points

Both belong in the **Settings area**, not the sidebar (they're
settings-shaped, and the sidebar is module navigation per the design
standards). Added as `ListTile`s in `SettingsScreen`:

- **Accessibility mode** (`accessibility_new_outlined`) → placed right after the
  Elderly simple-mode tile, forming an accessibility cluster. Title `a11yTitle`,
  subtitle `a11yTileSub`.
- **Digital security check-up** (`verified_user_outlined`) → placed right after
  the Safety section (protection cluster). Title `secTitle`, subtitle
  `secTileSub`.

No sidebar (`sidebar_sections.dart`) edit — honoring the forbidden list.

---

## Wiring + accessibility SEAM (honest)

The app-wide a11y seam lives in `app/lib/main.dart`:

1. `A11yPrefs` is created in `main()` and `load()`ed before the first frame.
2. `AssistoApp` wraps `MaterialApp` in `A11yScope` (InheritedNotifier) → any
   change rebuilds the subtree, so toggles apply **live**.
3. In `MaterialApp.builder` a `MediaQuery` override merges in:
   - `textScaler: TextScaler.linear(a.textScale)` → **all** `Text` grows.
   - `highContrast: … || a.highContrast` + `theme: applyHighContrast(...)`
     (stronger outlines, pure fg/bg) — both light & dark.
   - `disableAnimations: … || a.reduceMotion` → implicit animations + page
     transitions soften.

Honest seams I could **not** fully reach (documented, pref still persisted):

- **Simplified layout** — applied only where screens opt to read
  `A11yScope.of(context).simplifiedLayout`; not every screen honours it yet. The
  app already ships a full **Elderly simple-mode** home for a completely
  simplified experience, so this flag is the lighter opt-in hint. Subtitle says
  "where supported".
- **Screen-reader hints** — turns on extra in-app `Semantics` labels/hints
  (e.g. on the a11y toggles themselves). The OS reader (TalkBack/VoiceOver) is
  controlled by the phone, not this toggle — the subtitle + footer say so.
- **Haptics** — stored as a preference `A11yPrefs.haptics`; the a11y screen
  itself respects it (confirmation buzz on enable, selection ticks on slider).
  Other features that fire `HapticFeedback` should check this flag going
  forward; that is a per-call wiring follow-up, not an app-wide hook.

Nothing claims an OS capability or a protection that isn't real.

---

## Report summary

- **Files created:** 4 Flutter (`security_checkup_screen.dart`,
  `sec_engine.dart`, `accessibility_mode_screen.dart`, `a11y_prefs.dart`) +
  2 backend (`security_checkup.py`, `security_checkup_tests_snippets.py`) = **6 new files**.
  Edited (allowed): `main.dart`, `settings_screen.dart`, `tests.py` (one line).
- **ARB keys:** **61** new (60 plain + 1 param `secDoneOfTotal`); reused
  `cancel`, `retry`.
- **Tests:** **16** new backend snippet tests, all green standalone + via Django.
- **Zero-Bangla confirmation:** grep for U+0980–U+09FF over all new/edited .dart
  files → **zero** Bangla literals; every user-facing string flows through an
  `AppLocalizations` getter.
- **Scoring:** deterministic (fixed integer weights, integer-rounded percent,
  stable weak ordering) — Python and Dart mirrors agree.
