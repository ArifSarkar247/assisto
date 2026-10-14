# PA Secretary Mode — Visitor Filter (#105) + Liaison & Follow-up (#108)

SPEC v2.1 §14, built to the §21 **advanced** standard. All NEW files. No shared
files edited except **one** registration block in `core/tests.py`. No touches to
api.dart, core/models.py, core/urls.py, sidebar, app_*.arb, migrations, or
Asalify.

---

## New files

Frontend (Flutter):
- `app/lib/screens/pa/visitor_filter_screen.dart` — #105 visitor/appointment
  triage queue.
- `app/lib/screens/pa/liaison_screen.dart` — #108 liaison & follow-up tracker.

Backend (pure deterministic logic, no DB / no clock / no AI):
- `backend/core/logic/pa_visitor.py`
- `backend/core/logic/pa_visitor_tests_snippets.py` (27 tests)
- `backend/core/logic/pa_liaison.py`
- `backend/core/logic/pa_liaison_tests_snippets.py` (28 tests)

Spec artefacts:
- `.phaseB/up_pa2_arb.json` — 78 new ARB keys (incl. `_params`).
- `.phaseB/up_pa2_integration.md` — this file.

> Naming is deliberately disjoint from the parallel PA agent (which owns
> `pa_schedule.py` / `pa_brief.py` + schedule/brief screens). No collisions.

---

## ARB keys (78 new) + `_params`

Emitted in `.phaseB/up_pa2_arb.json` as `{"key":["<bn>","<en>"], ...}`. Bangla is
real and natural; zero Bangla literals in any `.dart`. Merge into `app_en.arb`
(en = index 1) and `app_bn.arb` (bn = index 0) with the standard merge tool, then
`gen-l10n`.

Two keys are **general-purpose** (not PA-specific) and were MISSING from the ARB:
`saveFailed`, `deleteFailed`. The rest are prefixed `paVis*` (#105, ~37 keys) and
`paLia*` (#108, ~39 keys).

Parameterised keys (declared in `_params`):
- `paVisContactHidden {hint}`, `paVisApproveConfirmBody {name}`,
  `paVisDeclineConfirmBody {name}`, `paVisDeleteConfirmBody {name}`,
  `paVisSummary {needs} {pending} {expired}`
- `paLiaWith {name}`, `paLiaContactHidden {hint}`, `paLiaNextNudge {date}`,
  `paLiaOverdueBanner {count}`, `paLiaOverdueBy {days}`, `paLiaDueInDays {days}`,
  `paLiaDeleteConfirmBody {title}`

`localeName` is the intrinsic `AppLocalizations.localeName` field (used for
locale-aware `intl.DateFormat`), not an ARB key — do not add it.

---

## Tests (55 new) + the single registration line

`backend/core/tests.py` — one block added (after the `MsgChannelSnippetTests` /
the other PA agent's `PaBrief` registration), following the `_make_snippet_case`
pattern used by `SocialComposeSnippetTests`:

```python
PaVisitorSnippetTests = _make_snippet_case(
    "core.logic.pa_visitor_tests_snippets", "PaVisitorSnippetTests")
PaLiaisonSnippetTests = _make_snippet_case(
    "core.logic.pa_liaison_tests_snippets", "PaLiaisonSnippetTests")
```

Both suites pass standalone and import cleanly under the Django harness
(`manage.py test` discovers 55 cases; they need no DB — pure asserts).

---

## Endpoints the screens call

The screens use the **existing generic collection helpers** in `api.dart`
(`listItems` / `createItem` / `updateItem` / `deleteItem`) — **no api.dart edit
required**. The integrator must mount two DRF collections so these resolve:

### `/api/v1/pa/visitors/` (#105)
- `GET  /api/v1/pa/visitors/` → list of the owner's visitor requests (JSON array).
- `POST /api/v1/pa/visitors/` → create. Body: `{name, reason, contact?,
  priority(vip|normal), requested_at?(ISO8601)}`.
- `PATCH /api/v1/pa/visitors/{id}/` → triage / priority / edit. Bodies sent:
  - approve: `{"status":"approved"}`
  - decline: `{"status":"declined"}`
  - suggest: `{"status":"suggested","requested_at":<ISO>,"suggested_at":<ISO>}`
  - priority: `{"priority":"vip"|"normal"}`
  - edit: full field set from the form.
- `DELETE /api/v1/pa/visitors/{id}/`.

### `/api/v1/pa/followups/` (#108)
- `GET  /api/v1/pa/followups/` → list of the owner's follow-ups.
- `POST /api/v1/pa/followups/` → create. Body: `{title, counterpart, contact?,
  nudge(off|daily|every_3_days|weekly), due_at?(ISO8601|null)}`.
- `PATCH /api/v1/pa/followups/{id}/` → status / edit. Bodies sent:
  - status: `{"status":"waiting"|"replied"|"done", "completed_at":<ISO|null>}`
  - edit: full field set from the form.
- `DELETE /api/v1/pa/followups/{id}/`.

The **server views should delegate all derived computation** (effective status /
expiry, overdue, urgency, ordering, counts, next-nudge, the privacy-minimised
projection) to `pa_visitor.py` / `pa_liaison.py` — the Dart screens already
mirror that logic exactly for offline-correct previews, so the two must stay in
lockstep. Pass the request time in as `now` (e.g. `timezone.now().isoformat()`);
never read the clock inside the pure modules.

---

## Models the integrator must create (describe only — NOT added here)

Add to `core/models.py` + one migration (DB backup first, per protocol).

### `PaVisitorRequest`  (#105)
| field | type | why |
|---|---|---|
| `user` | FK(User, on_delete=CASCADE) | owner-scoped; a PA acts for one owner. |
| `name` | CharField | visitor name — required (see `validate`). |
| `reason` | TextField | reason for the visit — required. |
| `contact` | CharField(blank) | raw phone/email. **Never returned in list rows** — `public_view()` strips it to a masked hint; only a single detail endpoint may expose the raw value. Store minimally. |
| `priority` | CharField(choices=vip/normal, default=normal) | VIP/normal triage tag. |
| `status` | CharField(choices=pending/approved/declined/suggested, default=pending) | STORED status. `expired` is **derived** at read time — do NOT add it as a stored choice. |
| `requested_at` | DateTimeField(null) | asked-for slot; optional (walk-ins). Drives computed expiry + ordering. |
| `suggested_at` | DateTimeField(null) | set when the owner reschedule-suggests. |
| `created_at` / `updated_at` | auto | audit. |

### `PaFollowUp`  (#108)
| field | type | why |
|---|---|---|
| `user` | FK(User, on_delete=CASCADE) | owner-scoped. |
| `title` | CharField | what's being chased — required. |
| `counterpart` | CharField | who it's with — required. |
| `contact` | CharField(blank) | raw phone/email — same privacy rule as above; masked in lists. |
| `status` | CharField(choices=waiting/replied/done, default=waiting) | open vs closed. |
| `due_at` | DateTimeField(null) | due date; optional. Drives computed overdue/urgency. |
| `nudge` | CharField(choices=off/daily/every_3_days/weekly, default=off) | nudge-reminder cadence. |
| `last_nudged_at` | DateTimeField(null) | anchor for `next_nudge_at` so a dormant item never fires a backlog of missed slots. Set by the scheduler when a nudge fires. |
| `completed_at` | DateTimeField(null) | stamped on `done`, cleared on re-open. |
| `created_at` / `updated_at` | auto | audit. |

Serializers should run list payloads through `public_view(row, now)` so raw
contact never fans out. A dedicated detail/reveal action can expose the raw
`contact` if the product wants a tap-to-call.

Nudge delivery (if/when wired to notifications): the scheduler calls
`pa_liaison.nudge_due(item, now)` to decide whether to emit, then stamps
`last_nudged_at = now`. Pure module decides nothing about transport.

---

## Sidebar entry (spec only — do NOT edit the sidebar here)

Per MEMORY the sidebar is owner-authoritative (`.phaseB/SIDEBAR_LAYOUT.md`, each
module ONE place, chat-openable with bn/en synonyms). PA Secretary Mode belongs
in the **Work** group. Suggested two chat routes + synonyms (coordinate with the
parallel PA agent's schedule/brief entries so PA Secretary reads as one section):

- Visitor filter — en: "Visitors", "Appointment requests", "Who's visiting";
  bn: "ভিজিটর", "অ্যাপয়েন্টমেন্ট", "দর্শনার্থী" → opens `VisitorFilterScreen`.
- Liaison & follow-up — en: "Follow-ups", "Liaison", "Chasing";
  bn: "ফলো-আপ", "যোগাযোগ", "তাড়া দেওয়া" → opens `LiaisonScreen`.

---

## Wiring checklist (integrator)

1. Merge `.phaseB/up_pa2_arb.json` → `app_en.arb` (idx 1) + `app_bn.arb` (idx 0);
   `gen-l10n`.
2. Add `PaVisitorRequest` + `PaFollowUp` to `core/models.py`; `makemigrations`
   (DB backup first), `migrate`.
3. Add DRF viewsets + routes for `/api/v1/pa/visitors/` and
   `/api/v1/pa/followups/` (owner-scoped querysets; list via `public_view`).
   Views delegate derived logic to the pure modules with an explicit `now`.
4. Add the two chat routes + synonyms under **Work** (with the other PA agent).
5. `flutter analyze` (0 errors), lang gate (already CLEAN), backend tests
   (55 new PA cases discovered + pass).
6. Gallery: render both screens × bn/en × light/dark (welcome, populated,
   filtered-empty, confirm dialogs).

---

## Advanced-standard notes (§21)

- **Honest states** everywhere: first-use welcome, loading skeleton, error +
  retry, filter-empty (distinct from no-data), masked contact.
- **Confirm gates**: approve + decline (committing), delete (destructive) all
  gated; suggest opens a time picker (not gated — reversible proposal).
- **Deterministic, key-free, no AI**: Dart mirrors the Python exactly; `now`
  is always injected on the server side; identical inputs → identical output.
- **Conservative privacy**: `public_view()` returns `has_contact` + a masked
  `contact_hint` (last 4 chars, dot-padded with U+00B7 — outside the Bangla
  gate range); raw phone/email never enters a list row, log, or export.
- **Honest overdue**: computed from the passed-in `now`; `done` is never
  overdue; no due date is never overdue.
- **No-backlog nudges**: `next_nudge_at` advances strictly past `now` so a
  long-dormant follow-up fires once, not a flood of missed slots.
- **360dp safe**: all labels `maxLines`/`ellipsis` guarded; action rows use
  `Expanded`; metadata uses `Wrap` to avoid overflow.

## Zero-Bangla confirmation

`grep -P "[\x{0980}-\x{09FF}]"` over both new `.dart` files → **no matches**.
`app/tool/lang_gate.py` → **LANG GATE: clean ✓**.
