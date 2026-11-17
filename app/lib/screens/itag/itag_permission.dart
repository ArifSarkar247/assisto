// flag-itag: the ONLY place Assisto asks Android for Bluetooth scan/connect
// ("Nearby devices", Android 12+) or, on Android 8–11, the location
// permission a Bluetooth scan needs. The full-screen reason
// (ItagReasonScreen) always comes first; "Not now" never prompts Android.
// Guarded by test/play_disclosure_guard_test.dart + test/itag_test.dart.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../ds/ds.dart';
import '../../itag/itag_platform.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;

enum ItagAsk { granted, denied, blocked }

enum ItagReady { ready, notNow, blocked, off, locationOff, unsupported }

/// Test seam: asks Android (after the reason screen) and reports the answer.
typedef ItagAskFn = Future<ItagAsk> Function(bool nearbyDevices);

/// Makes Bluetooth usable for the tag screen: the reason screen, then the
/// Android prompt, then the radio state. Never throws.
Future<ItagReady> itagEnsureReady(BuildContext context, ItagPlatform platform,
    {ItagAskFn? ask}) async {
  try {
    var s = await platform.state();
    if (s.radio == ItagRadio.noPermission) {
      if (!context.mounted) return ItagReady.notNow;
      final go = await ItagReasonScreen.show(context, nearbyDevices: s.nearbyDevicesPermission);
      if (!go) return ItagReady.notNow;
      final a = await (ask ?? _askAndroid)(s.nearbyDevicesPermission);
      if (a == ItagAsk.blocked) return ItagReady.blocked;
      if (a == ItagAsk.denied) return ItagReady.notNow;
      s = await platform.state();
    }
    return switch (s.radio) {
      ItagRadio.ready => ItagReady.ready,
      ItagRadio.off => ItagReady.off,
      ItagRadio.locationOff => ItagReady.locationOff,
      ItagRadio.noPermission => ItagReady.notNow,
      ItagRadio.unsupported => ItagReady.unsupported,
    };
  } catch (_) {
    return ItagReady.unsupported;
  }
}

/// Runs ONLY from itagEnsureReady, right after ItagReasonScreen.show(...).
Future<ItagAsk> _askAndroid(bool nearbyDevices) async {
  try {
    if (nearbyDevices) {
      // Android 12+: scan is declared neverForLocation (no location use)
      final r = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
      if (r.values.every((v) => v.isGranted)) return ItagAsk.granted;
      if (r.values.any((v) => v.isPermanentlyDenied)) return ItagAsk.blocked;
      return ItagAsk.denied;
    }
    // Android 8–11: a Bluetooth scan needs the location permission
    final st = await Permission.locationWhenInUse.request();
    if (st.isGranted) return ItagAsk.granted;
    if (st.isPermanentlyDenied) return ItagAsk.blocked;
    return ItagAsk.denied;
  } catch (_) {
    return ItagAsk.denied;
  }
}

/// The prominent, full-screen reason shown before any Bluetooth ask.
class ItagReasonScreen extends StatelessWidget {
  const ItagReasonScreen({super.key, required this.nearbyDevices});
  final bool nearbyDevices;

  static Future<bool> show(BuildContext context, {required bool nearbyDevices}) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ItagReasonScreen(nearbyDevices: nearbyDevices)));
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final d = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    Widget point(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: d.primaryInk),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(s, style: text.bodyLarge?.copyWith(height: 1.4))),
          ]),
        );
    return Scaffold(
      key: const Key('itag-reason'),
      appBar: AppBar(title: Text(t.itgReasonTitle)),
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            const Center(child: DsIllustration(icon: Icons.bluetooth_searching_rounded)),
            const SizedBox(height: Gap.lg),
            Text(nearbyDevices ? t.itgReasonNearby : t.itgReasonLegacy,
                style: text.titleMedium?.copyWith(height: 1.4)),
            const SizedBox(height: Gap.lg),
            point(Icons.notifications_active_rounded, t.itgReasonRing),
            point(Icons.directions_walk_rounded, t.itgReasonLeft),
            point(Icons.phonelink_ring_rounded, t.itgReasonButton),
            point(Icons.lock_rounded, t.itgReasonPrivacy),
            const SizedBox(height: Gap.lg),
            DsButton(
              buttonKey: const Key('itag-reason-yes'),
              label: t.continueWord,
              expand: true,
              onPressed: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: Gap.sm),
            DsButton.secondary(
              buttonKey: const Key('itag-reason-no'),
              label: t.notNow,
              expand: true,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
  }
}
