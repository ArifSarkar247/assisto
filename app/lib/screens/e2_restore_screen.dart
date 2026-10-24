import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../crypto/key_backup.dart';
import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show localDigits;
import '../theme.dart';
import '../widgets/password_field.dart';

/// e2e-recover — shown ONCE after sign-in on a new install / new phone when a
/// PIN-protected chat-key backup exists, BEFORE a new key is made: with the
/// right Security PIN the SAME key comes back (old chats open, contacts see
/// no security-code change). Skip = a new key; contacts' phones then
/// re-send the history. Pops with true when restored.
class E2RestoreScreen extends StatefulWidget {
  const E2RestoreScreen({super.key, required this.service, this.meta});
  final KeyBackupService service;
  final Map<String, dynamic>? meta;

  @override
  State<E2RestoreScreen> createState() => _E2RestoreScreenState();
}

class _E2RestoreScreenState extends State<E2RestoreScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final pin = _pin.text.trim();
    if (pin.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.service.restore(pin, meta: widget.meta);
    if (!mounted) return;
    switch (r.outcome) {
      case RestoreOutcome.restored:
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(t.e2rRestored)));
        Navigator.of(context).pop(true);
        return;
      case RestoreOutcome.wrongPin:
        _error = r.attemptsLeft > 0
            ? t.e2rWrongPin(localDigits('${r.attemptsLeft}', lang))
            : t.e2rLockedLater;
      case RestoreOutcome.locked:
        final u = r.lockedUntil;
        _error = u == null
            ? t.e2rLockedLater
            : t.e2rLocked(localDigits(
                DateFormat('d MMM, h:mm a', lang == 'bn' ? 'bn' : 'en')
                    .format(u),
                lang));
      case RestoreOutcome.noBackup:
        Navigator.of(context).pop(false);
        return;
      case RestoreOutcome.failed:
        _error = t.e2rFailed;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.e2rRestoreTitle),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Icon(Icons.lock_reset, size: 56, color: scheme.primary),
              const SizedBox(height: Gap.md),
              Text(t.e2rRestoreBody, style: tt.bodyLarge),
              const SizedBox(height: Gap.lg),
              ObscureTextField(
                key: const Key('e2r-pin'),
                controller: _pin,
                keyboardType: TextInputType.number,
                maxLength: 8,
                autofocus: true,
                enabled: !_busy,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: t.e2rPinLabel),
                onSubmitted: (_) => _restore(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(_error!,
                      key: const Key('e2r-error'),
                      style: TextStyle(color: scheme.error)),
                ),
              const SizedBox(height: Gap.md),
              FilledButton(
                key: const Key('e2r-restore'),
                onPressed: _busy ? null : _restore,
                child: Text(_busy ? t.e2rRestoring : t.e2rRestoreButton),
              ),
              const SizedBox(height: Gap.sm),
              TextButton(
                key: const Key('e2r-skip'),
                onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                child: Text(t.e2rSkip),
              ),
              const SizedBox(height: Gap.sm),
              Text(t.e2rSkipNote,
                  style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.sm),
              Text(t.e2rPinHonest,
                  style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
