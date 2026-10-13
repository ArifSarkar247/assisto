"""
circle_messaging_tests_snippets.py — plain-assert tests for
core.logic.circle_messaging.  NOT a Django TestCase (no DB).

Smoke locally:
    python3 -c "import core.logic.circle_messaging_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle as C
from core.logic import circle_messaging as M


def _now():
    return datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)


# ---- send precheck (circle-only enforcement) ----

def test_send_precheck_requires_mutual_accept():
    assert M.send_precheck(C.REQ_ACCEPTED, C.REQ_ACCEPTED) == (True, "ok")
    ok, why = M.send_precheck(C.REQ_ACCEPTED, C.REQ_PENDING)
    assert ok is False and why == "not_connected"
    ok, why = M.send_precheck(C.REQ_ACCEPTED, C.REQ_ACCEPTED, blocked_either=True)
    assert ok is False and why == "blocked"


def test_send_precheck_restricted_tagged():
    ok, why = M.send_precheck(C.REQ_ACCEPTED, C.REQ_ACCEPTED, restricted=True)
    assert ok is True and why == "restricted"


# ---- envelope validation (ciphertext-only, enrichments) ----

def test_build_text_envelope_opaque_with_reply():
    env = M.build_text_envelope(7, 1, [2], "3q2+7w==", "AAEC", "k1",
                                reply_to="m99", now=_now())
    ok, why = M.validate_message_envelope(env)
    assert ok, why
    assert env["reply_to"] == "m99"
    assert C.looks_like_plaintext(env) is False


def test_envelope_rejects_plaintext_reply_preview():
    # A client must NOT ship the quoted text; only the reply_to id.
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "reply_to": "m1", "text": "quoted mom"}
    ok, _ = M.validate_message_envelope(env)
    assert ok is False


def test_link_preview_must_be_opaque():
    bad = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2],
           "link_preview": {"url": "http://x", "title": "News"}}
    ok, why = M.validate_message_envelope(bad)
    assert ok is False and "link_preview" in why
    good = {"content_type": "text", "ciphertext": "x", "nonce": "y",
            "recipient_ids": [2],
            "link_preview": {"ciphertext": "AbC", "nonce": "Zm8"}}
    ok, _ = M.validate_message_envelope(good)
    assert ok is True


def test_forward_hops_bounds():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "forwarded": True, "forward_hops": 99}
    assert M.validate_message_envelope(env)[0] is False


# ---- edit window ----

def test_edit_within_window():
    env = M.build_text_envelope(7, 1, [2], "a", "b", "k1", now=_now())
    env2, ok = M.apply_edit(env, 1, "new", "nonce2", now=_now() + timedelta(minutes=5))
    assert ok and env2["ciphertext"] == "new" and env2["edited_at"]


def test_edit_blocked_after_window():
    env = M.build_text_envelope(7, 1, [2], "a", "b", "k1", now=_now())
    _, ok = M.apply_edit(env, 1, "new", "n", now=_now() + timedelta(minutes=20))
    assert ok is False


def test_edit_only_sender():
    env = M.build_text_envelope(7, 1, [2], "a", "b", "k1", now=_now())
    assert M.can_edit(env, 2, now=_now()) is False


# ---- delete for me / everyone ----

def test_delete_for_everyone_tombstones_ciphertext():
    env = M.build_text_envelope(7, 1, [2], "secret_ct", "n", "k1", now=_now())
    env2, ok = M.apply_delete(env, 1, "everyone", now=_now() + timedelta(minutes=10))
    assert ok and env2["deleted"] == "everyone"
    assert env2["ciphertext"] == "" and env2["nonce"] == ""
    assert M.display_tombstone(env2, "en") == "This message was deleted."


def test_delete_for_everyone_window_and_actor():
    env = M.build_text_envelope(7, 1, [2], "x", "n", "k1", now=_now())
    _, ok = M.apply_delete(env, 2, "everyone", now=_now())  # not sender
    assert ok is False
    _, ok = M.apply_delete(env, 1, "everyone",
                           now=_now() + timedelta(days=3))  # too late
    assert ok is False


def test_delete_for_me_hides_per_member():
    env = M.build_text_envelope(7, 1, [2], "x", "n", "k1", now=_now())
    env2, ok = M.apply_delete(env, 2, "me")
    assert ok and 2 in env2["hidden_for"]
    assert env2["ciphertext"] == "x"  # body kept for others


# ---- reactions ----

def test_reactions_add_remove_summary():
    env = M.build_text_envelope(7, 1, [2], "x", "n", "k1", now=_now())
    env, ok = M.add_reaction(env, 2, "\U0001F44D")
    assert ok
    env, _ = M.add_reaction(env, 3, "\U0001F44D")
    env, _ = M.add_reaction(env, 4, "❤️")
    s = M.reaction_summary(env)
    assert s["total"] == 3
    assert list(s["counts"].items())[0][1] == 2  # thumbs up most
    env, _ = M.remove_reaction(env, 2)
    assert M.reaction_summary(env)["total"] == 2


def test_reaction_rejects_overlong():
    env = M.build_text_envelope(7, 1, [2], "x", "n", "k1", now=_now())
    _, ok = M.add_reaction(env, 2, "this is not an emoji it is text")
    assert ok is False


# ---- star / pin ----

def test_star_toggle_per_member():
    env = M.build_text_envelope(7, 1, [2], "x", "n", "k1", now=_now())
    env, now_on = M.toggle_star(env, 1)
    assert now_on and M.is_starred(env, 1)
    env, now_on = M.toggle_star(env, 1)
    assert now_on is False and not M.is_starred(env, 1)


def test_pin_cap():
    pins = []
    pins, ok = M.apply_pin(pins, "m1"); assert ok
    pins, ok = M.apply_pin(pins, "m2"); assert ok
    pins, ok = M.apply_pin(pins, "m3"); assert ok
    pins, ok = M.apply_pin(pins, "m4")  # over cap of 3
    assert ok is False and "m4" not in pins
    assert M.can_pin(pins, "m2") is True       # already pinned -> can toggle
    pins, ok = M.apply_pin(pins, "m2", pin=False)
    assert "m2" not in pins


# ---- forward ----

def test_forward_label_and_fields():
    assert M.forward_label(0) is None
    assert M.forward_label(1, "en") == "Forwarded"
    assert M.forward_label(6, "en") == "Forwarded many times"
    src = {"forward_hops": 2, "reply_to": "m5", "reactions": {"2": "x"}}
    f = M.build_forward_fields(src)
    assert f["forwarded"] is True and f["forward_hops"] == 3
    assert f["reply_to"] is None


# ---- ticks ----

def test_tick_state():
    env = {"delivered_to": [2], "read_by": []}
    assert M.tick_state(env, 2) == "delivered"
    env["read_by"] = [2]
    assert M.tick_state(env, 2) == "read"
    assert M.tick_state(env, 9) == "sent"


# ---- offline queue ----

def test_retry_backoff_and_giveup():
    assert M.next_retry_delay(0) == 0
    assert M.next_retry_delay(2) == 5
    assert M.next_retry_delay(999) == M.RETRY_BACKOFF_SEC[-1]
    assert M.should_give_up(M.RETRY_MAX_ATTEMPTS) is True
    assert M.should_give_up(0) is False


def test_dedupe_key():
    assert M.dedupe_key(5, "abc") == "5:abc"


def test_queue_snapshot_orders_and_drops():
    base = _now()
    pending = [
        {"client_msg_id": "b", "created_at": (base + timedelta(seconds=10)).isoformat(), "attempt": 1},
        {"client_msg_id": "a", "created_at": base.isoformat(), "attempt": 0},
        {"client_msg_id": "dead", "created_at": base.isoformat(), "attempt": M.RETRY_MAX_ATTEMPTS},
    ]
    snap = M.queue_snapshot(pending)
    assert [p["client_msg_id"] for p in snap] == ["a", "b"]  # dead dropped, oldest first


# ---- search (client-side) ----

def test_match_message_terms_and_phrase():
    assert M.match_message("Dinner at 7 with Mom", "dinner mom") is True
    assert M.match_message("Dinner at 7 with Mom", "dinner dad") is False
    assert M.match_message("Dinner at 7 with Mom", '"with mom"') is True
    assert M.match_message("Dinner at 7 with Mom", '"mom with"') is False
    assert M.match_message("", "anything") is False


def test_search_messages_scopes():
    msgs = [
        {"id": "1", "chat_id": 10, "text": "hello mom", "at": "2026-01-01T10:00:00+00:00"},
        {"id": "2", "chat_id": 11, "text": "hello dad", "at": "2026-01-02T10:00:00+00:00"},
        {"id": "3", "chat_id": 10, "text": "deleted", "at": "2026-01-03T10:00:00+00:00", "deleted": "everyone"},
    ]
    allc = M.search_messages(msgs, "hello")
    assert {m["id"] for m in allc} == {"1", "2"}
    inchat = M.search_messages(msgs, "hello", in_chat_id=10)
    assert {m["id"] for m in inchat} == {"1"}
    assert allc[0]["id"] == "2"  # newest first


def test_search_index_hints_no_content():
    hints = M.search_index_hints([{"chat_id": 1, "message_count": 5,
                                    "last_at": "x", "participant_ids": [1, 2]}])
    assert hints[0]["message_count"] == 5
    assert "text" not in hints[0] and "ciphertext" not in hints[0]


# ---- link preview (sender-side only) ----

def test_extract_url_and_policy():
    assert M.extract_first_url("see https://a.com/x now") == "https://a.com/x"
    assert M.extract_first_url("no links here") is None
    pol = M.link_preview_policy()
    assert pol["server_fetches_url"] is False
    assert pol["fetched_on"] == "sender_device"
    assert pol["preview_stored_as"] == "ciphertext"


# ---- typing (ephemeral) ----

def test_typing_event_not_persisted():
    ev = M.typing_event(10, 1, True)
    assert ev["persist"] is False and ev["typing"] is True


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_messaging: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
