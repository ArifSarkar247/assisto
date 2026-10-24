# f2-design proof (owner order F, part 2)

- `sheets/<screen>.jpg`: before | after for bn/en × light/dark at 360 dp, 1x.
  Before = main at b13b556 (f1 shipped), after = branch `agent/f2-design`.
- `sheets_xl/<screen>_xl.jpg`: the same at 200 % text size
  (`ASSISTO_SHOT_SCALE=2.0`) for ai_chat, settings, biz_quick_sell,
  biz_khata, biz_cashbox, money, reminders, photo_studio_free_enhanced,
  crm_leads, shop_box. The gallery fails on any RenderFlex overflow; all
  passed.
- `a11y.txt`: `ASSISTO_SHOT_A11Y=1` audit (tap target ≥ 48 dp + labelled tap
  targets) over every after shot. What is left there is on frozen home or
  shared chat-card widgets (see REMAINING.md).
- Raw PNGs are not committed (≈50 MB); regenerate with
  `ASSISTO_SHOT_DIR=… ASSISTO_SHOT_ONLY=<names> flutter test test/screenshots_test.dart`.

Screens (33): ai_chat, chat (home chat thread), home_welcome,
photo_studio_free_empty, photo_studio_free_enhanced, photo_studio_gate,
photo_studio_d1_tools, settings, biz_hub, biz_khata, biz_quick_sell,
biz_cashbox, biz_products, biz_customers, biz_reports, biz_orders, supplier,
crm_home, crm_today, crm_leads, crm_pipeline, crm_dashboard, crm_lead_detail,
shop_box, shop_eod, money, money_report, money_budget, money_loan_detail,
money_networth, money_trends, reminders, p1_agent_home.

What to look for: dark-mode user chat bubble text is now dark-on-light-blue
(was white on light blue, ~2.6:1); success/warning/danger text uses the AA
tokens (amber text on white was ~2:1; CRM "warm" score chip now dark amber
with white text in light, dark ink in dark); 13/15/17/18 sp one-offs snap to
the type scale (14/16/16/20); amounts use tabular figures; money tabs keep
"Transaction" on one line at 1x.
