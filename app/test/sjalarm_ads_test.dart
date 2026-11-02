// sjalarm — OWNER FIX 3 Nov 02:55: Train Tracker ads. Exactly ONE adaptive
// banner at the bottom of the train SEARCH and train DETAIL (live map) pages;
// never in train chat, never in Safe Journey's train picker or the
// destination alarm; never over the 999 / 131 buttons or the map; no
// interstitial anywhere in train. 360 dp + 200 % font, bn + en.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/screens/train/train_chat_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/vehicle/veh_map.dart';

import 'fake_train.dart';

AdConfig _cfg() => AdConfig.fromJson({
      'plan': 'free',
      'paid': false,
      'ads_enabled': true,
      'placements': {'banner': true},
      'banner_screens': AdPlacements.bannerScreens.toList(),
    });

class _Handle implements BannerAdHandle {
  @override
  double get height => 50;
  @override
  Widget view() => const ColoredBox(
      key: ValueKey('fake-banner'), color: Color(0xFF888888), child: SizedBox(height: 50));
  @override
  void dispose() {}
}

class _Bridge implements BannerBridge {
  @override
  bool get linked => true;
  @override
  Future<BannerAdHandle?> load(String unitId, {required double width, required String placement}) async =>
      _Handle();
}

class _Api extends ApiClient {
  _Api({this.live = true}) {
    token = 't';
  }
  final bool live;
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeTrainGet(path, bn: false, empty: !live) ?? <String, dynamic>{};
  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

Widget _wrap(Widget home, {String lang = 'en', double scale = 1}) {
  final s = AppState();
  s.api = _Api();
  s.user = AppUser(id: 1, name: 'Rahim', phone: '01700000000', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) =>
          MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: home,
    ),
  );
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(360 * 3, 760 * 3); // 360 dp wide
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AdBannerSlot.debugBridge = _Bridge();
    AdBannerSlot.debugLoadConfig = () async => _cfg();
    FeatureFlags.instance.debugOverride = {'train_tracker': true, 'dest_alarm': true};
  });
  tearDown(() {
    AdBannerSlot.debugBridge = null;
    AdBannerSlot.debugLoadConfig = null;
    FeatureFlags.instance.resetForTest();
  });

  test('policy: train search + detail allowed; chat / alarm / picker never; no interstitial', () {
    final c = _cfg();
    for (final s in ['train_search', 'train_detail']) {
      expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isTrue, reason: s);
    }
    for (final s in ['train_chat', 'train_chat_join', 'destination_alarm', 'dest_alarm',
        'journey_train_pick', 'train_tracker']) {
      expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isFalse, reason: s);
    }
    expect(AdPlacements.interstitialMoments.values.any((s) => s.contains('train')), isFalse);
    expect(AdRules.isBlockedScreen('train_chat'), isTrue);
    // the train files: exactly the two banners, nothing else ad-related
    final tracker = File('lib/screens/train/train_tracker_screen.dart').readAsStringSync();
    expect(RegExp(r"AdBannerSlot\(screen: 'train_search'\)").allMatches(tracker).length, 1);
    expect(RegExp(r"AdBannerSlot\(screen: 'train_detail'\)").allMatches(tracker).length, 1);
    expect(RegExp(r'AdExit\.|maybeInterstitial|showInterstitial|HomeHero\(|SponsoredPostSlot\(')
        .hasMatch(tracker), isFalse);
    for (final f in Directory('lib/screens/train').listSync().whereType<File>()) {
      if (f.path.endsWith('train_tracker_screen.dart')) continue;
      expect(RegExp(r'AdBannerSlot\(|AdExit\.|AdsService|Interstitial').hasMatch(f.readAsStringSync()),
          isFalse, reason: '${f.path} must carry no ad');
    }
  });

  testWidgets('search page: one banner at the bottom', (t) async {
    _phone(t);
    await t.pumpWidget(_wrap(const TrainTrackerScreen()));
    await _settle(t);
    expect(find.byType(AdBannerSlot), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-banner')), findsOneWidget);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('detail page ($lang, 360 dp, 200 %): one banner, never over 999 / 131 or the map',
        (t) async {
      _phone(t);
      final l = await AppLocalizations.delegate.load(Locale(lang));
      await t.pumpWidget(_wrap(const TrainLiveScreen(no: '701', date: '2026-11-03'), lang: lang, scale: 2));
      await _settle(t);
      expect(find.byType(AdBannerSlot), findsOneWidget);
      final banner = find.byKey(const ValueKey('fake-banner'));
      expect(banner, findsOneWidget);
      final bannerTop = t.getRect(find.byType(AdBannerSlot)).top;
      // scroll so the hotlines sit at the very bottom of the body
      await t.scrollUntilVisible(find.byIcon(Icons.train_rounded), 100,
          scrollable: find.byType(Scrollable).first);
      await _settle(t);
      for (final icon in [Icons.call_rounded, Icons.train_rounded]) {
        final b = find.ancestor(
            of: find.byIcon(icon), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        expect(b, findsWidgets);
        expect(t.getRect(b.first).bottom, lessThanOrEqualTo(bannerTop),
            reason: 'hotline button overlaps the banner');
      }
      // the map (and its zoom / attribution controls) lives INSIDE the
      // scrolling body, whose viewport ends above the banner — clipped there
      expect(find.ancestor(of: find.byType(VehMap), matching: find.byType(Scrollable)), findsWidgets);
      expect(l.trCall999, isNotEmpty);
      // the body viewport ends where the banner starts (Scaffold layout)
      final body = t.getRect(find.byType(Scrollable).first);
      expect(body.bottom, lessThanOrEqualTo(bannerTop));
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('train chat, Safe Journey picker side and destination alarm: no banner', (t) async {
    _phone(t);
    await t.pumpWidget(_wrap(const TrainChatScreen(no: '701', date: '2026-11-03', title: 'Subarna')));
    await _settle(t);
    expect(find.byType(AdBannerSlot), findsNothing);
    DestAlarmScreen.debugStations = const [];
    DestAlarmScreen.debugBusStops = const [DestStation('b1', 'Farmgate', 'ফার্মগেট', 23.757, 90.39)];
    DestAlarmScreen.debugMetro = const [];
    addTearDown(() {
      DestAlarmScreen.debugStations = null;
      DestAlarmScreen.debugBusStops = null;
      DestAlarmScreen.debugMetro = null;
    });
    await t.pumpWidget(_wrap(const DestAlarmScreen()));
    await _settle(t);
    expect(find.byType(AdBannerSlot), findsNothing);
  });
}
