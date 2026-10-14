"""
supplier_market_tests_snippets.py — plain-assert tests for SUPPLIER & WHOLESALE
MARKET (#144, §21). Pure stdlib, deterministic.
`python supplier_market_tests_snippets.py` or import and call run_all().
"""
try:  # Django harness
    from core.logic import supplier_market as S
except ImportError:  # standalone
    import supplier_market as S  # noqa: E402


# --------------------------------------------------------------- normalize

def test_normalize_products_from_string():
    row = {"name": "  Acme  ", "category": "Wholesale", "rating": "4",
           "products": "Rice, rice ,Oil\nSalt"}
    s = S.normalize(row)
    assert s["name"] == "Acme"
    assert s["category"] == "wholesale"
    assert s["rating"] == 4
    # comma/newline split, trimmed, de-duped case-insensitively, order kept
    assert s["products"] == ["Rice", "Oil", "Salt"]
    assert s["products_display"] == "Rice, Oil, Salt"
    assert s["marker"] == S.MARKER_KEY


def test_normalize_products_from_list_and_bad_category():
    s = S.normalize({"name": "X", "category": "unknown-cat",
                     "products": ["A", " ", "A", "b"]})
    assert s["category"] == "other"           # unknown normalised
    assert s["products"] == ["A", "b"]        # blank dropped, dup dropped


def test_rating_clamped():
    assert S.normalize({"name": "a", "rating": 9})["rating"] == 5
    assert S.normalize({"name": "a", "rating": -3})["rating"] == 0
    assert S.normalize({"name": "a", "rating": "junk"})["rating"] == 0
    assert S.normalize({"name": "a"})["rating"] == 0


def test_category_space_dash_normalised():
    assert S.normalize({"name": "a", "category": "RAW MATERIAL"})["category"] \
        == "raw_material"


# --------------------------------------------------------------- search

def _rows():
    return [
        {"id": 1, "name": "Dhaka Wholesale", "category": "wholesale",
         "location": "Dhaka", "rating": 5, "products": "Rice, Oil",
         "reorder": True},
        {"id": 2, "name": "Ctg Packaging", "category": "packaging",
         "location": "Chittagong", "rating": 3, "products": "Boxes"},
        {"id": 3, "name": "Barisal Foods", "category": "food",
         "location": "Barisal", "rating": 4, "products": "Spices",
         "reorder": True},
        {"id": 4, "name": "", "category": "food"},   # no name -> dropped
    ]


def test_search_all_sorted_by_rating_then_name():
    out = S.search(_rows())
    assert out["total_count"] == 3           # blank-name dropped
    assert out["match_count"] == 3
    assert out["reorder_count"] == 2
    names = [s["name"] for s in out["suppliers"]]
    assert names == ["Dhaka Wholesale", "Barisal Foods", "Ctg Packaging"]
    assert out["partner_required"] is False
    assert out["by_category"] == {"wholesale": 1, "packaging": 1, "food": 1}


def test_search_by_category():
    out = S.search(_rows(), category="food")
    assert out["match_count"] == 1
    assert out["suppliers"][0]["name"] == "Barisal Foods"


def test_search_by_location_substring_caseins():
    out = S.search(_rows(), location="dhak")
    assert out["match_count"] == 1
    assert out["suppliers"][0]["id"] == 1


def test_search_by_query_matches_products():
    out = S.search(_rows(), query="rice")
    assert out["match_count"] == 1 and out["suppliers"][0]["id"] == 1


def test_search_min_rating_and_reorder_only():
    assert S.search(_rows(), min_rating=4)["match_count"] == 2
    ro = S.search(_rows(), reorder_only=True)
    assert ro["match_count"] == 2
    assert {s["id"] for s in ro["suppliers"]} == {1, 3}


def test_search_empty():
    out = S.search([])
    assert out["total_count"] == 0 and out["suppliers"] == []
    assert out["partner_required"] is False


def test_search_deterministic():
    assert S.search(_rows()) == S.search(_rows())


# --------------------------------------------------------------- compare

def test_compare_picks_in_order_and_best():
    out = S.compare(_rows(), [2, 1, 3])
    assert out["count"] == 3
    assert [s["id"] for s in out["suppliers"]] == [2, 1, 3]   # order preserved
    assert out["best_rating_id"] == 1                        # rating 5
    assert set(out["reorder_ids"]) == {1, 3}
    assert out["enough"] is True


def test_compare_not_enough():
    out = S.compare(_rows(), [1])
    assert out["enough"] is False and out["count"] == 1


def test_compare_unknown_ids_skipped():
    out = S.compare(_rows(), [99, 2])
    assert [s["id"] for s in out["suppliers"]] == [2]


def test_compare_best_none_when_all_unrated():
    rows = [{"id": 1, "name": "a", "rating": 0},
            {"id": 2, "name": "b", "rating": 0}]
    out = S.compare(rows, [1, 2])
    assert out["best_rating_id"] is None


# --------------------------------------------------------------- reorder

def test_reorder_list():
    out = S.reorder_list(_rows())
    assert out["count"] == 2
    assert [s["id"] for s in out["suppliers"]] == [1, 3]     # rating desc
    assert out["has_contact"] == 0


def test_reorder_empty():
    out = S.reorder_list([{"id": 1, "name": "a"}])
    assert out["count"] == 0 and out["suppliers"] == []


# --------------------------------------------------------------- seam

def test_directory_seam_honest_no_suppliers():
    s = S.directory_seam(query="rice", category="wholesale", location="Dhaka")
    assert s["partner_required"] is True
    assert s["mock"] is True
    assert s["suppliers"] == []              # NEVER scrapes/fabricates
    assert s["integration"] == "supplier_directory"
    assert s["query_shape"]["query"] == "rice"


# --------------------------------------------------------------- runner

def run_all():
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    return len(fns)


if __name__ == "__main__":
    n = run_all()
    print(f"supplier_market: {n} tests passed")
