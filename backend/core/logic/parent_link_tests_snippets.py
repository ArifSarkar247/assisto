"""
parent_link_tests_snippets.py — plain-assert tests for core.logic.parent_link.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.parent_link_tests_snippets as t; t.run_all()"
"""
from core.logic import parent_link as P
from core.logic import circle as C


SECRET = "test-secret-key"


# ---- phone validation ----

def test_normalize_phone_strips_formatting():
    assert P.normalize_phone("  017 11-223344 ") == "01711223344"
    assert P.normalize_phone("+880 1711 223344") == "+8801711223344"
    assert P.normalize_phone("") == ""
    assert P.normalize_phone(None) == ""


def test_validate_phone_rules():
    ok, err = P.validate_phone("01711223344")
    assert ok and err == P.OK
    ok, err = P.validate_phone("")
    assert not ok and err == P.ERR_NO_PHONE
    ok, err = P.validate_phone("123")
    assert not ok and err == P.ERR_BAD_PHONE


def test_validate_rejects_self_number():
    ok, err = P.validate_phone("01711223344", own_number="017-1122-3344")
    assert not ok and err == P.ERR_SELF


# ---- build_parent_link: channels, availability, honesty ----

def test_build_parent_link_bad_phone():
    r = P.build_parent_link(1, "Rahim", "12", secret=SECRET)
    assert r["ok"] is False and r["error"] == P.ERR_BAD_PHONE


def test_build_parent_link_happy_path():
    r = P.build_parent_link(1, "Rahim", "01711223344", relation_code="mother",
                            secret=SECRET, lang="en")
    assert r["ok"] is True
    assert r["phone"] == "01711223344"
    assert r["relation"] == "mother"
    assert r["reciprocal"] == "child"            # I add mother -> I am her child
    # token is a real signed, parseable invite token
    ok, data = C.parse_invite_token(r["token"], SECRET)
    assert ok and data["inviter_id"] == 1 and data["relation_code"] == "mother"
    assert r["invite_link"].endswith(r["token"])
    assert r["qr_payload"] == r["invite_link"]


def test_channels_present_and_ordered():
    r = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET)
    chans = {c["channel"]: c for c in r["channels"]}
    assert set(chans) == {P.CH_CALL, P.CH_SMS, P.CH_QR, P.CH_IVR}
    # call / sms / qr are always available (no dead taps, no gateway needed)
    assert chans[P.CH_CALL]["available"] is True
    assert chans[P.CH_SMS]["available"] is True
    assert chans[P.CH_QR]["available"] is True


def test_call_channel_is_tel_uri():
    r = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET)
    call = [c for c in r["channels"] if c["channel"] == P.CH_CALL][0]
    assert call["uri"] == "tel:01711223344"
    assert call["action"] == "dial"


def test_sms_channel_own_sim_no_gateway():
    r = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET)
    sms = [c for c in r["channels"] if c["channel"] == P.CH_SMS][0]
    assert sms["available"] is True
    assert sms["uri"].startswith("sms:01711223344?body=")
    assert sms["requires_send_sms_permission"] is False
    assert sms["uses_gateway"] is False
    assert sms["auto_sent"] is False


def test_qr_channel_carries_deep_link():
    r = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET)
    qr = [c for c in r["channels"] if c["channel"] == P.CH_QR][0]
    assert qr["qr"] == r["invite_link"]
    assert qr["action"] == "show_qr"


def test_ivr_channel_honest_gating():
    # locked by default -> not available, carries a bilingual reason, no dead tap
    locked = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET, lang="en")
    ivr = [c for c in locked["channels"] if c["channel"] == P.CH_IVR][0]
    assert ivr["available"] is False
    assert ivr["action"] == "locked"
    assert ivr["reason"] and "provider" in ivr["reason"].lower()
    # unlocked once the owner connects an IVR provider
    live = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET,
                               ivr_enabled=True)
    ivr2 = [c for c in live["channels"] if c["channel"] == P.CH_IVR][0]
    assert ivr2["available"] is True and ivr2["action"] == "ivr_call"
    assert ivr2["reason"] is None


def test_ivr_reason_bilingual():
    bn = P.ivr_gate_reason("bn")
    en = P.ivr_gate_reason("en")
    assert bn != en and "IVR" in bn.upper() or "ভয়েস" in bn
    assert "provider" in en.lower()


def test_invite_message_bilingual_and_has_link():
    bn = P.invite_message_text("রহিম", "https://x/i/tok", "bn")
    en = P.invite_message_text("Rahim", "https://x/i/tok", "en")
    assert "https://x/i/tok" in bn and "https://x/i/tok" in en
    assert bn != en
    assert "Assisto" in en


def test_token_window_short_and_parseable():
    r = P.build_parent_link(1, "Rahim", "01711223344", secret=SECRET,
                            ttl_minutes=60)
    ok, data = C.parse_invite_token(r["token"], SECRET)
    assert ok
    # wrong secret must fail (signed)
    bad_ok, _ = C.parse_invite_token(r["token"], "other-secret")
    assert bad_ok is False


# ---- onboarding role -> tailored first win ----

def test_role_normalize_and_label_bilingual():
    assert P.normalize_role("BUSINESS") == P.ROLE_BUSINESS
    assert P.normalize_role("nonsense") == P.ROLE_SELF
    assert P.role_label("parent", "en") == "Caring for an elderly parent"
    assert P.role_label("parent", "bn") != P.role_label("parent", "en")


def test_first_win_per_role():
    assert P.first_win_for_role("parent") == P.WIN_MEDICINE
    assert P.first_win_for_role("family") == P.WIN_MEDICINE
    assert P.first_win_for_role("business") == P.WIN_BILL
    assert P.first_win_for_role("self") == P.WIN_JOURNEY


def test_should_prompt_parent_link():
    assert P.should_prompt_parent_link("parent") is True
    assert P.should_prompt_parent_link("family") is True
    assert P.should_prompt_parent_link("self") is False
    assert P.should_prompt_parent_link("business") is False


def test_channel_labels_hints_bilingual():
    for chv in P.CHANNELS:
        assert P.channel_label(chv, "bn") != "" and P.channel_label(chv, "en") != ""
        assert P.channel_hint(chv, "bn") != "" and P.channel_hint(chv, "en") != ""
        assert P.channel_label(chv, "bn") != P.channel_label(chv, "en")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"parent_link: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
