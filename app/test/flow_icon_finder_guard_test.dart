// rf1 guard, also on every checks run (the reality.yml analyze step has the
// same rule): emulator flows find controls by Key / tooltip / text, never by
// icon — not by byIcon( and not by a look-alike Icon predicate
// (w is Icon && w.icon == ...). An icon change silently breaks such flows.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _iconFinder = RegExp(r'byIcon\(|\bis Icon\b|\.icon ==|is IconButton && .*\.icon\b');

void main() {
  test('no icon finders in integration_test/flows', () {
    final bad = <String>[];
    for (final f in Directory('integration_test/flows').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_iconFinder.hasMatch(lines[i])) bad.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(bad, isEmpty, reason: 'find controls by Key / tooltip / text, not by icon');
  });

  test('the pattern catches byIcon and Icon predicates, not Keys', () {
    expect(_iconFinder.hasMatch("find.byIcon(Icons.send)"), isTrue);
    expect(_iconFinder.hasMatch("find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.x)"), isTrue);
    expect(_iconFinder.hasMatch("find.byKey(const ValueKey('fcg-line-paused'))"), isFalse);
    expect(_iconFinder.hasMatch("find.byTooltip(f.t.msgrChatMore)"), isFalse);
  });
}
