import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// ENCRYPTED BACKUP & PHONE TRANSFER (#197, SPEC v2.1 §21, ADVANCED).
///
/// WHAT WORKS NOW, WITH NO KEY:
///  - BACKUP: pull the EXISTING export (AppState.api.exportRaw → GET /export),
///    encrypt it ON-DEVICE under a user passphrase using the app's OWN audited
///    primitives in crypto/e2e.dart — [Pbkdf2] (PBKDF2-HMAC-SHA256, 120k iters,
///    the same cost as [KeyBackup]) stretches the passphrase into a 32-byte key
///    and [ChaCha20Poly1305] AEAD seals it — then wrap it in a small base64
///    bundle with a PLAINTEXT manifest (format/version/salt/nonce/checksum, no
///    secrets) and let the user SAVE or SHARE the bundle file plus a recovery
///    note. A loud "keep your passphrase safe — without it the backup can't be
///    opened" warning is always shown. No AI, no key needed.
///  - RESTORE: paste a bundle (or load the last saved one), enter the
///    passphrase → decrypt → verify the plaintext checksum. WRONG PASSPHRASE or
///    a tampered bundle = an HONEST error (AEAD auth fails / checksum mismatch),
///    never a silent partial restore.
///  - PHONE TRANSFER: honest device-to-device handoff. The SAME encrypted
///    bundle is shared as a file by whatever channel the user already has
///    (share sheet / cable / Nearby Share / messaging app); a short TRANSFER
///    CODE (derived from the bundle checksum — NOT the key) is read out-of-band
///    so the receiving phone can confirm it imported the exact same bundle, and
///    the passphrase is spoken separately. No fake magic cloud sync.
///  - CLOUD BACKUP (Google Drive): a DOCUMENTED, KEY-GATED seam. Drive OAuth is
///    not configured, so the card honestly offers "connect Google Drive for
///    automatic cloud backup" and stays disabled; the LOCAL backup above needs
///    no key and is the shipped path.
///
/// The deterministic manifest / checksum / chunk / transfer-code RULES mirror
/// backend/core/logic/backup_transfer.py exactly so client and server agree.
class EncryptedBackupScreen extends StatefulWidget {
  const EncryptedBackupScreen({super.key});
  @override
  State<EncryptedBackupScreen> createState() => _EncryptedBackupScreenState();
}

// Format constants — MUST match backend/core/logic/backup_transfer.py.
const String _kFmt = 'assisto-backup';
const int _kFmtVersion = 1;
const String _kKdf = 'pbkdf2-hmac-sha256';
const String _kAead = 'chacha20-poly1305';
const int _kKdfIters = 120000; // same cost as KeyBackup.seal in crypto/e2e.dart
const String _kCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const int _kCodeGroups = 3;
const int _kCodeGroupLen = 4;

class _EncryptedBackupScreenState extends State<EncryptedBackupScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  AppLocalizations get t => AppLocalizations.of(context);

  // ---- backup state
  final _pass1 = TextEditingController();
  final _pass2 = TextEditingController();
  bool _show1 = false;
  bool _busy = false;
  String? _error;
  _Backup? _result; // the produced bundle (this session)

  // ---- restore state
  final _restoreInput = TextEditingController();
  final _restorePass = TextEditingController();
  bool _showRestorePass = false;
  bool _rBusy = false;
  String? _rError;
  String? _rSuccess; // decrypted preview (truncated)
  int? _rItems;

  @override
  void dispose() {
    _tabs.dispose();
    _pass1.dispose();
    _pass2.dispose();
    _restoreInput.dispose();
    _restorePass.dispose();
    super.dispose();
  }

  // =====================================================================
  // CRYPTO — reuses crypto/e2e.dart (Pbkdf2, ChaCha20Poly1305, Sha256).
  // The passphrase is NEVER logged and NEVER sent to the server.
  // =====================================================================

  String _sha256Hex(List<int> bytes) {
    final h = Sha256.hash(bytes);
    final sb = StringBuffer();
    for (final b in h) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = r.nextInt(256);
    }
    return out;
  }

  /// Deterministic transfer code from the bundle text — mirrors
  /// backup_transfer.make_transfer_code (domain-tagged SHA-256 → alphabet).
  String _transferCode(String bundleText) {
    final bundleSum = _sha256Hex(utf8.encode(bundleText));
    final tagged = Sha256.hash(utf8.encode('assisto-transfer-code:$bundleSum'));
    final chars = <String>[];
    for (var i = 0; i < _kCodeGroups * _kCodeGroupLen; i++) {
      chars.add(_kCodeAlphabet[tagged[i] % _kCodeAlphabet.length]);
    }
    final groups = <String>[];
    for (var g = 0; g < _kCodeGroups; g++) {
      groups.add(chars.sublist(g * _kCodeGroupLen, (g + 1) * _kCodeGroupLen).join());
    }
    return groups.join('-');
  }

  int? _countItems(String exportJson) {
    try {
      final decoded = jsonDecode(exportJson);
      if (decoded is Map) {
        var n = 0;
        decoded.forEach((_, v) {
          if (v is List) n += v.length;
        });
        return n;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _createBackup() async {
    FocusScope.of(context).unfocus();
    final app = context.read<AppState>();
    final p1 = _pass1.text;
    final p2 = _pass2.text;
    setState(() {
      _error = null;
      _result = null;
    });
    if (p1.length < 8) {
      setState(() => _error = t.bkErrPassShort);
      return;
    }
    if (p1 != p2) {
      setState(() => _error = t.bkErrPassMismatch);
      return;
    }
    setState(() => _busy = true);
    try {
      // 1) the EXISTING export (GET /export) — reused, no new endpoint.
      final raw = await app.api.exportRaw();
      final plainBytes = Uint8List.fromList(utf8.encode(raw));
      final plainSum = _sha256Hex(plainBytes);
      final items = _countItems(raw);

      // 2) stretch passphrase → key, seal with ChaCha20-Poly1305 (crypto/e2e).
      final salt = _randomBytes(16);
      final nonce = _randomBytes(12);
      final key = Pbkdf2.derive(utf8.encode(p1), salt, _kKdfIters, 32);
      final cipher = ChaCha20Poly1305.encrypt(key, nonce, plainBytes);

      // 3) manifest (plaintext header, NO secrets) — mirrors build_manifest().
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final manifest = <String, dynamic>{
        'format': _kFmt,
        'version': _kFmtVersion,
        'kdf': _kKdf,
        'kdf_iters': _kKdfIters,
        'aead': _kAead,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'cipher_len': cipher.length,
        'plaintext_sha256': plainSum,
        'source': 'assisto-export',
        'created_at': createdAt,
        if (items != null) 'item_count': items,
      };

      // 4) the bundle = base64(JSON{manifest, ct}). Opaque, shareable text.
      final bundleObj = <String, dynamic>{
        'manifest': manifest,
        'ct': base64Encode(cipher),
      };
      final bundleText = base64Encode(utf8.encode(jsonEncode(bundleObj)));
      final code = _transferCode(bundleText);

      if (!mounted) return;
      setState(() {
        _result = _Backup(
          bundleText: bundleText,
          code: code,
          createdAt: createdAt,
          items: items,
          bytes: cipher.length,
        );
        _busy = false;
      });
      // passphrase is done its job; clear the confirm field from memory view.
      _pass2.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.bkErrExport;
      });
    }
  }

  Future<File> _writeBundleFile(String bundleText) async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final f = File('${dir.path}/assisto-backup-$stamp.asbk');
    await f.writeAsString(bundleText);
    return f;
  }

  Future<void> _saveBundle() async {
    final r = _result;
    if (r == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await _writeBundleFile(r.bundleText);
      messenger.showSnackBar(SnackBar(content: Text(t.bkSavedTo(f.path))));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.bkErrSave)));
    }
  }

  Future<void> _shareBundle() async {
    final r = _result;
    if (r == null) return;
    try {
      final f = await _writeBundleFile(r.bundleText);
      // Share the ENCRYPTED file only. The code + passphrase go out-of-band.
      await Share.shareXFiles([XFile(f.path)], text: t.bkShareNote);
    } catch (_) {}
  }

  // =====================================================================
  // RESTORE
  // =====================================================================

  Future<void> _loadLastSaved() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.asbk'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (files.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(t.bkNoSavedBundle)));
        return;
      }
      final text = await files.first.readAsString();
      setState(() => _restoreInput.text = text);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.bkNoSavedBundle)));
    }
  }

  Future<void> _restore() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _rError = null;
      _rSuccess = null;
      _rItems = null;
    });
    final input = _restoreInput.text.trim();
    final pass = _restorePass.text;
    if (input.isEmpty) {
      setState(() => _rError = t.bkErrNoBundle);
      return;
    }
    if (pass.isEmpty) {
      setState(() => _rError = t.bkErrNoPass);
      return;
    }
    setState(() => _rBusy = true);
    try {
      // parse bundle → manifest + ciphertext
      final obj = jsonDecode(utf8.decode(base64Decode(input)))
          as Map<String, dynamic>;
      final manifest = obj['manifest'] as Map<String, dynamic>;
      final ct = base64Decode(obj['ct'] as String);

      if (manifest['format'] != _kFmt) {
        throw const _RestoreError('bad_format');
      }
      final iters = (manifest['kdf_iters'] as int?) ?? _kKdfIters;
      if ((manifest['kdf'] as String?) != _kKdf || iters < 100000) {
        throw const _RestoreError('bad_format');
      }
      final salt = base64Decode(manifest['salt'] as String);
      final nonce = base64Decode(manifest['nonce'] as String);
      final expectSum = (manifest['plaintext_sha256'] as String?)?.toLowerCase();

      final key = Pbkdf2.derive(utf8.encode(pass), salt, iters, 32);
      final plain = ChaCha20Poly1305.decrypt(key, nonce, ct);
      if (plain == null) {
        // AEAD auth failed → wrong passphrase or tampered bundle. HONEST error.
        throw const _RestoreError('wrong_pass');
      }
      // belt-and-braces integrity check against the manifest commitment.
      if (expectSum != null && _sha256Hex(plain) != expectSum) {
        throw const _RestoreError('integrity');
      }
      final text = utf8.decode(plain);
      if (!mounted) return;
      setState(() {
        _rBusy = false;
        _rItems = (manifest['item_count'] as int?) ?? _countItems(text);
        _rSuccess = text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
      });
    } on _RestoreError catch (e) {
      if (!mounted) return;
      setState(() {
        _rBusy = false;
        _rError = switch (e.code) {
          'wrong_pass' => t.bkErrWrongPass,
          'integrity' => t.bkErrIntegrity,
          _ => t.bkErrBadBundle,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rBusy = false;
        _rError = t.bkErrBadBundle;
      });
    }
  }

  // =====================================================================
  // UI
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.bkTitle),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(text: t.bkTabBackup),
            Tab(text: t.bkTabRestore),
            Tab(text: t.bkTabTransfer),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _backupTab(),
          _restoreTab(),
          _transferTab(),
        ],
      ),
    );
  }

  Widget _passphraseWarning() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t.bkPassWarning,
              style: TextStyle(
                  color: cs.onErrorContainer, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------- BACKUP tab
  Widget _backupTab() {
    final result = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _heroCard(
          icon: Icons.lock_outline,
          title: t.bkBackupHeroTitle,
          body: t.bkBackupHeroBody,
        ),
        const SizedBox(height: 16),
        _passphraseWarning(),
        if (result == null) ...[
          Text(t.bkChoosePass, style: _sectionStyle()),
          const SizedBox(height: 8),
          TextField(
            controller: _pass1,
            obscureText: !_show1,
            decoration: InputDecoration(
              labelText: t.bkPassLabel,
              helperText: t.bkPassHelper,
              helperMaxLines: 2,
              suffixIcon: IconButton(
                icon: Icon(_show1 ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show1 = !_show1),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass2,
            obscureText: !_show1,
            decoration: InputDecoration(labelText: t.bkPassConfirmLabel),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _errorLine(_error!),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _createBackup,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.enhanced_encryption_outlined),
            label: Text(_busy ? t.bkEncrypting : t.bkCreateBtn),
          ),
        ] else
          _backupResultCard(result),
      ],
    );
  }

  Widget _backupResultCard(_Backup r) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.verified_user, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(t.bkReadyTitle,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                r.items != null
                    ? t.bkReadyMetaItems(r.items!, _fmtBytes(r.bytes))
                    : t.bkReadyMeta(_fmtBytes(r.bytes)),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(t.bkTransferCodeLabel, style: _sectionStyle()),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                r.code,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                    fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              tooltip: t.bkCopy,
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: r.code));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t.bkCopied)));
              },
            ),
          ],
        ),
        Text(t.bkTransferCodeHint,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _saveBundle,
              icon: const Icon(Icons.save_alt),
              label: Text(t.bkSaveBtn),
            ),
            OutlinedButton.icon(
              onPressed: _shareBundle,
              icon: const Icon(Icons.ios_share),
              label: Text(t.bkShareBtn),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => setState(() {
            _result = null;
            _pass1.clear();
            _pass2.clear();
          }),
          icon: const Icon(Icons.refresh),
          label: Text(t.bkMakeAnother),
        ),
      ],
    );
  }

  // -------------------------------------------------------- RESTORE tab
  Widget _restoreTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _heroCard(
          icon: Icons.restore,
          title: t.bkRestoreHeroTitle,
          body: t.bkRestoreHeroBody,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text(t.bkPasteBundle, style: _sectionStyle())),
            TextButton.icon(
              onPressed: _loadLastSaved,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(t.bkLoadLast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _restoreInput,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: t.bkBundleHint,
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _restorePass,
          obscureText: !_showRestorePass,
          decoration: InputDecoration(
            labelText: t.bkPassLabel,
            suffixIcon: IconButton(
              icon: Icon(
                  _showRestorePass ? Icons.visibility_off : Icons.visibility),
              onPressed: () =>
                  setState(() => _showRestorePass = !_showRestorePass),
            ),
          ),
        ),
        if (_rError != null) ...[
          const SizedBox(height: 12),
          _errorLine(_rError!),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _rBusy ? null : _restore,
          icon: _rBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.lock_open_outlined),
          label: Text(_rBusy ? t.bkDecrypting : t.bkRestoreBtn),
        ),
        if (_rSuccess != null) ...[
          const SizedBox(height: 20),
          _restoreSuccessCard(_rSuccess!, _rItems),
        ],
      ],
    );
  }

  Widget _restoreSuccessCard(String preview, int? items) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.secondary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.check_circle, color: cs.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                items != null
                    ? t.bkRestoreOkItems(items)
                    : t.bkRestoreOk,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: cs.onSecondaryContainer),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(t.bkRestorePreview,
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: cs.onSecondaryContainer)),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                preview,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- TRANSFER tab
  Widget _transferTab() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _heroCard(
          icon: Icons.phonelink_ring,
          title: t.bkTransferHeroTitle,
          body: t.bkTransferHeroBody,
        ),
        const SizedBox(height: 16),
        Text(t.bkTransferHowTitle, style: _sectionStyle()),
        const SizedBox(height: 8),
        _step(1, t.bkTransferStep1),
        _step(2, t.bkTransferStep2),
        _step(3, t.bkTransferStep3),
        _step(4, t.bkTransferStep4),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(t.bkTransferHonest)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // ---- Cloud (Google Drive) — honest key-gated seam.
        Text(t.bkCloudTitle, style: _sectionStyle()),
        const SizedBox(height: 8),
        Opacity(
          opacity: 0.85,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.cloud_outlined, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(t.bkCloudCardTitle,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(t.bkCloudBody,
                    style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.bkCloudNotConfigured)));
                  },
                  icon: const Icon(Icons.link),
                  label: Text(t.bkCloudConnect),
                ),
                const SizedBox(height: 6),
                Text(t.bkCloudSeamNote,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- shared UI
  Widget _heroCard(
      {required IconData icon, required String title, required String body}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(body, style: TextStyle(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(int n, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: cs.primary,
            child: Text('$n',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  Widget _errorLine(String msg) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, color: cs.error, size: 20),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg, style: TextStyle(color: cs.error))),
      ],
    );
  }

  TextStyle _sectionStyle() =>
      const TextStyle(fontSize: 15, fontWeight: FontWeight.bold);

  String _fmtBytes(int b) {
    if (b < 1024) return t.bkBytes(b);
    if (b < 1024 * 1024) return t.bkKib((b / 1024).toStringAsFixed(1));
    return t.bkMib((b / (1024 * 1024)).toStringAsFixed(1));
  }
}

class _Backup {
  final String bundleText;
  final String code;
  final String createdAt;
  final int? items;
  final int bytes;
  const _Backup({
    required this.bundleText,
    required this.code,
    required this.createdAt,
    required this.items,
    required this.bytes,
  });
}

class _RestoreError implements Exception {
  final String code;
  const _RestoreError(this.code);
}
