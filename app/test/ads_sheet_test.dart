import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/rewarded_ad_sheet.dart';

class _Api extends ApiClient {
  _Api({required this.configured}) {
    token = 't';
  }
  final bool configured;
  final events = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/ads/wallet') {
      return {
        'balance_credits': 1,
        'caps': {
          'rewarded': {'cap': 5, 'used': 1, 'remaining': 4}
        },
      };
    }
    if (path == '/ads/config') {
      return {
        'configured': configured,
        'app_id': AdsService.builtAppId,
        'units': {'rewarded': 'ca-app-pub-1234567890123456/1111111111'},
        'plan': 'free',
        'rewarded_enabled': true,
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    events.add('$path:${body['kind']}');
    return {'ok': true, 'reason': 'ok', 'credited_credits': 2};
  }
}

class _Bridge implements AdsBridge {
  _Bridge(this.outcome);
  final RewardOutcome outcome;
  int shown = 0;
  @override
  Future<bool> init() async => true;
  @override
  bool get linked => true;
  @override
  Future<bool> showAppOpen(String unitId) async => false;
  @override
  Future<RewardOutcome> showRewarded(String unitId) async {
    shown++;
    return outcome;
  }
}

Future<(AppState, _Api)> _pump(WidgetTester tester,
    {required bool configured}) async {
  final app = AppState();
  final api = _Api(configured: configured);
  app.api = api;
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: RewardedAdSheet()),
    ),
  ));
  await tester.pumpAndSettle();
  return (app, api);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdsService.instance.resetForTest();
  });

  testWidgets('earned reward -> ads/event reported once', (tester) async {
    final b = _Bridge(RewardOutcome.earned);
    AdsService.instance.bridge = b;
    final (_, api) = await _pump(tester, configured: true);
    expect(find.textContaining('1'), findsWidgets); // caps parsed (used 1)
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(b.shown, 1);
    expect(api.events, ['/ads/event:rewarded']);
  });

  testWidgets('closed early -> no reward reported', (tester) async {
    AdsService.instance.bridge = _Bridge(RewardOutcome.dismissed);
    final (_, api) = await _pump(tester, configured: true);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(api.events, isEmpty);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adsDismissedBody), findsOneWidget);
  });

  testWidgets('no SDK / no AdMob ids -> honest not-set-up, no reward',
      (tester) async {
    // default NoopAdsBridge, unconfigured server
    final (_, api) = await _pump(tester, configured: false);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(api.events, isEmpty);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adNotSetUpTitle), findsOneWidget);
  });
}
