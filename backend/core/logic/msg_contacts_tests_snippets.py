"""
msg_contacts_tests_snippets.py — deterministic self-tests for msg_contacts.py.
Pure Python, no DB, no AI key.  Everything is passed in now.

Run:
    cd backend && python3 -c "import core.logic.msg_contacts_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.circle import REQ_ACCEPTED, REQ_PENDING
from core.logic.msg_contacts import (
    CHANNEL_IN_APP,
    CHANNEL_SHARE_LINK,
    CHANNEL_SMS_OWN_SIM,
    DAILY_REQUEST_LIMIT,
    ERR_DAILY_LIMIT,
    ERR_RELATION_REQUIRED,
    ERR_SELF_REQUEST,
    REQUEST_NOTE_MAX,
    act_on_connection_request,
    block_or_report_on_request,
    build_connection_request,
    can_send_before_accept,
    can_send_request,
    connection_request_actions,
    hash_contacts_clientside,
    hash_phone,
    hashing_contract,
    invite_existing_user,
    invite_non_user_share_link,
    invite_non_user_sms,
    is_connected,
    match_contacts,
    normalize_e164,
    pre_accept_message_count_ok,
    privacy_disclosure,
    requests_sent_last_24h,
)

SALT = "server-wide-match-salt-REVIEW"
NOW = datetime(2026, 10, 14, 12, 0, 0, tzinfo=timezone.utc)
_count = 0


def ok(cond, msg):
    global _count
    _count += 1
    if not cond:
        raise AssertionError("FAIL: " + msg)


# ---------------------------------------------------------------------------
# HASHED CONTACT MATCH — finds users, ignores + stores-nothing for non-users
# ---------------------------------------------------------------------------

def test_e164_normalization():
    ok(normalize_e164("01711112222") == "+8801711112222", "BD local -> E164")
    ok(normalize_e164("+8801711112222") == "+8801711112222", "already E164 kept")
    ok(normalize_e164("8801711112222") == "+8801711112222", "cc-prefixed kept")
    ok(normalize_e164("017-1111-2222") == "+8801711112222", "punctuation stripped")
    ok(normalize_e164("") == "", "blank -> blank")
    ok(normalize_e164("abc") == "", "no digits -> blank")


def test_hash_is_deterministic_and_matches_contract():
    e = normalize_e164("01711112222")
    h1 = hash_phone(e, SALT)
    h2 = hash_phone(e, SALT)
    ok(h1 == h2, "hash deterministic")
    ok(len(h1) == hashing_contract()["hex_length"], "hash length == contract")
    ok(hash_phone(e, "other-salt") != h1, "different salt => different hash")
    # client reference agrees with per-number hashing
    client = hash_contacts_clientside(["01711112222", "017-1111-2222"], SALT)
    ok(client == [h1], "client-side hashing dedupes normalized duplicates")


def test_match_finds_users():
    alice = normalize_e164("01711110001")
    bob = normalize_e164("01711110002")
    carol_nonuser = normalize_e164("01711119999")  # NOT registered
    reg = {
        hash_phone(alice, SALT): {"user_id": 1, "name": "Alice"},
        hash_phone(bob, SALT): {"user_id": 2, "name": "Bob"},
    }
    uploaded = hash_contacts_clientside(
        ["01711110001", "01711110002", "01711119999"], SALT)
    res = match_contacts(uploaded, reg, permission_granted=True)
    ok(res["ok"], "match ok with permission")
    ok(res["matched_count"] == 2, "found the 2 registered users")
    ok(res["checked"] == 3, "checked all 3 uploaded hashes")
    matched_users = {m["user"]["user_id"] for m in res["matches"]}
    ok(matched_users == {1, 2}, "matched exactly Alice + Bob")


def test_match_ignores_nonusers_and_stores_nothing():
    carol = normalize_e164("01711119999")
    dave = normalize_e164("01711118888")
    reg = {}  # nobody registered
    uploaded = hash_contacts_clientside(["01711119999", "01711118888"], SALT)
    res = match_contacts(uploaded, reg, permission_granted=True)
    ok(res["matched_count"] == 0, "no non-user matched")
    ok(res["matches"] == [], "non-users absent from matches (never recorded)")
    ok(res["stored"] is False, "matcher persists NOTHING (stored flag False)")
    # the function returns no structure retaining the non-user hashes
    all_hashes_in_result = {m["contact_hash"] for m in res["matches"]}
    ok(hash_phone(carol, SALT) not in all_hashes_in_result, "carol hash not kept")
    ok(hash_phone(dave, SALT) not in all_hashes_in_result, "dave hash not kept")


def test_match_requires_permission():
    res = match_contacts(["anything"], {"x": {"u": 1}}, permission_granted=False)
    ok(not res["ok"], "refused without permission")
    ok(res["reason"] == "permission_required", "permission_required reason")
    ok(res["matches"] == [] and res["checked"] == 0, "looked at nothing")
    ok(res["stored"] is False, "stored nothing when refused")


# ---------------------------------------------------------------------------
# INVITE descriptors — one per channel
# ---------------------------------------------------------------------------

def test_invite_existing_user_in_app():
    d_push = invite_existing_user("Rahim", 42, "friend",
                                  fcm_available=True, lang="en")
    ok(d_push["channel"] == CHANNEL_IN_APP, "existing-user => in_app channel")
    ok(d_push["delivery"] == "fcm_push", "push delivery when key present")
    ok(d_push["auto_sent"] is False, "never auto-sent")
    d_nokey = invite_existing_user("Rahim", 42, "friend",
                                   fcm_available=False, lang="en")
    ok(d_nokey["delivery"] == "on_next_open", "shown on next open w/o key")


def test_invite_non_user_share_link():
    d = invite_non_user_share_link("Rahim", "https://assisto.asalify.com/i/TOKEN",
                                   lang="en")
    ok(d["channel"] == CHANNEL_SHARE_LINK, "share_link channel")
    ok("https://assisto.asalify.com/i/TOKEN" in d["share_text"], "link in share text")
    ok(d["opens"] == "os_share_sheet", "opens OS share sheet")
    ok(d["auto_sent"] is False, "share never auto-sent")


def test_invite_non_user_sms_own_sim():
    d = invite_non_user_sms("Rahim", "https://assisto.asalify.com/i/TOKEN",
                            "01711112222", lang="en")
    ok(d["channel"] == CHANNEL_SMS_OWN_SIM, "sms_own_sim channel")
    ok(d["sms_uri"].startswith("sms:01711112222?body="), "prefilled sms: URI")
    ok(d["requires_send_sms_permission"] is False, "no SEND_SMS permission")
    ok(d["uses_gateway"] is False, "no gateway")
    ok(d["opens"] == "device_sms_composer", "opens composer, user sends")
    ok(d["auto_sent"] is False, "sms never auto-sent")
    ok("%20" in d["sms_uri"] or "%3A" in d["sms_uri"], "body is URI-encoded")


# ---------------------------------------------------------------------------
# PERSONAL CONNECTION REQUEST — relationship mandatory, daily limit, one note
# ---------------------------------------------------------------------------

def test_relationship_mandatory():
    ok(can_send_request(1, 2, "")[1] == ERR_RELATION_REQUIRED, "blank relation refused")
    ok(can_send_request(1, 2, "   ")[1] == ERR_RELATION_REQUIRED, "whitespace refused")
    ok(can_send_request(1, 2, "friend")[0], "valid relation allowed")


def test_no_self_request():
    ok(can_send_request(7, 7, "friend")[1] == ERR_SELF_REQUEST, "self-request refused")


def test_daily_limit_blocks_n_plus_1():
    # Build a sent_log with exactly DAILY_REQUEST_LIMIT requests in the window.
    log = [{"created_at": (NOW - timedelta(minutes=i + 1)).isoformat()}
           for i in range(DAILY_REQUEST_LIMIT)]
    ok(requests_sent_last_24h(log, now=NOW) == DAILY_REQUEST_LIMIT,
       "counts all in-window sends")
    okN, codeN = can_send_request(1, 2, "friend", sent_log=log, now=NOW)
    ok(not okN and codeN == ERR_DAILY_LIMIT, "the N+1 request is blocked")
    # one of them aging past 24h frees a slot
    log_old = [{"created_at": (NOW - timedelta(hours=25)).isoformat()}] + log[1:]
    ok(can_send_request(1, 2, "friend", sent_log=log_old, now=NOW)[0],
       "a slot freed when one ages out of the 24h window")
    # under the limit is fine
    ok(can_send_request(1, 2, "friend", sent_log=log[:-1], now=NOW)[0],
       "under the limit allowed")


def test_build_request_shape_and_one_note():
    long_note = "x" * (REQUEST_NOTE_MAX + 50)
    res = build_connection_request(1, 2, "cousin", note=long_note, now=NOW,
                                   custom_label="Cousin")
    ok(res["ok"], "request built")
    r = res["request"]
    ok(r["state"] == REQ_PENDING, "pending state")
    ok(r["relation"] == "custom", "'cousin' -> custom (unknown code)")
    ok(len(r["note"]) == REQUEST_NOTE_MAX, "note capped to ONE note max length")
    ok(r["note_used"] is True, "note budget marked used")
    ok("reciprocal_relation" in r, "reciprocal computed (reuses circle)")
    # refusal path returns no row
    bad = build_connection_request(1, 2, "", now=NOW)
    ok(not bad["ok"] and bad["request"] is None, "refused build persists nothing")


def test_pre_accept_allows_exactly_one_note_zero_further_messages():
    # 1) the single note is allowed when budget unused
    okn, why = can_send_before_accept(REQ_PENDING, note_already_used=False,
                                      is_note=True, is_call=False)
    ok(okn and why == "one_note", "the ONE pre-accept note is allowed")
    # 2) a SECOND note (budget used) is blocked
    ok(not can_send_before_accept(REQ_PENDING, True, is_note=True, is_call=False)[0],
       "second note blocked (budget exhausted)")
    # 3) any non-note message before accept is blocked
    okm, whym = can_send_before_accept(REQ_PENDING, False, is_note=False, is_call=False)
    ok(not okm and whym == "no_messages_before_accept", "no further messages pre-accept")
    # 4) calls are NEVER allowed before accept
    okc, whyc = can_send_before_accept(REQ_PENDING, False, is_note=False, is_call=True)
    ok(not okc and whyc == "no_calls_before_accept", "no calls pre-accept")
    # 5) after accept the gate steps aside
    ok(can_send_before_accept(REQ_ACCEPTED, True, is_note=False, is_call=True)[0],
       "post-accept the normal gates take over")
    # 6) invariant: at most one requester message exists before accept
    ok(pre_accept_message_count_ok([{"note": "hi"}]), "one note ok")
    ok(pre_accept_message_count_ok([]), "zero messages ok")
    ok(not pre_accept_message_count_ok([{"a": 1}, {"b": 2}]), "two messages violate")


def test_reuses_circle_2b_fix_semantics():
    # sender(outgoing) can only cancel; cannot accept their own
    ok(connection_request_actions("outgoing") == ["cancel"], "outgoing => cancel only")
    ok(connection_request_actions("incoming") == ["accept", "decline"],
       "incoming => accept/decline")
    ok(not act_on_connection_request("outgoing", "accept")[0],
       "sender cannot accept own request (2b fix)")
    ok(act_on_connection_request("incoming", "accept")[0],
       "receiver may accept")
    ok(act_on_connection_request("outgoing", "block")[0], "block allowed either side")
    ok(is_connected(REQ_ACCEPTED) is True, "connected only once accepted")
    ok(is_connected(REQ_PENDING) is False, "pending is NOT a connection")


def test_block_report_on_request():
    d = block_or_report_on_request(1, 2, action="report_and_block",
                                   reason="harassment", lang="en")
    ok(d["action"] == "report_and_block", "action recorded")
    ok(d["report"]["reporter_id"] == 1 and d["report"]["target_id"] == 2,
       "report carries parties (reuses circle.report_payload)")
    ok(d["block"] is True, "block directive set")
    # a plain spam report doesn't auto-block
    d2 = block_or_report_on_request(1, 2, action="report", reason="spam", lang="en")
    ok(d2["block"] is False, "spam report does not auto-block")
    # harassment report auto-blocks even when action='report'
    d3 = block_or_report_on_request(1, 2, action="report", reason="harassment")
    ok(d3["block"] is True, "harassment report auto-blocks")


def test_privacy_disclosure_invariants():
    # bilingual, all four disclosure facts present
    for lang in ("bn", "en"):
        d = privacy_disclosure(lang)
        for k in ("why", "sent", "never_stored", "control"):
            ok(isinstance(d[k], str) and d[k], f"{lang} disclosure.{k} present")
    # the HARD invariants the UI asserts verbatim — must match the contract
    f = privacy_disclosure("en")["facts"]
    ok(f["uploads_raw_numbers"] is False, "disclosure: never uploads raw numbers")
    ok(f["uploads_names"] is False, "disclosure: never uploads names")
    ok(f["stores_non_users"] is False, "disclosure: never stores non-users")
    ok(f["permission_gated"] is True, "disclosure: permission-gated")
    ok(f["auto_sends_anything"] is False, "disclosure: never auto-sends")
    ok(f["uploads_only"] == ["salted_hashes", "permission_flag"],
       "disclosure: uploads only salted hashes + permission flag")
    # the disclosure's stated facts agree with the hashing contract
    hc = hashing_contract()
    ok(hc["non_user_retention"] == "none",
       "contract + disclosure agree: non-users retained nowhere")
    ok("raw_numbers" in hc["upload_never_contains"],
       "contract + disclosure agree: raw numbers never uploaded")


# ---------------------------------------------------------------------------

def run_all():
    global _count
    _count = 0
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
    print(f"msg_contacts: ALL {_count} assertions passed across {len(tests)} tests.")
    return _count


if __name__ == "__main__":
    run_all()
