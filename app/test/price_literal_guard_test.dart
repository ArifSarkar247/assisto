// plans-credits (board row 7: "one screen shows one price, another a
// different one"): every price the app shows comes from the server
// (PricingConfig / the CCTV plan / Google Play's own price). GUARD:
//  1. no Dart string literal in lib/ carries a typed taka amount
//     ("৳500", "Tk 199", "BDT 99") — ৳0 (an empty balance) is fine;
//  2. no billing / plans / credits file falls back to a typed price
//     (`?? 500`, `return 449;`);
//  3. an ARB string with a typed taka amount is used by the code only when it
//     is a user-data EXAMPLE (an input hint like "500 taka groceries"), never
//     an Assisto price (the old biCctvPlanLine "From ৳500 a month").
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _nz = '1-9১-৯'; // a non-zero first digit (Latin or Bangla)
final _taka = RegExp('৳\\s?[$_nz]|\\bTk\\.?\\s?[1-9]|\\bBDT\\s?[1-9]');
final _takaWord = RegExp('[$_nz][0-9০-৯,]*\\s?(taka|টাকা)');
final _fallback = RegExp(r'\?\?\s*[1-9][0-9]+\b|return\s+[1-9][0-9]+;');

/// ARB keys that hold a sample of the USER's own money (input hints and
/// voice examples) — not an Assisto price. A new key here needs a reason.
const _exampleKeys = {
  'bizVoiceEntryHint', 'clnCallNoteHint', 'lg2CostExplain', 'mvoiceExample1',
  'mvoiceExample2', 'n500TakaFoodExpenseRemind', 'suggestionExpense',
  'supFieldPriceNoteHelp', 'vaExExpense',
};

const _billingFiles = [
  'lib/billing', 'lib/payments', 'lib/plans_v2', 'lib/safe_plans',
  'lib/screens/plans_screen.dart', 'lib/screens/credits_screen.dart',
  'lib/widgets/paywall_sheet.dart',
];

Iterable<File> _dart(String path) sync* {
  final t = FileSystemEntity.typeSync(path);
  if (t == FileSystemEntityType.file) {
    yield File(path);
  } else if (t == FileSystemEntityType.directory) {
    yield* Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
  }
}

/// The line without a trailing `// comment` (only " // " — never a URL).
String _code(String line) {
  final i = line.indexOf(' // ');
  return i < 0 ? line : line.substring(0, i);
}

bool _comment(String line) => line.trimLeft().startsWith('//');

void main() {
  test('no typed taka price in Dart string literals', () {
    final hits = <String>[];
    for (final f in _dart('lib')) {
      if (f.path.contains('/l10n/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_comment(lines[i])) continue;
        final c = _code(lines[i]);
        if (_taka.hasMatch(c) || _takaWord.hasMatch(c)) hits.add('${f.path}:${i + 1}: ${c.trim()}');
      }
    }
    expect(hits, isEmpty,
        reason: 'typed prices — show the server\'s number instead:\n${hits.join('\n')}');
  });

  test('billing / plans code never falls back to a typed price', () {
    final hits = <String>[];
    for (final p in _billingFiles) {
      for (final f in _dart(p)) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_comment(lines[i])) continue;
          final c = _code(lines[i]);
          if (c.contains('status')) continue; // an HTTP status code, not money
          if (_fallback.hasMatch(c)) hits.add('${f.path}:${i + 1}: ${c.trim()}');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('ARB strings with a typed taka amount are only user-data examples', () {
    final code = StringBuffer();
    for (final f in _dart('lib')) {
      if (!f.path.contains('/l10n/')) code.writeln(f.readAsStringSync());
    }
    final all = code.toString();
    final bad = <String>[];
    for (final lang in ['en', 'bn']) {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>;
      arb.forEach((k, v) {
        if (k.startsWith('@') || v is! String || _exampleKeys.contains(k)) return;
        if (!_taka.hasMatch(v) && !_takaWord.hasMatch(v)) return;
        // a legacy key nobody reads any more is harmless (ARB is append-only)
        if (RegExp('\\.$k\\b').hasMatch(all)) bad.add('$lang $k: $v');
      });
    }
    expect(bad, isEmpty,
        reason: 'an ARB string with a typed price is shown by the app — pass the '
            'server\'s number as a placeholder instead:\n${bad.join('\n')}');
  });

  test('the guard patterns catch a typed price and allow ৳0', () {
    for (final s in ['৳500 a month', 'মাসে ৳৪৪৯', 'Tk 199', '500 taka']) {
      expect(_taka.hasMatch(s) || _takaWord.hasMatch(s), isTrue, reason: s);
    }
    expect(_taka.hasMatch("fallback: '৳0'"), isFalse);
    expect(_fallback.hasMatch('?.toInt() ?? 500;'), isTrue);
  });
}
