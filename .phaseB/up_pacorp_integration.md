# PA Secretary Mode · CORPORATE tier — integration note

SPEC v2.1 §14 — **#116 Board-meeting pack**, **#117 Departmental update**,
**#118 VIP & stakeholder**. Built to the §21 ADVANCED standard: deterministic /
mock (works with **no key**), honest "AI-generated — review" markers, honest
"connect an AI key" seams, conservative privacy on VIP data. Original Assisto
identity. **Zero Bangla literals** in any `.dart` (every string is an
`AppLocalizations` getter). Asalify untouched; `api.dart`, `core/models.py`,
`core/urls.py`, sidebar, `app_*.arb`, migrations, `pa_hub_screen.dart` **not
edited by this build** (the hub tiles + ARB merge are the integrator's one-time
paste steps below).

---

## 1. New files

### Flutter screens (new)
- `app/lib/screens/pa/board_pack_screen.dart`  — #116, `BoardPackScreen`
- `app/lib/screens/pa/dept_update_screen.dart` — #117, `DeptUpdateScreen`
- `app/lib/screens/pa/vip_stakeholder_screen.dart` — #118, `VipStakeholderScreen`

### Backend logic (new, pure — no Django/DB/network/clock/AI)
- `backend/core/logic/pa_board.py`  — board-pack assembler (`build`, `validate`, `count_attendance`)
- `backend/core/logic/pa_dept.py`   — departmental roll-up (`rollup`, `validate`)
- `backend/core/logic/pa_vip.py`    — VIP status engine (`summarise`, `status_for`, `effective_next_touch`, `validate`)

### Backend tests (new, plain-assert; mirror the live logic)
- `backend/core/logic/pa_board_tests_snippets.py`  — 15 checks
- `backend/core/logic/pa_dept_tests_snippets.py`   — 13 checks
- `backend/core/logic/pa_vip_tests_snippets.py`    — 15 checks

### Already wired by this build (the one allowed `core/tests.py` edit)
Three `_make_snippet_case` registrations added after `PaLettersSnippetTests`
(class `SocialComposeSnippetTests` precedent): `PaBoardSnippetTests`,
`PaDeptSnippetTests`, `PaVipSnippetTests`. All 43 discovered + pass.

---

## 2. ARB keys — `up_pacorp_arb.json`

- **119 new keys**, each `"key": ["bn", "en"]`. Bangla is real & natural; `৳` is
  exempt (passes through user data). Merge `bn` → `app_bn.arb`, `en` →
  `app_en.arb` (keep `@`-metadata in `app_en.arb` only), then add the
  **19 parameterized keys** from the file's `_params` block to the merge
  script's `PARAMS` map, then `flutter gen-l10n`.
- **REUSED (not re-emitted):** `cancel`, `copy`, `copied`, `delete`,
  `deleteFailed`, `loadFailed`, `retry`, `save`, `saveFailed`, `share`,
  `paAiReviewMarker`.
- Parameterized keys (`_params`): `paBoardAgendaCount{n}`, `paBoardResCount{n}`,
  `paBoardDeleteBody{title}`, `paBoardRollupAttendance{breakdown}`,
  `paBoardQuorumMet{count}`, `paBoardQuorumShort{count}`, `paBoardToVote{n}`,
  `paBoardTotalMinutes{n}`, `paDeptDeleteBody{dept}`, `paDeptRollReporting{n}`,
  `paDeptRollBlocked{n}`, `paDeptRollHighlights{n}`, `paDeptRollBlockers{n}`,
  `paVipDeleteBody{name}`, `paVipBannerOverdue{n}`, `paVipBannerDueSoon{n}`,
  `paVipStatusOverdue{n}`, `paVipStatusDueSoon{n}`, `paVipStatusOnTrack{date}`.
- Verified: every `tr.*` getter used in the three new screens is either emitted
  here or in the reused set (0 missing); every emitted key is used (0 extra);
  all 19 param placeholders match between bn and en.

---

## 3. Persistence — generic REST collections (no migration)

Add these **three** strings to `GENERIC_COLLECTIONS` in `backend/core/views.py`
(the existing list that drives `GENERIC_COLLECTION_VIEWSETS` via `type()` over
`PaCollectionViewSet`; each row is a user-scoped `PaCollectionItem`, flattened by
`PaItemSerializer`). No model, serializer, URL or migration change — this is the
established pattern (precedent: `"pa/letters"`, `"pa/callemail"`, …).

```python
    # PA Secretary CORPORATE tier (§14 #116/#117/#118) — deterministic mock
    "pa/board", "pa/deptupdates", "pa/vip",
```

Resulting `kind` (auto, `name.replace("/", "_")`): `pa_board`, `pa_deptupdates`,
`pa_vip`. The screens call the generic api helpers already present in
`api.dart` — **no `api.dart` edit**:
`listItems(path)`, `createItem(path, body)`, `updateItem(path, id, body)`,
`deleteItem(path, id)`.

### Row shapes (each a `PaCollectionItem.data` JSON blob)

**`pa/board`** — one saved board pack:
```jsonc
{
  "title": "Q3 Board Meeting",
  "date": "2026-10-14",                 // free string, shown verbatim
  "quorum": 3,                          // int >= 0 (0 = none)
  "agenda":      [{"title": "...", "presenter": "...", "minutes": 20}],
  "documents":   [{"title": "...", "ref": "A1"}],
  "attendees":   [{"name": "...", "role": "...", "status": "present|apology|absent"}],
  "resolutions": [{"text": "...", "proposer": "...", "seconder": "..."}]
}
```

**`pa/deptupdates`** — one department's update (one row **per department**;
the list screen rolls them up client-side, mirroring `pa_dept.rollup`):
```jsonc
{
  "department": "Sales",
  "lead": "Karim",
  "highlights": "one point per line\nsecond point",   // newline-split
  "blockers":   "one blocker per line",               // newline-split
  "metrics":    [{"label": "Pipeline", "value": "৳4.2L"}]  // value verbatim, never computed
}
```

**`pa/vip`** — one stakeholder contact (privacy-sensitive; notes + log stay on
the row and never enter any roll-up):
```jsonc
{
  "name": "Mr Rahman",
  "org": "Acme Ltd",
  "tier": "strategic|key|standard",
  "last_touch": "2026-09-01",           // YYYY-MM-DD or ""
  "next_touch": "2026-10-20",           // YYYY-MM-DD or "" (derived if blank)
  "cadence_days": 30,                   // int >= 0
  "notes": "private free text",         // never surfaced in roll-ups
  "log": [{"date": "2026-09-01", "note": "what happened"}]
}
```

---

## 4. AI seams (honest, key-gated, never fabricate)

- **#116 board pack** — `pa_board.build(..., want_ai_summary=True)` sets
  `ai_required=True` and the deterministic cover/outline is **still fully
  assembled** (prose never faked). UI shows `paBoardAiSeamTitle/Body`
  ("connect an AI key → Anthropic" for an AI-written **executive summary**).
  Integrator wires to `core.ai.generate` (Anthropic) for the real path; request
  shape = the assembled pack dict.
- **#117 dept update** — `pa_dept.rollup(..., want_ai_synthesis=True)` sets
  `ai_required=True`; the structured roll-up is **always produced**. UI shows
  `paDeptAiSeamTitle/Body` for an AI-written **synthesis narrative**.
- **#118 VIP** — **fully deterministic, no AI path** (conservative privacy; no
  "AI writes your relationships"). Nothing to wire; nothing can be fabricated.
- Every engine result carries `mock=True` + `marker="ai_review"`; the UI renders
  the reused `paAiReviewMarker` chip wherever a draft/roll-up is shown.

---

## 5. PA-hub tiles — ready-to-paste (integrator edits `pa_hub_screen.dart`)

Add the imports:
```dart
import 'board_pack_screen.dart';
import 'dept_update_screen.dart';
import 'vip_stakeholder_screen.dart';
```
Append to the `tools` list in `PaHubScreen.build` (same `_PaTool(icon, title, builder)`
shape the hub already uses — each tile reuses the screen's own title ARB key, so
the hub stays string-free):
```dart
      _PaTool(Icons.groups_2_outlined, t.paBoardTitle,
          (_) => const BoardPackScreen()),
      _PaTool(Icons.insights_outlined, t.paDeptTitle,
          (_) => const DeptUpdateScreen()),
      _PaTool(Icons.handshake_outlined, t.paVipTitle,
          (_) => const VipStakeholderScreen()),
```

| # | Screen | Icon | Title ARB key (tile label) |
|---|--------|------|----------------------------|
| 116 | `BoardPackScreen` | `Icons.groups_2_outlined` | `paBoardTitle` |
| 117 | `DeptUpdateScreen` | `Icons.insights_outlined` | `paDeptTitle` |
| 118 | `VipStakeholderScreen` | `Icons.handshake_outlined` | `paVipTitle` |

---

## 6. Tests & wiring summary

- `core/tests.py`: 3 `_make_snippet_case` lines added (the single allowed edit).
  `python manage.py test` discovers **43** new checks (15 + 13 + 15); all pass
  standalone and via the Django import path.
- Determinism verified: `build`/`rollup`/`summarise` are pure; dates & `now` are
  passed in (no clock) so the Dart mirrors and the Python engines agree offline.
- Privacy verified (`pa_vip` test `test_summarise_privacy_never_leaks_notes_or_log`):
  the roll-up payload carries only `name, org, tier, status, due_date, days` —
  never notes or log bodies.

## 7. Integrator checklist
1. Merge `up_pacorp_arb.json` into `app_bn.arb` / `app_en.arb`; add the 19
   `_params` keys to the merge script's `PARAMS`; `flutter gen-l10n`.
2. Add the 3 strings to `GENERIC_COLLECTIONS` in `core/views.py`.
3. Add the 3 imports + 3 `_PaTool` tiles to `pa_hub_screen.dart` (§5 above).
4. (Optional, later) wire the two AI seams to `core.ai.generate` (Anthropic).
