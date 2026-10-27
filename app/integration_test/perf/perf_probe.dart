// perf2gb: measuring helpers for the 2 GB performance flows (perf_flows.dart).
//
//  * openTimed  — time from a trigger (push / tap) to (a) the first frame of
//                 the new screen and (b) "ready": route transition finished,
//                 no indeterminate spinner on screen, optional finder present
//  * frames     — FrameTiming (UI build + raster) for a window, via
//                 SchedulerBinding.addTimingsCallback (real engine timings;
//                 the binding runs fullyLive)
//  * scroll     — real flings on the screen's main list
//  * mem        — host-side `dumpsys meminfo` (PERF_MEM handshake, like the
//                 harness' screenshots) + the Dart-side RSS as a fallback
//
// Every flow's metrics go to <ext files>/reality/perf.json AND to logcat as
// `PERF_RESULT <id> i/n <json part>` (collected by tools/perf2gb/collect.py).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/widgets/chatnav.dart';

import '../support/harness.dart';
import 'perf_stats.dart';

class PerfRecorder {
  PerfRecorder._();
  static final PerfRecorder I = PerfRecorder._();
  final List<Map<String, dynamic>> flows = [];

  Future<void> save(Harness h, Map<String, dynamic> flow) async {
    flows.add(flow);
    try {
      final d = await h.outDir();
      await File('${d.path}/perf.json')
          .writeAsString(const JsonEncoder.withIndent(' ').convert({'flows': flows}));
    } catch (_) {}
    final js = jsonEncode(flow);
    final n = (js.length / 700).ceil();
    for (var i = 0; i < n; i++) {
      final stop = (i + 1) * 700 > js.length ? js.length : (i + 1) * 700;
      // ignore: avoid_print
      print('PERF_RESULT ${flow['id']} ${i + 1}/$n ${js.substring(i * 700, stop)}');
    }
  }
}

/// Collects FrameTimings while running.
class FrameWindow {
  final List<FrameTiming> _t = [];
  void _cb(List<FrameTiming> t) => _t.addAll(t);
  bool _on = false;

  void start() {
    if (_on) return;
    _on = true;
    SchedulerBinding.instance.addTimingsCallback(_cb);
  }

  /// Stop after letting the engine flush its batched timings (profile/release
  /// report them about once a second).
  Future<Map<String, dynamic>> stop(WidgetTester tester) async {
    await settle(tester, seconds: 1.2);
    SchedulerBinding.instance.removeTimingsCallback(_cb);
    _on = false;
    return frameStats(
      buildUs: [for (final f in _t) f.buildDuration.inMicroseconds],
      rasterUs: [for (final f in _t) f.rasterDuration.inMicroseconds],
      totalUs: [for (final f in _t) f.totalSpan.inMicroseconds],
    );
  }
}

class PerfFlowCtx {
  PerfFlowCtx(this.f, this.id, this.board);
  final RFlow f;
  final String id;
  final String board; // FEATURE_100_BOARD group, e.g. "২. আমার সার্কেল"
  final Map<String, dynamic> out = {};
  final Map<String, dynamic> opens = {};
  final Map<String, dynamic> jank = {};
  final Map<String, dynamic> mem = {};
  final List<String> notes = [];

  WidgetTester get tester => f.tester;

  static Route<dynamic>? topRoute() {
    Route<dynamic>? top;
    appNavigatorKey.currentState?.popUntil((r) {
      top = r;
      return true;
    });
    return top;
  }

  static bool _busy() => find
      .byWidgetPredicate((w) =>
          (w is CircularProgressIndicator && w.value == null) ||
          (w is LinearProgressIndicator && w.value == null))
      .evaluate()
      .isNotEmpty;

  /// Time [trigger] → first frame of a NEW top route → ready. With
  /// [sameRoute] the screen does not change (e.g. a tap inside a screen):
  /// first frame = the frame after the trigger.
  Future<Map<String, dynamic>> openTimed(String label, FutureOr<void> Function() trigger,
      {Finder? ready, bool sameRoute = false, double capSeconds = 10}) async {
    final before = topRoute();
    final win = FrameWindow()..start();
    final sw = Stopwatch()..start();
    await trigger();
    int? first;
    int? readyMs;
    int calmSince = -1;
    final cap = (capSeconds * 1000).round();
    while (sw.elapsedMilliseconds < cap) {
      await tester.pump(const Duration(milliseconds: 16));
      final top = topRoute();
      final changed = sameRoute || (top != null && !identical(top, before));
      if (!changed) continue;
      first ??= sw.elapsedMilliseconds;
      final anim = top is ModalRoute ? top.animation : null;
      final settled = anim == null || anim.status == AnimationStatus.completed;
      final ok = settled && !_busy() && (ready == null || ready.evaluate().isNotEmpty);
      if (ok) {
        if (calmSince < 0) calmSince = sw.elapsedMilliseconds;
        // ready = the first moment it was calm, confirmed one poll later
        if (sw.elapsedMilliseconds - calmSince >= 32) {
          readyMs = calmSince;
          break;
        }
      } else {
        calmSince = -1;
      }
    }
    final frames = await win.stop(tester);
    final r = {
      'first_frame_ms': first,
      'ready_ms': readyMs,
      'timed_out': readyMs == null,
      'frames': frames,
    };
    opens[label] = r;
    return r;
  }

  /// Open a ChatNav route the way the home / drawer does, timed.
  Future<Map<String, dynamic>> openRoute(String label, String route,
      {Finder? ready, double capSeconds = 10}) async {
    await f.backToHome();
    await f.pumpFor(const Duration(milliseconds: 600));
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) throw TestFailure('no navigator');
    return openTimed(label, () {
      if (!ChatNav.push(ctx, route)) throw TestFailure('route "$route" not available');
    }, ready: ready, capSeconds: capSeconds);
  }

  Future<Map<String, dynamic>> pushTimed(String label, Widget screen,
      {Finder? ready, double capSeconds = 10}) {
    final nav = appNavigatorKey.currentState;
    if (nav == null) throw TestFailure('no navigator');
    return openTimed(label, () {
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => screen)));
    }, ready: ready, capSeconds: capSeconds);
  }

  /// The biggest vertical scrollable on screen.
  Finder? _mainList() {
    final all = find.byType(Scrollable).hitTestable().evaluate().toList();
    Element? best;
    double bestH = 0;
    for (final e in all) {
      final w = e.widget as Scrollable;
      if (w.axisDirection != AxisDirection.down && w.axisDirection != AxisDirection.up) continue;
      final box = e.renderObject;
      if (box is! RenderBox || !box.hasSize) continue;
      final h = box.size.height * box.size.width;
      if (h > bestH) {
        bestH = h;
        best = e;
      }
    }
    if (best == null) return null;
    final target = best;
    return find.byElementPredicate((e) => identical(e, target));
  }

  /// Fling the main list [downs] times towards the end, then [ups] back,
  /// with real frames in between; FrameTimings of the whole scroll window.
  /// [older] = the list grows upwards (chat): "down the history" = drag down.
  Future<Map<String, dynamic>> scroll(String label,
      {int downs = 5, int ups = 2, bool older = false}) async {
    final list = _mainList();
    if (list == null) {
      notes.add('$label: no scrollable list on screen');
      return {};
    }
    final win = FrameWindow()..start();
    final dir = older ? 1.0 : -1.0;
    for (var i = 0; i < downs + ups; i++) {
      final sign = i < downs ? dir : -dir;
      if (list.evaluate().isEmpty) break;
      await tester.fling(list, Offset(0, 520 * sign), 2600, warnIfMissed: false);
      await settle(tester, seconds: 1.1);
    }
    final r = await win.stop(tester);
    jank[label] = r;
    return r;
  }

  /// Memory now: host dumpsys (PERF_MEM handshake; up to 20 s) + Dart RSS.
  Future<void> memory(String label) async {
    final tag = '${id}__$label';
    final d = await f.h.outDir();
    final ack = File('${d.path}/acks/$tag.mem');
    // ignore: avoid_print
    print('PERF_MEM $tag');
    var got = false;
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (await tester.runAsync(() => ack.exists()) == true) {
        got = true;
        break;
      }
    }
    mem[label] = {
      'dart_rss_mb': (ProcessInfo.currentRss / 1048576 * 10).round() / 10,
      'dart_max_rss_mb': (ProcessInfo.maxRss / 1048576 * 10).round() / 10,
      'host_dumpsys': got,
    };
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'board': board,
        'feature': f.r.feature,
        ...out,
        'opens': opens,
        'jank': jank,
        'mem': mem,
        'notes': notes,
      };
}

/// What is on screen when a flow stops (no screenshots reach us when the
/// artifact download is capped): top route, app state, first visible texts.
String _diag(RFlow f) {
  try {
    final top = PerfFlowCtx.topRoute();
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((s) => s.trim().isNotEmpty)
        .take(12)
        .join(' | ');
    final a = f.h.app;
    return 'route=${top?.settings.name ?? top.runtimeType} loading=${a?.loading} '
        'loggedIn=${a?.loggedIn} onboarded=${a?.onboarded} texts=$texts';
  } catch (e) {
    return 'diag failed: $e';
  }
}

/// PERF_ONLY filter (flow id prefixes); null = every flow.
List<String>? perfOnly;

/// One perf flow: a reality flow (boot = close + reopen the app) whose
/// metrics are saved even when a step fails.
void perfFlow(String id, String board, String feature,
    Future<void> Function(PerfFlowCtx p) body,
    {Duration timeout = const Duration(minutes: 6)}) {
  final only = perfOnly;
  if (only != null && !only.any((o) => id.startsWith(o.trim()))) return;
  realityFlow(id, 'Perf 2 GB', feature, (f) async {
    final p = PerfFlowCtx(f, id, board);
    var ok = false;
    // warm "reopen the app" time: AssistoApp pumped -> home visible
    final sw = Stopwatch()..start();
    await f.h.boot(f.tester, settleSeconds: 0);
    try {
      await f.home();
      p.out['reopen_to_home_ms'] = sw.elapsedMilliseconds;
      await f.pumpFor(const Duration(seconds: 2));
      await body(p);
      ok = true;
    } catch (e) {
      p.notes.add('stopped: ${'$e'.split('\n').first}');
      p.notes.add('screen: ${_diag(f)}');
      rethrow;
    } finally {
      p.out['ok'] = ok;
      p.out['flow_seconds'] = f.r.sw.elapsedMilliseconds / 1000;
      await PerfRecorder.I.save(f.h, p.toJson());
    }
  }, timeout: timeout, boot: false);
}
