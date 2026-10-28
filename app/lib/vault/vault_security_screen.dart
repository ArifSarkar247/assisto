// vault100 — "Security & storage": the honest protection model, recovery
// methods (recovery code on this phone + what the account can verify with),
// PIN change, fingerprint, and the offline copies' storage use.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../messaging/chat_lock.dart' show ChatLockAuth;
import '../theme.dart' show AType, Gap, Radii;
import '../widgets/ladder_common.dart' show fmtInt;
import 'vault_api.dart';
import 'vault_lock.dart';
import 'vault_lock_view.dart';
import 'vault_offline.dart';

/// Locale-aware size (Bangla digits): reuses the storage meter's units.
String vaultFmtBytes(BuildContext context, int bytes) {
  final t = AppLocalizations.of(context);
  const kb = 1024, mb = 1024 * 1024;
  String one(double v) {
    final r = (v * 10).round();
    final w = r ~/ 10, f = r % 10;
    return f == 0 ? fmtInt(context, w) : '${fmtInt(context, w)}.${fmtInt(context, f)}';
  }

  if (bytes >= mb) return t.storageUnitMb(one(bytes / mb));
  if (bytes >= kb) return t.storageUnitKb(fmtInt(context, (bytes / kb).round()));
  return t.storageUnitBytes(fmtInt(context, bytes));
}

class VaultSecurityScreen extends StatefulWidget {
  final VaultLock lock;
  final VaultOffline offline;
  final VaultBackend backend;
  const VaultSecurityScreen(
      {super.key, required this.lock, required this.offline, required this.backend});

  @override
  State<VaultSecurityScreen> createState() => _VaultSecurityScreenState();
}

class _VaultSecurityScreenState extends State<VaultSecurityScreen> {
  Map<String, dynamic>? _status;
  bool _statusFailed = false;
  bool _hasCode = false;
  bool _bio = false;
  int _offlineCount = 0;
  int _offlineBytes = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hasCode = await widget.lock.hasRecoveryCode();
    final bio = await widget.lock.biometricEnabled();
    final idx = await widget.offline.index();
    final bytes = await widget.offline.usageBytes();
    Map<String, dynamic>? st;
    var failed = false;
    try {
      st = await widget.backend.recoveryStatus();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _hasCode = hasCode;
      _bio = bio;
      _offlineCount = idx.length;
      _offlineBytes = bytes;
      _status = st;
      _statusFailed = failed;
      _loading = false;
    });
  }

  bool _on(String k) => _status?[k] == true;

  Future<void> _makeCode() async {
    final t = AppLocalizations.of(context);
    if (_hasCode) {
      final again = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          title: Text(t.vaultRecoveryCodeNew),
          content: Text(t.vaultRecoveryCodeReplaceWarn),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultRecoveryCodeNew)),
          ],
        ),
      );
      if (again != true) return;
    }
    final code = await widget.lock.newRecoveryCode();
    if (!mounted) return;
    if (code == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.vaultPinSaveFailed)));
      return;
    }
    await showVaultRecoveryCode(context, code);
    _load();
  }

  Future<void> _changePin() async {
    final t = AppLocalizations.of(context);
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (ctx) => _ChangePinPage(lock: widget.lock)));
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.vaultPinChanged)));
    }
  }

  Future<void> _toggleBio(bool on) async {
    final t = AppLocalizations.of(context);
    if (on) {
      final ok = await ChatLockAuth.biometric(t.vaultBioReason);
      if (!mounted) return;
      if (ok != true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok == null ? t.vaultBioUnavailable : t.vaultBioNotConfirmed)));
        return;
      }
    }
    await widget.lock.setBiometric(on);
    if (mounted) setState(() => _bio = on);
  }

  Future<void> _removeAll() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.vaultOfflineRemoveAll),
        content: Text(t.vaultOfflineRemoveAllConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultOfflineRemoveAll)),
        ],
      ),
    );
    if (ok != true) return;
    await widget.offline.removeAll();
    _load();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Semantics(header: true, child: Text(title, style: AType.titleMedium)),
      );

  Widget _check(bool ok, String label, String? hint) => ListTile(
        leading: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: ok ? Colors.green.shade700 : Theme.of(context).colorScheme.outline),
        title: Text(label),
        subtitle: hint == null ? null : Text(hint),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final anyAccount = _on('sms') || _on('email') || _on('password');
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultSecurityTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: Gap.xl), children: [
              if (!_hasCode && !anyAccount)
                Container(
                  key: const Key('vault_no_recovery_warn'),
                  margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(t.vaultNoRecoveryWarn,
                      style: AType.bodyMedium
                          .copyWith(color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              _section(t.vaultHowTitle),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final line in [t.vaultHowStored, t.vaultHowPin, t.vaultHowOffline, t.vaultHowRecover])
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(Icons.info_outline_rounded, size: 18)),
                        const SizedBox(width: Gap.sm),
                        Expanded(child: Text(line, style: AType.bodyMedium)),
                      ]),
                    ),
                ]),
              ),
              _section(t.vaultRecoverySection),
              ListTile(
                key: const Key('vault_rc_tile'),
                leading: const Icon(Icons.key_rounded),
                title: Text(t.vaultRecoveryCodeTitle),
                subtitle: Text(_hasCode ? t.vaultRecoveryCodeIsSet : t.vaultRecoveryCodeNotSet),
                trailing: TextButton(
                  onPressed: _makeCode,
                  child: Text(_hasCode ? t.vaultRecoveryCodeNew : t.vaultRecoveryCodeCreate),
                ),
              ),
              if (_statusFailed)
                ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: Text(t.vaultRecoverOffline),
                  trailing: TextButton(onPressed: _load, child: Text(t.retry)),
                )
              else ...[
                _check(_on('sms'), t.vaultMethodSms,
                    _on('sms') ? '${_status?['phone_masked'] ?? ''}' : t.vaultMethodSmsOff),
                _check(_on('email'), t.vaultMethodEmail,
                    _on('email') ? '${_status?['email_masked'] ?? ''}' : t.vaultMethodEmailOff),
                _check(_on('password'), t.vaultMethodPassword,
                    _on('password') ? null : t.vaultMethodPasswordOff),
              ],
              _section(t.vaultPinSection),
              ListTile(
                key: const Key('vault_change_pin'),
                leading: const Icon(Icons.pin_rounded),
                title: Text(t.vaultChangePin),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _changePin,
              ),
              SwitchListTile(
                key: const Key('vault_bio_switch'),
                secondary: const Icon(Icons.fingerprint_rounded),
                title: Text(t.vaultUseFingerprint),
                subtitle: Text(t.vaultFingerprintSub),
                value: _bio,
                onChanged: _toggleBio,
              ),
              _section(t.vaultOfflineSection),
              ListTile(
                key: const Key('vault_offline_usage'),
                leading: const Icon(Icons.sd_storage_rounded),
                title: Text(_offlineCount == 0
                    ? t.vaultOfflineNone
                    : t.vaultOfflineUsage(fmtInt(context, _offlineCount),
                        vaultFmtBytes(context, _offlineBytes))),
                subtitle: Text(t.vaultOfflineHowTo),
              ),
              if (_offlineCount > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      key: const Key('vault_offline_remove_all'),
                      onPressed: _removeAll,
                      icon: const Icon(Icons.delete_sweep_rounded),
                      label: Text(t.vaultOfflineRemoveAll),
                    ),
                  ),
                ),
            ]),
    );
  }
}

/// Show a fresh recovery code ONCE (copy + "I've written it down").
Future<void> showVaultRecoveryCode(BuildContext context, String code) {
  final t = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(t.vaultRecoveryCodeTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.vaultRecoveryCodeShowOnce, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        Center(
          child: SelectableText(code,
              key: const Key('vault_rc_value'),
              style: AType.titleLarge.copyWith(fontFamily: 'monospace', letterSpacing: 1.5)),
        ),
        const SizedBox(height: Gap.md),
        Text(t.vaultRecoveryCodeWarn, style: AType.bodySmall),
      ]),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(t.copied)));
            }
          },
          child: Text(t.copy),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(t.vaultRecoveryCodeSaved)),
      ],
    ),
  );
}

class _ChangePinPage extends StatefulWidget {
  final VaultLock lock;
  const _ChangePinPage({required this.lock});
  @override
  State<_ChangePinPage> createState() => _ChangePinPageState();
}

class _ChangePinPageState extends State<_ChangePinPage> {
  bool _verified = false;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultChangePin)),
      body: _verified
          ? VaultLockView(
              key: const ValueKey('set'),
              lock: widget.lock,
              mode: VaultLockMode.set,
              notice: t.vaultChangePinNew,
              onUnlocked: () => Navigator.of(context).pop(true))
          : VaultLockView(
              key: const ValueKey('enter'),
              lock: widget.lock,
              mode: VaultLockMode.enter,
              notice: t.vaultChangePinCurrent,
              onUnlocked: () => setState(() => _verified = true)),
    );
  }
}
