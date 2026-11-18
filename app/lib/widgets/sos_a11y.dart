// a11ysweep — SOS for TalkBack users, safely.
//
// Every SOS in Assisto (Family Care red button, elder Danger button, Safe
// Journey SOS) opens a short countdown with a big Cancel. A sighted user sees
// the number and the Cancel button at once. A TalkBack user has to SWIPE to
// find them, hears nothing while the number changes, and 5 seconds is gone
// before Cancel is reached — so a mis-tap sends a real alarm to the whole
// family. With TalkBack (or any accessible-navigation service) on:
//   * the countdown is at least [kSosTalkBackSeconds] seconds;
//   * the screen announces how long the user has and that Cancel is first;
//   * Cancel is the FIRST control in reading order (and on screen);
//   * the remaining seconds are a live region, so each change is spoken.
// Sending is never slower to reach: "Send now" is the next swipe.
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Minimum countdown while TalkBack / Switch Access is on.
const int kSosTalkBackSeconds = 10;

/// True while the OS screen reader (TalkBack, Switch Access, Select to
/// Speak navigation) drives the UI. Safe in initState (no MediaQuery needed).
bool sosScreenReaderOn([BuildContext? context]) {
  if (context != null) {
    final mq = MediaQuery.maybeOf(context);
    if (mq != null && mq.accessibleNavigation) return true;
  }
  return WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.accessibleNavigation;
}

/// The countdown to use: [base] as configured, raised to
/// [kSosTalkBackSeconds] for screen-reader users. 0 (send at once — used by
/// callers that already confirmed) stays 0.
int sosCountdownSeconds(int base, {bool? screenReader}) {
  if (base <= 0) return base;
  final sr = screenReader ?? sosScreenReaderOn();
  return sr && base < kSosTalkBackSeconds ? kSosTalkBackSeconds : base;
}

/// Speak [message] once (politely: it never cuts the screen reader off).
void sosAnnounce(BuildContext context, String message) {
  final FlutterView? view = View.maybeOf(context);
  if (view == null) return;
  SemanticsService.sendAnnouncement(view, message, Directionality.of(context))
      .catchError((Object _) {});
}

/// The big countdown digits: read as "[label]" and re-read on each change.
class SosCountdownSemantics extends StatelessWidget {
  const SosCountdownSemantics({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: label,
        excludeSemantics: true,
        child: child,
      );
}
