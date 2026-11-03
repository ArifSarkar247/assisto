// quranread: learner progress for "Learn to read Quran" - which items the
// learner marked "learned", practice per day (daily goal + streak), the last
// lesson, and the date each course (Qaida / Nazera) was first completed.
// Kept on THIS phone only (SharedPreferences, one JSON value); honest limit in
// the feature card: no backup yet.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/quran_learn_content.dart';
import 'qaida_model.dart';

class QlProgress {
  static const prefsKey = 'ql_progress_v1';
  static const goals = [5, 10, 20];
  static const defaultGoal = 10;

  final Set<String> learned;
  final Map<String, int> days; // 'yyyy-mm-dd' -> items learned that day
  int goal;
  String? lastLesson;
  final Map<String, String> done; // course -> 'yyyy-mm-dd' first completed
  final Map<String, int> best; // item -> best helper score (0-100)

  QlProgress({
    Set<String>? learned,
    Map<String, int>? days,
    this.goal = defaultGoal,
    this.lastLesson,
    Map<String, String>? done,
    Map<String, int>? best,
  })  : learned = learned ?? <String>{},
        days = days ?? <String, int>{},
        done = done ?? <String, String>{},
        best = best ?? <String, int>{};

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  factory QlProgress.fromJson(Map<String, dynamic> j) {
    final g = j['goal'];
    return QlProgress(
      learned: {for (final e in (j['learned'] as List? ?? const [])) '$e'},
      days: {
        for (final e in (j['days'] as Map? ?? const {}).entries)
          '${e.key}': (e.value as num?)?.toInt() ?? 0
      },
      goal: g is num && goals.contains(g.toInt()) ? g.toInt() : defaultGoal,
      lastLesson: j['last'] as String?,
      done: {
        for (final e in (j['done'] as Map? ?? const {}).entries)
          '${e.key}': '${e.value}'
      },
      best: {
        for (final e in (j['best'] as Map? ?? const {}).entries)
          '${e.key}': (e.value as num?)?.toInt() ?? 0
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'learned': learned.toList()..sort(),
        'days': days,
        'goal': goal,
        if (lastLesson != null) 'last': lastLesson,
        'done': done,
        'best': best,
      };

  int today(DateTime now) => days[dayKey(now)] ?? 0;

  /// Consecutive days with any practice, ending today (or yesterday when
  /// nothing was practised yet today - the streak is not lost until tonight).
  int streak(DateTime now) {
    var d = DateTime(now.year, now.month, now.day);
    if ((days[dayKey(d)] ?? 0) == 0) d = d.subtract(const Duration(days: 1));
    var n = 0;
    while ((days[dayKey(d)] ?? 0) > 0) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  /// Marks / unmarks [itemId]. A new mark counts towards today's goal and may
  /// complete a course (its date is kept once, never moved later).
  void toggle(String itemId, DateTime now, {List<QlStage> stages = kQlStages}) {
    if (learned.remove(itemId)) return;
    learned.add(itemId);
    final k = dayKey(now);
    days[k] = (days[k] ?? 0) + 1;
    for (final c in const [kCourseQaida, kCourseNazera]) {
      if (!done.containsKey(c) && courseComplete(c, stages)) done[c] = k;
    }
  }

  void recordScore(String itemId, int score) {
    if (score > (best[itemId] ?? -1)) best[itemId] = score < 0 ? 0 : (score > 100 ? 100 : score);
  }

  int learnedIn(QlLesson l) => l.items.where((i) => learned.contains(i.id)).length;
  bool lessonDone(QlLesson l) => learnedIn(l) == l.items.length;

  int stageTotal(QlStage s) => s.lessons.fold(0, (a, l) => a + l.items.length);
  int stageLearned(QlStage s) => s.lessons.fold(0, (a, l) => a + learnedIn(l));
  bool stageDone(QlStage s) => stageLearned(s) == stageTotal(s);

  bool courseComplete(String course, [List<QlStage> stages = kQlStages]) {
    final st = stages.where((s) => s.course == course).toList();
    return st.isNotEmpty && st.every(stageDone);
  }

  /// Highest stage number of [course] whose every item is learned (0 = none).
  int courseStage(String course, [List<QlStage> stages = kQlStages]) {
    var n = 0;
    for (final s in stages.where((s) => s.course == course)) {
      if (!stageDone(s)) break;
      n = s.n;
    }
    return n;
  }

  /// The first lesson that still has unlearned items, in course order.
  ({QlStage stage, QlLesson lesson})? nextLesson([List<QlStage> stages = kQlStages]) {
    for (final s in stages) {
      for (final l in s.lessons) {
        if (!lessonDone(l)) return (stage: s, lesson: l);
      }
    }
    return null;
  }
}

class QlProgressStore {
  QlProgressStore._();

  static Future<QlProgress> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(QlProgress.prefsKey);
      if (raw == null || raw.isEmpty) return QlProgress();
      return QlProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return QlProgress(); // corrupt value: start clean rather than crash
    }
  }

  static Future<void> save(QlProgress q) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(QlProgress.prefsKey, jsonEncode(q.toJson()));
    } catch (_) {/* storage full / unavailable: the screen still works */}
  }
}
