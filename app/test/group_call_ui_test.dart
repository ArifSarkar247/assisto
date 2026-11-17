// group-calls: the group call screen (8-tile grid, ringing / mic-off /
// speaking, controls, ended reasons), the Add person picker (search,
// checkboxes, 8-people limit, never a dead end) and the group chat's Join
// call bar — bn + en, 200 % text at 360 px, dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/group_add_people_sheet.dart';
import 'package:assisto/calls/group_call_controller.dart';
import 'package:assisto/calls/group_call_join_bar.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/group_call_screen.dart';

import 'group_call_fakes.dart';

Widget app(Widget home,
        {String lang = 'en', double scale = 1, bool dark = false}) =>
    MaterialApp(
      locale: Locale(lang),
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

void phone(WidgetTester tester, {double h = 760}) {
  tester.view.physicalSize = Size(360, h) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// A live 8-person call seen by person 1: 2..5 joined (3 muted), 6..8
/// ringing. Built without timers running in the widget test zone.
Future<GroupCallController> eightPeople(WidgetTester tester) async {
  final hub = Hub();
  final c = phoneFor(hub, 1);
  await tester.runAsync(() async {
    hub.hostStart(1, [2, 3, 4, 5, 6, 7, 8]);
    for (final u in [2, 3, 4, 5]) {
      hub.state[u] = 'joined';
    }
    hub.muted[3] = true;
    await c.start(initial: hub.snap(1));
  });
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('group call screen', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('8 tiles: ringing, mic-off, controls fit at 200 % ($lang)',
          (tester) async {
        phone(tester);
        final t = lookupAppLocalizations(Locale(lang));
        final c = await eightPeople(tester);
        await tester.pumpWidget(app(
            GroupCallScreen(roomId: 1, controller: c),
            lang: lang,
            scale: 2));
        await tester.pump();
        for (var u = 1; u <= 8; u++) {
          expect(find.byKey(Key('gcall-tile-$u')), findsOneWidget,
              reason: 'tile $u');
        }
        expect(find.byKey(const Key('gcall-mic-off')), findsOneWidget);
        expect(find.textContaining(t.gcallRinging), findsNWidgets(3));
        for (final k in [
          'gcall-speaker',
          'gcall-mute',
          'gcall-add',
          'gcall-leave'
        ]) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        expect(find.byKey(const Key('gcall-camera')), findsNothing,
            reason: 'audio call: no camera button');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => c.dispose());
      });
    }

    testWidgets('speaking person gets the green border + icon (dark)',
        (tester) async {
      phone(tester);
      final c = await eightPeople(tester);
      c.tiles.firstWhere((x) => x.userId == 2).speaking = true;
      await tester.pumpWidget(
          app(GroupCallScreen(roomId: 1, controller: c), dark: true));
      await tester.pump();
      expect(find.byKey(const Key('gcall-speaking')), findsOneWidget);
      final box = tester.widget<AnimatedContainer>(
          find.byKey(const Key('gcall-tile-2')));
      final deco = box.decoration! as BoxDecoration;
      expect((deco.border! as Border).top.width, 3);
      expect((deco.border! as Border).top.color, isNot(Colors.transparent));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => c.dispose());
    });

    testWidgets('video call shows camera + flip', (tester) async {
      phone(tester);
      final hub = Hub(kind: 'video');
      final c = phoneFor(hub, 1, video: true);
      await tester.runAsync(() async {
        hub.hostStart(1, [2]);
        hub.state[2] = 'joined';
        await c.start(initial: hub.snap(1));
      });
      await tester.pumpWidget(app(GroupCallScreen(roomId: 1, controller: c),
          lang: 'bn', scale: 2));
      await tester.pump();
      expect(find.byKey(const Key('gcall-camera')), findsOneWidget);
      expect(find.byKey(const Key('gcall-flip')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => c.dispose());
    });

    test('ended / error lines are honest', () {
      final t = lookupAppLocalizations(const Locale('bn'));
      expect(endLine(t, GroupEndReason.full), t.gcallFull);
      expect(endLine(t, GroupEndReason.mediaDenied), t.gcallMicDenied);
      expect(endLine(t, GroupEndReason.ended), t.gcallEndedAll);
      expect(groupErrorLine(t, const GroupCallError('upgrade_required')),
          t.gcallVideoPremium);
      expect(groupErrorLine(t, const GroupCallError('full')), t.gcallFull);
      expect(groupRoomOf(const {'room_id': '12'}), 12);
      expect(groupRoomOf(const {'room_id': ''}), isNull);
      expect(groupRoomOf(const {}), isNull);
    });

    test('add result line names who rings and who could not be added', () {
      final t = lookupAppLocalizations(const Locale('en'));
      final tiles = [
        GroupTile(userId: 5, name: 'Eti'),
        GroupTile(userId: 6, name: 'Fahim'),
      ];
      final line = addResultLine(
          t,
          [
            {'user_id': 5, 'ok': true},
            {'user_id': 6, 'ok': false, 'code': 'unavailable'},
            {'user_id': 7, 'ok': false, 'code': 'full'},
          ],
          tiles);
      expect(line, contains(t.gcallRingingNames('Eti')));
      expect(line, contains(t.gcallCouldNotAdd('Fahim')));
      expect(line, contains(t.gcallFull));
    });
  });

  group('add person picker', () {
    final people = [
      {'user_id': 2, 'name': 'Babu', 'in_call': true},
      {'user_id': 3, 'name': 'Chaya', 'in_call': false},
      {'user_id': 4, 'name': 'Dipu', 'in_call': false},
    ];

    for (final lang in ['en', 'bn']) {
      testWidgets('search + checkboxes + limit; in-call locked ($lang)',
          (tester) async {
        phone(tester, h: 1600);
        List<int>? done;
        await tester.pumpWidget(app(
            Scaffold(
                body: GroupAddPeoplePanel(
                    load: () async => people,
                    free: 1,
                    onDone: (ids) => done = ids,
                    onClose: () {})),
            lang: lang,
            scale: 2));
        await tester.pumpAndSettle();
        // in the call: ticked, locked
        final babu = tester.widget<CheckboxListTile>(
            find.byKey(const Key('gcall-pick-2')));
        expect(babu.value, isTrue);
        expect(babu.onChanged, isNull);
        // ring button is off until someone is picked
        await tester.tap(find.byKey(const Key('gcall-pick-3')));
        await tester.pump();
        // only 1 place left: Dipu is locked now
        expect(
            tester
                .widget<CheckboxListTile>(find.byKey(const Key('gcall-pick-4')))
                .onChanged,
            isNull);
        await tester.enterText(find.byKey(const Key('gcall-pick-search')), 'dip');
        await tester.pump();
        expect(find.byKey(const Key('gcall-pick-3')), findsNothing);
        expect(find.byKey(const Key('gcall-pick-4')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('gcall-pick-search')), 'zz');
        await tester.pump();
        expect(find.byKey(const Key('gcall-pick-nomatch')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('gcall-pick-search')), '');
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('gcall-pick-ring')));
        await tester.tap(find.byKey(const Key('gcall-pick-ring')));
        await tester.pump();
        expect(done, [3]);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nobody to add -> benefit + how-to + close (no dead end)',
        (tester) async {
      phone(tester);
      var closed = false;
      await tester.pumpWidget(app(Scaffold(
          body: GroupAddPeoplePanel(
              load: () async => const [],
              onDone: (_) {},
              onClose: () => closed = true))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gcall-pick-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gcall-pick-empty-close')));
      expect(closed, isTrue);
    });

    testWidgets('offline -> retry', (tester) async {
      phone(tester);
      var n = 0;
      await tester.pumpWidget(app(Scaffold(
          body: GroupAddPeoplePanel(
              load: () async {
                n++;
                if (n == 1) throw Exception('offline');
                return people;
              },
              onDone: (_) {},
              onClose: () {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gcall-pick-error')), findsOneWidget);
      await tester
          .tap(find.text(lookupAppLocalizations(const Locale('en')).retry));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gcall-pick-3')), findsOneWidget);
    });
  });

  group('join call bar', () {
    Future<void> pumpBar(WidgetTester tester, Map<String, dynamic>? call,
        {String lang = 'en', void Function(int, String)? onJoin}) async {
      phone(tester);
      await tester.pumpWidget(app(
          Scaffold(
              body: GroupCallJoinBar(
                  load: () async => call,
                  every: const Duration(hours: 1),
                  onJoin: onJoin ?? (_, __) {})),
          lang: lang,
          scale: 2));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('live call -> bar + Join (bn)', (tester) async {
      final t = lookupAppLocalizations(const Locale('bn'));
      (int, String)? joined;
      await pumpBar(
          tester,
          {
            'room_id': 7,
            'kind': 'voice',
            'joined': 3,
            'free': 5,
            'my_state': 'declined'
          },
          lang: 'bn',
          onJoin: (r, k) => joined = (r, k));
      expect(find.byKey(const Key('gcall-join-bar')), findsOneWidget);
      expect(find.text(t.gcallJoinBar('\u09E9')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gcall-join')));
      expect(joined, (7, 'voice'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('no call / already in it -> nothing', (tester) async {
      await pumpBar(tester, null);
      expect(find.byKey(const Key('gcall-join-bar')), findsNothing);
      await pumpBar(tester, {
        'room_id': 7,
        'kind': 'voice',
        'joined': 2,
        'free': 6,
        'my_state': 'joined'
      });
      expect(find.byKey(const Key('gcall-join-bar')), findsNothing);
    });

    testWidgets('full call -> the Bangla limit line, no Join', (tester) async {
      final t = lookupAppLocalizations(const Locale('bn'));
      await pumpBar(
          tester,
          {
            'room_id': 7,
            'kind': 'video',
            'joined': 8,
            'free': 0,
            'my_state': ''
          },
          lang: 'bn');
      expect(find.text(t.gcallFull), findsOneWidget);
      expect(find.byKey(const Key('gcall-join')), findsNothing);
    });
  });
}
