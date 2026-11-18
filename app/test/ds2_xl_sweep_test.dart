// design3 (lead 17 Nov, a11y lane): the app honours the phone's font size up
// to 2.0x app-wide, so EVERY gallery screen is checked at 2.0x, bn + en:
// no cut text (maxLines / ellipsis hit), no overflow / layout exception,
// and in bn no Taka amount in Latin digits.
//
// Runs only with DS2_XL=1 (the ds2-goldens job on the design lane branches),
// so the shared checks runners don't pay for ~1100 pumps.
//  * Writes $ASSISTO_SHOT_DIR/xl_sweep/<screen>_<lang>.txt for every failure.
//  * test/ds2_xl_known.json lists screens still failing (SHRINKING — the
//    design lane fixes and removes them). A screen not in the list must pass.
//    No list yet = report-only bootstrap.
//  * Home is layout-frozen (its own 2.0 runs pass) and is skipped here.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'screenshots_test.dart' show gallerySetUpAll, galleryPump, gallerySpecs;

final _on = Platform.environment['DS2_XL'] == '1';
final _dir = '${Platform.environment['ASSISTO_SHOT_DIR'] ?? 'build/shots'}/xl_sweep';

bool _frozenHome(String name) =>
    name == 'home' || name.startsWith('home_') || name.startsWith('h1_') || name.startsWith('hv2_');

/// Every cut text with the kind of control it sits in. `label-cut` (a
/// button / chip / tab / nav / tile label) and layout errors gate; plain
/// `text-cut` (a long name or preview line that ellipsizes on purpose) and
/// `appbar-cut` are reported only.
List<String> _cutKinds(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final r = e.renderObject;
    if (r is! RenderParagraph || !r.didExceedMaxLines) continue;
    var kind = 'text-cut';
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is ButtonStyleButton || w is IconButton || w is FloatingActionButton) {
        kind = 'label-cut(button)';
      } else if (w is Tab) {
        kind = 'label-cut(tab)';
      } else if (w is RawChip || w is Chip || w is ChoiceChip || w is FilterChip || w is ActionChip || w is InputChip) {
        kind = 'label-cut(chip)';
      } else if (w is NavigationDestination || w is BottomNavigationBar || w is NavigationBar) {
        kind = 'label-cut(nav)';
      } else if (w is AppBar) {
        kind = 'appbar-cut';
      } else if (w is Scaffold) {
        return false;
      } else {
        return true;
      }
      return false;
    });
    final c = r.text.toPlainText();
    out.add('$kind: ${c.length > 80 ? c.substring(0, 80) : c}');
  }
  return out;
}

bool _gates(String problem) =>
    problem.startsWith('label-cut') ||
    problem.startsWith('error') ||
    problem.startsWith('exception') ||
    problem.startsWith('latin-amount');

void main() {
  if (!_on) {
    test('ds2 xl sweep (DS2_XL=1 only)', () {}, skip: true);
    return;
  }
  final knownFile = File('test/ds2_xl_known.json');
  final bootstrap = !knownFile.existsSync();
  final known = bootstrap
      ? <String>{}
      : (jsonDecode(knownFile.readAsStringSync()) as List).cast<String>().toSet();

  setUpAll(() async {
    await gallerySetUpAll();
    Directory(_dir).createSync(recursive: true);
  });
  setUp(() => FakeApi.planSlug = 'premium');

  final specs = gallerySpecs();
  for (final name in specs.keys) {
    if (_frozenHome(name) || name.endsWith('_menu')) continue;
    for (final lang in ['bn', 'en']) {
      testWidgets('xl2 $name $lang', (tester) async {
        DsPerf.debugLite = true; // the cheap look: layout is what we check
        addTearDown(() => DsPerf.debugLite = null);
        final spec = specs[name]!;
        final problems = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => problems.add('error: ${d.exceptionAsString().split('\n').first}');
        try {
          await galleryPump(tester, name, lang, Brightness.light, spec.build(lang), spec.mode,
              key: GlobalKey(), textScale: 2.0);
          final ex = tester.takeException();
          if (ex != null) problems.add('exception: ${'$ex'.split('\n').first}');
          for (final c in _cutKinds(tester)) {
            problems.add(c);
          }
          // lead 17 Nov: a Taka amount on a Bangla screen uses Bangla digits
          if (lang == 'bn') {
            final latinTaka = RegExp('\u09F3\\s?-?[0-9]');
            for (final e in find.byType(RichText).evaluate()) {
              final txt = (e.widget as RichText).text.toPlainText();
              if (latinTaka.hasMatch(txt)) {
                problems.add('latin-amount: ${txt.length > 60 ? txt.substring(0, 60) : txt}');
              }
            }
          }
        } finally {
          FlutterError.onError = old;
        }
        // drain slow fake calls (the *_loading specs) so no timer is pending
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        if (problems.isNotEmpty) {
          File('$_dir/${name}_$lang.txt').writeAsStringSync(problems.join('\n'));
        }
        if (!bootstrap && !known.contains(name)) {
          expect(problems.where(_gates).toList(), isEmpty, reason: '$name ($lang) at 2.0x font');
        }
      });
    }
  }
}
