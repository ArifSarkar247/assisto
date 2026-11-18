// gap-carecall — the one-time ("once") Care Call date bug, phone side.
//   * the date FOLLOWS the picked time on the RECEIVER's clock (today when
//     that time is still ahead there, else tomorrow) — before, it was frozen
//     on Dhaka's calendar when "Once" was picked and could land a day late
//     or in the past (saved, never rang);
//   * a picked date + time already past is refused with a clear line;
//   * the receiver's own alarms ring on THEIR clock (the server's), not
//     Dhaka's (a UTC / Dubai phone rang hours off or twice).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/carecall/carecall_new_screen.dart';
import 'package:assisto/carecall/carecall_plan.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'carecall_fakes.dart';
import 'fake_api.dart';

DateTime _bd(int y, int mo, int d, int h, int mi) => ccBdInstant(y, mo, d, h, mi);

class _Api extends FakeCareCallApi {
  final List<Map<String, dynamic>> updated = [];
  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body) async {
    updated.add(body);
    return {'ok': true, 'care_call': {...body, 'id': id}};
  }
}

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget screen) => ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        locale: const Locale('en'),
        theme: AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
            builder: (c) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => screen)),
                        child: const Text('open'))))),
      ),
    );

Map<String, dynamic> _edit({String time = '23:30', String repeat = 'daily', String date = '', int off = 360}) => {
      'id': 5, 'text': 'Napa 500mg', 'time': time, 'repeat': repeat, 'days': const [],
      'date': date, 'active': true, 'has_voice': false, 'voice_sec': 0,
      'receiver_id': 7, 'other_name': 'Ammu', 'other_initial': 'A', 'link': 'accepted',
      'quiet_start': '', 'quiet_end': '', 'receiver_offset_min': off,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CareCallNewScreen.debugNow = null;
  });
  tearDown(() => CareCallNewScreen.debugNow = null);

  group('plan: the receiver\'s clock', () {
    test('once next date: today while ahead, else tomorrow (Dhaka)', () {
      final now = _bd(2026, 11, 18, 10, 0); // 04:00 UTC
      expect(ccOnceNextDate(now, 9 * 60), '2026-11-19');
      expect(ccOnceNextDate(now, 10 * 60), '2026-11-19'); // this minute = passed
      expect(ccOnceNextDate(now, 10 * 60 + 5), '2026-11-18');
      // just after Dhaka midnight (UTC still the 17th): Dhaka's 18th
      final mid = _bd(2026, 11, 18, 0, 30);
      expect(mid.toUtc().day, 17);
      expect(ccOnceNextDate(mid, 23 * 60), '2026-11-18');
      expect(ccOnceNextDate(mid, 10), '2026-11-19');
    });

    test('once next date on a Dubai / Malaysia / UTC clock', () {
      final now = _bd(2026, 11, 18, 1, 0); // = 17 Nov 23:00 Dubai, 19:00 UTC, 03:00 MYT
      expect(ccOnceNextDate(now, 23 * 60 + 30, offsetMin: 240), '2026-11-17');
      expect(ccOnceNextDate(now, 23 * 60 + 30), '2026-11-18');
      expect(ccOnceNextDate(now, 20 * 60, offsetMin: 0), '2026-11-17');
      expect(ccOnceNextDate(now, 2 * 60, offsetMin: 480), '2026-11-19');
      expect(ccToday(now, offsetMin: 240), DateTime(2026, 11, 17));
      expect(ccToday(now, offsetMin: 480), DateTime(2026, 11, 18));
    });

    test('past check is on the receiver\'s clock', () {
      final now = _bd(2026, 11, 18, 23, 0); // 19 Nov 01:00 in Malaysia
      expect(ccOncePast('2026-11-18', 23 * 60 + 30, now), isFalse);
      expect(ccOncePast('2026-11-18', 23 * 60 + 30, now, offsetMin: 480), isTrue);
      expect(ccOncePast('2026-11-19', 23 * 60 + 30, now, offsetMin: 480), isFalse);
    });

    test('a UTC-phone receiver\'s own alarm rings at the server\'s instant', () {
      final it = CcItem(id: 1, text: 'x', time: '09:00', repeat: 'once', date: '2026-11-18',
          link: 'accepted', tzOffsetMin: 0);
      final s = ccNextSlot(it, _bd(2026, 11, 18, 10, 0))!;
      expect(s, DateTime.utc(2026, 11, 18, 9, 0)); // 09:00 on the phone's clock
      final plan = ccPlanLocal([it], _bd(2026, 11, 18, 10, 0));
      expect(plan.first.at, DateTime.utc(2026, 11, 18, 9, 0));
      // the slot key stays the server's (Dhaka-clock) key
      expect(plan.first.slot, '202611181500');
    });

    test('quiet hours on the receiver\'s clock', () {
      // 22:00-07:00 on a UTC phone: 23:00 UTC is quiet, 23:00 Dhaka (17:00 UTC) is not
      expect(ccInQuiet(DateTime.utc(2026, 11, 18, 23, 0), '22:00', '07:00', offsetMin: 0), isTrue);
      expect(ccInQuiet(DateTime.utc(2026, 11, 18, 17, 0), '22:00', '07:00', offsetMin: 0), isFalse);
      expect(ccAfterQuiet(DateTime.utc(2026, 11, 18, 23, 0), '22:00', '07:00', offsetMin: 0),
          DateTime.utc(2026, 11, 19, 7, 0));
    });

    test('receiver_offset_min round-trips; old servers default to Dhaka', () {
      final it = CcItem.fromJson({'id': 1, 'receiver_offset_min': 240});
      expect(it.tzOffsetMin, 240);
      expect(CcItem.fromJson(it.toJson()).tzOffsetMin, 240);
      expect(CcItem.fromJson({'id': 1}).tzOffsetMin, 360);
    });
  });

  group('SCREEN 1: once date', () {
    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 4400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
    }

    Future<void> pickOnce(WidgetTester tester) async {
      await tester.tap(find.text('Daily').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Once'));
      await tester.pumpAndSettle();
    }

    testWidgets('Dubai parent at 23:00 their time: "once 23:30" is TONIGHT there', (tester) async {
      tall(tester);
      CareCallNewScreen.debugNow = () => _bd(2026, 11, 18, 1, 0); // 17 Nov 23:00 Dubai
      final api = _Api();
      await tester.pumpWidget(_app(CareCallNewScreen(api: api, edit: _edit(off: 240))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await pickOnce(tester);
      expect(find.textContaining('Today'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(api.updated.single['repeat'], 'once');
      expect(api.updated.single['date'], '2026-11-17'); // their day, not Dhaka's 18th
    });

    testWidgets('Dhaka: time already passed today -> tomorrow, never a dead call', (tester) async {
      tall(tester);
      CareCallNewScreen.debugNow = () => _bd(2026, 11, 18, 10, 0);
      final api = _Api();
      await tester.pumpWidget(_app(CareCallNewScreen(api: api, edit: _edit(time: '09:00'))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await pickOnce(tester);
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(api.updated.single['date'], '2026-11-19');
    });

    testWidgets('a picked date + time in the past is refused with a clear line', (tester) async {
      tall(tester);
      CareCallNewScreen.debugNow = () => _bd(2026, 11, 18, 10, 0);
      final api = _Api();
      await tester.pumpWidget(_app(CareCallNewScreen(
          api: api, edit: _edit(time: '09:00', repeat: 'once', date: '2026-11-18'))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(api.updated, isEmpty);
      expect(find.textContaining('already passed'), findsOneWidget);
    });
  });
}
