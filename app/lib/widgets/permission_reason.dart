import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The runtime permissions we show a reason for before requesting.
enum PermKind { mic, location, camera }

/// Shows a clear reason (in the user's language) BEFORE a runtime permission is
/// requested, so the user understands why — better grant rate, Play-policy
/// friendly. Returns true if the user chose to continue.
Future<bool> showPermissionReason(BuildContext context, PermKind kind) async {
  final t = AppLocalizations.of(context);
  final (IconData icon, String reason) = switch (kind) {
    PermKind.mic => (Icons.mic_none, t.permMic),
    PermKind.location => (Icons.location_on_outlined, t.permLocation),
    PermKind.camera => (Icons.photo_camera_outlined, t.permCamera),
  };
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        icon: Icon(icon, size: 36, color: scheme.primary),
        content: Text(reason,
            textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.notNow)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.continueWord)),
        ],
      );
    },
  );
  return ok == true;
}

/// Small helper for a brand-styled empty permission prompt inside a screen.
Widget permissionBlock(BuildContext context,
    {required IconData icon, required String text, required VoidCallback onTap,
    required String button}) {
  final scheme = Theme.of(context).colorScheme;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(Gap.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: scheme.primary),
        const SizedBox(height: Gap.lg),
        Text(text, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        FilledButton(onPressed: onTap, child: Text(button)),
      ]),
    ),
  );
}
