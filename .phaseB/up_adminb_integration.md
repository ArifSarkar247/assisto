# ADMIN/SETTINGS advanced bundle — #178 Cost kill-switch & feature flags, #179 Server-address swap

Raises two owner/settings surfaces to the Section-21 ADVANCED bar. UI + pure
backend logic only. **No** edits to `api.dart` request helpers, `core/models.py`,
`core/urls.py`, sidebar, `app_*.arb`, migrations, Flutter builds, or Asalify.

---

## Files changed

### New — Flutter (`app/lib/`)
- `screens/admin/cost_flags_screen.dart` — #178 owner console (flags list +
  confirm gate + audit timeline + honest loading/empty/error/owner-only states).
- `screens/admin/server_address_screen.dart` — #179 endpoint-swap surface
  (validation + reachability probe + confirm gate + safe revert).
- `admin_flags_api.dart` — `AdminFlagsApi` **extension on `ApiClient`** built only
  on the public `getJson`/`postJson` helpers (so `api.dart` is untouched), plus
  the on-device `FlagCatalog` mirror of the backend confirm-gate classification.
- `services/server_config.dart` — the separate config surface that persists the
  base-URL override (SharedPreferences), validates/normalizes a URL, and probes
  `/api/v1/health` on an **independent `http.Client`**. Exposes
  `ServerConfig.effectiveBase()` for the integrator to wire (see below).

### New — Backend (`backend/core/logic/`)
- `admin_flags.py` — PURE, deterministic engine: flag CATALOG, confirm-gate
  decision (`needs_confirm`/`confirm_reason_code`), `validate_flip`, pure
  `apply_flip` (returns new state + audit entry), `make_audit_entry`,
  `normalize_state`, `summarize`. No Django, no DB, no clock, no money.
- `admin_flags_tests_snippets.py` — 18 plain-assert tests.

### Edited
- `app/lib/screens/settings_screen.dart` — added the **two bounded entry tiles**
  inside the existing owner/operator-gated block (`if (_isOperator == true)` in
  `_MsgrSettingsSection`, gated by `moderationWhoAmI`), matching the existing
  `AdminUsersScreen`/`AdminModerationScreen` pattern. Two imports added.
- `backend/core/tests.py` — wired `AdminFlagsSnippetTests = _make_snippet_case(...)`
  via the existing `_make_snippet_case` pattern (next to `FamilySharingSnippetTests`).

---

## New ARB keys

Emit via `.phaseB/up_adminb_arb.json` (format `{"key":["<bn>","<en>"], ...}`),
merged with the usual `merge_arb.py` flow. **86** new keys; **18** are
parameterized (declared in the file's `_params` block). Do **not** hand-edit
`app_en.arb`/`app_bn.arb`.

`_params` (placeholder order matches the Dart call argument order):

| key | params |
|---|---|
| flagEnableTitle / flagDisableTitle | `label` |
| flagEnabledToast / flagDisabledToast | `label` |
| flagConfirmEnableCost / flagConfirmDisableCost / flagConfirmDisableFeature / flagConfirmGeneric | `label` |
| flagFlipFailed | `error` |
| flagSummaryCostLine | `on`, `total` |
| flagSummaryFeaturesOff | `n` |
| flagAuditEnabled / flagAuditDisabled | `label` |
| flagAuditMeta | `actor`, `when` |
| srvConfirmBody / srvRevertBody | `url` |
| srvProbeUnreachable | `status` |
| srvProbeLatency | `ms` |

One generic key added: `refresh` (there was no plain `refresh`; `retry`/`cancel`
already exist and are reused).

---

## New endpoints (integrator must wire — `urls.py`/views are NOT in my surface)

#178 drives three calls. Wire them (owner/superuser gated) backed by
`core.logic.admin_flags`. Suggested shapes (what the client sends/expects):

| method | path | body | response |
|---|---|---|---|
| GET | `/api/v1/admin/flags` | — | `{flags:[{id,kind,group,value,default,is_cost}], audit:[{flag,kind,old,new,actor,reason,at,confirm_code}], summary:{...}, can_manage:bool}` |
| GET | `/api/v1/admin/flags?probe=1` | — | `{can_manage:bool}` (role probe; the screen also catches 403) |
| POST | `/api/v1/admin/flags/flip` | `{flag, value, reason}` | same shape as GET (fresh snapshot incl. the new audit row) |

Server MUST re-validate every flip with `admin_flags.validate_flip` /
`apply_flip` (reject blank reason where the gate requires it → HTTP 400 with the
`problems` list; 403 for non-owners). The persisted flag state + audit rows are
a backend concern; `admin_flags` builds the audit entry for you
(`make_audit_entry(...)` — caller supplies `actor` id/label + ISO timestamp).
Until these endpoints exist the screen degrades honestly (owner-only / error +
retry). **No live endpoint is required for the pure-logic tests to pass.**

#179 does **not** add a server endpoint. It reuses the existing
`GET /api/v1/health` (AllowAny) purely as a reachability probe, on its own
client.

---

## Integrator wiring

1. **#178 endpoints** — add `GET /admin/flags`, `GET /admin/flags?probe=1`,
   `POST /admin/flags/flip` (owner/superuser gated) to `urls.py`/views, backed by
   `core.logic.admin_flags`. Persist the flag state + append-only audit rows.

2. **#179 apply** — for the saved base-URL override to actually take effect
   app-wide, make `api.dart` read it. The honest one-liner: at app start (where
   `ApiClient`/`AppConfig` is first used), call
   `await ServerConfig.effectiveBase()` and use it as the base. Because
   `AppConfig.apiBase` is a compile-time `const`, this is the ONE place the
   override has to be threaded in — the swap screen already validates, probes,
   persists and reverts, and its copy (`srvApplyNote`) states that the change
   applies after relaunch / this wiring. Nothing I changed touches `api.dart`.

3. **ARB** — merge `up_adminb_arb.json` (`merge_arb.py`); regenerate localizations.

4. **Entry points** — already added (owner/operator block in `_MsgrSettingsSection`).

---

## Tests added

- `backend/core/logic/admin_flags_tests_snippets.py` — **18** tests, all passing
  (`python admin_flags_tests_snippets.py` → `admin_flags: 18 tests passed`; also
  discovered by Django as `core.tests.AdminFlagsSnippetTests`, 18 tests).
  Covers: catalog shape/uniqueness, confirm-gate both-directions for cost vs
  disable-only for features, validation (unknown/bad-value/no-op/reason-required),
  pure `apply_flip` + audit entry, `normalize_state` coercion/default-fill,
  `summarize`, and an owner kill-then-restore scenario.

---

## Section-21 acceptance

- **Honest states**: #178 has loading (skeleton) / empty / error+retry /
  owner-only; #178 per-flag busy spinner; #179 has idle / checking / reachable
  (+latency) / unreachable (+status) / error probe states, plus a loading gate.
- **Confirm gates for destructive/cost actions**: #178 fires a typed-reason
  confirm for every cost flip (both directions) and every feature DISABLE
  (mirrors the backend gate); #179 confirms before switching servers (sterner
  warning when unverified) and before reverting.
- **Audit**: #178 renders an append-only who/what/old→new/when/why timeline
  (`AdminTimelineEntry`) with an explicit "can't be edited or deleted" note.
- **bn/en**: all copy via `AppLocalizations`; real Bangla in the ARB; zero Bangla
  codepoints (U+0980–U+09FF) in any `.dart` (codepoint-scanned).
- **Owner/superuser gated**: entry pre-gated (`moderationWhoAmI`), backend 403 →
  owner-only state; #179's override is a local owner action, revert always one tap.
- **Never holds money / no server-side pricing touched**: a kill switch toggles a
  capability only; `admin_flags` never computes a price or moves money.
- **No clipped text at 360dp**: cards use `Expanded`/wrap, tiles ellipsis-free
  multi-line, scrollable lists with `RefreshIndicator`.
