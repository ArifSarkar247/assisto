"""
circle_tests_snippets.py — plain-assert tests for core.logic.circle.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.circle_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle as C


# ---- relationship vocabulary ----

def test_relation_labels_bilingual():
    assert C.relation_label("father", "bn") == "আব্বা"
    assert C.relation_label("father", "en") == "Father"
    assert C.relation_label("friend", "en") == "Friend"


def test_relation_custom_uses_user_text():
    assert C.relation_label("custom", "en", "Cousin") == "Cousin"
    assert C.relation_label("custom", "bn", "") == "অন্যান্য"  # falls back


def test_normalize_relation_unknown_to_custom():
    assert C.normalize_relation("Father") == "father"
    assert C.normalize_relation("neighbour") == "custom"
    assert C.normalize_relation(None) == "custom"


def test_reciprocal():
    assert C.reciprocal_relation("father") == "child"
    assert C.reciprocal_relation("husband") == "wife"
    assert C.reciprocal_relation("wife") == "husband"
    assert C.reciprocal_relation("friend") == "friend"
    assert C.reciprocal_relation("brother") == "sibling"


def test_close_family():
    assert C.is_close_family("mother") is True
    assert C.is_close_family("colleague") is False


# ---- request state machine ----

def test_request_accept_decline_block():
    s, ch = C.apply_request_event(C.REQ_PENDING, "accept")
    assert s == C.REQ_ACCEPTED and ch is True
    s, ch = C.apply_request_event(C.REQ_PENDING, "decline")
    assert s == C.REQ_DECLINED and ch is True
    s, ch = C.apply_request_event(C.REQ_ACCEPTED, "block")
    assert s == C.REQ_BLOCKED and ch is True


def test_request_illegal_transition_noop():
    s, ch = C.apply_request_event(C.REQ_DECLINED, "accept")
    assert s == C.REQ_DECLINED and ch is False
    s, ch = C.apply_request_event(C.REQ_ACCEPTED, "accept")
    assert ch is False
    s, ch = C.apply_request_event("garbage", "nope")
    assert ch is False


def test_can_message_requires_mutual_accept():
    assert C.can_message(C.REQ_ACCEPTED, C.REQ_ACCEPTED) is True
    assert C.can_message(C.REQ_ACCEPTED, C.REQ_PENDING) is False
    assert C.can_message(C.REQ_ACCEPTED, C.REQ_ACCEPTED, blocked_either=True) is False
    assert C.can_message(C.REQ_ACCEPTED) is True  # single mutual row


# ---- consent gate ----

def test_contact_access_default_off():
    assert C.contact_access_allowed(False) is False
    assert C.contact_access_allowed(True) is True


def test_contact_access_expires():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    fresh = now - timedelta(days=10)
    stale = now - timedelta(days=400)
    assert C.contact_access_allowed(True, fresh, ttl_days=365, now=now) is True
    assert C.contact_access_allowed(True, stale, ttl_days=365, now=now) is False


# ---- sharing policy ----

def test_default_sharing_close_vs_other():
    close = C.default_sharing("mother")
    assert close["medicines"] is True and close["money"] is False
    other = C.default_sharing("colleague")
    assert other["medicines"] is False and other["profile"] is True


def test_can_see_and_normalize():
    pol = C.normalize_sharing({"medicines": True, "bogus": True})
    assert pol["medicines"] is True
    assert "bogus" not in pol
    assert C.can_see(pol, "medicines") is True
    assert C.can_see(pol, "money") is False
    assert C.can_see(pol, "unknown_scope") is False


# ---- ciphertext relay contract (THE privacy guarantee) ----

def test_validate_envelope_text_ok():
    env = {"content_type": "text", "ciphertext": "AbCd123+/=",
           "nonce": "Zm9v", "recipient_ids": [2]}
    ok, why = C.validate_envelope(env)
    assert ok is True, why


def test_validate_envelope_rejects_plaintext():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "plaintext": "hello mom"}
    ok, why = C.validate_envelope(env)
    assert ok is False and "plaintext" in why


def test_validate_envelope_rejects_secret_fields():
    for bad in ("private_key", "recovery_code", "password", "key"):
        env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
               "recipient_ids": [2], bad: "oops"}
        ok, _ = C.validate_envelope(env)
        assert ok is False, bad


def test_validate_media_needs_blob():
    env = {"content_type": "photo", "recipient_ids": [2]}
    assert C.validate_envelope(env)[0] is False
    env["blob_ref"] = "blob://abc"
    assert C.validate_envelope(env)[0] is True


def test_server_visible_fields_strips_unknown_and_secret():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "sender_id": 1,
           "sneaky": "leak", "private_key": "nope"}
    vis = C.server_visible_fields(env)
    assert "sneaky" not in vis
    assert "private_key" not in vis
    assert vis["ciphertext"] == "x" and vis["sender_id"] == 1


def test_ai_redaction_never_readable():
    env = {"content_type": "text", "ciphertext": "x"}
    r = C.ai_redaction(env)
    assert r["readable_by_server"] is False
    assert r["encrypted"] is True
    assert "ciphertext" not in r and "plaintext" not in r


# ---- the full build_text_envelope roundtrip (opaque relay) ----

def test_build_text_envelope_opaque():
    env = C.build_text_envelope(
        circle_id=7, sender_id=1, recipient_ids=[2, 3],
        ciphertext_b64="3q2+7w==", nonce_b64="AAECAwQF",
        sender_key_id="k1")
    assert env["scheme"] == C.FALLBACK_SCHEME
    assert C.validate_envelope(env)[0] is True
    assert C.looks_like_plaintext(env) is False
    # server projection carries no plaintext
    vis = C.server_visible_fields(env)
    assert set(vis["recipient_ids"]) == {2, 3}
    assert "plaintext" not in vis


def test_build_text_envelope_refuses_plaintext_looking():
    # If the app ever passed a space-containing "ciphertext" (i.e. plaintext),
    # the heuristic flags it.
    env = C.build_text_envelope(7, 1, [2], "not base64 text", "AAEC", "k1")
    assert C.looks_like_plaintext(env) is True


# ---- media gating ----

def test_media_gating():
    assert C.media_available("text") is True
    assert C.media_available("photo") is False
    assert C.media_gate_reason("text") is None
    assert C.media_gate_reason("photo", "en").startswith("Photos available")
    assert "কল" in C.media_gate_reason("call", "bn")


# ---- invite tokens ----

def test_invite_token_roundtrip():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    tok = C.make_invite_token(42, "father", secret="S3cr3t", ttl_minutes=60, now=now)
    ok, data = C.parse_invite_token(tok, secret="S3cr3t", now=now)
    assert ok is True, data
    assert data["inviter_id"] == 42
    assert data["relation_code"] == "father"
    assert data["reciprocal_for_invitee"] == "child"


def test_invite_token_bad_signature():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    tok = C.make_invite_token(42, "father", secret="S3cr3t", now=now)
    ok, why = C.parse_invite_token(tok, secret="WRONG", now=now)
    assert ok is False and why == "bad signature"


def test_invite_token_expired():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    tok = C.make_invite_token(42, "friend", secret="S", ttl_minutes=10, now=now)
    later = now + timedelta(minutes=20)
    ok, why = C.parse_invite_token(tok, secret="S", now=later)
    assert ok is False and why == "expired"


def test_invite_token_malformed():
    ok, why = C.parse_invite_token("garbage", secret="S")
    assert ok is False and why == "malformed token"


def test_qr_payload():
    tok = C.make_invite_token(1, "friend", secret="S")
    assert C.qr_payload(tok).startswith("https://assisto.asalify.com/i/")


# ---- delivery / read ----

def test_delivery_and_read_marks():
    assert C.mark_delivered([], 2) == [2]
    assert C.mark_delivered([2], 3) == [2, 3]
    assert C.mark_read([], 2) == [2]
    env = {"delivered_to": [2], "read_by": []}
    assert C.delivery_status(env, 2) == "delivered"
    env["read_by"] = [2]
    assert C.delivery_status(env, 2) == "read"
    assert C.delivery_status(env, 9) == "sent"


# ---- block / report ----

def test_report_payload_auto_block():
    r = C.report_payload(1, 2, "harassment", "bad", "en")
    assert r["auto_block"] is True
    assert r["reason"] == "harassment"
    r2 = C.report_payload(1, 2, "spam", "", "bn")
    assert r2["auto_block"] is False
    r3 = C.report_payload(1, 2, "weird", "", "en")
    assert r3["reason"] == "other"


# ---- notifications ----

def test_request_notification_bilingual():
    bn = C.request_notification("রহিম", "father", "bn")
    en = C.request_notification("Rahim", "father", "en")
    assert "আব্বা" in bn["body"]
    assert "Father" in en["body"]
    assert bn["kind"] == en["kind"] == "circle_request"


# ---- quick contact (medicine card hook) ----

def test_quick_contact_actions():
    acts = C.quick_contact_actions({"id": 5, "name": "Ma", "phone": "01711"}, "en")
    kinds = {a["action"] for a in acts}
    assert "message" in kinds and "dial" in kinds and "call" in kinds
    call = [a for a in acts if a["action"] == "call"][0]
    assert call["enabled"] is False  # key-gated
    assert call["reason"] is not None
    msg = [a for a in acts if a["action"] == "message"][0]
    assert msg["enabled"] is True


def test_quick_contact_no_phone_hides_dial():
    acts = C.quick_contact_actions({"id": 5, "name": "Ma", "phone": ""}, "bn")
    assert not any(a["action"] == "dial" for a in acts)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
