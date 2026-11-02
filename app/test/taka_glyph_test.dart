// sitelive (owner 3 Nov): "৳ shows as b" (b500 Food, b2,000). Noto Sans
// Bengali's taka sign reads as a Latin "b"; AssistoTaka (Hind Siliguri
// subset, U+09F3 only) is FIRST in AFonts.fallback so every ৳ in the app,
// the gallery screenshots and the website shots uses the clear form.
// Fails if the glyph is missing (test-font box) or comes from Noto again,
// in Bangla and in English.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/theme.dart';

import 'app_fonts.dart';

double _w(String text, TextStyle style, String lang) {
  final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      locale: Locale(lang))
    ..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

void main() {
  setUpAll(loadAppFonts);

  test('AssistoTaka is bundled with its OFL licence, first in the fallback', () {
    expect(File('assets/fonts/AssistoTaka.ttf').existsSync(), isTrue);
    expect(File('assets/fonts/AssistoTaka-OFL.txt').readAsStringSync(),
        contains('SIL Open Font License'));
    expect(File('pubspec.yaml').readAsStringSync(),
        contains('assets/fonts/AssistoTaka.ttf'));
    expect(AFonts.fallback.first, AFonts.taka);
    expect(AFonts.fallback, contains(AFonts.bangla));
  });

  for (final lang in const ['bn', 'en']) {
    test('৳ renders from AssistoTaka with the theme fonts ($lang)', () {
      // large size: the two glyphs differ by only 0.2 % in advance width
      const size = 1000.0;
      final theme = AssistoTheme.light.textTheme.titleMedium!
          .copyWith(fontSize: size, fontWeight: FontWeight.w600);
      final themed = _w('৳', theme, lang);
      final taka = _w('৳',
          const TextStyle(fontFamily: 'AssistoTaka', fontSize: size,
              fontWeight: FontWeight.w600),
          lang);
      final noto = _w('৳',
          const TextStyle(fontFamily: 'NotoSansBengali', fontSize: size,
              fontWeight: FontWeight.w600),
          lang);
      // the test font draws a missing glyph as a 1 em box
      expect((themed - size).abs() > 5, isTrue,
          reason: '৳ is missing (test-font box) in $lang');
      expect(themed, closeTo(taka, 0.05),
          reason: '৳ must come from AssistoTaka in $lang');
      expect((taka - noto).abs() > 1, isTrue,
          reason: 'AssistoTaka must not be the Noto glyph (reads as "b")');
      // money strings as the app writes them
      final amount = lang == 'bn' ? '৳৫০০' : '৳500';
      expect(_w(amount, theme, lang) > themed, isTrue);
    });
  }
}
