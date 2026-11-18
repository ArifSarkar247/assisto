// notif-nine: (1) Android 14+ exact alarms off -> explainer; declined ->
// the honest "may ring a few minutes late" line; (2) Done on a one-off
// reminder goes to the server straight from the closed app.
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notifications.dart';
import 'package:assisto/push/notif_text.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/exact_alarm_ui.dart';
import 'package:assisto/reminders/reminder_actions.dart';

Widget _host(void Function(BuildContext) onTap, {String lang = 'bn'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(onPressed: () => onTap(ctx), child: const Text('go')),
          ),
        ),
      ),
    );

NotificationResponse _tap(String action, String payload) => NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      actionId: action,
      payload: payload,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReminderActions.debugDoneOnServer = null;
  });

  group('one-off payload flag', () {
    test('one-off payload carries the flag; text still reads; old payloads are not one-off', () {
      final p = ReminderActions.payloadFor('rem-42', 'ওষুধ', 'খাওয়ার পরে', oneOff: true);
      expect(ReminderActions.isOneOff(p), isTrue);
      expect(ReminderActions.textOf(p), ('ওষুধ', 'খাওয়ার পরে'));
      expect(ReminderActions.keyOf(p), 'rem-42');
      final old = ReminderActions.payloadFor('rem-42', 'ওষুধ', '');
      expect(ReminderActions.isOneOff(old), isFalse);
      expect(ReminderActions.isOneOff('remalarm:rem-42'), isFalse);
      expect(ReminderActions.serverIdOf('rem-42'), 42);
      expect(ReminderActions.serverIdOf('remloc-abc'), isNull);
      expect(ReminderActions.serverIdOf('rem-42~1'), isNull);
    });

    test('planner marks one-offs only; their alarm signature changes once', () {
      final now = DateTime(2026, 11, 18, 9);
      final plans = planReminderAlarms([
        {'serverId': 1, 'localId': 'a', 'data': {'title': 'once', 'due_at': '2026-11-18T10:00:00'}},
        {'serverId': 2, 'localId': 'b', 'data': {
          'title': 'daily', 'due_at': '2026-11-18T11:00:00',
          'recurrence_rule': {'freq': 'daily', 'interval': 1}}},
      ], now: now);
      final once = plans.firstWhere((p) => p.title == 'once');
      final daily = plans.firstWhere((p) => p.title == 'daily');
      expect(once.oneOff, isTrue);
      expect(daily.oneOff, isFalse);
      expect(once.sig(AlarmMode.exact), endsWith('|o|a2'));
      expect(daily.sig(AlarmMode.exact), isNot(contains('|o|')));
    });
  });

  group('Done with the app closed', () {
    test('one-off Done goes straight to the server (and stays recorded as the retry)', () async {
      final sent = <int>[];
      ReminderActions.debugDoneOnServer = (id) async {
        sent.add(id);
        return true;
      };
      final a = await ReminderActions.record(_tap(ReminderActions.done,
          ReminderActions.payloadFor('rem-7', 'পানি', '', oneOff: true)));
      expect(a, ReminderActions.done);
      expect(sent, [7]);
      final prefs = await SharedPreferences.getInstance();
      expect(ReminderActions.decode(prefs.getString(ReminderActions.pendingKey)).single['k'], 'rem-7');
    });

    test('offline: nothing lost, still applied on the next start', () async {
      ReminderActions.debugDoneOnServer = (id) async => false;
      await ReminderActions.record(_tap(ReminderActions.done,
          ReminderActions.payloadFor('rem-8', 'x', '', oneOff: true)));
      final prefs = await SharedPreferences.getInstance();
      expect(ReminderActions.decode(prefs.getString(ReminderActions.pendingKey)), hasLength(1));
    });

    test('a repeating reminder, a local-only one and Snooze never call the server directly', () async {
      final sent = <int>[];
      ReminderActions.debugDoneOnServer = (id) async {
        sent.add(id);
        return true;
      };
      await ReminderActions.record(_tap(ReminderActions.done,
          ReminderActions.payloadFor('rem-9', 'daily pill', '')));
      await ReminderActions.record(_tap(ReminderActions.done,
          ReminderActions.payloadFor('remloc-x', 'local', '', oneOff: true)));
      expect(sent, isEmpty);
    });
  });

  group('exact alarms off (Android 14+ new installs)', () {
    setUp(() {
      ExactAlarmHooks.shouldExplain = () async => true;
    });
    tearDown(() {
      ExactAlarmHooks.shouldExplain = () async => false;
    });

    for (final lang in ['bn', 'en']) {
      testWidgets('declined -> honest "may ring a few minutes late" line ($lang)', (tester) async {
        var asked = 0;
        ExactAlarmHooks.requestExact = () async {
          asked++;
          return false;
        };
        await tester.pumpWidget(_host((ctx) => maybeAskExactAlarms(ctx), lang: lang));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.text(t.rmxExactTitle), findsOneWidget);
        await tester.tap(find.text(t.rmxLater));
        await tester.pumpAndSettle();
        expect(asked, 0);
        expect(find.text(t.rmxBannerTitle), findsOneWidget);
      });
    }

    testWidgets('Allow -> the system page; turned on -> no late warning', (tester) async {
      var asked = 0;
      ExactAlarmHooks.requestExact = () async {
        asked++;
        return true;
      };
      await tester.pumpWidget(_host((ctx) => maybeAskExactAlarms(ctx)));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      await tester.tap(find.text(t.rmxAllow));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(find.text(t.rmxBannerTitle), findsNothing);
    });

    testWidgets('Allow but left off in Settings -> the late warning too', (tester) async {
      ExactAlarmHooks.requestExact = () async => false;
      await tester.pumpWidget(_host((ctx) => maybeAskExactAlarms(ctx)));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      await tester.tap(find.text(t.rmxAllow));
      await tester.pumpAndSettle();
      expect(find.text(t.rmxBannerTitle), findsOneWidget);
    });

    testWidgets('two asks at once -> one sheet', (tester) async {
      await tester.pumpWidget(_host((ctx) {
        maybeAskExactAlarms(ctx);
        maybeAskExactAlarms(ctx);
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(t.rmxExactTitle), findsOneWidget);
    });
  });

  group('shade text audit (bn has no English, Bangla digits)', () {
    final latin = RegExp(r'[A-Za-z]');
    String strip(String x) => x.replaceAll('Assisto', '').replaceAll('SOS', '');

    test('every push channel name + description is Bangla in bn, English in en', () {
      for (final c in PushNotifier.channels('bn')) {
        expect(latin.hasMatch(strip(c.name)), isFalse, reason: 'bn channel ${c.id}: ${c.name}');
        expect(latin.hasMatch(strip(c.description ?? '')), isFalse,
            reason: 'bn channel ${c.id}: ${c.description}');
        expect(RegExp('[0-9]').hasMatch(c.description ?? ''), isFalse,
            reason: 'bn digits in ${c.id}');
      }
      for (final c in PushNotifier.channels('en')) {
        expect(RegExp('[ঀ-৿]').hasMatch(c.name), isFalse, reason: 'en channel ${c.id}');
      }
    });

    test('the phone-alarm reminder channel is named in the app language (was English only)', () {
      Notifications.actionLang = 'bn';
      final (bnName, bnDesc) = Notifications.reminderChannelNames();
      expect(latin.hasMatch(strip(bnName)), isFalse);
      expect(latin.hasMatch(strip(bnDesc)), isFalse);
      Notifications.actionLang = 'en';
      final (enName, _) = Notifications.reminderChannelNames();
      expect(enName, 'Reminder alarms');
      Notifications.actionLang = 'bn';
    });

    test('reminder alarm buttons are Bangla in bn', () {
      Notifications.actionLang = 'bn';
      final d = Notifications.detailsFor(ReminderActions.payloadFor('rem-1', 'x', ''));
      final acts = d.android!.actions!;
      expect(acts.map((a) => a.title), ['হয়ে গেছে', '১০ মিনিট পরে']);
      expect(d.android!.channelId, Notifications.reminderChannelId);
    });

    test('summary count uses Bangla digits in bn only', () {
      expect(notifDigits('bn', '3টি চ্যাটে নতুন মেসেজ'), '৩টি চ্যাটে নতুন মেসেজ');
      expect(notifDigits('bn', '10:30'), '১০:৩০');
      expect(notifDigits('en', 'New messages in 3 chats'), 'New messages in 3 chats');
    });
  });
}

