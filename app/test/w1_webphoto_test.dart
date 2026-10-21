// w1-webphoto: the lifeassisto.com/photo deep link opens the SAME photo in
// Photo Studio (fake API), an expired link says so honestly, signed-out links
// wait for sign-in, and exporting still goes through THE export gate.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_web_import.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/screens/web_photo_link_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'ps1_fakes.dart';
import 'w1_webphoto_fakes.dart';

AppState _state({bool loggedIn = true}) {
  final s = AppState();
  s.api = ApiClient(token: loggedIn ? 'test-token' : null);
  if (loggedIn) {
    s.user = AppUser(
        id: 1, name: 'Arif', phone: '01712345678', email: '',
        autonomyLevel: 2, language: 'en');
  }
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(AppState s, {Widget? home, String? initialRoute,
        Widget Function(String token)? link}) =>
    ChangeNotifierProvider.value(
      value: s,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home ?? const Scaffold(body: Text('HOME')),
        initialRoute: initialRoute,
        onGenerateRoute: link == null ? null : (rs) => WebPhotoLink.route(rs, link),
      ),
    );

const _tok = 'AbC_dEf-123456789012345678901234567890xyz';

void main() {
  setUp(() => WebPhotoLink.pending = null);

  group('deep-link parsing', () {
    test('route name and full https URL', () {
      expect(WebPhotoLink.tokenFrom('/photo/app?t=$_tok'), _tok);
      expect(WebPhotoLink.tokenFrom('https://lifeassisto.com/photo/app?t=$_tok&lang=en'), _tok);
    });
    test('anything else is not ours', () {
      expect(WebPhotoLink.tokenFrom('/'), isNull);
      expect(WebPhotoLink.tokenFrom('/photo'), isNull);
      expect(WebPhotoLink.tokenFrom('/photo/app'), isNull);
      expect(WebPhotoLink.tokenFrom('/photo/app?t='), isNull);
      expect(WebPhotoLink.tokenFrom('/photo/app?t=a%20b'), isNull);
      expect(WebPhotoLink.tokenFrom('https://evil.example/photo/app?t=$_tok'), isNull);
      expect(WebPhotoLink.tokenFrom('/photo/app?t=${'x' * 65}'), isNull);
      expect(WebPhotoLink.route(const RouteSettings(name: '/other'), (_) => const SizedBox()), isNull);
      // a full URL is the cold-start case, not a route
      expect(WebPhotoLink.route(const RouteSettings(name: 'https://lifeassisto.com/photo/app?t=$_tok'), (_) => const SizedBox()), isNull);
    });
  });

  group('controller: website photo keeps the export gate', () {
    Future<(PhotoStudioController, WebPsBackend, FakeSink, FakeRenderer)> open(
        {bool free = true, int credits = 0}) async {
      final b = WebPsBackend(free: free, credits: credits);
      final sink = FakeSink();
      final r = FakeRenderer();
      final c = PhotoStudioController(webDeps(b, sink: sink, renderer: r));
      await c.init();
      final claim = await FakeWebPhotoApi(b).claim(_tok);
      expect(claim.status, WebClaimStatus.ok);
      c.loadWebImport(claim.import!);
      return (c, b, sink, r);
    }

    test('opens the claimed photo with the passport preset', () async {
      final (c, b, _, _) = await open();
      expect(c.webImport, isTrue);
      expect(c.session!.edited, isTrue);
      expect(c.session!.current.jobId, isNotNull);
      expect(c.session!.current.previewOnly, isTrue);
      expect(c.options, contains('passport_bd'));
      expect(c.canExport, isTrue);
      // only the (watermarked) preview was fetched — no clean result yet
      expect(b.downloads.single, contains('web_preview'));
    });

    test('free: cancel -> nothing leaves; ads -> unlocked, corner mark, clean server result', () async {
      final (c, b, sink, r) = await open();
      await c.export(ExportKind.save, ScriptUi([null]));
      expect(c.notice, PsNotice.cancelled);
      expect(sink.delivered, isEmpty);
      expect(b.downloads.where((u) => u.contains('web_result')), isEmpty);
      await c.export(ExportKind.save, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(c.notice, PsNotice.saved);
      expect(sink.delivered, [ExportKind.save]);
      expect(r.marks, [true]);
      expect(b.downloads.last, contains('web_result'));
    });

    test('free: credits path charges the full price', () async {
      final (c, b, sink, _) = await open(credits: 5);
      await c.export(ExportKind.share, ScriptUi([FundChoice.credits]));
      expect(b.credits, 3);
      expect(sink.delivered, [ExportKind.share]);
    });

    test('premium: straight through, clean', () async {
      final (c, b, sink, r) = await open(free: false);
      await c.export(ExportKind.save, ScriptUi([]));
      expect(sink.delivered, [ExportKind.save]);
      expect(r.marks, [false]);
      expect(b.unlocks, [ExportKind.save]);
    });

    test('editing the website preview is refused honestly; picking the original resets', () async {
      final (c, _, _, _) = await open();
      await c.runEnhance();
      expect(c.notice, PsNotice.webImportNoEdit);
      await c.runPrompt('brighter', ScriptUi([]));
      expect(c.notice, PsNotice.webImportNoEdit);
      await c.pick(camera: false);
      expect(c.webImport, isFalse);
      expect(c.session!.edited, isFalse);
    });

    test('claim is single use', () async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b);
      expect((await api.claim(_tok)).status, WebClaimStatus.ok);
      expect((await api.claim(_tok)).status, WebClaimStatus.expired);
    });
  });

  group('deep-link screen', () {
    testWidgets('cold start: opening the link opens Photo Studio with the fetched photo', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b);
      Widget link(String t) => WebPhotoLinkScreen(token: t, api: api, deps: webDeps(b));
      WebPhotoLink.resetColdStart();
      // FlutterActivity hands over the FULL https URL as the initial route:
      // the Navigator falls back to home, and home pushes the link on top.
      await tester.pumpWidget(_app(_state(),
          initialRoute: 'https://lifeassisto.com/photo/app?t=$_tok',
          home: Builder(builder: (ctx) {
            WidgetsBinding.instance.addPostFrameCallback((_) =>
                WebPhotoLink.maybeOpenColdStart(
                    ctx, 'https://lifeassisto.com/photo/app?t=$_tok', link));
            return const Scaffold(body: Text('HOME'));
          }),
          link: link));
      await tester.pumpAndSettle();
      expect(api.claimed, [_tok]);
      expect(find.byType(PhotoStudioScreen), findsOneWidget);
      expect(find.byKey(const Key('psWebImage')), findsOneWidget);
      expect(find.byKey(const Key('psWebLabel')), findsOneWidget);
      expect(find.byKey(const Key('psWebPickOriginal')), findsOneWidget);
      // back goes home (the link screen was replaced)
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('path-form initial route keeps home underneath', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b);
      await tester.pumpWidget(_app(_state(),
          initialRoute: '/photo/app?t=$_tok',
          link: (t) => WebPhotoLinkScreen(token: t, api: api, deps: webDeps(b))));
      await tester.pumpAndSettle();
      expect(api.claimed, [_tok]);
      expect(find.byKey(const Key('psWebImage')), findsOneWidget);
    });

    testWidgets('warm start: a pushed route name opens the link on top', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b);
      await tester.pumpWidget(_app(_state(),
          link: (t) => WebPhotoLinkScreen(token: t, api: api, deps: webDeps(b))));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      // what WidgetsApp does for didPushRouteInformation (onNewIntent)
      await tester.binding.handlePushRoute('/photo/app?t=$_tok');
      await tester.pumpAndSettle();
      expect(api.claimed, [_tok]);
      expect(find.byKey(const Key('psWebImage')), findsOneWidget);
    });

    testWidgets('expired token shows an honest message, no photo', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b, status: 410);
      await tester.pumpWidget(_app(_state(),
          home: WebPhotoLinkScreen(token: _tok, api: api, deps: webDeps(b))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('psWebExpired')), findsOneWidget);
      expect(find.text('This link has expired'), findsOneWidget);
      expect(find.byKey(const Key('psWebImage')), findsNothing);
      expect(b.jobs, isEmpty);
    });

    testWidgets('signed out: asks to sign in and keeps the token, no claim', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b);
      await tester.pumpWidget(_app(_state(loggedIn: false),
          home: WebPhotoLinkScreen(token: _tok, api: api, deps: webDeps(b))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('psWebSignIn')), findsOneWidget);
      expect(WebPhotoLink.pending, _tok);
      expect(api.claimed, isEmpty);
    });

    testWidgets('network failure: retry message', (tester) async {
      final b = WebPsBackend();
      final api = FakeWebPhotoApi(b, status: 500);
      await tester.pumpWidget(_app(_state(),
          home: WebPhotoLinkScreen(token: _tok, api: api, deps: webDeps(b))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('psWebFailed')), findsOneWidget);
    });
  });
}
