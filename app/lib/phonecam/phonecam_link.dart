import 'package:flutter/material.dart';

import '../feature_flags.dart';
import 'phone_camera_screen.dart';
import 'phonecam_logic.dart';

/// cctvphone: the pairing QR is an Android App Link
/// (https://lifeassisto.com/pc/<code>). The old phone scans it with its own
/// camera / Google Lens and Assisto opens on the camera-phone pairing screen
/// with the code filled in. Behind the CCTV switch `cctv_watchman`; any
/// other route name returns null exactly as before.
class PhoneCamLink {
  PhoneCamLink._();

  static bool get _on => FeatureFlags.instance.isOn('cctv_watchman');

  /// MaterialApp.onGenerateRoute hook (warm App Link: "/pc/<code>").
  static Route<dynamic>? route(RouteSettings s) {
    final c = pairCodeFromLink(s.name);
    if (c == null || !_on) return null;
    return MaterialPageRoute<void>(
        settings: s, builder: (_) => PhoneCameraScreen(initialCode: c));
  }

  static bool _coldDone = false;

  /// Cold start: the link arrives as the full URL in defaultRouteName (the
  /// Navigator then falls back to home); push the pairing screen on top.
  static void maybeOpenColdStart(BuildContext context, String defaultRouteName) {
    if (_coldDone) return;
    _coldDone = true;
    final c = pairCodeFromLink(defaultRouteName);
    if (c == null || !_on) return;
    try {
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PhoneCameraScreen(initialCode: c)));
    } catch (_) {}
  }

  @visibleForTesting
  static void resetColdStart() => _coldDone = false;
}
