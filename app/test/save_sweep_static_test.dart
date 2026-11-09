// savesweep CI GUARD (owner P0, 10 Nov): no silent Save anywhere.
//
// Fails the build when app code
//  1. parses a text field's text with a raw int/double/num.(try)parse
//     (Bangla keyboard digits then become null -> the save silently returns;
//     the owner's Family accounting bug). Use lib/widgets/num_input.dart:
//     parseNumInput / parseIntInput / takaToPoishaInput.
//  2. uses FilteringTextInputFormatter.digitsOnly or a [0-9...] allow-list
//     without LatinDigitsFormatter first (Bangla digits are dropped: the
//     field stays empty and Save looks dead).
//  3. swallows the error of a SAVE call (createItem/updateItem/deleteItem or
//     an api.*Add/Create/Save/Update/Delete call) in an empty `catch {}`
//     with no comment. A deliberate best-effort catch must say why in a
//     comment on the same line.
//  4. builds a showAppSheet with the old double keyboard padding helper
//     (the builder must run below AppSheetInsets).
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

final _call = RegExp(r'\b(int|double|num)\.(tryParse|parse)\(');
final _write = RegExp(r'\b(createItem|updateItem|deleteItem)\(|'
    r'\bapi\.\w*(Add|Create|Save|Update|Delete|Remove)\w*\(|'
    r'\b_api\.\w*(Add|Create|Save|Update|Delete|Remove)\w*\(');
final _try = RegExp(r'\btry\s*\{');
final _emptyCatch = RegExp(
    r'^\s*(on \w+\s*)?catch\s*\(\w+(,\s*\w+)?\)\s*\{\s*\}(?![ \t]*//)');

int _argEnd(String s, int i) {
  var depth = 1;
  while (i < s.length) {
    final c = s[i];
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return i;
    i++;
  }
  return -1;
}

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'));

int _line(String s, int off) => '\n'.allMatches(s.substring(0, off)).length + 1;

void main() {
  test('number fields use the shared Bangla+English parser', () {
    final bad = <String>[];
    for (final f in _dartFiles()) {
      if (f.path.endsWith('widgets/num_input.dart')) continue;
      final s = f.readAsStringSync();
      for (final m in _call.allMatches(s)) {
        final e = _argEnd(s, m.end);
        if (e < 0) continue;
        final arg = s.substring(m.end, e);
        if (arg.contains('.text')) {
          bad.add('${f.path}:${_line(s, m.start)}  ${m.group(0)}$arg)');
        }
      }
    }
    expect(bad, isEmpty,
        reason: 'parse user-typed numbers with parseNumInput/parseIntInput '
            '(lib/widgets/num_input.dart) so Bangla digits work:\n${bad.join('\n')}');
  });

  test('digit-only fields accept Bangla digits (LatinDigitsFormatter first)', () {
    final bad = <String>[];
    final filt = RegExp(r"FilteringTextInputFormatter\.(digitsOnly|allow\(RegExp\(r?'\[0-9)");
    for (final f in _dartFiles()) {
      if (f.path.endsWith('widgets/num_input.dart')) continue;
      final s = f.readAsStringSync();
      for (final m in filt.allMatches(s)) {
        final before = s.substring(m.start > 120 ? m.start - 120 : 0, m.start);
        final after = s.substring(m.start, math.min(m.start + 80, s.length));
        if (before.contains('LatinDigitsFormatter()')) continue;
        if (after.contains(r'০')) continue; // allow-list already has Bangla
        bad.add('${f.path}:${_line(s, m.start)}');
      }
    }
    expect(bad, isEmpty,
        reason: 'put `const LatinDigitsFormatter()` before the digits filter:\n'
            '${bad.join('\n')}');
  });

  test('no save call swallowed by an empty catch', () {
    final bad = <String>[];
    for (final f in _dartFiles()) {
      final s = f.readAsStringSync();
      for (final m in _try.allMatches(s)) {
        var i = m.end, d = 1;
        while (i < s.length && d > 0) {
          if (s[i] == '{') d++;
          if (s[i] == '}') d--;
          i++;
        }
        final body = s.substring(m.end, i - 1);
        final rest = s.substring(i, math.min(i + 120, s.length));
        if (_emptyCatch.hasMatch(rest) && _write.hasMatch(body)) {
          bad.add('${f.path}:${_line(s, m.start)}');
        }
      }
    }
    expect(bad, isEmpty,
        reason: 'a failed save must show a bn/en error with Retry (or say in a '
            'same-line comment why it is best-effort):\n${bad.join('\n')}');
  });

  test('showAppSheet builders run below AppSheetInsets', () {
    final s = File('lib/widgets/app_sheet.dart').readAsStringSync();
    expect(s.contains('AppSheetInsets(child: Builder(builder: builder))'), isTrue,
        reason: 'a sheet builder that pads by MediaQuery.of(ctx).viewInsets '
            'would pad the keyboard twice -> Save drawn but not tappable');
  });
}
