import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/e2e.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Encrypted chat backup + recovery code + restore, and linked-devices entry
/// (M2 items 9 + 10).
///
/// BACKUP: the chat archive is serialized + SEALED on-device under a recovery
/// code (reusing crypto/e2e.dart KeyBackup — PBKDF2 -> ChaCha20-Poly1305). The
/// server stores ONLY the opaque sealed blob + non-secret KDF params (see
/// core/logic/circle_extras.build_backup_envelope / validate_backup_envelope).
/// The recovery code is shown ONCE to the user and NEVER sent to the server —
/// losing it means losing the backup (by design).
///
/// RESTORE: on a new phone the user enters the recovery code; KeyBackup.open
/// unseals the archive locally. A wrong code / tamper returns null.
///
/// LINKED DEVICES: item 10 is DESIGN now (owner_actions/linked_devices.md). The
/// tile shows the current device + a gated "web after mobile" state; the data
/// model lives in circle_extras.device_record / can_link_device.

/// Create-backup bottom sheet: generates a recovery code (KeyBackup) and shows
/// it once. The caller does the actual sealing + upload (it holds the archive
/// bytes + identity key).
class BackupSheet extends StatefulWidget {
  final int messageCount;
  /// Called with (recoveryCode, recoveryHint) once the user has saved the code.
  /// The caller seals the archive under [recoveryCode] via KeyBackup.seal and
  /// POSTs the circle_extras.build_backup_envelope payload.
  final void Function(String recoveryCode, String recoveryHint) onConfirm;
  const BackupSheet(
      {super.key, required this.messageCount, required this.onConfirm});

  @override
  State<BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<BackupSheet> {
  late String _code = KeyBackup.generateRecoveryCode();
  final _hint = TextEditingController();
  bool _savedAck = false;

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.circleExtrasBackup, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.circleExtrasBackupHint,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            Text(t.circleExtrasRecoveryCode,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: SelectableText(
                _code,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 20,
                    letterSpacing: 2),
              ),
            ),
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(t.circleExtrasCopyCode),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _code));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(t.circleExtrasCopied)));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: t.circleExtrasRecoveryCode,
                  onPressed: () =>
                      setState(() => _code = KeyBackup.generateRecoveryCode()),
                ),
              ],
            ),
            Text(t.circleExtrasRecoveryCodeHint,
                style: TextStyle(fontSize: 11, color: scheme.error)),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _hint,
              decoration: InputDecoration(
                labelText: t.circleExtrasRecoveryHintLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: Gap.md),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _savedAck,
              onChanged: (v) => setState(() => _savedAck = v ?? false),
              title: Text(t.circleExtrasRecoveryCodeHint, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: Gap.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _savedAck
                    ? () {
                        widget.onConfirm(_code, _hint.text.trim());
                        Navigator.of(context).maybePop();
                      }
                    : null,
                child: Text(t.circleExtrasCreateBackup),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Restore sheet: the user enters the recovery code; the caller unseals the
/// downloaded blob with KeyBackup.open. Returns the entered code via [onRestore];
/// the caller reports success/failure back through [errorText].
class RestoreSheet extends StatefulWidget {
  final ValueChanged<String> onRestore;
  final String? errorText;
  const RestoreSheet({super.key, required this.onRestore, this.errorText});

  @override
  State<RestoreSheet> createState() => _RestoreSheetState();
}

class _RestoreSheetState extends State<RestoreSheet> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.circleExtrasRestore, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.circleExtrasRestoreHint,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: t.circleExtrasRecoveryCode,
                border: const OutlineInputBorder(),
                errorText: widget.errorText,
                hintText: 'XXXX-XXXX-XXXX-XXXX',
              ),
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
            ),
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => widget.onRestore(_code.text.trim()),
                child: Text(t.circleExtrasRestore),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Linked-devices card (item 10, DESIGN). Shows the current device + a gated
/// "web after mobile" / link entry. The actual device list + link handshake is
/// wired by the integrator against /circle/devices (see
/// owner_actions/linked_devices.md and circle_extras.device_record).
class LinkedDevicesCard extends StatelessWidget {
  final String thisDeviceName;
  final int linkedCount;
  final VoidCallback? onLink;
  const LinkedDevicesCard({
    super.key,
    required this.thisDeviceName,
    this.linkedCount = 0,
    this.onLink,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(Icons.phone_android, color: scheme.primary),
          title: Text(t.circleExtrasThisDevice),
          subtitle: Text(thisDeviceName),
          trailing: const Icon(Icons.check_circle, color: Brand.success),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Text(t.circleExtrasLinkedDevicesHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: Gap.sm),
        ListTile(
          leading: const Icon(Icons.add_link),
          title: Text(t.circleExtrasLinkDevice),
          onTap: onLink,
        ),
        const SizedBox(height: Gap.md),
      ],
    );
  }
}
