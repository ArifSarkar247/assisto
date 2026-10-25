// "The rest": opens EVERY drawer feature (the exact builder the drawer uses)
// one by one, waits for it to load, screenshots it and records — per feature —
// every backend call it made with its status, any Flutter exception, and any
// visible load-failure state. One result row per feature, so the audit has
// evidence for features without a hand-written flow.
//
// It cannot prove deep actions inside each screen (the dedicated flows do
// that); a row passes only if the screen opened, made no 404/405/5xx call,
// threw nothing and is not showing a load-failed state.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/widgets/sidebar_sections.dart';

import '../support/harness.dart';

void registerSweepFlow() {
  testWidgets('99_drawer_sweep', (tester) async {
    final h = Harness.I;
    await h.boot(tester);
    final probe = FlowResult('99_sweep_boot', 'Sweep', 'boot');
    final pf = RFlow(h, tester, probe);
    try {
      await pf.home();
    } catch (_) {
      h.results.add(probe..status = 'fail'..error = 'home never appeared');
      await h.writeResults();
      return;
    }
    final t = h.t;
    // rf1: resume after a device death — items with a verdict are skipped,
    // and each item announces itself so a crash is pinned to ONE feature.
    final skips = await tester.runAsync(() => h.skipIds()) ?? const <String>{};
    final errorTexts = [t.loadFailed, t.checkInternetRetry, 'Something went wrong'];
    var n = 0;
    for (final section in SidebarSections.all) {
      for (final item in section.items) {
        n++;
        final label = item.label(t);
        final sid = 'S${n.toString().padLeft(3, '0')}';
        if (skips.contains(sid)) continue;
        // ignore: avoid_print
        print('REALITY_FLOW_START $sid');
        final r = FlowResult('S${n.toString().padLeft(3, '0')}', section.title(t), label);
        h.results.add(r);
        final f = RFlow(h, tester, r);
        final mark = h.recorder.hits.length;
        final errors = <String>[];
        final prev = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        try {
          await f.step('open "$label"', () async {
            final nav = appNavigatorKey.currentState!;
            unawaited(nav.push(MaterialPageRoute(builder: item.builder)));
            await f.pumpFor(const Duration(seconds: 4));
            await f.shot('open');
          });
          await f.step('loaded honestly (no 404/405/5xx, no exception, no load-failed)', () async {
            r.http.addAll(h.recorder.hits.sublist(mark));
            final bad = r.http.where((x) => x.status == 404 || x.status == 405 || x.status >= 500 || x.status < 0);
            final shown = errorTexts.where((e) => find.textContaining(e).evaluate().isNotEmpty).toList();
            if (errors.isNotEmpty) throw TestFailure('exception: ${errors.first}');
            if (bad.isNotEmpty) {
              throw TestFailure('server: ${bad.map((x) => '${x.method} ${x.path} ${x.status}').join(', ')}');
            }
            if (shown.isNotEmpty) throw TestFailure('screen shows "${shown.first}"');
            if (r.http.isEmpty) r.note = 'no backend call on open (local-only or static screen)';
            final keyed = r.http.where((x) => x.status == 402 || x.status == 403);
            if (keyed.isNotEmpty) r.note = '${r.note} gated: ${keyed.map((x) => '${x.path} ${x.status}').join(', ')}';
          });
          r.status = 'pass';
        } catch (e) {
          r.status = 'fail';
          r.error = '$e'.split('\n').first;
        } finally {
          FlutterError.onError = prev;
          if (r.http.isEmpty) r.http.addAll(h.recorder.hits.sublist(mark));
          // back to home for the next one
          final nav = appNavigatorKey.currentState;
          while (nav != null && nav.canPop()) {
            nav.pop();
            await tester.pump(const Duration(milliseconds: 300));
          }
          await settle(tester, seconds: 0.8);
          await h.writeResults();
        }
      }
    }
    // summarize.py: without this marker the sweep is reported unfinished (D)
    // ignore: avoid_print
    print('REALITY_SWEEP_DONE $n items');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
