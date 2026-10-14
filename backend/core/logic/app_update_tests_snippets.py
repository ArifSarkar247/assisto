"""
app_update_tests_snippets.py — plain-assert tests for the in-app version-compare
helper (#180, §21). Pure stdlib. `python app_update_tests_snippets.py` or import
and call run_all(). Every assertion is hand-verified against fixed inputs; the
helper does no I/O, so these are deterministic.
"""

try:  # Django harness: core.logic.app_update_tests_snippets
    from core.logic import app_update as U
except ImportError:  # standalone
    import app_update as U  # noqa: E402


# --------------------------------------------------------------- parse_version

def test_parse_basic_and_padding_equivalence():
    assert U.parse_version("1.2.3") == (1, 2, 3)
    assert U.parse_version("1") == (1,)
    assert U.parse_version("v2.0") == (2, 0)
    assert U.parse_version(60) == (60,)


def test_parse_strips_prerelease_suffix():
    assert U.parse_version("1.2.3-beta2") == (1, 2, 3)
    assert U.parse_version("1.0+build7") == (1, 0)


def test_parse_rejects_garbage():
    assert U.parse_version("latest") is None
    assert U.parse_version("") is None
    assert U.parse_version(None) is None
    assert U.parse_version(-5) is None


# --------------------------------------------------------------- compare_versions

def test_compare_ordering():
    assert U.compare_versions("1.0", "1.1") == -1
    assert U.compare_versions("1.1", "1.0") == 1
    assert U.compare_versions("1.0", "1.0.0") == 0  # padding makes these equal
    assert U.compare_versions("2.0", "10.0") == -1  # numeric, not lexical


def test_compare_fail_closed_on_garbage():
    # Unparseable on either side -> 0 ("no update"), never a false positive.
    assert U.compare_versions("1.0", "latest") == 0
    assert U.compare_versions("huh", "2.0") == 0
    assert U.compare_versions(None, None) == 0


# --------------------------------------------------------------- check_update

def _keys_ok(d):
    assert set(d.keys()) == {
        "latest", "current", "update_available", "changelog", "url"}


def test_check_update_shape():
    d = U.check_update("1.0", {"version_name": "1.1", "apk_url":
                               "https://x/y.apk", "notes": "Fixes"})
    _keys_ok(d)
    assert d["current"] == "1.0"
    assert d["latest"] == "1.1"
    assert d["update_available"] is True
    assert d["changelog"] == "Fixes"
    assert d["url"] == "https://x/y.apk"


def test_check_update_up_to_date_hides_url():
    d = U.check_update("1.1", {"version_name": "1.1", "apk_url":
                               "https://x/y.apk", "notes": "n"})
    assert d["update_available"] is False
    assert d["url"] == ""           # no url when already current
    assert d["latest"] == "1.1"


def test_check_update_newer_local_is_not_an_update():
    d = U.check_update("2.0", {"version_name": "1.9", "apk_url":
                               "https://x/y.apk"})
    assert d["update_available"] is False
    assert d["url"] == ""


def test_check_update_falls_back_to_version_code():
    # No human name -> label from code, and compare current(int-ish) vs code.
    d = U.check_update("59", {"version_code": 60, "apk_url":
                              "https://x/y.apk"})
    assert d["latest"] == "60"
    assert d["update_available"] is True
    assert d["url"] == "https://x/y.apk"


def test_check_update_rejects_non_http_url():
    d = U.check_update("1.0", {"version_name": "1.1",
                               "apk_url": "javascript:alert(1)"})
    assert d["update_available"] is True
    assert d["url"] == ""           # unsafe scheme stripped


def test_check_update_handles_empty_record():
    d = U.check_update("1.0", {})
    _keys_ok(d)
    assert d["latest"] == ""
    assert d["update_available"] is False
    assert d["changelog"] == ""
    assert d["url"] == ""


def test_check_update_handles_non_dict_record():
    d = U.check_update("1.0", None)
    _keys_ok(d)
    assert d["update_available"] is False


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"app_update: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
