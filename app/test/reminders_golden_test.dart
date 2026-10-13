import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/widgets/reminders_nlp.dart';

/// Python <-> Dart parity lock. Loads the SAME shared fixtures the backend test
/// (reminders_tests_snippets.test_golden) asserts against, runs the Dart mirror
/// parser (reminders_nlp.dart), and checks datetime / recurrence_rule /
/// clean_title all match. If the two parsers drift, this test fails.
///
/// The golden file lives in the backend so there is one source of truth; the
/// test reads it via a path relative to the Flutter project (app/) up one level.

String _goldenPath() {
  for (final p in [
    '../backend/core/logic/reminders_golden.json',
    'backend/core/logic/reminders_golden.json',
    '/home/ubuntu/assisto/backend/core/logic/reminders_golden.json',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return '../backend/core/logic/reminders_golden.json';
}

/// Dart local datetime -> 'YYYY-MM-DDTHH:MM:SS' (strip millis/micros) to match
/// the Python isoformat in the fixtures.
String? _iso(DateTime? d) {
  if (d == null) return null;
  final s = d.toIso8601String();
  final dot = s.indexOf('.');
  return dot == -1 ? s : s.substring(0, dot);
}

void main() {
  test('reminders_nlp Dart mirror matches shared golden fixtures', () {
    final file = File(_goldenPath());
    expect(file.existsSync(), isTrue,
        reason: 'reminders_golden.json not found at ${file.path}');
    final cases = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);

    final failures = <String>[];
    for (final c in cases) {
      final input = c['input'] as String;
      final now = DateTime.parse(c['now'] as String);
      final expected = c['expected'] as Map<String, dynamic>;

      final parsed = parseReminder(input, now: now);

      final gotDt = _iso(parsed.dateTime);
      final wantDt = expected['datetime'] as String?;
      if (gotDt != wantDt) {
        failures.add('[$input] datetime: got $gotDt, want $wantDt');
      }

      final gotRule = parsed.recurrence?.toJson();
      final wantRule = expected['recurrence_rule'] as Map<String, dynamic>?;
      if (!_ruleEq(gotRule, wantRule)) {
        failures.add('[$input] recurrence_rule: got $gotRule, want $wantRule');
      }

      final wantTitle = expected['clean_title'] as String?;
      if (wantTitle != null && parsed.cleanTitle != wantTitle) {
        failures
            .add('[$input] clean_title: got "${parsed.cleanTitle}", want "$wantTitle"');
      }
    }

    expect(failures, isEmpty,
        reason: 'Python<->Dart reminder parser drift:\n${failures.join('\n')}');
  });
}

bool _ruleEq(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  for (final k in ['freq', 'interval', 'weekday', 'day_of_month', 'month', 'time']) {
    if (a[k] != b[k]) return false;
  }
  return true;
}
