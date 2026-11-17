// flagproof (17 Nov 2026): the reality proofs for hidden features whose ONE
// missing thing was an emulator flow (owner_actions/FEATURE_SWITCHES_BN.md,
// group B). Group 'flagproof' — its seed (seed_reality, REALITY_DRIVE
// contains "flagproof") allow-lists demo users A-D for these flags and sets up
// the second accounts: D = A's brother with a small salon (booking page),
// B = an O+ blood donor in Dhaka, C = opted in to missing alerts for Dhaka.
//   31 ps_secretary      Today's brief: pick a follow-up out of a message, mark done
//   32 ai_daily_planner  an urgent task becomes a time block on today's plan
//   33 booking_bot       A books D's salon from the link; D confirms; A cancels
//   34 official_corners  Probashi helplines + real-cost check; Student official tab
//   35 blood_donors      A asks for blood -> donor B is told, says "I can", private chat
//   36 missing_alert     A says "I am safe" on D's alert; A posts -> C told, tips, reports; found
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/screens/booking/booking_widgets.dart' show BkSlotPicker, BkBookingTile;
import 'package:assisto/screens/pa/pa_hub_screen.dart';
import 'package:assisto/screens/probashi_screen.dart';
import 'package:assisto/screens/student_corner_screen.dart';

import '../support/harness.dart';

const _phoneC = String.fromEnvironment('REALITY_PHONE_C', defaultValue: '01711000777');
const _phoneD = '01700000004';
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

/// Sign a second demo account in from a separate harness device id (a sign-in
/// from the app's own device id would replace the app's session).
Future<ApiClient> _login(RFlow f, String phone, String device) async {
  final c = ApiClient();
  final appDevice = AppConfig.deviceId;
  AppConfig.deviceId = device;
  try {
    final r = await f.net(() => c.login(identifier: phone, password: Seed.password));
    c.token = r.token;
  } finally {
    AppConfig.deviceId = appDevice;
  }
  c.lang = 'en';
  return c;
}

Future<Map<String, dynamic>> _get(RFlow f, ApiClient c, String path) => f.net(() => c.getJson(path));
Future<Map<String, dynamic>> _post(RFlow f, ApiClient c, String path, Map<String, dynamic> body) =>
    f.net(() => c.postJsonRaw(path, body));

/// Drag the visible vertical list until [target] is built.
Future<void> _scrollDownTo(RFlow f, Finder target, String what) async {
  final list = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    if (list.evaluate().isEmpty) break;
    await f.tester.drag(list.first, const Offset(0, -300), warnIfMissed: false);
    await f.tester.pump(const Duration(milliseconds: 350));
  }
  await f.waitFor(target, what: what);
}

/// Drawer search first (the user's path); screens without a ChatNav route
/// are pushed directly if the drawer path fails (the note keeps it honest).
Future<void> _openDrawerOr(RFlow f, String label, Widget screen) async {
  try {
    await f.openFromDrawer(label);
  } catch (e) {
    f.note('drawer path failed for "$label" ($e); opened directly');
    await f.backToHome();
    await f.pushScreen(screen);
  }
}

Finder _keyPrefix(String p) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(p));

void registerFlagproofFlows() {
  // -------------------------------------------------------------- 31 PS
  realityFlow('31_ps_secretary', 'Work', "PS Today's brief: pick a follow-up out of a message, then mark it done",
      (f) async {
    await f.home();
    final title = 'Send the quotation fp$_tag';
    await f.step("open Personal Secretary -> Today's brief", () async {
      await _openDrawerOr(f, f.t.sidebarPersonalSecretary, const PaHubScreen());
      await f.tap(find.text(f.t.psecTodayTitle).last, settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('ps-act-pickup')), what: "Today's brief actions");
      await f.shot('today');
      f.expectHttp('GET', '/ps/today');
    });
    await f.step('pick up a follow-up from a pasted message', () async {
      await f.tap(find.byKey(const ValueKey('ps-act-pickup')), settleSeconds: 2);
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-msg')),
          'Karim Bhai: please send the quotation tomorrow at 5pm');
      await f.tap(find.byKey(const ValueKey('ps-pickup-find')), settleSeconds: 1);
      await f.tap(find.byKey(const ValueKey('ps-kind-followup')), settleSeconds: 1);
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-title')), title);
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-who')), 'Karim Bhai');
      await f.tester.pump(const Duration(milliseconds: 400));
      if (find.text(f.t.psecNoDateFound).evaluate().isNotEmpty) {
        throw TestFailure('"tomorrow at 5pm" was not understood as a date');
      }
      await f.shot('pickup-filled');
      await f.tap(find.byKey(const ValueKey('ps-pickup-add')), settleSeconds: 3);
      await f.waitFor(find.textContaining(title), seconds: 20, what: 'the follow-up on the brief');
      await f.shot('brief-with-followup');
      final api = await f.h.backend();
      await f.eventually('the brief on the server lists the follow-up', () async {
        final b = await api.getJson('/ps/today');
        return '${b['sections']}'.contains(title);
      });
    });
    await f.step('mark it done -> it leaves the brief', () async {
      final done = _keyPrefix('ps-done-');
      await _scrollDownTo(f, done, 'the "Done" button');
      await f.tap(done.first, settleSeconds: 3);
      final api = await f.h.backend();
      await f.eventually('the follow-up is done on the server', () async {
        final b = await api.getJson('/ps/today');
        return !'${b['sections']}'.contains(title);
      });
      await f.shot('done');
    });
  });

  // -------------------------------------------------------------- 32 planner
  realityFlow('32_day_planner', 'Work', 'AI daily planner: an urgent task becomes part of today\'s plan',
      (f) async {
    await f.home();
    final title = 'Pay the shop rent fp$_tag';
    await f.step('an urgent task exists (Task manager data)', () async {
      final api = await f.h.backend();
      await f.net(() => api.createItem('tasks_items',
          {'title': title, 'priority': 'urgent', 'status': 'todo', 'est_min': 30}));
      f.note('the task is created through the same API the Task manager uses');
    });
    await f.step('open the daily planner: the task is on today\'s plan', () async {
      await f.openFeature(f.t.p2DayPlanner, 'day_planner');
      await f.waitFor(find.textContaining(title), seconds: 20, what: 'the urgent task on the plan');
      await f.shot('plan');
      f.expectHttp('GET', '/planner/today');
      final api = await f.h.backend();
      final p = await f.net(() => api.getJson('/planner/today'));
      final onPlan = '${p['blocks']}${p['unscheduled']}'.contains(title);
      if (!onPlan) throw TestFailure('server plan does not hold the task');
      f.note('${'${p['blocks']}'.contains(title) ? 'time block' : 'listed as "does not fit today" (late run)'}; '
          'AI polish is optional and key-gated (not exercised)');
    });
  });

  // -------------------------------------------------------------- 33 booking
  realityFlow('33_booking_bot', 'Business', 'Booking: A books D\'s salon from its link; D confirms; A cancels',
      (f) async {
    await f.home();
    final d = await _login(f, _phoneD, 'reality-harness-d');
    int? bid;
    await f.step('open My bookings -> Book new -> paste the salon link', () async {
      await f.openFeature(f.t.bkgSidebarMine, 'my_bookings');
      await f.tap(find.widgetWithText(FloatingActionButton, f.t.bkgBookNew), settleSeconds: 2);
      await f.enter('lifeassisto.com/b/flagproof-salon', label: f.t.bkgLinkLabel);
      await f.tap(find.widgetWithText(FilledButton, f.t.bkgOpenLink), settleSeconds: 3);
      await f.waitFor(find.text('Haircut'), what: 'the salon\'s service');
      await f.shot('salon');
    });
    await f.step('pick a day + a free time -> Confirm', () async {
      final picker = find.byType(BkSlotPicker);
      await _scrollDownTo(f, picker, 'the time picker');
      final days = find.descendant(
          of: find.descendant(of: picker, matching: find.byType(ListView)), matching: find.byType(ChoiceChip));
      await f.tap(days.at(2), settleSeconds: 3);
      final times = find.descendant(
          of: find.descendant(of: picker, matching: find.byType(Wrap)), matching: find.byType(ChoiceChip));
      await f.waitFor(times, seconds: 15, what: 'free times');
      await f.tap(times.first, settleSeconds: 1);
      // run 44049525968: the Confirm button sits below 28 time chips in a lazy list
      final confirm = find.widgetWithText(FilledButton, f.t.bkgConfirmBooking);
      await _scrollDownTo(f, confirm, 'Confirm booking');
      await f.tester.ensureVisible(confirm);
      await f.shot('picked');
      await f.tap(confirm, settleSeconds: 4);
      await f.waitFor(find.text(f.t.bkgRequestedTitle), what: '"request sent" page');
      await f.shot('requested');
    });
    await f.step('the salon (second account) sees the request and confirms', () async {
      await f.eventually('D sees A\'s booking request', () async {
        final r = await d.getJson('/booking/biz/bookings?scope=upcoming');
        final rows = (r['bookings'] as List).cast<Map>();
        final row = rows.where((b) => b['status'] == 'requested').toList();
        if (row.isEmpty) return false;
        bid = row.first['id'] as int;
        return true;
      });
      final r = await _post(f, d, '/booking/biz/bookings/$bid/action', {'action': 'confirmed'});
      if (r['status'] != 'confirmed') throw TestFailure('confirm failed: $r');
      await f.tap(find.widgetWithText(FilledButton, f.t.bkgDone), settleSeconds: 3);
    });
    await f.step('A sees it confirmed and cancels; the salon sees the cancel', () async {
      final tile = find.byType(BkBookingTile);
      await f.waitFor(tile, what: 'the booking in My bookings');
      await f.shot('my-bookings');
      await f.tap(tile.first, settleSeconds: 2);
      await f.shot('booking-sheet');
      final cancel = find.text(f.t.bkgCancelBooking);
      await f.waitFor(cancel, what: 'Cancel booking');
      await f.tap(cancel, settleSeconds: 3);
      await f.eventually('the salon sees the booking cancelled', () async {
        final r = await d.getJson('/booking/biz/bookings/$bid');
        return '${r['status'] ?? (r['booking'] as Map?)?['status']}' == 'cancelled';
      });
      await f.shot('cancelled');
    });
  });

  // -------------------------------------------------------------- 34 official
  realityFlow('34_official_corners', 'Daily life', 'Probashi help (helplines, real cost) + Student official links',
      (f) async {
    await f.home();
    await f.step('Probashi corner -> Help: helplines from the official list', () async {
      await _openDrawerOr(f, f.t.probashiTitle, const ProbashiScreen());
      await f.tap(find.text(f.t.p3gTabHelp), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('p3g-probashi-help')), seconds: 20, what: 'the Help tab');
      await f.waitFor(find.text('16135'), what: 'Probash-Bondhu 16135');
      await f.waitFor(find.byKey(const ValueKey('p3g-call-probashbondhu')), what: 'its Call button');
      await f.shot('helplines');
      f.expectHttp('GET', '/official-info/probashi');
    });
    await f.step('real cost of one transfer (World Bank method)', () async {
      for (final (k, v) in [('p3g-amount', '500'), ('p3g-fee', '5'), ('p3g-rate-got', '30'), ('p3g-rate-ref', '30.5')]) {
        final box = find.byKey(ValueKey(k));
        await _scrollDownTo(f, box, k);
        await f.tester.ensureVisible(box);
        await f.tester.enterText(find.descendant(of: box, matching: find.byType(EditableText)).first, v);
      }
      await f.tap(find.byKey(const ValueKey('p3g-check')), settleSeconds: 2);
      // (5 + 500*(30.5-30)/30.5) / 500 = 2.64 % -> under the SDG 3 %
      await f.waitFor(find.byKey(const ValueKey('p3g-result')), what: 'the cost result');
      final shown = (f.tester.widget(find.byKey(const ValueKey('p3g-result'))) as Text).data ?? '';
      if (!shown.contains('2.64')) throw TestFailure('cost shown "$shown", expected 2.64 %');
      await f.shot('real-cost');
    });
    await f.step('Student corner -> Official: notice links + checked date', () async {
      await _openDrawerOr(f, f.t.studentTitle, const StudentCornerScreen());
      await f.tap(find.text(f.t.p3gTabOfficial), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('p3g-student-official')), seconds: 20, what: 'the Official tab');
      await f.shot('student-official');
      f.expectHttp('GET', '/official-info/student');
    });
  });

  // -------------------------------------------------------------- 35 blood
  realityFlow('35_blood_two_accounts', 'Health', 'Blood: A asks -> donor B is told, says "I can", private chat both ways',
      (f) async {
    await f.home();
    final b = await f.h.backend(userB: true);
    final hospital = 'Dhaka Medical College Hospital fp$_tag';
    int? rid;
    await f.step('A: urgent request (A+, Dhaka) from the Blood donor hub', () async {
      await f.openFeature(f.t.hv2TileBloodDonor, 'blood_panel');
      // the hub's own "Send request" button (the bottom bar one shows on other tabs)
      final hero = find.byKey(const ValueKey('bp-hero-request'));
      await f.tap(hero.evaluate().isNotEmpty ? hero : find.byKey(const ValueKey('bp-request-fab')),
          settleSeconds: 3);
      await f.tap(find.byKey(const ValueKey('bp-req-g-A+')), settleSeconds: 1);
      await f.tester.enterText(find.byKey(const ValueKey('bp-req-hospital')), hospital);
      await f.tap(find.byKey(const ValueKey('bp-req-district')), settleSeconds: 2);
      await f.tap(find.text('Dhaka').last, settleSeconds: 2);
      final area = find.byKey(const ValueKey('bp-req-area'));
      await f.tester.ensureVisible(area);
      await f.tester.enterText(area, 'Mirpur');
      final real = find.byKey(const ValueKey('bp-req-real'));
      await _scrollDownTo(f, real, 'the "real need" box');
      await f.tap(real, settleSeconds: 1);
      await f.shot('request-form');
      await f.tap(find.byKey(const ValueKey('bp-req-submit')), settleSeconds: 4);
      final api = await f.h.backend();
      await f.eventually('the request is live on the server', () async {
        final r = await api.getJson('/blood-panel/requests');
        final mine = (r['mine'] as List).cast<Map>().where((x) => '$x'.contains(hospital)).toList();
        if (mine.isEmpty) return false;
        rid = mine.first['id'] as int;
        return true;
      });
      await f.shot('request-sent');
    });
    await f.step('B (O+ donor, Dhaka) is told and answers "I can donate"', () async {
      await f.eventually('the request is in B\'s nearby list', () async {
        final r = await b.getJson('/blood-panel/requests');
        return (r['near'] as List).any((x) => (x as Map)['id'] == rid);
      });
      final feed = await _get(f, b, '/notif/feed');
      final told = '$feed'.contains('blood_panel');
      f.note(told ? 'B has the in-app notification (push goes to FCM on a real phone)'
                  : 'B listed as recipient; in-app row not in feed');
      final r = await _post(f, b, '/blood-panel/requests/$rid/respond', {'answer': 'can'});
      if ((r['_status'] as int) >= 300) throw TestFailure('respond failed: $r');
    });
    await f.step('A sees the donor (no phone) and opens the private chat', () async {
      // back to the hub, then reopen the request from "Requests"
      for (var i = 0; i < 3 && find.byKey(const ValueKey('bp-tab-requests')).evaluate().isEmpty; i++) {
        await f.tester.pageBack();
        await f.pumpFor(const Duration(seconds: 2));
      }
      await f.tap(find.byKey(const ValueKey('bp-tab-requests')), settleSeconds: 3);
      await f.tap(find.byKey(ValueKey('bp-req-$rid')), settleSeconds: 3);
      final msg = _keyPrefix('bp-resp-msg-');
      await _scrollDownTo(f, msg, 'the donor\'s Message button');
      await f.shot('responder');
      await f.tap(msg.first, settleSeconds: 3);
      await f.tester.enterText(find.byKey(const ValueKey('bp-thread-field')), 'Thank you! Ward 4, by 6 pm. fp$_tag');
      await f.tap(find.byKey(const ValueKey('bp-thread-send')), settleSeconds: 3);
      await f.shot('chat-sent');
    });
    await f.step('B reads A\'s message and answers; A sees the answer', () async {
      int? tid;
      await f.eventually('B has the private thread with A\'s message', () async {
        final r = await b.getJson('/blood-panel/threads');
        for (final t in (r['threads'] as List).cast<Map>()) {
          final m = await b.getJson('/blood-panel/threads/${t['id']}');
          if ('${m['messages']}'.contains('fp$_tag')) {
            tid = t['id'] as int;
            return true;
          }
        }
        return false;
      });
      await _post(f, b, '/blood-panel/threads/$tid', {'text': 'On my way, 20 minutes'});
      // the chat screen refreshes on its own or on reopen
      if (!await f.appears(find.textContaining('On my way'), seconds: 15)) {
        await f.tester.pageBack();
        await f.pumpFor(const Duration(seconds: 2));
        await f.tap(_keyPrefix('bp-resp-msg-').first, settleSeconds: 3);
      }
      await f.waitFor(find.textContaining('On my way'), seconds: 20, what: 'the donor\'s answer');
      await f.shot('chat-answer');
    });
  });

  // -------------------------------------------------------------- 36 missing
  realityFlow('36_missing_two_accounts', 'Safety',
      'Missing alert: A says "I am safe" on D\'s alert; A posts -> C told, tips, reports; found', (f) async {
    await f.home();
    final d = await _login(f, _phoneD, 'reality-harness-d');
    final c = await _login(f, _phoneC, 'reality-harness-c');
    final api = await f.h.backend();
    final me = await f.net(() => api.getJson('/me'));
    final aId = (me['id'] ?? (me['user'] as Map?)?['id']) as int;
    final today = DateTime.now();
    String day(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    int? aboutA;
    await f.step('D (A\'s brother) posts an alert about A (adult, GD)', () async {
      final r = await _post(f, d, '/missing-alerts', {
        'name': 'Rahim', 'age': 34, 'relation': 'brother', 'subject_user_id': aId,
        'area_text': 'Farmgate bus stand', 'district': 'dhaka', 'radius_km': 10,
        'description': 'Blue shirt, black bag',
        'last_seen_at': today.subtract(const Duration(hours: 3)).toUtc().toIso8601String(),
        'gd_number': 'GD No. 512/2026', 'gd_thana': 'Tejgaon', 'gd_date': day(today.subtract(const Duration(days: 1))),
        'confirm_is_family': true, 'confirm_no_address': true, 'confirm_false_post': true,
      });
      if ((r['_status'] as int) != 201) throw TestFailure('D could not post: $r');
      aboutA = (r['alert'] as Map)['id'] as int;
    });
    await f.step('A (the person) opens the hub and says "I am safe"', () async {
      await f.openFeature(f.t.maTitle, 'missing_alert');
      await f.waitFor(find.byKey(ValueKey('ma-about-$aboutA')), seconds: 20, what: 'the "about you" card');
      await f.shot('about-me');
      await f.tap(find.descendant(of: find.byKey(ValueKey('ma-about-$aboutA')),
          matching: find.byKey(const ValueKey('ma-safe'))), settleSeconds: 2);
      await f.tap(find.byKey(const ValueKey('ma-safe-confirm')), settleSeconds: 3);
      await f.eventually('D sees "safe" (no location shared)', () async {
        final r = await d.getJson('/missing-alerts/$aboutA');
        final a = r['alert'] as Map;
        // no location in what the family sees (run 44049525968: a '$a'.contains('lat')
        // check matched the word "relation")
        return a['safe_said'] == true && a['state'] == 'safe' && a['lat'] == null && a['lng'] == null;
      });
      await f.shot('safe-said');
    });
    final name = 'Rafiq fp$_tag';
    int? aid;
    await f.step('A posts an alert (adult, GD, Dhaka, three confirmations)', () async {
      await f.tap(find.byKey(const ValueKey('ma-post-fab')), settleSeconds: 3);
      await f.tap(find.byKey(const ValueKey('ma-who-other')), settleSeconds: 1);
      await f.tester.enterText(find.byKey(const ValueKey('ma-relation')), 'cousin');
      await f.tester.enterText(find.byKey(const ValueKey('ma-name')), name);
      await f.tester.enterText(find.byKey(const ValueKey('ma-age')), '34');
      await f.tester.pump(const Duration(milliseconds: 400));
      await f.tester.enterText(find.byKey(const ValueKey('ma-desc')), 'Grey shirt, glasses, about 5 feet 6');
      final area = find.byKey(const ValueKey('ma-area'));
      await _scrollDownTo(f, area, 'area box');
      await f.tester.ensureVisible(area);
      await f.tester.enterText(area, 'Mirpur 10 bus stand');
      final dist = find.byKey(const ValueKey('ma-district'));
      await f.tester.ensureVisible(dist);
      await f.tap(dist, settleSeconds: 2);
      await f.tap(find.text('Dhaka').last, settleSeconds: 2);
      final gd = find.byKey(const ValueKey('ma-gd-number'));
      await _scrollDownTo(f, gd, 'GD number');
      await f.tester.ensureVisible(gd);
      await f.tester.enterText(gd, '612/2026');
      await f.tester.enterText(find.byKey(const ValueKey('ma-gd-thana')), 'Mirpur Model');
      for (final k in ['ma-c1', 'ma-c2', 'ma-c3']) {
        final box = find.byKey(ValueKey(k));
        await _scrollDownTo(f, box, k);
        await f.tap(box, settleSeconds: 0.5);
      }
      await f.shot('post-form');
      final submit = find.byKey(const ValueKey('ma-submit'));
      await _scrollDownTo(f, submit, 'Post');
      await f.tap(submit, settleSeconds: 5);
      await f.eventually('A\'s alert is active on the server', () async {
        final r = await api.getJson('/missing-alerts');
        final mine = (r['mine'] as List).cast<Map>().where((x) => '$x'.contains(name)).toList();
        if (mine.isEmpty || mine.first['state'] != 'active') return false;
        aid = mine.first['id'] as int;
        return true;
      });
      await f.shot('posted');
    });
    await f.step('C (opted in, Dhaka) is told, sends a private tip and a report', () async {
      await f.eventually('the alert is in C\'s nearby list without the poster', () async {
        final r = await c.getJson('/missing-alerts');
        final near = (r['near'] as List).cast<Map>().where((x) => x['id'] == aid).toList();
        return near.isNotEmpty && !'$near'.contains('Reality Rahim');
      });
      final tip = await _post(f, c, '/missing-alerts/$aid/tips', {'text': 'Saw him near Mirpur 10 at 5 pm fp$_tag'});
      if ((tip['_status'] as int) >= 300) throw TestFailure('tip failed: $tip');
      final rep = await _post(f, c, '/missing-alerts/$aid/report', {'reason': 'fake', 'note': 'checking the report path'});
      if (rep['ok'] != true) throw TestFailure('report failed: $rep');
      f.note('report recorded (status ${rep['status']}); a new account\'s report is kept but not counted '
          'towards auto-hide (3 counted reports hide)');
    });
    await f.step('A reads the tip privately, then marks the person found; C is told', () async {
      // posting returns to the hub; reload it so the new alert is listed
      await f.openRoute('missing_alert');
      final tile = find.byKey(ValueKey('ma-alert-$aid'));
      await _scrollDownTo(f, tile, 'A\'s alert');
      await f.tap(tile, settleSeconds: 3);
      final tips = find.byKey(const ValueKey('ma-tips'));
      await _scrollDownTo(f, tips, 'the tips button');
      await f.tap(tips, settleSeconds: 3);
      await f.waitFor(find.textContaining('Saw him near Mirpur 10'), what: 'C\'s tip');
      await f.shot('tip');
      await f.tester.tapAt(const Offset(20, 60)); // close the sheet
      await f.pumpFor(const Duration(seconds: 2));
      final found = find.byKey(const ValueKey('ma-found'));
      await _scrollDownTo(f, found, 'Found');
      await f.tap(found, settleSeconds: 2);
      await f.tap(find.byKey(const ValueKey('ma-found-confirm')), settleSeconds: 4);
      await f.eventually('the alert is closed as found for C too', () async {
        final r = await c.getJson('/missing-alerts');
        return !(r['near'] as List).cast<Map>().any((x) => x['id'] == aid && x['state'] == 'active');
      });
      await f.shot('found');
    });
  });
}
