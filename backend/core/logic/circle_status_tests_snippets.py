"""
circle_status_tests_snippets.py — plain-assert tests for core.logic.circle_status.
NOT a Django TestCase (no DB).

Smoke locally:
    python3 -c "import core.logic.circle_status_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle_status as ST


def _now():
    return datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)


# ---- key-gating (text now, photo/video gated like M1 media) ----

def test_text_available_media_gated():
    assert ST.status_media_available(ST.STATUS_TEXT) is True
    # M1 media gate currently closed for photo/video.
    assert ST.status_media_available(ST.STATUS_PHOTO) is False
    assert ST.status_media_available(ST.STATUS_VIDEO) is False
    assert ST.status_gate_reason(ST.STATUS_TEXT) is None
    assert ST.status_gate_reason(ST.STATUS_PHOTO, "en").endswith("enabled.")
    assert "স্ট্যাটাস" in ST.status_gate_reason(ST.STATUS_VIDEO, "bn")


# ---- lifecycle / expiry (24h auto-expire) ----

def test_expiry_is_24h():
    created = _now()
    assert ST.expiry_for(created) == created + timedelta(hours=24)


def test_active_then_expired():
    s = {"created_at": _now().isoformat()}
    assert ST.is_active(s, now=_now() + timedelta(hours=1)) is True
    assert ST.is_expired(s, now=_now() + timedelta(hours=25)) is True
    assert ST.is_active(s, now=_now() + timedelta(hours=25)) is False


def test_seconds_remaining_and_label():
    s = {"created_at": _now().isoformat()}
    assert ST.seconds_remaining(s, now=_now()) == 24 * 3600
    assert ST.seconds_remaining(s, now=_now() + timedelta(hours=25)) == 0
    assert "left" in ST.remaining_label(s, now=_now() + timedelta(hours=1), lang="en")
    assert ST.remaining_label(s, now=_now() + timedelta(hours=25), lang="en") == "Expired"
    # minutes branch
    lbl = ST.remaining_label(s, now=_now() + timedelta(hours=23, minutes=30), lang="en")
    assert lbl.endswith("m left")


# ---- visibility resolver (everyone / family / chosen / except) ----

def _author():
    return {"id": 1, "blocked": [], "blocked_by": []}


def test_vis_everyone():
    vis = {"mode": ST.AUD_EVERYONE}
    assert ST.can_view_status(_author(), {"id": 2, "relation": "friend"}, vis) is True


def test_vis_family_only():
    vis = {"mode": ST.AUD_FAMILY}
    assert ST.can_view_status(_author(), {"id": 2, "relation": "mother"}, vis) is True
    assert ST.can_view_status(_author(), {"id": 3, "relation": "friend"}, vis) is False


def test_vis_chosen_allowlist():
    vis = {"mode": ST.AUD_CHOSEN, "allow_ids": [2, 4]}
    assert ST.can_view_status(_author(), {"id": 2}, vis) is True
    assert ST.can_view_status(_author(), {"id": 3}, vis) is False


def test_vis_except_excludelist():
    vis = {"mode": ST.AUD_EXCEPT, "except_ids": [3]}
    assert ST.can_view_status(_author(), {"id": 2}, vis) is True
    assert ST.can_view_status(_author(), {"id": 3}, vis) is False


def test_block_overrides_everyone():
    author = {"id": 1, "blocked": [2], "blocked_by": []}
    assert ST.can_view_status(author, {"id": 2, "relation": "friend"},
                              {"mode": ST.AUD_EVERYONE}) is False
    author2 = {"id": 1, "blocked": [], "blocked_by": [5]}
    assert ST.can_view_status(author2, {"id": 5}, {"mode": ST.AUD_EVERYONE}) is False


def test_mute_hides_author():
    viewer = {"id": 2, "muted_authors": [1]}
    assert ST.can_view_status(_author(), viewer, {"mode": ST.AUD_EVERYONE}) is False


def test_expired_visible_to_nobody():
    s = {"created_at": _now().isoformat()}
    assert ST.can_view_status(_author(), {"id": 2}, {"mode": ST.AUD_EVERYONE},
                              now=_now() + timedelta(hours=25), status=s) is False


def test_author_sees_own():
    assert ST.can_view_status(_author(), {"id": 1}, {"mode": ST.AUD_CHOSEN,
                              "allow_ids": []}) is True


def test_audience_ids_resolves_set():
    cands = [{"id": 2, "relation": "friend"},
             {"id": 3, "relation": "mother"},
             {"id": 4, "relation": "friend"}]
    ids = ST.audience_ids(_author(), cands, {"mode": ST.AUD_FAMILY})
    assert ids == [3]


def test_normalize_visibility_coerces():
    v = ST.normalize_visibility({"mode": "bogus", "allow_ids": ["2", 2, "x"]})
    assert v["mode"] == ST.AUD_EVERYONE
    assert v["allow_ids"] == [2]


# ---- viewer list (reciprocal read-receipts) ----

def test_record_view_once_and_count():
    views = ST.record_view([], 2, at=_now())
    views = ST.record_view(views, 2, at=_now() + timedelta(minutes=5))
    views = ST.record_view(views, 3, at=_now())
    assert ST.viewer_count(views) == 2


def test_anonymous_view_when_receipts_off():
    views = ST.record_view([], 2, at=_now(), viewer_read_receipts=False)
    assert ST.viewer_count(views) == 1
    assert ST.named_viewers(views) == []
    summary = ST.viewer_summary(views, "en")
    assert "Seen by 1" in summary and "receipts off" in summary


def test_viewer_summary_empty_and_named():
    assert "No views" in ST.viewer_summary([], "en")
    views = ST.record_view([], 2, at=_now())
    assert ST.viewer_summary(views, "en") == "Seen by 1."


def test_receipt_cannot_tighten_anonymity():
    # First view receipts OFF (anonymous), later view ON -> stays anonymous.
    views = ST.record_view([], 2, at=_now(), viewer_read_receipts=False)
    views = ST.record_view(views, 2, at=_now(), viewer_read_receipts=True)
    assert ST.named_viewers(views) == []


# ---- reply privately -> 1:1 E2E envelope ----

def test_build_reply_envelope_is_relay_safe():
    env = ST.build_status_reply_envelope(
        "st_1", ST.STATUS_PHOTO, sender_id=2, author_id=1,
        ciphertext="AbC", nonce="Zm8", scheme="sw", sender_key_id="k2")
    assert env["content_type"] == "text"
    assert env["recipient_ids"] == [1]
    assert env["reply_to_status"]["status_id"] == "st_1"
    assert env["reply_to_status"]["kind"] == "photo"
    # no forbidden/readable keys
    assert not (ST.FORBIDDEN_META_KEYS & set(env.keys()))
    # validate through circle.validate_envelope -> must pass
    from core.logic import circle as C
    ok, why = C.validate_envelope(env)
    assert ok, why


def test_reply_unknown_kind_normalizes():
    env = ST.build_status_reply_envelope("s", "bogus", 2, 1, "c", "n", "s", "k")
    assert env["reply_to_status"]["kind"] == ST.STATUS_TEXT


# ---- mute ----

def test_mute_toggle():
    s = ST.apply_status_mute([], 9)
    assert ST.is_status_muted(s, 9) is True
    s = ST.apply_status_mute(s, 9, on=False)
    assert ST.is_status_muted(s, 9) is False


# ---- content envelope (ciphertext-only) ----

def test_build_text_status_meta_ok():
    meta = ST.build_status_meta(ST.STATUS_TEXT, created_at=_now(),
                                ciphertext="AbC", nonce="Zm8", scheme="sw",
                                sender_key_id="k1",
                                visibility={"mode": ST.AUD_FAMILY})
    ok, why = ST.validate_status_meta(meta)
    assert ok, why
    assert meta["kind"] == "text"
    assert meta["expires_at"] == (_now() + timedelta(hours=24)).isoformat()
    assert meta["visibility"]["mode"] == ST.AUD_FAMILY


def test_text_status_requires_ciphertext():
    ok, why = ST.validate_status_meta({"kind": "text"})
    assert ok is False and "ciphertext" in why


def test_status_meta_rejects_plaintext():
    for k in ("text", "caption", "filename", "note", "url"):
        ok, why = ST.validate_status_meta(
            {"kind": "text", "ciphertext": "c", "nonce": "n", k: "leak"})
        assert ok is False, k


def test_status_meta_rejects_unknown_key():
    ok, why = ST.validate_status_meta(
        {"kind": "text", "ciphertext": "c", "nonce": "n", "lat": 1})
    assert ok is False and "disallowed" in why


def test_media_status_gated_at_validate():
    # photo status cannot validate while media is key-gated.
    ok, why = ST.validate_status_meta({"kind": "photo", "blob_ref": "b"})
    assert ok is False and "gated" in why


def test_build_media_status_raises_while_gated():
    try:
        ST.build_status_meta(ST.STATUS_PHOTO, blob_ref="b", byte_size=10)
        assert False, "should have raised while media gated"
    except ValueError:
        pass


# ---- cleanup / disk floor ----

def test_cleanup_only_expired():
    live = {"id": "a", "created_at": _now().isoformat()}
    dead = {"id": "b", "created_at": (_now() - timedelta(hours=25)).isoformat()}
    assert ST.should_cleanup_status(live, now=_now())[0] is False
    assert ST.should_cleanup_status(dead, now=_now())[0] is True
    plan = ST.cleanup_plan([live, dead], now=_now())
    assert plan == ["b"]


def test_blob_refs_to_free():
    dead_media = {"id": "b", "blob_ref": "blob://x",
                  "created_at": (_now() - timedelta(hours=25)).isoformat()}
    live_media = {"id": "a", "blob_ref": "blob://y",
                  "created_at": _now().isoformat()}
    refs = ST.blob_refs_to_free([dead_media, live_media], now=_now())
    assert refs == ["blob://x"]


def test_disk_floor():
    assert ST.disk_floor_ok(2 * 1024 * ST.MB, 100 * ST.MB) is True
    assert ST.disk_floor_ok(ST.STATUS_DISK_FLOOR_BYTES, 100 * ST.MB) is False


# ---- tray grouping ----

def test_group_by_author_unseen_first():
    now = _now()
    statuses = [
        {"id": "s1", "author_id": 2, "created_at": (now - timedelta(hours=1)).isoformat(),
         "views": [{"viewer": 99}]},                       # seen by me (99)
        {"id": "s2", "author_id": 3, "created_at": now.isoformat(), "views": []},  # unseen
        {"id": "s3", "author_id": 3, "created_at": (now - timedelta(hours=2)).isoformat(),
         "views": []},
        {"id": "s4", "author_id": 4, "created_at": (now - timedelta(hours=30)).isoformat(),
         "views": []},                                     # expired -> dropped
    ]
    entries = ST.group_by_author(statuses, me_id=99, now=now)
    ids = [e["author_id"] for e in entries]
    assert 4 not in ids                       # expired dropped
    assert ids[0] == 3                         # unseen author first
    a3 = next(e for e in entries if e["author_id"] == 3)
    assert a3["count"] == 2 and a3["has_unseen"] is True
    a2 = next(e for e in entries if e["author_id"] == 2)
    assert a2["has_unseen"] is False


# ---- labels ----

def test_labels_bilingual():
    assert ST.audience_label(ST.AUD_FAMILY, "en") == "Family only"
    assert ST.audience_label(ST.AUD_CHOSEN, "bn") == "নির্বাচিত ব্যক্তিরা"
    assert ST.kind_label(ST.STATUS_VIDEO, "en") == "Video"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_status: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
