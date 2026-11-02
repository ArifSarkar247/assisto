// launchsweep (2 Nov) — GUARD: no ASCII "0/120" counters on Bangla screens.
//
// Flutter's default TextField counter is '$current/$max' in ASCII digits.
// Every TextField / TextFormField in lib/ that sets `maxLength:` must also set
// `buildCounter: localCounter` (lib/widgets/local_counter.dart: Bangla digits
// in Bangla, Flutter's own TalkBack text) — or hide the counter with
// `counterText: ''` / its own `buildCounter`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/widgets/local_counter.dart';

/// The constructor name whose argument list contains offset [at].
String? _enclosingCall(String src, int at) {
  var depth = 0;
  final from = at - 4000 < 0 ? 0 : at - 4000;
  for (var j = at - 1; j >= from; j--) {
    final c = src[j];
    if (c == ')') depth++;
    if (c == '(') {
      if (depth == 0) {
        final m = RegExp(r'([A-Za-z_][A-Za-z0-9_.]*)\s*$').firstMatch(src.substring(from, j));
        return m?.group(1);
      }
      depth--;
    }
  }
  return null;
}

/// The argument list (text between the parens) of the call opened before [at].
String _callArgs(String src, int at) {
  var depth = 0, start = at;
  for (var j = at - 1; j >= 0; j--) {
    if (src[j] == ')') depth++;
    if (src[j] == '(') {
      if (depth == 0) { start = j; break; }
      depth--;
    }
  }
  depth = 0;
  for (var k = start; k < src.length; k++) {
    if (src[k] == '(') depth++;
    if (src[k] == ')') {
      depth--;
      if (depth == 0) return src.substring(start, k);
    }
  }
  return src.substring(start);
}

void main() {
  test('every TextField with maxLength shows its counter in local digits', () {
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart') || f.path.contains('l10n')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\n\s+maxLength: ').allMatches(src)) {
        final call = _enclosingCall(src, m.start + 1);
        if (call != 'TextField' && call != 'TextFormField') continue;
        final args = _callArgs(src, m.start + 1);
        if (args.contains('buildCounter') || args.contains('counterText')) continue;
        final line = '\n'.allMatches(src.substring(0, m.start + 1)).length + 1;
        bad.add('${f.path}:$line');
      }
    }
    expect(bad, isEmpty,
        reason: 'Add `buildCounter: localCounter` (widgets/local_counter.dart) — '
            'the default counter shows ASCII "0/120" on Bangla screens.');
  });

  testWidgets('localCounter: Bangla digits in bn, ASCII in en', (tester) async {
    for (final (lang, want) in [('bn', '৩/১২০'), ('en', '3/120')]) {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        supportedLocales: const [Locale('en'), Locale('bn')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: TextField(
            controller: TextEditingController(text: 'abc'),
            maxLength: 120,
            buildCounter: localCounter,
          ),
        ),
      ));
      expect(find.text(want), findsOneWidget, reason: lang);
    }
  });
}
