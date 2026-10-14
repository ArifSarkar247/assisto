"""
backup_transfer_tests_snippets.py — plain-assert tests for the ENCRYPTED BACKUP
& PHONE TRANSFER pure logic (#197, §21). Pure stdlib. Run standalone
(`python backup_transfer_tests_snippets.py`) or via run_all(). Everything is
deterministic, so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness: core.logic.backup_transfer_tests_snippets
    from core.logic import backup_transfer as B
except ImportError:  # standalone
    import backup_transfer as B  # noqa: E402


# --------------------------------------------------------------- checksum

def test_checksum_stable_and_accepts_bytes_and_str():
    assert B.checksum("hello") == B.checksum(b"hello")
    # known sha256("") for a sanity anchor
    assert B.checksum("") == (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    assert len(B.checksum("x")) == 64


def test_verify_integrity_honest():
    c = B.checksum("payload")
    assert B.verify_integrity("payload", c) is True
    assert B.verify_integrity("payload", c.upper()) is True   # case-insensitive
    assert B.verify_integrity("payloadX", c) is False         # tamper caught
    assert B.verify_integrity("payload", "") is False
    assert B.verify_integrity("payload", None) is False


# --------------------------------------------------------------- manifest

def _good_manifest(**over):
    kw = dict(
        plaintext_checksum=B.checksum("the-export"),
        cipher_len=1000,
        created_at="2026-10-14T00:00:00Z",
        salt_b64="c2FsdHNhbHRzYWx0c2FsdA==",
        nonce_b64="bm9uY2Vub25jZQ==",
        item_count=42,
    )
    kw.update(over)
    return B.build_manifest(**kw)


def test_build_manifest_shape_has_no_secrets():
    m = _good_manifest()
    for k in ("format", "version", "kdf", "kdf_iters", "aead", "salt", "nonce",
              "cipher_len", "chunk_size", "chunks", "plaintext_sha256",
              "source", "created_at", "item_count"):
        assert k in m, k
    # NEVER carry secret material
    blob = repr(m).lower()
    assert "passphrase" not in blob and "password" not in blob
    assert "key" not in m and "plaintext" not in m  # only a *checksum* of it
    assert m["format"] == B.FORMAT_ID
    assert m["kdf_iters"] == B.KDF_ITERS


def test_build_manifest_rejects_bad_inputs():
    for bad in [dict(plaintext_checksum="short"),
                dict(cipher_len=-1),
                dict(salt_b64="")]:
        try:
            _good_manifest(**bad)
            assert False, "should have raised for %r" % bad
        except ValueError:
            pass


def test_verify_manifest_accepts_good_rejects_tampered():
    m = _good_manifest()
    assert B.verify_manifest(m) == []
    assert "bad_format" in B.verify_manifest({**m, "format": "nope"})
    assert "bad_version" in B.verify_manifest({**m, "version": 99})
    assert "weak_kdf" in B.verify_manifest({**m, "kdf_iters": 10})
    assert "bad_aead" in B.verify_manifest({**m, "aead": "rot13"})
    assert "chunk_mismatch" in B.verify_manifest({**m, "chunks": 999})
    assert "not_a_manifest" in B.verify_manifest("x")


# --------------------------------------------------------------- chunking

def test_chunk_count_math():
    assert B.chunk_count(0, 10) == 0
    assert B.chunk_count(10, 10) == 1
    assert B.chunk_count(11, 10) == 2
    assert B.chunk_count(25, 10) == 3


def test_chunk_roundtrip_preserves_bytes():
    text = "A" * 50 + "B" * 37
    pieces = B.chunk(text, 16)
    assert len(pieces) == B.chunk_count(len(text), 16)
    assert all(p["n"] == len(pieces) for p in pieces)
    assert B.dechunk(pieces) == text


def test_dechunk_detects_missing_and_dupe_and_bad():
    text = "x" * 100
    pieces = B.chunk(text, 16)
    # missing one
    try:
        B.dechunk(pieces[:-1])
        assert False
    except ValueError as e:
        assert "missing" in str(e)
    # duplicate index
    try:
        B.dechunk(pieces + [pieces[0]])
        assert False
    except ValueError as e:
        assert "duplicate" in str(e)
    # out-of-range index
    bad = [dict(p) for p in pieces]
    bad[0]["i"] = 999
    try:
        B.dechunk(bad)
        assert False
    except ValueError:
        pass
    # empty
    try:
        B.dechunk([])
        assert False
    except ValueError:
        pass


# --------------------------------------------------------- transfer code

def test_transfer_code_deterministic_and_shaped():
    code = B.make_transfer_code("the-bundle-text")
    assert code == B.make_transfer_code("the-bundle-text")  # deterministic
    groups = code.split("-")
    assert len(groups) == B.CODE_GROUPS
    assert all(len(g) == B.CODE_GROUP_LEN for g in groups)
    assert all(ch in B.CODE_ALPHABET for g in groups for ch in g)
    # not the raw checksum, and different bundles differ
    assert code != B.checksum("the-bundle-text")
    assert code != B.make_transfer_code("other-bundle")


def test_transfer_code_accepts_checksum_or_bundle():
    bundle = "some-bundle"
    c = B.checksum(bundle)
    assert B.make_transfer_code(bundle) == B.make_transfer_code(c)


def test_validate_transfer_code_tolerant_but_correct():
    bundle = "bundle-xyz"
    code = B.make_transfer_code(bundle)
    assert B.validate_transfer_code(bundle, code) is True
    # tolerate spaces / lowercase / stray dashes
    messy = "  " + code.lower().replace("-", " ") + " "
    assert B.validate_transfer_code(bundle, messy) is True
    # wrong code honestly rejected
    assert B.validate_transfer_code(bundle, "AAAA-BBBB-CCCC") is False
    assert B.validate_transfer_code(bundle, "") is False
    assert B.validate_transfer_code(bundle, None) is False


# ------------------------------------------------------------ recovery note

def test_recovery_note_assembles_values_no_secrets():
    m = _good_manifest()
    code = B.make_transfer_code("bundle")
    lines = B.recovery_note(m, code)
    joined = "\n".join(lines)
    assert code in joined
    assert "2026-10-14T00:00:00Z" in joined
    assert "42" in joined  # item_count surfaced
    # with localized strings the labels come from the UI, values stay the same
    strings = {"title": "T", "created": "C", "format": "F", "items": "I",
               "code": "K", "warn": "W"}
    lines2 = B.recovery_note(m, code, strings=strings)
    assert lines2[0] == "T"
    assert code in "\n".join(lines2)


# --------------------------------------------------------- drive OAuth seam

def test_drive_seam_is_honest_key_gated():
    s = B.drive_seam()
    assert s["provider"] == "google_drive"
    assert s["configured"] is False
    assert s["connected"] is False            # never faked
    assert s["local_backup_available"] is True
    assert s["note"] == "key_gated"
    # even if a future config flips `configured`, connected stays False until a
    # real token layer exists (no fake sync).
    assert B.drive_seam(configured=True)["connected"] is False


# --------------------------------------------- end-to-end bookkeeping shape

def test_full_backup_bookkeeping_roundtrip():
    # Simulate the client flow WITHOUT doing encryption here (that's Dart's job):
    export_plaintext = '{"export":"data","n":1}'
    pt_sum = B.checksum(export_plaintext)
    # pretend ciphertext is twice the length (opaque to us)
    cipher_len = len(export_plaintext) * 2
    m = B.build_manifest(
        plaintext_checksum=pt_sum, cipher_len=cipher_len,
        created_at="2026-10-14T12:00:00Z",
        salt_b64="c2FsdA==", nonce_b64="bm9uY2U=", item_count=1,
        chunk_size=8)
    assert B.verify_manifest(m) == []
    # the shipped bundle text (base64) would be chunked for transfer:
    fake_bundle_b64 = "Zm9vYmFyYmF6" * 10
    pieces = B.chunk(fake_bundle_b64, m["chunk_size"])
    assert B.dechunk(pieces) == fake_bundle_b64
    # transfer code binds sender/receiver to the same bundle
    code = B.make_transfer_code(fake_bundle_b64)
    assert B.validate_transfer_code(fake_bundle_b64, code) is True
    # after decrypt on the receiver, integrity is verified against the manifest
    assert B.verify_integrity(export_plaintext, m["plaintext_sha256"]) is True


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print("backup_transfer: %d tests passed" % len(fns))
    return len(fns)


if __name__ == "__main__":
    run_all()
