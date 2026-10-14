"""
moneyvoice_tests_snippets.py — plain-assert tests for the money-VOICE parser
(feature #62, SPEC v2.1 §21).

Same convention as money_tests_snippets.py: NOT a Django TestCase, every
function takes no args and raises AssertionError on failure. The integrator
folds these into core/tests.py. Smoke locally with:

    python3 -c "import core.logic.moneyvoice_tests_snippets as m; m.run_all()"

They import only money_parse (no DB, no network), so they are safe anywhere.
They assert the money-voice helpers REUSE the SMS building blocks correctly
(Bangla numerals, amount token, category slugs) and that a spoken utterance is
turned into a REVIEWABLE draft (never auto-logged by the parser itself).
"""
from decimal import Decimal

from core.logic import money_parse as P


# ---------------------------------------------------------------------------
# single-entry parsing: amount + type + category + counterparty
# ---------------------------------------------------------------------------

def test_mv_banglish_expense_minimal():
    # "cha 20 taka" — a bare spoken expense, no verb.
    (r,) = P.parse_money_voice("cha 20 taka")
    assert r["amount"] == Decimal("20"), r
    assert r["txn_type"] == "expense", r
    assert r["note"] == "cha", r
    assert r["parsed"] is True, r


def test_mv_bangla_gave_is_expense():
    # "রহিমকে ৫০০ টাকা দিলাম" — gave Rahim 500tk => expense + counterparty.
    (r,) = P.parse_money_voice("রহিমকে ৫০০ টাকা দিলাম")
    assert r["amount"] == Decimal("500"), r          # Bangla numerals normalised
    assert r["txn_type"] == "expense", r
    assert r["counterparty"] == "রহিম", r            # dative -কে stripped
    assert r["parsed"] is True, r


def test_mv_bangla_numerals_reuse():
    # digits come straight through normalize_digits (SMS parser reuse).
    (r,) = P.parse_money_voice("চা ২৫ টাকা")
    assert r["amount"] == Decimal("25"), r


def test_mv_income_bangla():
    (r,) = P.parse_money_voice("বেতন পেলাম ২৫০০০")
    assert r["txn_type"] == "income", r
    assert r["amount"] == Decimal("25000"), r
    assert r["category_guess"] == "salary", r        # reuses guess_category


def test_mv_income_banglish():
    (r,) = P.parse_money_voice("salary pelam 30000")
    assert r["txn_type"] == "income", r
    assert r["amount"] == Decimal("30000"), r


def test_mv_due_in_lent():
    # "রহিমকে ৫০০ টাকা ধার দিলাম" — lent Rahim => due_in (someone owes you).
    (r,) = P.parse_money_voice("রহিমকে ৫০০ টাকা ধার দিলাম")
    assert r["txn_type"] == "due_in", r
    assert r["counterparty"] == "রহিম", r
    assert r["amount"] == Decimal("500"), r


def test_mv_due_out_borrowed():
    # "Karim theke 1000 dhar nilam" — borrowed from Karim => due_out.
    (r,) = P.parse_money_voice("Karim theke 1000 dhar nilam")
    assert r["txn_type"] == "due_out", r
    assert r["counterparty"] == "Karim", r
    assert r["amount"] == Decimal("1000"), r


def test_mv_due_out_bangla_from():
    (r,) = P.parse_money_voice("করিমের থেকে ১০০০ টাকা ধার নিলাম")
    assert r["txn_type"] == "due_out", r
    assert r["counterparty"] == "করিম", r


def test_mv_english_spent():
    (r,) = P.parse_money_voice("I spent 150 on lunch")
    assert r["txn_type"] == "expense", r
    assert r["amount"] == Decimal("150"), r


def test_mv_category_reuse_health():
    # category comes from the SMS guess_category keyword rules.
    (r,) = P.parse_money_voice("bought medicine for 300 taka")
    assert r["category_guess"] == "health", r
    assert r["txn_type"] == "expense", r


def test_mv_category_reuse_transport():
    (r,) = P.parse_money_voice("rickshaw 30")
    assert r["category_guess"] == "transport", r


# ---------------------------------------------------------------------------
# never auto-log a wrong/empty parse — review-first guarantees
# ---------------------------------------------------------------------------

def test_mv_empty_returns_nothing():
    assert P.parse_money_voice("") == []
    assert P.parse_money_voice("   ") == []
    assert P.parse_money_voice(None) == []


def test_mv_no_amount_is_unparsed_not_dropped():
    # understood words, no number => kept but parsed=False (review must fill it);
    # NEVER silently logged.
    (r,) = P.parse_money_voice("lunch with friends")
    assert r["amount"] is None, r
    assert r["parsed"] is False, r
    assert r["txn_type"] is None, r


def test_mv_amount_only_defaults_to_expense_for_review():
    # a bare number with no verb -> expense draft, but the UI still confirms.
    (r,) = P.parse_money_voice("45")
    assert r["amount"] == Decimal("45"), r
    assert r["txn_type"] == "expense", r
    assert r["parsed"] is True, r


# ---------------------------------------------------------------------------
# batch ("tea 20, rickshaw 30")
# ---------------------------------------------------------------------------

def test_mv_batch_comma():
    out = P.parse_money_voice("tea 20, rickshaw 30")
    assert len(out) == 2, out
    assert out[0]["amount"] == Decimal("20"), out
    assert out[0]["note"] == "tea", out
    assert out[1]["amount"] == Decimal("30"), out
    assert out[1]["category_guess"] == "transport", out


def test_mv_batch_bangla_comma():
    out = P.parse_money_voice("চা ২০, রিকশা ৩০")
    assert len(out) == 2, out
    assert out[0]["amount"] == Decimal("20"), out
    assert out[1]["amount"] == Decimal("30"), out


def test_mv_batch_and_separator():
    out = P.parse_money_voice("lunch 120 and bus 15")
    assert len(out) == 2, out
    assert out[0]["amount"] == Decimal("120"), out
    assert out[1]["amount"] == Decimal("15"), out


def test_mv_batch_does_not_split_inside_number():
    # "1,500" is ONE amount, not a batch boundary.
    out = P.parse_money_voice("groceries 1,500")
    assert len(out) == 1, out
    assert out[0]["amount"] == Decimal("1500"), out


def test_mv_single_returns_one_element_list():
    out = P.parse_money_voice("cha 20")
    assert isinstance(out, list) and len(out) == 1, out


def test_mv_split_drops_numberless_fragments():
    # trailing connective with no amount isn't an entry.
    frags = P.split_money_voice("tea 20, and")
    assert frags == ["tea 20"], frags


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"OK — {len(fns)} money-voice tests passed")
    return len(fns)
