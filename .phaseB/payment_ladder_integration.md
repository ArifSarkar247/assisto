# Payment / Auto-pay Ladder (SPEC v2.1 §21) — integration needs

Advanced escalating payment-collection / auto-pay reminder ladder for (a) money
the user is **OWED** (receivables / dues — reuses the khata/tagada concept) and
(b) bills / EMIs the user **OWES** (payables). Scope kept to the allowed edit
set; this file lists what the backend / API / model must gain so the new UI
persists everything it collects. Nothing below was applied (`models.py` /
`serializers.py` / `urls.py` / `api.dart` were out of scope).

## HARD PRODUCT RULES (enforced structurally — do not relax when wiring)
- **Never hold money.** The engine custodies no balance. `payment_ladder.holds_money()`
  and `ladder_common.kHoldsMoney` are constant `False`. Do not add a wallet balance.
- **Never auto-charge.** No step moves money on its own. `charges_money()` /
  `kChargesMoney` are constant `False`. Every step is a reminder / share / notify.
- **Key-gated payments.** Actually *paying* a payable bill requires the owner's
  OWN licensed payment key (bKash / Nagad / a licensed partner). Without a key,
  the `pay_key` action is downgraded to `pay_manual` (open the owner's own wallet
  / show instructions) by `resolve_pay_action()` / `resolvePayAction()`.
  `can_execute_pay(ladder, has_key)` is the single gate the wire must respect
  before touching any payment rail. We never act as a wallet.

## Files created
- **New** `app/lib/screens/payment_ladder_screen.dart` — two-tab screen
  (Owed to me / I owe), hero totals, due-now section, per-debt card with the
  current rung + "Do this step", mark-paid, snooze, swipe-to-delete, timeline
  sheet, honest no-money + key-gate banners. All §21 states (empty/loading/
  error/offline/bilingual/WCAG) present.
- **New** `app/lib/widgets/ladder_common.dart` — pure Dart engine mirroring the
  Python one (integer-poisha money, due-step/next-step decision, schedule,
  record-payment roll, validation, key gate, bn digits via code points, labels/
  icons). Zero Bangla code points.
- **New** `app/lib/widgets/ladder_cards.dart` — presentation atoms (hero,
  no-money banner, section header, step row, debt card).
- **New** `app/lib/widgets/ladder_builder_sheet.dart` — the advanced ladder
  BUILDER: party/amount/paid/due/recurring/stop-on-payment + per-step timing
  (slider over day offsets, negative = before due), action and channel pickers.
- **New** `backend/core/logic/payment_ladder.py` — pure deterministic engine
  (no Django / DB / net / clock; every `now` is an argument).
- **New** `backend/core/logic/payment_ladder_tests_snippets.py` — 24 plain-assert
  tests, `run_all()` green; registered in `core/tests.py` as
  `PaymentLadderSnippetTests` (folded into the Django suite).
- **New** `.phaseB/payment_ladder_arb.json` — 90 keys, `{key:[bn,en]}`.

## Why it's advanced (vs the existing stub)
`models.AutoPayRule` is a flat 3-step single-biller stub. This module is a full
per-debt **escalation ladder engine**: N ordered steps, each with its own timing
(offset in days from the due date; negative = before due for payable heads-ups),
its own action, and its own channel; a stop-on-payment rule; partial-payment
tracking; recurring-bill roll-forward; a pure due-step decision that supersedes
earlier rungs; a full past/due/upcoming timeline; and the structural
never-hold / no-auto-charge / key-gated invariants. The same decision runs
identically in Python (server/reminders) and Dart (offline client).

## What the UI needs the backend to persist
The screen reads two generic owned collections via the existing
`api.listItems/createItem/updateItem/deleteItem` helpers (same shape as
`autopay`). Register two `OwnedViewSet`s (mirrors `AutoPayRuleViewSet`):

```
router.register("ladder-receivable", views.LadderReceivableViewSet, basename="ladder-receivable")
router.register("ladder-payable",    views.LadderPayableViewSet,    basename="ladder-payable")
```

Each GET returns a JSON array of **debt rows with a nested `ladder` object**:

```json
[{
  "id": 1,
  "kind": "receivable",
  "party": "Rahim Store",
  "amount_poisha": 60000,
  "paid_poisha": 20000,
  "due_date": "2026-02-01",
  "recurring_days": 0,
  "paused": false,
  "ladder": {
    "stop_on_payment": true,
    "has_payment_key": false,
    "steps": [
      {"offset_days": 0,  "action": "remind_gentle", "channel": "in_app"},
      {"offset_days": 3,  "action": "remind_firm",   "channel": "whatsapp_share"},
      {"offset_days": 7,  "action": "final_notice",  "channel": "sms"},
      {"offset_days": 14, "action": "escalate_owner","channel": "in_app"}
    ]
  }
}]
```

The create/update body the client sends is exactly this debt map with `ladder`
nested. `mark paid` PATCHes `{paid_poisha, due_date?}`; snooze PATCHes
`{paused}`; delete is DELETE `/{id}/`.

### Suggested models (no live-table edits applied)
```python
class PaymentDebt(models.Model):
    KINDS = [("receivable", "owed to me"), ("payable", "I owe")]
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="payment_debts")
    kind = models.CharField(max_length=10, choices=KINDS, default="receivable")
    party = models.CharField(max_length=120)
    amount_poisha = models.BigIntegerField(default=0)   # INTEGER POISHA (no float)
    paid_poisha = models.BigIntegerField(default=0)
    due_date = models.DateField(null=True, blank=True)
    recurring_days = models.PositiveIntegerField(default=0)  # >0 ⇒ repeating bill
    paused = models.BooleanField(default=False)
    # The ladder config as emitted by the builder. JSONField keeps it migration-
    # light and matches the deterministic shape payment_ladder.py validates.
    ladder = models.JSONField(default=dict, blank=True)
    # has_payment_key lives on the ladder json OR as a per-user owner setting;
    # the engine reads ladder["has_payment_key"].
    updated_at = models.DateTimeField(auto_now=True)
    class Meta:
        ordering = ["due_date", "id"]
```
`kind` is fixed per collection (the two viewsets filter it), so a single model
backs both tabs. Reuse the existing `KhataParty` dues as the source for
receivables if you prefer to avoid a new table: map a party's net due →
`{kind:"receivable", party, amount_poisha, due_date}` and attach a ladder.

### Serializer
Expose all fields above; validate `ladder` on save with
`payment_ladder.validate_ladder(ladder)` → map the returned codes
(`bad_kind/no_steps/bad_step/bad_channel/duplicate_offset/no_auto_charge`) to
localised messages (the engine stays language-free). **Reject `no_auto_charge`
always** — there is no auto-charge action in the vocabulary.

## Server-side firing (reuse the reminders engine)
The engine is the single source of truth for *which rung fires when*:

```python
from core.logic import payment_ladder as PL
step = PL.due_step(debt_dict, ladder_dict, now=date.today())
```

For scheduled/foreground delivery, feed each debt's `due_date + step.offset_days`
at 09:00 into the existing `core/logic/reminders_engine.py` (one-shot anchors —
no new recurrence code). Per MEMORY, there is no background WorkManager; surface
due steps on the existing foreground `/alerts` poll (app open/resume). A
`autopay/stop-all`-style endpoint already exists for the old stub; add an
equivalent `ladder/stop-all` (set `paused=True` for all of a user's debts) if a
global snooze is wanted.

## Channel hand-off (client, never auto-send)
`_SharePreview` in the screen shows the prefilled message and a single button.
Wire its `onPressed` to the app's existing share helper (same one Messenger /
tagada use):
- `whatsapp_share` → `wa.me` / WhatsApp share intent, prefilled with
  `plMsgReceivable` / `plMsgPayable`.
- `sms` → `sms:` URI to the user's OWN SMS app, prefilled. The user presses Send.
- `in_app` → a local notification only.
We NEVER send on the user's behalf. The `pay_key`/`pay_manual` dialog already
discloses the key-gate before any wallet hand-off.

## ARB
`.phaseB/payment_ladder_arb.json` — **90 keys**, every value a `[bn,en]` pair.
Merge into `app/lib/l10n/app_bn.arb` / `app_en.arb` and regenerate
`AppLocalizations` (same step as every prior module). Placeholder keys used by
the UI: `plActionDueCount{count}`, `plStepN{n}`, `plOutstanding{amount}`,
`plOffsetAfter/Before{n}`, `plNextIn{n}`, `plDaysOverdue{n}`, `plDueInDays{n}`,
`plMsgReceivable{party,amount}`, `plMsgPayable{party,amount}`,
`plMarkPaidBody{party,amount}`, `plMarkedPaid{party}`, `plDeleteBody{party}`.
Until merged, `dart analyze` reports only `undefined_getter` for the `pl*` keys
(98 such, zero other issues) — identical to how every prior module shipped.

### Sidebar / navigation (out of scope here)
Add a drawer entry routing to `PaymentLadderScreen` (`payment_ladder_screen.dart`)
when wiring — `sidebar_sections.dart` was out of scope for this change.

## Verification
- `python3 backend/core/logic/payment_ladder_tests_snippets.py` →
  `payment_ladder: 24 tests passed`. Covers: escalation timing (which rung fires
  at +0/+3/+7/+14, highest-rung supersedes), stop-on-payment (silences when paid;
  partial keeps chasing; `stop_on_payment=false` keeps firing), paused silence,
  never-hold / no-auto-charge invariants, the key gate (`pay_key`→`pay_manual`
  without a key; survives with one), payable before-due heads-up, record-payment
  clamp + no-mutation + recurring roll, schedule statuses, validation, summary.
- `python3 manage.py test core` picks up `PaymentLadderSnippetTests`.
- Zero Bangla code points in any `.dart` (taka sign via `৳`; all copy via
  AppLocalizations). ARB validated: 90 keys, every value a `[bn,en]` pair.
- `dart analyze` on the four new `.dart` files: 0 issues other than the pending
  `pl*` AppLocalizations getters (resolved by the ARB merge above).
```
