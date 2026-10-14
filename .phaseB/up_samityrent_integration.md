# Section-20: Samity / committee (#184) + Landlord–tenant rent (#185)

SPEC v2.1 §20, built to the §21 ADVANCED standard. NEW work — thin modules on
the existing Money/Reminders foundation. Everything below is additive; the
integrator wires api.dart (NO edit needed — uses existing generic helpers),
backend viewsets/urls, sidebar, and merges the ARB. The ONLY edit made to an
existing file is the single registration block in `backend/core/tests.py`.

Both engines are PURE, deterministic, hold NO money
(`holds_money()`/`charges_money()` are constant `False`) and need no AI, no key,
no clock of their own (any "now"/month is passed in).

## New files

Backend (pure logic + self-tests):
- `backend/core/logic/samity.py` — #184. Rotating-savings (ROSCA) tracker.
  `to_poisha`, `active_members` (deterministic payout order), `validate`,
  `rotation` / `total_cycles` / `recipient_for_cycle`, `cycle_status` (the honest
  collected/pending reconciler — `expected == collected + pending`),
  `payout_status` (scheduled vs. recorded hand-over), `overview` (whole-round
  totals + received member ids), `next_turn` (skips already-received; honest
  round-complete). Integer poisha throughout.
- `backend/core/logic/landlord_tenant.py` — #185. Rent + utility-share tracker.
  `to_poisha`, `utility_amount` (fixed OR floor(total·num/den), no float),
  `monthly_bill` (itemised), `validate_unit`, `active_units`, `unit_month`
  (paid/partial/due + credit; `bill == paid + outstanding`), `month_summary`
  (portfolio totals reconcile), `arrears` (sum across an inclusive month range,
  year-rollover safe, reversed-range → empty honest), and `due_reminder_plan`
  (the DESCRIBE-ONLY reminder seam — `wired=False`, schedules nothing).
- `backend/core/logic/samity_tests_snippets.py` — 14 plain-assert tests.
- `backend/core/logic/landlord_tenant_tests_snippets.py` — 13 plain-assert tests.

Flutter (new screens + one shared engine mirror; ZERO Bangla glyphs in any
.dart — `app/tool/lang_gate.py` reports CLEAN; ৳ U+09F3 is gate-exempt):
- `app/lib/screens/samity_screen.dart` — #184. List of samitys + a detail screen
  (cycle picker, collected/pending hero, whose-turn payout card + confirm gate,
  per-member paid toggle, full rotation list with received badges, add/edit/
  delete + member add/remove).
- `app/lib/screens/landlord_tenant_screen.dart` — #185. Two tabs: **This month**
  (month picker, collected/due hero, per-unit expandable cards with itemised
  bill + record-payment sheet w/ receipt note + method) and **Arrears** (honest
  trailing-6-month window total + per-unit breakdown).
- `app/lib/widgets/samity_rent_common.dart` — on-device deterministic mirror of
  both Python engines (same numbers; backend tests pin the same cases) plus
  shared UI (`NoMoneyBanner`, `StatLine`, `StatusPill`, month helpers). Reuses
  `taka`/`fmtInt`/`takaToPoisha`/`poishaOf` from the existing
  `widgets/ladder_common.dart` so poisha math + Bangla digit/currency formatting
  can never drift between modules. Collection-path constants live here
  (`kColSamity`, `kColRentUnit`, …).

## Tests added

- `core/tests.py`: TWO registration lines (the one allowed edit), via the
  existing `_make_snippet_case` pattern (same as `SocialComposeSnippetTests`):
  `SamitySnippetTests` and `LandlordTenantSnippetTests`.
- 27 tests total (14 samity + 13 rent). All pass standalone:
  `python3 backend/core/logic/samity_tests_snippets.py`
  `python3 backend/core/logic/landlord_tenant_tests_snippets.py`
  (The Django runner collects all 27; test-DB creation is blocked in this sandbox
  by Postgres perms, unrelated to these pure tests.)

## ARB keys

`.phaseB/up_samityrent_arb.json` — **108 NEW keys** as `{"key":["<bn>","<en>"]}`,
plus a `_params` object listing placeholders for the **20 parameterized** keys.
Bangla is real, natural and correct; ৳ used for currency via the Dart formatter
(not in ARB strings). Parameterized keys + their placeholders:

- samity: `samityPerMemberChip{amount}`, `samityMembersChip{count}`,
  `samityDeleteBody{name}`, `samityRemoveMemberBody{name}`,
  `samityCycleOf{cycle,total}`, `samityExpectedLabel{amount}`,
  `samityPendingLabel{amount}`, `samityPaidCount{paid,total}`,
  `samityRecordPayoutBody{name,cycle}`, `samityNextTurn{name}`,
  `samityPaidFull{amount}`, `samityDueAmount{amount}`.
- rent: `rentDeleteUnitBody{label}`, `rentBilledLabel{amount}`,
  `rentDueLabel{amount}`, `rentStatusCounts{paid,partial,due}`,
  `rentBillPaid{paid,bill}`, `rentRecordFor{label,month}`,
  `rentArrearsWindow{from,to}`, `rentMonthsInArrears{count}`.

Also included (generic, shared by both screens): `commonOffline`,
`commonLoadFailedBody`, and `monthJan`..`monthDec` (the rent month picker +
arrears window need localised month names; none existed in the ARB).

REUSED existing getters (NOT re-emitted): `cancel, save, edit, delete, retry`.
Checked for NO collision with existing keys. Merge the 108 keys into
`app_bn.arb` / `app_en.arb` then regenerate `AppLocalizations`. Until merged,
`flutter analyze` on the three new files reports only
"getter isn't defined for AppLocalizations" for exactly these keys — they clear
the moment the keys land.

## Persistence — exact generic collection paths + row shapes

The screens persist ONLY via the EXISTING generic item helpers in `api.dart`
(`listItems/createItem/updateItem/deleteItem`) — NO api.dart edit. This is the
proven `PaCollectionItem` precedent: one flexible per-user JSON model + a flatten
serializer back arbitrary row shapes, and each `collection` is pinned by a
`PaCollectionViewSet` subclass so rows never leak across collections.

Collections used (constants in `samity_rent_common.dart`):

| path (REST)             | collection string         | row shape (JSON `data`) |
|-------------------------|---------------------------|-------------------------|
| `samity_groups`         | `samity_groups`           | `{name:str, amount_poisha:int, period:"weekly"\|"biweekly"\|"monthly"}` |
| `samity_members`        | `samity_members`          | `{samity_id:int, name:str, payout_order:int, active:bool}` |
| `samity_contributions`  | `samity_contributions`    | `{samity_id:int, member_id:int, cycle:int, paid:bool, paid_poisha?:int}` |
| `samity_payouts`        | `samity_payouts`          | `{samity_id:int, cycle:int, member_id:int, handed_over:bool}` |
| `rent_units`            | `rent_units`              | `{label:str, tenant_name:str, rent_poisha:int, active:bool, utilities:[{name:str, amount_poisha:int}  \| {name:str, share_of_poisha:int, share_num:int, share_den:int}]}` |
| `rent_payments`         | `rent_payments`           | `{unit_id:int, month:"YYYY-MM", paid_poisha:int, note:str, method:"cash"\|"bkash"\|"nagad"\|"bank"\|"other"}` |

Notes on access:
- The samity detail screen filters sibling collections by a query string, e.g.
  `GET /api/v1/samity_members/?samity_id=10`. The generic `listItems` helper
  already splits the slash before the query (`_withSlash`), so this round-trips.
  The viewset should honour a `samity_id` query filter (see below).
- All amounts are INTEGER POISHA. Utility shares accept either a fixed
  `amount_poisha` or a `share_of_poisha`+`share_num`/`share_den` fraction; the
  engine floors the fraction (never rounds up).

### Backend viewsets the integrator registers (describe-only; mirror PaCollection)

Register six `OwnedViewSet` collections exactly like
`PaVisitorsViewSet`/`PaFollowupsViewSet` (one model `PaCollectionItem` + the
`PaItemSerializer` flatten; each subclass pins its `collection`). Sketch:

```python
class _SamityGroupsVS(PaCollectionViewSet):      collection = "samity_groups"
class _SamityMembersVS(PaCollectionViewSet):     collection = "samity_members"
class _SamityContribVS(PaCollectionViewSet):     collection = "samity_contributions"
class _SamityPayoutVS(PaCollectionViewSet):      collection = "samity_payouts"
class _RentUnitsVS(PaCollectionViewSet):         collection = "rent_units"
class _RentPaymentsVS(PaCollectionViewSet):      collection = "rent_payments"
```
Register with matching basenames in `core/urls.py`:
`router.register("samity_groups", _SamityGroupsVS, "samity-groups")` … etc. Use
the underscore form (`samity_groups`, `rent_units`) — the screens call those
exact paths. `PaCollectionViewSet.get_queryset` already scopes to
`user=request.user, collection=…`; to support the `?samity_id=` filter, override
`get_queryset` to additionally filter `data__samity_id` when the query param is
present (optional — without it the screen still works, just unfiltered client-
side, so prefer adding it for larger datasets). No new MODEL or migration is
required — `PaCollectionItem` already exists and backs this precedent.

Server-side validation/derivation (optional but recommended for API/app parity)
should call the pure logic so the two never drift: `samity.cycle_status`,
`samity.overview`, `landlord_tenant.month_summary`, `landlord_tenant.arrears`.

## Rent-reminder seam (documented, NOT wired — per the task)

Due-rent reminders are NOT wired to notifications in this build. The seam is a
single pure function `landlord_tenant.due_reminder_plan(units, payments, month,
lead_days=3)` which returns the unpaid/partial units for a month plus a suggested
lead, and an honest `"wired": False`. To enable later WITHOUT touching this
module:

1. On the integrator side, after a month rolls over (or on app open), call
   `due_reminder_plan(...)` for the current month.
2. For each entry in `needs_reminder`, create a Reminder through the EXISTING
   reminders/notifications pipeline (the same path budgets/ladder reminders use),
   firing `lead_days` before the unit's conventional due day. The payload text
   should come from an ARB getter (e.g. a future `rentReminderDue{label,amount}`),
   not from the engine — the engine emits no prose.
3. Stop/skip a reminder the moment `unit_month(...).status == "paid"`.

The engine schedules nothing and holds no money; it only *plans* which units need
a nudge. This mirrors how `payment_ladder` documents its reminder seam.

## Sidebar entries (you wire; I must not touch the sidebar)

Per `.phaseB/SIDEBAR_LAYOUT.md`, add both under **আমার হিসাব / My Account**
(section 2 — ledger-adjacent, both are money-tracking tools):
- **Samity** → `SamityScreen` (`app/lib/screens/samity_screen.dart`).
  Icon suggestion: `Icons.groups_2_outlined`. Label key: reuse `samityTitle`.
- **House rent** → `LandlordTenantScreen`
  (`app/lib/screens/landlord_tenant_screen.dart`). Icon:
  `Icons.home_work_outlined`. Label key: reuse `rentTitle`.

(Alternative, if you later add a "Property/Income" grouping, `rentTitle` fits
there; it's placed in My Account for now to avoid a new section.) Also add
ChatNav routes + screen_synonyms so both open from chat (e.g. "সমিতি"/"samity",
"বাড়ি ভাড়া"/"house rent"/"rent"/"tenant"/"বাড়িওয়ালা").

## Wiring steps (summary)

1. Merge the 108 keys from `up_samityrent_arb.json` into `app_bn.arb` /
   `app_en.arb`; regenerate `AppLocalizations` (clears the analyze getter errors).
2. Register the six `PaCollectionViewSet` subclasses + router lines above
   (underscore paths). No model/migration needed — `PaCollectionItem` backs them.
   Optionally add the `?samity_id` queryset filter.
3. Add the two **My Account** sidebar entries + ChatNav routes/synonyms.
4. (Later, optional) wire the rent-reminder seam via `due_reminder_plan` through
   the existing reminders pipeline.

## Honest-states checklist (ADVANCED §21) — what shipped

- Loading skeleton, hard error + retry, offline banner (keeps the last list),
  first-use "welcome" empty states, and distinct honest secondary states
  (samity "need ≥2 members", rent "no arrears in this window" vs. first-use).
- Confirm gates with explicit "can't be undone" copy before every destructive
  delete (samity, member, unit) and before recording a payout hand-over.
- Transparent math surfaced, never hidden: samity shows expected/collected/
  pending that reconcile + per-member due; rent shows an itemised bill
  (base + each utility), paid-of-bill, outstanding, and overpay as *credit*
  (never silently applied). Arrears is a true multi-month sum, not a one-month
  snapshot.
- Structural "never holds money" banner on both modules; rotation is the
  members' own agreed order, never random; payouts are *recorded*, never
  *disbursed* by the app.
- Rent-reminder is an honest documented seam (`wired=False`), not a fake.
- bn/en throughout via ARB getters; ৳ via code-point formatter; no clipped text
  (ellipsis + maxLines on names/chips/pills); verified ZERO Bangla glyphs in any
  .dart (lang gate CLEAN).
