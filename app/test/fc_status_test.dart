// fcscreen — the Dart status rules match the server rules case by case
// (one JSON table: backend/core/logic/fc_status_cases.json) — ZERO FALSE GREEN.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/family_v3/fc_status.dart';

void main() {
  final data = jsonDecode(File('../backend/core/logic/fc_status_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final now = fcParseTs(data['now'])!;

  group('member status (shared case table)', () {
    for (final c in (data['cases'] as List).cast<Map>()) {
      test('${c['id']}', () {
        final got = fcMemberStatus(c['brain'] as Map, now, c['flags'] as Map);
        expect(got.state, c['state'], reason: '${c['id']}');
        expect(got.reason, c['reason'], reason: '${c['id']}');
        if (c.containsKey('fresh_until')) {
          expect(got.freshUntilIso, c['fresh_until'], reason: '${c['id']}');
        }
      });
    }
  });

  group('family line (shared case table)', () {
    for (final c in (data['lines'] as List).cast<Map>()) {
      test('${c['id']}', () {
        final got = fcFamilyLine((c['rows'] as List).cast<Map>());
        expect(got.state, c['state']);
        if (c.containsKey('name')) expect(got.name, c['name']);
      });
    }
  });

  test('never green without fresh data (fuzz)', () {
    for (final b in [null, 0, 5, 50, 100, 'x']) {
      for (final net in ['', 'none', 'wifi']) {
        for (final iv in [null, 0, 60, 3600, 1000000000]) {
          final brain = {'battery': b, 'net': net, 'interval_s': iv};
          expect(fcMemberStatus(brain, now).isGreen, isFalse);
          brain['last_seen'] = now.subtract(const Duration(days: 2)).toIso8601String();
          expect(fcMemberStatus(brain, now).isGreen, isFalse);
        }
      }
    }
  });

  test('a server green turns gray on the phone when its time runs out', () {
    final seen = now.subtract(const Duration(minutes: 10));
    final m = {
      'brain': {'last_seen': seen.toIso8601String(), 'battery': 80},
      'status': {
        'state': 'ok',
        'reason': 'ok',
        'fresh_until': seen.add(const Duration(hours: 3)).toIso8601String()
      },
    };
    expect(fcRecheck(m, now).state, 'ok');
    expect(fcRecheck(m, now.add(const Duration(hours: 2, minutes: 49))).state, 'ok');
    final later = fcRecheck(m, now.add(const Duration(hours: 2, minutes: 51)));
    expect(later.state, 'stale');
    expect(later.reason, 'background_killed');
  });

  test('a server gray is never upgraded by the phone', () {
    final m = {
      'brain': {'last_seen': now.toIso8601String(), 'battery': 80},
      'status': {'state': 'stale', 'reason': 'battery_off', 'fresh_until': null},
    };
    expect(fcRecheck(m, now).state, 'stale');
    final p = {
      'brain': {'last_seen': now.toIso8601String()},
      'status': {'state': 'paused', 'reason': 'paused'},
    };
    expect(fcRecheck(p, now).state, 'paused');
  });
}
