import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device mirror of `backend/core/logic/pa_tasks.py` (PA SECRETARY MODE
/// personal-task oversight, #115, §14). Deterministic prioritised ordering,
/// honest overdue (from a passed-in `now`), progress summary. No clock inside
/// the pure helpers — `now` is always an argument so overdue is honest.

const String statusTodo = 'todo';
const String statusDoing = 'doing';
const String statusDone = 'done';
const List<String> kStatuses = [statusTodo, statusDoing, statusDone];

const String priorityLow = 'low';
const String priorityNormal = 'normal';
const String priorityHigh = 'high';
const String priorityUrgent = 'urgent';
const List<String> kPriorities = [
  priorityUrgent,
  priorityHigh,
  priorityNormal,
  priorityLow,
];

const Map<String, int> _priorityWeight = {
  priorityUrgent: 3,
  priorityHigh: 2,
  priorityNormal: 1,
  priorityLow: 0,
};

const String _noDue = '9999-12-31T23:59:59';

class PaTask {
  final String id;
  final String title;
  final String status;
  final String priority;
  final String due; // ISO-8601 or '' (no due date)
  final String note;
  const PaTask({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    required this.due,
    required this.note,
  });

  PaTask copyWith({
    String? title,
    String? status,
    String? priority,
    String? due,
    String? note,
  }) =>
      PaTask(
        id: id,
        title: title ?? this.title,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        due: due ?? this.due,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status,
        'priority': priority,
        'due': due,
        'note': note,
      };

  factory PaTask.fromJson(Map<String, dynamic> j) => normalizeTask(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        priority: (j['priority'] ?? '').toString(),
        due: (j['due'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );
}

/// Coerce raw fields into a clean task with safe defaults (mirrors
/// normalize_task). Unknown status/priority fall back to todo/normal.
PaTask normalizeTask({
  required String id,
  required String title,
  String status = statusTodo,
  String priority = priorityNormal,
  String due = '',
  String note = '',
}) {
  final s = kStatuses.contains(status) ? status : statusTodo;
  final p = kPriorities.contains(priority) ? priority : priorityNormal;
  final cleanTitle = title.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return PaTask(
    id: id,
    title: cleanTitle,
    status: s,
    priority: p,
    due: due.trim(),
    note: note,
  );
}

DateTime? _parse(String dt) {
  var s = dt.trim();
  if (s.isEmpty) return null;
  if (s.endsWith('Z')) s = s.substring(0, s.length - 1);
  var d = DateTime.tryParse(s);
  d ??= DateTime.tryParse('${s}T00:00:00');
  return d;
}

/// Honest overdue: not done, has a real due date, and due < now.
bool isOverdue(PaTask t, DateTime now) {
  if (t.status == statusDone) return false;
  final due = _parse(t.due);
  if (due == null) return false;
  return due.isBefore(now);
}

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateTask({required String title, String due = ''}) {
  final problems = <String>[];
  if (title.trim().isEmpty) problems.add('title_required');
  if (due.trim().isNotEmpty && _parse(due) == null) problems.add('bad_due');
  return problems;
}

/// Display order: overdue first, then priority (urgent→low), then soonest due,
/// then title; done last. Deterministic, never mutates the input.
List<PaTask> orderTasks(List<PaTask> tasks, DateTime now) {
  final out = List<PaTask>.from(tasks);
  out.sort((a, b) {
    final doneA = a.status == statusDone ? 1 : 0;
    final doneB = b.status == statusDone ? 1 : 0;
    if (doneA != doneB) return doneA - doneB;
    final overA = isOverdue(a, now) ? 0 : 1;
    final overB = isOverdue(b, now) ? 0 : 1;
    if (overA != overB) return overA - overB;
    final wA = -(_priorityWeight[a.priority] ?? 1);
    final wB = -(_priorityWeight[b.priority] ?? 1);
    if (wA != wB) return wA.compareTo(wB);
    final dueA = _parse(a.due)?.toIso8601String() ?? _noDue;
    final dueB = _parse(b.due)?.toIso8601String() ?? _noDue;
    final cmp = dueA.compareTo(dueB);
    if (cmp != 0) return cmp;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return out;
}

class PaProgress {
  final int total, todo, doing, done, overdue, percentDone;
  const PaProgress({
    required this.total,
    required this.todo,
    required this.doing,
    required this.done,
    required this.overdue,
    required this.percentDone,
  });
}

PaProgress progressSummary(List<PaTask> tasks, DateTime now) {
  var todo = 0, doing = 0, done = 0, overdue = 0;
  for (final t in tasks) {
    if (t.status == statusTodo) todo++;
    if (t.status == statusDoing) doing++;
    if (t.status == statusDone) done++;
    if (isOverdue(t, now)) overdue++;
  }
  final total = tasks.length;
  final percent = total == 0 ? 0 : (done * 100 ~/ total);
  return PaProgress(
    total: total,
    todo: todo,
    doing: doing,
    done: done,
    overdue: overdue,
    percentDone: percent,
  );
}

// ---------------------------------------------------------------- store

class PaTasksStore {
  static const _key = 'pa_tasks_v1';

  static Future<List<PaTask>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => PaTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<PaTask> tasks) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(tasks.map((t) => t.toJson()).toList()));
  }
}
