// q1-seams — reality audit 22 Oct ("Seam audit 22 Oct" in
// .phaseB/REALITY_AUDIT.md). Regression proofs that a failed server write is
// never shown as a success, and that facade entry points stay hidden:
//
//  * Safe Journey live: a failed "I've arrived" / "Stop" says so and keeps the
//    live screen (it used to show "arrived safely" / close silently).
//  * Journey settings: a failed wellness save says so.
//  * Family selective sharing: the grid loads the SERVER's grants and a failed
//    toggle says so and reloads the truth (it started empty and swallowed).
//  * AppState.saveProfile reports failure (it was swallowed).
//  * My Circle chat extras: scheduled / broadcast / backup / restore / sticker
//    / wallpaper / link-a-device facades are hidden behind one honest note;
//    export with nothing to export says so.
//  * Circle invite + referral QR are REAL scannable QR codes.
//  * Business reports: no "PDF"/"Excel" claim for a plain-text share.
//  * Products: the spreadsheet import (media picker) entry point is hidden.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/products_screen.dart';
import 'package:assisto/screens/business/reports_screen.dart';
import 'package:assisto/screens/circle_extras_hub_screen.dart';
import 'package:assisto/screens/crm/crm_proposal_advanced_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_settings_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_invite_sheet.dart';
import 'package:assisto/widgets/fam_share_section.dart';
import 'package:assisto/widgets/ref_share_sheet.dart';

import 'fake_api.dart';

final _en = AppLocalizationsEn();

/// A server where any path containing one of [fail] answers 503.
class _Api extends ApiClient {
  _Api({Set<String>? fail}) : fail = fail ?? {} {
    token = 't';
  }

  final Set<String> fail;
  final List<String> posts = [];
  Map<String, dynamic> consent = {
    'rows': [
      {
        'member_id': 7,
        'name': 'Ammu',
        'relation': 'mother',
        'items': {'location': true, 'medicine': false},
      }
    ],
  };

  void _gate(String path) {
    if (fail.any(path.contains)) throw ApiException('down', 503);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    _gate(path);
    if (path.contains('family/sharing/consent')) return consent;
    if (path.contains('/journey/wellness')) {
      return {'enabled': false, 'parent_opt_in': false};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    _gate(path);
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> createItem(
      String path, Map<String, dynamic> body) async {
    posts.add(path);
    _gate(path);
    return consent;
  }

  @override
  Future<AppUser> updateProfile(Map<String, dynamic> fields) async {
    _gate('/me');
    return _user();
  }
}

AppUser _user() => AppUser(
    id: 1,
    name: 'Me',
    phone: '+8801700000000',
    email: '',
    autonomyLevel: 2,
    language: 'en');

AppState _state(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = _user();
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, Widget home, ApiClient api) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api),
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: home,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Unmount and let snackbars / guarded timers run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Safe Journey live', () {
    testWidgets('failed "arrived" is never shown as arrived', (tester) async {
      final api = _Api(fail: {'/arrived'});
      await _pump(
          tester, const Scaffold(body: JourneyLiveScreen(journeyId: 5)), api);
      final btn = find.text(_en.journeyImSafe);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, contains('/journey/5/arrived'));
      expect(find.text(_en.realityArrivedNotSent), findsOneWidget);
      expect(find.text(_en.journeyArrivedSafely), findsNothing);
      expect(find.byType(JourneyLiveScreen), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('failed "stop" says so and keeps the live screen',
        (tester) async {
      final api = _Api(fail: {'/stop'});
      await _pump(
          tester, const Scaffold(body: JourneyLiveScreen(journeyId: 5)), api);
      final btn = find.text(_en.journeyStop);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text(_en.journeyStopConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, contains('/journey/5/stop'));
      expect(find.text(_en.grpActionFailed), findsOneWidget);
      expect(find.byType(JourneyLiveScreen), findsOneWidget);
      await _drain(tester);
    });
  });

  testWidgets('journey settings: a failed wellness save says so',
      (tester) async {
    // fail only the POST: getJson must keep working for the reload.
    final failing = _PostFailApi('/journey/wellness');
    await _pump(tester, const JourneySettingsScreen(), failing);
    final sw = find.text(_en.wellnessEnable);
    await tester.ensureVisible(sw);
    await tester.tap(sw);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(failing.posts, contains('/journey/wellness'));
    expect(find.text(_en.grpActionFailed), findsOneWidget);
    await _drain(tester);
  });

  group('family selective sharing', () {
    testWidgets('loads the server grants and a failed toggle says so',
        (tester) async {
      final api = _Api(fail: {'family/sharing/grant'});
      await _pump(
          tester,
          const Scaffold(
              body: FamShareSection(members: [
            {'id': 7, 'name': 'Ammu', 'relation': 'mother'}
          ])),
          api);
      // Server says "location" is shared -> the card is not "nothing shared".
      await tester.tap(find.text('Ammu'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      bool on(int i) => tester
          .widget<SwitchListTile>(find.byType(SwitchListTile).at(i))
          .value;
      expect(on(0), isTrue); // location (from the server)
      expect(on(1), isFalse); // medicine
      await tester.tap(find.byType(SwitchListTile).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, contains('family/sharing/grant'));
      expect(find.text(_en.grpActionFailed), findsOneWidget);
      expect(on(1), isFalse); // reloaded server truth, not the optimistic on
      await _drain(tester);
    });

    testWidgets('a failed load is shown, never a silent "nothing shared"',
        (tester) async {
      final api = _Api(fail: {'family/sharing/consent'});
      await _pump(
          tester,
          const Scaffold(
              body: FamShareSection(members: [
            {'id': 7, 'name': 'Ammu', 'relation': 'mother'}
          ])),
          api);
      expect(find.byKey(const ValueKey('q1-famshare-load-failed')),
          findsOneWidget);
      await _drain(tester);
    });
  });

  test('AppState.saveProfile reports a failed save', () async {
    final s = _state(_Api(fail: {'/me'}));
    expect(await s.saveProfile({'fall_detect': true}), isFalse);
    final ok = _state(_Api());
    expect(await ok.saveProfile({'fall_detect': true}), isTrue);
  });

  testWidgets('chat extras: only real tools, no "not yet" row',
      (tester) async {
    await _pump(
        tester,
        CircleExtrasHubScreen(
            member: const {'id': 3, 'name': 'Rahim'},
            decryptedMessages: () => const []),
        _Api());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_en.circleExtrasDisappearing), findsWidgets);
    expect(find.byKey(const ValueKey('q1-extras-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('q1-extras-not-yet')), findsNothing);
    for (final gone in [
      _en.circleExtrasScheduled,
      _en.circleExtrasBroadcast,
      _en.circleExtrasCreateBackup,
      _en.circleExtrasRestore,
      _en.circleExtrasStickers,
      _en.circleExtrasViewOnce,
      _en.circleExtrasLinkDevice,
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await tester.tap(find.byKey(const ValueKey('q1-extras-export')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_en.q1ExtrasExportEmpty), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('circle invite dialog shows a real QR', (tester) async {
    await _pump(
        tester,
        Builder(
            builder: (c) => Scaffold(
                body: TextButton(
                    onPressed: () => showCircleInviteLink(c,
                        link: 'https://lifeassisto.com/i/abc', token: 'abc'),
                    child: const Text('open')))),
        _Api());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('q1-invite-qr')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('referral share sheet QR is a real QR', (tester) async {
    await _pump(
        tester,
        Builder(
            builder: (c) => Scaffold(
                body: TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                        context: c,
                        isScrollControlled: true, // as referral_screen.dart
                        builder: (_) => const RefShareSheet(
                            link: 'https://lifeassisto.com/r/XYZ',
                            code: 'XYZ',
                            message: 'Join me')),
                    child: const Text('open')))),
        _Api());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text(_en.refShareQr));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('q1-ref-qr')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('business reports: no PDF/Excel claim', (tester) async {
    await _pump(tester, const ReportsScreen(businessId: 1),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('q1-report-share')), findsOneWidget);
    expect(find.text('PDF'), findsNothing);
    expect(find.text('Excel'), findsNothing);
    await _drain(tester);
  });

  test('CRM quote acceptance "link" (a relative JSON path) stays hidden', () {
    expect(kQuoteAcceptPageWired, isFalse);
  });

  testWidgets('products: the media-picker "Excel import" is hidden',
      (tester) async {
    expect(kProductImportPickerWired, isFalse);
    await _pump(tester, const ProductsScreen(businessId: 1),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.upload_file_outlined), findsNothing);
    await _drain(tester);
  });
}

/// Every GET works; a POST to [failPath] fails.
class _PostFailApi extends _Api {
  _PostFailApi(this.failPath);
  final String failPath;

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    if (path.contains(failPath)) throw ApiException('down', 503);
    return {'ok': true};
  }
}
