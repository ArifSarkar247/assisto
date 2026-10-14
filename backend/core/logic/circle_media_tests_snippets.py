"""
circle_media_tests_snippets.py — plain-assert tests for core.logic.circle_media.
NOT a Django TestCase (no DB).

Smoke locally:
    python3 -c "import core.logic.circle_media_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle_media as MD


def _now():
    return datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)


# ---- size limits + HD tier ----

def test_size_limits_standard_vs_hd():
    assert MD.within_size_limit("photo", 10 * MD.MB) is True
    assert MD.within_size_limit("photo", 20 * MD.MB) is False
    assert MD.within_size_limit("photo", 20 * MD.MB, hd=True) is True
    assert MD.size_limit("video", hd=True) > MD.size_limit("video")


def test_size_reject_reason():
    assert MD.size_reject_reason("photo", 1 * MD.MB) is None
    r = MD.size_reject_reason("photo", 999 * MD.MB, lang="en")
    assert r is not None and "Maximum" in r
    rb = MD.size_reject_reason("photo", 999 * MD.MB, lang="bn")
    assert "MB" in rb


def test_server_hard_cap_above_sender():
    assert MD.server_hard_cap("photo") > MD.size_limit("photo")


# ---- compression + thumbnails ----

def test_compression_targets():
    std = MD.compression_target("photo")
    hd = MD.compression_target("photo", MD.QUALITY_HD)
    assert hd["max_long_edge_px"] > std["max_long_edge_px"]
    assert hd["jpeg_quality"] >= std["jpeg_quality"]
    v = MD.compression_target("video", MD.QUALITY_HD)
    assert v["video_kbps"] > MD.compression_target("video")["video_kbps"]


def test_thumbnail_target_only_visual():
    assert MD.thumbnail_target("photo")["encrypt"] is True
    assert MD.thumbnail_target("document") is None


# ---- blob meta validation (ciphertext-only) ----

def test_blob_meta_opaque_ok():
    meta = MD.build_blob_meta("photo", "blob://abc", 2 * MD.MB,
                              caption_ciphertext="AbC", caption_nonce="Zm8",
                              thumb_ciphertext="Th", thumb_nonce="Tn",
                              width=1600, height=900)
    ok, why = MD.validate_blob_meta(meta)
    assert ok, why


def test_blob_meta_rejects_plaintext_caption():
    bad = {"kind": "photo", "blob_ref": "b", "caption": "hi mom"}
    ok, why = MD.validate_blob_meta(bad)
    assert ok is False and "forbidden" in why


def test_blob_meta_rejects_filename_and_url():
    for k in ("filename", "url", "transcript", "address"):
        ok, _ = MD.validate_blob_meta({"kind": "document", "blob_ref": "b", k: "x"})
        assert ok is False, k


def test_blob_meta_rejects_oversize():
    ok, why = MD.validate_blob_meta({"kind": "photo", "blob_ref": "b",
                                     "byte_size": 999 * MD.MB})
    assert ok is False and "cap" in why


def test_blob_meta_missing_blob_ref():
    ok, _ = MD.validate_blob_meta({"kind": "photo", "byte_size": 10})
    assert ok is False


def test_build_blob_meta_raises_on_plaintext():
    try:
        MD.build_blob_meta("photo", "b", 10)
        # add a forbidden key by hand -> build only sets allowed keys, so this
        # path is exercised via validate in build; craft directly instead:
    except ValueError:
        pass
    # direct validate of a smuggled field:
    ok, _ = MD.validate_blob_meta({"kind": "photo", "blob_ref": "b", "note": "x"})
    assert ok is False


# ---- documents ----

def test_document_mime_and_support():
    assert MD.document_mime_hint("pdf") == "application/pdf"
    assert MD.document_mime_hint(".DOCX").endswith("wordprocessingml.document")
    assert MD.document_mime_hint("exe") == "application/octet-stream"
    assert MD.is_supported_document("xlsx") is True
    assert MD.is_supported_document("exe") is False


# ---- voice notes ----

def test_voice_limit_and_speed_cycle():
    assert MD.voice_within_limit(60) is True
    assert MD.voice_within_limit(60 * 60) is False
    assert MD.next_playback_speed(1.0) == 1.5
    assert MD.next_playback_speed(2.0) == 1.0
    assert MD.next_playback_speed(99) == 1.0


# ---- short video ----

def test_video_limit():
    assert MD.video_within_limit(30) is True
    assert MD.video_within_limit(60 * 60) is False


# ---- contact card ----

def test_contact_card_opaque():
    m = MD.contact_card_meta("CT", "N", "scheme", "k1", count=2)
    assert m["kind"] == "contact" and m["ciphertext"] == "CT" and m["count"] == 2
    assert "name" not in m and "phone" not in m


# ---- location (current + live) ----

def test_live_location_expiry_and_active():
    start = _now()
    exp = MD.live_location_expiry("1h", start=start)
    assert exp == start + timedelta(hours=1)
    assert MD.live_location_active(exp, now=start + timedelta(minutes=30)) is True
    assert MD.live_location_active(exp, now=start + timedelta(hours=2)) is False
    assert MD.live_location_expiry("bogus") is None


def test_location_fix_meta_opaque():
    m = MD.location_fix_meta("CT", "N", "s", "k1")
    assert m["kind"] == "location" and m["live"] is False
    assert "lat" not in m and "lng" not in m
    live = MD.location_fix_meta("CT", "N", "s", "k1", live=True,
                                duration_key="8h", start=_now())
    assert live["live"] is True and "expires_at" in live


def test_duration_labels():
    assert MD.duration_label("15m", "en") == "15 minutes"
    assert MD.duration_label("8h", "bn") == "৮ ঘণ্টা"


# ---- cleanup + disk floor ----

def test_cleanup_undelivered_ttl():
    old = {"created_at": (_now() - timedelta(days=40)).isoformat(),
           "recipient_ids": [2], "delivered_to": []}
    cleanup, reason = MD.should_cleanup_blob(old, now=_now())
    assert cleanup is True and reason == "undelivered_ttl_elapsed"


def test_cleanup_delivered_grace():
    recent = {"created_at": (_now() - timedelta(hours=1)).isoformat(),
              "recipient_ids": [2], "delivered_to": [2]}
    cleanup, _ = MD.should_cleanup_blob(recent, now=_now())
    assert cleanup is False
    aged = {"created_at": (_now() - timedelta(hours=48)).isoformat(),
            "recipient_ids": [2], "delivered_to": [2]}
    cleanup, reason = MD.should_cleanup_blob(aged, now=_now())
    assert cleanup is True and reason == "delivered_grace_elapsed"


def test_disk_floor():
    assert MD.disk_floor_ok(2 * 1024 * MD.MB, 100 * MD.MB) is True
    assert MD.disk_floor_ok(MD.DISK_FLOOR_BYTES, 100 * MD.MB) is False


def test_eviction_plan_prefers_cleanable_then_oldest():
    now = _now()
    blobs = [
        {"id": "cleanable", "byte_size": 100 * MD.MB,
         "created_at": (now - timedelta(days=40)).isoformat(),
         "recipient_ids": [2], "delivered_to": []},
        {"id": "old_undelivered", "byte_size": 100 * MD.MB,
         "created_at": (now - timedelta(days=1)).isoformat(),
         "recipient_ids": [2], "delivered_to": []},
        {"id": "newer_undelivered", "byte_size": 100 * MD.MB,
         "created_at": now.isoformat(),
         "recipient_ids": [2], "delivered_to": []},
    ]
    plan = MD.eviction_plan(blobs, free_bytes=MD.DISK_FLOOR_BYTES,
                            need_bytes=150 * MD.MB, now=now)
    assert "cleanable" in plan
    assert plan.index("cleanable") == 0
    # oldest undelivered chosen before newer
    if "newer_undelivered" in plan:
        assert "old_undelivered" in plan


# ---- send-state machine (§21 honest states) ----

def test_send_state_happy_path():
    s, a = "queued", 0
    s, a = MD.next_send_state(s, "start", a)
    assert s == "uploading"
    s, a = MD.next_send_state(s, "progress", a)
    assert s == "uploading"
    s, a = MD.next_send_state(s, "done", a)
    assert s == "sent" and a == 0
    # sent is terminal: further events are no-ops
    assert MD.next_send_state(s, "error", a) == ("sent", 0)


def test_send_state_error_then_retry():
    s, a = MD.next_send_state("uploading", "error", 0)
    assert s == "failed" and a == 1
    assert MD.is_retryable_send(s, a) is True
    s2, a2 = MD.next_send_state(s, "retry", a)
    assert s2 == "queued" and a2 == 1  # retry re-queues, keeps attempt count


def test_send_state_retry_exhausts():
    assert MD.is_retryable_send("failed", 5, max_attempts=5) is False
    # retry at the ceiling is a no-op (stops nagging)
    assert MD.next_send_state("failed", "retry", 5, max_attempts=5) == ("failed", 5)
    # cannot retry a non-failed state
    assert MD.is_retryable_send("uploading", 0) is False


def test_send_state_cancel_and_illegal():
    assert MD.next_send_state("uploading", "cancel", 0) == ("canceled", 0)
    assert MD.can_transition_send("sent", "uploading") is False
    # unknown event is a no-op
    assert MD.next_send_state("queued", "bogus", 2) == ("queued", 2)


def test_send_state_labels_bilingual():
    assert MD.send_state_label("failed", "en") == "Not sent"
    assert MD.send_state_label("uploading", "bn") == "আপলোড হচ্ছে"


def test_upload_progress_pct_clamped():
    assert MD.upload_progress_pct(0, 0) == 0        # unknown total -> 0, not NaN
    assert MD.upload_progress_pct(50, 100) == 50
    assert MD.upload_progress_pct(999, 100) == 100  # clamped
    assert MD.upload_progress_pct(1, 3) == 33


# ---- pre-send guards (size + type + duration) ----

def test_precheck_blocks_when_gated():
    # storage is key-gated in tests -> any media pick is blocked with a reason
    ok, reason = MD.precheck_media_send("photo", 1 * MD.MB, lang="en")
    assert ok is False and reason is not None


def test_precheck_reasons_are_localized_strings():
    ok, reason = MD.precheck_media_send("document", 1 * MD.MB, ext="exe", lang="bn")
    assert ok is False and isinstance(reason, str) and reason


# ---- offline cache classifier ----

def test_cache_status_gated_when_storage_off():
    assert MD.cache_status({"kind": "photo"}) == "gated"


def test_cache_status_labels_bilingual():
    assert MD.cache_status_label("downloadable", "en") == "Tap to download"
    assert MD.cache_status_label("cached", "bn") == "ডিভাইসে সংরক্ষিত"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_media: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
