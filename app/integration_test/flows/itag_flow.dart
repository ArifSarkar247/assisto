// itag-proof (18 Nov): Bluetooth iTag end to end in the REAL app on the
// emulator. An emulator has no Bluetooth, so a FAKE TAG answers behind the
// platform channel "com.assisto/itag" (the exact method names / event maps
// ItagChannel.kt speaks; its own link logic is JVM-tested in itag-proof.yml).
// Everything above the channel is real: drawer entry (switch itag_tags,
// allow-listed for demo user A by seed_reality), MethodChannelItagPlatform,
// ItagController, the screens, the full-screen alerts, the alarm sound,
// notifications, real 10 s grace and 15 s reconnect timers.
//   pair -> ring (Immediate Alert level 2, stop = 0) -> tag button rings the
//   phone -> "watch my bag" (link-loss level 2) -> link lost -> "left behind"
//   alarm after ~10 s -> tag back in range -> reconnect -> alarm stops by
//   itself -> Bluetooth turned off mid-watch = NO false alarm + honest card
//   -> on again = reconnects -> permission denied = Allow card, no dead end
//   -> bn + dark shots -> unpair.
import 'dart:async';

import 'package:assisto/itag/itag_controller.dart';
import 'package:assisto/itag/itag_platform.dart';
import 'package:assisto/itag/itag_store.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _tag = 'AA:BB:CC:DD:EE:01'; // made-up address
const _chName = 'com.assisto/itag';

/// The fake iTag + the phone's Bluetooth, answering like ItagChannel.kt.
class _FakeTagNative {
  _FakeTagNative(this.tester);
  final WidgetTester tester;
  String radio = 'ready';
  bool inRange = true;
  final calls = <String>[];
  final rings = <int>[];
  final linkLoss = <int>[];
  int connects = 0;

  void install() {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_chName), (call) async {
      final a = (call.arguments is Map) ? (call.arguments as Map) : const {};
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return {'state': radio, 'sdk': 33};
        case 'scan':
          return [
            {'address': _tag, 'name': 'iTAG', 'rssi': -52, 'likely': true},
            {'address': '11:22:33:44:55:66', 'name': 'Band', 'rssi': -70, 'likely': false},
          ];
        case 'connect':
          connects++;
          final ok = radio == 'ready' && inRange;
          if (ok) unawaited(Future(() => send('connected')));
          return ok;
        case 'ring':
          rings.add((a['level'] as num).toInt());
          return radio == 'ready' && inRange;
        case 'linkLoss':
          linkLoss.add((a['level'] as num).toInt());
          return true;
        case 'battery':
          return 87;
        case 'disconnect':
          return true;
        case 'openSettings':
          return true;
      }
      return null;
    });
  }

  void uninstall() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_chName), null);

  Future<void> send(String type, {bool user = false, bool radioOff = false}) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _chName,
        const StandardMethodCodec().encodeMethodCall(MethodCall('event', {
          'type': type,
          'address': type == 'radio' ? '' : _tag,
          'user': user,
          'radioOff': radioOff,
        })),
        (_) {});
  }
}

/// The real alarm (NativeDestAlarmSound), counted.
class _CountedSound implements DestAlarmSound {
  final DestAlarmSound real = NativeDestAlarmSound();
  int starts = 0;
  int stops = 0;
  @override
  Future<bool> start({required bool sound, required bool vibrate}) {
    starts++;
    return real.start(sound: sound, vibrate: vibrate);
  }

  @override
  Future<void> stop() {
    stops++;
    return real.stop();
  }

  @override
  Future<bool> speak(String text, String lang) => real.speak(text, lang);
  @override
  Future<bool> playClip(String path) => real.playClip(path);
  @override
  Future<bool> vibrateOnce() => real.vibrateOnce();
}

void registerItagFlows() {
  realityFlow('41i_itag_tag', 'Daily life',
      'Bluetooth iTag (fake tag behind the platform channel): pair -> ring -> tag button rings the phone -> watch my bag -> left behind after ~10 s -> back in range stops the alarm -> Bluetooth off = no false alarm -> on = reconnect -> permission denied = no dead end -> bn/dark -> unpair',
      (f) async {
    await f.home();
    final n = _FakeTagNative(f.tester)..install();
    final sound = _CountedSound();
    final c = ItagController(
      platform: MethodChannelItagPlatform(),
      sound: sound,
      locate: () async => ItagPlace(23.7808, 90.4130, DateTime.now().millisecondsSinceEpoch),
    );
    ItagController.instanceForTest = c;
    final t = f.t;
    try {
      await f.step('open "Bluetooth tag" from the drawer (switch itag_tags)', () async {
        await f.openFeature(t.itgTitle, 'itag_tags');
        await f.waitFor(find.byKey(const Key('itag-screen')), what: 'tag screen');
        await f.waitFor(find.byKey(const Key('itag-add-empty')), what: 'empty state + Add');
        await f.shot('itag_empty_en_light');
      });

      await f.step('pair: scan lists the iTag first -> name it -> linked + battery', () async {
        await f.tap(find.byKey(const Key('itag-add-empty')), settleSeconds: 2);
        final row = find.byKey(const Key('itag-found-$_tag'));
        await f.waitFor(row, what: 'iTag in the scan list');
        await f.shot('itag_scan');
        await f.tap(row);
        await f.waitFor(find.byKey(const Key('itag-name')), what: 'name dialog');
        await f.tester.enterText(find.byKey(const Key('itag-name')), 'Keys');
        await f.tap(find.byKey(const Key('itag-name-ok')), settleSeconds: 2);
        await f.waitFor(find.byKey(const Key('itag-tag-$_tag')), what: 'tag card');
        await f.waitFor(find.byKey(const Key('itag-battery-$_tag')), what: 'battery 87%');
        if (!c.connected.contains(_tag)) throw TestFailure('not linked after pairing');
        if (n.linkLoss.isEmpty || n.linkLoss.last != kItagAlertOff) {
          throw TestFailure('link-loss beep should be OFF while not watching: ${n.linkLoss}');
        }
        final saved = await f.net(() => ItagStore().load());
        if (saved.where((x) => x.address == _tag).isEmpty) throw TestFailure('not saved on the phone');
        await f.shot('itag_paired');
      });

      await f.step('ring my tag = Immediate Alert level 2; Stop = 0', () async {
        await f.tap(find.byKey(const Key('itag-ring-$_tag')));
        if (n.rings.lastOrNull != kItagAlertHigh) throw TestFailure('ring wrote ${n.rings}');
        await f.shot('itag_ringing');
        await f.tap(find.byKey(const Key('itag-ring-$_tag')));
        if (n.rings.lastOrNull != kItagAlertOff) throw TestFailure('stop wrote ${n.rings}');
      });

      await f.step('the tag button rings this phone (find my phone); Stop silences', () async {
        final before = sound.starts;
        await n.send('button');
        await f.waitFor(find.byKey(const Key('itag-alert-find')), what: 'find-my-phone alert');
        if (sound.starts != before + 1 || !c.phoneRinging) throw TestFailure('phone did not ring');
        await f.shot('itag_find_phone');
        await f.tap(find.byKey(const Key('itag-alert-stop')), settleSeconds: 2);
        if (c.phoneRinging) throw TestFailure('still ringing after Stop');
        await f.waitFor(find.byKey(const Key('itag-screen')), what: 'back on the tag screen');
      });

      late DateTime dropAt;
      await f.step('watch my bag -> link lost -> "left behind" alarm after ~10 s', () async {
        await f.scrollTo(find.byKey(const Key('itag-watch')));
        await f.tap(find.byKey(const Key('itag-watch')));
        await f.waitFor(find.byKey(const Key('itag-watch-banner')), what: 'watch banner');
        if (n.linkLoss.last != kItagAlertHigh) throw TestFailure('tag link-loss beep not armed');
        n.inRange = false; // walked away
        dropAt = DateTime.now();
        final starts = sound.starts;
        await n.send('disconnected');
        await f.pumpFor(const Duration(seconds: 6));
        if (find.byKey(const Key('itag-alert-left')).evaluate().isNotEmpty) {
          throw TestFailure('alarm before the 10 s grace');
        }
        await f.waitFor(find.byKey(const Key('itag-alert-left')), seconds: 12, what: 'left-behind alert');
        final ms = DateTime.now().difference(dropAt).inMilliseconds;
        f.note('left-behind alert ${ms}ms after the drop');
        if (ms < 9500 || ms > 16000) throw TestFailure('alert after ${ms}ms (want ~10 s)');
        if (sound.starts != starts + 1) throw TestFailure('alarm sound did not start');
        await f.shot('itag_left_behind');
      });

      await f.step('tag back in range -> auto-reconnect -> alarm stops by itself', () async {
        n.inRange = true;
        final before = n.connects;
        final stops = sound.stops;
        // the 15 s retry while watching reconnects; native then says "connected"
        await f.eventually('alert closed by itself',
            () async => find.byKey(const Key('itag-alert-left')).evaluate().isEmpty,
            seconds: 25);
        if (n.connects <= before) throw TestFailure('no reconnect attempt');
        if (c.leftBehind != null || sound.stops <= stops) throw TestFailure('alarm still on');
        await f.waitFor(find.byKey(const Key('itag-screen')), what: 'tag screen');
        await f.shot('itag_back_in_range');
      });

      await f.step('Bluetooth turned off mid-watch -> NO false alarm, card says not watched', () async {
        n.radio = 'off';
        final starts = sound.starts;
        await n.send('disconnected', radioOff: true);
        await n.send('radio', radioOff: true);
        await f.waitFor(find.byKey(const Key('itag-radio')), what: 'Bluetooth off card');
        await f.waitFor(find.text(t.itgBtOffWatching), what: '"not being watched" text');
        await f.pumpFor(const Duration(seconds: 12));
        if (find.byKey(const Key('itag-alert-left')).evaluate().isNotEmpty || sound.starts != starts) {
          throw TestFailure('false left-behind alarm with Bluetooth off');
        }
        await f.shot('itag_bt_off');
        await f.tap(find.byKey(const Key('itag-radio-action')));
        if (!n.calls.contains('openSettings')) throw TestFailure('Turn on did not open Bluetooth settings');
      });

      await f.step('Bluetooth on again -> reconnects, card gone', () async {
        n.radio = 'ready';
        final before = n.connects;
        await n.send('radio');
        await f.eventually('reconnected', () async => c.connected.contains(_tag), seconds: 10);
        await f.eventually('card gone',
            () async => find.byKey(const Key('itag-radio')).evaluate().isEmpty, seconds: 10);
        if (n.connects <= before) throw TestFailure('no reconnect after Bluetooth on');
        await f.scrollTo(find.byKey(const Key('itag-watch')));
        await f.tap(find.byKey(const Key('itag-watch'))); // watch off
      });

      await f.step('bn + dark: tag screen and the left-behind alert', () async {
        await f.net(() => f.app.setLocale(const Locale('bn'), syncServer: false));
        await f.net(() => f.app.setThemeMode(ThemeMode.dark));
        await f.pumpFor(const Duration(seconds: 2));
        await f.shot('itag_paired_bn_dark');
        await f.scrollTo(find.byKey(const Key('itag-watch')));
        await f.tap(find.byKey(const Key('itag-watch')));
        n.inRange = false;
        await n.send('disconnected');
        await f.waitFor(find.byKey(const Key('itag-alert-left')), seconds: 14, what: 'bn left-behind alert');
        await f.shot('itag_left_behind_bn_dark');
        await f.tap(find.byKey(const Key('itag-alert-stop')), settleSeconds: 2);
        if (c.leftBehind != null) throw TestFailure('Stop did not clear the alarm');
        n.inRange = true;
        await f.scrollTo(find.byKey(const Key('itag-watch')));
        await f.tap(find.byKey(const Key('itag-watch')));
        await f.net(() => c.connectAll());
        await f.eventually('linked again', () async => c.connected.contains(_tag), seconds: 10);
        await f.net(() => f.app.setThemeMode(ThemeMode.light));
        await f.pumpFor(const Duration(seconds: 1));
        await f.shot('itag_paired_bn_light');
        await f.net(() => f.app.setLocale(const Locale('en'), syncServer: false));
        await f.net(() => f.app.setThemeMode(ThemeMode.dark));
        await f.pumpFor(const Duration(seconds: 1));
        await f.shot('itag_paired_en_dark');
        await f.net(() => f.app.setThemeMode(ThemeMode.light));
        await f.pumpFor(const Duration(seconds: 1));
      });

      await f.step('permission denied -> reason screen -> Not now -> Allow card stays (no dead end)', () async {
        n.radio = 'no_permission';
        await f.scrollTo(find.byKey(const Key('itag-ring-$_tag')));
        await f.tap(find.byKey(const Key('itag-ring-$_tag')));
        await f.waitFor(find.byKey(const Key('itag-reason')), what: 'reason screen first');
        await f.shot('itag_reason');
        await f.tap(find.byKey(const Key('itag-reason-no')), settleSeconds: 2);
        await f.waitFor(find.byKey(const Key('itag-radio-action')), what: 'Allow button');
        await f.shot('itag_permission_card');
        n.radio = 'ready';
      });

      await f.step('unpair -> card gone, tag disconnected', () async {
        await f.scrollTo(find.byKey(const Key('itag-menu-$_tag')));
        await f.tap(find.byKey(const Key('itag-menu-$_tag')));
        await f.tap(find.byKey(const Key('itag-unpair')));
        await f.tap(find.byKey(const Key('itag-unpair-ok')), settleSeconds: 2);
        await f.waitFor(find.byKey(const Key('itag-add-empty')), what: 'empty state again');
        if (!n.calls.contains('disconnect')) throw TestFailure('tag not disconnected');
      });
    } finally {
      await c.setWatching(false);
      await sound.stop();
      n.uninstall();
      ItagController.instanceForTest = null;
      try {
        await f.app.setLocale(const Locale('en'), syncServer: false);
        await f.app.setThemeMode(ThemeMode.light);
      } catch (_) {}
    }
  }, timeout: const Duration(minutes: 6));
}
