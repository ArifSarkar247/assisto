import 'dart:convert';

/// sec_engine.dart — on-device Dart mirror of
/// `backend/core/logic/security_checkup.py` (the DIGITAL SECURITY CHECK-UP
/// scorer, #198, SPEC v2.1 §20).
///
/// It is a PURE DETERMINISTIC scorer: identical answers always give an identical
/// score, verdict and weak-area order, matching the Python source of truth
/// semantics-for-semantics. No network, no AI, no device probing.
///
/// HONEST BY CONSTRUCTION: the check-up is entirely SELF-REPORTED. This code
/// reads NO device/account state and verifies nothing — a "done" item means the
/// user said so. An unanswered item counts as NOT done (we never flatter). The
/// UI states this plainly.

/// One security practice. [weight] is a fixed integer reflecting how much the
/// practice reduces real risk; [id] keys both the ARB label/tip and the stored
/// answer. ORDER of [kSecItems] is load-bearing (stable done/weak lists).
class SecItem {
  final String id;
  final int weight;
  final String category; // device | money | accounts | data | awareness | privacy
  const SecItem(this.id, this.weight, this.category);
}

/// Kept in lockstep with `security_checkup.py::ITEMS` (ids, weights, order).
const List<SecItem> kSecItems = [
  SecItem('screen_lock', 5, 'device'),
  SecItem('app_lock', 3, 'device'),
  SecItem('wallet_pin', 5, 'money'),
  SecItem('two_factor', 5, 'accounts'),
  SecItem('strong_passwords', 3, 'accounts'),
  SecItem('backup_enabled', 2, 'data'),
  SecItem('scam_awareness', 2, 'awareness'),
  SecItem('permissions_review', 1, 'privacy'),
];

final List<String> kSecItemIds = kSecItems.map((e) => e.id).toList();
final Map<String, int> kSecWeights = {for (final i in kSecItems) i.id: i.weight};
final int kSecMaxScore =
    kSecItems.fold<int>(0, (sum, i) => sum + i.weight);

/// Grade thresholds on the integer percentage, checked high→low. Mirrors
/// `security_checkup.py::GRADES`. Deliberately conservative.
const List<MapEntry<String, int>> _kGrades = [
  MapEntry('strong', 85),
  MapEntry('good', 65),
  MapEntry('fair', 40),
  MapEntry('at_risk', 0),
];

/// Map an integer percentage to a verdict key. Deterministic, total.
String gradeFor(int percent) {
  final p = percent.clamp(0, 100);
  for (final g in _kGrades) {
    if (p >= g.value) return g.key;
  }
  return 'at_risk';
}

/// The computed check-up result. Mirrors `security_checkup.py::score`.
class SecScore {
  final int earned;
  final int max;
  final int percent;
  final String grade;
  final List<String> done;
  final List<String> weak; // not-done, worst-weight first
  const SecScore({
    required this.earned,
    required this.max,
    required this.percent,
    required this.grade,
    required this.done,
    required this.weak,
  });

  int get doneCount => done.length;
  int get totalCount => kSecItemIds.length;

  /// Always true — this check-up reads nothing and verifies nothing.
  bool get selfReported => true;
}

/// A practice is done ONLY when its answer is exactly `true`.
bool secIsDone(Map<String, bool> answers, String id) => answers[id] == true;

/// Pure deterministic score of the self-reported checklist. Unknown keys in
/// [answers] are ignored; any item not present (or not exactly true) is NOT done.
SecScore scoreSecurity(Map<String, bool> answers) {
  final done = kSecItemIds.where((id) => secIsDone(answers, id)).toList();
  final earned =
      done.fold<int>(0, (sum, id) => sum + (kSecWeights[id] ?? 0));
  final percent =
      kSecMaxScore == 0 ? 0 : (earned * 100 / kSecMaxScore).round();
  final notDone =
      kSecItemIds.where((id) => !done.contains(id)).toList();
  // worst (heaviest) weight first; ties keep kSecItems order.
  notDone.sort((a, b) {
    final byWeight = (kSecWeights[b] ?? 0).compareTo(kSecWeights[a] ?? 0);
    if (byWeight != 0) return byWeight;
    return kSecItemIds.indexOf(a).compareTo(kSecItemIds.indexOf(b));
  });
  return SecScore(
    earned: earned,
    max: kSecMaxScore,
    percent: percent,
    grade: gradeFor(percent),
    done: done,
    weak: notDone,
  );
}

/// Clean {id: bool} map keyed only by known items — the exact shape persisted to
/// the 'security/checklist' row. Drops unknown keys, coerces to strict bool.
Map<String, bool> secSanitize(Map<String, bool> answers) =>
    {for (final id in kSecItemIds) id: answers[id] == true};

/// Local persistence for the checklist. Primary store is the generic REST
/// collection 'security/checklist' (a single row, see sec_store below); this
/// JSON codec is shared by that row's `data` payload. Row shape:
///   { "id": <int>, "answers": {"screen_lock": true, ...}, "updated_at": "<iso>" }
Map<String, bool> secAnswersFromRow(Map<String, dynamic> row) {
  final raw = row['answers'];
  final map = <String, bool>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (k is String) map[k] = v == true;
    });
  }
  return secSanitize(map);
}

String secEncodeAnswers(Map<String, bool> answers) =>
    jsonEncode(secSanitize(answers));
