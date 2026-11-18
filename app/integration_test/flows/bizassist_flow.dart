// bizassist (18 Nov 2026): Personal Secretary (board row 17) + booking bot
// (row 26) proofs. Opt-in group 'bizassist' (reality.yml `optin`; never part
// of "all"). The seed (REALITY_DRIVE contains "bizassist") allow-lists A-D for
// ps_secretary / booking_bot, links A<->D as brothers and opens D's
// "Flagproof Salon" (Haircut 30 min, 09:00-21:00, capacity 1, shop confirms).
// The emulator runs in Asia/Dhaka (-timezone) like a phone in Bangladesh; a
// host loop runs `booking_reminders --ci-24h-before` every 15 s (CI-only time
// travel: the real sweep, as if 23 h 55 min before the start).
//   37 ps_brief  today's real reminders (one-off + a daily repeat from 3 days
//                ago), a bill (subscription due tomorrow) and a calendar item
//                show on the brief; a Bangla dictated task lands at tomorrow
//                10:00 phone time; D's missed call shows with Call back + Add
//                a note -> a follow-up; brief GET p95.
//   38 booking   D sets the hours; B and C book the SAME slot at the same
//                moment -> exactly one wins; A books from the share link in
//                the app; D confirms; the reminder reaches A; A moves it; D
//                sees and re-confirms; A cancels in the app; D sees the whole
//                history; booking POST p95.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/screens/booking/booking_widgets.dart' show BkSlotPicker, BkBookingTile;
import 'package:assisto/screens/pa/pa_hub_screen.dart';

import '../support/harness.dart';

const _phoneB = '01700000002';
const _phoneC = String.fromEnvironment('REALITY_PHONE_C', defaultValue: '01711000777');
const _phoneD = '01700000004';
const _slug = 'flagproof-salon';
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
const _allWeek = {
  '0': [['09:00', '21:00']], '1': [['09:00', '21:00']], '2': [['09:00', '21:00']],
  '3': [['09:00', '21:00']], '4': [['09:00', '21:00']], '5': [['09:00', '21:00']],
  '6': [['09:00', '21:00']],
};

/// A second demo account from its own harness device id (a sign-in from the
/// app's device id would replace the app's session).
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

Future<Map<String, dynamic>> _post(RFlow f, ApiClient c, String path, Map<String, dynamic> body) =>
    f.net(() => c.postJsonRaw(path, body));

int _p95(List<int> ms) {
  final s = [...ms]..sort();
  return s[((s.length * 95 + 99) ~/ 100 - 1).clamp(0, s.length - 1)];
}

Future<void> _scrollDownTo(RFlow f, Finder target, String what) async {
  final list = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  for (var i = 0; i < 25 && target.evaluate().isEmpty; i++) {
    if (list.evaluate().isEmpty) break;
    await f.tester.drag(list.first, const Offset(0, -300), warnIfMissed: false);
    await f.tester.pump(const Duration(milliseconds: 350));
  }
  await f.waitFor(target, what: what);
}

Finder _keyPrefix(String p) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(p));

/// Today at hh:mm in the PHONE's clock, as the UTC ISO the API stores.
String _todayAt(int h, int m, {int addDays = 0}) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + addDays, h, m).toUtc().toIso8601String();
}

Future<void> _openBrief(RFlow f) async {
  try {
    await f.openFromDrawer(f.t.sidebarPersonalSecretary);
  } catch (e) {
    f.note('drawer path failed ($e); opened the hub directly');
    await f.backToHome();
    await f.pushScreen(const PaHubScreen());
  }
  await f.tap(find.text(f.t.psecTodayTitle).last, settleSeconds: 3);
  await f.waitFor(find.byKey(const ValueKey('ps-dictate')), what: "Today's brief");
}

void registerBizassistFlows() {
  // -------------------------------------------------------------- 37 brief
  realityFlow('37_ps_brief_real', 'Work',
      "PS brief: today's reminders + bill + calendar, Bangla dictation in Dhaka time, missed-call note",
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final d = await _login(f, _phoneD, 'reality-harness-d');
    final pill = 'Ammu medicine bz$_tag';
    final desco = 'Pay DESCO bill bz$_tag';
    final net = 'Link3 internet bz$_tag';
    final meet = 'Supplier meeting bz$_tag';
    final off = DateTime.now().timeZoneOffset;
    f.note('phone clock UTC${off.isNegative ? '' : '+'}${off.inMinutes / 60}'
        '${off.inMinutes == 360 ? ' (Asia/Dhaka)' : ' (NOT Dhaka: -timezone was ignored)'}');

    await f.step('real rows exist: 2 reminders (one repeats daily), a subscription, a meeting', () async {
      await f.net(() => api.createItem('reminders', {
            'title': desco, 'notes': '', 'due_at': _todayAt(23, 50), 'recurrence': 'none',
            'recurrence_rule': <String, dynamic>{}, 'date_only': false, 'done': false}));
      await f.net(() => api.createItem('reminders', {
            'title': pill, 'notes': '', 'due_at': _todayAt(23, 40, addDays: -3), 'recurrence': 'daily',
            'recurrence_rule': {'freq': 'daily', 'interval': 1}, 'date_only': false, 'done': false}));
      final n = DateTime.now();
      final tmr = DateTime(n.year, n.month, n.day + 1);
      await f.net(() => api.createItem('subscriptions', {
            'name': net, 'amount': '1200', 'cycle': 'monthly',
            'next_due': '${tmr.year}-${'${tmr.month}'.padLeft(2, '0')}-${'${tmr.day}'.padLeft(2, '0')}'}));
      await f.net(() => api.createItem('pa_schedule', {
            'title': meet, 'start': DateTime(n.year, n.month, n.day, 23, 30).toIso8601String(),
            'duration_min': 20}));
      f.note('rows made through the same APIs the Reminders / Subscriptions / Schedule screens use');
    });

    await f.step('D (second account) calls A on My Circle and hangs up before A answers', () async {
      final m = await f.net(() => d.getJson('/circle/members'));
      final rows = ((m['results'] ?? m['members'] ?? const []) as List).cast<Map>();
      final edge = rows.firstWhere((r) => '${r['name']}'.contains('Rahim'),
          orElse: () => throw TestFailure('D has no circle edge to A: $rows'));
      final call = await _post(f, d, '/circle/${edge['id']}/call', {'kind': 'voice'});
      final id = call['call_id'];
      if (id == null) throw TestFailure('call not placed: $call');
      await f.tester.pump(const Duration(seconds: 2));
      await _post(f, d, '/circle/calls/$id/event', {'event': 'cancel'});
      await f.tester.pump(const Duration(seconds: 3));
      await f.backToHome(); // any incoming-call screen is gone after the cancel
    });

    await f.step("open Personal Secretary -> Today's brief: every real row is there", () async {
      await _openBrief(f);
      f.expectHttp('GET', '/ps/today');
      await f.shot('brief-top');
      for (final s in [meet, desco, pill, net]) {
        await _scrollDownTo(f, find.textContaining(s), '"$s" on the brief');
      }
      await f.shot('brief-rows');
      final b = await f.net(() => api.getJson('/ps/today?tz=${off.inMinutes}'));
      final keys = (b['sections'] as List).map((s) => '${(s as Map)['key']}').toList();
      for (final k in ['meetings', 'reminders', 'bills', 'missed_calls']) {
        if (!keys.contains(k)) throw TestFailure('server brief has no "$k" section: $keys');
      }
      f.note('server sections: ${keys.join(',')}');
    });

    await f.step('missed call from D: Call back + Add a note -> a follow-up for tomorrow 11 am', () async {
      final note = _keyPrefix('ps-missednote-');
      await _scrollDownTo(f, note, 'the missed-call line');
      if (_keyPrefix('ps-callback-').evaluate().isEmpty) {
        throw TestFailure('no "Call back" button on the missed-call line');
      }
      await f.shot('missed-call');
      await f.tap(note.first, settleSeconds: 2);
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-msg')),
          'Call Selim back about the haircut booking tomorrow at 11am');
      await f.tap(find.byKey(const ValueKey('ps-pickup-find')), settleSeconds: 1);
      await f.tap(find.byKey(const ValueKey('ps-kind-followup')), settleSeconds: 1);
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-title')), 'Call Selim back bz$_tag');
      await f.tester.enterText(find.byKey(const ValueKey('ps-pickup-who')), 'Reality Selim');
      await f.tester.pump(const Duration(milliseconds: 400));
      await f.shot('missed-note');
      await f.tap(find.byKey(const ValueKey('ps-pickup-add')), settleSeconds: 3);
      await f.eventually('the follow-up is saved for tomorrow 11:00 phone time', () async {
        final rows = await api.listItems('pa/followups');
        final row = rows.where((r) => '${r['title']}'.contains('Call Selim back bz$_tag')).toList();
        if (row.isEmpty) return false;
        final due = DateTime.tryParse('${row.first['due_at']}')?.toLocal();
        final n = DateTime.now();
        return due != null && due.day == DateTime(n.year, n.month, n.day + 1).day && due.hour == 11;
      });
    });

    await f.step('dictate a task in Bangla -> reminder at tomorrow 10:00 (Dhaka)', () async {
      final bar = find.descendant(of: find.byKey(const ValueKey('ps-dictate')), matching: find.byType(TextField));
      await _scrollUpTo(f, bar);
      // what the phone's speech-to-text writes for the spoken sentence
      await f.tester.enterText(bar, 'কাল সকাল ১০টায় করিম ভাইকে ফোন করতে হবে $_tag');
      await f.tester.pump(const Duration(milliseconds: 600));
      await f.shot('dictate-preview');
      await f.tap(find.descendant(of: find.byKey(const ValueKey('ps-dictate')), matching: find.byType(FilledButton)),
          settleSeconds: 3);
      // the exact-alarm explainer may open once; it is not part of this proof
      if (find.byType(AlertDialog).evaluate().isNotEmpty) await f.back();
      await f.eventually('the server holds the reminder at tomorrow 10:00 phone time', () async {
        final rows = await api.listItems('reminders');
        final row = rows.where((r) => '${r['title']}'.contains('$_tag') && '${r['title']}'.contains('করিম')).toList();
        if (row.isEmpty) return false;
        final due = DateTime.parse('${row.first['due_at']}');
        final n = DateTime.now();
        final want = DateTime(n.year, n.month, n.day + 1, 10);
        if (!due.toLocal().isAtSameMomentAs(want)) {
          throw TestFailure('due ${due.toUtc()} != tomorrow 10:00 local ${want.toUtc()}');
        }
        if (off.inMinutes == 360 && due.toUtc().hour != 4) {
          throw TestFailure('not 10:00 Dhaka (04:00 UTC): ${due.toUtc()}');
        }
        return true;
      }, seconds: 30);
      await f.shot('dictated');
    });

    await f.step('speed: brief GET p95 over 20 loads', () async {
      final ms = <int>[];
      for (var i = 0; i < 20; i++) {
        final sw = Stopwatch()..start();
        await f.net(() => api.getJson('/ps/today?tz=${off.inMinutes}'));
        ms.add(sw.elapsedMilliseconds);
      }
      f.note('brief GET p50=${([...ms]..sort())[9]}ms p95=${_p95(ms)}ms (emulator->runner)');
      if (_p95(ms) > 1500) throw TestFailure('brief p95 ${_p95(ms)} ms > 1500 ms');
    });
  });

  // -------------------------------------------------------------- 38 booking
  realityFlow('38_booking_race_full', 'Business',
      'Booking: shop sets hours; 2 customers race for one slot; A books via link; reminder; move; cancel; shop sees all',
      (f) async {
    await f.home();
    final a = await f.h.backend();
    final b = await _login(f, _phoneB, 'reality-harness-b');
    final c = await _login(f, _phoneC, 'reality-harness-c');
    final d = await _login(f, _phoneD, 'reality-harness-d');
    late int svc;
    late String raceStart;
    final bookMs = <int>[];
    int? bid;

    await f.step('D (shop) sets the week hours + capacity 1; the share link shows Haircut', () async {
      final r = await _post(f, d, '/booking/biz', {
        'weekly_hours': _allWeek, 'capacity': 1, 'auto_confirm': false, 'slug': _slug,
        'enabled': true, 'cancel_hours': 2, 'min_notice_min': 60});
      if (r['_status'] != 200) throw TestFailure('hours not saved: $r');
      final p = await f.net(() => b.getJson('/booking/p/$_slug'));
      svc = (((p['services'] as List).first as Map)['id'] as num).toInt();
    });

    await f.step('B and C press Confirm for the SAME slot at the same moment -> exactly one booking', () async {
      final n = DateTime.now();
      final day = DateTime(n.year, n.month, n.day + 4);
      final ds = '${day.year}-${'${day.month}'.padLeft(2, '0')}-${'${day.day}'.padLeft(2, '0')}';
      final s = await f.net(() => b.getJson('/booking/p/$_slug/slots?service=$svc&day=$ds'));
      raceStart = '${((s['slots'] as List).first as Map)['start']}';
      final both = await f.net(() => Future.wait([
            b.postJsonRaw('/booking/p/$_slug/book', {'service': svc, 'start': raceStart}),
            c.postJsonRaw('/booking/p/$_slug/book', {'service': svc, 'start': raceStart}),
          ]));
      final codes = both.map((r) => r['_status']).toList()..sort((x, y) => '$x'.compareTo('$y'));
      f.note('race at $raceStart -> HTTP ${codes.join(' + ')}');
      if (!(codes.contains(201) && codes.contains(409))) {
        throw TestFailure('expected one 201 + one 409, got $both');
      }
      final lost = both.firstWhere((r) => r['_status'] == 409);
      if ('${lost['error']}' != 'slot_taken') throw TestFailure('loser error: $lost');
      final list = await f.net(() => d.getJson('/booking/biz/bookings?scope=upcoming'));
      final at = (list['bookings'] as List).where((x) => '${(x as Map)['start']}' == raceStart).toList();
      if (at.length != 1) throw TestFailure('shop sees ${at.length} bookings at the raced slot: $at');
      // the winner frees the slot again
      final won = both.firstWhere((r) => r['_status'] == 201);
      final cli = identical(won, both[0]) ? b : c;
      await _post(f, cli, '/booking/mine/${won['id']}/action', {'action': 'cancelled'});
    });

    // 3 each: the per-phone daily cap (5) and the per-IP hourly cap (10) stay honest
    await f.step('speed: B and C book + cancel 3 times each (booking POST p95)', () async {
      final n = DateTime.now();
      final day = DateTime(n.year, n.month, n.day + 5);
      final ds = '${day.year}-${'${day.month}'.padLeft(2, '0')}-${'${day.day}'.padLeft(2, '0')}';
      final s = await f.net(() => b.getJson('/booking/p/$_slug/slots?service=$svc&day=$ds'));
      final starts = (s['slots'] as List).map((x) => '${(x as Map)['start']}').toList();
      for (var i = 0; i < 6; i++) {
        final who = i.isEven ? b : c;
        final sw = Stopwatch()..start();
        final r = await f.net(() => who.postJsonRaw('/booking/p/$_slug/book', {'service': svc, 'start': starts[i]}));
        bookMs.add(sw.elapsedMilliseconds);
        if (r['_status'] != 201) throw TestFailure('booking ${i + 1} failed: $r');
        await _post(f, who, '/booking/mine/${r['id']}/action', {'action': 'cancelled'});
      }
      f.note('booking POST p50=${([...bookMs]..sort())[2]}ms p95=${_p95(bookMs)}ms');
      if (_p95(bookMs) > 2000) throw TestFailure('booking p95 ${_p95(bookMs)} ms > 2000 ms');
    });

    await f.step('A opens the share link in the app, picks a free time and confirms', () async {
      await f.openFeature(f.t.bkgSidebarMine, 'my_bookings');
      await f.tap(find.widgetWithText(FloatingActionButton, f.t.bkgBookNew), settleSeconds: 2);
      await f.enter('lifeassisto.com/b/$_slug', label: f.t.bkgLinkLabel);
      await f.tap(find.widgetWithText(FilledButton, f.t.bkgOpenLink), settleSeconds: 3);
      await f.waitFor(find.text('Haircut'), what: "the salon's service");
      final picker = find.byType(BkSlotPicker);
      await _scrollDownTo(f, picker, 'the time picker');
      final days = find.descendant(
          of: find.descendant(of: picker, matching: find.byType(ListView)), matching: find.byType(ChoiceChip));
      await f.tap(days.at(2), settleSeconds: 3);
      final times = find.descendant(
          of: find.descendant(of: picker, matching: find.byType(Wrap)), matching: find.byType(ChoiceChip));
      await f.waitFor(times, seconds: 15, what: 'free times');
      await f.tap(times.first, settleSeconds: 1);
      final confirm = find.widgetWithText(FilledButton, f.t.bkgConfirmBooking);
      await _scrollDownTo(f, confirm, 'Confirm booking');
      await f.tester.ensureVisible(confirm);
      await f.shot('a-picked');
      await f.tap(confirm, settleSeconds: 4);
      await f.waitFor(find.text(f.t.bkgRequestedTitle), what: '"request sent" page');
      await f.shot('a-requested');
    });

    await f.step('D sees the request and confirms; the reminder sweep reaches A', () async {
      await f.eventually("D sees A's request", () async {
        final r = await d.getJson('/booking/biz/bookings?scope=upcoming');
        final rows = (r['bookings'] as List).cast<Map>()
            .where((x) => x['status'] == 'requested' && '${x['customer_name']}'.contains('Rahim')).toList();
        if (rows.isEmpty) return false;
        bid = (rows.first['id'] as num).toInt();
        return true;
      });
      final r = await _post(f, d, '/booking/biz/bookings/$bid/action', {'action': 'confirmed'});
      if (r['status'] != 'confirmed') throw TestFailure('confirm failed: $r');
      await f.eventually('A got the booking reminder (notification centre)', () async {
        final feed = await a.getJson('/notif/feed');
        final s = '${feed['items']}';
        return s.contains('Flagproof Salon') && s.contains('STOP');
      }, seconds: 90);
      f.note('reminder = the real send_due_reminders path, swept as if 23 h 55 min before (CI time travel)');
    });

    await f.step('A moves the booking (customer API); D sees the new time and re-confirms', () async {
      final mine = await f.net(() => a.getJson('/booking/mine'));
      final row = (mine['upcoming'] as List).cast<Map>().firstWhere((x) => x['id'] == bid);
      final old = '${row['start']}';
      final day = DateTime.parse(old).add(const Duration(days: 1));
      final ds = '${day.year}-${'${day.month}'.padLeft(2, '0')}-${'${day.day}'.padLeft(2, '0')}';
      final s = await f.net(() => a.getJson('/booking/mine/$bid/slots?day=$ds'));
      final to = '${((s['slots'] as List).first as Map)['start']}';
      final r = await _post(f, a, '/booking/mine/$bid/action', {'action': 'reschedule', 'start': to});
      if (r['_status'] != 200) throw TestFailure('move failed: $r');
      final seen = await f.net(() => d.getJson('/booking/biz/bookings/$bid'));
      final st = seen['start'] ?? (seen['booking'] as Map?)?['start'];
      if ('$st' != to) throw TestFailure('shop sees $st, wanted $to');
      final c2 = await _post(f, d, '/booking/biz/bookings/$bid/action', {'action': 'confirmed'});
      if (c2['status'] != 'confirmed') throw TestFailure('re-confirm failed: $c2');
    });

    await f.step('A cancels in the app; D sees cancelled + the whole history', () async {
      await f.backToHome();
      await f.openFeature(f.t.bkgSidebarMine, 'my_bookings');
      final tile = find.byType(BkBookingTile);
      await f.waitFor(tile, what: 'the booking in My bookings');
      await f.shot('a-my-bookings');
      await f.tap(tile.first, settleSeconds: 2);
      final cancel = find.text(f.t.bkgCancelBooking);
      await f.waitFor(cancel, what: 'Cancel booking');
      await f.shot('a-booking-sheet');
      await f.tap(cancel, settleSeconds: 3);
      await f.eventually('the shop sees the booking cancelled with its history', () async {
        final r = await d.getJson('/booking/biz/bookings/$bid');
        final h = '${r['history'] ?? (r['booking'] as Map?)?['history']}';
        final st = '${r['status'] ?? (r['booking'] as Map?)?['status']}';
        return st == 'cancelled' && h.contains('rescheduled') && h.contains('reminder') &&
            h.contains('confirmed');
      });
      await f.shot('a-cancelled');
    });
  });
}

/// Drag the list down (towards the top) until [target] is on screen.
Future<void> _scrollUpTo(RFlow f, Finder target) async {
  final list = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  for (var i = 0; i < 25 && target.hitTestable().evaluate().isEmpty; i++) {
    if (list.evaluate().isEmpty) break;
    await f.tester.drag(list.first, const Offset(0, 300), warnIfMissed: false);
    await f.tester.pump(const Duration(milliseconds: 350));
  }
  await f.waitFor(target, what: 'the dictation bar');
}
