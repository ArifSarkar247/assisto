// bubbles2 (owner FINAL bubbles order, 3 Nov 01:50): the install-day card
// (exact wording, Turn on → re-check → success / honest lines), the "Later"
// schedule, the phone-status decision, in-call bubbles, My Circle's bubble
// row, the native contract (by source text — Kotlin is compiled by the APK
// build only) and "no company names" in our own features.
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/bubble_ask.dart';
import 'package:assisto/messaging/bubble_card.dart';
import 'package:assisto/messaging/in_call_bubbles.dart';
import 'package:assisto/messaging/msg_native.dart';
import 'package:assisto/messaging/msg_settings_section.dart';
import 'package:assisto/widgets/bubble_chats_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _src(String p) => File(p).readAsStringSync();
const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/messaging';

Widget _wrap(Widget child, {String lang = 'en', double scale = 1}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: child,
    );

BubbleStatus _st(String? pref,
        {int sdk = 33, bool? notifs = true, bool? lowRam = false, bool? page = true, bool? phoneOn}) =>
    BubbleStatus.fromMap({
      'sdk': sdk,
      'pref': pref,
      'notifs': notifs,
      'lowRam': lowRam,
      'page': page,
      'phoneOn': phoneOn,
    });

/// Leave the app (the system Bubbles page) and come back.
void _roundTrip(WidgetTester tester) {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  group('phone status (point 6 + 8)', () {
    test('the one decision', () {
      expect(_st('all').ready, BubbleReady.on);
      expect(_st('selected').ready, BubbleReady.selectedOnly);
      expect(_st('none').ready, BubbleReady.off);
      expect(_st('none', sdk: 29).ready, BubbleReady.unsupported); // Android 10
      expect(_st('none', lowRam: true).ready, BubbleReady.blocked); // Go phone
      expect(_st('none', page: false).ready, BubbleReady.blocked); // brand removed it
      expect(_st('none', notifs: false).ready, BubbleReady.notifsOff);
      expect(BubbleStatus.fromMap(null).ready, BubbleReady.unknown);
      expect(_st('none').askable, isTrue);
      expect(_st('selected').askable, isTrue);
      for (final s in [_st('all'), _st('none', sdk: 29), _st('none', lowRam: true)]) {
        expect(s.askable, isFalse);
      }
    });
  });

  group('ask schedule (point 6: install day, first My Circle, +3 days, never)', () {
    final t0 = DateTime(2026, 11, 3, 10);
    bool ask(BubbleAskWhere w, int stage, {DateTime? now, DateTime? last}) =>
        BubbleAskPolicy.shouldAsk(where: w, stage: stage, now: now ?? t0, lastAsk: last);

    test('full path', () {
      expect(ask(BubbleAskWhere.onboarding, 0), isTrue);
      var stage = BubbleAskPolicy.after(BubbleAskWhere.onboarding, 0);
      expect(stage, 1);
      expect(ask(BubbleAskWhere.onboarding, stage), isFalse); // once
      expect(ask(BubbleAskWhere.circleOpen, stage), isTrue); // first My Circle
      stage = BubbleAskPolicy.after(BubbleAskWhere.circleOpen, stage);
      expect(stage, 2);
      expect(ask(BubbleAskWhere.circleOpen, stage,
          now: t0.add(const Duration(days: 2, hours: 23)), last: t0), isFalse);
      expect(ask(BubbleAskWhere.circleOpen, stage,
          now: t0.add(const Duration(days: 3)), last: t0), isTrue);
      stage = BubbleAskPolicy.after(BubbleAskWhere.circleOpen, stage);
      expect(stage, BubbleAskPolicy.finalStage);
      expect(ask(BubbleAskWhere.circleOpen, stage,
          now: t0.add(const Duration(days: 300)), last: t0), isFalse); // never
      expect(ask(BubbleAskWhere.onboarding, stage), isFalse);
    });

    test('an update from an older build: asked at My Circle, then once more', () {
      expect(ask(BubbleAskWhere.circleOpen, 0), isTrue);
      expect(BubbleAskPolicy.after(BubbleAskWhere.circleOpen, 0), 2);
    });

    test('due() reads prefs + the phone; app switch off → never', () async {
      SharedPreferences.setMockInitialValues({});
      BubbleAsk.clock = () => t0;
      BubbleAsk.readStatus = () async => {'sdk': 33, 'pref': 'none', 'notifs': true, 'page': true};
      expect(await BubbleAsk.due(BubbleAskWhere.onboarding), isTrue);
      await BubbleAsk.markAsked(BubbleAskWhere.onboarding);
      expect(await BubbleAsk.due(BubbleAskWhere.onboarding), isFalse);
      expect(await BubbleAsk.due(BubbleAskWhere.circleOpen), isTrue);
      // already on → no ask
      BubbleAsk.readStatus = () async => {'sdk': 33, 'pref': 'all', 'notifs': true};
      expect(await BubbleAsk.due(BubbleAskWhere.circleOpen), isFalse);
      // Android 10: silent
      BubbleAsk.readStatus = () async => {'sdk': 29};
      expect(await BubbleAsk.due(BubbleAskWhere.circleOpen), isFalse);
      // the app's own switch off
      BubbleAsk.readStatus = () async => {'sdk': 33, 'pref': 'none', 'notifs': true};
      SharedPreferences.setMockInitialValues({'c3_bubbles_on': false});
      expect(await BubbleAsk.due(BubbleAskWhere.onboarding), isFalse);
      BubbleAsk.readStatus = MsgNative.bubbleStatus;
      BubbleAsk.clock = DateTime.now;
    });

    test('in-call overlay is a TIME, cleared on exit', () async {
      SharedPreferences.setMockInitialValues({});
      BubbleAsk.clock = () => t0;
      await BubbleAsk.setCallOverlay(true);
      final p = await SharedPreferences.getInstance();
      expect(p.getInt(BubbleAsk.kCallOverlayUntil),
          t0.add(BubbleAsk.overlayTtl).millisecondsSinceEpoch);
      await BubbleAsk.setCallOverlay(false);
      expect(p.getInt(BubbleAsk.kCallOverlayUntil), isNull);
      BubbleAsk.clock = DateTime.now;
    });
  });

  group('the card (exact owner wording, point 7)', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('Turn on → settings → back → success ($lang, 200%)', (tester) async {
        var opened = 0;
        var status = _st('none');
        bool? done;
        await tester.pumpWidget(_wrap(
            Scaffold(
              body: SingleChildScrollView(
                child: BubbleTurnOnCard(
                  initial: status,
                  openSettings: () async {
                    opened++;
                    return true;
                  },
                  readStatus: () async => status,
                  onDone: (on) => done = on,
                ),
              ),
            ),
            lang: lang,
            scale: 2));
        await tester.pumpAndSettle();
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.text(t.bbl2Title), findsOneWidget);
        expect(find.text(t.bbl2Body), findsOneWidget);
        expect(find.text(t.bbl2TurnOn), findsOneWidget);
        expect(find.text(t.bbl2Later), findsOneWidget);
        if (lang == 'en') {
          expect(t.bbl2Title, 'Turn on floating chat bubbles?');
          expect(t.bbl2On, 'Floating chat bubbles are on.');
        } else {
          expect(t.bbl2Title, 'ভাসমান চ্যাট বাবল চালু করবেন?');
          expect(t.bbl2TurnOn, 'চালু করুন');
          expect(t.bbl2Later, 'পরে');
          expect(t.bbl2On, 'ভাসমান চ্যাট বাবল চালু হয়েছে');
        }
        expect(tester.getSize(find.byKey(const Key('bbl2-turn-on'))).height,
            greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(const Key('bbl2-turn-on')));
        await tester.pumpAndSettle();
        expect(opened, 1);
        // the user picked "All conversations can bubble" and came back
        status = _st('all');
        _roundTrip(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bbl2-success')), findsOneWidget);
        expect(find.text(t.bbl2On), findsOneWidget);
        await tester.tap(find.byKey(const Key('bbl2-continue')));
        expect(done, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('came back without choosing "All" → honest how-to', (tester) async {
      var status = _st('selected');
      await tester.pumpWidget(_wrap(Scaffold(
        body: SingleChildScrollView(
          child: BubbleTurnOnCard(
            initial: _st('none'),
            openSettings: () async => true,
            readStatus: () async => status,
            onDone: (_) {},
          ),
        ),
      )));
      await tester.tap(find.byKey(const Key('bbl2-turn-on')));
      await tester.pumpAndSettle();
      _roundTrip(tester);
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.bbl2SelectedOnly), findsOneWidget);
      status = _st('none', phoneOn: false);
      _roundTrip(tester);
      await tester.pumpAndSettle();
      expect(find.text(t.bbl2PhoneSwitch), findsOneWidget);
    });

    testWidgets('phone blocks bubbles → honest line + Continue, no Turn on (bn)',
        (tester) async {
      bool? done;
      await tester.pumpWidget(_wrap(
          Scaffold(
            body: SingleChildScrollView(
              child: BubbleTurnOnCard(
                  initial: _st('none', lowRam: true), onDone: (on) => done = on),
            ),
          ),
          lang: 'bn'));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(t.bbl2Blocked), findsOneWidget);
      expect(find.byKey(const Key('bbl2-turn-on')), findsNothing);
      await tester.tap(find.byKey(const Key('bbl2-continue')));
      expect(done, isFalse);
    });

    testWidgets('Later → onDone(false)', (tester) async {
      bool? done;
      await tester.pumpWidget(_wrap(Scaffold(
          body: SingleChildScrollView(
              child: BubbleTurnOnCard(initial: _st('none'), onDone: (on) => done = on)))));
      await tester.tap(find.byKey(const Key('bbl2-later')));
      expect(done, isFalse);
    });

    testWidgets('install-day screen fits at 200% (bn)', (tester) async {
      await tester.pumpWidget(_wrap(BubbleOnboardingScreen(initial: _st('none')),
          lang: 'bn', scale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('bbl2-title')), findsOneWidget);
    });

    testWidgets('My Circle settings always has Turn on while off', (tester) async {
      await tester.pumpWidget(_wrap(Scaffold(
          body: SingleChildScrollView(
              child: BubbleStatusTile(initial: _st('none'))))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-set-turn-on')), findsOneWidget);
      await tester.pumpWidget(_wrap(Scaffold(
          body: SingleChildScrollView(
              child: BubbleStatusTile(key: const Key('x'), initial: _st('all'))))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-set-on')), findsOneWidget);
    });
  });

  group('in-call bubbles (point 4)', () {
    test('list: newest first, unread counts, cap, read/remove', () {
      final now = DateTime(2026, 11, 3);
      var l = InCallBubbleList.add(const [], 'member:1', name: 'Rina', now: now);
      l = InCallBubbleList.add(l, 'member:2', name: 'Karim', now: now);
      l = InCallBubbleList.add(l, 'member:1', now: now);
      expect(l.map((b) => b.key), ['member:1', 'member:2']);
      expect(l.first.unread, 2);
      expect(l.first.name, 'Rina');
      for (var i = 3; i < 10; i++) {
        l = InCallBubbleList.add(l, 'member:$i', now: now);
      }
      expect(l.length, InCallBubbleList.max);
      l = InCallBubbleList.read(l, 'member:9');
      expect(l.first.unread, 0);
      expect(InCallBubbleList.remove(l, 'member:9').length, InCallBubbleList.max - 1);
    });

    test('bus: only while a call screen holds it; push + realtime de-duplicated', () {
      var now = DateTime(2026, 11, 3, 10);
      final bus = InCallBubbles(clock: () => now);
      bus.onMessage('member:1', name: 'Rina', msgId: 'a');
      expect(bus.items.value, isEmpty); // no call screen
      bus.attach();
      bus.onMessage('member:1', name: 'Rina', msgId: 'a');
      bus.onMessage('member:1', name: 'Rina', msgId: 'a'); // same push twice
      bus.onMessage('member:1'); // its realtime echo
      expect(bus.items.value.single.unread, 1);
      now = now.add(const Duration(seconds: 10));
      bus.onMessage('member:1'); // a later message
      expect(bus.items.value.single.unread, 2);
      bus.onMessage('nonsense');
      expect(bus.items.value.length, 1);
      bus.detach();
      expect(bus.items.value, isEmpty);
    });

    testWidgets('overlay: stack → row of photos → open; ✕ closes; off when PiP',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final bus = InCallBubbles();
      final opened = <String>[];
      Widget host(bool enabled) => _wrap(InCallBubbleHost(
            enabled: enabled,
            bus: bus,
            resolve: (k) async => (name: k == 'member:1' ? 'Rina' : 'Karim', photo: '', photoV: ''),
            onOpen: opened.add,
            child: const Scaffold(body: ColoredBox(color: Colors.black)),
          ));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-call-stack')), findsNothing);
      bus.onMessage('member:1', msgId: '1');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-call-stack')), findsOneWidget);
      bus.onMessage('member:2', msgId: '2');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bbl2-call-stack')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-call-row')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bbl2-call-face-member:1')));
      await tester.pumpAndSettle();
      expect(opened, ['member:1']);
      // drag the stack to ✕
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('bbl2-call-stack'))));
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(find.byKey(const Key('bbl2-call-x')), findsOneWidget);
      await g.moveTo(tester.getCenter(find.byKey(const Key('bbl2-call-x'))));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(bus.items.value, isEmpty);
      // PiP: no in-app overlay (the system bubbles work there)
      bus.onMessage('member:2', msgId: '3');
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl2-call-stack')), findsNothing);
      final p = await SharedPreferences.getInstance();
      expect(p.getInt(BubbleAsk.kCallOverlayUntil), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('My Circle bubble row (point 5)', () {
    test('bubbles on screen first (newest), then unread; known chats only', () {
      final keys = bubbleRowKeys(
        active: [
          {'key': 'member:3', 'bubble': true},
          {'key': 'group:9'},
          {'key': 'member:77'}, // a locked / unknown chat: never shown
        ],
        unread: {'member:5': 1, 'member:6': 4, 'member:3': 2, 'member:8': 0},
        known: {'member:3', 'group:9', 'member:5', 'member:6', 'member:8'},
      );
      expect(keys, ['member:3', 'group:9', 'member:6', 'member:5']);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('row: round photos, unread badge, tap opens ($lang, 200%)',
          (tester) async {
        final opened = <String>[];
        await tester.pumpWidget(_wrap(
            Scaffold(
              body: Column(children: [
                BubbleChatsRow(
                  entries: const [
                    BubbleRowEntry(key: 'member:3', name: 'Rina', unread: 2, floating: true),
                    BubbleRowEntry(key: 'group:9', name: 'Family', group: true, unread: 12),
                  ],
                  onOpen: opened.add,
                ),
              ]),
            ),
            lang: lang,
            scale: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(lang == 'bn' ? '১২' : '12'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('bbl2-row-group:9')));
        expect(opened, ['group:9']);
        expect(tester.getSize(find.byKey(const ValueKey('bbl2-row-member:3'))).height,
            greaterThanOrEqualTo(48));
      });
    }

    testWidgets('no chats → nothing drawn', (tester) async {
      await tester.pumpWidget(_wrap(Scaffold(
          body: BubbleChatsRow(entries: const [], onOpen: (_) {}))));
      expect(find.byKey(const Key('bbl2-circle-row')), findsNothing);
    });
  });

  group('native contract (Kotlin compiled by the APK build)', () {
    test('status, exact page, active chats, in-call TTL', () {
      final h = _src('$_kt/BubbleHelper.kt');
      expect(h, contains('ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS'));
      expect(h, contains('Build.VERSION_CODES.R ->'));
      expect(h, contains('BUBBLE_PREFERENCE_ALL'));
      expect(h, contains('areBubblesAllowed'));
      expect(h, contains('isLowRamDevice'));
      expect(h, contains('FLAG_BUBBLE'));
      expect(h, contains('flutter.c3_call_overlay_until'));
      expect(h, contains('if (inCallOverlay(p)) return false'));
      // auto ON: bubble metadata + long-lived conversation shortcut stay
      expect(h, contains('setBubbleMetadata'));
      expect(h, contains('setLongLived(true)'));
      final c = _src('$_kt/C3MessagingChannel.kt');
      expect(c, contains('"bubbleStatus" ->'));
      expect(c, contains('"activeChats" ->'));
    });

    test('keep list never loses a drawable (b286 avatar + callpip icons)', () {
      final keep = _src('android_overlay/app/src/main/res/raw/assisto_keep.xml');
      expect(keep, contains('c3_person_avatar'));
      expect(keep, contains('ic_pip_'));
    });

    test('install-day step runs right after the notification checklist', () {
      expect(_src('lib/main.dart'), contains('then: maybeAskBubblesOnInstallDay'));
      expect(_src('lib/screens/messenger/messenger_home_screen.dart'),
          contains('maybeAskBubblesAtCircle'));
      expect(_src('lib/screens/circle_call_screen.dart'), contains('InCallBubbleHost('));
    });
  });

  group('no company names in our own features (point 7)', () {
    final names = RegExp(r'messenger|whatsapp|facebook|viber|telegram|imo\b|মেসেঞ্জার|হোয়াটসঅ্যাপ|ফেসবুক',
        caseSensitive: false);
    for (final lang in ['en', 'bn']) {
      test('bubble + My Circle strings ($lang)', () async {
        final t = await AppLocalizations.delegate.load(Locale(lang));
        for (final s in [
          t.bbl2Title, t.bbl2Body, t.bbl2TurnOn, t.bbl2Later, t.bbl2On, t.bbl2How,
          t.bbl2NotYet, t.bbl2SelectedOnly, t.bbl2PhoneSwitch, t.bbl2Blocked,
          t.bbl2NotifsOff, t.bbl2SettingsTitle, t.bbl2SetSub, t.bbl2SettingsOff,
          t.bbl2RowTitle, t.bbl2SettingsCircleSection, t.bbl2FlagPublic,
          t.bbl2ChatOpenFailed, t.bbl2InviteCardBody, t.bblSetSub, t.c3SetBubblesSystem,
        ]) {
          expect(names.hasMatch(s), isFalse, reason: s);
        }
      });
    }

    test('screens use the new keys', () {
      expect(_src('lib/screens/settings_screen.dart'), contains('t.bbl2SettingsCircleSection'));
      expect(_src('lib/screens/admin/cost_flags_screen.dart'), contains('t.bbl2FlagPublic'));
      expect(_src('lib/screens/messenger/contacts_screen.dart'), contains('bbl2ChatOpenFailed'));
      expect(_src('lib/widgets/contacts_match_model.dart'), contains('bbl2InviteCardBody'));
    });
  });
}
