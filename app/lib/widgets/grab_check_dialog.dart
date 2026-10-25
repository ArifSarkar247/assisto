import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/antitheft_service.dart';
import '../services/security_guard.dart';

/// grab-guard (owner 25 Oct) — on the OWN phone a detected grab first asks
/// "Was this you?" (native heads-up notification; this dialog when Assisto is
/// opened). The engine holds the grab for 60 s:
///   * "Yes, it was me" -> Security PIN, verified by the SERVER (POST
///     security/engine/false-alarm, same as build 221's "It was me"; a wrong
///     PIN counts toward the lock, so a thief cannot use it) -> the pending
///     grab is dropped. If it was already sent, that endpoint clears it and
///     the family gets the all-clear.
///   * "No, alert my family now" -> sent at once.
///   * no answer -> the engine sends it after 60 s as usual.
class GrabCheck {
  GrabCheck._();

  static bool _showing = false;

  /// Test seams.
  @visibleForTesting
  static Future<int?> Function() pending = AntiTheftService.grabPendingMs;
  @visibleForTesting
  static Future<bool> Function() cancelNative = AntiTheftService.grabCancel;
  @visibleForTesting
  static Future<void> Function() sendNow = AntiTheftService.grabSendNow;

  @visibleForTesting
  static void resetForTest() => _showing = false;

  /// App open / resume: show the dialog if a grab is waiting. [send] posts
  /// the PIN to security/engine/false-alarm. Never throws.
  static Future<void> maybeShow(
    BuildContext context, {
    required Future<Map<String, dynamic>> Function(String pin) send,
    Future<String?> Function(BuildContext context)? askPin,
  }) async {
    if (_showing) return;
    try {
      final left = await pending();
      if (left == null || !context.mounted) return;
      _showing = true;
      final tr = AppLocalizations.of(context);
      final mine = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.back_hand_outlined),
          title: Text(tr.grabAskTitle),
          content: Text(tr.grabAskBody),
          actions: [
            TextButton(
                key: const Key('grab-no'),
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr.grabAskNo, softWrap: true)),
            FilledButton(
                key: const Key('grab-yes'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr.grabAskYes, softWrap: true)),
          ],
        ),
      );
      // back button: nothing (the engine sends it when the 60 s are up)
      if (mine == null || !context.mounted) return;
      if (!mine) {
        await sendNow();
        if (context.mounted) _snack(context, tr.grabSentNow);
        return;
      }
      final pin = await (askPin?.call(context) ??
          const SecurityGuard().askPin(context, tr));
      if (pin == null || pin.isEmpty || !context.mounted) return;
      final r = await send(pin);
      if (!context.mounted) return;
      final st = r['_status'] as int?;
      if (r['ok'] == true && (st == null || st < 400)) {
        final dropped = await cancelNative();
        if (context.mounted) {
          _snack(context, dropped ? tr.grabCleared : tr.atfaCleared);
        }
      } else if (st == 429 || r['reason'] == 'rate_limited') {
        _snack(context, tr.atfaRateLimited);
      } else if (r['locked'] == true) {
        _snack(context, tr.securityLockedOut);
      } else if (st == 403 || r['reason'] == 'bad_pin') {
        _snack(context, tr.securityBadPin);
      } else {
        _snack(context, tr.securityActionError);
      }
    } catch (_) {
      try {
        if (context.mounted) {
          _snack(context, AppLocalizations.of(context).securityActionError);
        }
      } catch (_) {}
    } finally {
      _showing = false;
    }
  }

  static void _snack(BuildContext context, String m) {
    try {
      ScaffoldMessenger.maybeOf(context)
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(m)));
    } catch (_) {}
  }
}
