/// student_gpa_engine.dart — pure, deterministic STUDENT CORNER math mirrored
/// VERBATIM from backend/core/logic/student_corner.py (#192, §20). No widgets,
/// no I/O, no Bangla literals — the display copy lives in AppLocalizations and
/// the screen renders it. Keeping the math here (not inline) means the live
/// on-device result is identical to the backend and the self-tests.
///
/// GPA scale: UGC Uniform Grading System (Bangladesh 4.00). Documented in the
/// Python module; the table below is the single source for Dart.
library;

class GradeBand {
  final String letter;
  final double point;
  final int minMarks;
  final int maxMarks;
  const GradeBand(this.letter, this.point, this.minMarks, this.maxMarks);

  String get pointDisplay => point.toStringAsFixed(2);
  String get band => letter == 'F' ? '0–$maxMarks' : '$minMarks–$maxMarks';
}

class CourseRow {
  final dynamic id;
  final String title;
  final double credit;
  final String letter;
  final double? point;
  final double contribution;
  final bool graded;
  const CourseRow({
    required this.id,
    required this.title,
    required this.credit,
    required this.letter,
    required this.point,
    required this.contribution,
    required this.graded,
  });

  String get pointDisplay => graded ? point!.toStringAsFixed(2) : '—';
  String get contributionDisplay =>
      graded ? contribution.toStringAsFixed(2) : '—';
}

class CgpaResult {
  final double cgpa;
  final double totalCredits;
  final double gradedCredits;
  final double qualityPoints;
  final String classBand; // resolved by the caller via l10n; here a key
  final List<CourseRow> courses;
  final bool honest; // true = no graded credit yet
  const CgpaResult({
    required this.cgpa,
    required this.totalCredits,
    required this.gradedCredits,
    required this.qualityPoints,
    required this.classBand,
    required this.courses,
    required this.honest,
  });

  String get cgpaDisplay => cgpa.toStringAsFixed(2);
  String get qualityPointsDisplay => qualityPoints.toStringAsFixed(2);
}

class RoutinePeriod {
  final dynamic id;
  final String subject;
  final String room;
  final String start;
  final String end;
  final bool conflict;
  const RoutinePeriod({
    required this.id,
    required this.subject,
    required this.room,
    required this.start,
    required this.end,
    required this.conflict,
  });
}

class RoutineDay {
  final int index;
  final String key;
  final List<RoutinePeriod> periods;
  final bool overlaps;
  const RoutineDay(this.index, this.key, this.periods, this.overlaps);
}

class AssignmentStatus {
  final dynamic id;
  final String state; // done|no_due|overdue|due_today|upcoming
  final int? days; // signed; negative = overdue
  final String? dueDate;
  final bool done;
  final String title;
  final String kind;
  const AssignmentStatus({
    required this.id,
    required this.state,
    required this.days,
    required this.dueDate,
    required this.done,
    required this.title,
    required this.kind,
  });
}

class TrackerBoard {
  final List<AssignmentStatus> all;
  final int overdueCount;
  const TrackerBoard(this.all, this.overdueCount);
}

class GoalProgress {
  final int total;
  final int done;
  final int percent;
  const GoalProgress(this.total, this.done, this.percent);
}

class StudentEngine {
  StudentEngine._();

  // UGC Uniform Grading (Bangladesh 4.00). high→low.
  static const List<GradeBand> scaleRows = [
    GradeBand('A+', 4.00, 80, 100),
    GradeBand('A', 3.75, 75, 79),
    GradeBand('A-', 3.50, 70, 74),
    GradeBand('B+', 3.25, 65, 69),
    GradeBand('B', 3.00, 60, 64),
    GradeBand('B-', 2.75, 55, 59),
    GradeBand('C+', 2.50, 50, 54),
    GradeBand('C', 2.25, 45, 49),
    GradeBand('D', 2.00, 40, 44),
    GradeBand('F', 0.00, 0, 39),
  ];

  static List<String> get letters =>
      scaleRows.map((b) => b.letter).toList(growable: false);

  static const List<String> dayKeys = [
    'sat', 'sun', 'mon', 'tue', 'wed', 'thu', 'fri'
  ];

  static double? pointForLetterRaw(String? letter) {
    if (letter == null) return null;
    final key = letter.trim().toUpperCase();
    for (final b in scaleRows) {
      if (b.letter == key) return b.point;
    }
    return null;
  }

  static String pointForLetter(String letter) {
    final p = pointForLetterRaw(letter);
    return p == null ? '—' : p.toStringAsFixed(2);
  }

  static String? letterForMarks(num? marks) {
    if (marks == null || marks < 0 || marks > 100) return null;
    for (final b in scaleRows) {
      if (marks >= b.minMarks) return b.letter;
    }
    return 'F';
  }

  // ---- CGPA ----------------------------------------------------------------
  static CgpaResult computeCgpa(List<Map<String, dynamic>> courses) {
    final rows = <CourseRow>[];
    double totalCredits = 0, gradedCredits = 0, quality = 0;
    for (final c in courses) {
      double credit = _num(c['credit']) ?? 0;
      if (credit <= 0) credit = 0;
      final resolved = _coursePoint(c);
      final graded = resolved != null;
      final point = resolved?.$1;
      final letter = resolved?.$2 ?? '';
      final contribution = graded ? _round4(point! * credit) : 0.0;
      if (graded) {
        gradedCredits += credit;
        quality += contribution;
      }
      if (credit > 0) totalCredits += credit;
      rows.add(CourseRow(
        id: c['id'],
        title: (c['title'] ?? '').toString().trim(),
        credit: credit,
        letter: letter,
        point: point,
        contribution: contribution,
        graded: graded,
      ));
    }
    final cgpa = gradedCredits > 0 ? _round4(quality / gradedCredits) : 0.0;
    return CgpaResult(
      cgpa: cgpa,
      totalCredits: _round(totalCredits, 3),
      gradedCredits: _round(gradedCredits, 3),
      qualityPoints: _round4(quality),
      classBand: _classBandKey(cgpa, gradedCredits),
      courses: rows,
      honest: gradedCredits <= 0,
    );
  }

  static (double, String)? _coursePoint(Map<String, dynamic> c) {
    final rawLetter = c['letter'] ?? c['grade'];
    if (rawLetter != null && rawLetter.toString().trim().isNotEmpty) {
      final key = rawLetter.toString().trim().toUpperCase();
      final p = pointForLetterRaw(key);
      if (p != null) return (p, key);
    }
    final marks = c['marks'];
    if (marks != null && marks.toString().isNotEmpty) {
      final n = _num(marks);
      final lt = letterForMarks(n);
      if (lt != null) return (pointForLetterRaw(lt)!, lt);
    }
    return null;
  }

  // Returns an l10n band KEY; the screen maps it via tr.studentCreditsSummary.
  static String _classBandKey(double cgpa, double gradedCredits) {
    if (gradedCredits <= 0) return 'none';
    if (cgpa >= 3.75) return 'outstanding';
    if (cgpa >= 3.00) return 'very_good';
    if (cgpa >= 2.00) return 'satisfactory';
    return 'needs_improvement';
  }

  // ---- tracker -------------------------------------------------------------
  static const Map<String, int> _order = {
    'overdue': 0, 'due_today': 1, 'upcoming': 2, 'no_due': 3, 'done': 4
  };

  static AssignmentStatus assignmentStatus(
      Map<String, dynamic> item, DateTime now) {
    final due = parseDate(item['due_date']);
    final done = item['done'] == true;
    final title = (item['title'] ?? '').toString().trim();
    final kind = (item['kind'] ?? 'assignment').toString();
    String state;
    int? days;
    if (done) {
      state = 'done';
    } else if (due == null) {
      state = 'no_due';
    } else {
      days = _dayDiff(_dateOnly(now), due);
      state = days < 0 ? 'overdue' : (days == 0 ? 'due_today' : 'upcoming');
    }
    return AssignmentStatus(
      id: item['id'],
      state: state,
      days: days,
      dueDate: due == null ? null : isoDate(due),
      done: done,
      title: title,
      kind: kind,
    );
  }

  static TrackerBoard trackerBoard(
      List<Map<String, dynamic>> items, DateTime now) {
    final list = items.map((e) => assignmentStatus(e, now)).toList();
    list.sort((a, b) {
      final oa = _order[a.state] ?? 9, ob = _order[b.state] ?? 9;
      if (oa != ob) return oa.compareTo(ob);
      final da = a.dueDate ?? '9999-99-99', db = b.dueDate ?? '9999-99-99';
      if (da != db) return da.compareTo(db);
      final ta = a.title.toLowerCase(), tb = b.title.toLowerCase();
      if (ta != tb) return ta.compareTo(tb);
      return '${a.id}'.compareTo('${b.id}');
    });
    final overdue = list.where((s) => s.state == 'overdue').length;
    return TrackerBoard(list, overdue);
  }

  // ---- routine -------------------------------------------------------------
  static List<RoutineDay> routineByDay(List<Map<String, dynamic>> periods) {
    final byDay = <int, List<Map<String, dynamic>>>{};
    for (final p in periods) {
      byDay.putIfAbsent(_dayIndex(p), () => []).add(p);
    }
    final days = <RoutineDay>[];
    final sortedKeys = byDay.keys.toList()..sort();
    for (final di in sortedKeys) {
      final rows = byDay[di]!
        ..sort((a, b) {
          final ma = _minutes(a['start']) ?? 9999,
              mb = _minutes(b['start']) ?? 9999;
          if (ma != mb) return ma.compareTo(mb);
          final sa = (a['subject'] ?? '').toString().toLowerCase();
          final sb = (b['subject'] ?? '').toString().toLowerCase();
          if (sa != sb) return sa.compareTo(sb);
          return '${a['id']}'.compareTo('${b['id']}');
        });
      int? prevEnd;
      bool dayOverlap = false;
      final out = <RoutinePeriod>[];
      for (final p in rows) {
        final start = _minutes(p['start']);
        final end = _minutes(p['end']);
        final conflict = prevEnd != null && start != null && start < prevEnd;
        if (conflict) dayOverlap = true;
        out.add(RoutinePeriod(
          id: p['id'],
          subject: (p['subject'] ?? '').toString().trim(),
          room: (p['room'] ?? '').toString().trim(),
          start: (p['start'] ?? '').toString(),
          end: (p['end'] ?? '').toString(),
          conflict: conflict,
        ));
        if (end != null) prevEnd = prevEnd == null ? end : (end > prevEnd ? end : prevEnd);
      }
      final key = (di >= 0 && di <= 6) ? dayKeys[di] : 'other';
      days.add(RoutineDay(di, key, out, dayOverlap));
    }
    return days;
  }

  static int _dayIndex(Map<String, dynamic> p) {
    final d = p['day'];
    if (d is bool) return 7;
    if (d is int) return (d >= 0 && d <= 6) ? d : 7;
    final i = dayKeys.indexOf(d.toString().trim().toLowerCase());
    return i < 0 ? 7 : i;
  }

  static int? _minutes(dynamic hhmm) {
    if (hhmm == null) return null;
    final s = hhmm.toString().trim();
    if (!s.contains(':')) return null;
    final parts = s.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  // ---- goals ---------------------------------------------------------------
  static GoalProgress goalProgress(List<Map<String, dynamic>> goals) {
    final total = goals.length;
    final done = goals.where((g) => g['done'] == true).length;
    final percent = total == 0 ? 0 : (done * 100 / total).round();
    return GoalProgress(total, done, percent);
  }

  // ---- date / number helpers ----------------------------------------------
  static DateTime? parseDate(dynamic v) {
    if (v == null || v == '') return null;
    if (v is DateTime) return DateTime(v.year, v.month, v.day);
    try {
      final s = v.toString().substring(0, 10);
      final p = s.split('-');
      return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    } catch (_) {
      return null;
    }
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static int _dayDiff(DateTime from, DateTime to) =>
      to.difference(from).inDays;

  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static double? _num(dynamic v) {
    if (v == null || v == '') return null;
    if (v is bool) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static double _round(double v, int dp) {
    final f = _pow10(dp);
    return (v * f).round() / f;
  }

  static double _round4(double v) => _round(v, 4);

  static double _pow10(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
