import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/local_digits.dart' show toLocalDigits;
import '../widgets/app_sheet.dart';
import 'ad_control.dart';
import 'ads_bridge.dart' show RewardOutcome;
import 'ads_service.dart';

/// How a rewarded gate grants what it unlocks.
enum AdGateGrant {
  /// one ad per use (a manual scan, a number check, More routes)
  perUse,

  /// one ad ONCE, then free forever on this phone (security switch-on)
  once,

  /// one ad, then free for N minutes (train live location; owner-editable)
  window,
}

/// adcontrol (owner 10 Nov 03:45) — "watch one short ad to continue" for a
/// registered REWARDED placement (City Service More routes, Train live
/// location, Security features switch-on / manual scan / number check).
///
/// HONEST + NEVER BLOCKING: the gate is only offered to a FREE user when the
/// owner's switch for [placement] is on AND a rewarded ad can really play
/// right now. Premium / Plus / Business, switched off, no AdMob, no consent,
/// no fill, a test build -> [run] simply runs the action (no ad, no sheet, no
/// dead end). If the user closes the sheet nothing happens (they can tap
/// again); if the ad fails to load or show the action still runs.
class AdRewardGate {
  AdRewardGate._();

  /// Test seams.
  @visibleForTesting
  static Future<bool> Function(String placement)? debugAvailable;
  @visibleForTesting
  static Future<RewardOutcome> Function(String placement)? debugShow;
  @visibleForTesting
  static int Function()? debugTrainMinutes;

  static String _onceKey(String id) => 'adgate_once_$id';
  static String _windowKey(String id) => 'adgate_window_$id';

  /// true = already unlocked (no ad needed). Never throws.
  static Future<bool> unlocked(AdGateGrant grant, String unlockId,
      {DateTime? now, int minutes = 15}) async {
    if (grant == AdGateGrant.perUse) return false;
    try {
      final p = await SharedPreferences.getInstance();
      if (grant == AdGateGrant.once) return p.getBool(_onceKey(unlockId)) == true;
      final ms = p.getInt(_windowKey(unlockId));
      return AdControl.trainWindowOpen(
          ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
          now ?? DateTime.now(),
          minutes);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _remember(AdGateGrant grant, String unlockId) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (grant == AdGateGrant.once) await p.setBool(_onceKey(unlockId), true);
      if (grant == AdGateGrant.window) {
        await p.setInt(_windowKey(unlockId), DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  static bool _linked() {
    try {
      return AdsService.instance.bridge.linked;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _available(BuildContext context, String placement) async {
    final f = debugAvailable;
    if (f != null) return f(placement);
    try {
      return await AdsService.instance
          .rewardedAvailable(context.read<AppState>(), screen: placement);
    } catch (_) {
      return false;
    }
  }

  static Future<RewardOutcome> _show(BuildContext context, String placement) async {
    final f = debugShow;
    if (f != null) return f(placement);
    try {
      return await AdsService.instance
          .showRewarded(context.read<AppState>(), screen: placement);
    } catch (_) {
      return RewardOutcome.unavailable;
    }
  }

  static int _minutes() {
    final f = debugTrainMinutes;
    if (f != null) return f();
    return AdsService.instance.config.control.trainFreeMinutes;
  }

  /// Run [action] behind one rewarded ad at [placement]. [unlockId] names
  /// what a once / window grant unlocks (e.g. 'scam', 'train_live').
  /// [what] is the short Bangla/English line "to see the live location".
  /// Returns true when [action] ran.
  static Future<bool> run(
    BuildContext context, {
    required String placement,
    required AdGateGrant grant,
    required String what,
    required FutureOr<void> Function() action,
    String unlockId = '',
  }) async {
    // no AdMob on this build / platform: run at once (synchronously, before
    // any await — exactly as without the gate)
    if (debugAvailable == null && !_linked()) {
      await action();
      return true;
    }
    final id = unlockId.isEmpty ? placement : unlockId;
    final minutes = _minutes();
    if (await unlocked(grant, id, minutes: minutes) ||
        !context.mounted ||
        !await _available(context, placement)) {
      await action();
      return true;
    }
    if (!context.mounted) return false;
    final go = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _GateSheet(what: what, grant: grant, minutes: minutes),
    );
    if (go != true || !context.mounted) return false;
    final out = await _show(context, placement);
    if (out == RewardOutcome.dismissed) return false; // closed early: try again
    if (out == RewardOutcome.earned) await _remember(grant, id);
    // earned, or the ad could not play after all -> never a dead end
    await action();
    return true;
  }
}

class _GateSheet extends StatelessWidget {
  const _GateSheet({required this.what, required this.grant, required this.minutes});
  final String what;
  final AdGateGrant grant;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final note = switch (grant) {
      AdGateGrant.once => t.adGateOnceNote,
      AdGateGrant.window => t.adGateWindowNote(toLocalDigits('$minutes',
          Localizations.localeOf(context).languageCode == 'bn')),
      AdGateGrant.perUse => t.adGatePerUseNote,
    };
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          key: const ValueKey('ad-gate-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.adGateTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.adGateBody(what)),
            const SizedBox(height: Gap.xs),
            Text(note, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const ValueKey('ad-gate-watch'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.play_circle_outline_rounded),
              label: Text(t.adGateWatch),
            ),
            const SizedBox(height: Gap.sm),
            TextButton(
              key: const ValueKey('ad-gate-cancel'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.adGateNotNow),
            ),
          ],
        ),
      ),
    );
  }
}
