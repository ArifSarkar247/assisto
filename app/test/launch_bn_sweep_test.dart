// launchsweep (2 Nov) — LAUNCH BANGLA + BIG-FONT GUARD for every screen that
// shipped on 2 Nov (owner launches ALL features on 8 Nov).
//
// For each gallery spec (gallerySpecs() in screenshots_test.dart) whose name
// starts with one of [_launchPrefixes] this test pumps the screen exactly like
// the gallery and fails on:
//   digit     bn UI: a visible text with an ASCII digit 0-9 (owner rule: Bangla
//             digits everywhere in Bangla — money, counts, dates, times, km).
//   english   bn UI: a visible text that is EXACTLY an English app string (an
//             app_en.arb value with no Bangla twin shown) — i.e. a hard-coded
//             or untranslated label leaking into the Bangla screen.
//   overflow  bn AND en at text scale 2.0 (owner rule: 200 % font, 360 dp):
//             any RenderFlex/RenderBox overflow is a clipped label.
//
// New screens are covered automatically: add the gallery spec with one of
// the prefixes below (or add the prefix). A finding fails unless it matches
// the reviewed [_allow] list ("<screen>|<check>|<text in finding>").
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart' show FakeMode;
import 'screenshots_test.dart' as gallery;

/// Gallery spec name prefixes of the 2 Nov launch features.
const _launchPrefixes = <String>[
  'emergency_hub', // emergency hub
  'blood_', // blood donor list / profile / request / share
  'missing_', // missing alert
  'train_', 'dest_alarm', // train tracker + chat + destination alarm
  'journey_', // journey modes
  'chip_', // tracker chip
  'kid_audio', // child emergency audio
  'acct_', // accounting + account modes (acct_mode_*)
  'inv_', // invoices
  'rt_', // CRM automation (retention1)
  'chx_', // channels + communities
  'callpip_', // call PiP / mini tile / call bar
  'bizops_', // biz brief card
];

/// Reviewed exceptions. Keep it tiny and say why.
const Map<String, String> _allow = {
};

final _env = Platform.environment;
final Set<String>? _only = () {
  final o = _env['LAUNCH_ONLY'];
  return (o == null || o.isEmpty) ? null : o.split(',').toSet();
}();

bool _allowed(String screen, String check, String detail) {
  for (final k in _allow.keys) {
    final p = k.split('|');
    final s = p[0];
    final ok = s == '*' || s == screen ||
        (s.endsWith('*') && screen.startsWith(s.substring(0, s.length - 1)));
    if (!ok) continue;
    if (p[1] != '*' && p[1] != check) continue;
    if (detail.contains(p.sublist(2).join('|'))) return true;
  }
  return false;
}

/// English strings of the app (app_en.arb values) that are worth flagging:
/// at least one 3+ letter word, no placeholders, not a brand-only string.
final Set<String> _enStrings = () {
  final out = <String>{};
  try {
    final m = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
    m.forEach((k, v) {
      if ('$k'.startsWith('@') || v is! String) return;
      final s = v.trim();
      if (s.contains('{') || !RegExp(r'[A-Za-z]{3,}').hasMatch(s)) return;
      if (_brandOnly(s)) return;
      out.add(s);
    });
  } catch (_) {}
  return out;
}();

const _brands = {
  'assisto', 'bkash', 'nagad', 'rocket', 'upay', 'whatsapp', 'facebook',
  'messenger', 'google', 'play', 'imo', 'telegram', 'viber', 'youtube', 'sms',
  'otp', 'qr', 'pdf', 'csv', 'excel', 'gps', 'sos', 'ai', 'pip', 'id',
  'lifeassisto.com', 'wi-fi', 'wifi', 'android', 'vat', 'bin', 'tin', 'ok',
};

bool _brandOnly(String s) => s
    .toLowerCase()
    .split(RegExp(r'[\s/·,.:()\-]+'))
    .where((w) => w.isNotEmpty)
    .every(_brands.contains);

/// Visible strings on screen (every paragraph that painted).
List<String> _texts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph || !ro.attached || !ro.hasSize) continue;
    if (ro.size.isEmpty) continue;
    final s = ro.text.toPlainText(includeSemanticsLabels: false).trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

final _ascii = RegExp(r'[0-9]');
// URLs / app links / invite codes are not reading text.
final _urlish = RegExp(r'(https?://|lifeassisto\.com|\.com/|www\.)');

void main() {
  setUpAll(gallery.gallerySetUpAll);
  final specs = gallery.gallerySpecs();
  final names = specs.keys
      .where((n) => _launchPrefixes.any(n.startsWith))
      .where((n) => _only == null || _only!.contains(n))
      .toList();

  test('launch prefixes match gallery specs (guard is not silently empty)', () {
    for (final p in _launchPrefixes) {
      expect(specs.keys.any((n) => n.startsWith(p)), isTrue,
          reason: 'no gallery spec starts with "$p" — the launch sweep would '
              'skip that feature. Add its gallery states or fix the prefix.');
    }
  });

  for (final name in names) {
    final spec = specs[name]!;
    testWidgets('launch bn text $name', (tester) async {
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await gallery.galleryPump(tester, name, 'bn', Brightness.light,
          spec.build('bn'), spec.mode, key: GlobalKey());
      await tester.pump();
      final open = <String>{};
      for (final s in _texts(tester)) {
        final one = s.replaceAll('\n', ' ');
        if (_ascii.hasMatch(one) && !_urlish.hasMatch(one)) {
          final d = 'digit: "$one"';
          if (!_allowed(name, 'digit', d)) open.add(d);
        }
        if (_enStrings.contains(s)) {
          final d = 'english: "$one"';
          if (!_allowed(name, 'english', d)) open.add(d);
        }
      }
      if (spec.mode == FakeMode.slow) {
        await tester.pump(const Duration(milliseconds: 1400));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(open.toList(), isEmpty,
          reason: 'Bangla screen "$name" shows ASCII digits or English app '
              'strings. Use the Bangla-digit helper (localDigits / acctDigits '
              '/ moneyDigits …) and the bn ARB string, or justify in _allow.');
    });
    for (final lang in const ['bn', 'en']) {
      testWidgets('launch 2x font $name $lang', (tester) async {
        final errs = <String>{};
        final orig = FlutterError.onError;
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            errs.add(s.split('\n').first);
          } else {
            orig?.call(d);
          }
        };
        try {
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await gallery.galleryPump(tester, name, lang, Brightness.light,
              spec.build(lang), spec.mode,
              key: GlobalKey(), textScale: 2.0);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          final open = [
            for (final e in errs)
              if (!_allowed(name, 'overflow', e)) e,
          ];
          expect(open, isEmpty,
              reason: 'Overflow on "$name" ($lang) at 200 % font, 360 dp. '
                  'Let the text wrap (Expanded/Flexible, Wrap, maxLines).');
        } finally {
          FlutterError.onError = orig;
        }
      });
    }
  }
}
