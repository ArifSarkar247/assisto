// agent-core WP-APP: the hidden Assisto Agent screen + approval cards + the
// `agent_approval` push (fake server, no network): cost shown BEFORE running,
// live run polling, result + sources, cancel, feedback, history, approval
// inbox, honest states (flag off / AI not set up / out of credits / offline /
// daily cap), push payload -> right screen, notification actions; bn digits,
// 48 dp, dark and 200% text with no overflow.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/agent_core/agent_approvals_screen.dart';
import 'package:assisto/screens/agent_core/agent_core_push.dart';
import 'package:assisto/screens/agent_core/agent_core_screen.dart';
import 'package:assisto/screens/agent_core/agent_core_widgets.dart';
import 'package:assisto/screens/agent_core/agent_history_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/feature_unavailable.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

import 'agent_core_fakes.dart';
import 'fake_api.dart';

AppState _state({bool online = true}) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  s.online = online;
  return s;
}

Widget _app(Widget home,
        {String lang = 'en', double scale = 1.0, bool dark = false, AppState? state}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state ?? _state(),
      child: MaterialApp(
        key: UniqueKey(),
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
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 1600}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

const _fast = [Duration(milliseconds: 100)];
late AppLocalizations en;
late AppLocalizations bn;

String? _runState(WidgetTester tester) {
  final f = find.byKey(const ValueKey('ac_run_state'));
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
}

Future<void> _typeAndEstimate(WidgetTester tester, String goal) async {
  await tester.enterText(find.byKey(const ValueKey('ac_goal_input')), goal);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('ac_check_cost')));
  await _settle(tester);
}

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.debugOverride = {'agent_core': true};
  });
  tearDown(() {
    FeatureFlags.instance.debugOverride = null;
    CreditsOut.debugOffer = null;
    AgentCorePush.debugCancel = null;
    AgentCorePush.debugRedraw = null;
  });

  group('agent screen', () {
    testWidgets('cost is shown BEFORE anything runs; Run sends once; result + sources + spent',
        (tester) async {
      _phone(tester);
      final src = FakeAgentCore('data');
      await tester.pumpWidget(_app(AgentCoreScreen(source: src, pollSchedule: _fast)));
      await _settle(tester);
      expect(find.text(en.acIntro), findsOneWidget);
      // "See the cost" is disabled until a goal is typed
      expect(
          tester.widget<FilledButton>(find.ancestor(
              of: find.text(en.acCheckCost), matching: find.byType(FilledButton))).onPressed,
          isNull);
      await _typeAndEstimate(tester, 'Where did I spend the most?');
      expect(find.byKey(const ValueKey('ac_estimate')), findsOneWidget);
      expect(find.text(en.acEstimateTypical('7')), findsOneWidget);
      expect(find.text(en.acEstimateMax('15')), findsOneWidget);
      expect(find.text(en.acEstimateRunsLeft('3')), findsOneWidget);
      expect(find.text(en.acRunConfirm('7')), findsOneWidget);
      expect(src.calls.where((c) => c.startsWith('goal:')), isEmpty); // nothing ran yet
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      final goals = src.calls.where((c) => c.startsWith('goal:')).toList();
      expect(goals.length, 1);
      expect(goals.single, startsWith('goal:Where did I spend the most?:ac-'));
      expect(_runState(tester), en.acStateDone);
      expect(find.byKey(const ValueKey('ac_answer')), findsOneWidget);
      expect(find.text(en.acSourcesTitle), findsOneWidget);
      expect(find.text('Month income/expense summary'), findsWidgets); // the source module
      expect(find.text(en.acSpent('7')), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_cancel')), findsNothing); // finished
      // feedback 👎 + note
      await tester.tap(find.byKey(const ValueKey('ac_fb_down')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('ac_fb_note')), 'too slow');
      await tester.tap(find.byKey(const ValueKey('ac_fb_send')));
      await _settle(tester);
      expect(src.calls, contains('feedback:5:-1:too slow'));
      expect(find.text(en.acFeedbackThanks), findsOneWidget);
      // new task resets
      await tester.ensureVisible(find.byKey(const ValueKey('ac_new_task')));
      await tester.tap(find.byKey(const ValueKey('ac_new_task')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_goal_input')), findsOneWidget);
    });

    testWidgets('Bangla: strict bn text and Bangla digits in the estimate', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
          _app(AgentCoreScreen(source: FakeAgentCore('data', bn: true)), lang: 'bn'));
      await _settle(tester);
      await _typeAndEstimate(tester, 'x');
      expect(find.text(bn.acEstimateTypical('৭')), findsOneWidget); // ৭
      expect(find.text(bn.acEstimateMax('১৫')), findsOneWidget); // ১৫
      expect(find.text(bn.acRunConfirm('৭')), findsOneWidget);
      expect(acDigits(2026, true), '২০২৬');
    });

    testWidgets('live run: polls while running, stops when done (no fake progress)',
        (tester) async {
      _phone(tester);
      final src = FakeAgentCore('slow');
      await tester.pumpWidget(_app(AgentCoreScreen(source: src, pollSchedule: _fast)));
      await _settle(tester);
      await _typeAndEstimate(tester, 'slow one');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await tester.pump();
      await tester.pump();
      expect(_runState(tester), en.acStateRunning);
      expect(find.byKey(const ValueKey('ac_cancel')), findsOneWidget);
      await _settle(tester, 12);
      expect(_runState(tester), en.acStateDone);
      final n = src.polls;
      await _settle(tester, 12);
      expect(src.polls, n); // polling stopped
    });

    testWidgets('cancel a working run', (tester) async {
      _phone(tester);
      final src = FakeAgentCore('slow');
      await tester.pumpWidget(_app(AgentCoreScreen(
          source: src,
          debugPhase: AcPhase.run,
          debugRun: null,
          pollSchedule: const [Duration(seconds: 30)])));
      await _settle(tester);
      // start one for real
      await tester.tap(find.byKey(const ValueKey('ac_new_task')));
      await _settle(tester);
      await _typeAndEstimate(tester, 'c');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('ac_cancel')));
      await _settle(tester);
      expect(src.calls, contains('cancel:5'));
      expect(_runState(tester), en.acStateCancelled);
    });

    testWidgets('AI not set up: the honest state from the router', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('no_ai'))));
      await _settle(tester);
      await _typeAndEstimate(tester, 'g');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_no_ai')), findsOneWidget);
      expect(find.text(en.acNotSetUpTitle), findsOneWidget);
      expect(find.text('The agent is not switched on yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_answer')), findsNothing);
    });

    testWidgets('out of credits opens the billing sheet; bought -> back to the cost step',
        (tester) async {
      _phone(tester);
      var opened = '';
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        opened = screen;
        return true;
      };
      await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('credits'))));
      await _settle(tester);
      await _typeAndEstimate(tester, 'g2');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.text(en.acOutOfCreditsTitle), findsOneWidget);
      await tester.tap(find.text(en.acBuyCredits));
      await _settle(tester);
      expect(opened, 'agent_core');
      expect(find.byKey(const ValueKey('ac_estimate')), findsOneWidget);
    });

    testWidgets('offline: not started, nothing sent; back online -> sent exactly once',
        (tester) async {
      _phone(tester);
      final st = _state(online: false);
      final src = FakeAgentCore('data');
      await tester.pumpWidget(_app(AgentCoreScreen(source: src), state: st));
      await _settle(tester);
      await _typeAndEstimate(tester, 'later');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_offline_queued')), findsOneWidget);
      expect(find.text(en.acOfflineQueued), findsOneWidget);
      expect(src.calls.where((c) => c.startsWith('goal:')), isEmpty);
      st.online = true;
      st.notifyListeners(); // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      await _settle(tester);
      expect(src.calls.where((c) => c.startsWith('goal:')).length, 1);
      expect(_runState(tester), en.acStateDone);
    });

    testWidgets('no answer from the server = not started (offline card, Send now)',
        (tester) async {
      _phone(tester);
      final src = FakeAgentCore('offline');
      await tester.pumpWidget(_app(AgentCoreScreen(source: src)));
      await _settle(tester);
      await _typeAndEstimate(tester, 'x');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_offline_queued')), findsOneWidget);
      expect(find.text(en.acStateRunning), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ac_send_now')));
      await _settle(tester);
      // the retry re-uses the same client_id (server dedupes)
      final ids = src.calls
          .where((c) => c.startsWith('goal:'))
          .map((c) => c.split(':').last)
          .toSet();
      expect(ids.length, 1);
    });

    testWidgets('daily cap: server text, stays on the cost step; 0 runs left disables Run',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('cap'))));
      await _settle(tester);
      await _typeAndEstimate(tester, 'x');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_send_error')), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_estimate')), findsOneWidget);

      await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('data', left: 0))));
      await _settle(tester);
      await _typeAndEstimate(tester, 'x');
      expect(find.text(en.acDailyCap), findsOneWidget);
      expect(
          tester.widget<FilledButton>(find.ancestor(
              of: find.text(en.acRunConfirm('7')), matching: find.byType(FilledButton))).onPressed,
          isNull);
    });

    testWidgets('flag off on the server: feature-off notice, never a fake screen',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('off'))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_feature_off')), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_goal_input')), findsNothing);
    });

    testWidgets('a step that needs approval: card in the run, approve -> run continues',
        (tester) async {
      _phone(tester, height: 2200);
      final src = FakeAgentCore('approval');
      await tester.pumpWidget(_app(AgentCoreScreen(source: src, pollSchedule: _fast)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_approvals_banner')), findsOneWidget);
      await _typeAndEstimate(tester, 'delete old list');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(_runState(tester), en.acStateWaiting);
      expect(find.text("Delete note: 'Grocery list'?"), findsOneWidget);
      expect(find.text(en.acApCostFree), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ac_approve_11')));
      await _settle(tester);
      expect(src.calls, contains('decide:11:approve'));
      expect(_runState(tester), en.acStateDone);
    });

    testWidgets('step semantics for TalkBack', (tester) async {
      _phone(tester);
      final h = tester.ensureSemantics();
      await tester.pumpWidget(_app(AgentCoreScreen(
          source: FakeAgentCore('data'),
          debugPhase: AcPhase.run,
          debugRun: null)));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('ac_new_task')));
      await _settle(tester);
      await _typeAndEstimate(tester, 'x');
      await tester.tap(find.byKey(const ValueKey('ac_run')));
      await _settle(tester);
      expect(find.bySemanticsLabel(en.acSemStep('2', 'Month income/expense summary', en.acStepStDone)),
          findsOneWidget);
      h.dispose();
    });
  });

  group('approval inbox', () {
    testWidgets('lists cards with what / to whom (partly hidden) / cost / expiry; reject',
        (tester) async {
      _phone(tester, height: 2200);
      var cancelled = <int>[];
      AgentCorePush.debugCancel = (id) async => cancelled.add(id);
      final src = FakeAgentCore('approval');
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: src)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_approval_11')), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_approval_12')), findsOneWidget);
      expect(find.text('to: 017•••••678'), findsOneWidget);
      expect(find.text(en.acApMaskedNote), findsOneWidget);
      expect(find.text(en.acApCost('1')), findsOneWidget);
      expect(find.text(en.acRiskExternal), findsOneWidget);
      expect(find.text(en.acRiskDelete), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ac_reject_12')));
      await _settle(tester);
      expect(src.calls, contains('decide:12:reject'));
      expect(find.byKey(const ValueKey('ac_decided_12')), findsOneWidget);
      expect(cancelled, [PushPayload({'kind': 'agent_approval', 'approval_id': '12'}).notificationId]);
    });

    testWidgets('expired approval cannot be approved', (tester) async {
      _phone(tester, height: 2600);
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: FakeAgentCore('expired'))));
      await _settle(tester);
      expect(find.text(en.acApExpired), findsOneWidget);
      final b = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('ac_approve_13')));
      expect(b.onPressed, isNull);
    });

    testWidgets('from the notification Approve action: focused card says confirm here',
        (tester) async {
      _phone(tester, height: 2200);
      final src = FakeAgentCore('approval');
      await tester.pumpWidget(
          _app(AgentApprovalsScreen(source: src, focusId: 12, fromApproveAction: true)));
      await _settle(tester);
      expect(find.text(en.acApFromNotif), findsOneWidget);
      expect(src.calls.where((c) => c.startsWith('decide')), isEmpty); // never blind
      // focused card first
      final y12 = tester.getTopLeft(find.byKey(const ValueKey('ac_approval_12'))).dy;
      final y11 = tester.getTopLeft(find.byKey(const ValueKey('ac_approval_11'))).dy;
      expect(y12 < y11, isTrue);
    });

    testWidgets('empty + error states', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: FakeAgentCore('empty'))));
      await _settle(tester);
      expect(find.text(en.acApprovalsEmpty), findsOneWidget);
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: FakeAgentCore('fail'))));
      await _settle(tester);
      expect(find.text(en.acRetry), findsOneWidget);
    });

    testWidgets('a foreground agent_approval push reloads the open inbox', (tester) async {
      _phone(tester);
      final src = FakeAgentCore('approval');
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: src)));
      await _settle(tester);
      final n = src.calls.where((c) => c == 'approvals').length;
      AgentCorePush.onForegroundPush(PushPayload({'kind': 'agent_approval', 'approval_id': '9'}));
      await _settle(tester);
      expect(src.calls.where((c) => c == 'approvals').length, n + 1);
    });
  });

  group('history', () {
    testWidgets('lists runs; tap opens the run detail', (tester) async {
      _phone(tester);
      final src = FakeAgentCore('data');
      await tester.pumpWidget(_app(AgentHistoryScreen(source: src)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ac_hist_5')), findsOneWidget);
      expect(find.byKey(const ValueKey('ac_hist_3')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ac_hist_5')));
      await _settle(tester, 20);
      expect(src.calls, contains('run:5'));
      expect(find.byKey(const ValueKey('ac_answer')), findsOneWidget);
    });

    testWidgets('empty history', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(AgentHistoryScreen(source: FakeAgentCore('empty'))));
      await _settle(tester);
      expect(find.text(en.acHistoryEmpty), findsOneWidget);
    });
  });

  group('push agent_approval', () {
    final p = PushPayload.fromData({
      'kind': 'agent_approval',
      'approval_id': '12',
      'run_id': '5',
      'risk': 'external',
      'route': 'agent/approval',
      'title': 'Approval needed',
      'body': 'The Assisto agent wants to send something for you: Send a message',
      'lang': 'en',
      'channel': 'alerts',
      'sent_at': '1',
    });

    test('known kind on the alerts channel, one stable id per approval', () {
      expect(p.isKnownKind, isTrue);
      expect(p.isAgentApproval, isTrue);
      expect(p.channel, PushChannels.alerts);
      expect(p.notificationId,
          PushPayload({'kind': 'agent_approval', 'approval_id': '12', 'sent_at': '99'}).notificationId);
      expect(AgentCorePush.approvalId(p), 12);
    });

    test('tap routes to the approval inbox', () {
      expect(PushRouting.targetFor(p)?.chatNavRoute, 'agent_approvals');
      final noRoute = PushPayload({'kind': 'agent_approval', 'approval_id': '3'});
      expect(PushRouting.targetFor(noRoute)?.chatNavRoute, 'agent_approvals');
    });

    testWidgets('Approve action opens THAT card (flag on), never approves by itself',
        (tester) async {
      final b = AgentCorePush.builderFor(p, action: AgentCorePush.actionApprove);
      late Widget w;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        w = b(ctx);
        return const SizedBox();
      })));
      expect(w, isA<AgentApprovalsScreen>());
      final s = w as AgentApprovalsScreen;
      expect(s.focusId, 12);
      expect(s.fromApproveAction, isTrue);
      final tap = AgentCorePush.builderFor(p);
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        w = tap(ctx);
        return const SizedBox();
      })));
      expect((w as AgentApprovalsScreen).fromApproveAction, isFalse);
    });

    testWidgets('flag off: the push opens the "not available" notice', (tester) async {
      FeatureFlags.instance.debugOverride = {'agent_core': false};
      final b = AgentCorePush.builderFor(p, action: AgentCorePush.actionApprove);
      late Widget w;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        w = b(ctx);
        return const SizedBox();
      })));
      expect(w, isA<FeatureUnavailableScreen>());
    });

    test('notification: private on the lock screen; Reject = no UI, Approve opens the app', () {
      final d = PushNotifier.detailsFor(p).android!;
      expect(d.visibility, NotificationVisibility.private);
      final acts = d.actions!;
      expect(acts.map((a) => a.id), [AgentCorePush.actionReject, AgentCorePush.actionApprove]);
      expect(acts[0].showsUserInterface, isFalse);
      expect(acts[0].title, en.acNotifReject);
      expect(acts[1].showsUserInterface, isTrue);
      expect(acts[1].title, en.acNotifApprove);
    });

    test('Reject action calls the API with the app token, then removes the notification',
        () async {
      final cancelled = <int>[];
      AgentCorePush.debugCancel = (id) async => cancelled.add(id);
      late http.Request seen;
      final client = MockClient((r) async {
        seen = r;
        return http.Response(jsonEncode({'approval': {'status': 'rejected'}}), 200);
      });
      final r = await AgentCorePush.rejectFromNotification(p, token: 'tok-1', client: client);
      expect(r, 'rejected');
      expect(seen.method, 'POST');
      expect(seen.url.path, endsWith('/agent-core/approvals/12'));
      expect(seen.headers['Authorization'], 'Token tok-1');
      expect(jsonDecode(seen.body), {'decision': 'reject'});
      expect(cancelled, [p.notificationId]);
    });

    test('Reject: already decided / not mine -> notification removed; server error -> '
        'redrawn as "could not reject" (no fake success)', () async {
      final cancelled = <int>[];
      final redrawn = <PushPayload>[];
      AgentCorePush.debugCancel = (id) async => cancelled.add(id);
      AgentCorePush.debugRedraw = (x) async => redrawn.add(x);
      expect(
          await AgentCorePush.rejectFromNotification(p,
              token: 't', client: MockClient((_) async => http.Response('{}', 404))),
          'gone');
      expect(cancelled.length, 1);
      expect(
          await AgentCorePush.rejectFromNotification(p,
              token: 't', client: MockClient((_) async => http.Response('{}', 500))),
          'failed');
      expect(redrawn.single.body, en.acNotifRejectFailed);
      expect(redrawn.single.data['approval_id'], '12');
      expect(cancelled.length, 1);
      // signed out: nothing is sent
      var sent = false;
      expect(
          await AgentCorePush.rejectFromNotification(p,
              token: '',
              client: MockClient((_) async {
                sent = true;
                return http.Response('{}', 200);
              })),
          'signed_out');
      expect(sent, isFalse);
    });
  });

  group('flag gating (home frozen: nothing visible while off)', () {
    test('routes + sidebar entry exist only with the flag', () {
      FeatureFlags.instance.debugOverride = {'agent_core': false};
      expect(ChatNav.routes.containsKey('agent_core'), isFalse);
      expect(ChatNav.routes.containsKey('agent_approvals'), isFalse);
      bool inSidebar() => SidebarSections.all
          .expand((s) => s.items)
          .any((i) => i.feature == 'agent_core');
      expect(inSidebar(), isFalse);
      FeatureFlags.instance.debugOverride = {'agent_core': true};
      expect(ChatNav.routes.containsKey('agent_core'), isTrue);
      expect(ChatNav.routes.containsKey('agent_approvals'), isTrue);
      expect(inSidebar(), isTrue);
    });
  });

  group('a11y: dark, bn, 200% text, 48 dp', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('no overflow at 200% ($lang, dark)', (tester) async {
        _phone(tester, height: 3200);
        await tester.pumpWidget(_app(
            AgentCoreScreen(source: FakeAgentCore('approval', bn: lang == 'bn'), pollSchedule: _fast),
            lang: lang,
            scale: 2.0,
            dark: true));
        await _settle(tester);
        await _typeAndEstimate(tester, 'x');
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('ac_run')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(_app(
            AgentApprovalsScreen(source: FakeAgentCore('approval', bn: lang == 'bn')),
            lang: lang,
            scale: 2.0,
            dark: true));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('tap targets >= 48 dp and labelled', (tester) async {
      _phone(tester, height: 2200);
      final h = tester.ensureSemantics();
      await tester.pumpWidget(_app(AgentApprovalsScreen(source: FakeAgentCore('approval'))));
      await _settle(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      h.dispose();
    });
  });
}
