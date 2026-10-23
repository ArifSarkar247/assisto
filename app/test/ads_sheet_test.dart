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

import 'p2_fakes.dart';

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

  String? customData;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData}) async {
    shown++;
    this.customData = customData;
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
    RewardedAdSheet.debugBackend = null;
  });

  // p2-money: rewards come ONLY from Google's signed SSV callback; the app
  // never claims a reward itself (no /ads/event for rewarded any more).
  testWidgets('earned -> SSV ticket used, server state read, no client claim',
      (tester) async {
    final b = _Bridge(RewardOutcome.earned);
    AdsService.instance.bridge = b;
    final sb = FakeSponsorBackend();
    RewardedAdSheet.debugBackend = sb;
    final (_, api) = await _pump(tester, configured: true);
    expect(find.textContaining('1'), findsWidgets); // caps parsed (used 1)
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(b.shown, 1);
    expect(b.customData, 'n1');
    expect(sb.ticketReads, 1);
    expect(api.events, isEmpty);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adRewardedTitle), findsOneWidget);
  });

  testWidgets('closed early -> no reward, no ticket read', (tester) async {
    AdsService.instance.bridge = _Bridge(RewardOutcome.dismissed);
    final sb = FakeSponsorBackend();
    RewardedAdSheet.debugBackend = sb;
    final (_, api) = await _pump(tester, configured: true);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(api.events, isEmpty);
    expect(sb.ticketReads, 0);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adsDismissedBody), findsOneWidget);
  });

  testWidgets('no AdMob linked -> server refuses the ticket, honest state',
      (tester) async {
    final b = _Bridge(RewardOutcome.earned);
    AdsService.instance.bridge = b;
    RewardedAdSheet.debugBackend = FakeSponsorBackend(
        ticket: {'ok': false, 'reason': 'ads_not_configured', 'msg': ''});
    final (_, api) = await _pump(tester, configured: false);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(b.shown, 0);
    expect(api.events, isEmpty);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adNotSetUpTitle), findsOneWidget);
  });

  testWidgets('daily cap -> honest cap state, no ad', (tester) async {
    final b = _Bridge(RewardOutcome.earned);
    AdsService.instance.bridge = b;
    RewardedAdSheet.debugBackend =
        FakeSponsorBackend(ticket: {'ok': false, 'reason': 'capped'});
    await _pump(tester, configured: true);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(b.shown, 0);
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.adCapTitle), findsOneWidget);
  });
}
