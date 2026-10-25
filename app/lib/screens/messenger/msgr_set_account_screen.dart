import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';
import 'msgr_set_change_number_screen.dart';
import 'msgr_set_twostep_screen.dart';

/// Account settings for the hub: two-step verification PIN, change number,
/// request my data export (REUSES the existing /export raw dump), and delete
/// account (REUSES AppState.deleteAccount — same server call the main Settings
/// screen uses). No new export/delete logic is duplicated; the two genuinely
/// new surfaces (two-step, change number) live in their own screens.
class MsgrSetAccountScreen extends StatelessWidget {
  const MsgrSetAccountScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => screen));

  // ---- data export: reuse the existing raw dump (ApiClient.exportRaw) ----
  Future<void> _exportData(BuildContext context) async {
    final app = context.read<AppState>();
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await app.api.exportRaw();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/assisto-export.json');
      await f.writeAsString(raw);
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.msgrSetExportTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                raw.length > 4000 ? '${raw.substring(0, 4000)}…' : raw,
                style:
                    const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(t.ok)),
          ],
        ),
      );
      messenger.showSnackBar(
          SnackBar(content: Text(t.msgrSetExportSaved(f.path))));
    } catch (_) {
      messenger
          .showSnackBar(SnackBar(content: Text(t.msgrSetExportFailed)));
    }
  }

  // ---- delete account: reuse AppState.deleteAccount (same as main Settings) -
  Future<void> _deleteAccount(BuildContext context) async {
    final app = context.read<AppState>();
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.msgrSetDeleteTitle),
        content: Text(t.msgrSetDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.msgrSetDeleteConfirm),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await app.deleteAccount();
      } catch (_) {
        messenger.showSnackBar(
            SnackBar(content: Text(t.msgrSetDeleteFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetAccount)),
      body: ListView(
        children: [
          MsgrSetRow(
            icon: Icons.pin_rounded,
            title: t.msgrSetTwoStepTitle,
            subtitle: t.msgrSetTwoStepRowSub,
            onTap: () => _open(context, const MsgrSetTwoStepScreen()),
          ),
          MsgrSetRow(
            icon: Icons.swap_horiz_rounded,
            title: t.msgrSetChangeNumberTitle,
            subtitle: t.msgrSetChangeNumberRowSub,
            onTap: () => _open(context, const MsgrSetChangeNumberScreen()),
          ),
          const Divider(),
          MsgrSetRow(
            icon: Icons.download_rounded,
            title: t.msgrSetRequestData,
            subtitle: t.msgrSetRequestDataSub,
            onTap: () => _exportData(context),
          ),
          const Divider(),
          MsgrSetRow(
            icon: Icons.delete_forever_rounded,
            title: t.msgrSetDeleteTitle,
            subtitle: t.msgrSetDeleteRowSub,
            color: scheme.error,
            onTap: () => _deleteAccount(context),
          ),
        ],
      ),
    );
  }
}
