// learncert (owner 3 Nov part C) — Assisto learning certificate:
//  1 the card shows name, course, level, date, QR, code and the MANDATORY
//    "not an official qualification" line, bn + en;
//  2 exam names only as "-style practice"; Quran card only "Qaida completed"
//    (never ijazah / Qari) — on everything the card renders;
//  3 My certificates: list -> tap -> card; empty = benefit + big button +
//    how-to; failure = honest message + retry;
//  4 revoke asks first, then shows the revoked banner and hides sharing;
//  5 courseResult(): flag OFF or no token -> nothing; flag ON -> name sheet
//    -> claim -> the card opens;
//  6 Bangla 200% text at 360 dp, light + dark: no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/learn_cert_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_learncert.dart';

const _discEn = 'Assisto learning certificate — not an official qualification';
const _exams = ['IELTS', 'TOPIK', 'JLPT', 'Goethe', 'DELF', 'DELE', 'HSK'];

Widget _app(Widget child, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
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
      builder: scale == 1
          ? null
          : (ctx, w) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
              child: w!),
      home: child,
    ),
  );
}

void _tall(WidgetTester t, {double w = 1080}) {
  t.view.physicalSize = Size(w, 6400);
  t.view.devicePixelRatio = w == 1080 ? 2.5 : 3;
  addTearDown(t.view.reset);
}

List<String> _texts(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text))) w.data ?? '',
      for (final w in t.widgetList<SelectableText>(find.byType(SelectableText))) w.data ?? '',
    ];

bool _examOutsideStyle(String s) {
  for (final n in _exams) {
    for (final m in RegExp('(?<![A-Za-z])$n(?![A-Za-z])', caseSensitive: false).allMatches(s)) {
      final tail = s.substring(m.end);
      if (!tail.startsWith('-style practice') && !tail.startsWith('-ধাঁচের')) {
        return true;
      }
    }
  }
  return false;
}

class _CallSite extends StatelessWidget {
  final void Function(Map<String, dynamic>?) done;
  final String? token;
  const _CallSite({required this.done, this.token = 'signed-token'});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () async => done(await courseResult(context,
                course: 'lang_ko', level: 'L3', score: 78, token: token)),
            child: const Text('finish'),
          ),
        ),
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FeatureFlags.instance.debugOverride = null;
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  testWidgets('card: name, level, QR, code, disclaimer (en)', (t) async {
    _tall(t);
    await t.pumpWidget(_app(LearnCertDetailScreen(cert: fakeLangCert()), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Rahim Uddin'), findsOneWidget);
    expect(find.text('Korean — Language Partner'), findsOneWidget);
    expect(find.textContaining('TOPIK-style practice'), findsOneWidget);
    expect(find.text('ALC-KMPR-TXWA-HBQE'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(_discEn), findsOneWidget);
    final tr = AppLocalizations.of(t.element(find.byType(LearnCertCard)));
    expect(find.text(tr.lcDownloadPdf), findsOneWidget);
    expect(find.text(tr.lcShareFacebook), findsOneWidget);
    for (final s in _texts(t)) {
      expect(_examOutsideStyle(s), isFalse, reason: s);
    }
  });

  testWidgets('card in Bangla carries the Bangla disclaimer', (t) async {
    _tall(t);
    await t.pumpWidget(_app(LearnCertDetailScreen(cert: fakeLangCert()), FakeApi(), lang: 'bn'));
    await t.pumpAndSettle();
    final bn = (fakeLangCert()['bn'] as Map)['disclaimer'] as String;
    expect(find.text(bn), findsOneWidget);
    expect(find.text(_discEn), findsNothing);
    final tr = AppLocalizations.of(t.element(find.byType(LearnCertCard)));
    expect(tr.lcDisclaimer, bn);
  });

  testWidgets('Quran card: only "Qaida completed", never ijazah / Qari', (t) async {
    _tall(t);
    for (final lang in ['en', 'bn']) {
      await t.pumpWidget(_app(LearnCertDetailScreen(cert: fakeQuranCert()), FakeApi(lang: lang), lang: lang));
      await t.pumpAndSettle();
      final all = _texts(t).join(' | ').toLowerCase();
      for (final bad in ['ijazah', 'ইজাযাহ', 'qari', 'ক্বারী']) {
        expect(all.contains(bad), isFalse, reason: '$lang: $bad');
      }
      if (lang == 'en') expect(find.text('Qaida completed'), findsOneWidget);
    }
  });

  testWidgets('list -> tap -> card; empty and failure states', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const LearnCertScreen(), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Korean — Language Partner'), findsOneWidget);
    expect(find.text('Learn to read Quran — Qaida'), findsOneWidget);
    await t.tap(find.text('Korean — Language Partner'));
    await t.pumpAndSettle();
    expect(find.byType(LearnCertCard), findsOneWidget);

    await t.pumpWidget(_app(const LearnCertScreen(), FakeApi(lang: 'en', mode: FakeMode.empty)));
    await t.pumpAndSettle();
    final tr = AppLocalizations.of(t.element(find.byType(LearnCertScreen)));
    expect(find.text(tr.lcEmptyTitle), findsOneWidget);
    expect(find.text(tr.lcEmptyAction), findsOneWidget);
    expect(find.text(tr.lcEmptyHow), findsOneWidget);
    final btn = t.getSize(find.ancestor(of: find.text(tr.lcEmptyAction), matching: find.byType(FilledButton)));
    expect(btn.height, greaterThanOrEqualTo(48));

    await t.pumpWidget(_app(const LearnCertScreen(), FakeApi(lang: 'en', mode: FakeMode.fail)));
    await t.pumpAndSettle();
    expect(find.text(tr.retry), findsOneWidget);
  });

  testWidgets('revoke asks first, then shows the revoked banner', (t) async {
    _tall(t);
    await t.pumpWidget(_app(LearnCertDetailScreen(cert: fakeLangCert()), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    final tr = AppLocalizations.of(t.element(find.byType(LearnCertCard)));
    await t.tap(find.text(tr.lcRevoke));
    await t.pumpAndSettle();
    expect(find.text(tr.lcRevokeTitle), findsOneWidget);
    await t.tap(find.text(tr.cancel));
    await t.pumpAndSettle();
    expect(find.text(tr.lcRevokedBanner), findsNothing);
    await t.tap(find.text(tr.lcRevoke));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(tr.lcRevoke)));
    await t.pumpAndSettle();
    expect(find.text(tr.lcRevokedBanner), findsOneWidget);
    expect(find.text(tr.lcShareFacebook), findsNothing);
  });

  testWidgets('courseResult: flag OFF / no token -> nothing', (t) async {
    _tall(t);
    Map<String, dynamic>? got = {'x': 1};
    FeatureFlags.instance.debugOverride = {kLearnCertFlag: false};
    await t.pumpWidget(_app(_CallSite(done: (c) => got = c), FakeApi(lang: 'en')));
    await t.tap(find.text('finish'));
    await t.pumpAndSettle();
    expect(got, isNull);
    expect(find.byType(LearnCertClaimSheet), findsNothing);

    got = {'x': 1};
    FeatureFlags.instance.debugOverride = {kLearnCertFlag: true};
    await t.pumpWidget(_app(_CallSite(done: (c) => got = c, token: null), FakeApi(lang: 'en')));
    await t.tap(find.text('finish'));
    await t.pumpAndSettle();
    expect(got, isNull);
    expect(find.byType(LearnCertClaimSheet), findsNothing);
  });

  testWidgets('courseResult: flag ON -> name sheet -> claim -> card', (t) async {
    _tall(t);
    FeatureFlags.instance.debugOverride = {kLearnCertFlag: true};
    Map<String, dynamic>? got;
    await t.pumpWidget(_app(_CallSite(done: (c) => got = c), FakeApi(lang: 'en')));
    await t.tap(find.text('finish'));
    await t.pumpAndSettle();
    expect(find.byType(LearnCertClaimSheet), findsOneWidget);
    final tr = AppLocalizations.of(t.element(find.byType(LearnCertClaimSheet)));
    expect(find.text(tr.lcDisclaimer), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Rahim Uddin');
    await t.tap(find.text(tr.lcGetCert));
    await t.pumpAndSettle();
    expect(find.byType(LearnCertCard), findsOneWidget);
    expect(find.text(_discEn), findsOneWidget);
    // back to the caller -> the issued certificate comes back
    await t.pageBack();
    await t.pumpAndSettle();
    expect(got?['code'], 'ALC-KMPR-TXWA-HBQE');
  });

  for (final dark in [false, true]) {
    testWidgets('Bangla 200% at 360 dp, dark=$dark: no overflow', (t) async {
      _tall(t, w: 1080);
      t.view.devicePixelRatio = 3; // 360 dp wide
      for (final w in <Widget>[
        LearnCertDetailScreen(cert: fakeLangCert()),
        LearnCertDetailScreen(cert: fakeQuranCert()),
        LearnCertDetailScreen(cert: fakeLangCert(valid: false)),
        const LearnCertScreen(),
        const Scaffold(body: LearnCertClaimSheet(token: 'tok', defaultName: 'Rahim Uddin')),
      ]) {
        await t.pumpWidget(_app(w, FakeApi(), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
    });
  }
}
