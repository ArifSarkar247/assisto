# Action Center & audit log — ADVANCED upgrade: integration needs

SPEC v2.1 §21, feature #9 ("Action center & audit log"). This file lists what
the backend must gain so the new Action Center UI is fully wired. Scope was
kept to the allowed edit set — **no** `models.py` / `serializers.py` / `urls.py`
changes were applied (migrations are out of scope), so the PENDING approval
queue is documented here and degrades honestly in the app until it ships.

## Files changed / created (app side)
- **New** `app/lib/screens/action_center_screen.dart` — two-tab Action Center:
  WAITING (pending approvals) + DONE (audit log). Transparency banner, honest
  loading/empty/error/offline states, pull-to-refresh, module filter, Undo.
- **New** `app/lib/action_api.dart` — `extension ActionCenterApi on ApiClient`
  built only on the public `getJson`/`postJson`/`audit` helpers (no api.dart
  edit). Holds all endpoint contracts below.
- **New** `app/lib/widgets/action_models.dart` — `PendingAction` model + pure
  helpers (module/type parsing, icon/colour/label maps, autonomy-level names).
- **New** `app/lib/widgets/action_cards.dart` — transparency banner, pending
  card (Approve/Reject/Edit), done tile (+Undo), module filter bar.
- **New** `app/lib/widgets/action_edit_sheet.dart` — review/edit-before-approve
  bottom sheet.
- **New** `.phaseB/up_action_arb.json` — 59 keys, `{en:{...}, bn:{...}}` + 3
  placeholder metas. ZERO Bangla in any `.dart`.

## Wiring the screen in (NOT done — touches disallowed files)
`settings_screen.dart` already has `AuditScreen` behind the `auditLogTile`.
Repoint that tile (or add a drawer entry) to `const ActionCenterScreen()` when
folding in. The old `AuditScreen` can stay or be retired — the new DONE tab is
a strict superset (icons, module labels, filter, undo).

## DONE tab — REAL endpoint today (no change needed)
`GET /api/v1/audit` → `AuditListView` → `AuditLog` (newest-first, 200 cap).
Each row: `{id, action, detail, created_at}`. The app reuses the existing
`AuditEntry` model and `ApiClient.audit()`. The `action` string is split on the
first dot into module/type for the icon, label and filter. No backend work.

## UNDO — REAL endpoint today (no change needed)
`POST /api/v1/undo` → `UndoView`: recreates the most-recently-DELETED item
within 180s (reads `AuditLog` rows `action__endswith=".delete"`,
`detail.undone != True`). The app only shows the Undo button when
`ActionCenterApi.isUndoable(entry)` is true (a `*.delete` not yet undone), so it
never offers an Undo that 404s. `undoLast()` treats 400/404 as "nothing to
undo" and shows an honest note rather than an error.

### Optional backend hardening for undo (safe, no migration)
Undo is currently "most-recent delete" only; the UI undoes per-row but the
backend always pops the newest. To make per-row undo exact, `UndoView` could
accept an optional `{audit_id}` in the POST body and restore that specific
entry instead of the newest candidate. Pure view logic, no schema change:
```python
# UndoView.post, after computing `candidates`:
aid = request.data.get("audit_id")
if aid:
    entry = next((e for e in candidates if e.id == aid and not e.detail.get("undone")), None)
else:
    entry = next((e for e in candidates if not e.detail.get("undone")), None)
```
The app already has the `audit_id` to hand (`AuditEntry.id` — add it to the
`actionHistory`/`undoLast` call when this lands).

## PENDING tab — NEW endpoints required (approval queue, autonomy level 3)
There is currently **no** model for actions the AI has *prepared but not yet
run*. The `log(user, action, **detail)` helper only records things that already
happened. Feature #9 + the autonomy dial (§21, level 3 = "prepare, run after
one approval") need a small queue.

### Suggested model (`core/models.py`) — needs one migration
```python
class PendingAction(models.Model):
    """An action the AI PREPARED and is holding for the user's approval
    (autonomy level 3). Never executed until approved; rejecting discards it.
    Executing one writes an AuditLog row exactly as a direct action would."""
    STATES = [("pending", "pending"), ("approved", "approved"),
              ("rejected", "rejected")]
    user = models.ForeignKey(User, on_delete=models.CASCADE,
                             related_name="pending_actions")
    action = models.CharField(max_length=80)          # same vocab as AuditLog
    module = models.CharField(max_length=24, blank=True)
    title = models.CharField(max_length=200)
    summary = models.TextField(blank=True)            # e.g. drafted message body
    autonomy_level = models.PositiveSmallIntegerField(default=3)
    payload = models.JSONField(default=dict, blank=True)  # how to run it
    state = models.CharField(max_length=9, choices=STATES, default="pending")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
```

### Endpoints (add to `core/urls.py` + a view; `core/logic` may hold the pure
executor so it is unit-testable)
| method / path | body | returns | notes |
|---|---|---|---|
| `GET /actions/pending` | — | `{pending:[{id, action, module, title, summary, autonomy_level, created_at, detail}]}` | only `state="pending"` for `request.user`. `detail` = `payload` so the edit sheet can show/seed it. |
| `POST /actions/{id}/approve` | `{edit?: {<field>: <value>}}` | `{ok: true, done: {...}}` | merge `edit` into `payload`, RUN the action, set `state="approved"`, write the matching `AuditLog` row. `edit` carries the user's tweak to a draftable field (`body`/`text`/`message`/`note`/`draft`). |
| `POST /actions/{id}/reject` | `{reason?}` | `{ok: true}` | set `state="rejected"`; log `action.reject` for the audit trail. |

The app degrades honestly without these: `pendingActions()` catches a 404 and
returns an empty list, so the WAITING tab shows "Nothing waiting" instead of an
error. Approve/Reject simply surface the server error via a snackbar if called
before the endpoints exist.

### Autonomy wiring (where the queue gets populated)
Anywhere the agent is about to take a non-trivial action it should branch on
`user.autonomy_level`:
- **1 (remind only)** — don't act; just surface a reminder/suggestion.
- **2 (suggest)** — surface a tappable suggestion (current behaviour).
- **3 (approve)** — create a `PendingAction` instead of running; it appears in
  the WAITING tab.
- **4 (auto within limits)** — run now + `log(...)` (never money/external
  without a prior per-case opt-in, per the model docstring).

## Honest-states checklist (Section-21 all 10 covered in the UI)
1. Pending list · 2. Approve · 3. Reject · 4. Edit-before-approve · 5. Done
chronological audit (what/when/module/outcome) · 6. Module filter · 7. Undo
where possible · 8. Transparency banner tied to the live autonomy level ·
9. Offline/error states · 10. Empty states (pending-empty, done-empty,
filter-empty) — all distinct and honest.
