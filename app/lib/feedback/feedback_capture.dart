import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// f1-founders: screenshot of the screen the user is on, for "Send feedback".
///
/// No plugin: main.dart wraps the whole app in a [RepaintBoundary] keyed by
/// [boundaryKey]; [capture] renders that boundary with Flutter's built-in
/// `RenderRepaintBoundary.toImage` BEFORE the feedback sheet opens, so the
/// sheet itself is never in the picture. Platform views (camera preview,
/// WebRTC video) render blank — that is a Flutter limit, not a bug.
/// Every failure returns null (the sheet then simply has no screenshot).
class AppShot {
  AppShot._();

  static final GlobalKey boundaryKey = GlobalKey(debugLabel: 'app-shot');

  /// Longest output side in physical pixels (keeps uploads well under 4 MB).
  static const int maxSide = 1600;

  static Future<Uint8List?> capture({GlobalKey? key}) async {
    try {
      final ctx = (key ?? boundaryKey).currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.hasSize) return null;
      final size = ro.size;
      final longest = math.max(size.width, size.height);
      if (longest <= 0) return null;
      final dpr = ctx != null ? MediaQuery.maybeDevicePixelRatioOf(ctx) ?? 2.0 : 2.0;
      final ratio = math.min(dpr, maxSide / longest);
      final ui.Image img = await ro.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}

/// Remembers the name of the top route (ChatNav pushes carry their route key
/// as RouteSettings.name), so a feedback report can say which screen it came
/// from. Pure bookkeeping — never throws, never navigates.
class ScreenTracker extends NavigatorObserver {
  ScreenTracker._();
  static final ScreenTracker instance = ScreenTracker._();

  final List<Route<dynamic>> _stack = [];

  /// The innermost named page route, or null when no named route is open.
  String? get current {
    for (var i = _stack.length - 1; i >= 0; i--) {
      final n = _stack[i].settings.name;
      if (n != null && n.isNotEmpty && n != '/') return n;
    }
    return null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute == null || newRoute is PopupRoute) {
      if (i >= 0) _stack.removeAt(i);
      return;
    }
    if (i >= 0) {
      _stack[i] = newRoute;
    } else {
      _stack.add(newRoute);
    }
  }
}
