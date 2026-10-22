import 'dart:io';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/vault_doc_types.dart';
import '../widgets/scam_safety_api.dart';
import '../widgets/ladder_common.dart' show fmtInt;

class VaultScreen extends StatefulWidget {
  /// Preview/screenshot: skip the PIN gate and load straight to the list.
  final bool previewUnlocked;
  const VaultScreen({super.key, this.previewUnlocked = false});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _secure = const FlutterSecureStorage();
  bool _unlocked = false;
  bool _checking = true;
  List<Map<String, dynamic>> _docs = [];
  bool _loading = false;
  bool _error = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.previewUnlocked) {
      _unlocked = true;
      _checking = false;
      _load();
    } else {
      _gate();
    }
  }

  // ------------------------------------------------------------------ PIN gate
  Future<void> _gate() async {
    final pin = await _secure.read(key: 'vault_pin');
    setState(() => _checking = false);
    if (pin == null) {
      await _setPin();
    } else {
      await _enterPin(pin);
    }
    if (_unlocked) _load();
  }

  Future<void> _setPin() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context, barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).vaultSetPinTitle),
        content: ObscureTextField(
          controller: ctrl, keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: InputDecoration(labelText: AppLocalizations.of(context).vaultPinLengthHint),
        ),
        actions: [FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).vaultSetButton))],
      ),
    );
    if (ok == true && ctrl.text.length >= 4) {
      await _secure.write(key: 'vault_pin', value: ctrl.text);
      setState(() => _unlocked = true);
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _enterPin(String real) async {
    final ctrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context, barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text(AppLocalizations.of(context).vaultLockedTitle),
        content: ObscureTextField(
          controller: ctrl, keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: AppLocalizations.of(context).vaultEnterPinHint, errorText: err),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(onPressed: () {
            if (ctrl.text == real) {
              Navigator.pop(ctx, true);
            } else {
              setD(() => err = AppLocalizations.of(context).vaultWrongPin);
            }
          }, child: Text(AppLocalizations.of(context).vaultUnlockButton)),
        ],
      )),
    );
    if (ok == true) {
      setState(() => _unlocked = true);
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  // ------------------------------------------------------------------ data
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _docs = await context.read<AppState>().api.listDocuments();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<String?> _pickImage() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(AppLocalizations.of(context).camera),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
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

  Future<File?> _downloadFile(int id) async {
    final bytes = await context.read<AppState>().api.getBytes('/documents/$id/file');
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/vault_$id.jpg');
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<void> _viewFile(int id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await _downloadFile(id);
      if (f != null) await OpenFilex.open(f.path);
    } catch (_) {
      messenger.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).vaultNoFileAttached)));
    }
  }

  // ------------------------------------------------------------------ add/edit
  Future<void> _add() async {
    final title = TextEditingController();
    final free = TextEditingController();
    String type = 'nid';
    DateTime? expiry;
    String? filePath;
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
                        Icon(d.icon, size: 18), const SizedBox(width: 8), Text(d.label(t))
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(dt.helpText(t)!, style: const TextStyle(fontSize: 12.5))),
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
                        icon: const Icon(Icons.event, size: 18),
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
              icon: const Icon(Icons.event, size: 18),
              label: Text(expiry == null ? t.vaultExpiryDate
                  : '${t.vaultExpiryDate}: ${DateFormat('d MMM yyyy', Localizations.localeOf(ctx).languageCode).format(expiry!)}'),
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: expiry ?? DateTime.now(),
                    firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (d != null) setD(() => expiry = d);
              },
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: Icon(filePath == null ? Icons.attach_file : Icons.check_circle,
                  size: 18, color: filePath == null ? null : Colors.green),
              label: Text(filePath == null ? t.vaultAttachImage : t.vaultImageAttached),
              onPressed: () async {
                final p = await _pickImage();
                if (p != null) setD(() => filePath = p);
              },
            ),
            const SizedBox(height: 10),
            TextField(controller: free, decoration: InputDecoration(labelText: t.moneyFieldNoteOptional)),
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
        if (filePath != null) {
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
    final t = AppLocalizations.of(context);
    final dt = vaultTypeOf(doc['doc_type']);
    final decoded = readDocDetails(doc);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.6, maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView(controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Row(children: [
            Icon(dt.icon, size: 26),
            const SizedBox(width: 10),
            Expanded(child: Text(doc['title'] ?? '',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 4),
          Text(dt.label(t), style: TextStyle(color: Colors.grey)),
          if (dt.helpText(t) != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(dt.helpText(t)!, style: const TextStyle(fontSize: 12.5))),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          if (decoded.details.isNotEmpty)
            for (final e in decoded.details.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 140, child: Text(_fieldLabel(t, dt, e.key),
                      style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(child: SelectableText(e.value)),
                ]),
              ),
          if (doc['expiry_date'] != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.event_busy, size: 18),
              const SizedBox(width: 8),
              Text('${t.vaultExpiryDate}: '),
              if (_expiryBadge(doc['expiry_date']) != null) _expiryBadge(doc['expiry_date'])!,
            ]),
          ],
          if (decoded.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(decoded.note),
          ],
          const SizedBox(height: 18),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (doc['file_url'] != null)
              FilledButton.tonalIcon(
                onPressed: () { Navigator.pop(ctx); _viewFile(doc['id']); },
                icon: const Icon(Icons.visibility_outlined), label: Text(t.view)),
            FilledButton.tonalIcon(
              onPressed: () { Navigator.pop(ctx); _shareToNominee(doc); },
              icon: const Icon(Icons.ios_share), label: Text(t.vaultShareToNominee)),
            if (dt.guideKey != null)
              FilledButton.tonalIcon(
                onPressed: () { Navigator.pop(ctx); _showRenewal(dt); },
                icon: const Icon(Icons.autorenew), label: Text(t.vaultRenewalSteps)),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await context.read<AppState>().api.deleteDocument(doc['id']);
                _load();
              },
              icon: const Icon(Icons.delete_outline), label: Text(t.delete)),
          ]),
        ]),
      ),
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
    showModalBottomSheet(
      context: context, showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.vaultRenewalSteps, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          if (svc == null)
            Text(t.vaultRenewalUnavailable)
          else ...[
            if (svc['portal'] != null) ...[
              Row(children: [
                const Icon(Icons.public, size: 16), const SizedBox(width: 6),
                SelectableText(svc['portal'].toString()),
              ]),
              const SizedBox(height: 10),
            ],
            for (int i = 0; i < ((svc['steps'] ?? []) as List).length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
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
        final f = await _downloadFile(doc['id']);
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
                decoration: InputDecoration(hintText: t.vaultQuickLookupHint, prefixIcon: const Icon(Icons.search)),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 8),
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
    else if (days <= 90) { c = const Color(0xFFB8860B); t = AppLocalizations.of(context).vaultExpiresInDays(daysStr); }
    else { c = Colors.green; t = DateFormat('d MMM yyyy', Localizations.localeOf(context).languageCode).format(d); }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
      child: Text(t, style: TextStyle(fontSize: 11, color: c)));
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return Scaffold(
        appBar: AppBar(title: Text(t.vaultTitle)),
        body: Center(child: Text(t.vaultLockedMessage)),
      );
    }
    final filtered = _query.isEmpty
        ? _docs
        : _docs.where((d) => (d['title'] ?? '').toString().toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultTitle), actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: t.vaultQuickLookup,
          onPressed: _quickLookup,
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add, icon: const Icon(Icons.add), label: Text(t.add)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.loadFailed,
                  message: t.checkInternetRetry,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : _docs.isEmpty
                  ? StateMessage(
                      icon: Icons.folder_open_outlined,
                      title: t.vaultEmptyTitle,
                      message: t.vaultEmptyMessage)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                      children: [
                        for (final doc in filtered)
                          Card(child: ListTile(
                            onTap: () => _openDoc(doc),
                            leading: Icon(vaultTypeOf(doc['doc_type']).icon),
                            title: Text(doc['title'] ?? ''),
                            subtitle: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(vaultTypeOf(doc['doc_type']).label(t)),
                                if (_expiryBadge(doc['expiry_date']) != null)
                                  _expiryBadge(doc['expiry_date'])!,
                              ]),
                            trailing: const Icon(Icons.chevron_right),
                          )),
                      ],
                    ),
    );
  }
}
