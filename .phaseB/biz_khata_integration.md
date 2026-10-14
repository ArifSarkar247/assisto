# Digital Khata + Cashbox — integration guide

Pure logic lives in `backend/core/logic/business_khata.py` (NO Django imports;
all money is **integer poisha**, all user strings are `{bn,en}` pairs). This doc
tells the integrator exactly what Django to add. **Do not** change the pure
module to add ORM — keep it pure; the views feed it rows and persist results.

Money convention: the logic speaks integer poisha (৳1 = 100 poisha). Store
amounts as `BigIntegerField` poisha (preferred — matches the logic, no float),
or as `DecimalField(max_digits=14, decimal_places=2)` taka and convert at the
boundary with `business_khata.to_poisha()` / `taka_str()`.

---

## (a) Django models to add

All FK to `BusinessProfile` (one books-set per business; a user may own several
businesses — see plan §1). Add `related_name` so a profile can list its parties.

```python
class KhataParty(models.Model):
    """A customer or supplier in one business's books (plan §2)."""
    BOOK = [("customer", "customer"), ("supplier", "supplier")]
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="khata_parties")
    book     = models.CharField(max_length=10, choices=BOOK)
    name     = models.CharField(max_length=120)
    phone    = models.CharField(max_length=40, blank=True, default="")
    area     = models.CharField(max_length=80, blank=True, default="")
    note     = models.TextField(blank=True, default="")
    vip      = models.BooleanField(default=False)
    archived = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["business", "book"]),
                   models.Index(fields=["business", "phone"])]


class KhataEntry(models.Model):
    """One ledger line. direction is owner-POV ('gave'|'got'); meaning depends
    on the party's book (see business_khata.py header)."""
    DIRECTION = [("gave", "gave"), ("got", "got")]
    party   = models.ForeignKey(KhataParty, on_delete=models.CASCADE,
                                related_name="entries")
    direction = models.CharField(max_length=4, choices=DIRECTION)
    amount_poisha = models.BigIntegerField()          # always > 0
    note    = models.CharField(max_length=200, blank=True, default="")
    bill_photo = models.ImageField(upload_to="khata_bills/", null=True, blank=True)
    at      = models.DateTimeField()                  # owner-supplied event time
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at", "id"]
        indexes = [models.Index(fields=["party", "at"])]


class CashboxDay(models.Model):
    """One business day's drawer. Reconciliation writes counted_poisha."""
    business = models.ForeignKey(BusinessProfile, on_delete=models.CASCADE,
                                 related_name="cashbox_days")
    day              = models.DateField()
    opening_poisha   = models.BigIntegerField(default=0)
    counted_poisha   = models.BigIntegerField(null=True, blank=True)  # set at reconcile
    reconciled_at    = models.DateTimeField(null=True, blank=True)
    created_at       = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("business", "day")]
        indexes = [models.Index(fields=["business", "day"])]


class CashEntry(models.Model):
    KIND = [("in", "in"), ("out", "out")]
    day     = models.ForeignKey(CashboxDay, on_delete=models.CASCADE,
                                related_name="entries")
    kind    = models.CharField(max_length=3, choices=KIND)
    amount_poisha = models.BigIntegerField()          # > 0
    note    = models.CharField(max_length=200, blank=True, default="")
    ref     = models.CharField(max_length=60, blank=True, default="")  # e.g. order id
    at      = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["at", "id"]


class TagadaSchedule(models.Model):
    """A recurring reminder for one party. The pure layer only compares
    next_at to `now`; the view advances next_at after firing (cadence owned by
    the view, plan §2)."""
    party   = models.ForeignKey(KhataParty, on_delete=models.CASCADE,
                                related_name="tagada_schedules")
    preset  = models.CharField(max_length=16, default="reminder")  # polite/reminder/firm/thanks
    channel = models.CharField(max_length=20, default="whatsapp_share")  # or 'sms'
    next_at = models.DateTimeField()
    interval_days = models.IntegerField(default=7)
    enabled = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
```

Mapping to the pure layer: a `KhataEntry` row -> dict
`{party_id, direction, amount: amount_poisha, note, at: at.isoformat(), bill_photo_ref: bill_photo.url}`.
Convert `at` to ISO strings before calling the logic (it sorts by string `at`).

---

## (b) Endpoints (all under `api/v1/business/`)

Auth: `IsAuthenticated` + the request's selected business must belong to
`request.user` (resolve `BusinessProfile` by id, 404 otherwise). **Staff role**
(plan §3: staff can sell, cannot see profit/cost): staff MUST NOT see the
**supplier payables** book or supplier statements (those expose cost). Gate
every supplier-book path with an owner-only check; customer receivables, tagada,
and cashbox are allowed for staff.

| Method | Path | Pure fn | Role |
|---|---|---|---|
| GET  | `khata/parties?book=customer\|supplier` | — (list) + `running_balance` per row | owner; `book=supplier` **owner-only** |
| POST | `khata/parties` | — | owner; create supplier party owner-only |
| GET  | `khata/parties/<id>/statement` | `party_statement` | owner; supplier party owner-only |
| POST | `khata/parties/<id>/entries` | `new_entry` (validate) then persist | owner; supplier entry owner-only. Returns the entry + updated balance; if `notify_customer` flag set and customer book, also returns `entry_added_message` |
| POST | `khata/parties/<id>/payment` | `apply_payment` | same gating as entries |
| GET  | `khata/net-position` | `net_position` (customer list always; supplier list omitted/zeroed for staff) | all; supplier figures **owner-only** |
| POST | `khata/tagada/single` | `plan_tagada_single` | owner+staff (customer dues only) |
| POST | `khata/tagada/bulk` | `plan_tagada_bulk` | owner+staff |
| GET/POST | `khata/tagada/schedule` | create `TagadaSchedule`; a cron/worker calls `plan_tagada_scheduled(party, bal, {next_at}, now)` and, when `due`, advances `next_at += interval_days` | owner |
| POST | `khata/parties/<id>/statement.pdf` | `statement_pdf_data` -> hand dict to PDF renderer layer | owner; supplier owner-only |
| GET  | `cashbox/<day>` | `cashbox_summary` | owner+staff |
| POST | `cashbox/<day>/entries` | `cash_entry` (validate) then persist | owner+staff |
| POST | `cashbox/<day>/reconcile` | `reconcile_cashbox` -> persist `counted_poisha`, `reconciled_at` | owner+staff |

SMS gating (plan §2): pass `sms_enabled=<bool>` into the tagada planners, where
the bool = "a licensed SMS provider key is configured for this business". With
no key, `share_descriptor(channel='sms')` returns `available=False` + a reason
pair; WhatsApp share is always available. Never embed an Assisto-controlled
payment link — only the owner's own bKash/Nagad number via `pay_hint` (plan §6:
we never hold money).

`now` must be passed by the view (e.g. `timezone.now().isoformat()`), never read
inside the pure layer (offline-first determinism).

---

## (c) ARB keys

See `biz_khata_arb.json` (sibling file) — every user-facing static string the
logic implies (tagada presets + tones, cashbox labels, statement headers/footer,
ledger/net-position labels, SMS-unavailable reason), each `key: [bn, en]`, both
languages filled, never mixed. Dynamic amounts/names are injected by Flutter via
the `{bn,en}` pairs the logic already returns (`fmt_amount`, `balance_status`,
`tagada_message`, etc.) — do not re-translate those; the logic owns them.
