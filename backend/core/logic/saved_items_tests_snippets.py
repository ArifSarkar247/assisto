"""
saved_items_tests_snippets.py — plain-assert tests for the SAVED / BOOKMARKS
logic (#18, §21). Pure stdlib. `python saved_items_tests_snippets.py` or import
and call run_all(). All helpers are deterministic, so every assertion is
hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import saved_items as S
except ImportError:  # standalone
    import saved_items as S  # noqa: E402


# ---------------------------------------------------------------- normalise
def test_normalise_tag():
    assert S.normalise_tag("  #Finance ") == "finance"
    assert S.normalise_tag("Health  Tips") == "health tips"
    assert S.normalise_tag("") == ""
    assert S.normalise_tag(None) == ""
    assert len(S.normalise_tag("x" * 100)) == S.MAX_TAG


def test_normalise_kind_defaults():
    assert S.normalise_kind("LINK") == "link"
    assert S.normalise_kind("weird") == S.DEFAULT_KIND
    assert S.normalise_kind(None) == S.DEFAULT_KIND


# ---------------------------------------------------------------- validate
def test_validate_ok():
    assert S.validate("A good tip") == []
    assert S.validate("My link", "link", "https://example.com") == []


def test_validate_catches_each_bad_input():
    assert "title_required" in S.validate("   ")
    assert "bad_kind" in S.validate("t", "nope")
    assert "ref_required_for_link" in S.validate("t", "link", "")


# ---------------------------------------------------------------- make_item
def test_make_item_normalises_and_trims():
    it = S.make_item("  Save me  ", note="  body  ", tag="#Money",
                     kind="answer", ref=" r ", created="2026-10-14")
    assert it["title"] == "Save me"
    assert it["note"] == "body"
    assert it["tag"] == "money"
    assert it["kind"] == "answer"
    assert it["ref"] == "r"
    assert "id" not in it  # collection assigns id


def test_make_item_rejects_invalid():
    try:
        S.make_item("")
        assert False, "expected ValueError"
    except ValueError as e:
        assert "title_required" in str(e)


def test_make_item_caps_title_length():
    it = S.make_item("x" * 500)
    assert len(it["title"]) == S.MAX_TITLE


# ---------------------------------------------------------------- search
_ITEMS = [
    {"id": 1, "title": "Eid sale idea", "note": "shop discount", "tag": "money",
     "kind": "note", "ref": "", "created": "2026-10-10"},
    {"id": 2, "title": "Strong passwords", "note": "use a manager",
     "tag": "safety", "kind": "answer", "ref": "", "created": "2026-10-12"},
    {"id": 3, "title": "Doctor visit", "note": "bring reports", "tag": "health",
     "kind": "doc", "ref": "doc-7", "created": "2026-10-11"},
    {"id": 4, "title": "Useful link", "note": "", "tag": "safety",
     "kind": "link", "ref": "https://example.com", "created": "2026-10-13"},
]


def test_search_blank_returns_all():
    assert S.search(_ITEMS, "") == list(_ITEMS)
    assert S.search(_ITEMS, "   ") == list(_ITEMS)


def test_search_is_case_insensitive_and_and_of_terms():
    out = S.search(_ITEMS, "EID sale")
    assert [i["id"] for i in out] == [1]
    # both terms must appear somewhere
    assert S.search(_ITEMS, "eid safety") == []


def test_search_matches_note_tag_and_ref():
    assert [i["id"] for i in S.search(_ITEMS, "manager")] == [2]  # note
    assert [i["id"] for i in S.search(_ITEMS, "health")] == [3]   # tag
    assert [i["id"] for i in S.search(_ITEMS, "example.com")] == [4]  # ref


def test_search_preserves_order():
    out = S.search(_ITEMS, "a")  # appears in several
    ids = [i["id"] for i in out]
    assert ids == sorted(ids, key=lambda x: [j["id"] for j in _ITEMS].index(x))


# ---------------------------------------------------------------- filters
def test_filter_by_tag():
    assert [i["id"] for i in S.filter_by_tag(_ITEMS, "safety")] == [2, 4]
    assert S.filter_by_tag(_ITEMS, "") == list(_ITEMS)  # 'All'
    assert S.filter_by_tag(_ITEMS, "#Safety") == \
        [i for i in _ITEMS if i["tag"] == "safety"]  # normalised


def test_filter_by_kind():
    assert [i["id"] for i in S.filter_by_kind(_ITEMS, "link")] == [4]
    assert S.filter_by_kind(_ITEMS, "") == list(_ITEMS)
    assert S.filter_by_kind(_ITEMS, "bogus") == list(_ITEMS)


def test_untagged_only_matches_blank_tag():
    items = [{"id": 9, "title": "t", "tag": "", "kind": "note"}]
    assert S.filter_by_tag(items, "money") == []
    assert S.filter_by_tag(items, "") == items


# ---------------------------------------------------------------- tag counts
def test_tag_counts_sorted_by_frequency_then_alpha():
    tc = S.tag_counts(_ITEMS)
    assert tc[0] == ("safety", 2)  # most used first
    rest = dict(tc)
    assert rest["money"] == 1 and rest["health"] == 1
    # ties sorted alphabetically: health before money
    tags_in_order = [t for t, _ in tc]
    assert tags_in_order == ["safety", "health", "money"]


def test_tag_counts_excludes_untagged():
    items = [{"tag": ""}, {"tag": "x"}]
    assert S.tag_counts(items) == [("x", 1)]


# ---------------------------------------------------------------- sort
def test_sort_recent_newest_first():
    out = S.sort_recent(_ITEMS)
    assert [i["id"] for i in out] == [4, 2, 3, 1]  # by created desc


def test_sort_recent_blank_created_sorts_last():
    items = [{"id": 1, "created": ""}, {"id": 2, "created": "2026-01-01"}]
    assert [i["id"] for i in S.sort_recent(items)] == [2, 1]


# ---------------------------------------------------------------- apply (states)
def test_apply_empty_state():
    r = S.apply([])
    assert r["empty"] is True and r["no_results"] is False
    assert r["items"] == []


def test_apply_no_results_distinct_from_empty():
    r = S.apply(_ITEMS, query="zzzzz")
    assert r["empty"] is False
    assert r["no_results"] is True  # has items but filter matched none
    assert r["items"] == []


def test_apply_browse_all_is_not_no_results():
    r = S.apply(_ITEMS)  # no filter -> browsing everything
    assert r["empty"] is False and r["no_results"] is False
    assert len(r["items"]) == len(_ITEMS)


def test_apply_pipeline_tag_then_search_then_sort():
    r = S.apply(_ITEMS, query="link", tag="safety")
    assert [i["id"] for i in r["items"]] == [4]
    assert r["no_results"] is False


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"saved_items: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
