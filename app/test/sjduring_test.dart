import 'dart:async';

// sjduring: Safe Journey V2 DURING — the private route-change / stop screen
// (exact button order + notes, family sees only "Time extended"), the
// traveller panel (ask opens by itself, PIN on an abnormal arrival: wrong ->
// retry, safe -> Arrived, danger -> the SAME Arrived + quiet clip), and the
// watcher board (count, late-but-moving never red, near note, badges).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/screens/safe_journey/sj_danger_audio.dart';
import 'package:assisto/screens/safe_journey/sj_during_panel.dart';
import 'package:assisto/screens/safe_journey/sj_private_ask_screen.dart';
import 'package:assisto/screens/safe_journey/sj_watch_board.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'sjduring_shots_test.dart' show SjdApi, sjdAskRoute, sjdBoardActive, sjdBoardFinished,
    sjdDuring, sjdWatching;

Future<SjdApi> _pump(WidgetTester tester, Widget home, {String lang = 'en', SjdApi? api,
    Size size = const Size(400, 1400)}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  AddressResolver.debugPhone = (lat, lng, l) async => lat < 23.83 ? 'Badda' : 'Uttara';
  addTearDown(() => AddressResolver.debugPhone = null);
  final a = api ?? SjdApi(lang);
  final app = AppState()
    ..api = a
    ..user = AppUser(id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2,
        language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: home,
    ),
  ));
  await tester.pumpAndSettle();
  return a;
}

// sosfam-crm-proof: the watch-board answer waits until the test releases it.
class _SlowBoardApi extends SjdApi {
  _SlowBoardApi(super.lang);
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/watch-board') await _gate.future;
    return super.getJson(path);
  }
}

double _y(WidgetTester t, String k) => t.getTopLeft(find.byKey(ValueKey(k))).dy;

void main() {
  group('private route-change screen', () {
    testWidgets('notes + buttons in the owner order; from/to area names', (t) async {
      await _pump(t, SjPrivateAskScreen(journeyId: 5, ask: sjdAskRoute()));
      expect(find.text('Only on your phone — the family does not know yet'), findsOneWidget);
      expect(find.text('Changed route?'), findsWidgets);
      expect(find.text('From Badda to Uttara'), findsOneWidget);
      expect(find.text('The family sees only “Time extended”'), findsOneWidget);
      expect(find.textContaining('If you do not answer in 5 minutes'), findsOneWidget);
      final order = ['sjd_only_you', 'sjd_ask_card', 'sjd_extend', 'sjd_share', 'sjd_ok',
        'sjd_danger', 'sjd_bottom_note'];
      for (var i = 1; i < order.length; i++) {
        expect(_y(t, order[i]), greaterThan(_y(t, order[i - 1])), reason: order[i]);
      }
      // default 40 minutes selected
      expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('sjd_min_40'))).selected, isTrue);
      // 48dp targets
      for (final k in ['sjd_extend', 'sjd_share', 'sjd_ok', 'sjd_danger']) {
        expect(t.getSize(find.byKey(ValueKey(k))).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('Yes, add time sends the picked minutes', (t) async {
      final api = await _pump(t, Scaffold(body: Builder(builder: (c) => TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute(
              builder: (_) => SjPrivateAskScreen(journeyId: 5, ask: sjdAskRoute()))),
          child: const Text('open')))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sjd_min_60')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('sjd_extend')));
      await t.pumpAndSettle();
      expect(api.posts.last, '/journey/5/answer');
      expect(api.bodies.last, {'action': 'extend', 'minutes': 60});
      expect(find.byType(SjPrivateAskScreen), findsNothing);
    });

    testWidgets('Bangla: Bangla digits, no Latin digits on the chips', (t) async {
      await _pump(t, SjPrivateAskScreen(journeyId: 5, ask: sjdAskRoute()), lang: 'bn');
      expect(find.text('৪০ মিনিট'), findsOneWidget);
      expect(find.text('শুধু আপনার ফোনে — পরিবার এখনো জানে না'), findsOneWidget);
    });
  });

  group('traveller panel', () {
    testWidgets('a pending ask opens the private screen by itself', (t) async {
      final api = SjdApi('en')..during = sjdDuring(ask: sjdAskRoute());
      await _pump(t, Scaffold(body: ListView(children: [
        SjDuringPanel(journeyId: 5, poll: false, onArrived: (_) {}, onDanger: () {}),
      ])), api: api);
      expect(find.byType(SjPrivateAskScreen), findsOneWidget);
    });

    // sosfam-crm-proof: reality 44220546983 — the journey screen closed while
    // the watch-board read was in flight; _react then used a dead context and
    // the framework error broke every later flow on the phone.
    testWidgets('closing during the watch-board read throws nothing', (t) async {
      final api = _SlowBoardApi('en')..during = sjdDuring(state: 'slow');
      await _pump(t, Scaffold(body: ListView(children: [
        SjDuringPanel(journeyId: 5, poll: false, onArrived: (_) {}, onDanger: () {}),
      ])), api: api);
      await t.pumpWidget(const SizedBox()); // the panel goes away mid-load
      api.release();
      await t.pump(const Duration(milliseconds: 50));
      expect(t.takeException(), isNull);
    });

    testWidgets('late while moving shows Slow in traffic, no alarm words', (t) async {
      final api = SjdApi('en')..during = sjdDuring(state: 'slow');
      await _pump(t, Scaffold(body: ListView(children: [
        SjDuringPanel(journeyId: 5, poll: false, onArrived: (_) {}, onDanger: () {}),
      ])), api: api);
      expect(find.text('Slow in traffic'), findsOneWidget);
      expect(find.textContaining('late'), findsNothing);
    });

    testWidgets('PIN: wrong -> retry; danger -> the same Arrived + quiet clip', (t) async {
      final clips = <int>[];
      sjRecordDangerClip = (api, id) async => clips.add(id);
      addTearDown(() => sjRecordDangerClip = (a, i) async {});
      final api = SjdApi('en')
        ..during = sjdDuring(state: 'nearly', pinWait: {'why': ['too_early'], 'at': 'x'})
        ..pinAnswers = [
          {'ok': false, 'pin': 'wrong', '_status': 400},
          {'ok': true, 'status': 'arrived', 'state': 'arrived', 'k': 1, '_status': 200},
        ];
      bool? kept;
      await _pump(t, Scaffold(body: ListView(children: [
        SjDuringPanel(journeyId: 5, poll: false, onArrived: (k) => kept = k, onDanger: () {}),
      ])), api: api);
      expect(find.text('Enter your PIN to finish'), findsWidgets);
      expect(find.text('Arriving this early is not possible, so your PIN is needed.'), findsOneWidget);
      await t.enterText(find.byType(TextField), '0000');
      await t.tap(find.byKey(const ValueKey('sjd_pin_ok')));
      await t.pumpAndSettle();
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      await t.enterText(find.byType(TextField), '1357');
      await t.tap(find.byKey(const ValueKey('sjd_pin_ok')));
      await t.pumpAndSettle();
      expect(kept, isTrue);          // the location goes on for the watchers
      expect(clips, [5]);
    });

    testWidgets('safe PIN -> Arrived, tracking ends', (t) async {
      final api = SjdApi('en')
        ..during = sjdDuring(state: 'nearly', pinWait: {'why': ['off_route'], 'at': 'y'})
        ..pinAnswers = [
          {'ok': true, 'status': 'arrived', 'state': 'arrived', 'k': 0, '_status': 200},
        ];
      bool? kept;
      await _pump(t, Scaffold(body: ListView(children: [
        SjDuringPanel(journeyId: 5, poll: false, onArrived: (k) => kept = k, onDanger: () {}),
      ])), api: api);
      expect(find.text('You changed route or stopped for long, so your PIN is needed.'),
          findsOneWidget);
      await t.enterText(find.byType(TextField), '2468');
      await t.tap(find.byKey(const ValueKey('sjd_pin_ok')));
      await t.pumpAndSettle();
      expect(kept, isFalse);
    });
  });

  group('watcher board', () {
    testWidgets('active count, finished badges, near note, amber/red, never late-red', (t) async {
      final api = SjdApi('en')
        ..watching = sjdWatching('en')
        ..board = {'count': 5, 'active': sjdBoardActive('en'), 'finished': sjdBoardFinished('en')};
      await _pump(t, const JourneyWatchScreen(), api: api, size: const Size(400, 4000));
      expect(find.text('Active journeys (5)'), findsOneWidget);
      expect(find.text('Finished journeys'), findsOneWidget);
      expect(find.byKey(const ValueKey('sjd_near_note')), findsOneWidget);
      expect(find.text('Check on Tania'), findsOneWidget);
      expect(find.text('Urgent — call now'), findsOneWidget);
      expect(find.text('Confirmed with PIN'), findsNWidgets(2));
      expect(find.text('Unusually fast arrival, PIN asked'), findsOneWidget);
      expect(find.text('Play the 30-second audio'), findsOneWidget);
      expect(find.textContaining('The battery probably ran out'), findsOneWidget);
      // overdue_state = alert on every row, yet V2 cards never say "late"
      final ctx = t.element(find.byType(JourneyWatchScreen));
      expect(find.text(AppLocalizations.of(ctx).j100StLate), findsNothing);
      expect(_y(t, 'sjd_finished_head'), greaterThan(_y(t, 'sjd_active_head')));
    });

    testWidgets('Family tile: count in Bangla digits, opens the list', (t) async {
      final api = SjdApi('bn')
        ..board = {'count': 2, 'active': sjdBoardActive('bn').take(2).toList(), 'finished': []};
      await _pump(t, const Scaffold(body: SjActiveJourneysTile()), api: api, lang: 'bn');
      expect(find.text('চলমান যাত্রা (২)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sjd_family_tile')));
      await t.pumpAndSettle();
      expect(find.byType(JourneyWatchScreen), findsOneWidget);
    });

    testWidgets('Family tile: nobody travelling says so (no dead tile)', (t) async {
      await _pump(t, const Scaffold(body: SjActiveJourneysTile()));
      expect(find.text('Nobody is travelling now'), findsOneWidget);
    });
  });

  test('ApiClient type is the app client', () {
    expect(SjdApi('en'), isA<ApiClient>());
  });
}
