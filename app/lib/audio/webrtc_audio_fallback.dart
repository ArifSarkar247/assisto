import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'audio_route_service.dart';

/// audioroute: the ONLY file allowed to call flutter_webrtc's routing helpers
/// (Helper.setSpeakerphoneOn / selectAudioOutput / …) — CI guard
/// test/audio_route_guard_test.dart. Imported only by calls/webrtc_media.dart
/// (itself a deferred import), so nothing here loads at app launch.
///
/// Used ONLY when AudioRouteChannel.kt could not switch the plugin's own audio
/// switch off (a future plugin rename / an OEM reflection block): routing then
/// goes through the plugin, still under the route service's policy
/// (headset > earpiece / speaker, user pick sticks, live switch).
void installWebrtcAudioFallback(AudioRouteService svc) {
  svc.fallback ??= _select;
}

/// The plugin's communication preset (echo cancellation, earpiece default).
/// Only when the native owner could not take over.
Future<void> prepareWebrtcAudioFallback() async {
  try {
    await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.communication);
  } catch (_) {}
}

Future<void> _select(AudioRoute r) async {
  switch (r) {
    case AudioRoute.speaker:
      await Helper.setSpeakerphoneOn(true);
    case AudioRoute.earpiece:
      await Helper.setSpeakerphoneOn(false);
      await Helper.selectAudioOutput('earpiece');
    case AudioRoute.bluetooth:
      await Helper.selectAudioOutput('bluetooth');
    case AudioRoute.wired:
      await Helper.selectAudioOutput('wired-headset');
  }
}
