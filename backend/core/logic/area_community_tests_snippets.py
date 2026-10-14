"""
area_community_tests_snippets.py — plain-assert tests for the Area/neighbourhood
board logic (#194, §20, advanced). Pure stdlib. Deterministic (no clock), every
assertion hand-verified against fixed inputs. No DB, no AI, no network.

    python3 area_community_tests_snippets.py   (or import and call run_all())
"""

try:  # Django harness
    from core.logic import area_community as A
except ImportError:  # standalone
    import area_community as A  # noqa: E402


def _posts():
    return [
        {"id": 1, "category": "announcement", "title": "Water off Friday",
         "body": "Supply cut 9-12", "area": "Dhanmondi, Dhaka",
         "created": "2026-10-10T09:00:00"},
        {"id": 2, "category": "service", "title": "Maths tutor",
         "body": "Class 6-10", "area": "dhanmondi,  dhaka",
         "contact": "0170...", "price": "2000", "created": "2026-10-12T08:00:00"},
        {"id": 3, "category": "lost_found", "title": "Lost grey cat",
         "area": "Gulshan, Dhaka", "created": "2026-10-11T10:00:00"},
        {"id": 4, "category": "alert", "title": "Scam calls in block B",
         "area": "Dhanmondi, Dhaka", "created": "2026-10-12T20:00:00"},
    ]


# --------------------------------------------------------------- validation

def test_validate_requires_category_title_area():
    p = A.validate(category="bogus", title="", area="")
    assert "bad_category" in p
    assert "empty_title" in p
    assert "empty_area" in p


def test_validate_all_is_not_a_post_category():
    # 'all' is a filter pseudo-category; a POST may not use it
    assert "bad_category" in A.validate(category="all", title="x", area="A")


def test_validate_clean_post_ok():
    assert A.validate(category="event", title="Eid fair",
                      area="Mirpur") == []


def test_validate_title_length_bound():
    assert "title_too_long" in A.validate(category="event",
                                          title="x" * 200, area="A")


# --------------------------------------------------------------- privacy

def test_display_drops_precise_location_fields():
    row = {"id": 9, "category": "service", "title": "Plumber",
           "area": "Mirpur", "house": "12/B road 4", "gps": "23.8,90.4",
           "lat": "23.8", "lon": "90.4", "created": "2026-10-10"}
    out = A.display_post(row)
    for bad in ("house", "gps", "lat", "lon"):
        assert bad not in out
    assert out["area"] == "Mirpur"


def test_display_omits_blank_optional_fields():
    out = A.display_post({"id": 1, "category": "event", "title": "t",
                          "area": "A", "created": "2026-01-01"})
    assert "contact" not in out and "price" not in out


def test_display_keeps_optional_when_present():
    out = A.display_post({"id": 1, "category": "service", "title": "t",
                          "area": "A", "contact": " 017 ", "price": " 500 ",
                          "created": "2026-01-01"})
    assert out["contact"] == "017" and out["price"] == "500"


# --------------------------------------------------------------- area scope

def test_feed_area_filter_is_case_and_space_insensitive():
    f = A.feed(_posts(), area="  DHANMONDI , DHAKA ")
    ids = {p["id"] for p in f["posts"]}
    # rows 1,2,4 are Dhanmondi (note row 2 uses different spacing/case); 3 is Gulshan
    assert ids == {1, 2, 4}


def test_feed_no_area_returns_all_titled_posts():
    f = A.feed(_posts())
    assert f["count"] == 4


def test_feed_drops_titleless_rows():
    rows = _posts() + [{"id": 99, "category": "event", "title": "   ",
                        "area": "Dhanmondi, Dhaka", "created": "2026-10-13"}]
    f = A.feed(rows, area="Dhanmondi, Dhaka")
    assert all(p["id"] != 99 for p in f["posts"])


# --------------------------------------------------------------- category

def test_feed_category_filter():
    f = A.feed(_posts(), area="Dhanmondi, Dhaka", category="alert")
    assert [p["id"] for p in f["posts"]] == [4]


def test_feed_counts_are_area_scoped_before_category_filter():
    f = A.feed(_posts(), area="Dhanmondi, Dhaka", category="alert")
    # counts reflect ALL Dhanmondi rows (announcement1, service1, alert1)
    assert f["counts"]["announcement"] == 1
    assert f["counts"]["service"] == 1
    assert f["counts"]["alert"] == 1
    assert f["counts"]["lost_found"] == 0
    assert f["area_total"] == 3


def test_bad_category_filter_falls_back_to_all():
    f = A.feed(_posts(), area="Dhanmondi, Dhaka", category="nonsense")
    assert f["category"] == A.FILTER_ALL
    assert f["count"] == 3


# --------------------------------------------------------------- order

def test_feed_newest_first_ties_by_id():
    rows = [
        {"id": 5, "category": "event", "title": "a", "area": "Z",
         "created": "2026-10-12T08:00:00"},
        {"id": 6, "category": "event", "title": "b", "area": "Z",
         "created": "2026-10-12T08:00:00"},
        {"id": 7, "category": "event", "title": "c", "area": "Z",
         "created": "2026-10-13T08:00:00"},
    ]
    f = A.feed(rows, area="Z")
    assert [p["id"] for p in f["posts"]] == [7, 6, 5]


def test_feed_is_deterministic():
    assert A.feed(_posts(), area="Dhanmondi, Dhaka", category="all") == \
        A.feed(_posts(), area="Dhanmondi, Dhaka", category="all")


# --------------------------------------------------------------- labels

def test_category_label_bilingual():
    assert A.category_label("en", "alert") == "Alert"
    assert A.category_label("bn", "alert") != "Alert"  # Bangla string


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"area_community: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
