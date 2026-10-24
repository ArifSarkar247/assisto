// f6 — NO SHOWPIECES (owner order 6 part F). Proves each "wake up" fix:
// the features made real really do their job, and the hidden ones are not
// reachable from the sidebar / chat routes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_gates.dart';
import 'package:assisto/messaging/broadcast_send.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/agent_studio_screen.dart';
import 'package:assisto/screens/area_community_screen.dart';
import 'package:assisto/screens/fall_detect_screen.dart';
import 'package:assisto/screens/exam_result_screen.dart' show examReminderId;
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/probashi_reminders.dart';
import 'package:assisto/widgets/ramadan_alarms.dart';
import 'package:assisto/widgets/sidebar_sections.dart';
import 'package:assisto/widgets/watch_hide_store.dart';

import 'package:assisto/api.dart';

class _RecApi extends ApiClient {
  final posts = <String, Map<String, dynamic>>{};
  _RecApi() {
    token = 'test';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      path.startsWith('/circle/keys/peer/') ? {'public_key': ''} : {};
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts[path] = body;
    return {'id': 99};
  }
}

class _MemStore implements OutboxStore {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<List<Map<String, dynamic>>> load() async => rows;
  @override
  Future<void> save(List<Map<String, dynamic>> r) async => rows = r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hidden entry points (feature_gates.dart)', () {
    test('gates that hide showpieces are off', () {
      expect(kAgentStudioRunsAutomations, isFalse);
      expect(kAreaBoardShared, isFalse);
      expect(kInAppSoundBuilt, isFalse);
      expect(kCommunityAlertsBuilt, isFalse);
      expect(kJobsFeedConnected, isFalse);
      expect(kShowSampleDisasterWarnings, isFalse);
      expect(kMsgrChatBackupWired, isFalse);
      expect(kLostActionSwitchesWired, isFalse);
      expect(kSourcePermissionsEnforced, isFalse);
      expect(FallDetectScreen.engineShipped, isFalse);
    });

    testWidgets('sidebar has no Agent Studio / Area board / Fall detect',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      final ctx = tester.element(find.byType(SizedBox));
      final screens = [
        for (final s in SidebarSections.all)
          for (final i in s.items) i.builder(ctx).runtimeType
      ];
      expect(screens, isNot(contains(AgentStudioScreen)));
      expect(screens, isNot(contains(AreaCommunityScreen)));
      expect(screens, isNot(contains(FallDetectScreen)));
      expect(ChatNav.routes.containsKey('agent_studio'), isFalse);
    });
  });

  group('Probashi document reminders (were "not wired yet")', () {
    test('plans 30-days-before and expiry-day, future only', () {
      final now = DateTime(2026, 10, 24, 12);
      final plan = ProbashiReminders.plan([
        {'id': 1, 'kind': 'passport', 'expiry': '2027-01-10'},
        {'id': 2, 'kind': 'visa', 'expiry': '2026-11-10'}, // -30d is past
        {'id': 3, 'kind': 'ticket', 'expiry': ''}, // undated
        {'id': 4, 'kind': 'other', 'expiry': '2026-01-01'}, // expired
      ], now);
      final ids = plan.map((r) => r.localId).toList();
      expect(ids, ['probashi-doc-1-30', 'probashi-doc-1-0', 'probashi-doc-2-0']);
      expect(plan.first.when, DateTime(2026, 12, 11, 9));
      expect(plan[1].when, DateTime(2027, 1, 10, 9));
    });

    test('sync cancels old slots, then schedules with title + body',
        () async {
      final scheduled = <String>[];
      final cancelled = <String>[];
      await ProbashiReminders.sync(
        [
          {'id': 7, 'kind': 'passport', 'label': 'My passport', 'expiry': '2027-03-01'}
        ],
        title: (d) => '${d['label']}',
        body: (onDay) => onDay ? 'today' : 'in30',
        now: DateTime(2026, 10, 24),
        schedule: (id, t, b, w) async => scheduled.add('$id|$t|$b'),
        cancel: (id) async => cancelled.add(id),
      );
      expect(cancelled, ['probashi-doc-7-30', 'probashi-doc-7-0']);
      expect(scheduled, [
        'probashi-doc-7-30|My passport|in30',
        'probashi-doc-7-0|My passport|today',
      ]);
    });
  });

  group('Ramadan alarms (sliders used to save nothing)', () {
    test('plan: only switched-on alarms, minus the offset, today+tomorrow',
        () {
      final now = DateTime(2026, 3, 1, 3, 0);
      final plan = RamadanAlarms.plan(
          sehriEnd: '04:50',
          iftar: '18:05',
          prefs: const RamadanAlarmPrefs(
              sehriOn: true, sehriMin: 60, iftarOn: false),
          now: now);
      expect(plan.map((a) => a.localId), ['ramadan-sehri-0', 'ramadan-sehri-1']);
      expect(plan.first.when, DateTime(2026, 3, 1, 3, 50));
    });

    test('prefs persist on the phone', () async {
      SharedPreferences.setMockInitialValues({});
      await RamadanAlarms.save(const RamadanAlarmPrefs(
          sehriOn: true, sehriMin: 40, iftarOn: true, iftarMin: 20));
      final p = await RamadanAlarms.load();
      expect([p.sehriOn, p.sehriMin, p.iftarOn, p.iftarMin], [true, 40, true, 20]);
    });

    test('sync with both off cancels every slot and schedules none',
        () async {
      final cancelled = <String>[];
      final n = await RamadanAlarms.sync(
          sehriEnd: '04:50',
          iftar: '18:05',
          prefs: const RamadanAlarmPrefs(),
          sehriTitle: 's',
          iftarTitle: 'i',
          now: DateTime(2026, 3, 1),
          schedule: (a, b, c, d) async => fail('nothing should be scheduled'),
          cancel: (id) async => cancelled.add(id));
      expect(n, 0);
      expect(cancelled, RamadanAlarms.ids);
    });
  });

  group('Watch feed snooze / dismiss survive a reopen', () {
    test('snooze hides until tomorrow; dismiss 30 days; expired dropped',
        () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime(2026, 10, 24, 15);
      await WatchHideStore.hide('rem:1', WatchHideStore.snoozeUntil(now));
      await WatchHideStore.hide('alert:2', WatchHideStore.dismissUntil(now));
      expect(await WatchHideStore.load(now: now), {'rem:1', 'alert:2'});
      // next day: the snoozed one is back, the dismissed one stays hidden
      expect(await WatchHideStore.load(now: DateTime(2026, 10, 25, 0, 1)),
          {'alert:2'});
      final p = await SharedPreferences.getInstance();
      expect((jsonDecode(p.getString('watch_feed_hidden_v1')!) as Map).keys,
          ['alert:2']);
    });
  });

  test('exam reminder id is stable per watcher', () {
    final d = DateTime(2027, 2, 1);
    expect(examReminderId('https://x', d), examReminderId('https://x', d));
    expect(examReminderId('https://x', d).startsWith('exam-2027-2-1-'), isTrue);
  });

  group('Broadcast really sends (was: no sender -> always failed)', () {
    test('seals per recipient, posts 1:1, queues keyless in the outbox',
        () async {
      final e2e = SoftwareE2E();
      final me = e2e.generateIdentity();
      final peer = e2e.generateIdentity();
      final api = _RecApi();
      final posts = api.posts;
      final box = Outbox(store: _MemStore());
      final r = await sendBroadcastText(api, me, [11, 12], 'Eid Mubarak',
          members: [
            {'id': 11, 'name': 'A', 'public_key': base64Encode(peer.publicKey)},
            {'id': 12, 'name': 'B', 'public_key': ''},
          ],
          e2e: e2e,
          outbox: box);
      expect(r.sent, 1);
      expect(r.queued, 1);
      expect(r.failed, 0);
      final env = posts['/circle/11/messages']!;
      expect(env['content_type'], 'text');
      expect(env.containsKey('forwarded'), isFalse);
      expect(jsonEncode(env).contains('Eid Mubarak'), isFalse); // sealed
      final queued = await box.all();
      expect(queued.single.chatId, 12);
      expect(queued.single.text, 'Eid Mubarak');
    });
  });
}
