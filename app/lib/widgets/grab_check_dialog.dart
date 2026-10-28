import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/antitheft_service.dart';
import '../services/security_guard.dart';
import '../services/intruder_snap.dart'; // at100

/// grab-guard (owner 25 Oct) / antitheft2 (owner 27 Oct) — on the OWN phone
/// a detected grab first asks "Are you OK?" (at2OkTitle, bn + en) (native heads-up
/// notification; this dialog when Assisto is opened). The engine has
/// ALREADY sent the grab to the server, which HOLDS it for 60 s:
///   * "I'm OK" -> Security PIN, verified by the SERVER (POST
///     security/engine/false-alarm; a wrong PIN counts toward the lock) ->
///     the held grab is dropped, nobody is told. A WRONG PIN escalates it at
///     once (the server does that itself).
///   * "I need help" -> POST security/engine/escalate: the trusted contacts
///     are alerted now.
///   * no answer -> the server escalates when the 60 s are up (even if the
///     phone was switched off meanwhile).
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
    Future<Map<String, dynamic>> Function(String reason)? escalate,
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
          title: Text(tr.at2OkTitle),
          content: SingleChildScrollView(child: Text(tr.at2OkBody)),
          actions: [
            TextButton(
                key: const Key('grab-no'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr.at2OkNo, softWrap: true)),
            FilledButton(
                key: const Key('grab-yes'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr.at2OkYes, softWrap: true)),
          ],
        ),
      );
      // back button: nothing (the engine sends it when the 60 s are up)
      if (mine == null || !context.mounted) return;
      if (!mine) {
        await sendNow();
        try {
          await escalate?.call('not_ok');
        } catch (_) {}
        if (context.mounted) _snack(context, tr.at2OkSent);
        return;
      }
      final pin = await (askPin?.call(context) ??
          const SecurityGuard().askPin(context, tr));
      if (pin == null || pin.isEmpty || !context.mounted) return;
      final r = await send(pin);
      IntruderSnap.after(r); // at100: wrong PIN -> the consented photo
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
        // antitheft2: the server already escalated the held grab
        _snack(context, tr.at2OkWrongPin);
      } else if (st == 403 || r['reason'] == 'bad_pin') {
        _snack(context, tr.at2OkWrongPin);
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
