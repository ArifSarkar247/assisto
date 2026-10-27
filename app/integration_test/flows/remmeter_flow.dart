// remmeter: exact reminders + prepaid meter guard on the emulator (API 33).
//
// 20_reminder_exact — a reminder 75 s ahead is reconciled into an EXACT OS
// alarm (stable id = the server push id), then we wait for Android to POST
// it and measure scheduled-vs-delivered lateness from the notification's
// real post time (native StatusBarNotification.postTime). Fails when it
// does not arrive within 60 s of its time (owner's alert bar).
// Real OEM battery savers (Xiaomi/Realme/Oppo/Vivo) need a real phone:
// owner_actions/REMINDERS_METER_100_BN.md.
//
// 21_prepaid_meter — a DESCO meter with a low balance + daily-use estimate
// shows "low", the recharge sheet shows the verified bKash/Nagad steps.
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/notifications.dart';
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/reminder_alarms.dart';
import 'package:assisto/screens/prepaid_meter_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
const _oem = MethodChannel('com.assisto/oem_guide');

void registerRemMeterFlows() {
  realityFlow('20_reminder_exact', 'Personal',
      'Reminders: exact OS alarm, delivered on time (measured on the emulator)',
      (f) async {
    await f.home();
    final title = 'Exact alarm r$_tag';
    late AlarmPlan plan;
    late bool exact;
    await f.step('local notifications up; exact alarms allowed?', () async {
      await f.net(() => Notifications.init());
      exact = await f.net(() => Notifications.canScheduleExact());
      f.note('exact alarms allowed: $exact');
    });
    await f.step('create a reminder 75 s ahead -> exact alarm with the push id',
        () async {
      final due = DateTime.now().add(const Duration(seconds: 75));
      await f.net(() => f.app.reminders.add({
            'title': title,
            'notes': '',
            'due_at': due.toUtc().toIso8601String(),
            'recurrence': 'none',
            'recurrence_rule': <String, dynamic>{},
            'date_only': false,
            'done': false,
            'link': <String, dynamic>{},
          }));
      await f.eventually('alarm handed to Android', () async {
        await ReminderAlarms.reconcile(f.app.reminders.items);
        final plans = planReminderAlarms(f.app.reminders.items,
            now: DateTime.now());
        final mine = plans.where((p) => p.title == title);
        if (mine.isEmpty) return false;
        plan = mine.first;
        final ids = await Notifications.pendingIds();
        return ids != null && ids.contains(plan.id);
      });
      f.note('key ${plan.key}');
    });
    await f.step('Android delivers it within 60 s of its time', () async {
      int? post;
      await f.eventually('notification posted', () async {
        final m = await _oem.invokeMethod<Map>('activePostTimes');
        final v = m?[plan.id];
        post = v is int ? v : null;
        return post != null;
      }, seconds: 180);
      final lateS =
          ((post! - plan.at.millisecondsSinceEpoch) / 1000).round();
      f.note('scheduled ${plan.at.toIso8601String()} delivered '
          '${DateTime.fromMillisecondsSinceEpoch(post!).toIso8601String()} '
          'late ${lateS}s (mode ${exact ? 'exact' : 'inexact'})');
      await f.shot('delivered');
      if (lateS > 60) {
        throw TestFailure('reminder delivered ${lateS}s late (bar: 60 s)');
      }
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('21_prepaid_meter', 'Money',
      'Prepaid meter: company + estimate -> low; verified recharge steps',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final name = 'Home meter m$_tag';
    await f.step('a DESCO meter, ৳100 left, ৳50/day estimate', () async {
      await f.net(() => api.createItem('meter/meters', {
            'name': name,
            'kind': 'electricity',
            'utility': 'desco',
            'meter_no': '12345678',
            'balance': '100',
            'balance_date':
                DateTime.now().toIso8601String().split('T').first,
            'daily_use': '50',
            'alert_days': 3,
            'alerts': true,
          }));
    });
    await f.step('open Prepaid meter -> card says low, alert on', () async {
      await f.openRoute('prepaid_meter');
      await f.waitFor(find.byType(PrepaidMeterScreen), what: 'meter screen');
      await f.waitFor(find.text(name), what: 'the new meter');
      await f.waitFor(find.text(f.t.meterStateLow).first, what: 'low state');
      await f.shot('meter_low');
    });
    await f.step('How to recharge -> verified bKash + Nagad steps', () async {
      final cta = find.text(f.t.mtrPayCta).first;
      await f.tester.ensureVisible(cta);
      await f.tap(cta, settleSeconds: 2);
      await f.waitFor(find.byType(PayPathSheet), what: 'pay sheet');
      expect(find.text(f.t.mtrStepPayBill), findsNWidgets(2));
      await f.shot('pay_paths');
    });
  });
}
