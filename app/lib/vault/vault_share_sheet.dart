// p3docs — "Show with a link": a time-limited, END-TO-END encrypted link to
// one vault document (flag vault_e2e). The phone seals a fresh copy with a
// new random key; the server gets only that ciphertext; the key rides in the
// link's #fragment, which browsers never send to a server
// (web/views_vault_share.py decrypts in the browser). Expiry 1 h / 1 day /
// 3 days / 7 days, 1 / 3 / 10 opens, owner sees opens and turns it off.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart' show AType, Gap;
import '../widgets/app_sheet.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'vault_e2e.dart';
import 'vault_e2e_api.dart';

/// [loadPlain] returns the document's decrypted file bytes (null = none).
Future<void> showVaultShareSheet(
  BuildContext context, {
  required int docId,
  required String title,
  required VaultE2EBackend backend,
  required Future<Uint8List?> Function() loadPlain,
}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => VaultShareSheet(docId: docId, title: title, backend: backend, loadPlain: loadPlain),
  );
}

String sniffMime(Uint8List b) {
  bool at(List<int> sig) {
    if (b.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[i] != sig[i]) return false;
    }
    return true;
  }

  if (at([0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (at([0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (at([0x25, 0x50, 0x44, 0x46])) return 'application/pdf';
  if (b.length > 12 && at([0x52, 0x49, 0x46, 0x46]) && b[8] == 0x57 && b[9] == 0x45) return 'image/webp';
  return 'application/octet-stream';
}

class VaultShareSheet extends StatefulWidget {
  final int docId;
  final String title;
  final VaultE2EBackend backend;
  final Future<Uint8List?> Function() loadPlain;
  const VaultShareSheet(
      {super.key, required this.docId, required this.title, required this.backend, required this.loadPlain});

  @override
  State<VaultShareSheet> createState() => _VaultShareSheetState();
}

class _VaultShareSheetState extends State<VaultShareSheet> {
  static const hoursChoices = [1, 24, 72, 168];
  static const opensChoices = [1, 3, 10];
  int _hours = 24;
  int _opens = 1;
  bool _busy = false;
  String? _link;
  String? _error;
  List<Map<String, dynamic>> _links = const [];

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  Future<void> _loadLinks() async {
    try {
      final l = await widget.backend.shares(widget.docId);
      if (mounted) setState(() => _links = l);
    } catch (_) {}
  }

  String _hoursLabel(AppLocalizations t, int h) => switch (h) {
        1 => t.vaultShare1h,
        24 => t.vaultShare1d,
        72 => t.vaultShare3d,
        _ => t.vaultShare7d,
      };

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plain = await widget.loadPlain();
      if (plain == null) {
        _error = t.vaultShareNoFile;
      } else if (plain.length > VaultE2E.maxShareBytes) {
        _error = t.vaultShareTooBig;
      } else {
        final mime = sniffMime(plain);
        final ext = switch (mime) {
          'image/jpeg' => 'jpg',
          'image/png' => 'png',
          'image/webp' => 'webp',
          'application/pdf' => 'pdf',
          _ => 'bin',
        };
        final seal = await VaultE2E.sealForShare(plain,
            mime: mime, name: 'document.$ext', title: widget.title);
        final r = await widget.backend.createShare(widget.docId, _hours, _opens, seal.blob);
        final base = '${r['url'] ?? ''}';
        _link = '$base#${seal.fragment}';
      }
    } catch (e) {
      _error = '$e'.isEmpty ? t.vaultE2eFailed : '$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _loadLinks();
  }

  Future<void> _revoke(Map<String, dynamic> l) async {
    try {
      await widget.backend.revokeShare((l['id'] as num).toInt());
    } catch (_) {}
    _loadLinks();
  }

  String _until(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    return DateFormat('d MMM, h:mm a', Localizations.localeOf(context).languageCode).format(d);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final link = _link;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(t.vaultShareLink, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.vaultShareLinkSub, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          Text(t.vaultShareFor, style: AType.titleSmall),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final h in hoursChoices)
              ChoiceChip(
                key: Key('share_h_$h'),
                label: Text(_hoursLabel(t, h)),
                selected: _hours == h,
                onSelected: _busy ? null : (_) => setState(() => _hours = h),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.vaultShareOpens, style: AType.titleSmall),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final o in opensChoices)
              ChoiceChip(
                key: Key('share_o_$o'),
                label: Text(fmtInt(context, o)),
                selected: _opens == o,
                onSelected: _busy ? null : (_) => setState(() => _opens = o),
              ),
          ]),
          const SizedBox(height: Gap.md),
          if (link == null)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                key: const Key('share_create'),
                onPressed: _busy ? null : _create,
                icon: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_link_rounded),
                label: Text(t.vaultShareCreate),
              ),
            )
          else ...[
            Text(t.vaultShareReady, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            SelectableText(link, key: const Key('share_link'), style: AType.bodySmall),
            Wrap(spacing: Gap.sm, children: [
              FilledButton.icon(
                key: const Key('share_send'),
                onPressed: () => Share.share(t.vaultShareText(link)),
                icon: const Icon(Icons.send_rounded),
                label: Text(t.vaultShareSend),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: link));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.vaultShareCopied)));
                },
                icon: const Icon(Icons.copy_rounded),
                label: Text(t.vaultShareCopy),
              ),
            ]),
          ],
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_links.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Text(t.vaultShareActive, style: AType.titleSmall),
            for (final l in _links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(l['state'] == 'open' ? Icons.link_rounded : Icons.link_off_rounded),
                title: Text(l['state'] == 'open'
                    ? t.vaultShareRowState(
                        fmtInt(context, (l['opens'] as num?)?.toInt() ?? 0),
                        fmtInt(context, (l['max_opens'] as num?)?.toInt() ?? 0),
                        _until(l['expires_at'] as String?))
                    : t.vaultShareEnded),
                trailing: l['state'] == 'open'
                    ? TextButton(onPressed: () => _revoke(l), child: Text(t.vaultShareStop))
                    : null,
              ),
          ],
        ]),
      ),
    );
  }
}
