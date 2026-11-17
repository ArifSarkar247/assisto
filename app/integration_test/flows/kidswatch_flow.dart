// gap-kidswatch (17 Nov): kids watch end to end on the emulator.
//   A = the parent (the app on screen). The WATCH is simulated from inside the
//   test over real TCP to the runner's tracker server (10.0.2.2:5023, started
//   by reality.yml next to Django) speaking the "3G" / SeTracker text
//   protocol exactly like a Q12-type watch: LK link, UD position, AL SOS.
// A pairs the watch (no SOS numbers given -> A's own number is the default)
// -> the watch connects -> A sees it online with its SOS line -> the child
// presses SOS on the watch -> A's watch card shows the red SOS banner with
// "Call the watch" + "See where" -> A opens Watch settings, adds a second SOS
// number -> the watch RECEIVES the new SOS numbers over TCP and ACKs them.
// Never: a listening command (the test fails if any MONITOR-type frame ever
// reaches the watch).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _trackerHost = String.fromEnvironment('REALITY_TRACKER_HOST', defaultValue: '10.0.2.2');
const _trackerPort = int.fromEnvironment('REALITY_TRACKER_PORT', defaultValue: 5023);
const _forbidden = {
  'MONITOR', 'CALL', 'ACALL', 'GSMANT', 'SMS', 'RCAPTURE', 'UPGRADE', 'DEBUG',
  'IMEI', 'IP', 'MONITOR2', 'LISTEN', 'JT', 'SILENTCALL', 'CALLBACK', 'AUDIOMONITOR',
};

/// A minimal kids watch: text frames "[3G*<id>*LLLL*<content>]".
class _SimWatch {
  _SimWatch(this.id);
  final String id;
  Socket? _s;
  String _buf = '';
  final List<String> got = []; // server frame contents, in order
  final List<String> forbidden = [];

  Future<void> connect() async {
    _s = await Socket.connect(_trackerHost, _trackerPort, timeout: const Duration(seconds: 10));
    _s!.listen((data) {
      _buf += latin1.decode(data);
      while (true) {
        final a = _buf.indexOf('[');
        final b = _buf.indexOf(']', a + 1);
        if (a < 0 || b < 0) break;
        final fr = _buf.substring(a + 1, b);
        _buf = _buf.substring(b + 1);
        final parts = fr.split('*');
        if (parts.length < 4) continue;
        final content = parts.sublist(3).join('*');
        final typ = content.split(',').first.toUpperCase();
        got.add(content);
        if (_forbidden.contains(typ)) {
          forbidden.add(typ);
          continue;
        }
        // like real firmware: ACK every server command by echoing its type
        if (!const {'LK', 'AL', 'TKQ', 'TKQ2', 'INIT'}.contains(typ)) send(typ);
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  void send(String content) {
    final len = content.length.toRadixString(16).toUpperCase().padLeft(4, '0');
    _s?.add(latin1.encode('[3G*$id*$len*$content]'));
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// UD / AL content (Dhaka local time, valid GPS fix).
  String pos(String typ, double lat, double lng, {int status = 0}) {
    final l = DateTime.now().toUtc().add(const Duration(hours: 6));
    final d = '${_two(l.day)}${_two(l.month)}${_two(l.year % 100)}';
    final t = '${_two(l.hour)}${_two(l.minute)}${_two(l.second)}';
    final st = status.toRadixString(16).toUpperCase().padLeft(8, '0');
    return '$typ,$d,$t,A,${lat.toStringAsFixed(6)},N,${lng.toStringAsFixed(6)},E,'
        '0.00,0,0.0,9,100,72,0,0,$st,0,0,';
  }

  bool has(String prefix) => got.any((c) => c.startsWith(prefix));

  Future<void> close() async {
    try {
      await _s?.close();
    } catch (_) {}
    _s?.destroy();
  }
}

void registerKidsWatchFlows() {
  realityFlow('18k_kidswatch_sos', 'Family & safety',
      'Kids watch: pair (own number = SOS default) -> simulated watch over TCP -> SOS -> red banner + Call the watch -> Watch settings -> watch receives the new SOS numbers (never a listen command)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final run = DateTime.now().millisecondsSinceEpoch % 100000000;
    final code = '88${run.toString().padLeft(8, '0')}';
    final w = _SimWatch(code);
    late int wid;

    await f.step('A pairs the watch (no SOS number typed)', () async {
      final r = await f.net(() => api.postJsonRaw('/kids-watch/watches', {
            'code': code,
            'child_name': 'Rina',
            'sim_phone': '01911000008',
          }));
      if (r['ok'] != true) throw TestFailure('pair failed: $r');
      wid = ((r['watch'] as Map)['id'] as num).toInt();
      if (r['sos_defaulted'] != true || (r['watch'] as Map)['sos_ready'] != true) {
        throw TestFailure('SOS button would call nobody: $r');
      }
    });

    await f.step('the watch connects over TCP and is paired', () async {
      await f.net(() => w.connect());
      w.send('LK,120,0,72');
      await f.eventually('LK answered', () async => w.has('LK'));
      w.send(w.pos('UD', 23.7808, 90.4130));
      await f.eventually('watch paired + first fix', () async {
        final r = await api.getJson('/kids-watch/watches/$wid');
        final x = (r['watch'] as Map?) ?? const {};
        return x['state'] == 'paired' && x['live'] != null;
      }, seconds: 30);
      await f.eventually('watch got its SOS numbers', () async => w.has('SOS,'), seconds: 30);
    });

    await f.step('the child presses SOS on the watch -> red banner on A', () async {
      w.send(w.pos('AL', 23.7810, 90.4131, status: 1 << 16));
      await f.eventually('AL answered', () async => w.has('AL'));
      await f.eventually('SOS on the card', () async {
        final r = await api.getJson('/kids-watch/watches/$wid');
        return ((r['watch'] as Map?) ?? const {})['sos_at'] != null;
      }, seconds: 30);
      await f.openRoute('kids_watch');
      final banner = find.byKey(ValueKey('kwg-sos-$wid'));
      await f.scrollTo(banner);
      await f.waitFor(banner, what: 'red SOS banner');
      expect(find.descendant(of: banner, matching: find.byKey(ValueKey('kwg-sos-call-$wid'))),
          findsOneWidget);
      await f.shot('kidswatch_sos_banner');
    });

    await f.step('Watch settings: add a second SOS number -> the watch receives it', () async {
      final settings = find.byKey(ValueKey('kwg-settings-$wid'));
      await f.scrollTo(settings);
      await f.tap(settings);
      final sos = find.byKey(const ValueKey('kwg-set-sos'));
      await f.waitFor(sos, what: 'SOS numbers field');
      final ctl = f.tester.widget<TextField>(sos).controller!;
      if (ctl.text.trim().isEmpty) throw TestFailure('SOS field not pre-filled');
      await f.tester.enterText(sos, '${ctl.text}, 01811000002');
      await f.shot('kidswatch_settings');
      await f.tap(find.byKey(const ValueKey('kwg-set-save')), settleSeconds: 3);
      f.expectHttp('PATCH', '/kids-watch/watches/$wid');
      await f.eventually('watch got the new SOS list',
          () async => w.got.any((c) => c.startsWith('SOS,') && c.contains('01811000002')),
          seconds: 30);
      final r = await f.net(() => api.getJson('/kids-watch/watches/$wid'));
      final nums = ((r['watch'] as Map)['sos_numbers'] as List).map((e) => '$e').toList();
      if (!nums.contains('01811000002')) throw TestFailure('server SOS list: $nums');
      if (w.forbidden.isNotEmpty) throw TestFailure('listen command reached the watch: ${w.forbidden}');
      f.note('watch frames: ${w.got.map((c) => c.split(',').first).toList()}');
    });

    await f.step('cleanup: remove the watch', () async {
      await f.net(() => w.close());
      await f.net(() => api.deleteJson('/kids-watch/watches/$wid'));
    });
  });
}
