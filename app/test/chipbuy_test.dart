// chipbuy (owner 2 Nov) — tracker chip on the child card + "Where to buy".
//  1 "Where to buy" opens https://asalifymart.com/?utm_source=assisto in the
//    EXTERNAL browser (url_launcher externalApplication) — nothing else in
//    the URL; failure = an honest snackbar; bn + en titles per product;
//  2 the child card shows a chip: name, battery % (Bangla digits in bn),
//    low-battery pill, "battery: not reported" when the model is silent,
//    who can see it; the child's own phone shows "on + who sees" only;
//  3 adding a chip validates the IMEI and posts ONLY to the chip endpoint
//    (never the paid vehicle pairing), with the picked brand's protocol;
//  4 the empty state offers the chip + where-to-buy links;
//  5 200% Bangla, dark: no overflow.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/kids_watch/chip_widgets.dart';
import 'package:assisto/screens/kids_watch/kids_watch_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/where_to_buy.dart';

import 'fake_kidswatch.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.bn = false}) {
    token = 't';
  }

  final bool empty;
  final bool bn;
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeKidsWatchGet(path, bn: bn, empty: empty) ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path == '/kids-watch/chips') {
      return {
        'ok': true,
        'chip': {'id': 9, 'state': 'pending', 'kind': 'chip', 'child_name': 'Rafi',
                 'protocol': body['protocol'], 'imei': body['imei'], 'live': null,
                 'pair_expires_at': DateTime.now().toUtc()
                     .add(const Duration(minutes: 10)).toIso8601String()},
      };
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> patchJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async => {'ok': true};
}

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

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6400);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('where to buy', () {
    final opened = <(Uri, LaunchMode)>[];
    var result = true;
    setUp(() {
      opened.clear();
      result = true;
      WhereToBuyLink.launcher = (u, m) async {
        opened.add((u, m));
        return result;
      };
    });

    test('the link lives in ONE widget; no other app code mentions asalifymart', () {
      final hits = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'))
          .where((f) => f.readAsStringSync().toLowerCase().contains('asalifymart'))
          .map((f) => f.path.replaceAll(r'\\', '/'))
          .toList();
      expect(hits, ['lib/widgets/where_to_buy.dart']);
    });

    test('plain external link, one utm_source, nothing else', () {
      final u = WhereToBuyLink.uri;
      expect(u.scheme, 'https');
      expect(u.host, 'asalifymart.com');
      expect(u.queryParameters, {'utm_source': 'assisto'});
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('$lang: every product title, tap opens the browser externally', (t) async {
        final l = await AppLocalizations.delegate.load(Locale(lang));
        await t.pumpWidget(_app(
            const Scaffold(
              body: Column(children: [
                WhereToBuyLink(product: BuyProduct.cctv),
                WhereToBuyLink(product: BuyProduct.vehicle),
                WhereToBuyLink(product: BuyProduct.kidsWatch),
                WhereToBuyLink(product: BuyProduct.chip, dense: true),
              ]),
            ),
            _Fake(),
            lang: lang));
        for (final s in [l.buyCctvTitle, l.buyVehicleTitle, l.buyKidsWatchTitle,
          l.buyChipTitle]) {
          expect(find.text(s), findsOneWidget);
        }
        await t.tap(find.byKey(const ValueKey('where-to-buy-chip')));
        await t.pump();
        expect(opened.single.$1.toString(), kWhereToBuyUrl);
        expect(opened.single.$2, LaunchMode.externalApplication);
        // 48 dp+ touch target
        expect(t.getSize(find.byKey(const ValueKey('where-to-buy-cctv'))).height,
            greaterThanOrEqualTo(48));
      });
    }

    testWidgets('browser cannot open: honest snackbar', (t) async {
      result = false;
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      await t.pumpWidget(_app(
          const Scaffold(body: WhereToBuyLink(product: BuyProduct.vehicle)), _Fake()));
      await t.tap(find.byKey(const ValueKey('where-to-buy-vehicle')));
      await t.pump();
      expect(find.text(l.buyOpenFailed), findsOneWidget);
    });
  });

  testWidgets('child card: chip battery, low pill, not reported, who sees, child view',
      (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake()));
    await t.pumpAndSettle();
    final paired = find.byKey(const ValueKey('chip-card-7'));
    expect(paired, findsOneWidget);
    expect(find.descendant(of: paired, matching: find.text('Rafi')), findsOneWidget);
    expect(find.descendant(of: paired, matching: find.text(l.kwBattery('15'))), findsOneWidget);
    expect(find.descendant(of: paired, matching: find.text(l.chipBatteryLow)), findsOneWidget);
    expect(find.descendant(of: paired, matching: find.text(l.chipWhoSees('Mum'))),
        findsOneWidget);
    expect(find.descendant(of: paired, matching: find.text(l.chipHistory)), findsOneWidget);
    final waiting = find.byKey(const ValueKey('chip-card-8'));
    expect(find.descendant(of: waiting, matching: find.text(l.chipBatteryUnknown)),
        findsOneWidget);
    expect(find.descendant(of: waiting, matching: find.text(l.chipWaiting)), findsOneWidget);
    // the child's own phone: on + who sees, never a location
    final worn = find.byKey(const ValueKey('chip-worn-7'));
    expect(find.descendant(of: worn, matching: find.text(l.chipWornBody('Dad', 'Dad, Mum'))),
        findsOneWidget);
    // guardian history sheet
    await t.ensureVisible(find.byKey(const ValueKey('chip-history')));
    await t.tap(find.byKey(const ValueKey('chip-history')));
    await t.pumpAndSettle();
    expect(find.text(l.chipHistoryNote), findsOneWidget);
    expect(find.byIcon(Icons.place_outlined), findsNWidgets(2));
  });

  testWidgets('bn: chip battery in Bangla digits', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('bn'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(bn: true), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text(l.kwBattery('১৫')), findsOneWidget);
    expect(find.text(l.chipBatteryUnknown), findsOneWidget);
    expect(find.text(l.chipKind), findsNWidgets(2));
  });

  testWidgets('add chip: IMEI checked, posts only to the chip endpoint', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const Scaffold(body: ChipPairSheet()), api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('where-to-buy-chip')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('chip-name')), 'Rafi');
    await t.enterText(find.byKey(const ValueKey('chip-imei')), '1234');
    await t.ensureVisible(find.byKey(const ValueKey('chip-pair-submit')));
    await t.tap(find.byKey(const ValueKey('chip-pair-submit')));
    await t.pumpAndSettle();
    expect(find.text(l.chipErrImei), findsOneWidget);
    expect(api.posts, isEmpty);
    await t.tap(find.byKey(const ValueKey('chip-brand-sinotrack')));
    await t.enterText(find.byKey(const ValueKey('chip-imei')), '865920051234563');
    await t.ensureVisible(find.byKey(const ValueKey('chip-pair-submit')));
    await t.tap(find.byKey(const ValueKey('chip-pair-submit')));
    await t.pump();
    await t.pump();
    expect(api.posts.first.$1, '/kids-watch/chips');
    expect(api.posts.first.$2['imei'], '865920051234563');
    expect(api.posts.first.$2['protocol'], 'h02');
    expect(api.posts.first.$2['child_name'], 'Rafi');
    expect(api.posts.any((p) => p.$1.startsWith('/vehicle/')), isFalse);
    // dispose the live setup view (its poll timers stop)
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('empty: chip button + where-to-buy links', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(empty: true)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('kw-empty-chip')), findsOneWidget);
    expect(find.text(l.chipAddTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('where-to-buy-kidsWatch')), findsOneWidget);
    expect(find.byKey(const ValueKey('where-to-buy-chip')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: chips + pair sheet, no overflow',
        (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(bn: true),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(const Scaffold(body: ChipPairSheet()), _Fake(bn: true),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
