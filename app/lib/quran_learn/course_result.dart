// quranread -> agent/learncert seam: the Assisto learning certificate reads a
// Quran course result from here.
//
//   final r = await courseResult(kCourseQaida);   // or kCourseNazera
//   if (r != null && r.completed) { /* r.stage, r.date */ }
//
// course:  'quran_qaida'  = stages 1-7 (letters + makhraj ... words)
//          'quran_nazera' = stages 8-9 (ayat + basic tajweed)
// stage:   'completed' when every item of the course is learned, else
//          'stage_<n>' = the highest fully learned stage (n may be 0).
// date:    the day the course was FIRST completed (kept, never moved), or
//          the day of the latest practice while in progress.
//
// RULES for the certificate (owner order 3 Nov): issue only when
// `completed`; wording only "Qaida completed" / "Nazera reading completed";
// never ijazah, never a Qari title; the course is EXPERIMENTAL until a
// qualified Qari reviews the lessons. There is no exam score (the recitation
// helper is not a grade), so `score` stays null.
import 'learn_progress.dart';
import 'qaida_model.dart';

class CourseResult {
  final String course;
  final String stage;
  final DateTime date;
  final int? score;
  const CourseResult(this.course, this.stage, this.date, {this.score});

  bool get completed => stage == 'completed';

  Map<String, dynamic> toJson() => {
        'course': course,
        'stage': stage,
        'date': QlProgress.dayKey(date),
        if (score != null) 'score': score,
      };
}

/// The learner's result for [course] ('quran_qaida' | 'quran_nazera'), or
/// null for another course or when nothing has been practised yet.
Future<CourseResult?> courseResult(String course, {QlProgress? progress}) async {
  if (course != kCourseQaida && course != kCourseNazera) return null;
  final p = progress ?? await QlProgressStore.load();
  return resultOf(p, course);
}

/// Pure form of [courseResult] (tests).
CourseResult? resultOf(QlProgress p, String course) {
  final doneOn = p.done[course];
  if (doneOn != null) {
    final d = DateTime.tryParse(doneOn);
    if (d != null) return CourseResult(course, 'completed', d);
  }
  if (p.days.isEmpty) return null;
  final last = (p.days.keys.toList()..sort()).last;
  final d = DateTime.tryParse(last);
  if (d == null) return null;
  return CourseResult(course, 'stage_${p.courseStage(course)}', d);
}
