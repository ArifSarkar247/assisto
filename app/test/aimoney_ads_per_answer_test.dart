// aimoney (owner 10 Nov 03:45, part G): the rewarded-ad sheet tells the user
// honestly how many ads buy one AI answer TODAY (the server's daily number),
// in English and Bangla (Bangla digits); no number from the server -> no line.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/rewarded_ad_sheet.dart';

import 'pay1_fakes.dart';

class _Api extends ApiClient {
  _Api(this.n) {
    token = 't';
  }
  final int? n;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/ads/wallet') {
      return {
        'balance_credits': 0,
        'caps': {
          'rewarded': {'cap': 5, 'used': 0, 'remaining': 5}
        },
        if (n != null) 'ads_per_answer': n,
      };
    }
    return {};
  }
}

Future<void> _pump(WidgetTester tester, int? n, String lang) async {
  final app = AppState();
  app.api = _Api(n);
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: lang);
  app.loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: SingleChildScrollView(child: RewardedAdSheet())),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdsService.instance.resetForTest();
    RewardedAdSheet.debugBackend = null;
  });

  testWidgets('shows the daily number: Watch 3 ads for 1 AI answer', (tester) async {
    await _pump(tester, 3, 'en');
    expect(find.byKey(const Key('ad-per-answer')), findsOneWidget);
    expect(find.text('Watch 3 ads for 1 AI answer'), findsOneWidget);
  });

  testWidgets('Bangla line with Bangla digits', (tester) async {
    await _pump(tester, 2, 'bn');
    expect(find.text('১টি AI উত্তরের জন্য ২টি বিজ্ঞাপন দেখুন'), findsOneWidget);
  });

  testWidgets('no number from the server -> no line (never a guess)', (tester) async {
    await _pump(tester, null, 'en');
    expect(find.byKey(const Key('ad-per-answer')), findsNothing);
  });

  // lead (10 Nov): the in-task credits sheet reads N from the server (no
  // typed 2) and lists the new ৳49 = 15 pack the server sells.
  group('credits-finished sheet', () {
    PayConfig cfg() => PayConfig.fromJson({
          'channels': [
            {'id': 'gateway', 'enabled': true, 'ready': true, 'label': 'EPS'},
          ],
          'products': {
            'gateway': [
              pay1Product('c15', price: 49, kind: 'pack', credits: 15),
              pay1Product('c50', price: 179, kind: 'pack', credits: 60),
              pay1Product('c120', price: 399, kind: 'pack', credits: 140),
              pay1Product('c300', price: 949, kind: 'pack', credits: 330),
            ],
          },
        });

    Future<void> pumpSheet(WidgetTester tester, Future<int?> Function(BuildContext) n,
        {String lang = 'en'}) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
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
        home: Scaffold(
            body: SingleChildScrollView(
                child: CreditsOutSheet(
                    screen: 'ai_chat',
                    draftKept: true,
                    backend: FakePaymentsBackend(cfg: cfg()),
                    flavour: 'apk',
                    adsAvailable: (_) async => true,
                    adsPerAnswer: n))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('server N = 3 -> "watch 3 short ads", and the ৳49 pack is listed',
        (tester) async {
      await pumpSheet(tester, (_) async => 3);
      expect(find.textContaining('watch 3 short ads = 1 Normal answer'), findsOneWidget);
      expect(find.textContaining('2 short ads'), findsNothing);
      expect(find.textContaining('৳49'), findsOneWidget);
      expect(find.textContaining('৳179'), findsOneWidget);
    });

    testWidgets('Bangla: N in Bangla digits', (tester) async {
      await pumpSheet(tester, (_) async => 4, lang: 'bn');
      expect(find.textContaining('৪টি ছোট বিজ্ঞাপন'), findsOneWidget);
    });

    testWidgets('N unknown -> the plain line, never a guessed number', (tester) async {
      await pumpSheet(tester, (_) async => null);
      expect(find.byKey(const Key('credout-ad')), findsOneWidget);
      expect(find.textContaining('short ads = 1 Normal answer'), findsNothing);
    });
  });
}
