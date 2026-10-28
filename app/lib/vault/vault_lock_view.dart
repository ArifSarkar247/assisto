// vault100 — full-screen vault lock: set a PIN (twice) or unlock with PIN /
// fingerprint, wrong-PIN back-off with a live countdown, and "Forgot PIN?".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../messaging/chat_lock.dart' show ChatLockAuth;
import '../theme.dart' show AType, Gap;
import '../widgets/ladder_common.dart' show fmtInt;
import 'vault_lock.dart';

enum VaultLockMode { set, enter }

class VaultLockView extends StatefulWidget {
  final VaultLock lock;
  final VaultLockMode mode;
  final VoidCallback onUnlocked;
  final VoidCallback? onForgot;

  /// Shown above the PIN boxes when setting a NEW PIN after a recovery.
  final String? notice;
  const VaultLockView(
      {super.key,
      required this.lock,
      required this.mode,
      required this.onUnlocked,
      this.onForgot,
      this.notice});

  @override
  State<VaultLockView> createState() => _VaultLockViewState();
}

/// "1 min 05 s" style, Bangla digits in bn.
String vaultFmtWait(BuildContext context, Duration d) {
  final t = AppLocalizations.of(context);
  final s = d.inSeconds < 1 ? 1 : d.inSeconds;
  if (s < 60) return t.vaultWaitSeconds(fmtInt(context, s));
  final m = (s / 60).ceil();
  return t.vaultWaitMinutes(fmtInt(context, m));
}

class _VaultLockViewState extends State<VaultLockView> {
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _bio = false;
  Duration? _locked;
  int _triesLeft = VaultLock.freeTries;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (widget.mode == VaultLockMode.enter) {
      final bio = await widget.lock.biometricEnabled();
      final locked = await widget.lock.lockedFor();
      final left = await widget.lock.triesLeftBeforeLockout();
      if (!mounted) return;
      setState(() {
        _bio = bio;
        _locked = locked;
        _triesLeft = left;
      });
      _armTick();
      if (bio && locked == null) _tryBio();
    }
  }

  void _armTick() {
    _tick?.cancel();
    if (_locked == null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      final l = await widget.lock.lockedFor();
      if (!mounted) return;
      setState(() => _locked = l);
      if (l == null) {
        _tick?.cancel();
        setState(() => _error = null);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pin.dispose();
    _pin2.dispose();
    super.dispose();
  }

  Future<void> _tryBio() async {
    final t = AppLocalizations.of(context);
    final ok = await ChatLockAuth.biometric(t.vaultBioReason);
    if (!mounted) return;
    if (ok == true) {
      widget.onUnlocked();
    } else if (ok == null) {
      setState(() => _error = t.vaultBioUnavailable);
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final pin = _pin.text.trim();
    if (_busy) return;
    if (widget.mode == VaultLockMode.set) {
      if (!VaultLock.validPin(pin)) {
        setState(() => _error = t.vaultPinLengthHint);
        return;
      }
      if (pin != _pin2.text.trim()) {
        setState(() => _error = t.vaultPinMismatch);
        return;
      }
      setState(() => _busy = true);
      final ok = await widget.lock.setPin(pin);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        widget.onUnlocked();
      } else {
        setState(() => _error = t.vaultPinSaveFailed);
      }
      return;
    }
    if (pin.isEmpty) return;
    setState(() => _busy = true);
    final r = await widget.lock.check(pin);
    if (!mounted) return;
    _pin.clear();
    final locked = await widget.lock.lockedFor();
    final left = await widget.lock.triesLeftBeforeLockout();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _locked = locked;
      _triesLeft = left;
      _error = switch (r) {
        PinCheck.ok => null,
        PinCheck.wrong => t.vaultWrongPinLeft(fmtInt(context, left)),
        PinCheck.lockedOut => t.vaultTooManyTries,
        PinCheck.noPin => t.vaultWrongPin,
      };
    });
    if (r == PinCheck.ok) {
      widget.onUnlocked();
    } else {
      _armTick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final setting = widget.mode == VaultLockMode.set;
    final locked = _locked;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(setting ? Icons.lock_outline_rounded : Icons.lock_rounded,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: Gap.md),
              Semantics(
                header: true,
                child: Text(setting ? t.vaultSetPinTitle : t.vaultLockedTitle,
                    textAlign: TextAlign.center, style: AType.titleLarge),
              ),
              const SizedBox(height: Gap.sm),
              Text(widget.notice ?? (setting ? t.vaultSetPinInfo : t.vaultUnlockInfo),
                  textAlign: TextAlign.center, style: AType.bodyMedium),
              const SizedBox(height: Gap.lg),
              TextField(
                key: const Key('vault_pin'),
                controller: _pin,
                autofocus: true,
                obscureText: true,
                enabled: locked == null,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: VaultLock.maxPin,
                textAlign: TextAlign.center,
                style: AType.titleLarge.copyWith(letterSpacing: 8),
                decoration: InputDecoration(
                    labelText: setting ? t.vaultPinLengthHint : t.vaultEnterPinHint,
                    counterText: ''),
                onSubmitted: (_) => setting ? null : _submit(),
              ),
              if (setting) ...[
                const SizedBox(height: Gap.sm),
                TextField(
                  key: const Key('vault_pin2'),
                  controller: _pin2,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: VaultLock.maxPin,
                  textAlign: TextAlign.center,
                  style: AType.titleLarge.copyWith(letterSpacing: 8),
                  decoration: InputDecoration(labelText: t.vaultPinConfirm, counterText: ''),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null || locked != null) ...[
                const SizedBox(height: Gap.sm),
                Semantics(
                  liveRegion: true,
                  child: Text(
                      locked != null
                          ? '${t.vaultTooManyTries} ${t.vaultTryAgainIn(vaultFmtWait(context, locked))}'
                          : _error!,
                      textAlign: TextAlign.center,
                      style: AType.bodyMedium
                          .copyWith(color: Theme.of(context).colorScheme.error)),
                ),
              ] else if (!setting && _triesLeft < VaultLock.freeTries) ...[
                const SizedBox(height: Gap.sm),
                Text(t.vaultTriesLeft(fmtInt(context, _triesLeft)),
                    textAlign: TextAlign.center, style: AType.bodySmall),
              ],
              const SizedBox(height: Gap.md),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  key: const Key('vault_pin_submit'),
                  onPressed: (_busy || locked != null) ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(setting ? t.vaultSetPinButton : t.vaultUnlockButton),
                ),
              ),
              if (!setting && _bio) ...[
                const SizedBox(height: Gap.sm),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: locked != null ? null : _tryBio,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(t.vaultUseFingerprint),
                  ),
                ),
              ],
              if (!setting && widget.onForgot != null) ...[
                const SizedBox(height: Gap.sm),
                SizedBox(
                  height: 48,
                  child: TextButton(
                    key: const Key('vault_forgot'),
                    onPressed: widget.onForgot,
                    child: Text(t.vaultForgotPin),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
