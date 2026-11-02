import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../business_khata_api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show showActionFailed;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';

/// bizbar: "Is my khata safe?" — the honest answer (it lives on the server,
/// a new phone gets it back by logging in, two phones can share one shop)
/// plus the owner's own spreadsheet copy (CSV, opens in Excel / Google
/// Sheets with Bangla intact). TallyKhata/Hishabee keep data on their servers
/// too; Vyapar's local backup file is the model for the copy.
Future<void> showKhataBackupSheet(BuildContext context, {required int businessId}) =>
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BackupSheet(businessId: businessId),
    );

class _BackupSheet extends StatefulWidget {
  final int businessId;
  const _BackupSheet({required this.businessId});
  @override
  State<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<_BackupSheet> {
  bool _busy = false;

  Future<void> _export() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.khataExport(widget.businessId);
      final dir = await getTemporaryDirectory();
      final name = '${r['filename'] ?? 'assisto-khata.csv'}'
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final f = File('${dir.path}/$name');
      // UTF-8 BOM: Excel then shows Bangla instead of garbage
      await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('${r['csv'] ?? ''}')],
          flush: true);
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')],
          text: t.bbBackupShareText);
    } catch (e) {
      if (mounted) showActionFailed(context, 'khata.export', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget point(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: AssistoTokens.of(context).success),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(s)),
          ]),
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.bbBackupTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.md),
          point(Icons.cloud_done_rounded, t.bbBackupServer),
          point(Icons.phonelink_rounded, t.bbBackupNewPhone),
          point(Icons.groups_rounded, t.bbBackupStaff),
          point(Icons.wifi_off_rounded, t.bbBackupOffline),
          const SizedBox(height: Gap.sm),
          Text(t.bbBackupCopyHow, style: AType.bodySmall.copyWith(color: muted)),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('bb-backup-export'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _export,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.table_view_rounded),
              label: Text(t.bbBackupExport, maxLines: 2, textAlign: TextAlign.center),
            ),
          ),
        ]),
      ),
    );
  }
}
