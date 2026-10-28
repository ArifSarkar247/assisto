// vault100 — "Forgot PIN?": prove it is you, then set a new PIN.
//
// Methods (whichever this account has right now — GET vault/recovery/status):
//   * a 6-digit code to the account's own number (SMS) or verified email —
//     the shared OTP step (purpose vault_reset), then POST vault/recovery/verify
//   * the account password
//   * the RECOVERY CODE kept (as a hash) on this phone — works with no internet
// Only the proof / password goes to the server; the PIN and the recovery code
// never do. Documents are never lost: they are not encrypted with the PIN.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../otp_api.dart';
import '../screens/otp/otp_verify_screen.dart';
import '../theme.dart' show AType, Gap, Radii;
import 'vault_api.dart';
import 'vault_lock.dart';
import 'vault_lock_view.dart' show vaultFmtWait;

class VaultRecoveryScreen extends StatefulWidget {
  final VaultLock lock;
  final VaultBackend backend;
  final OtpBackend? otpBackend;
  const VaultRecoveryScreen(
      {super.key, required this.lock, required this.backend, this.otpBackend});

  /// Resolves true when the PIN was cleared (caller asks for a new one).
  static Future<bool> run(BuildContext context,
          {required VaultLock lock, required VaultBackend backend, OtpBackend? otpBackend}) async =>
      (await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => VaultRecoveryScreen(
              lock: lock, backend: backend, otpBackend: otpBackend)))) ==
      true;

  @override
  State<VaultRecoveryScreen> createState() => _VaultRecoveryScreenState();
}

class _VaultRecoveryScreenState extends State<VaultRecoveryScreen> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _offline = false;
  bool _hasCode = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offline = false;
    });
    final hasCode = await widget.lock.hasRecoveryCode();
    Map<String, dynamic>? st;
    var offline = false;
    try {
      st = await widget.backend.recoveryStatus();
    } catch (_) {
      offline = true;
    }
    if (!mounted) return;
    setState(() {
      _hasCode = hasCode;
      _status = st;
      _offline = offline;
      _loading = false;
    });
  }

  bool _on(String k) => _status?[k] == true;

  Future<void> _done() async {
    await widget.lock.clearPin();
    if (mounted) Navigator.of(context).pop(true);
  }

  String _serverMsg(Map<String, dynamic> r, AppLocalizations t) {
    final m = '${r['message'] ?? ''}'.trim();
    if (m.isNotEmpty) return m;
    return t.vaultRecoverFailed;
  }

  Future<void> _viaCode() async {
    final t = AppLocalizations.of(context);
    final otp = widget.otpBackend;
    if (otp == null) return;
    final proof = await OtpVerifyScreen.run(context,
        backend: otp,
        purpose: 'vault_reset',
        title: t.vaultRecoverOtpTitle,
        intro: t.vaultRecoverOtpIntro);
    if (proof == null || !mounted) return;
    await _verify({'method': 'otp', 'otp_proof': proof});
  }

  Future<void> _verify(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    Map<String, dynamic> r;
    try {
      r = await widget.backend.recoveryVerify(body);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t.vaultRecoverNoNet;
        });
      }
      return;
    }
    if (!mounted) return;
    final st = (r['_status'] as int?) ?? 200;
    if (st >= 200 && st < 300 && r['ok'] == true) {
      setState(() => _busy = false);
      await _done();
      return;
    }
    setState(() {
      _busy = false;
      _error = _serverMsg(r, t);
    });
  }

  Future<void> _viaPassword() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.vaultRecoverPasswordTitle),
        content: TextField(
          key: const Key('vault_recover_password'),
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(labelText: t.vaultRecoverPasswordLabel),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultVerify)),
        ],
      ),
    );
    final pw = ctrl.text;
    ctrl.dispose();
    if (ok != true || pw.isEmpty || !mounted) return;
    await _verify({'method': 'password', 'password': pw});
  }

  Future<void> _viaRecoveryCode() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.vaultRecoveryCodeEnterTitle),
        content: TextField(
          key: const Key('vault_recover_code'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t.vaultRecoveryCodeLabel,
              hintText: 'XXXX-XXXX-XXXX-XXXX'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultVerify)),
        ],
      ),
    );
    final code = ctrl.text;
    ctrl.dispose();
    if (ok != true || code.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    final r = await widget.lock.useRecoveryCode(code);
    if (!mounted) return;
    if (r == PinCheck.ok) {
      setState(() => _busy = false);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    final wait = await widget.lock.codeLockedFor();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = wait != null
          ? '${t.vaultTooManyTries} ${t.vaultTryAgainIn(vaultFmtWait(context, wait))}'
          : t.vaultRecoveryCodeWrong;
    });
  }

  Widget _option(
      {required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback? onTap}) {
    return Card(
      child: ListTile(
        key: key,
        minVerticalPadding: Gap.md,
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: !_busy && onTap != null,
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final codeTargets = <String>[
      if (_on('sms')) '${_status?['phone_masked'] ?? ''}',
      if (_on('email')) '${_status?['email_masked'] ?? ''}',
    ].where((s) => s.isNotEmpty).join(' / ');
    final anyServer = _on('sms') || _on('email') || _on('password');
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultForgotPin)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
              Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.verified_user_rounded,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.vaultRecoverSafeTitle,
                          style: AType.titleMedium.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onPrimaryContainer)),
                      const SizedBox(height: Gap.xs),
                      Text(t.vaultRecoverSafeBody,
                          style: AType.bodyMedium.copyWith(
                              color: Theme.of(context).colorScheme.onPrimaryContainer)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: Gap.lg),
              Text(t.vaultRecoverChoose, style: AType.titleMedium),
              const SizedBox(height: Gap.sm),
              if (_on('sms') || _on('email'))
                _option(
                    key: const Key('vault_recover_otp'),
                    icon: Icons.sms_rounded,
                    title: t.vaultRecoverByCode,
                    subtitle: codeTargets.isEmpty ? null : t.vaultRecoverCodeTo(codeTargets),
                    onTap: widget.otpBackend == null ? null : _viaCode),
              if (_on('password'))
                _option(
                    key: const Key('vault_recover_pw'),
                    icon: Icons.password_rounded,
                    title: t.vaultRecoverByPassword,
                    onTap: _viaPassword),
              if (_hasCode)
                _option(
                    key: const Key('vault_recover_rc'),
                    icon: Icons.key_rounded,
                    title: t.vaultRecoverByRecoveryCode,
                    subtitle: t.vaultRecoverByRecoveryCodeSub,
                    onTap: _viaRecoveryCode),
              if (_offline) ...[
                const SizedBox(height: Gap.sm),
                ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: Text(t.vaultRecoverOffline),
                  trailing: TextButton(onPressed: _load, child: Text(t.retry)),
                ),
              ],
              if (!_offline && !anyServer && !_hasCode)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Text(t.vaultRecoverNone, style: AType.bodyMedium),
                  ),
                ),
              if ((_status?['resets_left_today'] as num?) == 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(t.vaultRecoverCapToday, style: AType.bodySmall),
                ),
              if (_error != null) ...[
                const SizedBox(height: Gap.md),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!,
                      style: AType.bodyMedium
                          .copyWith(color: Theme.of(context).colorScheme.error)),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: Gap.md),
                const Center(child: CircularProgressIndicator()),
              ],
              const SizedBox(height: Gap.lg),
              Text(t.vaultRecoverNeverPin,
                  style: AType.bodySmall),
            ]),
    );
  }
}
