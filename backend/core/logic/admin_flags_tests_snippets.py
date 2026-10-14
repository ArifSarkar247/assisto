"""
admin_flags_tests_snippets.py — plain-assert tests for the COST KILL-SWITCH &
FEATURE-FLAGS engine (#178, §21). Pure stdlib. `python admin_flags_tests_snippets.py`
or import and call run_all(). The engine is deterministic, so every assertion
below is hand-verified against fixed inputs.
"""

try:  # Django harness: core.logic.admin_flags_tests_snippets
    from core.logic import admin_flags as F
except ImportError:  # standalone
    import admin_flags as F  # noqa: E402


# --------------------------------------------------------------- catalog

def test_catalog_shape_and_ids_unique():
    cat = F.catalog()
    assert len(cat) == len(F.CATALOG)
    ids = [c["id"] for c in cat]
    assert len(ids) == len(set(ids))  # unique
    for c in cat:
        assert c["kind"] in F.KINDS
        assert isinstance(c["default"], bool)
        assert c["is_cost"] == (c["kind"] == F.KIND_COST)


def test_catalog_has_both_cost_and_feature():
    kinds = {c["kind"] for c in F.catalog()}
    assert F.KIND_COST in kinds
    assert F.KIND_FEATURE in kinds


def test_default_state_covers_every_flag():
    st = F.default_state()
    assert set(st.keys()) == set(F.FLAG_IDS)
    assert all(isinstance(v, bool) for v in st.values())


# --------------------------------------------------------------- confirm gate

def test_cost_flip_always_needs_confirm_both_directions():
    assert F.needs_confirm("ai_drafting", True) is True
    assert F.needs_confirm("ai_drafting", False) is True
    assert F.confirm_reason_code("ai_drafting", True) == "enable_cost"
    assert F.confirm_reason_code("ai_drafting", False) == "disable_cost"


def test_feature_confirm_only_on_disable():
    assert F.needs_confirm("messenger_public", False) is True
    assert F.needs_confirm("messenger_public", True) is False
    assert F.confirm_reason_code("messenger_public", False) == "disable_feature"
    assert F.confirm_reason_code("messenger_public", True) == ""


def test_unknown_flag_never_needs_confirm():
    assert F.needs_confirm("nope", True) is False
    assert F.confirm_reason_code("nope", True) == ""


# --------------------------------------------------------------- validation

def test_validate_rejects_unknown_flag():
    assert F.validate_flip("nope", True, None, "x") == ["unknown_flag"]


def test_validate_rejects_non_bool_value():
    assert "bad_value" in F.validate_flip("ai_drafting", "yes", True, "x")


def test_validate_flags_noop():
    # already True, asking for True
    assert "no_op" in F.validate_flip("ai_drafting", True, True, "x")


def test_validate_requires_reason_for_cost():
    probs = F.validate_flip("ai_drafting", False, True, "   ")
    assert "reason_required" in probs
    # a real reason clears it (and it is not a no-op: True -> False)
    assert F.validate_flip("ai_drafting", False, True, "cut spend") == []


def test_validate_feature_enable_needs_no_reason():
    # turning a feature back ON is safe: no reason required, no no-op
    assert F.validate_flip("messenger_public", True, False, "") == []


# --------------------------------------------------------------- apply + audit

def test_apply_flip_is_pure_and_builds_audit():
    st = F.default_state()
    before = dict(st)
    out = F.apply_flip(st, "ai_drafting", False, "owner#1", "cut spend",
                       "2026-10-14T10:00:00Z")
    assert out["ok"] is True
    assert out["problems"] == []
    # original dict untouched (pure)
    assert st == before
    # new state reflects the flip
    assert out["state"]["ai_drafting"] is False
    a = out["audit"]
    assert a["flag"] == "ai_drafting"
    assert a["old"] is True and a["new"] is False
    assert a["actor"] == "owner#1"
    assert a["reason"] == "cut spend"
    assert a["at"] == "2026-10-14T10:00:00Z"
    assert a["confirm_code"] == "disable_cost"
    assert a["kind"] == F.KIND_COST


def test_apply_flip_blocks_bad_flip():
    st = F.default_state()
    out = F.apply_flip(st, "ai_drafting", True, "owner#1", "", "t")
    # True->True is a no-op
    assert out["ok"] is False
    assert "no_op" in out["problems"]
    assert out["audit"] is None
    assert out["state"] == st


def test_apply_flip_requires_reason_when_gated():
    st = F.default_state()
    out = F.apply_flip(st, "sms_fanout", False, "owner#1", "", "t")
    assert out["ok"] is False
    assert "reason_required" in out["problems"]


def test_normalize_state_fills_defaults_and_drops_unknown():
    norm = F.normalize_state({"ai_drafting": False, "ghost": True})
    assert norm["ai_drafting"] is False
    assert "ghost" not in norm
    assert set(norm.keys()) == set(F.FLAG_IDS)
    # a flag we didn't pass keeps its default
    assert norm["new_signups"] == F.default_of("new_signups")


def test_normalize_state_coerces_known_forms():
    norm = F.normalize_state({"ai_drafting": "false", "sms_fanout": 0,
                              "push_fanout": "1"})
    assert norm["ai_drafting"] is False
    assert norm["sms_fanout"] is False
    assert norm["push_fanout"] is True


def test_summarize_counts_cost_on_and_features_off():
    st = F.default_state()  # all ON by default
    s0 = F.summarize(st)
    assert s0["cost_on"] == s0["cost_total"]
    assert s0["features_off"] == 0
    # kill one cost switch + disable one feature
    st["ai_drafting"] = False
    st["messenger_public"] = False
    s1 = F.summarize(st)
    assert s1["cost_on"] == s0["cost_total"] - 1
    assert s1["features_off"] == 1
    assert s1["total"] == len(F.CATALOG)


# --------------------------------------------------------------- scenario

def test_scenario_owner_kills_ai_then_restores():
    st = F.default_state()
    # 1) owner kills AI drafting to stop spend — needs reason, provides one
    k = F.apply_flip(st, "ai_drafting", False, "owner#1", "bill spike",
                     "2026-10-14T09:00:00Z")
    assert k["ok"] is True
    st = k["state"]
    assert st["ai_drafting"] is False
    # 2) tries to restore WITHOUT a reason -> blocked (cost flip, both ways)
    bad = F.apply_flip(st, "ai_drafting", True, "owner#1", "", "t2")
    assert bad["ok"] is False and "reason_required" in bad["problems"]
    # 3) restores WITH a reason -> ok, audit shows enable_cost
    good = F.apply_flip(st, "ai_drafting", True, "owner#1", "budget ok",
                        "2026-10-14T12:00:00Z")
    assert good["ok"] is True
    assert good["audit"]["confirm_code"] == "enable_cost"
    assert good["state"]["ai_drafting"] is True


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"admin_flags: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
