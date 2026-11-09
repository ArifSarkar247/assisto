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
import 'package:assisto/state.dart';
import 'package:assisto/widgets/rewarded_ad_sheet.dart';

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
}
