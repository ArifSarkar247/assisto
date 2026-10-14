# #197 — Encrypted backup & phone transfer (SPEC v2.1 §21, ADVANCED)

Local encrypted backup + device-to-device transfer, built to advanced. Cloud
(Google Drive) is a documented, key-gated seam. Nothing fakes a cloud sync.

## New files
- `app/lib/screens/encrypted_backup_screen.dart` — the screen (3 tabs: Backup /
  Restore / Phone transfer). Zero Bangla literals (all strings via `t.bk*`).
- `backend/core/logic/backup_transfer.py` — PURE deterministic logic: manifest
  build/verify, SHA-256 checksum + integrity verify, chunk/dechunk, transfer-code
  make/validate, recovery-note assembly, Drive-OAuth seam. No DB, no network, no
  clock (created_at is passed in), **no crypto and no secrets**.
- `backend/core/logic/backup_transfer_tests_snippets.py` — 14 plain-assert tests.

## Changed files (one line each, nothing else touched)
- `backend/core/tests.py` — added:
  ```python
  BackupTransferSnippetTests = _make_snippet_case(
      "core.logic.backup_transfer_tests_snippets", "BackupTransferSnippetTests")
  ```
  (placed right after `SocialComposeSnippetTests`, same pattern as every other
  snippet case.)

NOT touched (per constraints): `api.dart` request helpers, `core/models.py`,
`core/urls.py`, sidebar source, `app_*.arb`, migrations, Flutter build config,
Asalify.

## Existing crypto reused (NO new/weak crypto invented)
All from `app/lib/crypto/e2e.dart` (the SoftwareE2E layer):
- `Pbkdf2.derive(passphrase, salt, 120000, 32)` — PBKDF2-HMAC-SHA256 key
  stretching, **same 120 000-iteration cost as `KeyBackup.seal`**.
- `ChaCha20Poly1305.encrypt / .decrypt` — RFC 8439 AEAD. `decrypt` returns
  `null` on auth failure, which is exactly how a wrong passphrase / tampered
  bundle is detected → honest error, never a silent partial restore.
- `Sha256.hash` — plaintext integrity checksum + transfer-code derivation.

The passphrase is never logged and never sent to the server. The manifest that
rides outside the ciphertext carries only format id/version, KDF params,
salt+nonce, cipher length, and a **checksum commitment of the plaintext** — no
key, no passphrase, no password hash.

## Existing export reused (NO new endpoint)
Backup pulls the existing export via `AppState.api.exportRaw()` →
`GET /export`. No new Django endpoint, no new API helper, no model change.

## Flow
### Backup (works now, no key)
1. `exportRaw()` → plaintext JSON.
2. random 16-byte salt + 12-byte nonce; `Pbkdf2.derive` → 32-byte key.
3. `ChaCha20Poly1305.encrypt(key, nonce, plaintext)` → ciphertext.
4. plaintext manifest (mirrors `build_manifest`): format/version/kdf/kdf_iters/
   aead/salt/nonce/cipher_len/plaintext_sha256/source/created_at/item_count.
5. bundle = `base64(JSON{manifest, ct})` — one opaque, shareable text blob.
6. transfer code = domain-tagged SHA-256 of the bundle → unambiguous alphabet
   (mirrors `make_transfer_code`). Save (`.asbk` in app documents dir) or share
   the file via the share sheet (`Share.shareXFiles`). Loud passphrase-loss
   warning shown on the tab.

### Restore (honest success/failure)
Paste bundle (or "Load last saved" reads newest `.asbk`) + passphrase →
re-derive key with the manifest's salt/iters → `ChaCha20Poly1305.decrypt`.
`null` ⇒ `bkErrWrongPass` (wrong passphrase or tamper). Then re-check
`Sha256` against `plaintext_sha256` ⇒ `bkErrIntegrity` on mismatch. Bad/
non-Assisto bundle ⇒ `bkErrBadBundle`. A truncated 2 KB preview is shown on
success. Nothing silent.

### Phone transfer (honest transport — no fake cloud sync)
Documented 4-step flow on the tab: create backup on old phone → move the
**encrypted file** by share/cable/Nearby Share → read the transfer code and
passphrase out-of-band (not in a message) → restore on the new phone. An
info box states plainly it is not magic cloud sync: the user moves the file,
the code only verifies both phones got the same bundle, the passphrase is the
only thing that opens it.

### Cloud backup (Google Drive) — key-gated seam
`backup_transfer.drive_seam()` returns `connected=False`,
`local_backup_available=True`, `note="key_gated"`, scope
`drive.appdata`. The UI card honestly offers "Connect Google Drive" and, when
tapped, says it isn't enabled yet while local encrypted backup works fully.
`connected` stays `False` even if a future config flips `configured` — no real
token layer exists, so no sync is faked. To enable later: wire Drive OAuth
(`google-oauth2`, `drive.appdata`) and upload the SAME encrypted bundle; the
manifest/chunk/checksum rules already hold.

## Collection / endpoint
None added. Reuses `GET /export`. No new Django route, model, or migration.
(The `.asbk` bundle is a local file; it is never uploaded anywhere by the
shipped code.)

## Tests
- `backend/core/logic/backup_transfer_tests_snippets.py` — **14** tests, all
  passing standalone (`python3 backup_transfer_tests_snippets.py` →
  `backup_transfer: 14 tests passed`). Covers checksum stability, integrity
  verify (tamper caught), manifest shape has no secrets + rejects weak KDF /
  bad format / chunk mismatch, chunk/dechunk roundtrip + missing/dupe/bad-index
  detection, deterministic transfer code (not the checksum, differs per bundle),
  tolerant-but-correct code validation, recovery-note assembly, honest key-gated
  Drive seam, and a full bookkeeping roundtrip.
- Registered in `core/tests.py` via `_make_snippet_case` (runs in CI alongside
  the other snippet cases).

## ARB keys — `.phaseB/up_backup_arb.json` (62 keys, bn + en, natural Bangla)
Parameterized keys (`_params` for the merge `PARAMS` map):
- `bkReadyMeta` → `["size"]`
- `bkReadyMetaItems` → `["count", "size"]`
- `bkSavedTo` → `["path"]`
- `bkRestoreOkItems` → `["count"]`
- `bkBytes` → `["n"]`
- `bkKib` → `["v"]`
- `bkMib` → `["v"]`

All other 55 keys are plain. en/bn parity verified; placeholder sets match
between bn and en for every key. `dart analyze` on the screen is clean except
for the 65 `bk*` undefined-getter errors that the ARB merge resolves (same as
every prior `up_*_arb.json`). **Zero Bangla literals in the `.dart` file**
(verified by a `\x{0980}-\x{09FF}` grep → NONE).

### Merge PARAMS snippet (for merge_arb.py)
```python
"bkReadyMeta": ["size"],
"bkReadyMetaItems": ["count", "size"],
"bkSavedTo": ["path"],
"bkRestoreOkItems": ["count"],
"bkBytes": ["n"],
"bkKib": ["v"],
"bkMib": ["v"],
```

## Wiring / sidebar entry (Settings)
The screen is self-contained. Suggested wiring (not applied here — settings
file edit is left to the integrator so this change stays to NEW files + the
single `tests.py` line):

- Import in `app/lib/screens/settings_screen.dart`:
  `import 'encrypted_backup_screen.dart';`
- Add a ListTile in the Settings "data / security" group near the existing
  `_export` tile:
  ```dart
  ListTile(
    leading: const Icon(Icons.enhanced_encryption_outlined),
    title: Text(t.bkTitle),
    onTap: () => Navigator.push(context,
        MaterialPageRoute(builder: (_) => const EncryptedBackupScreen())),
  ),
  ```
  It sits naturally beside the plaintext export: export = quick raw copy,
  encrypted backup = the safe, passphrase-protected copy + phone transfer.
