// home_v2 golden screenshots: the new home rendered on the reference phone
// (390 x 844, owner_actions/design/assisto_home_v6.png) and on a small 360 x
// 800 phone, Bangla + English, light + dark, at 100 % and 200 % font. Every
// render must be free of layout exceptions (overflow = a failing test).
// PNGs go to $HV2_SHOT_DIR (default build/home_v2_shots); the owner's
// before/after set in owner_actions/design/ is produced from this file.
//
// `HV2_BEFORE=1` also renders the previous home (HomeScreen) for "before".
import 'dart:io';
import 'dart:ui' as ui;

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/widgets/bn_day_periods.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fake_api.dart';
import 'home_v2_shots.dart';
import 'screenshots_test.dart' show gallerySetUpAll, galleryStub;

final _dir = Platform.environment['HV2_SHOT_DIR'] ?? 'build/home_v2_shots';
final _before = Platform.environment['HV2_BEFORE'] == '1';

Future<void> _render(WidgetTester tester, String file, Widget screen,
    {required String lang,
    required Brightness b,
    required Size size,
    double scale = 1.0}) async {
  debugDisableShadows = false;
  await tester.binding.setSurfaceSize(size);
  final key = GlobalKey();
  final app = galleryStub(lang: lang);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
    child: RepaintBoundary(
      key: key,
      child: MediaQuery(
        data: MediaQueryData(
            size: size,
            padding: const EdgeInsets.only(top: 24),
            viewPadding: const EdgeInsets.only(top: 24),
            textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale(lang),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            BnDayPeriods.delegate,
          ],
          theme: AssistoTheme.light,
          darkTheme: AssistoTheme.dark,
          themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
          home: screen,
        ),
      ),
    ),
  ));
  await tester.runAsync(() async {
    for (final el in find.byType(Image).evaluate()) {
      final img = el.widget as Image;
      await precacheImage(img.image, el)
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    await Future.delayed(const Duration(milliseconds: 250));
  });
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(tester.takeException(), isNull, reason: file);
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image =
      await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
  final bytes = await tester
      .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  Directory(_dir).createSync(recursive: true);
  File('$_dir/$file.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
  // let the Discover auto-rotate timer / hero timers drain
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  debugDisableShadows = true;
}

void main() {
  setUpAll(() async {
    await gallerySetUpAll();
  });
  setUp(() {
    FakeApi.planSlug = 'premium';
  });

  const sizes = {'ref': Size(390, 844), 'small': Size(360, 800)};
  for (final lang in ['bn', 'en']) {
    for (final b in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        for (final s in sizes.entries) {
          final name =
              'home_v2_${lang}_${b.name}_${s.key}${scale == 1.0 ? '' : '_200'}';
          testWidgets('golden $name', (tester) async {
            await _render(tester, name, homeV2Shot(),
                lang: lang, b: b, size: s.value, scale: scale);
          });
        }
      }
      // the whole 200 % page at once (tall surface) to review every section
      testWidgets('golden home_v2_${lang}_${b.name}_full_200', (tester) async {
        await _render(tester, 'home_v2_${lang}_${b.name}_full_200', homeV2Shot(),
            lang: lang, b: b, size: const Size(360, 2000), scale: 2.0);
      });
      // owner feedback 27 Oct: the Free user's home with the COMPACT ad
      // (default), at 100 % and 200 %, plus the server "large" option
      for (final scale in [1.0, 2.0]) {
        final name =
            'home_v2_free_${lang}_${b.name}${scale == 1.0 ? '' : '_200'}';
        testWidgets('golden $name', (tester) async {
          await _render(tester, name, homeV2Shot(free: true),
              lang: lang, b: b, size: sizes['ref']!, scale: scale);
        });
      }
      // tall: the whole Free home incl. the ad and the Need help card
      testWidgets('golden home_v2_free_${lang}_${b.name}_full', (tester) async {
        await _render(tester, 'home_v2_free_${lang}_${b.name}_full',
            homeV2Shot(free: true),
            lang: lang, b: b, size: const Size(390, 1080));
      });
      testWidgets('golden home_v2_free_large_${lang}_${b.name}', (tester) async {
        await _render(tester, 'home_v2_free_large_${lang}_${b.name}',
            homeV2Shot(free: true, size: 'large'),
            lang: lang, b: b, size: sizes['ref']!);
      });
      // 02:00 -> the late-night greeting (never "Good evening")
      testWidgets('golden home_v2_night_${lang}_${b.name}', (tester) async {
        await _render(tester, 'home_v2_night_${lang}_${b.name}',
            homeV2Shot(now: DateTime(2026, 10, 27, 2)),
            lang: lang, b: b, size: sizes['ref']!);
      });
      if (_before) {
        testWidgets('before $lang ${b.name}', (tester) async {
          await _render(tester, 'home_before_${lang}_${b.name}',
              const HomeScreen(),
              lang: lang, b: b, size: sizes['ref']!);
        });
      }
    }
  }
}
