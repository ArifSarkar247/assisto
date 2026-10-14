# Business v2 — SELLING integration (§3)

Pure logic lives in `backend/core/logic/business_selling.py` (NO Django). The
views layer feeds it ORM rows (as plain dicts) and persists what it returns.
Tests: `backend/core/logic/business_selling_tests_snippets.py` →
`run_all()` = **39 asserts, 7 are minimum-price enforcement** (below-min add
rejected, below-min edit rejected + price unchanged, 1-poisha-below rejected,
at-min ok, above-min ok, discount cannot breach the min floor, end-to-end
checkout discount clamped to floor).

**Money rule everywhere: integer POISHA (1 taka = 100 poisha). No floats.**
Converters: `taka_to_poisha`, `poisha_to_taka`, `fmt_taka`.

---

## (a) Django models / fields / indexes to add

EXTEND existing (`core/models.py` ~685-730), do not duplicate.

### Product (EXTEND the existing model)
Add:
- `category` CharField(max_length=80, blank, default="") — index
- `barcode` CharField(max_length=64, blank, default="", db_index=True)
- `min_price` DecimalField(max_digits=12, decimal_places=2, default=0) — bargaining floor
- `cost_price` DecimalField(max_digits=12, decimal_places=2, default=0)
- keep existing `price` as the SELLING price; `stock`, `sku` stay.
- `low_stock_at` IntegerField(default=3)
- `business` FK → BusinessProfile (nullable) so multiple businesses per user (plan §1).

Indexes: `(user, category)`, `(user, barcode)`, `(user, sku)`.

### ProductVariant (NEW) — size/colour combos
- `product` FK → Product (related_name="variants", CASCADE)
- `vkey` CharField(max_length=120)  # from `variant_key(size,colour)`; `__base__` if none
- `size` CharField(80, blank), `colour` CharField(80, blank)
- `sell_price` / `cost_price` / `min_price` DecimalField(12,2)
- `stock` IntegerField(default=0), `barcode` CharField(64, blank, db_index=True)
- `low_stock_at` IntegerField(default=3)
- Meta: `unique_together = [("product", "vkey")]`; index `(product, vkey)`.

### Category (NEW, optional convenience)
- `user` FK, `business` FK(null), `name` CharField(80); `unique_together=(user,business,name)`.

### Customer (NEW)
- `user` FK, `business` FK(null)
- `name` CharField(120, blank), `phone` CharField(40, blank)
- `phone_key` CharField(40, blank, db_index=True)  # from `normalize_phone()`, dedupe key
- `address` TextField(blank), `area` CharField(80, blank), `notes` TextField(blank)
- `vip` BooleanField(default=False)
- Meta: `unique_together = [("user", "business", "phone_key")]` (blank phone_key allowed many).

### Sale (NEW) — a completed checkout
- `user` FK, `business` FK(null), `customer` FK → Customer (null, SET_NULL)
- `staff` FK → User (null) — who rang it up (role gate audit)
- money as IntegerField in POISHA: `subtotal`, `discount`, `total`, `paid`, `change`, `due`, `profit`
- `payment_method` CharField(10, choices=cash/bkash/nagad/due)
- `discount_clamped` BooleanField(default=False)  # a discount hit the min floor
- `created_at` DateTimeField(auto_now_add, db_index=True)  # period reports
- Index `(user, created_at)`, `(business, created_at)`, `(customer, created_at)`.

### SaleLine (NEW)
- `sale` FK → Sale (related_name="lines", CASCADE)
- `product` FK(null, SET_NULL), `variant` FK(null, SET_NULL)
- `product_name` CharField(160), `size`/`colour` CharField(80, blank)
- `qty` IntegerField
- `unit_price` / `min_price` / `cost_price` / `sell_price` IntegerField (POISHA)

### Expense (NEW) — for net-profit-after-expenses
- `user` FK, `business` FK(null), `amount` IntegerField(POISHA), `category` CharField(80, blank)
- `note` CharField(200, blank), `date` DateField(db_index=True), `created_at`

---

## (b) Endpoints (all under `api/v1/business/…`)

All take `role` from the authenticated staff membership; apply redaction before
serialising. `req_lang(request)` → pass `lang` into the pure fns for localised
strings. Below-min and clamp reasons map to `biz_selling_arb.json`.

| Method | Path | Pure fn(s) | Role gate / redaction |
|---|---|---|---|
| POST | `products/` | `make_product` + `validate_product` | owner only (writes cost/min) |
| GET | `products/` | — (ORM) → `redact_product(p, role)` | staff: cost/min stripped |
| GET | `products/{id}/` | `redact_product` | staff redacted |
| POST | `products/import/` | `parse_import_rows` + `check_import_uniqueness` | owner only; returns `{products, bad_rows, conflicts}` |
| POST | `products/{id}/variants/` | `make_variant` + `validate_variant` | owner only |
| POST | `cart/add/` | `cart_add_line` | **below-min → 422 `below_min`**; staff may sell |
| POST | `cart/line/{id}/price/` | `cart_set_price` | **below-min → 422 `below_min`** (price unchanged) |
| POST | `cart/line/{id}/qty/` | `cart_set_qty` | — |
| DELETE | `cart/line/{id}/` | `cart_remove_line` | — |
| POST | `cart/discount/preview/` | `apply_cart_discount` | clamp → returns `discount_clamped:true` + `below_min` reason |
| POST | `sales/checkout/` | `checkout` → persist Sale/SaleLine; `apply_stock_decrements` → update stock/low-stock | staff may complete sale; response `redact_sale(res, role)` (no profit/cost for staff). Discount clamp enforced server-side. |
| GET | `sales/{id}/receipt/` | `build_receipt` | staff sees receipt (no profit) |
| GET | `customers/` | — ; create via `find_or_create_customer` on checkout | — |
| POST | `customers/dedupe/` | `dedupe_customers` | owner |
| GET | `customers/{phone}/history/` | `purchase_history`, `customer_dues_poisha` | staff: ok (no cost) |
| GET | `reports/?period=daily\|weekly\|monthly` | `full_report` (wraps `sales_report`, `top_products`, `top_customers`, `by_payment_method`, `net_profit_report`) | **staff → `full_report(..., role="staff")` strips profit/cost/net** |

**Hard rule reminder:** minimum-price enforcement is in the pure layer
(`cart_add_line` / `cart_set_price` reject below-min; `apply_cart_discount` /
`checkout` clamp any blanket discount to the min floor). Endpoints MUST surface
the reason code, never bypass it — selling below minimum is impossible here.

Staff redaction uses `redact_for_role(obj, role)` (deep-strips
`cost_price, min_price, minimum, profit, gross_profit, net_profit, margin,
markup`). `can_see_cost(role)` and `staff_restricted_notice(lang)` for guards.

---

## (c) biz_selling_arb.json

See `biz_selling_arb.json` next to this file: `{key: [bn, en]}` for every
user-facing string (product fields, cart, payment methods, report labels,
staff-restricted notice, below-min message). Both languages filled.
