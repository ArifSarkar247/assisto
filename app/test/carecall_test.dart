// carecall (owner order 4 Nov 01:50) — Care Call phone rules + screens:
//   * plan: Bangladesh-time slots identical to the server, ring #1 + retry
//     #2 ten minutes later, quiet hours (DND) shift, answered slots skipped,
//     nothing for a not-accepted / switched-off schedule;
//   * the phone's OWN alarms: scheduled once, re-armed when an OEM cleaner
//     dropped them, survive a reboot (boot receiver in the manifest patch);
//   * one ring per slot when the server push and the own alarm both come;
//   * Done / Snooze: queued offline, sent later; snooze rings again locally;
//   * consent once (Accept) + stop; SCREEN 3 amber card Call now / See
//     location only when sharing exists; medicine words never blocked;
//   * Bangla + 200 % font render.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:assisto/calls/fullscreen_call_prompt.dart';
import 'package:assisto/carecall/carecall_alarms.dart';
import 'package:assisto/carecall/carecall_new_screen.dart';
import 'package:assisto/carecall/carecall_plan.dart';
import 'package:assisto/carecall/carecall_ring_screen.dart';
import 'package:assisto/carecall/carecall_screen.dart';
import 'package:assisto/carecall/cc_recorder.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'carecall_fakes.dart';
import 'fake_api.dart';

class FakeRecorder implements CcRecorder {
  final List<String> calls = [];
  @override
  Future<bool> start() async {
    calls.add('start');
    return true;
  }

  @override
  Future<String?> stop() async {
    calls.add('stop');
    return '/tmp/cc_test_voice.m4a';
  }

  @override
  Future<void> delete(String path) async => calls.add('delete');
}

class FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final Map<int, ({DateTime at, String? payload, AndroidScheduleMode? mode})> scheduled = {};
  final List<int> cancelled = [];
  int schedules = 0;

  @override
  Future<void> zonedSchedule(int id, String? title, String? body, tz.TZDateTime scheduledDate,
      NotificationDetails notificationDetails,
      {required UILocalNotificationDateInterpretation uiLocalNotificationDateInterpretation,
      bool androidAllowWhileIdle = false,
      AndroidScheduleMode? androidScheduleMode,
      String? payload,
      DateTimeComponents? matchDateTimeComponents}) async {
    schedules++;
    scheduled[id] = (at: scheduledDate.toUtc(), payload: payload, mode: androidScheduleMode);
  }

  @override
  Future<void> cancel(int id, {String? tag}) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async =>
      [for (final e in scheduled.entries) PendingNotificationRequest(e.key, null, null, e.value.payload)];
}

CcItem _item({String time = '09:00', String repeat = 'daily', List<int> days = const [],
        String date = '', String link = 'accepted', bool active = true,
        String qs = '22:00', String qe = '07:00'}) =>
    CcItem(id: 1, text: 'Napa 500mg — take your gas tablet', time: time, repeat: repeat,
        days: days, date: date, link: link, active: active, setterId: 3, receiverId: 7,
        otherName: 'Arif', otherInitial: 'A', quietStart: qs, quietEnd: qe,
        hasVoice: true, voiceRev: 1);

DateTime _bd(int y, int mo, int d, int h, int mi) => ccBdInstant(y, mo, d, h, mi);

AppState _state(String lang) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(lang),
      child: MaterialApp(
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

/// A host page that pushes [screen] (so its pop has somewhere to go).
Widget _host(Widget screen) => Builder(
    builder: (c) => Scaffold(
        body: Center(
            child: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('open')))));

/// A tall phone so the whole form is built (ListView builds lazily).
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

void main() {
  late FakePlugin plugin;

  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    plugin = FakePlugin();
    CareCallAlarms.debugPlugin = plugin;
    FullScreenCallPrompt.debugCanOverride = true;
    CareCallRingScreen.open.clear();
  });

  tearDown(() => CareCallAlarms.debugPlugin = null);

  group('plan (same slots as the server)', () {
    test('slot keys are Bangladesh wall time', () {
      expect(ccSlotOf(_bd(2026, 11, 4, 9, 0)), '202611040900');
      expect(ccSlotInstant('202611040900'), _bd(2026, 11, 4, 9, 0));
      expect(_bd(2026, 11, 4, 9, 0), DateTime.utc(2026, 11, 4, 3, 0));
    });

    test('next slot: daily / chosen days / once', () {
      final after = _bd(2026, 11, 4, 9, 30); // Wednesday
      expect(ccNextSlot(_item(), after), _bd(2026, 11, 5, 9, 0));
      expect(ccNextSlot(_item(time: '10:00'), after), _bd(2026, 11, 4, 10, 0));
      expect(ccNextSlot(_item(repeat: 'days', days: [4]), after), _bd(2026, 11, 6, 9, 0));
      expect(ccNextSlot(_item(repeat: 'days', days: []), after), isNull);
      expect(ccNextSlot(_item(repeat: 'once', date: '2026-11-04', time: '11:00'), after),
          _bd(2026, 11, 4, 11, 0));
      expect(ccNextSlot(_item(repeat: 'once', date: '2026-11-04'), after), isNull);
    });

    test('DND: a ring inside quiet hours waits until they end', () {
      expect(ccAfterQuiet(_bd(2026, 11, 4, 23, 0), '22:00', '07:00'), _bd(2026, 11, 5, 7, 0));
      expect(ccAfterQuiet(_bd(2026, 11, 5, 6, 59), '22:00', '07:00'), _bd(2026, 11, 5, 7, 0));
      expect(ccAfterQuiet(_bd(2026, 11, 5, 9, 0), '22:00', '07:00'), _bd(2026, 11, 5, 9, 0));
      expect(ccAfterQuiet(_bd(2026, 11, 5, 23, 0), '', ''), _bd(2026, 11, 5, 23, 0));
      final r = ccPlanLocal([_item(time: '23:30')], _bd(2026, 11, 4, 20, 0));
      expect(r.first.at, _bd(2026, 11, 5, 7, 0));
      expect(r[1].at, _bd(2026, 11, 5, 7, 10));
      expect(r.first.slot, '202611042330'); // the slot keeps its own time
    });

    test('retry: ring #1 at the slot, ring #2 ten minutes later', () {
      final now = _bd(2026, 11, 4, 8, 0);
      final r = ccPlanLocal([_item()], now);
      expect(r.map((x) => (x.slot, x.attempt)).toList(), [
        ('202611040900', 1), ('202611040900', 2), ('202611050900', 1), ('202611050900', 2)]);
      expect(r[1].at.difference(r[0].at), const Duration(minutes: 10));
      expect(r.map((x) => x.id).toSet().length, 4);
      // answered slots are skipped
      expect(ccPlanLocal([_item()], now, handled: {'1-202611040900'}).length, 2);
      // a ring that started 5 min ago still gets its retry
      expect(ccPlanLocal([_item()], _bd(2026, 11, 4, 9, 5)).first.attempt, 2);
    });

    test('consent: nothing rings before acceptance or when switched off', () {
      final now = _bd(2026, 11, 4, 8, 0);
      expect(ccPlanLocal([_item(link: 'pending')], now), isEmpty);
      expect(ccPlanLocal([_item(link: 'stopped')], now), isEmpty);
      expect(ccPlanLocal([_item(active: false)], now), isEmpty);
    });

    test('the push and the own alarm share one notification id', () {
      final p = PushPayload({'kind': 'carecall', 'slot_key': '1-202611040900', 'attempt': '2'});
      expect(p.notificationId, ccNotifId('1-202611040900', 2));
      expect(p.channel, PushChannels.calls);
      expect(p.isKnownKind, isTrue);
    });
  });

  group('the phone\'s own alarms (offline, reboot, battery savers)', () {
    test('scheduled once, carrying the ring payload; re-armed after an OEM drop', () async {
      final now = DateTime.now();
      final w = ccBdWall(now.add(const Duration(hours: 1)));
      final it = _item(time: ccHhmm(w.hour, w.minute), qs: '', qe: '');
      expect(await CareCallAlarms.reconcile([it], lang: 'bn', now: now), 4);
      final first = plugin.scheduled.values.first;
      expect(first.payload, contains('"kind":"carecall"'));
      expect(first.payload, contains('Napa 500mg'));
      expect(await CareCallAlarms.reconcile([it], lang: 'bn', now: now), 0);
      plugin.scheduled.clear(); // force-stop / cleaner dropped them
      expect(await CareCallAlarms.reconcile([it], lang: 'bn', now: now), 4);
      // the schedule stopped -> its waiting alarms are cancelled
      await CareCallAlarms.reconcile([], lang: 'bn', now: now);
      expect(plugin.scheduled, isEmpty);
    });

    test('reboot: the boot receiver + full-screen permission are in the manifest patch', () {
      final yml = File('../.github/workflows/android.yml').readAsStringSync();
      expect(yml, contains('ScheduledNotificationBootReceiver'));
      expect(yml, contains('android.intent.action.BOOT_COMPLETED'));
      expect(yml, contains('USE_FULL_SCREEN_INTENT'));
      expect(yml.contains('androidx.work'), isFalse, reason: 'WorkManager is banned (ColorOS crash)');
      final main = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt')
          .readAsStringSync();
      expect(main, contains('careCallPayload'));
      expect(main, contains('"/carecall_ring?p="'));
    });

    test('one ring per slot: push silent when the own alarm rang, rings when it is late', () async {
      final now = DateTime.now();
      final w = ccBdWall(now.add(const Duration(minutes: 1)));
      final it = _item(time: ccHhmm(w.hour, w.minute), qs: '', qe: '');
      await CareCallAlarms.reconcile([it], lang: 'en', now: now);
      final slot = ccSlotOf(ccNextSlot(it, now.subtract(const Duration(minutes: 11)))!);
      final push = PushPayload({'kind': 'carecall', 'slot_key': '1-$slot', 'attempt': '1'});
      // own alarm still waiting (late) -> the push rings, the alarm goes
      expect(await CareCallAlarms.onPush(push, plugin: plugin, now: now.add(const Duration(minutes: 1))), isTrue);
      expect(plugin.cancelled, contains(ccNotifId('1-$slot', 1)));
      // own alarm already fired (no longer pending) -> the push stays silent
      await CareCallAlarms.reconcile([it], lang: 'en', now: now);
      plugin.scheduled.remove(ccNotifId('1-$slot', 1));
      expect(await CareCallAlarms.onPush(push, plugin: plugin, now: now.add(const Duration(minutes: 1))), isFalse);
      // answered -> silent
      await CareCallAlarms.markHandled('1-$slot');
      expect(await CareCallAlarms.onPush(push, plugin: plugin), isFalse);
    });
  });

  group('answers + offline queue', () {
    final ring = ccRing('en');

    test('Done offline is kept and sent when online; the retry alarm is cancelled', () async {
      final api = FakeCareCallApi(offline: true);
      await CareCallActions.answer(ring, 'done', api: api);
      expect((await CareCallActions.outbox()).single['action'], 'done');
      expect(await CareCallAlarms.isHandled(ring['slot_key']!), isTrue);
      expect(plugin.cancelled, contains(ccNotifId(ring['slot_key']!, 2)));
      api.offline = false;
      expect(await CareCallActions.flush(api: api), isTrue);
      expect(await CareCallActions.outbox(), isEmpty);
      expect(api.ackBatches.single.single['slot'], '202611040900');
    });

    test('Snooze rings again in 10 minutes from the phone itself', () async {
      final now = DateTime.now();
      await CareCallActions.answer(ring, 'snooze', api: FakeCareCallApi(), now: now);
      final s = plugin.scheduled[ccNotifId(ring['slot_key']!, 9)];
      expect(s, isNotNull);
      expect(s!.at.difference(now.toUtc()).inMinutes, 10);
      expect(await CareCallAlarms.isHandled(ring['slot_key']!), isFalse);
    });
  });

  group('screens', () {
    testWidgets('consent: Accept once', (tester) async {
      final api = FakeCareCallApi(mine: ccMine('en', invite: true));
      await tester.pumpWidget(_app(CareCallScreen(api: api, debugMine: ccMine('en', invite: true))));
      await tester.pumpAndSettle();
      expect(find.text('Rina wants to send you Care Calls. Accept?'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(api.consents, [(9, true)]);
    });

    testWidgets('SCREEN 3: confirmed card + amber card with Call now / See location', (tester) async {
      await tester.pumpWidget(_app(CareCallScreen(api: FakeCareCallApi(), debugMine: ccMine('en'))));
      await tester.pumpAndSettle();
      expect(find.text('Care Call 9:20 am'), findsOneWidget);
      expect(find.text('Ammu did not answer twice'), findsOneWidget);
      expect(find.text('Care Call 9:02 am'), findsOneWidget);
      expect(find.text('Ammu confirmed'), findsOneWidget);
      expect(find.text('Call now'), findsOneWidget);
      expect(find.text('See location'), findsOneWidget);
    });

    testWidgets('SCREEN 3: no See location without existing sharing', (tester) async {
      await tester.pumpWidget(_app(CareCallScreen(api: FakeCareCallApi(), debugMine: ccMine('en', location: false))));
      await tester.pumpAndSettle();
      expect(find.text('Call now'), findsOneWidget);
      expect(find.text('See location'), findsNothing);
    });

    testWidgets('empty state: benefit line + big button + how-to', (tester) async {
      await tester.pumpWidget(_app(CareCallScreen(api: FakeCareCallApi(), debugMine: ccMine('en', empty: true))));
      await tester.pumpAndSettle();
      expect(find.textContaining('in your own voice'), findsOneWidget);
      expect(find.ancestor(of: find.text('New Care Call'), matching: find.byWidgetPredicate((w) => w is FilledButton)), findsOneWidget);
      expect(find.textContaining('Pick someone from My Circle'), findsOneWidget);
    });

    testWidgets('SCREEN 1: medicine words are sent exactly as written', (tester) async {
      _tall(tester);
      final api = FakeCareCallApi();
      await tester.pumpWidget(_app(_host(CareCallNewScreen(api: api, person: ccPerson('en')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('New Care Call'), findsOneWidget);
      expect(find.text('Record in your own voice'), findsOneWidget);
      expect(find.textContaining('tries again after 10 minutes'), findsOneWidget);
      const words = 'Napa 500mg + Seclo 20 before food — ওষুধ খাওয়ার সময়';
      await tester.enterText(find.byType(TextField), words);
      await tester.tap(find.text('Medicine time'));
      await tester.pump();
      await tester.tap(find.text('Turn on Care Call'));
      await tester.pumpAndSettle();
      expect(api.created.single['text'], '$words, Medicine time');
      expect(api.created.single['receiver_id'], 7);
      expect(api.created.single['time'], '09:00');
      expect(api.created.single['repeat'], 'daily');
    });

    testWidgets('SCREEN 1: Record in your own voice -> recording -> stop -> play / re-record / delete', (tester) async {
      _tall(tester);
      final rec = FakeRecorder();
      final oldF = ccRecorderFactory;
      ccRecorderFactory = () => rec;
      ccMicGrantedForTest = true;
      addTearDown(() {
        ccRecorderFactory = oldF;
        ccMicGrantedForTest = null;
      });
      await tester.pumpWidget(_app(_host(CareCallNewScreen(api: FakeCareCallApi(), person: ccPerson('en')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record in your own voice'));
      await tester.pump();
      expect(rec.calls, ['start']);
      expect(find.textContaining('Recording'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(rec.calls, ['start', 'stop']);
      expect(find.textContaining('Your voice'), findsOneWidget);
      expect(find.byTooltip('Record again'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete recording'));
      await tester.pumpAndSettle();
      expect(rec.calls.last, 'delete');
      expect(find.text('Record in your own voice'), findsOneWidget);
    });

    testWidgets('SCREEN 1: microphone refused -> clear message, nothing recorded', (tester) async {
      _tall(tester);
      final rec = FakeRecorder();
      final oldF = ccRecorderFactory;
      ccRecorderFactory = () => rec;
      ccMicGrantedForTest = false;
      addTearDown(() {
        ccRecorderFactory = oldF;
        ccMicGrantedForTest = null;
      });
      await tester.pumpWidget(_app(_host(CareCallNewScreen(api: FakeCareCallApi(), person: ccPerson('en')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record in your own voice'));
      await tester.pump();
      expect(rec.calls, isEmpty);
      expect(find.textContaining('Microphone permission is off'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('SCREEN 1: asks for who / what first (no silent dead button)', (tester) async {
      _tall(tester);
      final api = FakeCareCallApi();
      await tester.pumpWidget(_app(_host(CareCallNewScreen(api: api))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn on Care Call'));
      await tester.pump();
      expect(find.text('Pick who to remind.'), findsOneWidget);
      expect(api.created, isEmpty);
    });

    testWidgets('SCREEN 1: DND note when the time is in their quiet hours', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_host(CareCallNewScreen(api: FakeCareCallApi(), edit: {
        'id': 1, 'text': 'Drink water', 'time': '23:00', 'repeat': 'daily', 'days': [],
        'receiver_id': 7, 'other_name': 'Ammu', 'other_initial': 'A', 'link': 'accepted',
        'quiet_start': '22:00', 'quiet_end': '07:00', 'has_voice': false,
      }))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('so this call will ring at 7:00 am'), findsOneWidget);
    });

    testWidgets('SCREEN 2: big Done sends the answer, voice line shown', (tester) async {
      final api = FakeCareCallApi();
      final sound = FakeSound();
      await tester.pumpWidget(_app(_host(CareCallRingScreen(data: ccRing('en'), api: api, sound: sound))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Arif is reminding you'), findsOneWidget);
      expect(find.text('“Take your gas tablet”'), findsOneWidget);
      expect(find.text('Care Call · Assisto'), findsOneWidget);
      expect(tester.getSize(find.ancestor(of: find.text('Done'), matching: find.byWidgetPredicate((w) => w is FilledButton))).height,
          greaterThanOrEqualTo(72));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(api.ackBatches.single.single['action'], 'done');
      expect(find.text('Arif is reminding you'), findsNothing);
      expect(sound.calls, contains('stop')); // the voice stops on the answer
    });

    testWidgets('SCREEN 2: Remind me in 10 minutes', (tester) async {
      final api = FakeCareCallApi();
      await tester.pumpWidget(_app(_host(CareCallRingScreen(data: ccRing('en'), api: api, sound: FakeSound(), autoPlay: false))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remind me in 10 minutes'));
      await tester.pumpAndSettle();
      expect(api.ackBatches.single.single['action'], 'snooze');
      expect(plugin.scheduled.containsKey(ccNotifId('1-202611040900', 9)), isTrue);
    });

    for (final lang in const ['bn', 'en']) {
      testWidgets('all Care Call screens render at 200 % font, dark, $lang', (tester) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        for (final w in <Widget>[
          CareCallNewScreen(api: FakeCareCallApi(), person: ccPerson(lang), debugVoiceSec: 7,
              debugText: lang == 'bn' ? 'গ্যাসের ট্যাবলেটটা খাও' : 'Take your gas tablet'),
          CareCallRingScreen(data: ccRing(lang), sound: FakeSound(), autoPlay: false),
          CareCallScreen(api: FakeCareCallApi(), debugMine: ccMine(lang)),
        ]) {
          await tester.pumpWidget(_app(w, lang: lang, scale: 2.0, dark: true));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  });
}
