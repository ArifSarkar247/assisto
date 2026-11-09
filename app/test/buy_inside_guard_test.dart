// buyinside CI GUARD (owner add-on 10 Nov 00:52):
//  1. every paid feature (a plan or credits unlock it) has an in-place buy
//     entry in its own screen — kPaidFeatures[key].entry must really call a
//     buy screen;
//  2. the app list and the backend inventory (core/logic/paid_gates.py,
//     which its own test ties to every 402 gate in the server code) are the
//     SAME keys — a new gated feature cannot ship without a buy entry;
//  3. FREE ZONE fence: never any buy button, paywall or limit message on
//     SOS, Emergency, Safe Journey core, Family Care core, Care Call free
//     schedules, blood donor or Quran.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/plans_v2/buy_inside.dart';

/// A call that opens a buy screen (or IS the plan's own buy screen).
final _buyCall = RegExp(r'BuyInside\.(open|handle)\(|UpgradeSheet\.(show|handle)\(|'
    r'CreditsOut\.offer\(|PaywallSheet\.show\(|CctvLockedSheet\.show\(|'
    r'ProbashiBuyer|showSafeCreditsOutSheet\(');

/// Anything that sells or limits: buy screens, plan pages, upgrade / paywall
/// / credits copy keys.
final _sellsOrLimits = RegExp(r'BuyInside\.|UpgradeSheet|CreditsOut|PaywallSheet|'
    r'PlansScreen|SafePlansScreen|CctvPlanScreen|CctvLockedSheet|CheckoutSheet|'
    r'PlanPriceButton|RewardedAdSheet|showSafeCreditsOutSheet|'
    r'\b(t|tr|l|loc)\.(pv2|p2Pay|credout|bi[A-Z]|cplBuy|cplStartTrial)');

/// FREE ZONE: files and folders (relative to lib/).
const _freeZone = [
  // SOS
  'family_sos/', 'screens/voice_sos_screen.dart', 'screens/sos_triggers_screen.dart',
  'screens/journey_sos_screen.dart', 'services/sos_ladder.dart',
  'services/sos_trigger_settings.dart',
  // Emergency
  'screens/emergency_screen.dart', 'screens/emergency_hub_screen.dart',
  'widgets/emergency_', 'nearby/emergency_numbers',
  // Safe Journey core
  'screens/safe_journey/', 'screens/journey_', 'screens/guardian_journey_screen.dart',
  'widgets/journey_', 'services/journey_tracker.dart',
  // Family Care core
  'screens/family_screen.dart', 'screens/family_alerts_screen.dart', 'widgets/fam_',
  // Care Call free schedules (the paid EXTRA schedule lives in carecall_new_screen)
  'carecall/carecall_screen.dart', 'carecall/carecall_ring_screen.dart',
  'carecall/carecall_alarms.dart',
  // blood donor
  'screens/blood/', 'blood_panel_api.dart',
  // Quran
  'screens/quran_screen.dart', 'quran/', 'quran_learn/',
];

Iterable<File> _dart(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _rel(File f) {
  final p = f.path.replaceAll('\\', '/');
  final i = p.indexOf('lib/');
  return i < 0 ? p : p.substring(i + 4);
}

void main() {
  test('every paid feature has an in-place buy entry in its own screen', () {
    final missing = <String>[];
    for (final f in kPaidFeatures.values) {
      final file = File('lib/${f.entry}');
      if (!file.existsSync()) {
        missing.add('${f.key}: ${f.entry} does not exist');
        continue;
      }
      if (!_buyCall.hasMatch(file.readAsStringSync())) {
        missing.add('${f.key}: no buy call in ${f.entry}');
      }
    }
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  test('app buy entries == backend paid-gate inventory (no feature missed)', () {
    final py = File('../backend/core/logic/paid_gates.py');
    if (!py.existsSync()) {
      markTestSkipped('backend not checked out next to app/');
      return;
    }
    final src = py.readAsStringSync();
    final start = src.indexOf('PAID_GATES = {');
    final end = src.indexOf('\n}\n', start);
    final backend = RegExp(r'^    "([a-z0-9_]+)": \{"unlock"', multiLine: true)
        .allMatches(src.substring(start, end))
        .map((m) => m.group(1)!)
        .toSet();
    final app = kPaidFeatures.keys.toSet();
    expect(backend.difference(app), isEmpty,
        reason: 'gated on the server, no buy entry in the app');
    expect(app.difference(backend), isEmpty,
        reason: 'buy entry for a feature the server does not gate');
  });

  test('FREE ZONE: no buy button, paywall or limit message on safety screens', () {
    final hits = <String>[];
    var scanned = 0;
    for (final f in _dart('lib')) {
      final rel = _rel(f);
      if (!_freeZone.any((z) => rel.startsWith(z))) continue;
      scanned++;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//') || l.startsWith('///')) continue;
        if (_sellsOrLimits.hasMatch(l)) hits.add('$rel:${i + 1}: $l');
      }
    }
    expect(scanned, greaterThan(30), reason: 'the fence must really see the files');
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('no paid feature points INTO the free zone', () {
    for (final f in kPaidFeatures.values) {
      expect(_freeZone.any((z) => f.entry.startsWith(z)), isFalse, reason: f.key);
    }
  });
}
