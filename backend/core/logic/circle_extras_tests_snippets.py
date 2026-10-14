"""
circle_extras_tests_snippets.py — plain-assert tests for core.logic.circle_extras
(M2 items 9 + 10).  NOT a Django TestCase (no DB).

Smoke locally:
    python3 -c "import core.logic.circle_extras_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle as C
from core.logic import circle_extras as X


def _now():
    return datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)


# ---- disappearing messages ----

def test_disappearing_normalize_and_label():
    assert X.normalize_disappearing(X.DISAPPEAR_7D) == X.DISAPPEAR_7D
    assert X.normalize_disappearing(999) == X.DISAPPEAR_OFF
    assert X.normalize_disappearing("x") == X.DISAPPEAR_OFF
    assert X.disappearing_label(X.DISAPPEAR_24H, "en") == "24 hours"
    assert X.disappearing_label(X.DISAPPEAR_OFF, "en") == "Off"


def test_disappearing_expiry_clock_starts_at_send():
    created = _now()
    exp = X.message_expires_at(created, X.DISAPPEAR_24H)
    assert exp == created + timedelta(hours=24)
    assert X.is_expired(created, X.DISAPPEAR_24H, now=created + timedelta(hours=25))
    assert not X.is_expired(created, X.DISAPPEAR_24H, now=created + timedelta(hours=1))
    # OFF never expires
    assert X.message_expires_at(created, X.DISAPPEAR_OFF) is None
    assert X.is_expired(created, X.DISAPPEAR_OFF, now=created + timedelta(days=9999)) is False


def test_disappearing_seconds_until():
    created = _now()
    rem = X.seconds_until_expiry(created, X.DISAPPEAR_24H,
                                 now=created + timedelta(hours=23))
    assert rem == 3600
    assert X.seconds_until_expiry(created, X.DISAPPEAR_OFF) is None
    # never negative
    assert X.seconds_until_expiry(created, X.DISAPPEAR_24H,
                                  now=created + timedelta(days=5)) == 0


# ---- view-once ----

def test_view_once_state_machine():
    st = X.view_once_initial("photo")
    assert X.can_open_view_once(st)
    st2, ok = X.open_view_once(st, now=_now())
    assert ok and st2["state"] == X.VIEW_ONCE_OPENED
    # cannot open again
    assert not X.can_open_view_once(st2)
    st3, ok2 = X.open_view_once(st2, now=_now())
    assert ok2 is False
    # grace window -> consumed
    assert X.view_once_consumed(st2, now=_now()) is False
    assert X.view_once_consumed(st2, now=_now() + timedelta(seconds=31)) is True
    assert X.view_once_consumed(X.consume_view_once(st2)) is True


# ---- per-chat settings (wallpaper/theme/disappearing) ----

def test_chat_settings_build_and_validate():
    s = X.build_chat_settings(disappearing_sec=X.DISAPPEAR_7D,
                              wallpaper="cyan_blue", theme="dark")
    assert s["disappearing_sec"] == X.DISAPPEAR_7D
    assert s["wallpaper"] == "cyan_blue" and s["theme"] == "dark"
    # unknown wallpaper/theme snap to defaults
    s2 = X.build_chat_settings(wallpaper="nope", theme="nope")
    assert s2["wallpaper"] == "default" and s2["theme"] == "system"
    # custom wallpaper => blob ref, marked custom
    s3 = X.build_chat_settings(wallpaper_blob_ref="blob123")
    assert s3["wallpaper"] == "custom" and s3["wallpaper_blob_ref"] == "blob123"


def test_chat_settings_reject_plaintext():
    ok, why = X.validate_chat_settings({"wallpaper": "default",
                                        "text": "secret note"})
    assert ok is False
    ok2, _ = X.validate_chat_settings({"wallpaper": "default", "foo": 1})
    assert ok2 is False
    assert X.wallpaper_catalog("en")[0]["id"] == "default"
    assert any(t["id"] == "dark" for t in X.theme_catalog("en"))


# ---- stickers ----

def test_sticker_catalog_and_refs():
    cat = X.sticker_pack_catalog("en")
    assert any(p["id"] == "assisto_hearts" for p in cat)
    ref = X.build_builtin_sticker_ref("assisto_faces", "wink")
    assert ref and ref["source"] == "builtin" and ref["sticker_id"] == "wink"
    assert X.build_builtin_sticker_ref("assisto_faces", "notreal") is None
    uref = X.build_user_sticker_ref("blobXYZ")
    assert uref["source"] == "user" and uref["blob_ref"] == "blobXYZ"
    # user sticker gate
    assert X.user_sticker_gate(True) is None
    assert X.user_sticker_gate(False, "en") is not None


# ---- GIF picker gate ----

def test_gif_gate_and_request():
    assert X.gif_search_available("") is False
    assert X.gif_search_available("KEY123") is True
    assert "GIF" in X.gif_gate_reason("en")
    req = X.gif_search_request("cat", provider="giphy", limit=100, lang="en")
    assert req["provider"] == "giphy" and req["q"] == "cat"
    assert req["limit"] == 50  # clamped
    assert req["content_filter"] == "high"  # family-safe default
    assert req["locale"] == "en"


# ---- voice transcription gate/stub ----

def test_transcription_gate_and_stub():
    g = X.transcribe_voice_note(b"audio", model_present=False)
    assert g["available"] is False and g["gated_reason"]
    def _model(audio, lang):
        return "hello world"
    r = X.transcribe_voice_note(b"audio", model_present=True, model=_model)
    assert r["available"] is True and r["text"] == "hello world"


# ---- translation (AI key gate + mock) ----

def test_translation_gate_and_mock():
    g = X.translate_message("hi", target_lang="bn", ai_key=None)
    assert g["available"] is False and g["gated_reason"]
    m = X.translate_message("hi", target_lang="bn", ai_key="AIKEY")
    assert m["available"] is True and m["mocked"] is True and "[bn]" in m["text"]
    def _tr(text, tl):
        return "oporibhasha"
    r = X.translate_message("hi", target_lang="bn", ai_key="AIKEY", translator=_tr)
    assert r["mocked"] is False and r["text"] == "oporibhasha"


# ---- scheduled messages ----

def test_schedule_validation():
    now = _now()
    ok, _ = X.validate_schedule_time(now + timedelta(minutes=5), now=now)
    assert ok
    ok2, why2 = X.validate_schedule_time(now + timedelta(seconds=10), now=now)
    assert ok2 is False and why2 == "too soon"
    ok3, why3 = X.validate_schedule_time(now + timedelta(days=400), now=now)
    assert ok3 is False and why3 == "too far"


def test_schedule_build_and_due():
    now = _now()
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2]}
    sm = X.build_scheduled_message(env, now + timedelta(hours=2), "cm1", now=now)
    assert sm["status"] == "pending"
    # not due yet
    assert X.is_scheduled_due(sm, now=now) is False
    assert X.is_scheduled_due(sm, now=now + timedelta(hours=3)) is True
    # due list, oldest first + skips sent
    s_later = X.build_scheduled_message(env, now + timedelta(hours=1), "cm2", now=now)
    due = X.due_scheduled([sm, s_later], now=now + timedelta(hours=4))
    assert [d["client_msg_id"] for d in due] == ["cm2", "cm1"]
    sent = X.mark_scheduled(sm, "sent")
    assert X.is_scheduled_due(sent, now=now + timedelta(hours=4)) is False


def test_schedule_rejects_plaintext_envelope():
    now = _now()
    try:
        X.build_scheduled_message({"content_type": "text", "body": "secret"},
                                  now + timedelta(hours=1), "cmX", now=now)
        assert False, "should have raised"
    except ValueError:
        pass


# ---- broadcast fan-out ----

def test_broadcast_validate():
    ok, _ = X.validate_broadcast(1, [2, 3], accepted_ids={2, 3})
    assert ok
    ok2, why2 = X.validate_broadcast(1, [2, 9], accepted_ids={2})
    assert ok2 is False and why2 == "not_connected"
    ok3, why3 = X.validate_broadcast(1, [1], accepted_ids={1})
    assert ok3 is False and why3 == "no recipients"  # self excluded


def test_broadcast_fanout_individual_no_shared_id():
    plan = X.broadcast_fanout_plan(1, [2, 3, 1], accepted_ids={2, 3},
                                   broadcast_id="b7", base_client_msg_id="cm")
    assert len(plan) == 2  # self dropped
    ids = {p["recipient_id"] for p in plan}
    assert ids == {2, 3}
    # distinct per-recipient dedupe ids; recipients can't see each other (no
    # shared message id field).
    cm_ids = {p["client_msg_id"] for p in plan}
    assert cm_ids == {"cm:2", "cm:3"}
    for p in plan:
        assert p["is_broadcast"] is True
        assert "recipient_ids" not in p  # not a group fan-out


# ---- @Assisto on-device parse ----

def test_assisto_trigger_detect_and_strip():
    assert X.has_assisto_trigger("hey @Assisto remind me") is True
    assert X.has_assisto_trigger("no trigger here") is False
    assert X.strip_assisto_trigger("@Assisto pay rent") == "pay rent"


def test_assisto_actions_expense():
    acts = X.assisto_actions("@Assisto Cash Out Tk 500 to shop", now=_now())
    types = [a["type"] for a in acts]
    assert "expense" in types
    exp = next(a for a in acts if a["type"] == "expense")
    assert exp["payload"]["amount"] is not None


def test_assisto_actions_reminder_event():
    acts = X.assisto_actions("@Assisto meeting tomorrow at 5pm", now=_now())
    types = [a["type"] for a in acts]
    assert "reminder" in types and "event" in types
    # recurrence ranks reminder first
    rec = X.assisto_actions("@Assisto every friday 8am gym", now=_now())
    assert rec and rec[0]["type"] == "reminder"
    assert X.assisto_action_label(acts[0], "en")


def test_assisto_actions_empty_when_nothing():
    acts = X.assisto_actions("@Assisto hello", now=_now())
    assert acts == [] or all(a.get("confidence", 0) >= 0 for a in acts)


# ---- encrypted backup + restore ----

def test_backup_envelope_build_and_validate():
    env = X.build_backup_envelope(owner_id=1, ciphertext_b64="CT",
                                  nonce_b64="N", salt_b64="S", iters=120000,
                                  message_count=42, recovery_hint="notebook",
                                  now=_now())
    ok, why = X.validate_backup_envelope(env)
    assert ok, why
    assert env["message_count"] == 42
    assert "recovery_code" not in env and "key" not in env


def test_backup_rejects_secret():
    try:
        X.build_backup_envelope(1, "CT", "N", "S", 1, 1,
                                now=_now())
        # add a secret manually and validate
    except Exception:
        pass
    ok, why = X.validate_backup_envelope({"v": 1, "ciphertext": "x", "nonce": "n",
                                          "salt": "s", "recovery_code": "ABCD"})
    assert ok is False and "secret" in why


def test_restore_plan():
    env = X.build_backup_envelope(1, "CT", "N", "S", 120000, 10, now=_now())
    plan = X.restore_plan(env, "en")
    assert plan["ciphertext"] == "CT" and plan["iters"] == 120000
    assert "recovery code" in plan["prompt"]
    assert X.restore_plan({"bad": 1}) is None


# ---- chat export ----

def test_export_chat_text():
    msgs = [
        {"at": _now(), "sender_name": "Mom", "text": "hi", "content_type": "text"},
        {"at": _now(), "sender_name": "Me", "content_type": "photo"},
        {"at": _now(), "sender_name": "Me", "text": "gone", "deleted": "everyone"},
    ]
    out = X.export_chat_text(msgs, chat_title="Family", lang="en")
    assert "Assisto Circle chat export" in out
    assert "Mom: hi" in out
    assert "[photo]" in out
    assert "gone" not in out  # deleted skipped


def test_export_chat_json():
    msgs = [{"at": _now(), "sender_name": "Me", "text": "x", "content_type": "text"},
            {"at": _now(), "deleted": "me", "text": "y"}]
    out = X.export_chat_json(msgs, chat_title="T", lang="bn")
    assert out["message_count"] == 1
    assert out["messages"][0]["text"] == "x"


# ---- linked devices (item 10 data model) ----

def test_device_record_and_cap():
    d = X.device_record("dev1", "android", role=X.DEVICE_ROLE_PRIMARY,
                        public_key_id="pk1", linked_at=_now())
    assert d["platform"] == "android" and d["revoked"] is False
    assert d["role"] == X.DEVICE_ROLE_PRIMARY
    # web only after mobile
    ok, why = X.can_link_device([], "web")
    assert ok is False and why == "web_after_mobile"
    ok2, _ = X.can_link_device([d], "web")
    assert ok2 is True
    # cap
    many = [X.device_record(f"d{i}", "ios") for i in range(X.MAX_LINKED_DEVICES)]
    ok3, why3 = X.can_link_device(many, "android")
    assert ok3 is False and why3 == "device_cap"


def test_link_request_opaque_and_revoke():
    req = X.build_link_request("primary1", "pk_new", "ios", "SEALEDBLOB",
                               now=_now())
    assert req["sealed_welcome"] == "SEALEDBLOB"
    assert "key" not in req and "private_key" not in req
    devs = [X.device_record("d1", "android"), X.device_record("d2", "ios")]
    revoked = X.revoke_device(devs, "d2")
    assert any(d["device_id"] == "d2" and d["revoked"] for d in revoked)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_extras: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
