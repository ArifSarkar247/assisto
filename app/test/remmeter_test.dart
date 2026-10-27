// remmeter: exact reminder alarms (pure planning, stable ids shared with the
// server push, reconcile diff, push dedupe, lateness stats) + prepaid meter
// guard (companies, meter number, 20-digit tokens, pay paths, bn/en, dark,
// 48dp). No plugins: Notifications is not initialised in tests.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/meter/meter_logic.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/exact_alarm_ui.dart';
import 'package:assisto/reminders/reminder_alarms.dart';
import 'package:assisto/screens/prepaid_meter_screen.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'fake_api.dart';

Widget _app(Widget child, {String lang = 'en', bool dark = false}) =>
    MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );

Map<String, dynamic> _rem(
  String title,
  DateTime due, {
  int? serverId,
  String localId = 'l1',
  bool done = false,
  String recurrence = 'none',
  Map<String, dynamic>? rule,
  String? priority,
  int lead = 0,
}) =>
    {
      'localId': localId,
      'serverId': serverId,
      'pendingOp': 'none',
      'data': {
        'title': title,
        'notes': '',
        'due_at': due.toUtc().toIso8601String(),
        'recurrence': recurrence,
        'recurrence_rule': rule ?? <String, dynamic>{},
        'done': done,
        if (priority != null) 'priority': priority,
        if (lead > 0) 'remind_before_min': lead,
      },
    };

class _FakeOem implements OemGuideNative {
  @override
  Future<OemInfo?> info() async => const OemInfo(batteryOptIgnored: false);
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

void main() {
  final now = DateTime(2026, 10, 27, 10, 0);

  group('alarm plan', () {
    test('ids are stable and match the server push id', () {
      final plans = planReminderAlarms(
          [_rem('Pay rent', now.add(const Duration(hours: 1)), serverId: 42)],
          now: now);
      expect(plans, hasLength(1));
      expect(plans.first.key, 'rem-42');
      final push = PushPayload.fromData(
          {'kind': 'reminder', 'reminder_id': '42'});
      // the push for the same reminder REPLACES the local notification
      expect(plans.first.id, push.notificationId);
    });

    test('unsynced reminder uses its local id; past/done skipped', () {
      final plans = planReminderAlarms([
        _rem('a', now.add(const Duration(minutes: 5)), localId: 'x9'),
        _rem('past', now.subtract(const Duration(minutes: 1)), localId: 'p'),
        _rem('done', now.add(const Duration(minutes: 5)),
            localId: 'd', done: true),
      ], now: now);
      expect(plans.map((p) => p.key), ['remloc-x9']);
    });

    test('lead time, important -> alarm clock, daily repeat', () {
      final plans = planReminderAlarms([
        _rem('lead', now.add(const Duration(minutes: 30)),
            serverId: 1, lead: 10),
        _rem('vip', now.add(const Duration(minutes: 40)),
            serverId: 2, priority: 'high'),
        _rem('pill', DateTime(2026, 10, 20, 9, 0),
            serverId: 3,
            recurrence: 'daily',
            rule: {'freq': 'daily', 'interval': 1, 'time': '21:00'}),
      ], now: now);
      expect(plans[0].at, now.add(const Duration(minutes: 20)));
      expect(modeFor(plans[1], exactAllowed: true), AlarmMode.alarm);
      expect(modeFor(plans[1], exactAllowed: false), AlarmMode.inexact);
      expect(modeFor(plans[0], exactAllowed: true), AlarmMode.exact);
      final pill = plans.firstWhere((p) => p.key == 'rem-3');
      expect(pill.at, DateTime(2026, 10, 27, 21, 0));
      expect(pill.repeat, AlarmRepeat.daily);
    });

    test('monthly recurring is scheduled one occurrence at a time', () {
      final plans = planReminderAlarms([
        _rem('bill', DateTime(2026, 9, 5, 9, 0),
            serverId: 4,
            recurrence: 'monthly',
            rule: {'freq': 'monthly', 'day_of_month': 5, 'time': '09:00'}),
      ], now: now);
      expect(plans.single.at, DateTime(2026, 11, 5, 9, 0));
      expect(plans.single.repeat, AlarmRepeat.none);
    });

    test('reconcile diff: new, unchanged, moved, gone, dropped by the OS', () {
      final p = planReminderAlarms([
        _rem('a', now.add(const Duration(hours: 1)), serverId: 1),
        _rem('b', now.add(const Duration(hours: 2)), serverId: 2),
      ], now: now);
      final ledger = <int, LedgerEntry>{
        p[0].id: LedgerEntry(
            key: p[0].key,
            at: p[0].at.millisecondsSinceEpoch,
            mode: AlarmMode.exact,
            repeat: AlarmRepeat.none,
            sig: p[0].sig(AlarmMode.exact)),
        999: const LedgerEntry(
            key: 'rem-9', at: 1, mode: AlarmMode.exact,
            repeat: AlarmRepeat.none, sig: ''),
      };
      var ops = diffAlarms(
          plans: p, ledger: ledger, exactAllowed: true,
          pendingIds: {p[0].id, 999});
      expect(ops.cancel, [999]);
      expect(ops.schedule.map((x) => x.key), ['rem-2']);
      // exact permission revoked -> re-handed as inexact
      ops = diffAlarms(
          plans: p, ledger: ledger, exactAllowed: false,
          pendingIds: {p[0].id});
      expect(ops.schedule.map((x) => x.key), containsAll(['rem-1', 'rem-2']));
      // the OS dropped it (boot after revoke) -> re-handed
      ops = diffAlarms(
          plans: p, ledger: ledger, exactAllowed: true, pendingIds: {});
      expect(ops.schedule.map((x) => x.key), contains('rem-1'));
    });

    test('ledger round-trips without titles', () {
      final l = {
        7: const LedgerEntry(
            key: 'rem-7', at: 123, mode: AlarmMode.alarm,
            repeat: AlarmRepeat.weekly, sig: 's')
      };
      final s = encodeLedger(l);
      expect(s.contains('Pay'), isFalse);
      final back = decodeLedger(s)[7]!;
      expect(back.mode, AlarmMode.alarm);
      expect(back.repeat, AlarmRepeat.weekly);
      expect(decodeLedger('garbage'), isEmpty);
    });
  });

  group('push dedupe (no double alert)', () {
    const at = 1000000000000;
    const e = LedgerEntry(
        key: 'rem-5', at: at, mode: AlarmMode.exact,
        repeat: AlarmRepeat.none, sig: '');
    test('local alarm already rang -> push silent', () {
      expect(decideReminderPush(entry: e, fireMs: at + 20000, pending: false),
          PushDecision.suppress);
    });
    test('local alarm still waiting (late) -> push rings, alarm cancelled', () {
      expect(decideReminderPush(entry: e, fireMs: at, pending: true),
          PushDecision.showAndCancelLocal);
    });
    test('no local alarm / different fire -> push rings', () {
      expect(decideReminderPush(entry: null, fireMs: at, pending: null),
          PushDecision.show);
      expect(
          decideReminderPush(entry: e, fireMs: at + 3600000, pending: false),
          PushDecision.show);
    });
    test('daily native repeat: exact same minute -> silent', () {
      final d = DateTime(2026, 10, 20, 21, 0).millisecondsSinceEpoch;
      final r = LedgerEntry(
          key: 'rem-3', at: d, mode: AlarmMode.exact,
          repeat: AlarmRepeat.daily, sig: '');
      final today = DateTime(2026, 10, 27, 21, 0).millisecondsSinceEpoch;
      expect(decideReminderPush(entry: r, fireMs: today, pending: true),
          PushDecision.suppress);
    });

    test('onReminderPush reads the ledger the UI isolate wrote', () async {
      final p = planReminderAlarms(
          [_rem('x', now.add(const Duration(hours: 1)), serverId: 77)],
          now: now);
      SharedPreferences.setMockInitialValues({
        ReminderAlarms.ledgerKey: encodeLedger({
          p.first.id: LedgerEntry(
              key: 'rem-77',
              at: p.first.at.millisecondsSinceEpoch,
              mode: AlarmMode.exact,
              repeat: AlarmRepeat.none,
              sig: '')
        })
      });
      // plugin unavailable in tests -> pending unknown -> exact = trust it
      final d = await ReminderAlarms.onReminderPush({
        'kind': 'reminder',
        'reminder_id': '77',
        'fire_at': p.first.at.toUtc().toIso8601String(),
      });
      expect(d, PushDecision.suppress);
      expect(
          await ReminderAlarms.onReminderPush(
              {'kind': 'reminder', 'reminder_id': '78'}),
          PushDecision.show);
    });
  });

  group('lateness', () {
    test('stats: on time within 60 s, median, worst', () {
      final s = DeliveryStats.of([
        for (final late in [0, 5, 30, 200])
          DeliverySample(
              scheduledMs: 0,
              observedMs: late * 1000,
              source: 'local',
              mode: AlarmMode.exact),
      ]);
      expect(s.count, 4);
      expect(s.onTime, 3);
      expect(s.worstSeconds, 200);
      expect(s.medianSeconds, 30);
      var log = <DeliverySample>[];
      for (var i = 0; i < 50; i++) {
        log = appendSample(
            log,
            DeliverySample(
                scheduledMs: i, observedMs: i, source: 'local',
                mode: AlarmMode.exact));
      }
      expect(log.length, 40);
      expect(log.first.scheduledMs, 10);
    });
  });

  group('meter logic', () {
    test('tokens from a pasted SMS (grouped, Bangla digits, KCT)', () {
      expect(
          extractTokens('Token 1234-5678-9012-3456-7890 KCT1 1111 2222 '
              '3333 4444 5555 Tk 500'),
          ['12345678901234567890', '11112222333344445555']);
      expect(extractTokens('০১২৩৪৫৬৭'
          '৮৯০১২৩৪৫৬৭৮'
          '৯'), ['01234567890123456789']);
      expect(extractTokens('ref 12345 amount 500'), isEmpty);
      expect(validToken('1234 5678 9012 3456 7890'), isTrue);
      expect(groupToken('12345678901234567890'), '1234 5678 9012 3456 7890');
    });

    test('meter number: digits only, no guessed company format', () {
      expect(meterNumberProblem(''), isNull);
      expect(meterNumberProblem('0123 4567'), isNull);
      expect(meterNumberProblem('12ab45'), 'meter_digits_only');
      expect(meterNumberProblem('123'), 'meter_length');
      expect(normalizeNumber('১২-৩'), '123');
    });

    test('catalog mirrors the backend; gas has no wallet path', () {
      expect(kUtilities.map((u) => u.id),
          ['desco', 'dpdc', 'nesco', 'wzpdcl', 'breb', 'bpdb', 'titas',
           'karnaphuli', 'other']);
      expect(utilityById('titas')!.bkash, isFalse);
      expect(utilityById('desco')!.nagad, isTrue);
      expect(utilityById('nesco')!.nagad, isFalse); // not verified
      expect(utilitiesFor('gas').map((u) => u.id),
          ['titas', 'karnaphuli', 'other']);
      expect(alertDaysOf({'alert_days': 30}), 7);
      expect(alertDaysOf({}), 3);
    });

    test('meter_low push opens the meter screen', () {
      expect(
          PushRouting.targetFor(PushPayload.fromData(
                  {'kind': 'meter_low', 'route': 'prepaid_meter'}))!
              .chatNavRoute,
          'prepaid_meter');
      expect(PushPayload.fromData({'kind': 'meter_low'}).isKnownKind, isTrue);
    });
  });

  group('meter screen', () {
    // Regression: _Meter.toPoisha padded with '00' then took 3 chars ->
    // RangeError on EVERY whole amount ("500"), so the screen crashed as
    // soon as a meter or recharge had a whole-taka value.
    for (final lang in ['en', 'bn']) {
      testWidgets('whole-taka amounts render ($lang): low, estimate, alert',
          (t) async {
        t.view.physicalSize = const Size(1080, 5200);
        t.view.devicePixelRatio = 2.0;
        addTearDown(t.view.reset);
        final app = AppState();
        app.api = FakeApi(mode: FakeMode.data, lang: lang);
        await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app, child: _app(const PrepaidMeterScreen(), lang: lang)));
        await t.pumpAndSettle(const Duration(seconds: 3));
        expect(t.takeException(), isNull);
        final tr = AppLocalizations.of(
            t.element(find.byType(PrepaidMeterScreen)));
        expect(find.text(tr.meterStateLow), findsWidgets);
        expect(find.text(tr.mtrRateFromEstimate), findsOneWidget);
        expect(find.text(tr.mtrPayCta), findsNWidgets(3));
        expect(find.text(tr.mtrAlertOffChip), findsOneWidget);
      });
    }
  });

  group('pay path sheet', () {
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('electricity $lang dark=$dark: verified steps', (t) async {
          t.view.physicalSize = const Size(1080, 5200);
          t.view.devicePixelRatio = 2.0;
          addTearDown(t.view.reset);
          await t.pumpWidget(_app(
              const PayPathSheet(meter: {
                'name': 'Home',
                'kind': 'electricity',
                'utility': 'nesco',
                'meter_no': '01234567',
              }),
              lang: lang,
              dark: dark));
          await t.pumpAndSettle();
          final tr = AppLocalizations.of(
              t.element(find.byType(PayPathSheet)));
          expect(find.text(tr.mtrPayTitle), findsOneWidget);
          // bKash verified for NESCO -> steps; Nagad not verified -> honest
          expect(find.text(tr.mtrStepPayBill), findsOneWidget);
          expect(find.text(tr.mtrNotVerified(tr.mtrNagad, tr.mtrUtilNesco)),
              findsOneWidget);
          expect(find.text(tr.mtrPayHonest), findsOneWidget);
          if (lang == 'bn') {
            // Bangla digits for the meter number
            expect(find.textContaining('০১২'), findsWidgets);
          }
          for (final b in find.byType(OutlinedButton).evaluate()) {
            expect(t.getSize(find.byWidget(b.widget)).height,
                greaterThanOrEqualTo(48));
          }
          expect(t.takeException(), isNull);
        });
      }
    }

    testWidgets('gas: warning, no wallet buttons', (t) async {
      await t.pumpWidget(_app(const PayPathSheet(
          meter: {'name': 'Gas', 'kind': 'gas', 'utility': 'titas'})));
      await t.pumpAndSettle();
      final tr = AppLocalizations.of(t.element(find.byType(PayPathSheet)));
      expect(find.text(tr.mtrGasWarning), findsOneWidget);
      expect(find.text(tr.mtrStepPayBill), findsNothing);
    });
  });

  group('reminder delivery UI', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ExactAlarmHooks.canExact = () async => false;
      ExactAlarmHooks.notifEnabled = () async => true;
      ExactAlarmHooks.oem = _FakeOem();
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('delivery check $lang: honest states', (t) async {
        await t.pumpWidget(_app(const ReminderDeliverySheet(), lang: lang));
        await t.pumpAndSettle();
        final tr = AppLocalizations.of(
            t.element(find.byType(ReminderDeliverySheet)));
        expect(find.text(tr.rmxCheckExactOff), findsOneWidget);
        expect(find.text(tr.rmxCheckBatteryOpt), findsOneWidget);
        expect(find.text(tr.rmxCheckNone), findsOneWidget);
        expect(find.text(tr.rmxCheckTest), findsOneWidget);
        expect(find.text(tr.rmxCheckPrivacy), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('delivery check shows measured lateness', (t) async {
      SharedPreferences.setMockInitialValues({
        ReminderAlarms.logKey:
            '[{"s":0,"o":4000,"src":"local","m":"exact"},'
                '{"s":0,"o":90000,"src":"push","m":"inexact","lb":true}]'
      });
      ExactAlarmHooks.canExact = () async => true;
      await t.pumpWidget(_app(const ReminderDeliverySheet()));
      await t.pumpAndSettle();
      final tr = AppLocalizations.of(
          t.element(find.byType(ReminderDeliverySheet)));
      expect(find.text(tr.rmxCheckExactOn), findsOneWidget);
      expect(find.text(tr.rmxCheckMeasured('2', '1', '90')), findsOneWidget);
      expect(find.text(tr.rmxCheckWorst('90')), findsOneWidget);
    });

    testWidgets('banner hidden while notifications are not initialised',
        (t) async {
      await t.pumpWidget(_app(const ExactAlarmBanner()));
      await t.pumpAndSettle();
      final tr =
          AppLocalizations.of(t.element(find.byType(ExactAlarmBanner)));
      expect(find.text(tr.rmxBannerTitle), findsNothing);
    });
  });
}
