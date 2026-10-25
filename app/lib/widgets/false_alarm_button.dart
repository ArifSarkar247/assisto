import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../antitheft_api.dart';
import '../l10n/app_localizations.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';

/// at-falsealarm — the owner's "It was me / false alarm" action.
///
/// Shown ONLY while a theft signal / freeze is active ([shouldShow]). It needs
/// the Security PIN, which the SERVER verifies (a wrong PIN counts toward the
/// wrong-PIN lock — a thief cannot use this to undo a real alarm). On success
/// the freeze is lifted, recent theft signals are removed (kept in the audit
/// trail), the engine re-records its SIM baseline and the approved family get
/// one short all-clear. [onCleared] lets the host screen reload.
class FalseAlarmButton extends StatefulWidget {
  const FalseAlarmButton({
    super.key,
    this.onCleared,
    this.askPin,
    this.send,
  });

  final VoidCallback? onCleared;

  /// Test seams (default: the Security PIN modal / the real endpoint).
  final Future<String?> Function(BuildContext context)? askPin;
  final Future<Map<String, dynamic>> Function(String pin)? send;

  /// Is a theft signal or freeze active in this state map? Understands the
  /// engine state ({frozen, theft_signal}), security/state ({frozen_until})
  /// and security/lost-phone ({frozen}).
  static bool shouldShow(Map<String, dynamic> s) {
    if (s['frozen'] == true || s['theft_signal'] == true) return true;
    final fu = s['frozen_until'];
    if (fu is String && fu.isNotEmpty) {
      final dt = DateTime.tryParse(fu);
      return dt != null && dt.isAfter(DateTime.now());
    }
    return false;
  }

  @override
  State<FalseAlarmButton> createState() => _FalseAlarmButtonState();
}

class _FalseAlarmButtonState extends State<FalseAlarmButton> {
  bool _busy = false;

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _run() async {
    final tr = AppLocalizations.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.atfaConfirmTitle),
        content: Text(tr.atfaConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
              key: const Key('atfa-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.atfaConfirmYes)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final pin = await (widget.askPin?.call(context) ??
        const SecurityGuard().askPin(context, tr));
    if (pin == null || pin.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final send = widget.send ??
          (String p) => context.read<AppState>().api.engineFalseAlarm(pin: p);
      final r = await send(pin);
      final st = r['_status'] as int?;
      if (r['ok'] == true && (st == null || st < 400)) {
        final n = r['cleared'];
        _snack(n == 0 && r['frozen'] == false ? tr.atfaNothing : tr.atfaCleared);
        widget.onCleared?.call();
      } else if (st == 429 || r['reason'] == 'rate_limited') {
        _snack(tr.atfaRateLimited);
      } else if (r['locked'] == true) {
        _snack(tr.securityLockedOut);
      } else if (st == 403 || r['reason'] == 'bad_pin') {
        _snack(tr.securityBadPin);
      } else {
        _snack(tr.securityActionError);
      }
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(tr.atfaHint, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          key: const Key('atfa-button'),
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.verified_user_rounded),
          label: Text(tr.atfaButton, softWrap: true),
        ),
      ],
    );
  }
}
