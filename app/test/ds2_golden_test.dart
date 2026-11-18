// designv2 goldens (owner order 10 Nov, Design System V2, step 4).
//  * Key redesigned screens + the DS component gallery, light + dark:
//    PNGs always go to $ASSISTO_SHOT_DIR/ds2 (CI artifact shots-*); when a
//    golden exists in test/goldens/ds2/ the render must match it
//    (`flutter test --update-goldens test/ds2_golden_test.dart` after an
//    intended visual change).
//  * HOME LAYOUT LOCK (owner 10 Nov 01:45): Home's layout must not change —
//    only token colours may. The test records every box's position + size
//    (colours are not part of it) and compares with
//    test/goldens/home_layout_<variant>.txt. Missing baseline = bootstrap
//    (written to the shot dir, then committed by the design lane).
//  * Redesigned screens: no cut text, 48 dp touch targets.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/bn_day_periods.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'ds2_guard_test.dart' show cutTexts, dsGallery;
import 'fake_api.dart';
import 'home_v2_shots.dart';
import 'screenshots_test.dart' show gallerySetUpAll, galleryPump, gallerySpecs, galleryStub;

final _shotDir =
    '${Platform.environment['ASSISTO_SHOT_DIR'] ?? 'build/shots'}/ds2';

/// Screens redesigned in Design System V2 (grows with every batch).
const ds2Screens = <String>[
  'blood_hub',
  'blood_hub_empty',
  'blood_requests',
  'blood_me',
  'fc3_board', // batch 2: Family member cards
  'fc3_board_sos',
  'settings', // batch 2: grouped V2 cards
  'money', // batch 3
  'biz_khata', // batch 3
  'ai_chat', // batch 3
  'blood_request_mine', // batch 3
  'blood_request_form', // batch 4
  'blood_setup', // batch 4
  'blood_verify', // batch 4
  'blood_banks', // batch 4
  'blood_thread', // batch 4
  'blood_saved', // batch 4
  'fce_are_you_ok', // batch 4
  'fce_watch_alert', // batch 4
  'fce_watch_none', // batch 4
  'fce_watch_empty', // batch 4
  'fce_setup_form', // batch 4
  'fce_setup_qr', // batch 4
  'fce_setup_empty', // batch 4
  'fce_consent', // batch 4
  'fcs_alarm', // batch 4
  'fcs_countdown', // batch 4
  'fcs_sent', // batch 4
  'school_mode_child', // batch 4
  'school_mode_child_empty', // batch 4
  'medicine_history', // batch 4
  'health_tips', // batch 4
  'medicine_db', // batch 4
  'sjl_hub', // batch 5
  'push_settings', // batch 5
  'notification_centre', // batch 5
  'circle', // batch 5
  'emergency_hub', // batch 5
];

Future<void> _png(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image =
      await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
  final bytes =
      await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  Directory(_shotDir).createSync(recursive: true);
  File('$_shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}

/// design3: blood_requests differed 4.6 % between the goldens job and a
/// checks shard (time-relative fixture rows) — shot-only.
const _noGolden = {'blood_requests'};

Future<void> _golden(GlobalKey key, String name) async {
  final f = 'goldens/ds2/$name.png';
  // --update-goldens writes the baselines (design3: CI job ds2-goldens.yml)
  if (autoUpdateGoldenFiles || File('test/$f').existsSync()) {
    await expectLater(find.byKey(key), matchesGoldenFile(f));
  }
}

/// Layout signature: depth, box type, global position and size of every
/// RenderBox (rounded to 0.5 px). Colours are not part of it.
String layoutSignature(RenderObject root) {
  final out = StringBuffer();
  String r(double v) => (v * 2).round().toString();
  void walk(RenderObject o, int depth) {
    if (o is RenderBox && o.hasSize) {
      final p = o.localToGlobal(Offset.zero);
      out.writeln('$depth ${o.runtimeType} ${r(p.dx)},${r(p.dy)} '
          '${r(o.size.width)}x${r(o.size.height)}');
    }
    o.visitChildren((c) => walk(c, depth + 1));
  }

  walk(root, 0);
  return out.toString();
}

/// Buttons / switches / chips whose touch box is under 48 × 48 dp.
List<String> smallTargets(WidgetTester tester) {
  final out = <String>[];
  final f = find.byWidgetPredicate((w) =>
      w is ButtonStyleButton || w is IconButton || w is Switch || w is ChoiceChip);
  for (final e in f.evaluate()) {
    final r = e.renderObject;
    if (r is! RenderBox || !r.hasSize || !r.attached) continue;
    final s = r.size;
    // a Switch / Checkbox inside a list tile: the whole tile (>= 48 dp) is the target
    if (e.widget is Switch &&
        e.findAncestorWidgetOfExactType<ListTile>() != null) {
      continue;
    }
    if (s.width < 47.5 || s.height < 47.5) {
      out.add('${e.widget.runtimeType} ${e.widget.key} ${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}');
    }
  }
  return out;
}

/// design3: goldens tolerate a tiny pixel noise (pulse / shimmer phase,
/// anti-aliasing, "5 min ago" text against fixture times): up to 1 % of the
/// pixels may differ.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);
  static const tolerance = 0.01;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final r = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (r.passed || r.diffPercent <= tolerance) {
      r.dispose();
      return true;
    }
    final error = await generateFailureOutput(r, golden, basedir);
    r.dispose();
    throw FlutterError(error);
  }
}

void main() {
  setUpAll(() async {
    await gallerySetUpAll();
    final c = goldenFileComparator;
    if (c is LocalFileComparator) {
      goldenFileComparator = _TolerantComparator(c.basedir.resolve('ds2_golden_test.dart'));
    }
  });
  setUp(() {
    FakeApi.planSlug = 'premium';
  });

  final specs = gallerySpecs();
  for (final name in ds2Screens) {
    for (final b in Brightness.values) {
      for (final lang in ['bn', 'en']) {
        testWidgets('ds2 $name $lang ${b.name}', (tester) async {
          DsPerf.debugLite = false; // the full V2 look (fixed pumps, no settle)
          addTearDown(() => DsPerf.debugLite = null);
          debugDisableShadows = false;
          final spec = specs[name]!;
          final key = GlobalKey();
          await galleryPump(tester, name, lang, b, spec.build(lang), spec.mode, key: key);
          expect(tester.takeException(), isNull);
          expect(cutTexts(tester), isEmpty, reason: '$name: text cut off');
          await _png(tester, key, '${name}_${lang}_${b.name}');
          // design3: screens whose fixture content moves with the clock or the
          // shard's shared fake state stay shot-only (no pixel compare)
          if (lang == 'bn' && !_noGolden.contains(name)) await _golden(key, '${name}_${b.name}');
          debugDisableShadows = true;
          expect(smallTargets(tester), isEmpty, reason: '$name: touch target < 48 dp');
        });
      }
    }
  }

  for (final b in Brightness.values) {
    testWidgets('ds2 component gallery ${b.name}', (tester) async {
      DsPerf.debugLite = false;
      addTearDown(() => DsPerf.debugLite = null);
      debugDisableShadows = false;
      await tester.binding.setSurfaceSize(const Size(360, 2600));
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('bn'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AssistoTheme.light,
          darkTheme: AssistoTheme.dark,
          themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
          home: Scaffold(body: dsGallery('bn')),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await _png(tester, key, 'ds_gallery_bn_${b.name}');
      await _golden(key, 'ds_gallery_${b.name}');
      debugDisableShadows = true;
    });
  }

  // ---------------------------------------------------------- home lock
  for (final lang in ['bn', 'en']) {
    testWidgets('home layout lock $lang (colours only may change)', (tester) async {
      const size = Size(390, 844);
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
            data: const MediaQueryData(
                size: size,
                padding: EdgeInsets.only(top: 24),
                viewPadding: EdgeInsets.only(top: 24)),
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
              themeMode: ThemeMode.light,
              home: homeV2Shot(),
            ),
          ),
        ),
      ));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 250)));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(tester.takeException(), isNull);
      final sig = layoutSignature(key.currentContext!.findRenderObject()!);
      Directory(_shotDir).createSync(recursive: true);
      File('$_shotDir/home_layout_$lang.txt').writeAsStringSync(sig);
      final base = File('test/goldens/home_layout_$lang.txt');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      if (!base.existsSync()) {
        // ignore: avoid_print
        print('home layout lock: no baseline yet (bootstrap) — $_shotDir/home_layout_$lang.txt');
        return;
      }
      final want = base.readAsLinesSync();
      final got = sig.trimRight().split('\n');
      final diff = <String>[];
      for (var i = 0; i < want.length || i < got.length; i++) {
        final w = i < want.length ? want[i] : '<none>';
        final g = i < got.length ? got[i] : '<none>';
        if (w != g) diff.add('line ${i + 1}: want "$w" got "$g"');
        if (diff.length >= 8) break;
      }
      expect(diff, isEmpty,
          reason: 'Home layout changed (owner 10 Nov: Home = colours only). If '
              'this is an owner-approved change, replace test/goldens/'
              'home_layout_$lang.txt with the new file from the shots artifact.\n'
              '${diff.join('\n')}');
    });
  }
}
