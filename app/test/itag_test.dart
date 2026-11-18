// flag-itag (W7): Bluetooth iTag tag — a BLE fake drives pair / ring /
// disconnect ("left behind") / button ("find my phone") / battery / unpair,
// the permission flow (reason screen first, "Not now" never asks Android),
// and the placement guards (never on child or safety screens).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_registry.dart';
import 'package:assisto/itag/itag_controller.dart';
import 'package:assisto/itag/itag_platform.dart';
import 'package:assisto/itag/itag_store.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/itag/itag_alert.dart';
import 'package:assisto/screens/itag/itag_permission.dart';
import 'package:assisto/screens/itag/itag_screen.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:assisto/widgets/chatnav.dart';

const _a = 'AA:BB:CC:DD:EE:01';
const _found = ItagFound(_a, 'iTAG', -50, true);

class FakeItag implements ItagPlatform {
  ItagRadioState st = const ItagRadioState(ItagRadio.ready, 33);
  ItagRadioState? afterAsk;
  List<ItagFound> found = const [_found, ItagFound('11:22:33:44:55:66', 'Band', -40, false)];
  bool connectOk = true;
  int? batt = 87;
  final rings = <int>[];
  final linkLosses = <int>[];
  final disconnects = <String>[];
  int connects = 0;
  int settings = 0;
  final _ev = StreamController<ItagEvent>.broadcast();

  void emit(ItagEventType t, {bool user = false}) => _ev.add(ItagEvent(t, _a, user: user));

  @override
  Future<ItagRadioState> state() async => st;
  @override
  Future<List<ItagFound>> scan({Duration duration = const Duration(seconds: 8)}) async => found;
  @override
  Future<bool> connect(String address) async {
    connects++;
    return connectOk;
  }

  @override
  Future<bool> ring(String address, int level) async {
    rings.add(level);
    return true;
  }

  @override
  Future<bool> linkLoss(String address, int level) async {
    linkLosses.add(level);
    return true;
  }

  @override
  Future<int?> battery(String address) async => batt;
  @override
  Future<void> disconnect(String address) async => disconnects.add(address);
  @override
  Future<void> openSettings() async => settings++;
  @override
  Stream<ItagEvent> get events => _ev.stream;
}

class FakeSound implements DestAlarmSound {
  int starts = 0;
  int stops = 0;
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    starts++;
    return true;
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<bool> speak(String text, String lang) async => true;
  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
}

ItagController _ctl(FakeItag p, FakeSound s, {ItagLocate? locate}) => ItagController(
      platform: p,
      sound: s,
      locate: locate ?? () async => const ItagPlace(23.81, 90.41, 1700000000000),
      grace: const Duration(seconds: 10),
    );

Widget _app(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      theme: ThemeData(useMaterial3: true),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('controller (BLE fake)', () {
    testWidgets('pair -> saved on this phone, battery read, link-loss off', (tester) async {
      final p = FakeItag();
      final c = _ctl(p, FakeSound());
      await c.load();
      expect(await c.pair(_found, 'Keys'), isTrue);
      await tester.pump();
      expect(c.tags.single.name, 'Keys');
      expect(c.connected, contains(_a));
      expect(p.linkLosses, [kItagAlertOff]);
      expect(c.tags.single.battery, 87);
      final saved = await ItagStore().load();
      expect(saved.single.address, _a);
      expect(saved.single.battery, 87);
      c.dispose();
    });

    testWidgets('pair fails when the tag does not connect', (tester) async {
      final p = FakeItag()..connectOk = false;
      final c = _ctl(p, FakeSound());
      await c.load();
      expect(await c.pair(_found, 'Keys'), isFalse);
      expect(c.tags, isEmpty);
      c.dispose();
    });

    testWidgets('ring my tag writes alert level 2, stop writes 0, auto-stops', (tester) async {
      final p = FakeItag();
      final c = _ctl(p, FakeSound());
      await c.load();
      await c.pair(_found, 'Keys');
      expect(await c.ringTag(_a), isTrue);
      expect(p.rings, [kItagAlertHigh]);
      expect(c.tagRinging, contains(_a));
      await c.stopTag(_a);
      expect(p.rings, [kItagAlertHigh, kItagAlertOff]);
      await c.ringTag(_a);
      await tester.pump(const Duration(seconds: 21));
      expect(c.tagRinging, isEmpty);
      expect(p.rings.last, kItagAlertOff);
      c.dispose();
    });

    testWidgets('disconnect while watching -> last seen saved, alarm after grace',
        (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      final alerts = <ItagAlertKind>[];
      c.onAlert = (k, _) => alerts.add(k);
      await c.load();
      await c.pair(_found, 'Bag');
      await c.setWatching(true);
      expect(p.linkLosses.last, kItagAlertHigh); // the tag beeps too
      p.connectOk = false; // walked away: reconnects fail
      p.emit(ItagEventType.disconnected);
      await tester.pump();
      await tester.pump();
      expect(c.tags.single.lastSeen?.lat, 23.81);
      expect(s.starts, 0); // no alarm before the grace time
      await tester.pump(const Duration(seconds: 11));
      expect(c.leftBehind, _a);
      expect(s.starts, 1);
      expect(alerts, [ItagAlertKind.leftBehind]);
      // back in reach -> the alarm stops by itself
      p.emit(ItagEventType.connected);
      await tester.pump();
      expect(c.leftBehind, isNull);
      expect(s.stops, greaterThanOrEqualTo(1));
      await c.setWatching(false);
      c.dispose();
    });

    testWidgets('a short drop that reconnects never alarms', (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      await c.pair(_found, 'Bag');
      await c.setWatching(true);
      p.emit(ItagEventType.disconnected);
      await tester.pump();
      p.emit(ItagEventType.connected);
      await tester.pump(const Duration(seconds: 11));
      expect(c.leftBehind, isNull);
      expect(s.starts, 0);
      await c.setWatching(false);
      c.dispose();
    });

    testWidgets('disconnect without "watch my bag" saves the place but never alarms',
        (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      await c.pair(_found, 'Bag');
      p.emit(ItagEventType.disconnected);
      await tester.pump(const Duration(seconds: 30));
      expect(c.tags.single.lastSeen, isNotNull);
      expect(s.starts, 0);
      c.dispose();
    });

    testWidgets('no location permission -> no place saved (never asked here)', (tester) async {
      final p = FakeItag();
      final c = _ctl(p, FakeSound(), locate: () async => null);
      await c.load();
      await c.pair(_found, 'Bag');
      p.emit(ItagEventType.disconnected);
      await tester.pump();
      expect(c.tags.single.lastSeen, isNull);
      c.dispose();
    });

    testWidgets('tag button rings the phone; second press stops; setting off = silent',
        (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      final alerts = <ItagAlertKind>[];
      c.onAlert = (k, _) => alerts.add(k);
      await c.load();
      await c.pair(_found, 'Keys');
      p.emit(ItagEventType.button);
      await tester.pump();
      expect(c.phoneRinging, isTrue);
      expect(s.starts, 1);
      expect(alerts, [ItagAlertKind.findPhone]);
      p.emit(ItagEventType.button);
      await tester.pump();
      expect(c.phoneRinging, isFalse);
      expect(s.stops, 1);
      await c.setButtonRingsPhone(false);
      p.emit(ItagEventType.button);
      await tester.pump();
      expect(c.phoneRinging, isFalse);
      expect(s.starts, 1);
      c.dispose();
    });

    testWidgets('phone ring stops by itself after 30 s', (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      await c.pair(_found, 'Keys');
      p.emit(ItagEventType.button);
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(c.phoneRinging, isFalse);
      expect(s.stops, 1);
      c.dispose();
    });

    testWidgets('a button press from an unknown tag is ignored', (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      p.emit(ItagEventType.button);
      await tester.pump();
      expect(s.starts, 0);
      c.dispose();
    });

    testWidgets('unpair forgets the tag + disconnects; user disconnect never alarms',
        (tester) async {
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      await c.pair(_found, 'Bag');
      await c.setWatching(true);
      await c.unpair(_a);
      p.emit(ItagEventType.disconnected, user: true);
      await tester.pump(const Duration(seconds: 20));
      expect(c.tags, isEmpty);
      expect(p.disconnects, [_a]);
      expect(await ItagStore().load(), isEmpty);
      expect(c.watching, isFalse); // no tag left to watch
      expect(s.starts, 0);
      c.dispose();
    });
  });

  group('permission flow', () {
    testWidgets('reason screen first; "Not now" never asks Android', (tester) async {
      final p = FakeItag()..st = const ItagRadioState(ItagRadio.noPermission, 33);
      var asked = 0;
      ItagReady? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              key: const Key('go'),
              onPressed: () async => got = await itagEnsureReady(ctx, p, ask: (_) async {
                    asked++;
                    return ItagAsk.granted;
                  }),
              child: const Text('go')))));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('itag-reason')), findsOneWidget);
      await tester.tap(find.byKey(const Key('itag-reason-no')));
      await tester.pumpAndSettle();
      expect(asked, 0);
      expect(got, ItagReady.notNow);
    });

    testWidgets('Continue -> Android 12+ asks nearby devices, then ready', (tester) async {
      final p = FakeItag()..st = const ItagRadioState(ItagRadio.noPermission, 33);
      final nearby = <bool>[];
      ItagReady? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              key: const Key('go'),
              onPressed: () async => got = await itagEnsureReady(ctx, p, ask: (n) async {
                    nearby.add(n);
                    p.st = const ItagRadioState(ItagRadio.ready, 33);
                    return ItagAsk.granted;
                  }),
              child: const Text('go')))));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nearby devices'), findsWidgets);
      await tester.tap(find.byKey(const Key('itag-reason-yes')));
      await tester.pumpAndSettle();
      expect(nearby, [true]);
      expect(got, ItagReady.ready);
    });

    testWidgets('Android 8–11: the reason names location; blocked is reported',
        (tester) async {
      final p = FakeItag()..st = const ItagRadioState(ItagRadio.noPermission, 29);
      final nearby = <bool>[];
      ItagReady? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              key: const Key('go'),
              onPressed: () async => got = await itagEnsureReady(ctx, p, ask: (n) async {
                    nearby.add(n);
                    return ItagAsk.blocked;
                  }),
              child: const Text('go')))));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.textContaining('location permission'), findsOneWidget);
      await tester.tap(find.byKey(const Key('itag-reason-yes')));
      await tester.pumpAndSettle();
      expect(nearby, [false]);
      expect(got, ItagReady.blocked);
    });

    testWidgets('ready radio never shows the reason screen', (tester) async {
      final p = FakeItag();
      ItagReady? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              key: const Key('go'),
              onPressed: () async => got = await itagEnsureReady(ctx, p,
                  ask: (_) async => fail('must not ask')),
              child: const Text('go')))));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('itag-reason')), findsNothing);
      expect(got, ItagReady.ready);
    });
  });

  group('screen', () {
    for (final loc in const [Locale('en'), Locale('bn')]) {
      testWidgets('empty state -> scan -> pair -> ring -> unpair (${loc.languageCode})',
          (tester) async {
        _tall(tester);
        final p = FakeItag();
        final c = _ctl(p, FakeSound());
        await tester.pumpWidget(_app(
            ItagScreen(controller: c, locationAllowed: () async => true),
            locale: loc));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('itag-add-empty')), findsOneWidget);
        await tester.tap(find.byKey(const Key('itag-add-empty')));
        await tester.pumpAndSettle();
        // the likely iTag is listed first
        expect(find.byKey(const Key('itag-found-$_a')), findsOneWidget);
        await tester.tap(find.byKey(const Key('itag-found-$_a')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('itag-name')), 'Keys');
        await tester.tap(find.byKey(const Key('itag-name-ok')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('itag-tag-$_a')), findsOneWidget);
        expect(find.byKey(const Key('itag-battery-$_a')), findsOneWidget);
        if (loc.languageCode == 'bn') {
          expect(find.textContaining('৮৭'), findsOneWidget); // Bangla digits
          expect(find.textContaining('87'), findsNothing);
        }
        await tester.tap(find.byKey(const Key('itag-ring-$_a')));
        await tester.pumpAndSettle();
        expect(p.rings, [kItagAlertHigh]);
        await tester.tap(find.byKey(const Key('itag-ring-$_a')));
        await tester.pumpAndSettle();
        expect(p.rings, [kItagAlertHigh, kItagAlertOff]);
        // watch my bag -> visible banner
        await tester.tap(find.byKey(const Key('itag-watch')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('itag-watch-banner')), findsOneWidget);
        await tester.tap(find.byKey(const Key('itag-watch')));
        await tester.pumpAndSettle();
        // unpair (confirmed)
        await tester.tap(find.byKey(const Key('itag-menu-$_a')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('itag-unpair')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('itag-unpair-ok')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('itag-tag-$_a')), findsNothing);
        expect(p.disconnects, [_a]);
        expect(tester.takeException(), isNull);
        c.dispose();
      });
    }

    testWidgets('Bluetooth off -> a card with a working Turn on button', (tester) async {
      _tall(tester);
      final p = FakeItag()..st = const ItagRadioState(ItagRadio.off, 33);
      final c = _ctl(p, FakeSound());
      await tester.pumpWidget(
          _app(ItagScreen(controller: c, locationAllowed: () async => true)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('itag-radio-action')));
      await tester.pumpAndSettle();
      expect(p.settings, 1);
      c.dispose();
    });

    testWidgets('left-behind alert screen: Stop silences, closes', (tester) async {
      _tall(tester);
      final p = FakeItag();
      final s = FakeSound();
      final c = _ctl(p, s);
      await c.load();
      await c.pair(_found, 'Bag');
      await c.setWatching(true);
      p.connectOk = false;
      p.emit(ItagEventType.disconnected);
      await tester.pump(const Duration(seconds: 11));
      expect(c.leftBehind, _a);
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              key: const Key('open'),
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                  builder: (_) => ItagAlertScreen(
                      controller: c, kind: ItagAlertKind.leftBehind, tagName: 'Bag'))),
              child: const Text('open')))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('itag-alert-left')), findsOneWidget);
      await tester.tap(find.byKey(const Key('itag-alert-stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('itag-alert-left')), findsNothing);
      expect(c.leftBehind, isNull);
      await c.setWatching(false);
      c.dispose();
    });
  });

  group('placement', () {
    test('behind the server switch itag_tags (OFF), routed + in the drawer', () {
      expect(kFeatureDefaults['itag_tags'], isFalse);
      expect(kRouteFeature['itag_tags'], 'itag_tags');
      // switch OFF: no entry anywhere, a stale link opens "not available"
      expect(ChatNav.routes.containsKey('itag_tags'), isFalse);
      expect(ChatNav.builderFor('itag_tags'), isNotNull);
    });

    test('never on child or safety screens', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final p = f.path.replaceAll('\\', '/');
        if (!p.endsWith('.dart')) continue;
        final low = p.toLowerCase();
        final safety = low.contains('kid') ||
            low.contains('child') ||
            low.contains('sos') ||
            low.contains('family') ||
            low.contains('safe_journey') ||
            low.contains('emergency') ||
            low.contains('school');
        if (safety && f.readAsStringSync().contains('ItagScreen')) bad.add(p);
      }
      expect(bad, isEmpty);
      final sb = File('lib/widgets/sidebar_sections.dart').readAsStringSync();
      final item = sb.indexOf("feature: 'itag_tags'");
      final section = sb.lastIndexOf('SidebarSection(', item);
      expect(sb.substring(section, section + 40), contains("'home_life'"));
    });

    test('the native channel stays lazy, never scans in the background', () {
      final k = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/itag/ItagChannel.kt')
          .readAsStringSync();
      final reg = k.substring(k.indexOf('fun register('), k.indexOf('// ---- state'));
      expect(reg.contains('getSystemService'), isFalse);
      expect(k.contains('startForeground'), isFalse);
      expect(k.contains('PendingIntent'), isFalse); // no background scan
      expect(File('android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt')
          .readAsStringSync(), contains('ItagChannel.register('));
    });
  });
}
