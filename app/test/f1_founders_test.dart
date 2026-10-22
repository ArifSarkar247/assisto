// f1-founders: feedback sheet (required note, screenshot attach/remove/undo,
// details shown before sending, error -> retry keeps the draft, rate limit,
// bn/en) + Founding Member badge + /me parsing + chat command routing.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feedback/feedback_capture.dart';
import 'package:assisto/feedback/feedback_sheet.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/founder_badge.dart';

import 'f1_shots.dart' show f1FakeShot;

const _meta = FeedbackMeta(
    appVersion: '1.0.0',
    appBuild: '151',
    deviceModel: 'realme RMX3491',
    osVersion: 'Android 13',
    language: 'en',
    route: 'money');

Future<void> _pump(WidgetTester tester, Widget child,
    {String lang = 'en', Brightness b = Brightness.light, double scale = 1}) async {
  await tester.binding.setSurfaceSize(const Size(360, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    locale: Locale(lang),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: AssistoTheme.light,
    darkTheme: AssistoTheme.dark,
    themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
    home: MediaQuery(
      data: MediaQueryData(
          size: const Size(360, 900), textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: child),
    ),
  ));
  await tester.pump();
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(FeedbackForm)));

void main() {
  setUp(FeedbackDraft.clear);

  group('feedback form', () {
    testWidgets('note is required — nothing is sent without it', (tester) async {
      var calls = 0;
      await _pump(tester, FeedbackForm(meta: _meta, send: (b) async {
        calls++;
        return {'ok': true};
      }));
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      expect(calls, 0);
      expect(find.text(_t(tester).fbNoteRequired), findsOneWidget);
      await tester.enterText(find.byKey(const Key('fb-note')), 'hi');
      await tester.pump();
      expect(find.text(_t(tester).fbNoteRequired), findsNothing);
    });

    testWidgets('sends note, category, details and the screenshot',
        (tester) async {
      Map<String, dynamic>? sent;
      await _pump(
          tester,
          FeedbackForm(
              meta: _meta,
              screenshot: f1FakeShot(),
              send: (b) async {
                sent = b;
                return {'ok': true};
              }));
      // details are visible BEFORE sending (privacy)
      expect(find.byKey(const Key('fb-details')), findsOneWidget);
      expect(find.text('realme RMX3491'), findsOneWidget);
      expect(find.text('Android 13'), findsOneWidget);
      expect(find.text('1.0.0 (151)'), findsOneWidget);
      expect(find.text('money'), findsOneWidget);
      expect(find.byKey(const Key('fb-shot')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fb-cat-idea')));
      await tester.enterText(find.byKey(const Key('fb-note')), 'Dark khata');
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      expect(sent, isNotNull);
      expect(sent!['note'], 'Dark khata');
      expect(sent!['category'], 'idea');
      expect(sent!['device_model'], 'realme RMX3491');
      expect(sent!['app_build'], '151');
      expect(sent!['route'], 'money');
      expect((sent!['screenshot_b64'] as String).isNotEmpty, isTrue);
      expect(FeedbackDraft.note, '', reason: 'draft cleared after success');
    });

    testWidgets('screenshot can be removed and added back', (tester) async {
      Map<String, dynamic>? sent;
      await _pump(
          tester,
          FeedbackForm(
              meta: _meta,
              screenshot: f1FakeShot(),
              send: (b) async {
                sent = b;
                return {'ok': true};
              }));
      await tester.tap(find.byKey(const Key('fb-shot-remove')));
      await tester.pump();
      expect(find.byKey(const Key('fb-shot')), findsNothing);
      expect(find.byKey(const Key('fb-shot-removed')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fb-shot-undo')));
      await tester.pump();
      expect(find.byKey(const Key('fb-shot')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fb-shot-remove')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('fb-note')), 'no picture');
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      expect(sent!.containsKey('screenshot_b64'), isFalse);
    });

    testWidgets('no screenshot -> honest "none attached"', (tester) async {
      await _pump(tester, const FeedbackForm(meta: FeedbackMeta()));
      expect(find.text(_t(tester).fbShotNone), findsOneWidget);
      // unknown details are labelled, never invented
      expect(find.text(_t(tester).fbDetailsUnknown), findsWidgets);
    });

    testWidgets('offline: error shown, draft kept, retry sends it',
        (tester) async {
      var fail = true;
      final bodies = <Map<String, dynamic>>[];
      await _pump(
          tester,
          FeedbackForm(
              meta: _meta,
              send: (b) async {
                bodies.add(b);
                if (fail) throw const SocketException('offline');
                return {'ok': true};
              }));
      await tester.enterText(find.byKey(const Key('fb-note')), 'crash on money');
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('fb-error')), findsOneWidget);
      expect(find.text(_t(tester).fbErrOffline), findsOneWidget);
      expect(find.text('crash on money'), findsOneWidget);
      expect(FeedbackDraft.note, 'crash on money');
      fail = false;
      await tester.tap(find.byKey(const Key('fb-retry')));
      await tester.pump();
      await tester.pump();
      expect(bodies.length, 2);
      expect(bodies.last['note'], 'crash on money');
      expect(FeedbackDraft.note, '');
    });

    testWidgets('draft survives closing and reopening', (tester) async {
      await _pump(tester, const FeedbackForm(meta: _meta));
      await tester.enterText(find.byKey(const Key('fb-note')), 'half written');
      await tester.tap(find.byKey(const Key('fb-cat-other')));
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const FeedbackForm(meta: _meta));
      expect(find.text('half written'), findsOneWidget);
      expect(FeedbackDraft.category, 'other');
    });

    testWidgets('rate limit and server errors are told apart', (tester) async {
      var status = 429;
      await _pump(
          tester,
          FeedbackForm(
              meta: _meta,
              send: (b) async => throw ApiException('x', status)));
      await tester.enterText(find.byKey(const Key('fb-note')), 'n');
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      expect(find.text(_t(tester).fbErrRate), findsOneWidget);
      status = 503;
      await tester.tap(find.byKey(const Key('fb-retry')));
      await tester.pump();
      expect(find.text(_t(tester).fbErrServer), findsOneWidget);
      status = 400;
      await tester.tap(find.byKey(const Key('fb-retry')));
      await tester.pump();
      expect(find.text('x'), findsOneWidget); // server's localised detail
    });

    testWidgets('timeout counts as offline', (tester) async {
      await _pump(
          tester,
          FeedbackForm(
              meta: _meta,
              send: (b) async => throw TimeoutException('slow')));
      await tester.enterText(find.byKey(const Key('fb-note')), 'n');
      await tester.tap(find.byKey(const Key('fb-send')));
      await tester.pump();
      expect(find.text(_t(tester).fbErrOffline), findsOneWidget);
    });

    for (final lang in ['bn', 'en']) {
      for (final b in Brightness.values) {
        testWidgets('renders $lang ${b.name}, large font, no overflow',
            (tester) async {
          await _pump(
              tester,
              FeedbackForm(
                  meta: _meta, screenshot: f1FakeShot(), debugStartOffline: true),
              lang: lang,
              b: b,
              scale: 1.4);
          final t = _t(tester);
          expect(find.text(t.fbTitle), findsOneWidget);
          expect(find.text(t.fbCatBug), findsOneWidget);
          expect(find.text(t.fbSend), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('founding member badge', () {
    testWidgets('badge label bn/en', (tester) async {
      await _pump(tester, const FounderBadge());
      expect(find.text('Founding Member'), findsOneWidget);
      await _pump(tester, const FounderBadge(), lang: 'bn');
      final t = AppLocalizations.of(tester.element(find.byType(FounderBadge)));
      expect(find.text(t.fmBadge), findsOneWidget);
      expect(t.fmBadge, isNot('Founding Member'));
    });

    testWidgets('block shows free Premium end date, hidden for non-members',
        (tester) async {
      final until = DateTime.now().add(const Duration(days: 200)).toIso8601String();
      final member = AppUser.fromJson({
        'id': 1, 'name': 'A', 'is_founder': true,
        'founding_member': {'active': true, 'since': '2026-10-22T00:00:00Z',
          'premium_until': until},
      });
      await _pump(tester, FounderBadgeBlock(user: member));
      expect(find.byKey(const Key('founder-badge')), findsOneWidget);
      expect(find.textContaining('Free Premium until'), findsOneWidget);
      final plain = AppUser.fromJson({'id': 2, 'name': 'B'});
      await _pump(tester, FounderBadgeBlock(user: plain));
      expect(find.byKey(const Key('founder-badge')), findsNothing);
    });

    test('AppUser parses and round-trips the badge', () {
      final u = AppUser.fromJson({
        'id': 1, 'name': 'A', 'is_founder': true,
        'founding_member': {'active': true, 'since': 's', 'premium_until': 'p'},
      });
      expect(u.isFounder, isTrue);
      expect(u.founderPremiumUntil, 'p');
      final again = AppUser.fromJson(u.toJson());
      expect(again.isFounder, isTrue);
      expect(again.founderSince, 's');
      expect(AppUser.fromJson({'id': 3, 'name': ''}).isFounder, isFalse);
    });
  });

  group('routing + capture', () {
    test('chat commands open feedback', () {
      for (final s in ['feedback', 'Send feedback', 'report a problem',
        'please report a bug', 'open feedback']) {
        expect(ChatNav.detectRoute(s), 'feedback', reason: s);
      }
      expect(ChatNav.routes.containsKey('feedback'), isTrue);
      expect(ChatNav.detectRoute('I spent 500 on food'), isNull);
      expect(ChatNav.detectRoute('my circle'), 'circle_add');
    });

    testWidgets('AppShot captures a boundary; missing boundary -> null',
        (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: const ColoredBox(color: Colors.blue, child: SizedBox(width: 40, height: 80))));
      final bytes = await tester.runAsync(() => AppShot.capture(key: key));
      expect(bytes, isNotNull);
      expect(bytes!.sublist(0, 4), [137, 80, 78, 71]);
      final none = await tester.runAsync(() => AppShot.capture(key: GlobalKey()));
      expect(none, isNull);
      expect(key.currentContext!.findRenderObject(), isA<RenderRepaintBoundary>());
    });

    test('ScreenTracker reports the innermost named route', () {
      final tr = ScreenTracker.instance;
      final a = MaterialPageRoute<void>(
          builder: (_) => const SizedBox(), settings: const RouteSettings(name: 'money'));
      final b = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tr.didPush(a, null);
      tr.didPush(b, a);
      expect(tr.current, 'money');
      tr.didPop(b, a);
      tr.didPop(a, null);
      expect(tr.current, isNull);
    });
  });
}
