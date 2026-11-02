// bubbles gallery states for test/screenshots_test.dart: the floating chat
// bubble window when the chat can't be opened (Retry + Open in Assisto) and
// when the phone is signed out. The open chat itself is the normal chat
// screen (already in the gallery) with "Open in Assisto" instead of calls.
import 'package:flutter/material.dart';

import 'package:assisto/messaging/bubble_main.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

AppState _app(String l, {bool signedIn = true}) {
  final s = AppState()
    ..locale = Locale(l)
    ..loading = false;
  if (signedIn) {
    s.api.token = 'gallery';
    s.user = AppUser(
        id: 1, name: 'Rina', phone: '', email: '', autonomyLevel: 2, language: l);
  }
  return s;
}

final Map<String, Widget Function(String)> bubblesShots = {
  'bbl_window_cant_open': (l) => BubbleChatHost(
      app: _app(l),
      takeChat: () async => 'member:1',
      buildChat: (a, k, i) async => throw StateError('offline')),
  'bbl_window_signed_out': (l) => BubbleChatHost(
      app: _app(l, signedIn: false), takeChat: () async => 'member:1'),
};
