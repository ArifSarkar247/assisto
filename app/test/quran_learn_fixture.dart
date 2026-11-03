// quranread: the REAL bundled Tanzil Uthmani file, read synchronously for
// tests and the screenshot gallery (no invented Quran text).
import 'dart:convert';
import 'dart:io';

import 'package:assisto/l10n/quran_learn_content.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/uthmani_text.dart';

UthmaniText? _cached;

UthmaniText realUthmani() => _cached ??= UthmaniText.parse(utf8.decode(
    gzip.decode(File('assets/quran/quran-uthmani.txt.gz').readAsBytesSync())));

/// Make UthmaniText.load() return the real data immediately.
void preloadRealUthmani() => UthmaniText.debugPreload(realUthmani());

/// Gallery progress: stage 1 lesson 1 learned + 3 items of lesson 2, today 6
/// of 10, practised yesterday too (a 2-day streak). A learner's state, not
/// content - every lesson shown is the real bundled lesson.
QlProgress qlShotProgress() {
  final now = DateTime.now();
  final l1 = kQlStages[0].lessons[0].items.map((i) => i.id);
  final l2 = kQlStages[0].lessons[1].items.take(3).map((i) => i.id);
  return QlProgress(
    learned: {...l1, ...l2},
    days: {
      QlProgress.dayKey(now.subtract(const Duration(days: 1))): 4,
      QlProgress.dayKey(now): 6,
    },
    lastLesson: kQlStages[0].lessons[1].id,
  );
}
