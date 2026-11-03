import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/vault_doc_types.dart';
import '../widgets/scam_safety_api.dart';
import '../services/error_kind.dart' show FailKind, failKindOf, honestFailText; // qa2
import '../otp_api.dart' show ApiOtpBackend, OtpBackend;
import '../photo_studio/ps_engines.dart' show ChannelSecureScreen, SecureScreen;
import '../vault/vault_api.dart';
import '../vault/vault_e2e.dart';
import '../vault/vault_e2e_api.dart';
import '../vault/vault_e2e_screen.dart';
import '../vault/vault_share_sheet.dart';
import '../feature_flags.dart' show FeatureFlags;
import '../vault/vault_lock.dart';
import '../vault/vault_lock_view.dart';
import '../vault/vault_offline.dart';
import '../vault/vault_recovery_screen.dart';
import '../vault/vault_security_screen.dart';
import '../vault/vault_viewer.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'package:assisto/widgets/app_sheet.dart';
import '../theme.dart' show AType, Brand, Gap, Radii; // qa1

class VaultScreen extends StatefulWidget {
  /// Preview/screenshot: skip the PIN gate and load straight to the list.
  final bool previewUnlocked;

  /// vault100 seams (tests inject fakes; the app uses the real ones).
  final VaultLock? lock;
  final VaultOffline? offline;
  final VaultBackend? backend;
  final OtpBackend? otpBackend;
  final SecureScreen secure;
  const VaultScreen(
      {super.key,
      this.previewUnlocked = false,
      this.lock,
      this.offline,
      this.backend,
      this.otpBackend,
      this.secure = const ChannelSecureScreen()});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

enum _Gate { checking, setPin, enterPin, open }

class _VaultScreenState extends State<VaultScreen> {
  late final VaultLock _lock = widget.lock ?? VaultLock();
  late final VaultOffline _offline = widget.offline ?? VaultOffline.instance;
  VaultBackend? _backendCache;
  VaultBackend get _backend =>
      _backendCache ??= widget.backend ?? ApiVaultBackend(context.read<AppState>().api);
  OtpBackend get _otp => widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);
  // p3docs: end-to-end lock (flag vault_e2e)
  VaultE2EBackend? _e2eCache;
  VaultE2EBackend get _e2eBackend =>
      _e2eCache ??= ApiVaultE2EBackend(context.read<AppState>().api);
  bool get _e2eFlag => FeatureFlags.instance.isOn('vault_e2e');

  _Gate _gateState = _Gate.checking;
  String? _gateNotice;
  List<Map<String, dynamic>> _docs = [];
  bool _loading = false;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  String _query = '';
  // vault100: offline copies
  Set<int> _offlineIds = {};
  bool _offlineMode = false; // the list below is the phone's saved copies
  final Set<int> _busyIds = {};
  bool _hasRecoveryCode = true;
  bool _nudgeDismissed = false;

  @override
  void initState() {
    super.initState();
    widget.secure.enable(); // vault100: no screenshots / recents preview
    if (widget.previewUnlocked) {
      _gateState = _Gate.open;
      _load();
    } else {
      _gate();
    }
  }

  @override
  void dispose() {
    widget.secure.disable();
    VaultE2E.instance.lock(); // p3docs: the document key leaves memory with the vault
    super.dispose();
  }

  // ------------------------------------------------------------------ PIN gate
  Future<void> _gate() async {
    final has = await _lock.hasPin();
    if (!mounted) return;
    setState(() => _gateState = has ? _Gate.enterPin : _Gate.setPin);
  }

  void _opened() {
    setState(() {
      _gateState = _Gate.open;
      _gateNotice = null;
    });
    _load();
  }

  Future<void> _forgot() async {
    final ok = await VaultRecoveryScreen.run(context,
        lock: _lock, backend: _backend, otpBackend: _otp);
    if (!ok || !mounted) return;
    setState(() {
      _gateState = _Gate.setPin;
      _gateNotice = AppLocalizations.of(context).vaultRecoverSetNew;
    });
  }

  // ------------------------------------------------------------------ data
  static const _localWait = Duration(seconds: 3);

  Future<Map<int, OfflineEntry>> _savedCopies() =>
      _offline.index().timeout(_localWait, onTimeout: () => <int, OfflineEntry>{});

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _docs = (await context.read<AppState>().api.listDocuments()).map(_unseal).toList();
      if (_docs.any((d) => d['_e2e_locked'] == true)) {
        // p3docs: a sealed document opened earlier on this phone keeps its
        // saved (locally encrypted) details, so syncing never loses them.
        final saved = await _savedCopies();
        _docs = [
          for (final d in _docs)
            if (d['_e2e_locked'] == true && saved[d['id']]?.meta['_sealed'] is Map)
              {...saved[d['id']]!.meta, 'id': d['id'], 'e2e': true}
            else
              d
        ];
      }
      _offlineMode = false;
      // keep the phone's copies in step (never blocks the list)
      // best-effort: syncWith never throws (every store call is caught inside);
      // if it ever failed, the copies just keep their last saved details and
      // still open offline — the next load retries. The badges refresh anyway.
      unawaited(_offline.syncWith(_docs).then((_) => _refreshLocal(),
          onError: (_) => _refreshLocal()));
    } catch (e) {
      _failCause = e;
      final saved = failKindOf(e) == FailKind.network
          ? await _savedCopies()
          : const <int, OfflineEntry>{};
      if (saved.isNotEmpty) {
        // vault100: no internet -> the copies saved on this phone, honestly labelled
        _docs = [for (final x in saved.values) x.meta];
        _offlineMode = true;
      } else {
        _error = true;
      }
    }
    if (mounted) setState(() => _loading = false);
    unawaited(_refreshLocal());
  }

  /// Offline badges + the recovery-code nudge: local reads AFTER the list is
  /// shown (a slow phone store never holds the list back).
  Future<void> _refreshLocal() async {
    final ids = (await _offline.index()).keys.toSet();
    final has = await _lock.hasRecoveryCode();
    if (!mounted) return;
    setState(() {
      _offlineIds = ids;
      _hasRecoveryCode = has;
    });
  }

  /// p3docs: open a sealed document's box with the in-memory key. Locked
  /// (key not on this phone yet) -> blank title + `_e2e_locked`.
  Map<String, dynamic> _unseal(Map<String, dynamic> d) {
    if (d['e2e'] != true) return d;
    final det = d['details'];
    final box = det is Map ? '${det['box'] ?? ''}' : '';
    final meta = VaultE2E.instance.openDocBox(box);
    if (meta == null) return {...d, 'title': '', 'details': <String, dynamic>{}, '_e2e_locked': true};
    return {
      ...d,
      'title': '${meta['title'] ?? ''}',
      'note': '${meta['note'] ?? ''}',
      'details': meta['details'] is Map ? meta['details'] : <String, dynamic>{},
      'expiry_date': d['expiry_date'] ?? meta['expiry'],
      '_sealed': meta,
    };
  }

  /// The document's real bytes: as-is for a normal document, decrypted on
  /// the phone for a sealed one (null = locked / tampered).
  Future<Uint8List?> _plainBytes(Map<String, dynamic> doc, List<int> bytes) async {
    if (doc['e2e'] != true) return Uint8List.fromList(bytes);
    final meta = doc['_sealed'];
    if (meta is! Map) return null;
    return VaultE2E.openDocFile(meta.cast<String, dynamic>(), bytes);
  }

  Future<void> _openE2E() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VaultE2EScreen(lock: _lock, backend: _e2eBackend)));
    if (mounted) _load();
  }

  Future<void> _shareLink(Map<String, dynamic> doc) async {
    final id = doc['id'] as int;
    await showVaultShareSheet(context,
        docId: id,
        title: '${doc['title'] ?? ''}',
        backend: _e2eBackend,
        loadPlain: () async {
          if (doc['file_url'] == null) return null;
          final bytes = await context.read<AppState>().api.getBytes('/documents/$id/file');
          return _plainBytes(doc, bytes);
        });
  }

  Future<String?> _pickImage() async {
    final src = await showAppSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(AppLocalizations.of(context).camera),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(AppLocalizations.of(context).gallery),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (src == null) return null;
    if (src == ImageSource.camera && mounted) {
      if (!await showPermissionReason(context, PermKind.camera)) {
        return null;
      }
    }
    final x = await ImagePicker().pickImage(source: src, imageQuality: 70);
    return x?.path;
  }

  Future<File?> _downloadFile(Map<String, dynamic> doc) async {
    final id = doc['id'] as int;
    final raw = await context.read<AppState>().api.getBytes('/documents/$id/file');
    final bytes = await _plainBytes(doc, raw); // p3docs: decrypt a sealed one
    if (bytes == null) return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/vault_$id.jpg');
    await f.writeAsBytes(bytes);
    return f;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// vault100: the phone's encrypted copy first (works with no internet),
  /// else the server; shown in the in-app viewer (bytes stay in memory).
  Future<void> _viewFile(Map<String, dynamic> doc) async {
    final t = AppLocalizations.of(context);
    final id = doc['id'] as int;
    final nav = Navigator.of(context);
    final title = '${doc['title'] ?? ''}';
    if (_offlineIds.contains(id)) {
      final saved = await _offline.openFile(id);
      final bytes = saved == null ? null : await _plainBytes(doc, saved);
      if (bytes != null) {
        nav.push(MaterialPageRoute(
            builder: (_) => VaultViewer(bytes: bytes, title: title, fromOfflineCopy: true)));
        return;
      }
    }
    if (_offlineMode) {
      _snack(t.vaultNotOfflineYet);
      return;
    }
    try {
      final raw = await context.read<AppState>().api.getBytes('/documents/$id/file');
      final bytes = await _plainBytes(doc, raw);
      if (!mounted) return;
      if (bytes == null) {
        _snack(t.vaultE2eLockedOpen);
        return;
      }
      nav.push(MaterialPageRoute(
          builder: (_) => VaultViewer(bytes: bytes, title: title)));
    } catch (e) {
      _snack(failKindOf(e) == FailKind.network
          ? t.vaultNeedInternetOpen
          : honestFailText(t, e, otherwise: t.vaultNoFileAttached));
    }
  }

  /// vault100: keep / drop the encrypted copy on this phone.
  Future<void> _setOffline(Map<String, dynamic> doc, bool on) async {
    final t = AppLocalizations.of(context);
    final id = doc['id'] as int;
    setState(() => _busyIds.add(id));
    var ok = true;
    try {
      if (on) {
        List<int>? bytes;
        if (doc['file_url'] != null) {
          bytes = await context.read<AppState>().api.getBytes('/documents/$id/file');
        }
        ok = await _offline.save(doc, bytes);
      } else {
        await _offline.remove(id);
      }
    } catch (e) {
      if (mounted) {
        _snack(failKindOf(e) == FailKind.network ? t.vaultNeedInternetSave : t.vaultOfflineSaveFailed);
      }
      if (mounted) setState(() => _busyIds.remove(id));
      return;
    }
    _offlineIds = (await _offline.index()).keys.toSet();
    if (!mounted) return;
    setState(() => _busyIds.remove(id));
    if (!ok) {
      _snack(t.vaultOfflineSaveFailed);
    } else {
      _snack(on ? t.vaultOfflineSaved : t.vaultOfflineRemoved);
    }
  }

  Future<void> _setAlerts(Map<String, dynamic> doc, bool on) async {
    final t = AppLocalizations.of(context);
    try {
      final meta = doc['_sealed'];
      if (doc['e2e'] == true && meta is Map && meta['expiry'] != null) {
        // p3docs: a sealed document's expiry date is on the server ONLY while
        // its reminder is on; switching it off takes the date back off.
        await context.read<AppState>().api.patchJson('/documents/${doc['id']}/',
            {'expiry_alerts': on, 'expiry_date': on ? meta['expiry'] : null});
      } else {
        await _backend.setExpiryAlerts(doc['id'] as int, on);
      }
      setState(() => doc['expiry_alerts'] = on);
    } catch (e) {
      _snack(failKindOf(e) == FailKind.network ? t.vaultNeedInternet : honestFailText(t, e));
    }
  }

  Future<void> _delete(Map<String, dynamic> doc) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.vaultDeleteTitle),
        content: Text(t.vaultDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const Key('vault_delete_confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteDocument(doc['id'] as int);
      await _offline.remove(doc['id'] as int);
      _load();
    } catch (e) {
      _snack(failKindOf(e) == FailKind.network ? t.vaultNeedInternet : honestFailText(t, e));
    }
  }

  Future<void> _openSecurity() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VaultSecurityScreen(lock: _lock, offline: _offline, backend: _backend)));
    if (!mounted) return;
    _offlineIds = (await _offline.index()).keys.toSet();
    _hasRecoveryCode = await _lock.hasRecoveryCode();
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ add/edit
  Future<void> _add() async {
    final title = TextEditingController();
    final free = TextEditingController();
    String type = 'nid';
    DateTime? expiry;
    String? filePath;
    // p3docs: end-to-end lock this document (default ON once the lock is open)
    final canSeal = _e2eFlag && VaultE2E.instance.unlocked;
    var seal = canSeal;
    final details = <String, TextEditingController>{};
    final detailDates = <String, DateTime?>{};

    TextEditingController ctrlFor(String k) =>
        details.putIfAbsent(k, () => TextEditingController());

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final t = AppLocalizations.of(ctx);
        final dt = vaultTypeOf(type);
        return AlertDialog(
          title: Text(t.vaultAddDocument),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: InputDecoration(labelText: t.vaultNameRequired)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: type,
              decoration: InputDecoration(labelText: t.moneyFieldType),
              items: kVaultDocTypes.map((d) =>
                  DropdownMenuItem(value: d.key,
                      child: Row(children: [
                        Icon(d.icon, size: 18), const SizedBox(width: Gap.sm), Text(d.label(t))
                      ]))).toList(),
              onChanged: (v) => setD(() => type = v ?? 'other'),
            ),
            const SizedBox(height: 10),
            // Honest how-to helper for types that need it (e.g. finding IMEI).
            if (dt.helpText(t) != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline_rounded, size: 18),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(dt.helpText(t)!, style: AType.bodySmall)),
                ]),
              ),
              const SizedBox(height: 10),
            ],
            // type-specific fields
            for (final f in dt.fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: f.isDate
                    ? OutlinedButton.icon(
                        icon: const Icon(Icons.event_rounded, size: 18),
                        label: Text(detailDates[f.key] == null
                            ? f.label(t)
                            : '${f.label(t)}: ${DateFormat('d MMM yyyy', Localizations.localeOf(ctx).languageCode).format(detailDates[f.key]!)}'),
                        onPressed: () async {
                          final d = await showDatePicker(context: ctx,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(1950), lastDate: DateTime(2100));
                          if (d != null) {
                            setD(() {
                              detailDates[f.key] = d;
                              // auto-suggest expiry from issue/purchase date
                              if (dt.defaultValidityYears != null &&
                                  (f.key == 'issue_date' || f.key == 'purchase_date') &&
                                  expiry == null) {
                                expiry = DateTime(d.year + dt.defaultValidityYears!, d.month, d.day);
                              }
                            });
                          }
                        },
                      )
                    : TextField(
                        controller: ctrlFor(f.key),
                        decoration: InputDecoration(labelText: f.label(t)),
                      ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_rounded, size: 18),
              label: Text(expiry == null ? t.vaultExpiryDate
                  : '${t.vaultExpiryDate}: ${DateFormat('d MMM yyyy', Localizations.localeOf(ctx).languageCode).format(expiry!)}'),
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: expiry ?? DateTime.now(),
                    firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (d != null) setD(() => expiry = d);
              },
            ),
            if (expiry != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.vaultExpiryRemindNote, style: AType.bodySmall),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: Icon(filePath == null ? Icons.attach_file_rounded : Icons.check_circle_rounded,
                  size: 18, color: filePath == null ? null : Colors.green),
              label: Text(filePath == null ? t.vaultAttachImage : t.vaultImageAttached),
              onPressed: () async {
                final p = await _pickImage();
                if (p != null) setD(() => filePath = p);
              },
            ),
            const SizedBox(height: 10),
            TextField(controller: free, decoration: InputDecoration(labelText: t.moneyFieldNoteOptional)),
            if (canSeal)
              SwitchListTile(
                key: const Key('vault_seal_switch'),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.enhanced_encryption_rounded),
                title: Text(t.vaultE2eSealSwitch),
                subtitle: Text(t.vaultE2eSealSwitchSub),
                value: seal,
                onChanged: (v) => setD(() => seal = v),
              ),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        );
      }),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      final detailMap = <String, String>{};
      details.forEach((k, v) => detailMap[k] = v.text);
      detailDates.forEach((k, v) {
        if (v != null) detailMap[k] = DateFormat('yyyy-MM-dd').format(v);
      });
      // Structured fields travel as a real map; the free text stays as note.
      // Nothing is packed into a delimited string, so values with ';', '|' or
      // '=' can no longer corrupt the record.
      final cleaned = cleanDetails(detailMap);
      final noteStr = free.text.trim();
      try {
        final expiryStr = expiry != null ? DateFormat('yyyy-MM-dd').format(expiry!) : null;
        if (seal && VaultE2E.instance.unlocked) {
          // p3docs: sealed on THIS phone; the server gets ciphertext only.
          final fp = filePath;
          final bytes = fp == null ? null : await File(fp).readAsBytes();
          final sealed = await VaultE2E.instance.sealDocument({
            'title': title.text.trim(),
            'note': noteStr,
            'details': cleaned,
            if (expiryStr != null) 'expiry': expiryStr,
          }, file: bytes, mime: bytes == null ? null : sniffMime(bytes));
          await _e2eBackend.uploadSealed(
              docType: type, expiryDate: expiryStr, expiryAlerts: true,
              box: sealed.box, file: sealed.file);
        } else if (filePath != null) {
          await context.read<AppState>().api.uploadDocumentWithDetails(
              title: title.text.trim(), docType: type,
              expiryDate: expiryStr, details: cleaned, note: noteStr,
              filePath: filePath!);
        } else {
          await context.read<AppState>().api.createDocumentWithDetails(
              title: title.text.trim(), docType: type,
              expiryDate: expiryStr, details: cleaned, note: noteStr);
        }
        await _load();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  // ------------------------------------------------------------------ detail sheet
  void _openDoc(Map<String, dynamic> doc) {
    if (doc['_e2e_locked'] == true) {
      _openE2E(); // p3docs: unlock first (recovery code / trusted person)
      return;
    }
    final t = AppLocalizations.of(context);
    final dt = vaultTypeOf(doc['doc_type']);
    final decoded = readDocDetails(doc);
    final id = doc['id'] as int;
    showAppSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.6, maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView(controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, Gap.xl), children: [
          Row(children: [
            Icon(dt.icon, size: 26),
            const SizedBox(width: 10),
            Expanded(child: Text(doc['title'] ?? '',
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(dt.label(t), style: TextStyle(color: Colors.grey)),
          if (doc['e2e'] == true)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(children: [
                const Icon(Icons.enhanced_encryption_rounded, size: 18),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(t.vaultE2eBadgeLong, style: AType.bodySmall)),
              ]),
            ),
          if (dt.helpText(t) != null) ...[
            const SizedBox(height: Gap.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline_rounded, size: 18),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(dt.helpText(t)!, style: AType.bodySmall)),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          if (decoded.details.isNotEmpty)
            for (final e in decoded.details.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 140, child: Text(_fieldLabel(t, dt, e.key),
                      style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(child: SelectableText(e.value)),
                ]),
              ),
          if (doc['expiry_date'] != null) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              const Icon(Icons.event_busy_rounded, size: 18),
              const SizedBox(width: Gap.sm),
              Text('${t.vaultExpiryDate}: '),
              if (_expiryBadge(doc['expiry_date']) != null) _expiryBadge(doc['expiry_date'])!,
            ]),
          ],
          if (decoded.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(decoded.note),
          ],
          const SizedBox(height: Gap.md),
          // vault100: keep an encrypted copy on this phone (opens offline)
          SwitchListTile(
            key: const Key('vault_offline_switch'),
            contentPadding: EdgeInsets.zero,
            secondary: _busyIds.contains(id)
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_offlineIds.contains(id) ? Icons.offline_pin_rounded : Icons.download_for_offline_outlined),
            title: Text(t.vaultAvailableOffline),
            subtitle: Text(_offlineIds.contains(id) ? t.vaultAvailableOfflineOn : t.vaultAvailableOfflineOff),
            value: _offlineIds.contains(id),
            onChanged: _busyIds.contains(id) || (_offlineMode && !_offlineIds.contains(id))
                ? null
                : (v) async {
                    await _setOffline(doc, v);
                    setS(() {});
                  },
          ),
          if (doc['expiry_date'] != null)
            SwitchListTile(
              key: const Key('vault_alerts_switch'),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_active_outlined),
              title: Text(t.vaultExpiryAlerts),
              subtitle: Text(t.vaultExpiryAlertsSub),
              value: doc['expiry_alerts'] != false,
              onChanged: _offlineMode
                  ? null
                  : (v) async {
                      await _setAlerts(doc, v);
                      setS(() {});
                    },
            ),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (doc['file_url'] != null)
              FilledButton.tonalIcon(
                key: const Key('vault_view'),
                onPressed: () { Navigator.pop(ctx); _viewFile(doc); },
                icon: const Icon(Icons.visibility_rounded), label: Text(t.view)),
            if (_e2eFlag && doc['file_url'] != null)
              FilledButton.tonalIcon(
                key: const Key('vault_share_link'),
                onPressed: () {
                  Navigator.pop(ctx);
                  if (_offlineMode) { _snack(t.vaultNeedInternet); } else { _shareLink(doc); }
                },
                icon: const Icon(Icons.add_link_rounded), label: Text(t.vaultShareLink)),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(ctx);
                if (_offlineMode) { _snack(t.vaultNeedInternet); } else { _shareToNominee(doc); }
              },
              icon: const Icon(Icons.ios_share_rounded), label: Text(t.vaultShareToNominee)),
            if (dt.guideKey != null)
              FilledButton.tonalIcon(
                onPressed: () { Navigator.pop(ctx); _showRenewal(dt); },
                icon: const Icon(Icons.autorenew_rounded), label: Text(t.vaultRenewalSteps)),
            OutlinedButton.icon(
              key: const Key('vault_delete'),
              onPressed: () { Navigator.pop(ctx); _delete(doc); },
              icon: const Icon(Icons.delete_outline_rounded), label: Text(t.delete)),
          ]),
        ]),
      )),
    );
  }

  String _fieldLabel(AppLocalizations t, VaultDocType dt, String key) {
    for (final f in dt.fields) {
      if (f.key == key) return f.label(t);
    }
    // fall back to generic labels
    return VaultField(key).label(t);
  }

  // ------------------------------------------------------------------ renewal
  Future<void> _showRenewal(VaultDocType dt) async {
    final t = AppLocalizations.of(context);
    List<Map<String, dynamic>> services = [];
    try {
      services = await context.read<AppState>().api.govtGuides();
    } catch (_) {} // best-effort: the sheet then says vaultRenewalUnavailable
    if (!mounted) return;
    Map<String, dynamic>? svc;
    for (final s in services) {
      if (s['key'] == dt.guideKey) { svc = s; break; }
    }
    showAppSheet(
      context: context, showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.vaultRenewalSteps, style: AType.titleLarge.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          if (svc == null)
            Text(t.vaultRenewalUnavailable)
          else ...[
            if (svc['portal'] != null) ...[
              Row(children: [
                const Icon(Icons.public_rounded, size: 16), const SizedBox(width: 6),
                SelectableText(svc['portal'].toString()),
              ]),
              const SizedBox(height: 10),
            ],
            for (int i = 0; i < ((svc['steps'] ?? []) as List).length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 11, child: Text('${i + 1}', style: AType.bodySmall)),
                  const SizedBox(width: 10),
                  Expanded(child: Text((svc['steps'] as List)[i].toString())),
                ]),
              ),
          ],
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ share
  Future<void> _shareToNominee(Map<String, dynamic> doc) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.vaultShareToNominee),
        content: Text(t.vaultShareConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultShareNow)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final decoded = readDocDetails(doc);
      final buf = StringBuffer()
        ..writeln(doc['title'] ?? '')
        ..writeln(vaultTypeOf(doc['doc_type']).label(t));
      decoded.details.forEach((k, v) =>
          buf.writeln('${_fieldLabel(t, vaultTypeOf(doc['doc_type']), k)}: $v'));
      if (doc['expiry_date'] != null) buf.writeln('${t.vaultExpiryDate}: ${doc['expiry_date']}');
      if (doc['file_url'] != null) {
        final f = await _downloadFile(doc);
        if (f != null) {
          await Share.shareXFiles([XFile(f.path)], text: buf.toString());
          return;
        }
      }
      await Share.share(buf.toString());
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.vaultShareFailed)));
    }
  }

  // ------------------------------------------------------------------ quick lookup
  Future<void> _quickLookup() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = ctrl.text.trim().toLowerCase();
        final matches = q.isEmpty
            ? <Map<String, dynamic>>[]
            : _docs.where((d) {
                final decoded = readDocDetails(d);
                final hay = [
                  d['title'] ?? '',
                  decoded.details.values.join(' '),
                  decoded.note,
                ].join(' ').toLowerCase();
                return hay.contains(q);
              }).toList();
        return AlertDialog(
          title: Text(t.vaultQuickLookup),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: ctrl, autofocus: true,
                decoration: InputDecoration(hintText: t.vaultQuickLookupHint, prefixIcon: const Icon(Icons.search_rounded)),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: Gap.sm),
              if (q.isNotEmpty && matches.isEmpty)
                Text(t.vaultQuickLookupNone),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final d in matches)
                    ListTile(
                      dense: true,
                      leading: Icon(vaultTypeOf(d['doc_type']).icon, size: 20),
                      title: Text(d['title'] ?? ''),
                      subtitle: Text(_lookupPreview(d)),
                      onTap: () { Navigator.pop(ctx); _openDoc(d); },
                    ),
                ]),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.close))],
        );
      }),
    );
  }

  String _lookupPreview(Map<String, dynamic> d) {
    final decoded = readDocDetails(d);
    if (decoded.details.containsKey('number')) return decoded.details['number']!;
    if (decoded.details.containsKey('policy_no')) return decoded.details['policy_no']!;
    return decoded.details.values.isNotEmpty ? decoded.details.values.first : (decoded.note);
  }

  // ------------------------------------------------------------------ expiry badge
  Widget? _expiryBadge(String? iso) {
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    final days = d.difference(DateTime.now()).inDays;
    Color c;
    String t;
    final daysStr = fmtInt(context, days);
    if (days < 0) { c = Colors.red; t = AppLocalizations.of(context).vaultExpired; }
    else if (days <= 7) { c = Colors.red; t = AppLocalizations.of(context).vaultExpiresInDays(daysStr); }
    else if (days <= 30) { c = Colors.orange; t = AppLocalizations.of(context).vaultExpiresInDays(daysStr); }
    else if (days <= 90) { c = Brand.warnInk(context); t = AppLocalizations.of(context).vaultExpiresInDays(daysStr); }
    else { c = Colors.green; t = DateFormat('d MMM yyyy', Localizations.localeOf(context).languageCode).format(d); }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
      // qa1: orange/green 11px on their own pale tint was ~2.5:1
      child: Text(t, style: AType.labelSmall.copyWith(color: Brand.onTint(context, c))));
  }

  // ------------------------------------------------------------------ build
  /// p3docs: the end-to-end lock's state at the top of the list.
  Widget _e2eCard(AppLocalizations t) {
    final locked = _docs.where((d) => d['_e2e_locked'] == true).length;
    final on = VaultE2E.instance.unlocked;
    return Card(
      key: const Key('vault_e2e_card'),
      child: ListTile(
        minVerticalPadding: Gap.sm,
        leading: Icon(locked > 0 ? Icons.lock_rounded : Icons.enhanced_encryption_rounded),
        title: Text(locked > 0
            ? t.vaultE2eLockedCount(fmtInt(context, locked))
            : on
                ? t.vaultE2eOnTitle
                : t.vaultE2eTitle),
        subtitle: Text(locked > 0 ? t.vaultE2eUnlockCode : (on ? t.vaultE2eBadgeLong : t.vaultE2eWhatShort)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _openE2E,
      ),
    );
  }

  Widget _nudge(AppLocalizations t) => Card(
        key: const Key('vault_recovery_nudge'),
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.key_rounded, color: Theme.of(context).colorScheme.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.vaultNudgeTitle,
                      style: AType.titleSmall.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSecondaryContainer))),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.vaultNudgeBody,
                style: AType.bodyMedium
                    .copyWith(color: Theme.of(context).colorScheme.onSecondaryContainer)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, children: [
              FilledButton(
                  onPressed: () async {
                    final code = await _lock.newRecoveryCode();
                    if (code == null || !mounted) return;
                    await syncE2ERecoveryCode(_e2eBackend, code); // p3docs
                    if (!mounted) return;
                    await showVaultRecoveryCode(context, code);
                    _hasRecoveryCode = await _lock.hasRecoveryCode();
                    if (mounted) setState(() {});
                  },
                  child: Text(t.vaultRecoveryCodeCreate)),
              TextButton(
                  onPressed: () => setState(() => _nudgeDismissed = true),
                  child: Text(t.vaultNudgeLater)),
            ]),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    switch (_gateState) {
      case _Gate.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Gate.setPin:
      case _Gate.enterPin:
        return Scaffold(
          appBar: AppBar(title: Text(t.vaultTitle)),
          body: VaultLockView(
            key: ValueKey(_gateState),
            lock: _lock,
            mode: _gateState == _Gate.setPin ? VaultLockMode.set : VaultLockMode.enter,
            notice: _gateNotice,
            onUnlocked: _opened,
            onForgot: _forgot,
          ),
        );
      case _Gate.open:
        break;
    }
    final filtered = _query.isEmpty
        ? _docs
        : _docs.where((d) => (d['title'] ?? '').toString().toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultTitle), actions: [
        IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: t.vaultQuickLookup,
          onPressed: _quickLookup,
        ),
        IconButton(
          key: const Key('vault_security'),
          icon: const Icon(Icons.shield_outlined),
          tooltip: t.vaultSecurityTitle,
          onPressed: _openSecurity,
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _offlineMode ? () => _snack(t.vaultNeedInternet) : _add,
          icon: const Icon(Icons.add_rounded), label: Text(t.add)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.checkInternetRetry),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : _docs.isEmpty
                  ? StateMessage(
                      icon: Icons.folder_open_rounded,
                      title: t.vaultEmptyTitle,
                      message: t.vaultEmptyMessage,
                      action: _e2eFlag
                          ? OutlinedButton.icon(
                              key: const Key('vault_e2e_empty'),
                              onPressed: _openE2E,
                              icon: const Icon(Icons.enhanced_encryption_rounded),
                              label: Text(t.vaultE2eTitle))
                          : null)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
                      children: [
                        if (_offlineMode)
                          Card(
                            key: const Key('vault_offline_banner'),
                            child: ListTile(
                              leading: const Icon(Icons.cloud_off_rounded),
                              title: Text(t.vaultOfflineBanner(fmtInt(context, _docs.length))),
                              subtitle: Text(t.vaultOfflineBannerSub),
                              trailing: TextButton(onPressed: _load, child: Text(t.retry)),
                            ),
                          ),
                        if (!_offlineMode && !_hasRecoveryCode && !_nudgeDismissed && !widget.previewUnlocked)
                          _nudge(t),
                        if (_e2eFlag && !_offlineMode) _e2eCard(t),
                        for (final doc in filtered)
                          Card(child: ListTile(
                            minVerticalPadding: Gap.sm,
                            onTap: () => _openDoc(doc),
                            leading: Icon(doc['_e2e_locked'] == true
                                ? Icons.lock_rounded
                                : vaultTypeOf(doc['doc_type']).icon),
                            title: Text(doc['_e2e_locked'] == true
                                ? t.vaultE2eLockedTitle
                                : '${doc['title'] ?? ''}'),
                            subtitle: Wrap(spacing: Gap.sm, runSpacing: Gap.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(vaultTypeOf(doc['doc_type']).label(t)),
                                if (_expiryBadge(doc['expiry_date']) != null)
                                  _expiryBadge(doc['expiry_date'])!,
                                if (doc['e2e'] == true)
                                  Semantics(
                                    label: t.vaultE2eBadge,
                                    child: const Icon(Icons.enhanced_encryption_rounded, size: 18),
                                  ),
                                if (_offlineIds.contains(doc['id']))
                                  Semantics(
                                    label: t.vaultAvailableOffline,
                                    child: const Icon(Icons.offline_pin_rounded, size: 18),
                                  ),
                              ]),
                            trailing: const Icon(Icons.chevron_right_rounded),
                          )),
                      ],
                    )),
    );
  }
}
