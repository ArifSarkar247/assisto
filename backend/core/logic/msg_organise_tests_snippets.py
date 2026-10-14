"""
msg_organise_tests_snippets.py — plain-assert tests for core.logic.msg_organise.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py via
_make_snippet_case (see SocialComposeSnippetTests / MsgMessengerUiSnippetTests).
Smoke locally:
    python3 -c "import core.logic.msg_organise_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import msg_organise as O


_NOW = datetime(2026, 10, 14, 12, 0, 0, tzinfo=timezone.utc)


# ---- #87: PIN (cap + ordering) ----

def test_pin_cap_blocks_beyond_limit():
    ok, why = O.can_pin_chat(O.PIN_CAP_PER_USER, is_already_pinned=False)
    assert ok is False and why == "pin_cap_reached"
    # under the cap -> allowed
    assert O.can_pin_chat(O.PIN_CAP_PER_USER - 1, False) == (True, "ok")


def test_pin_unpin_always_allowed_idempotent():
    # un-pinning / re-touching an already-pinned chat is always ok even at cap
    assert O.can_pin_chat(O.PIN_CAP_PER_USER, is_already_pinned=True) == (True, "ok")


def test_order_pinned_float_to_top_by_pin_at():
    chats = [
        {"id": "a", "at": _NOW.isoformat()},
        {"id": "b", "pinned": True,
         "pin_at": (_NOW - timedelta(minutes=1)).isoformat(),
         "at": (_NOW - timedelta(hours=5)).isoformat()},
        {"id": "c", "pinned": True,
         "pin_at": (_NOW - timedelta(minutes=10)).isoformat(),
         "at": _NOW.isoformat()},
        {"id": "d", "at": (_NOW - timedelta(hours=1)).isoformat()},
    ]
    ordered = [c["id"] for c in O.order_chat_list(chats)]
    # pinned first (earliest pin_at = c then b), then rest newest-first (a, d)
    assert ordered == ["c", "b", "a", "d"]


# ---- #87: ARCHIVE ----

def test_partition_archived_counts_and_splits():
    chats = [{"id": 1}, {"id": 2, "archived": True}, {"id": 3}]
    part = O.partition_archived(chats)
    assert part["archived_count"] == 1
    assert [c["id"] for c in part["active"]] == [1, 3]
    assert [c["id"] for c in part["archived"]] == [2]


def test_archiving_clears_pin():
    out = O.set_archived({"id": 1, "pinned": True, "pin_at": _NOW.isoformat()}, True)
    assert out["archived"] is True
    assert out["pinned"] is False and out["pin_at"] is None
    # un-archive leaves pin untouched (stays unpinned here)
    back = O.set_archived(out, False)
    assert back["archived"] is False


# ---- #87: MUTE ----

def test_mute_duration_normalised():
    assert O.normalize_mute_duration("1W") == "1w"
    assert O.normalize_mute_duration("bogus") == "8h"


def test_timed_mute_expires_but_always_stays():
    rec8h = O.build_mute({"chat_kind": "member", "chat_id": "5"}, "8h", now=_NOW)
    assert O.is_muted(rec8h, now=_NOW) is True
    later = _NOW + timedelta(seconds=O.MUTE_8H_SEC + 1)
    assert O.is_muted(rec8h, now=later) is False          # honest: expired
    always = O.build_mute({"chat_kind": "member", "chat_id": "5"}, "always",
                          now=_NOW)
    assert always["mute_until"] is None
    assert O.is_muted(always, now=later) is True           # no expiry


def test_missing_mute_record_not_muted():
    assert O.is_muted(None, now=_NOW) is False
    assert O.is_muted({}, now=_NOW) is False


# ---- #87: SEARCH (honest result state) ----

def test_search_idle_when_blank():
    chats = [{"member": {"name": "Rahim"}, "last_text": "hi"}]
    res = O.search_chats(chats, "   ")
    assert res["state"] == "idle"
    assert len(res["results"]) == 1


def test_search_results_and_no_results():
    chats = [
        {"member": {"name": "Rahim Uddin"}, "last_text": "meeting at 5"},
        {"member": {"name": "Karim"}, "last_text": "lunch?"},
    ]
    hit = O.search_chats(chats, "rahim meeting")
    assert hit["state"] == "results"
    assert len(hit["results"]) == 1
    miss = O.search_chats(chats, "zzz nobody")
    assert miss["state"] == "no_results"
    assert miss["results"] == []


def test_search_strips_ask_assisto_prefix_and_folds_accents():
    chats = [{"member": {"name": "Zoë"}, "last_text": ""}]
    res = O.search_chats(chats, "Ask Assisto zoe")
    assert res["state"] == "results"
    assert len(res["results"]) == 1


# ---- #86: EDIT gate ----

def test_can_edit_mine_in_window():
    m = {"mine": True, "content_type": "text",
         "at": (_NOW - timedelta(minutes=5)).isoformat()}
    assert O.can_edit_message(m, now=_NOW) == (True, "ok")


def test_cannot_edit_others_or_stale_or_media():
    assert O.can_edit_message({"mine": False, "at": _NOW.isoformat()},
                              now=_NOW) == (False, "not_mine")
    stale = {"mine": True, "content_type": "text",
             "at": (_NOW - timedelta(minutes=O.EDIT_WINDOW_MIN + 1)).isoformat()}
    assert O.can_edit_message(stale, now=_NOW) == (False, "edit_window_passed")
    media = {"mine": True, "content_type": "photo", "at": _NOW.isoformat()}
    assert O.can_edit_message(media, now=_NOW) == (False, "not_text")


# ---- #86: DELETE scope options + apply ----

def test_delete_scopes_everyone_only_mine_in_window():
    mine = {"mine": True, "at": (_NOW - timedelta(minutes=10)).isoformat()}
    assert O.delete_scope_options(mine, now=_NOW) == ["me", "everyone"]
    theirs = {"mine": False, "at": _NOW.isoformat()}
    assert O.delete_scope_options(theirs, now=_NOW) == ["me"]
    stale = {"mine": True,
             "at": (_NOW - timedelta(minutes=O.DELETE_EVERYONE_WINDOW_MIN + 1))
             .isoformat()}
    assert O.delete_scope_options(stale, now=_NOW) == ["me"]


def test_apply_delete_everyone_tombstones():
    out = O.apply_delete({"text": "secret", "mine": True}, "everyone")
    assert out["deleted"] == "everyone" and out["text"] == ""
    me = O.apply_delete({"text": "keep", "mine": True}, "me")
    assert me["deleted"] == "me"


# ---- #86: markers ----

def test_edited_marker_hidden_once_deleted():
    assert O.edited_marker({"edited": True}) is True
    assert O.edited_marker({"edited": True, "deleted": "everyone"}) is False


def test_deleted_marker_values():
    assert O.deleted_marker({"deleted": "everyone"}) == "everyone"
    assert O.deleted_marker({"deleted": "me"}) == "me"
    assert O.deleted_marker({}) == ""


# ---- #86: forward hops ----

def test_forward_hops_increment_and_many_label():
    first = O.normalize_forward({"forward_hops": 0})
    assert first["forward_hops"] == 1 and first["many_times"] is False
    many = O.normalize_forward({"forward_hops": O.FORWARD_MANY_HOPS - 1})
    assert many["forward_hops"] == O.FORWARD_MANY_HOPS and many["many_times"] is True
    # a negative/garbage hop count never drops below one
    assert O.normalize_forward({"forward_hops": -3})["forward_hops"] == 1


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"msg_organise: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
