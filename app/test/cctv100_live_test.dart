// cctv100: the Shop Box live view is never a dead end — an honest error
// (device offline / no answer) always offers "Retry" right there, the retry
// really starts a new session, and both languages fit at 200% font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/shop_live_screen.dart';
import 'package:assisto/state.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final starts = <int>[];

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/shop/live/start') {
      starts.add((body['camera'] as num).toInt());
      throw ApiException('The Shop Box device is offline right now.', 409);
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async => const {};
}

Future<_Api> _pump(WidgetTester tester, String lang, {double scale = 1.0}) async {
  final app = AppState();
  final api = _Api();
  app.api = api;
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
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: const ShopLiveScreen(cameraId: 7, cameraName: 'Cash counter'),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('offline device: honest message + working Retry (no dead end)',
      (tester) async {
    final api = await _pump(tester, 'en');
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.byKey(const Key('shopLiveRetry')), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(api.starts, [7]);
    await tester.tap(find.byKey(const Key('shopLiveRetry')));
    await tester.pumpAndSettle();
    expect(api.starts, [7, 7]); // a real second attempt, not a fake spinner
    expect(find.byKey(const Key('shopLiveRetry')), findsOneWidget);
    final size = tester.getSize(find.byKey(const Key('shopLiveRetry')));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('error state fits at 200% font ($lang)', (tester) async {
      tester.view.physicalSize = const Size(720, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await _pump(tester, lang, scale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('shopLiveRetry')), findsOneWidget);
    });
  }

  test('no-answer timeout stays below the server pending timeout (45 s)', () {
    expect(ShopLiveScreen.connectTimeoutSeconds, lessThan(45));
    expect(ShopLiveScreen.connectTimeoutSeconds, greaterThanOrEqualTo(20));
  });
}
