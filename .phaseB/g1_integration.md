# G1 — Business AI Agent advanced ("Night Salesman", 24/7) — integration notes

Branch `agent/g1-bizagent`. Extends P1 (core/bizagent_service.py, views_bizagent.py,
logic/bizagent.py) — nothing rewritten.

## Merge checklist
1. **Migration** `backend/core/migrations/0076_g1_bizagent.py` — depends on `0072_p4_world`;
   re-chain after the newest on main. Adds: SellerAgent (ai_mode, resume_minutes, rules_enabled,
   quiet_hours, morning_summary/hour, last_morning_day, followups_*, upsell_enabled, bundle_rules,
   auto_courier, vision/voice_enabled, comment_dm, widget_*), ChatThread (ai_paused_until,
   paused_by, reply_lock_until, followups_sent, last_followup_at, opted_out, upsell_done,
   channel choice `website`), Message (reply_source [indexed], credits, cost_bdt), Order
   (payment_status, via_agent), SellerChannel kind `website`; new models BizFaq, BizPostLink,
   BizProductSig. All additive with defaults.
2. **ARB** `.phaseB/up_g1_arb.json` — 111 keys en + bn (g1*), @metadata for 13 placeholder keys.
   Apply, then `flutter gen-l10n`.
3. **Pricing defaults**: `ai_sales_vision` (0.012 USD / 6 credits) and `ai_sales_voice`
   (0.006 / 3) added to `_ACTION_DEFAULTS` (admin-editable in Owner Admin → Pricing).
4. **Integrations**: new slug `voice_transcribe` (OpenAI audio; api_key, model,
   cost_per_minute_usd; Test = test_openai).
5. **No new cron** (`bizagent_process` every minute now also runs G1 sweeps: resume after human
   pause, deferred messages, follow-ups, morning summary). **No new web route** (widget script at
   `/api/v1/bizagent/chat.js`).
6. Behaviour changes in P1 (tests updated): rule/order/bargain replies no longer consume a plan
   reply or credits (only LLM replies do); a Page echo PAUSES the AI for `resume_minutes`
   instead of a permanent takeover; `threads/<id>/handover` off also clears the pause; the chat
   screen's switch became the "Let AI reply / I will reply" toggle.

## Proof
- Backend: `core.tests_g1_bizagent` (44 tests) + `web.tests_g1_sellers` + updated
  `core.tests_p1_bizagent`.
- Live proof (no Meta/vision/courier key): see owner_actions/BUSINESS_AGENT_SETUP.md § G1-ঙ —
  `manage.py bizagent_g1_selftest_setup --secret …` then `tools/g1_selftest.py … --html`.
  Ran end-to-end over HTTP against a local server (file SQLite) → **ALL PASSED** (the first run
  found a real bug — a partial product-name hit in the customer's NAME overrode the product chosen
  by photo — fixed + regression test).
- Flutter: `test/g1_bizagent_test.dart`; gallery shots `g1_agent_behaviour`, `g1_agent_answers`,
  `g1_agent_report`, `g1_agent_chat_image_order` (bn/en × light/dark).

## STATUS (Bangla, 3 lines)
- বিজনেস AI এজেন্ট এখন নিয়ম-আগে চলে: দাম, স্টক, সাইজ, ডেলিভারি, সময়, অর্ডারের অবস্থা ও FAQ-এর উত্তর AI ছাড়াই যায় (খরচ ০); Owner Admin → Sellers-এ নিয়ম বনাম AI % ও বাঁচানো টাকা।
- এজেন্ট ২৪/৭; মানুষ উত্তর দিলে শুধু ওই চ্যাটে AI থামে, ১৫ মিনিট পর অপেক্ষায় থাকা গ্রাহককে আবার উত্তর দেয়; প্রতি চ্যাটে "আমি উত্তর দেব / AI উত্তর দিক", ব্যবসা-মোড সবসময়/দোকান বন্ধের সময়/বন্ধ।
- ছবি → পণ্য মেলানো → অর্ডার → কুরিয়ার (টেস্টে নকল, স্পষ্ট লেখা) → পেমেন্ট স্ক্রিনশট "যাচাই বাকি" — self-test-এ সব পাস; ভিশন ও ভয়েসের জন্য মালিকের key লাগবে।
