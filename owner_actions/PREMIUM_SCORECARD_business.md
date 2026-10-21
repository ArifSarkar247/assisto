# Premium scorecard — Business + Money screens (Part 7, slot a2)

Method: every screen rendered bn/en × light/dark at 360×800 with FakeApi data,
plus a large-font pass at 1.4× (`ASSISTO_SHOT_SCALE=1.4`). Scored /10 on
clipping, contrast, spacing, empty/error/loading states and Bangla quality.
Anything under 9 was fixed and re-rendered.

Shots (not in git): `/tmp/claude-1000/-home-ubuntu-assisto/ea8a0e54-3e29-4bc2-a831-7f9d2da14cc0/scratchpad/qa` (before) and `/tmp/claude-1000/-home-ubuntu-assisto/ea8a0e54-3e29-4bc2-a831-7f9d2da14cc0/scratchpad/qa2` (after),
files `<screen>_<bn|en>_<light|dark>[_s1.4].png`. Re-render:
`ASSISTO_SHOT_DIR=<dir> [ASSISTO_SHOT_SCALE=1.4] ASSISTO_SHOT_ONLY=<names> flutter test test/screenshots_test.dart`.

## Batch 1 (21 screens)

| Screen (gallery name) | Before → After | What was fixed |
|---|---|---|
| Business hub (`biz_hub`) | 6 → 9 | Gallery only ever showed the "create a business" welcome: FakeApi answered `profiles` but the real server answers `businesses` + `selected_id`. Fixed the stub; the real hub (summary, manage list) now renders and reviews clean at 1.4×. |
| Products (`biz_products`) | 6 → 9 | Title, header and FAB all said "Product name"; the empty state said "Cart is empty". Now "Products" / "Add product" / an honest "No products yet" empty state (new keys). Prices now have thousands separators (৳1,200). |
| Khata (`biz_khata`) | 7 → 9 | At 1.4× the section title broke mid-word ("Customer s (Dues)") and the tabs were cut. The header now wraps the "Remind everyone" button to its own line; the tabs scroll on a large font. |
| Cashbox (`biz_cashbox`) | 9 → 9 | No change needed. |
| Customers (`biz_customers`) | 7 → 9 | The title said "Customer", the FAB said "Name" and the empty state said "Cart is empty". Now "Customers", "Add customer", and a proper empty state. |
| Quick sell (`biz_quick_sell`) | 8 → 9 | Prices are grouped (৳1,200 / ৳2,500) via the shared `fmtTaka` fix. |
| Selling reports (`biz_reports`) | 8 → 9 | Totals are grouped (৳3,650). |
| Orders (`biz_orders`) | 6 → 9 | Totals were shown raw (৳240000; real server sends taka decimals "2400.00"). At 1.4× the long status chip cut the customer's name to "#101 · …". The name now gets the full width; amount, status and COD wrap below; totals are formatted (৳2,400). The order detail uses the same formatter. |
| Payments (`biz_payments`) | 8.5 → 9 | Fine; no action needed (long merchant number wraps only at 1.4×). |
| Money summary (`money`) | 7 → 9 | At 1.4× the 5 tabs broke mid-word ("Summa ry", "অ্যাকাউ ন্ট"). At 1.0× they keep the existing fit-all layout; on a large font they scroll. |
| Budget (`money_budget`) | 8 → 9 | The "This month" tab was cut at 1.4×; the tabs now scroll on a large font. |
| Monthly report (`money_report`) | 8 → 9 | Stat labels were cut at 1.0× in English ("Income This Mo…"). Labels now take 2 lines; values shrink to fit instead of clipping (shared `statCard`, also used by the overview). |
| Net worth (`money_networth`) | 9 → 9 | No change needed. |
| Trends (`money_trends`) | 7 → 9 | **Overflow crash** at 1.4× (legend Row overflowed by 49 px, red/yellow stripes). The legend is now a Wrap. |
| Loan detail (`money_loan_detail`) | 9 → 9 | No change needed. |
| Finance tools (`finance`) | 9 → 9 | No change needed. |
| Subscriptions (`subscriptions`) | 8 → 9 | English said "Overdue by 1 days", now "Overdue by 1 day". The Bangla "৪ দিনে বকেয়া" (ambiguous) is now "আর ৪ দিন বাকি". |
| CRM dashboard (`crm_dashboard`) | 7 → 9 | The Bangla screen showed the server's English formula ("Sum (value x probability / 100) over open deals"); it is now a localized method line. "Won — ERP হ্যান্ড-অফ" (a button label) was reused as a stat label; it is now "জয়"/"Won". KPI values were cut ("৳২,১৫০,০…") at 1.4×; they now scale down to fit. |
| Shop Box (`shop_box`) | 9 → 9 | Built and reviewed in the CCTV task. |
| Shop EOD (`shop_eod`) | 9 → 9 | Built and reviewed in the CCTV task. |
| Shop camera settings (`shop_cam_settings`) | 9 → 9 | Built and reviewed in the CCTV task. |

States also rendered: `biz_products_empty`, `biz_khata_error`, `biz_reports_loading` — all clean.

Gallery additions (`app/test/screenshots_test.dart`): 13 business/money
screens + 3 state variants, and a `ASSISTO_SHOT_SCALE` large-font knob.
New ARB keys: `shopQa*` (12) in `app/up_a2_arb.json`.
