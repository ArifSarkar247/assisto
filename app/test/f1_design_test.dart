// f1-design: the design system's hard guarantees.
//  1. Bangla never clips: tall conjuncts and below-base vowel signs, at every
//     text style of the type scale (1x and 2x text size), keep their ink
//     inside the line box (golden-free pixel check).
//  2. Theme components meet the 48 dp tap-target + label guidelines.
//  3. Fonts are bundled (pubspec) with their OFL licences, never fetched.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fonts.dart';

const _tall = 'ক্ষ্ম স্ত্র ঙ্ক্ষ কু কূ কৃ রু রূ হৃ শ্রু দ্রু ক্রূ';
const _mixed = 'ক্ষ্ম Assisto ৳১২৩ স্ত্র Ag';

Map<String, TextStyle?> _styles(TextTheme t) => {
      'displayLarge': t.displayLarge,
      'displayMedium': t.displayMedium,
      'displaySmall': t.displaySmall,
      'headlineLarge': t.headlineLarge,
      'headlineMedium': t.headlineMedium,
      'headlineSmall': t.headlineSmall,
      'titleLarge': t.titleLarge,
      'titleMedium': t.titleMedium,
      'titleSmall': t.titleSmall,
      'bodyLarge': t.bodyLarge,
      'bodyMedium': t.bodyMedium,
      'bodySmall': t.bodySmall,
      'labelLarge': t.labelLarge,
      'labelMedium': t.labelMedium,
      'labelSmall': t.labelSmall,
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
  });

  group('Bangla never clips', () {
    final theme = AssistoTheme.light;
    for (final scale in [1.0, 2.0]) {
      for (final e in _styles(theme.textTheme).entries) {
        for (final text in [_tall, _mixed]) {
          testWidgets('${e.key} x$scale ${text == _tall ? 'conjuncts' : 'mixed'}',
              (tester) async {
            await tester.binding.setSurfaceSize(const Size(2400, 600));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final key = GlobalKey();
            final textKey = GlobalKey();
            await tester.pumpWidget(MaterialApp(
              theme: theme,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: key,
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(60),
                      child: Text(text,
                          key: textKey,
                          maxLines: 1,
                          softWrap: false,
                          style: e.value!.copyWith(color: Colors.black)),
                    ),
                  ),
                ),
              ),
            ));
            final box = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final textBox = tester.getRect(find.byKey(textKey));
            final origin = tester.getTopLeft(find.byKey(key));
            final img = await tester.runAsync(() => box.toImage(pixelRatio: 1.0));
            final bytes = await tester.runAsync(
                () => img!.toByteData(format: ui.ImageByteFormat.rawRgba));
            final data = bytes!.buffer.asUint8List();
            final w = img!.width, h = img.height;
            int? top, bottom;
            for (var y = 0; y < h; y++) {
              for (var x = 0; x < w; x++) {
                final i = (y * w + x) * 4;
                if (data[i + 3] > 200 && data[i] < 160) {
                  top ??= y;
                  bottom = y;
                  break;
                }
              }
            }
            final dump = Platform.environment['F1_CLIP_DUMP'];
            if (dump != null) {
              final png = await tester.runAsync(
                  () => img.toByteData(format: ui.ImageByteFormat.png));
              File('$dump/${e.key}_${scale}_${text.length}.png')
                  .writeAsBytesSync(png!.buffer.asUint8List());
              // ignore: avoid_print
              print('${e.key} x$scale ink $top..$bottom line '
                  '${textBox.top - origin.dy}..${textBox.bottom - origin.dy} img ${w}x$h');
            }
            img.dispose();
            expect(top, isNotNull, reason: 'nothing rendered');
            final lineTop = textBox.top - origin.dy;
            final lineBottom = textBox.bottom - origin.dy;
            // Ink (rows) must sit inside the line box (1 px AA tolerance).
            expect(top! >= lineTop - 1, isTrue,
                reason: '${e.key}: ink top $top above line top $lineTop');
            expect(bottom! <= lineBottom + 1, isTrue,
                reason: '${e.key}: ink bottom $bottom below line bottom $lineBottom');
          });
        }
      }
    }
  });

  testWidgets('theme components meet tap-target + label guidelines',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: AssistoTheme.light,
      home: Scaffold(
        appBar: AppBar(title: const Text('Assisto')),
        body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          FilledButton(onPressed: () {}, child: const Text('Save')),
          const SizedBox(height: Gap.sm),
          OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
          const SizedBox(height: Gap.sm),
          TextButton(onPressed: () {}, child: const Text('Skip')),
          const SizedBox(height: Gap.sm),
          ElevatedButton(onPressed: () {}, child: const Text('More')),
          const SizedBox(height: Gap.sm),
          Row(children: [
            IconButton(
                onPressed: () {},
                tooltip: 'Call',
                icon: const Icon(Icons.call_rounded)),
          ]),
          ListTile(title: const Text('Settings'), onTap: () {}),
        ]),
      ),
    ));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });

  test('type scale: every style uses Inter + Bangla fallback, height >= 1.35',
      () {
    for (final b in [AssistoTheme.light, AssistoTheme.dark]) {
      for (final e in _styles(b.textTheme).entries) {
        final s = e.value!;
        expect(s.fontFamily, AFonts.latin, reason: e.key);
        expect(s.fontFamilyFallback, contains(AFonts.bangla), reason: e.key);
        expect(s.height! >= 1.35, isTrue, reason: e.key);
      }
    }
  });

  test('fonts are bundled with OFL licences (never downloaded)', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    for (final f in ['Inter', 'NotoSansBengali']) {
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        expect(pub, contains('assets/fonts/$f-$w.ttf'));
        expect(File('assets/fonts/$f-$w.ttf').existsSync(), isTrue);
      }
      expect(File('assets/fonts/$f-OFL.txt').readAsStringSync(),
          contains('SIL Open Font License'));
    }
    expect(pub.contains('google_fonts'), isFalse);
  });

  test('dark tokens keep AA contrast on the dark surface', () {
    double lum(Color c) {
      double ch(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double ratio(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    for (final th in [AssistoTheme.light, AssistoTheme.dark]) {
      final s = th.colorScheme;
      final t = th.extension<AssistoTokens>()!;
      for (final bg in [s.surface, s.surfaceContainerLow, s.surfaceContainerHigh]) {
        expect(ratio(s.onSurface, bg) >= 4.5, isTrue);
        expect(ratio(s.onSurfaceVariant, bg) >= 4.5, isTrue);
        expect(ratio(s.primary, bg) >= 4.5, isTrue);
        expect(ratio(t.textMuted, bg) >= 4.5, isTrue);
        expect(ratio(t.success, bg) >= 4.5, isTrue);
        expect(ratio(t.warning, bg) >= 4.5, isTrue);
        expect(ratio(t.info, bg) >= 4.5, isTrue);
      }
      expect(ratio(s.onPrimary, s.primary) >= 4.5, isTrue);
      expect(ratio(t.onSuccessContainer, t.successContainer) >= 4.5, isTrue);
      expect(ratio(t.onWarningContainer, t.warningContainer) >= 4.5, isTrue);
      expect(ratio(t.onInfoContainer, t.infoContainer) >= 4.5, isTrue);
    }
  });
}
