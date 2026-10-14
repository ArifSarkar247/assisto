"""
Hand-verified tests for logic_capture.py — PURE PYTHON, no Django, no DB.

Run:  python backend/crm/logic_capture_tests_snippets.py
   or: python -c "from crm.logic_capture_tests_snippets import run_all; run_all()"

The load-bearing guarantees under test:
  * dedupe matches on phone/email/(company+name), BD phone formats collapse.
  * MERGE PLAN never drops an activity (before == after, union preserved).
  * business-card OCR is key-gated: no key → needs_key, invents nothing.
  * form intake maps aliases, lower-cases email, keeps unmapped fields visible.
"""
from .logic_capture import (find_duplicates, is_duplicate_of, merge_plan,
                            card_parse, form_intake, norm_phone)


def _eq(a, b, msg=""):
    assert a == b, f"{msg}: expected {b!r}, got {a!r}"


def test_norm_phone():
    # +880, 0-prefixed, and bare all collapse to the same last-10 key.
    _eq(norm_phone("+8801712345678"), "1712345678", "intl")
    _eq(norm_phone("01712345678"), "1712345678", "local")
    _eq(norm_phone("01712-345678"), "1712345678", "dashed")
    _eq(norm_phone("1712345678"), "1712345678", "bare")
    assert norm_phone("+8801712345678") == norm_phone("01712 345678"), "formats equal"


def test_find_duplicates():
    leads = [
        {"id": 1, "name": "Karim", "company": "ABC Ltd", "phone": "01712345678",
         "email": "karim@abc.com"},
        {"id": 2, "name": "Karim", "company": "ABC Ltd", "phone": "+8801712345678"},
        {"id": 3, "name": "Rahim", "company": "XYZ", "email": "KARIM@ABC.COM"},
        {"id": 4, "name": "Solo", "company": "Nobody", "phone": "01999999999"},
    ]
    groups = find_duplicates(leads)
    # 1&2 are the same person (shared phone AND company+name); 1&3 share email
    # (case-insensitive). 4 is alone. Groups are keyed by their id-signature, so
    # assert by membership (a signature can be reached via >1 match key).
    sigs = {tuple(g["lead_ids"]) for g in groups}
    assert (1, 2) in sigs, "1&2 grouped (phone / company+name)"
    assert (1, 3) in sigs, "1&3 grouped (email, case-insensitive)"
    assert all(4 not in g["lead_ids"] for g in groups), "solo lead not grouped"


def test_is_duplicate_of():
    existing = [{"id": 1, "phone": "01712345678"},
                {"id": 2, "email": "x@y.com"}]
    cand = {"phone": "+8801712345678"}      # same person as id 1
    _eq(is_duplicate_of(cand, existing), [1], "new capture collides with id 1")
    _eq(is_duplicate_of({"phone": "01000000000"}, existing), [], "genuinely new")


def test_merge_plan_never_drops_activities():
    survivor = {
        "id": 1, "name": "Karim", "company": "", "email": "",
        "activities": [{"id": 101}, {"id": 102}],
        "deals": [{"id": 9}],
        "conversations": [], "proposals": [],
    }
    dup = {
        "id": 2, "name": "", "company": "ABC Ltd", "email": "karim@abc.com",
        "activities": [{"id": 201}, {"id": 202}, {"id": 203}],
        "deals": [{"id": 10}],
        "conversations": [{"id": 50}], "proposals": [{"id": 70}],
    }
    plan = merge_plan(survivor, [dup])
    _eq(plan["survivor_id"], 1, "survivor id")
    _eq(plan["delete_ids"], [2], "dup deleted")
    # NO ACTIVITY LOSS: survivor(2) + dup(3) = 5 before; dup's 3 re-pointed.
    _eq(plan["activity_count_before"], 5, "activities before")
    _eq(plan["activity_count_after"], 5, "activities after == before")
    _eq(sorted(plan["reassign"]["activities"]), [201, 202, 203],
        "all dup activities re-pointed, none dropped")
    _eq(sorted(plan["reassign"]["conversations"]), [50], "conversation kept")
    _eq(sorted(plan["reassign"]["proposals"]), [70], "proposal kept")
    _eq(sorted(plan["reassign"]["deals"]), [10], "deal kept")
    # Blank-only backfill: survivor's empty company/email filled from the dup;
    # survivor's own name is NOT overwritten.
    _eq(plan["backfill"].get("company"), "ABC Ltd", "backfill company")
    _eq(plan["backfill"].get("email"), "karim@abc.com", "backfill email")
    assert "name" not in plan["backfill"], "survivor name not overwritten"
    _eq(plan["warnings"], [], "no warnings / no loss")


def test_merge_plan_multi_dup_union():
    survivor = {"id": 1, "activities": [{"id": 1}]}
    d2 = {"id": 2, "activities": [{"id": 2}, {"id": 3}]}
    d3 = {"id": 3, "activities": [{"id": 4}]}
    plan = merge_plan(survivor, [d2, d3])
    _eq(plan["activity_count_before"], 4, "union before = 1+2+1")
    _eq(plan["activity_count_after"], 4, "no loss across 2 dups")
    _eq(sorted(plan["reassign"]["activities"]), [2, 3, 4], "union of dup activities")
    _eq(plan["delete_ids"], [2, 3], "both dups deleted")


def test_card_parse_key_gated():
    # NO key, no text → honest needs-key, invents nothing.
    r = card_parse(has_ocr_key=False)
    _eq(r["available"], False, "card no key not available")
    _eq(r["needs_key"], True, "card needs key")
    _eq(r["draft"], {}, "card invents nothing")
    # Typed/already-OCR'd text parses into a DRAFT (review step) even without a
    # key — we only forbid IMAGE OCR, not text structuring.
    text = ("Karim Rahman\nABC Textiles Ltd\n"
            "karim@abctextiles.com\n+880 1712-345678\nwww.abctex.com")
    r = card_parse(ocr_text=text, has_ocr_key=False)
    _eq(r["draft"]["email"], "karim@abctextiles.com", "card email")
    _eq(r["draft"]["company"], "ABC Textiles Ltd", "card company (Ltd suffix)")
    _eq(r["draft"]["name"], "Karim Rahman", "card name (first non-contact line)")
    assert "1712" in r["draft"]["phone"], "card phone parsed"
    assert "website" in r["draft"], "card website parsed"
    assert set(r["found"]) >= {"email", "phone", "name", "company"}, "found list"


def test_form_intake():
    payload = {"Full Name": " Karim ", "Company Name": "ABC Ltd",
               "E-mail": "Karim@ABC.com", "Phone Number": "01712345678",
               "Message": "Need VAT ERP", "budget": "5 lakh"}
    r = form_intake(payload)
    d = r["draft"]
    _eq(d["name"], "Karim", "form name trimmed")
    _eq(d["company"], "ABC Ltd", "form company")
    _eq(d["email"], "karim@abc.com", "form email lower-cased")
    _eq(d["phone"], "01712345678", "form phone")
    _eq(d["notes"], "Need VAT ERP", "form message → notes")
    _eq(d["source"], "website", "form source stamped")
    # unrecognised field is surfaced, never silently dropped.
    _eq(r["unmapped"], {"budget": "5 lakh"}, "unmapped field kept visible")


def run_all():
    tests = [test_norm_phone, test_find_duplicates, test_is_duplicate_of,
             test_merge_plan_never_drops_activities, test_merge_plan_multi_dup_union,
             test_card_parse_key_gated, test_form_intake]
    count = 0
    for t in tests:
        t()
        count += 1
    print(f"logic_capture: {count} test groups passed "
          f"(dedupe match; merge-plan NEVER drops activities; "
          f"card OCR key-gated mock; form intake normaliser)")
    return count


if __name__ == "__main__":
    run_all()
