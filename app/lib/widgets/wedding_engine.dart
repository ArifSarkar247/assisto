/// wedding_engine.dart — pure, deterministic WEDDING & EVENTS math mirrored
/// VERBATIM from backend/core/logic/wedding_events.py (#189, §20). No widgets,
/// no I/O, no Bangla literals. All money is INTEGER POISHA (1 taka = 100
/// poisha); the ৳ sign is a currency glyph (gate-exempt). Holds no money.
library;

class GuestSummary {
  final int total;
  final Map<String, int> counts; // yes/no/maybe/invited
  final int confirmedHeads;
  final int expectedHeads;
  final int pending;
  const GuestSummary(this.total, this.counts, this.confirmedHeads,
      this.expectedHeads, this.pending);
  bool get empty => total == 0;
}

class BudgetCategory {
  final String category;
  final int estimated; // poisha
  final int actual; // poisha
  final bool over;
  const BudgetCategory(this.category, this.estimated, this.actual, this.over);
  int get variance => actual - estimated;
}

class BudgetSummary {
  final List<BudgetCategory> categories;
  final int totalEstimated;
  final int totalActual;
  final bool overBudget;
  final int overAmount;
  const BudgetSummary(this.categories, this.totalEstimated, this.totalActual,
      this.overBudget, this.overAmount);
  int get totalVariance => totalActual - totalEstimated;
  bool get empty => categories.isEmpty;
}

class TaskStatus {
  final dynamic id;
  final String state; // done|no_due|overdue|due_today|upcoming
  final int? days;
  final String? dueDate;
  final bool done;
  final String title;
  final String vendor;
  const TaskStatus({
    required this.id,
    required this.state,
    required this.days,
    required this.dueDate,
    required this.done,
    required this.title,
    required this.vendor,
  });
}

class TaskBoard {
  final List<TaskStatus> all;
  final int overdueCount;
  const TaskBoard(this.all, this.overdueCount);
}

class Countdown {
  final String state; // no_date|today|future|past
  final int? days;
  final int? daysAgo;
  final String? eventDate;
  const Countdown(this.state, this.days, this.daysAgo, this.eventDate);
}

class WeddingEngine {
  WeddingEngine._();

  static const List<String> rsvpStates = ['yes', 'no', 'maybe', 'invited'];

  // Suggested budget category keys (labels come from l10n). Free text allowed.
  static const List<String> categoryKeys = [
    'venue', 'food', 'decor', 'photography', 'attire', 'gifts',
    'transport', 'other'
  ];

  // ---- poisha --------------------------------------------------------------
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v; // already poisha
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final i = s.indexOf('.');
      whole = s.substring(0, i);
      frac = s.substring(i + 1);
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = (frac + '00');
    frac = frac.substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  /// Integer poisha → '৳12,34,567.89'. ৳ is a currency glyph (gate-exempt).
  static String fmtPoisha(int p) {
    final neg = p < 0;
    final abs = p.abs();
    final taka = abs ~/ 100;
    final paisa = abs % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  // ---- guests --------------------------------------------------------------
  static GuestSummary guestSummary(List<Map<String, dynamic>> guests) {
    final counts = {for (final s in rsvpStates) s: 0};
    int confirmed = 0, expected = 0;
    for (final g in guests) {
      final s = _rsvp(g);
      counts[s] = counts[s]! + 1;
      final heads = 1 + _plus(g);
      if (s == 'yes') {
        confirmed += heads;
        expected += heads;
      } else if (s == 'maybe') {
        expected += heads;
      }
    }
    return GuestSummary(guests.length, counts, confirmed, expected,
        counts['maybe']! + counts['invited']!);
  }

  static String _rsvp(Map<String, dynamic> g) {
    final s = (g['rsvp'] ?? g['status'] ?? 'invited').toString().trim().toLowerCase();
    return rsvpStates.contains(s) ? s : 'invited';
  }

  static int _plus(Map<String, dynamic> g) {
    final v = int.tryParse('${g['plus_ones'] ?? 0}') ?? 0;
    return v < 0 ? 0 : v;
  }

  // ---- budget --------------------------------------------------------------
  static BudgetSummary budgetSummary(List<Map<String, dynamic>> rows) {
    final agg = <String, List<int>>{}; // cat -> [est, act]
    final order = <String>[];
    for (final r in rows) {
      var cat = (r['category'] ?? 'other').toString().trim();
      if (cat.isEmpty) cat = 'other';
      if (!agg.containsKey(cat)) {
        agg[cat] = [0, 0];
        order.add(cat);
      }
      agg[cat]![0] += toPoisha(r['estimated']);
      agg[cat]![1] += toPoisha(r['actual']);
    }
    final cats = <BudgetCategory>[];
    int totEst = 0, totAct = 0;
    for (final cat in order) {
      final est = agg[cat]![0], act = agg[cat]![1];
      totEst += est;
      totAct += act;
      cats.add(BudgetCategory(cat, est, act, act > est));
    }
    final over = totAct > totEst;
    return BudgetSummary(cats, totEst, totAct, over, over ? totAct - totEst : 0);
  }

  // ---- tasks ---------------------------------------------------------------
  static const Map<String, int> _order = {
    'overdue': 0, 'due_today': 1, 'upcoming': 2, 'no_due': 3, 'done': 4
  };

  static TaskStatus taskStatus(Map<String, dynamic> task, DateTime now) {
    final due = parseDate(task['due_date']);
    final done = task['done'] == true;
    final title = (task['title'] ?? '').toString().trim();
    final vendor = (task['vendor'] ?? '').toString().trim();
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
    return TaskStatus(
      id: task['id'],
      state: state,
      days: days,
      dueDate: due == null ? null : isoDate(due),
      done: done,
      title: title,
      vendor: vendor,
    );
  }

  static TaskBoard taskBoard(List<Map<String, dynamic>> tasks, DateTime now) {
    final list = tasks.map((t) => taskStatus(t, now)).toList();
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
    return TaskBoard(list, overdue);
  }

  // ---- countdown -----------------------------------------------------------
  static Countdown countdown(dynamic eventDate, DateTime now) {
    final ev = parseDate(eventDate);
    if (ev == null) return const Countdown('no_date', null, null, null);
    final delta = _dayDiff(_dateOnly(now), ev);
    if (delta > 0) return Countdown('future', delta, null, isoDate(ev));
    if (delta == 0) return Countdown('today', 0, 0, isoDate(ev));
    return Countdown('past', null, -delta, isoDate(ev));
  }

  // ---- date helpers --------------------------------------------------------
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
  static int _dayDiff(DateTime from, DateTime to) => to.difference(from).inDays;
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
