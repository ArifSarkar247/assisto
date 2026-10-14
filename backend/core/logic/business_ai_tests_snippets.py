"""
business_ai_tests_snippets.py — plain-assert tests for core.logic.business_ai.

NOT a Django TestCase (the module under test is pure Python). Smoke locally:

    cd /home/ubuntu/assisto/backend && \
      python3 -c "import core.logic.business_ai_tests_snippets as t; t.run_all()"

Headline safety tests (called out in the report):
  - test_negotiate_* : MINIMUM PRICE can NEVER be breached.
  - test_payments_never_holds_funds / test_payment_link_never_custody : we never
    hold money / never a wallet.
  - test_no_personal_whatsapp / test_guard_* : official channels ONLY.
"""
from decimal import Decimal

try:
    from core.logic import business_ai as B
except Exception:  # pragma: no cover
    import business_ai as B  # type: ignore


# --- helpers ---------------------------------------------------------------

def _ctx(**kw):
    return B.build_context(**kw)


CATALOG = [
    {"name": "Panjabi", "price": "1200", "stock": 5, "min_price": "1000",
     "description": "cotton"},
    {"name": "Saree", "price": "2500", "stock": 0, "min_price": "2000"},
]
DELIVERY = {"inside_dhaka": 60, "outside_dhaka": 120}
POLICIES = {"returns": "7 days", "hours": "10am-10pm"}


# ===========================================================================
# language detection
# ===========================================================================

def test_detect_lang_bangla():
    assert B.detect_lang("দাম কত?") == "bn"
    assert B.reply_lang("দাম কত?") == "bn"


def test_detect_lang_banglish():
    assert B.detect_lang("panjabi r dam koto?") == "banglish"
    assert B.reply_lang("panjabi r dam koto?") == "bn"  # banglish → reply bn


def test_detect_lang_english():
    assert B.detect_lang("what is the price?") == "en"
    assert B.reply_lang("what is the price?") == "en"


# ===========================================================================
# reply pipeline — never fabricates, key-gates the real provider
# ===========================================================================

def test_draft_reply_uses_mock_by_default():
    ctx = _ctx(catalog=CATALOG, delivery=DELIVERY, policies=POLICIES,
               shop_name="Rong", lang="bn")
    out = B.draft_reply("দাম কত?", ctx)
    assert out["used_ai"] is False  # no key → mock
    assert out["confidence"] >= B.HANDOFF_CONFIDENCE
    assert "১২০০" in out["text"] or "1200" in out["text"]


def test_draft_reply_real_provider_only_with_key():
    calls = []

    def fake_llm(prompt):
        calls.append(prompt)
        return {"text": "hi", "confidence": 0.9}

    ctx = _ctx(catalog=CATALOG, lang="en")
    # No key → mock, provider NOT called.
    B.draft_reply("price?", ctx, reply_provider=fake_llm, ai_key=None)
    assert calls == []
    # Key present → provider used.
    out = B.draft_reply("price?", ctx, reply_provider=fake_llm, ai_key="KEY")
    assert out["used_ai"] is True and len(calls) == 1


def test_draft_reply_no_facts_never_high_confidence_on_price():
    # Empty catalog → the pipeline must NOT let a price-ish reply ride high.
    ctx = _ctx(catalog=[], lang="en")

    def over_confident(prompt):
        return {"text": "it's 500 taka", "confidence": 0.99}

    out = B.draft_reply("price?", ctx, reply_provider=over_confident, ai_key="K")
    assert out["confidence"] <= B.CONF_LOW
    assert out["needs_human"] is True


def test_draft_reply_owner_takeover_silences_ai():
    ctx = _ctx(catalog=CATALOG, lang="bn")
    out = B.draft_reply("দাম কত?", ctx, owner_takeover=True)
    assert out["text"] == "" and out["needs_human"] is True
    assert out["handoff_reason"] == "owner_takeover"


def test_assistant_disclosure_present():
    ctx = _ctx(catalog=CATALOG, lang="en")
    out = B.draft_reply("are you a bot?", ctx)
    assert "AI assistant" in out["disclosure"]["short"]
    bn = B.assistant_disclosure("bn")
    assert "এআই" in bn["short"]


# ===========================================================================
# BARGAINING — MINIMUM PRICE ENFORCED IN CODE (headline safety tests)
# ===========================================================================

PROD = {"name": "Panjabi", "price": "1200", "min_price": "1000"}


def test_negotiate_below_min_defers_never_sells():
    out = B.negotiate("800", PROD, lang="en")
    assert out["action"] == B.ACTION_DEFER
    assert out["price"] is None  # NEVER a price below min
    assert "owner" in out["message"].lower()
    assert out["owner_notification"]["type"] == "bargain_below_min"


def test_negotiate_below_min_bn_message():
    out = B.negotiate("500", PROD, lang="bn")
    assert out["action"] == B.ACTION_DEFER
    assert "মালিক" in out["message"]


def test_negotiate_at_min_accepts_at_min_not_below():
    out = B.negotiate("1000", PROD, lang="en")
    assert out["action"] == B.ACTION_ACCEPT
    assert out["price"] == Decimal("1000")
    assert out["price"] >= out["min_price"]


def test_negotiate_within_band_accepts_offer():
    out = B.negotiate("1100", PROD, lang="en")
    assert out["action"] == B.ACTION_ACCEPT
    assert out["price"] == Decimal("1100")
    assert out["price"] >= Decimal("1000")


def test_negotiate_at_or_above_list_accepts_list():
    for offer in ("1200", "1500"):
        out = B.negotiate(offer, PROD, lang="en")
        assert out["action"] == B.ACTION_ACCEPT
        assert out["price"] == Decimal("1200")  # never overcharge past list


def test_negotiate_counter_never_below_min_percent_ladder():
    # 50% off 1200 = 600, but min is 1000 → clamp to 1000.
    out = B.negotiate(None, PROD, rules={"discount_steps": [50]}, lang="en")
    assert out["action"] == B.ACTION_COUNTER
    assert out["price"] == Decimal("1000")
    assert out["price"] >= out["min_price"]


def test_negotiate_counter_never_below_min_absolute_ladder():
    # 500 taka off 1200 = 700, min 1000 → clamp to 1000.
    out = B.negotiate(None, PROD, rules={"discount_steps": [500]}, lang="en")
    assert out["price"] == Decimal("1000")


def test_negotiate_counter_allowed_discount_within_floor():
    # 10% off 1200 = 1080 >= min 1000 → allowed.
    out = B.negotiate(None, PROD, rules={"discount_steps": [10]}, lang="en")
    assert out["action"] == B.ACTION_COUNTER
    assert out["price"] == Decimal("1080")


def test_negotiate_invariant_brute_force_every_offer_ge_min_or_defer():
    # Exhaustive: for a spread of offers, result price is NEVER below minimum.
    prod = {"name": "X", "price": "1000", "min_price": "700"}
    minp = Decimal("700")
    for cents in range(0, 1500, 37):
        out = B.negotiate(str(cents), prod, lang="en")
        if out["price"] is not None:
            assert out["price"] >= minp, (cents, out)
        else:
            # price None only when deferring (offer below min)
            assert out["action"] == B.ACTION_DEFER
            assert Decimal(str(cents)) < minp


def test_negotiate_misconfigured_min_above_list_is_clamped():
    prod = {"name": "X", "price": "500", "min_price": "9999"}
    out = B.negotiate("500", prod, lang="en")
    assert out["action"] == B.ACTION_ACCEPT and out["price"] == Decimal("500")


def test_negotiate_missing_min_defaults_to_list_no_discount():
    prod = {"name": "X", "price": "500"}
    out = B.negotiate(None, prod, rules={"discount_steps": [50]}, lang="en")
    assert out["price"] == Decimal("500")  # no discount below list without a min


def test_negotiate_free_delivery_mention():
    prod = {"name": "X", "price": "2000", "min_price": "1500"}
    out = B.negotiate(None, prod,
                      rules={"discount_steps": [10], "free_delivery_over": 1000},
                      lang="en")
    assert "free delivery" in out["message"].lower()


# ===========================================================================
# handoff triggers
# ===========================================================================

def test_handoff_angry():
    assert B.handoff_trigger("this is a scam, worst shop") == B.HANDOFF_ANGRY
    ctx = _ctx(catalog=CATALOG, lang="en")
    out = B.draft_reply("you cheated me, this is fraud", ctx)
    assert out["needs_human"] and out["handoff_reason"] == B.HANDOFF_ANGRY


def test_handoff_refund():
    assert B.handoff_trigger("I want a refund") == B.HANDOFF_REFUND
    assert B.handoff_trigger("টাকা ফেরত চাই") == B.HANDOFF_REFUND


def test_handoff_big_order():
    assert B.handoff_trigger("hi", order_total="25000") == B.HANDOFF_BIG_ORDER
    assert B.handoff_trigger("hi", order_total="100") is None


def test_handoff_low_confidence():
    assert B.handoff_trigger("hi", confidence=0.2) == "low_confidence"
    assert B.handoff_trigger("hi", confidence=0.9) is None


def test_handoff_message_both_langs():
    assert B.handoff_message("en", B.HANDOFF_REFUND)
    assert B.handoff_message("bn", B.HANDOFF_ANGRY) != \
        B.handoff_message("en", B.HANDOFF_ANGRY)


# ===========================================================================
# order state machine + courier + COD + parcel status
# ===========================================================================

def test_state_machine_legal_path():
    assert B.can_transition(B.STATUS_NEW, B.STATUS_CONFIRMED)
    assert B.can_transition(B.STATUS_CONFIRMED, B.STATUS_PACKED)
    assert B.can_transition(B.STATUS_PACKED, B.STATUS_SHIPPED)
    assert B.can_transition(B.STATUS_SHIPPED, B.STATUS_DELIVERED)
    assert B.can_transition(B.STATUS_SHIPPED, B.STATUS_RETURNED)


def test_state_machine_illegal_transitions():
    assert not B.can_transition(B.STATUS_NEW, B.STATUS_SHIPPED)
    assert not B.can_transition(B.STATUS_DELIVERED, B.STATUS_PACKED)
    assert not B.can_transition(B.STATUS_CANCELLED, B.STATUS_CONFIRMED)
    try:
        B.advance_order({"status": B.STATUS_NEW}, B.STATUS_DELIVERED)
        assert False, "should have raised"
    except ValueError:
        pass


def test_shipped_requires_courier():
    order = {"id": 7, "status": B.STATUS_PACKED, "total": "1200", "payment": "cod"}
    try:
        B.advance_order(order, B.STATUS_SHIPPED)  # no courier
        assert False
    except ValueError:
        pass
    try:
        B.advance_order(order, B.STATUS_SHIPPED, courier="dhl")  # bad courier
        assert False
    except ValueError:
        pass


def test_courier_key_gated_mock():
    order = {"id": 7, "status": B.STATUS_PACKED, "total": "1200", "payment": "cod"}
    new, ev = B.advance_order(order, B.STATUS_SHIPPED, courier="pathao")
    assert new["status"] == B.STATUS_SHIPPED
    assert new["courier_live"] is False  # no key → mock, not a real booking
    assert new["tracking"].startswith("PATHAO-MOCK-")
    # With a key, live flips True (would call the real API).
    new2, _ = B.advance_order(order, B.STATUS_SHIPPED, courier="steadfast",
                              courier_keys={"steadfast": "K"})
    assert new2["courier_live"] is True


def test_cod_amount():
    assert B.cod_amount({"total": "1200", "payment": "cod"}) == Decimal("1200")
    assert B.cod_amount({"total": "1200", "payment": "bkash"}) == Decimal("0")


def test_parcel_status_lookup():
    order = {"id": 7, "status": B.STATUS_SHIPPED, "courier": "redx",
             "tracking": "REDX-MOCK-7"}
    s = B.parcel_status(order, lang="en")
    assert "shipped" in s["message"].lower() and "REDX-MOCK-7" in s["message"]
    sbn = B.parcel_status(order, lang="bn")
    assert "REDX-MOCK-7" in sbn["message"]


# ===========================================================================
# morning summary
# ===========================================================================

def test_morning_summary_counts():
    s = B.morning_summary(messages=[1] * 34, orders=[1] * 8, needs_you=[1, 2],
                          lang="en")
    assert s["messages"] == 34 and s["orders"] == 8 and s["needs_you"] == 2
    assert "34" in s["text"] and "need you" in s["text"]
    sbn = B.morning_summary(messages=[], orders=[], needs_you=[], lang="bn")
    assert "সুপ্রভাত" in sbn["text"]


# ===========================================================================
# official channels ONLY — never personal WhatsApp (headline safety tests)
# ===========================================================================

def test_no_personal_whatsapp():
    for ch in (B.CHANNEL_WA_PERSONAL, B.CHANNEL_WA_BUSINESS_APP):
        try:
            B.guard_channel(ch)
            assert False, "personal WhatsApp must be refused"
        except B.PersonalWhatsAppBanned:
            pass


def test_guard_allows_official_channels():
    assert B.guard_channel(B.CHANNEL_WA_CLOUD) == B.CHANNEL_WA_CLOUD
    assert B.guard_channel(B.CHANNEL_MESSENGER) == B.CHANNEL_MESSENGER
    try:
        B.guard_channel("telegram")
        assert False
    except ValueError:
        pass


def test_assemble_webhook_refuses_personal():
    try:
        B.assemble_webhook_send(B.CHANNEL_WA_PERSONAL, "0171", text="hi")
        assert False
    except B.PersonalWhatsAppBanned:
        pass


# ===========================================================================
# 24h window + paid templates
# ===========================================================================

def test_within_service_window():
    now = 100_000
    assert B.within_service_window(now - 3600, now) is True       # 1h ago
    assert B.within_service_window(now - 25 * 3600, now) is False  # 25h ago
    assert B.within_service_window(None, now) is False


def test_outbound_plan_freeform_inside_window():
    now = 100_000
    plan = B.outbound_message_plan(B.CHANNEL_WA_CLOUD, now - 3600, now)
    assert plan["mode"] == "freeform" and plan["paid_template"] is False
    assert plan["allowed"] is True


def test_outbound_plan_requires_paid_template_outside_window():
    now = 100_000
    # outside window, no template → not allowed
    plan = B.outbound_message_plan(B.CHANNEL_WA_CLOUD, now - 50 * 3600, now)
    assert plan["allowed"] is False and plan["paid_template"] is True
    # outside window, with approved template → allowed + paid
    plan2 = B.outbound_message_plan(B.CHANNEL_WA_CLOUD, now - 50 * 3600, now,
                                    template_name="order_update")
    assert plan2["allowed"] is True and plan2["paid_template"] is True


def test_assemble_webhook_cloud_body():
    now = 100_000
    out = B.assemble_webhook_send(B.CHANNEL_WA_CLOUD, "8801711", text="hi",
                                  last_inbound_ts=now - 3600, now_ts=now)
    assert out["ok"] and out["needs_key"] is True
    assert out["body"]["messaging_product"] == "whatsapp"
    assert "graph.facebook.com" in out["endpoint"]


def test_assemble_webhook_blocked_outside_window_no_template():
    now = 100_000
    out = B.assemble_webhook_send(B.CHANNEL_WA_CLOUD, "8801711", text="hi",
                                  last_inbound_ts=now - 50 * 3600, now_ts=now)
    assert out["ok"] is False


# ===========================================================================
# §5 AI extras (mock, key-gated)
# ===========================================================================

def test_voice_entry_parse_draft():
    out = B.voice_entry_parse("Rahim er khatay 500 taka baki", lang="en")
    assert out["needs_review"] is True and out["transcription_mock"] is True
    assert out["draft"]["amount"] == "500"
    assert out["draft"]["kind"] == "due"


def test_paper_khata_parse_review_step():
    out = B.paper_khata_parse(
        mock_rows=[{"name": "Karim", "amount": "300", "kind": "due"},
                   {"name": "Sohel", "amount": "150"}], lang="bn")
    assert out["count"] == 2 and out["needs_review"] is True
    assert out["ocr_mock"] is True
    assert out["entries"][0]["amount"] == "300"


def test_match_payment_to_due_matches_on_amount():
    notif = "You have received Tk 300.00 from 01712345678. TrxID 9F2A"
    dues = [{"id": 1, "name": "Karim", "phone": "01712345678", "amount": "300"},
            {"id": 2, "name": "Sohel", "amount": "900"}]
    out = B.match_payment_to_due(notif, dues, lang="en")
    assert out["matched"] is True and out["due_id"] == 1
    assert out["auto_apply"] is False  # always owner-confirmed, never auto


def test_match_payment_no_match():
    notif = "You have received Tk 77.00 from 0199. TrxID Z"
    dues = [{"id": 1, "name": "Karim", "amount": "300"}]
    out = B.match_payment_to_due(notif, dues, lang="en")
    assert out["matched"] is False and out["auto_apply"] is False


def test_insights_sales_down_and_old_due():
    recs = {
        "sales_by_product": {"Tea": {"prev": 100, "this": 75},     # -25%
                             "Rice": {"prev": 100, "this": 98}},   # -2% no flag
        "dues": [{"name": "Rahim", "age_days": 45, "amount": "500"},
                 {"name": "New", "age_days": 3, "amount": "100"}],
    }
    out = B.insights(recs, lang="en")
    kinds = {i["kind"] for i in out}
    assert "sales_down" in kinds and "old_due" in kinds
    sd = [i for i in out if i["kind"] == "sales_down"][0]
    assert sd["pct"] == 25 and sd["product"] == "Tea"


def test_bank_loan_report_no_lending_no_scoring():
    rows = [{"month": "2026-08", "amount": "10000"},
            {"month": "2026-09", "amount": "20000"},
            {"month": "2026-10", "amount": "30000"}]
    out = B.bank_loan_report_data(rows, lang="en")
    assert out["total_sales"] == "60000"
    assert out["avg_monthly_sales"] == "20000"
    assert out["is_lending"] is False and out["is_credit_scoring"] is False
    assert "lend" in out["disclaimer"].lower()


# ===========================================================================
# §6 payments — NEVER hold money / NEVER a wallet (headline safety tests)
# ===========================================================================

def test_payments_never_holds_funds():
    d = B.merchant_qr_descriptor(
        {"provider": "bkash", "merchant_number": "01700000000",
         "merchant_name": "Rong"}, lang="en")
    assert d["holds_funds"] is False
    assert d["is_wallet"] is False
    assert d["routes_through_assisto"] is False
    assert d["merchant_number"] == "01700000000"


def test_merchant_qr_rejects_unknown_provider():
    try:
        B.merchant_qr_descriptor({"provider": "paypal"}, lang="en")
        assert False
    except ValueError:
        pass


def test_payment_link_never_custody():
    order = {"id": 9, "total": "1500"}
    # No partner key → mock link, not live, custodian is the partner (never us).
    mock = B.payment_link_builder(order, partner_key=None, lang="en")
    assert mock["live"] is False and mock["holds_funds"] is False
    assert mock["custodian"] == "licensed_partner"
    assert mock["needs_key"] is True
    # With a partner key → live link, STILL not our custody.
    live = B.payment_link_builder(order, partner_key="PK", lang="en")
    assert live["live"] is True and live["holds_funds"] is False
    assert live["custodian"] == "licensed_partner"


# ===========================================================================

def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"business_ai: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
