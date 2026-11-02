// callsbar UI: the call screen's low-data chip + network & data sheet (a
// real switch), the audio-only-fallback badges, "this call used ~X MB", the
// one-tap rating row (good / bad -> what went wrong -> thanks), the honest
// group-call sheet (one-tap 1:1 call, no dead button), the missed-call
// notification's Call back / Message buttons and the low-data setting —
// bn + en, 360 px and 200 % text without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_data_prefs.dart';
import 'package:assisto/calls/call_rating.dart';
import 'package:assisto/calls/group_call_sheet.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

Widget app(Widget home, {String lang = 'en', double scale = 1}) => MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('call data amount', () {
    test('KB under 1 MB, one decimal under 10 MB', () {
      expect(callDataAmount(300), '1 KB');
      expect(callDataAmount(850 * 1024), '850 KB');
      expect(callDataAmount((1.42 * 1024 * 1024).round()), '1.4 MB');
      expect(callDataAmount(23 * 1024 * 1024), '23 MB');
    });
  });

  for (final lang in ['en', 'bn']) {
    final t = lookupAppLocalizations(Locale(lang));

    testWidgets('live call: low-data chip, my + their paused video ($lang)',
        (tester) async {
      phone(tester);
      final c = previewController(
          video: true, outgoing: true, phase: CallPhase.connected);
      c.lowData = true;
      c.remoteVideoPausedNet = true;
      c.netPolicy.videoPaused = true;
      await tester.pumpWidget(app(
          CircleCallScreen(
              member: const {'id': 7, 'name': 'Nadia'},
              kind: 'video',
              controller: c,
              surface: FakeSurface()),
          lang: lang));
      await tester.pump();
      expect(find.byKey(const Key('call-low-data-chip')), findsOneWidget);
      expect(find.text(t.cbarLowDataChip), findsOneWidget);
      expect(find.byKey(const Key('call-my-video-paused')), findsOneWidget);
      expect(find.text(t.cbarRemoteVideoPaused('Nadia')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tap the quality bars -> network & data sheet; the switch '
        'really changes the call + the saved setting ($lang)', (tester) async {
      phone(tester);
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.connected);
      c.dataBytes = 3 * 1024 * 1024;
      await tester.pumpWidget(app(
          CircleCallScreen(
              member: const {'id': 7, 'name': 'Nadia'},
              kind: 'voice',
              controller: c),
          lang: lang));
      await tester.pump();
      await tester.tap(find.byKey(const Key('call-net-button')));
      await tester.pumpAndSettle();
      expect(find.text(t.cbarNetSheetTitle), findsOneWidget);
      expect(find.text(t.cbarNetGood), findsOneWidget);
      expect(find.byKey(const Key('call-net-data')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-low-data-switch')));
      await tester.pumpAndSettle();
      expect(c.lowData, isTrue);
      expect(await CallDataPrefs.lowData(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('ended call: data used + rating good/bad/issue/thanks at 200% '
        'text ($lang)', (tester) async {
      phone(tester);
      final c = previewController(
          video: false,
          outgoing: true,
          phase: CallPhase.ended,
          reason: CallEndReason.hangup);
      c.connectedAt = DateTime(2026, 11, 2, 10, 0, 0);
      c.endedAt = DateTime(2026, 11, 2, 10, 4, 7);
      c.dataBytes = 900 * 1024;
      await tester.pumpWidget(app(
          CircleCallScreen(
              member: const {'id': 7, 'name': 'Nadia'},
              kind: 'voice',
              controller: c,
              previewAskRating: true),
          lang: lang,
          scale: 2));
      await tester.pump();
      expect(find.byKey(const Key('call-data-used')), findsOneWidget);
      expect(find.text(t.cbarRateAsk), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('call-rate-bad')));
      await tester.tap(find.byKey(const Key('call-rate-bad')));
      await tester.pump();
      expect(find.text(t.cbarRateWhat), findsOneWidget);
      expect(find.byKey(const Key('call-rate-issue-choppy')), findsOneWidget);
      expect(find.byKey(const Key('call-rate-issue-video')), findsNothing,
          reason: 'voice call: no video issue');
      await tester.ensureVisible(
          find.byKey(const Key('call-rate-issue-choppy')));
      await tester.tap(find.byKey(const Key('call-rate-issue-choppy')));
      await tester.pump();
      expect(find.text(t.cbarRateThanks), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2)); // auto-close timer
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('rating row sends exactly what was tapped', (tester) async {
    final sent = <(String, String?)>[];
    var done = 0;
    await tester.pumpWidget(app(Scaffold(
        backgroundColor: Colors.black,
        body: CallRatingRow(
            video: true,
            onSend: (r, i) async => sent.add((r, i)),
            onDone: () => done++))));
    await tester.tap(find.byKey(const Key('call-rate-good')));
    await tester.pump();
    expect(sent, [('good', null)]);
    expect(done, 1);
  });

  testWidgets('rating row: a failing send never throws', (tester) async {
    await tester.pumpWidget(app(Scaffold(
        body: CallRatingRow(onSend: (r, i) => throw StateError('offline')))));
    await tester.tap(find.byKey(const Key('call-rate-good')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('group call sheet', () {
    final members = <Map<String, dynamic>>[
      {'user_id': 1, 'name': 'Me', 'is_self': true, 'circle_member_id': null},
      {'user_id': 2, 'name': 'Babu', 'circle_member_id': 21},
      {'user_id': 3, 'name': 'Chaya', 'circle_member_id': null},
    ];

    for (final lang in ['en', 'bn']) {
      testWidgets('honest text + one-tap 1:1 call, not-in-circle listed '
          'without a dead button ($lang)', (tester) async {
        tester.view.physicalSize = const Size(360, 1600) * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final t = lookupAppLocalizations(Locale(lang));
        final calls = <(Map<String, dynamic>, String)>[];
        await tester.pumpWidget(app(
            Scaffold(
                body: GroupCallSheet(
                    members: members,
                    groupName: 'Family',
                    onCall: (m, k) => calls.add((m, k)))),
            lang: lang,
            scale: 2));
        await tester.pump();
        expect(find.text(t.cbarGroupHonest), findsOneWidget);
        expect(find.byKey(const Key('group-call-voice-2')), findsOneWidget);
        expect(find.byKey(const Key('group-call-voice-3')), findsNothing);
        expect(find.byKey(const Key('group-call-member-3')), findsOneWidget);
        expect(find.byKey(const Key('group-call-member-1')), findsNothing,
            reason: 'never call myself');
        await tester.ensureVisible(find.byKey(const Key('group-call-voice-2')));
        await tester.tap(find.byKey(const Key('group-call-voice-2')));
        await tester.pump();
        expect(calls.single.$1['id'], 21);
        expect(calls.single.$1['name'], 'Babu');
        expect(calls.single.$2, 'voice');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nobody callable -> empty-state how-to + back button',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      await tester.pumpWidget(app(Scaffold(
          body: GroupCallSheet(
              members: const [
                {'user_id': 3, 'name': 'Chaya', 'circle_member_id': null}
              ],
              groupName: 'Family',
              onCall: (_, __) {}))));
      await tester.pump();
      expect(find.text(t.cbarGroupNoneCallable), findsOneWidget);
      expect(find.byKey(const Key('group-call-close')), findsOneWidget);
    });
  });

  group('missed call notification', () {
    test('has Call back + Message when the caller is in my circle', () {
      final d = PushNotifier.detailsFor(PushPayload(const {
        'kind': 'missed_call',
        'call_id': '42',
        'chat_id': '21',
        'caller_name': 'Nadia',
        'lang': 'bn',
        'channel': 'missed_calls',
      }));
      final a = d.android!.actions!;
      expect(a.map((e) => e.id),
          [PushNotifier.actionCallBack, PushNotifier.actionMessage]);
      expect(a.every((e) => e.showsUserInterface), isTrue);
      final t = lookupAppLocalizations(const Locale('bn'));
      expect(a.first.title, t.cbarCallBack);
    });

    test('no buttons without my circle edge (no dead button)', () {
      final d = PushNotifier.detailsFor(PushPayload(const {
        'kind': 'missed_call',
        'call_id': '42',
        'chat_id': '',
        'lang': 'en',
        'channel': 'missed_calls',
      }));
      expect(d.android!.actions, isNull);
    });
  });

  testWidgets('settings: low-data switch saves on this phone', (tester) async {
    await tester.pumpWidget(
        app(const Scaffold(body: CallLowDataTile())));
    await tester.pump();
    final t = lookupAppLocalizations(const Locale('en'));
    expect(find.text(t.cbarLowDataTitle), findsOneWidget);
    await tester.tap(find.byKey(const Key('calls-low-data-setting')));
    await tester.pump();
    expect(await CallDataPrefs.lowData(), isTrue);
  });
}
