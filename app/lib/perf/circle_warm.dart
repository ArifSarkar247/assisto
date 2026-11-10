// faststart (owner 10 Nov: "My Circle chat list visible under 1 second after
// tap"): the CI start-speed run showed the chat list waiting ~2.5 s on the
// first open after a cold start — the on-phone chat identity key (secure
// storage) and the message-preview cache load only when My Circle opens.
// Both are single-flight and cached for the process, so warming them in the
// background a moment after Home is on screen makes the tap instant.
// Signed-in only, after the first frame, never awaited, never throws.
import 'dart:async';

import '../crypto/identity_vault.dart';
import '../messaging/preview_cache.dart';
import '../state.dart';

class CircleWarm {
  CircleWarm._();

  static bool _started = false;

  /// Test seam: what "warm" does (default: identity + previews).
  static Future<void> Function() warm = _defaultWarm;

  static Future<void> _defaultWarm() async {
    try {
      await IdentityVault.instance.get();
    } catch (_) {}
    try {
      await PreviewCache.instance.warm();
    } catch (_) {}
  }

  /// Once per process: when [app] has finished loading and is signed in,
  /// wait [delay] (Home paints first), then warm.
  static void start(AppState app,
      {Duration delay = const Duration(milliseconds: 400)}) {
    if (_started) return;
    _started = true;
    void go() {
      if (!app.loggedIn) return;
      unawaited(Future<void>.delayed(delay, () async {
        try {
          await warm();
        } catch (_) {}
      }));
    }

    if (!app.loading) {
      go();
      return;
    }
    late void Function() l;
    l = () {
      if (app.loading) return;
      app.removeListener(l);
      go();
    };
    app.addListener(l);
  }

  static void resetForTest() {
    _started = false;
    warm = _defaultWarm;
  }
}
