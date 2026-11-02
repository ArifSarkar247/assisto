// sjlive (owner Safe Journey final order 3 Nov): the three cards with Live
// Location selected by default, card 1's four buttons, Who is where now with
// honest accuracy / age, the real-life rows, Share for a While (what is
// sent), Request Location (location only, consent states), Child School
// (holidays, gate camera only when linked) and the tracker's accuracy +
// offline buffer replay. Fake server, no plugins.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/guardian_journey_screen.dart';
import 'package:assisto/screens/guardian_request_screen.dart';
import 'package:assisto/screens/safe_journey/sj_child_school_screen.dart';
import 'package:assisto/screens/safe_journey/sj_hub_screen.dart';
import 'package:assisto/screens/safe_journey/sj_share_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

class _Hit {
  final String method, path;
  final Map<String, dynamic> body;
  _Hit(this.method, this.path, this.body);
}

class _Api extends ApiClient {
  _Api() {
    token = 'test-token';
  }
  final hits = <_Hit>[];
  Map<String, dynamic> active = const {};
  List<Map<String, dynamic>> where = [];
  bool whereFails = false;
  Map<String, dynamic> circle = {'results': []};
  Map<String, dynamic> requests = {'incoming': [], 'outgoing': [], 'history': [], 'people': []};
  List<Map<String, dynamic>> plans = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    hits.add(_Hit('GET', path, const {}));
    if (path == '/journey/active') return active;
    if (path == '/journey/where-now') {
      if (whereFails) throw ApiException('down', 500);
      return {'people': where};
    }
    if (path == '/circle/members') return circle;
    if (path == '/journey/requests') return requests;
    if (path == '/school-mode/plans') return {'plans': plans};
    if (path == '/school-mode/mine') return {'plans': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('POST', path, body));
    // only what is SENT is checked: failing keeps the real live screen
    // (tracker, foreground service plugins) out of the widget test
    if (path == '/journey/start') throw ApiException('test: not started', 500);
    return {'ok': true, 'id': 1};
  }

  List<_Hit> posts(String p) => hits.where((h) => h.method == 'POST' && h.path == p).toList();
}

class _Oem implements OemGuideNative {
  const _Oem();
  @override
  Future<OemInfo?> info() async =>
      const OemInfo(manufacturer: 'Google', brand: 'google', batteryOptIgnored: true);
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_Api api, Widget home, {String lang = 'en', double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      navigatorKey: _nav,
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

late AppLocalizations en, bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    FeatureFlags.instance.debugOverride = null;
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  group('pure', () {
    test('cards: Live Location always first; 2 and 3 only with their flag', () {
      expect(sjVisibleCards(alarmOn: false, trainOn: false), [SjCard.live]);
      expect(sjVisibleCards(alarmOn: true, trainOn: true),
          [SjCard.live, SjCard.alarm, SjCard.train]);
    });

    test('share until a time: 15 min .. 24 h, past times mean tomorrow', () {
      final now = DateTime(2026, 11, 3, 10, 0);
      expect(sjMinutesUntil(now, 11, 0), 60);
      expect(sjMinutesUntil(now, 10, 10), isNull); // < 15 min
      expect(sjMinutesUntil(now, 9, 30), 23 * 60 + 30); // tomorrow
    });

    test('honest accuracy bands and junk dropped', () {
      expect(journeyAccBand(8), 'good');
      expect(journeyAccBand(60), 'ok');
      expect(journeyAccBand(900), 'rough');
      expect(journeyAccBand(null), isNull);
      expect(journeyCleanAcc(0), isNull);
      expect(journeyCleanAcc(double.nan), isNull);
      expect(journeyCleanAcc(50000), isNull);
      expect(journeyCleanAcc(12.5), 12.5);
    });

    test('holidays: only upcoming, sorted; iso day', () {
      expect(sjIsoDay(DateTime(2026, 1, 5)), '2026-01-05');
      expect(sjUpcomingHolidays(['2026-11-10', '2026-11-01', '2026-11-03'],
          DateTime(2026, 11, 3)), ['2026-11-03', '2026-11-10']);
    });
  });

  group('offline buffer replay', () {
    test('accuracy survives the disk queue and old rows stay valid', () {
      final q = JourneyFixQueue()
        ..add(JourneyFix(23.7, 90.4, DateTime.utc(2026, 11, 3, 9), 50, 'app', 12.34))
        ..add(JourneyFix(23.8, 90.4, DateTime.utc(2026, 11, 3, 9, 1), null, 'bg'));
      final back = JourneyFixQueue.decode(q.encode());
      expect(back.items.first.acc, 12.3);
      expect(back.items.first.toJson()['acc'], 12.3);
      expect(back.items.last.acc, isNull);
      expect(back.items.last.toJson().containsKey('acc'), isFalse);
      // a row written by an older build (no acc key) still decodes
      final old = JourneyFixQueue.decode(
          '[{"lat":23.7,"lng":90.4,"at":"2026-11-03T09:00:00Z","src":"app"}]');
      expect(old.items.single.acc, isNull);
    });

    test('offline -> every fix kept in order -> sent in one go when back', () async {
      var online = false;
      final sent = <List<Map<String, dynamic>>>[];
      var now = DateTime(2026, 11, 3, 8, 0);
      var lat = 23.70;
      final tr = JourneyTracker(
          useService: false,
          clock: () => now,
          position: () async => (lat: lat += 0.002, lng: 90.39),
          battery: () async => 70);
      await tr.start(11, (id, pts) async {
        if (!online) throw ApiException('offline');
        sent.add(pts);
        return {'status': 'active', 'overdue_state': 'no_eta'};
      });
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 31));
        await tr.tick();
      }
      expect(tr.value.net, JourneyNet.offline);
      final waiting = tr.value.queued; // start() may take a first fix too
      expect(waiting, greaterThanOrEqualTo(4));
      online = true;
      now = now.add(const Duration(seconds: 31));
      await tr.tick();
      expect(tr.value.queued, 0);
      final ats = sent.expand((b) => b).map((p) => '${p['at']}').toList();
      expect(ats.length, waiting + 1);
      expect([...ats]..sort(), ats); // oldest first, nothing lost
      await tr.stop();
    });
  });

  group('hub', () {
    testWidgets('Live Location is selected by default with four buttons', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(api, const SafeJourneyHubScreen(oem: _Oem())));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_card_live')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_card_check_live')), findsOneWidget);
      // flags off -> no dead cards
      expect(find.byKey(const ValueKey('sjl_card_alarm')), findsNothing);
      expect(find.byKey(const ValueKey('sjl_card_train')), findsNothing);
      for (final k in ['sjl_btn_trip', 'sjl_btn_school', 'sjl_btn_request', 'sjl_btn_share']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text(en.sjlSubLive), findsWidgets);
      // TalkBack hears "selected" on the default card
      expect(
          find.ancestor(
              of: find.byKey(const ValueKey('sjl_card_live')),
              matching: find.byWidgetPredicate(
                  (w) => w is Semantics && w.properties.selected == true)),
          findsOneWidget);
      // empty "who is where" = benefit + big button + how-to
      expect(find.byKey(const ValueKey('sjl_where_empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_where_ask')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('sjl_real_acc')), 300);
      expect(find.byKey(const ValueKey('sjl_real_bg')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_real_oem')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_real_offline')), findsOneWidget);
      expect(find.text(en.sjlRealOemOk), findsOneWidget); // honest: this phone is fine
    });

    testWidgets('three cards when flags are on; names are the same everywhere', (tester) async {
      FeatureFlags.instance.debugOverride = {'dest_alarm': true, 'train_tracker': true};
      await tester.pumpWidget(_app(_Api(), const SafeJourneyHubScreen(oem: _Oem()), lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.sjlNameLive), findsWidgets);
      expect(find.text(bn.sjlNameAlarm), findsOneWidget);
      expect(find.text(bn.sjlNameTrain), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_card_check_alarm')), findsNothing);
      expect(bn.sjlNameAlarm, 'গন্তব্য অ্যালার্ম');
      expect(en.sjlNameTrain, 'Train Tracker');
    });

    testWidgets('who is where: honest accuracy, age, battery; rough said so', (tester) async {
      final api = _Api()
        ..where = [
          {'kind': 'share', 'journey_id': 7, 'name': 'Ammu', 'sos': false, 'lat': 23.78,
           'lng': 90.40, 'fix_age_s': 30, 'acc_m': 12, 'battery': 64},
          {'kind': 'trip', 'journey_id': 8, 'name': 'Rina', 'sos': false, 'lat': 23.74,
           'lng': 90.37, 'fix_age_s': 420, 'acc_m': 1600, 'battery': 21},
          {'kind': 'school', 'plan_id': 1, 'name': 'Rafi', 'sos': false, 'lat': null,
           'lng': null, 'fix_age_s': null, 'acc_m': null},
        ];
      await tester.pumpWidget(_app(api, const SafeJourneyHubScreen(oem: _Oem())));
      await _settle(tester);
      final ammu = find.byKey(const ValueKey('sjl_where_share_7'));
      await tester.scrollUntilVisible(ammu, 200);
      expect(find.descendant(of: ammu, matching: find.textContaining('± 12 m')), findsOneWidget);
      expect(find.descendant(of: ammu, matching: find.textContaining(en.sjlAgeNow)), findsOneWidget);
      final rina = find.byKey(const ValueKey('sjl_where_trip_8'));
      expect(find.descendant(of: rina, matching: find.textContaining(en.sjlAccRough('1.6 km'))),
          findsOneWidget);
      expect(find.descendant(of: rina, matching: find.textContaining(en.sjlAgeMin('7'))),
          findsOneWidget);
      final rafi = find.byKey(const ValueKey('sjl_where_school_1'));
      expect(find.descendant(of: rafi, matching: find.textContaining(en.sjlNoFixYet)),
          findsOneWidget);
      // no tile provider -> honest note, maps app per person
      expect(find.byKey(const ValueKey('sjl_where_nomap')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_where_maps_7')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_where_maps_1')), findsNothing);
    });

    testWidgets('who is where: a failure says so and can retry', (tester) async {
      final api = _Api()..whereFails = true;
      await tester.pumpWidget(_app(api, const SafeJourneyHubScreen(oem: _Oem())));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_where_error')), findsOneWidget);
      api.whereFails = false;
      await tester.tap(find.text(en.sjlRetry));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_where_empty')), findsOneWidget);
    });
  });

  group('share for a while', () {
    testWidgets('no family -> add-family step; else sends minutes + people only',
        (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(api, const SjShareScreen(oem: _Oem())));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_share_add_family')), findsOneWidget);

      api.circle = {
        'results': [
          {'id': 3, 'name': 'Ammu', 'state': 'accepted', 'phone': '01711000002'},
          {'id': 4, 'name': 'Abbu', 'state': 'accepted'},
        ]
      };
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(api, const SjShareScreen(oem: _Oem())));
      await _settle(tester);
      // nobody picked -> told, nothing sent
      await tester.ensureVisible(find.byKey(const ValueKey('sjl_share_start')));
      await tester.tap(find.byKey(const ValueKey('sjl_share_start')));
      await _settle(tester, 5);
      expect(api.posts('/journey/start'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('sjl_share_180')));
      await tester.tap(find.byKey(const ValueKey('sjl_share_p_3')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('sjl_share_start')));
      await tester.tap(find.byKey(const ValueKey('sjl_share_start')));
      await _settle(tester);
      final body = api.posts('/journey/start').single.body;
      expect(body['share_minutes'], 180);
      expect(body['watcher_ids'], [3]);
      expect((body['destination'] as Map), isEmpty);
    });
  });

  group('request location', () {
    testWidgets('location only: no destination, 1 h from now, kind=location', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(
          api,
          const GuardianRequestScreen(locationOnly: true, people: [
            {'member_id': 3, 'name': 'Ammu'}
          ])));
      await _settle(tester);
      expect(find.byKey(const ValueKey('gj_dest')), findsNothing);
      expect(find.byKey(const ValueKey('gj_school')), findsNothing);
      expect(find.text(en.sjlReqIntro), findsOneWidget); // never covert, said up front
      await tester.tap(find.byKey(const ValueKey('gj_person_3')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('gj_send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gj_send')));
      await _settle(tester);
      final b = api.posts('/journey/requests').single.body;
      expect(b['kind'], 'location');
      expect((b['destination'] as Map), isEmpty);
      final s = DateTime.parse(b['start'] as String), e = DateTime.parse(b['end'] as String);
      expect(e.difference(s).inMinutes, 60);
    });

    testWidgets('consent states on the asked phone: pending shows accept / decline',
        (tester) async {
      final api = _Api()
        ..requests = {
          'incoming': [
            {'id': 21, 'role': 'traveller', 'name': 'Ammu', 'status': 'pending',
             'destination': {'name': '', 'share': true}, 'kind': 'location',
             'window_start': DateTime.now().toIso8601String(),
             'window_end': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
             'late_note': '', 'late_tail_min': 0, 'log': const []},
          ],
          'outgoing': [], 'history': [], 'people': [],
        };
      await tester.pumpWidget(_app(api, const GuardianJourneyScreen(locationOnly: true)));
      await _settle(tester);
      expect(find.textContaining(en.sjlNameLive), findsWidgets);
      expect(find.byKey(const ValueKey('gj_accept_21')), findsOneWidget);
      expect(find.byKey(const ValueKey('gj_decline_21')), findsOneWidget);
      expect(find.byKey(const ValueKey('gj_late_note_21')), findsNothing); // no late tail
      expect(find.text(en.sjlBtnRequest), findsOneWidget); // same name as the button
    });
  });

  group('child school', () {
    Map<String, dynamic> plan({int? cam, List<String> holidays = const [], bool accepted = true}) => {
          'id': 5, 'child_name': 'Rafi', 'mine': true, 'accepted': accepted,
          'mode': 'phone', 'enabled': true,
          'config': {'gate_camera_id': cam, 'holidays': holidays},
          'watchers': [{'id': 2, 'name': 'Ammu'}],
          'today': {'school_day': true, 'left_home_at': '2026-11-03T07:40:00+06:00',
                    'arrived_school_at': null, 'arrive_due': '2026-11-03T08:15:00+06:00'},
        };

    testWidgets('four steps, both parents, no camera -> no gate button', (tester) async {
      final api = _Api()..plans = [plan()];
      await tester.pumpWidget(_app(api, const SjChildSchoolScreen()));
      await _settle(tester);
      expect(find.text(en.sjlStepLeftHome), findsOneWidget);
      expect(find.text(en.sjlStepAtSchool), findsOneWidget);
      expect(find.text(en.sjlStepLeftSchool), findsOneWidget);
      expect(find.text(en.sjlStepHome), findsOneWidget);
      expect(find.text(en.sjlParents('Ammu')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_school_gate_5')), findsNothing);
      expect(find.byKey(const ValueKey('sjl_school_gate_link_5')), findsNothing);
      expect(find.byKey(const ValueKey('sjl_school_holidays_5')), findsOneWidget);
    });

    testWidgets('a linked camera shows the gate button; a holiday says so', (tester) async {
      final today = sjIsoDay(DateTime.now());
      final api = _Api()..plans = [plan(cam: 9, holidays: [today])];
      await tester.pumpWidget(_app(api, const SjChildSchoolScreen()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_school_gate_5')), findsOneWidget);
      expect(find.text(en.sjlTodayHoliday), findsOneWidget);
    });

    testWidgets('not accepted yet is said; empty state has the big button', (tester) async {
      final api = _Api()..plans = [plan(accepted: false)];
      await tester.pumpWidget(_app(api, const SjChildSchoolScreen()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sjl_school_wait_5')), findsOneWidget);
      api.plans = [];
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(api, const SjChildSchoolScreen(), lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.sjlSchoolEmptyTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('sjl_school_add')), findsOneWidget);
    });
  });

  testWidgets('200% font: hub has no overflow', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    FeatureFlags.instance.debugOverride = {'dest_alarm': true, 'train_tracker': true};
    await tester.pumpWidget(
        _app(_Api(), const SafeJourneyHubScreen(oem: _Oem()), lang: 'bn', scale: 2));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('sjl_real_acc')), 400);
    expect(tester.takeException(), isNull);
    unawaited(Future<void>.value());
  });
}
