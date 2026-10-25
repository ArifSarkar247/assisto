import 'package:flutter/material.dart';
import '../theme.dart';

/// Task Manager (#21, SPEC v2.1 §21 ADVANCED) model + bilingual string helpers
/// + pure list ops. Mirrors backend/core/logic/task_manager.py so the app and
/// server agree on bucketing, ordering, overdue and progress.
///
/// NO Bangla glyphs live in this file (SPEC §21): every localized string comes
/// from the local bilingual table [_strings] via [tmStr], carrying [bn, en]
/// pairs that are ALSO emitted to .phaseB/up_taskmgr_arb.json for the next ARB
/// sync (per task rules we do NOT edit app_*.arb here). Bangla DIGITS use
/// codepoints only (see [tmNum]). The 'tm' prefix matches the emitted keys.

bool tmIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer: Western digits, or Bangla digits via codepoints when bn.
String tmNum(BuildContext c, int n) {
  if (!tmIsBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero codepoint
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Pick a bilingual string by key for the active locale. Falls back to the
/// English entry, then the key itself (never throws, never blank).
String tmStr(BuildContext c, String key) {
  final pair = _strings[key];
  if (pair == null) return key;
  return tmIsBn(c) ? pair[0] : pair[1];
}

/// Fill a single {n} placeholder with a locale-formatted integer.
String tmStrNum(BuildContext c, String key, int n) =>
    tmStr(c, key).replaceFirst('{n}', tmNum(c, n));

/// Fill a single {name} placeholder with a raw (already-localized) value.
String tmStrName(BuildContext c, String key, String name) =>
    tmStr(c, key).replaceFirst('{name}', name);

// ---------------------------------------------------------------------------
// Vocabulary — kept in lock-step with task_manager.py.
// ---------------------------------------------------------------------------
const kStatusTodo = 'todo';
const kStatusDoing = 'doing';
const kStatusDone = 'done';
const kBoardColumns = [kStatusTodo, kStatusDoing, kStatusDone];

const kPriorityLow = 'low';
const kPriorityNormal = 'normal';
const kPriorityHigh = 'high';
const kPriorityUrgent = 'urgent';
const kPriorities = [
  kPriorityUrgent,
  kPriorityHigh,
  kPriorityNormal,
  kPriorityLow
];

const _priorityWeight = {
  kPriorityUrgent: 3,
  kPriorityHigh: 2,
  kPriorityNormal: 1,
  kPriorityLow: 0,
};

const _noDue = '9999-12-31T23:59:59';

String statusLabel(BuildContext c, String s) {
  switch (s) {
    case kStatusDoing:
      return tmStr(c, 'tmStatusDoing');
    case kStatusDone:
      return tmStr(c, 'tmStatusDone');
    case kStatusTodo:
    default:
      return tmStr(c, 'tmStatusTodo');
  }
}

String priorityLabel(BuildContext c, String p) {
  switch (p) {
    case kPriorityUrgent:
      return tmStr(c, 'tmPriorityUrgent');
    case kPriorityHigh:
      return tmStr(c, 'tmPriorityHigh');
    case kPriorityLow:
      return tmStr(c, 'tmPriorityLow');
    case kPriorityNormal:
    default:
      return tmStr(c, 'tmPriorityNormal');
  }
}

Color statusColor(BuildContext c, String s) {
  final scheme = Theme.of(c).colorScheme;
  switch (s) {
    case kStatusDoing:
      return Brand.blue;
    case kStatusDone:
      return Brand.success;
    case kStatusTodo:
    default:
      return scheme.onSurfaceVariant;
  }
}

Color priorityColor(BuildContext c, String p) {
  final scheme = Theme.of(c).colorScheme;
  switch (p) {
    case kPriorityUrgent:
      return Brand.danger;
    case kPriorityHigh:
      return Brand.warning;
    case kPriorityLow:
      return scheme.onSurfaceVariant;
    case kPriorityNormal:
    default:
      return Brand.blue;
  }
}

IconData priorityIcon(String p) {
  switch (p) {
    case kPriorityUrgent:
      return Icons.priority_high_rounded;
    case kPriorityHigh:
      return Icons.keyboard_double_arrow_up_rounded;
    case kPriorityLow:
      return Icons.keyboard_arrow_down_rounded;
    case kPriorityNormal:
    default:
      return Icons.drag_handle_rounded;
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A project — the top-level container that owns tasks. Backed by the
/// `tasks_projects` REST collection (see up_taskmgr_integration.md).
class Project {
  int? id;
  String name;
  String description;
  String color;

  Project({this.id, this.name = '', this.description = '', this.color = ''});

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}'),
        name: (j['name'] ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' '),
        description: (j['description'] ?? '').toString(),
        color: (j['color'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'description': description,
        'color': color,
      };
}

/// A task. Backed by the `tasks_items` REST collection; `projectId` ties it to
/// its [Project] (null = inbox / no project).
class TaskItem {
  int? id;
  int? projectId;
  String title;
  String description;
  String assignee;
  String status;
  String priority;
  String due; // ISO-8601 or ''
  int progress; // 0..100

  TaskItem({
    this.id,
    this.projectId,
    this.title = '',
    this.description = '',
    this.assignee = '',
    this.status = kStatusTodo,
    this.priority = kPriorityNormal,
    this.due = '',
    this.progress = 0,
  });

  factory TaskItem.fromJson(Map<String, dynamic> j) {
    var status = (j['status'] ?? '').toString();
    if (!kBoardColumns.contains(status)) status = kStatusTodo;
    var priority = (j['priority'] ?? '').toString();
    if (!kPriorities.contains(priority)) priority = kPriorityNormal;
    var progress = 0;
    final rawP = j['progress'];
    if (rawP is num) {
      progress = rawP.round();
    } else {
      progress = int.tryParse('$rawP') ?? 0;
    }
    if (progress < 0) progress = 0;
    if (progress > 100) progress = 100;
    if (status == kStatusDone) progress = 100;
    return TaskItem(
      id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}'),
      projectId: j['project_id'] is int
          ? j['project_id'] as int
          : int.tryParse('${j['project_id']}'),
      title: (j['title'] ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' '),
      description: (j['description'] ?? '').toString(),
      assignee:
          (j['assignee'] ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' '),
      status: status,
      priority: priority,
      due: (j['due'] ?? '').toString().trim(),
      progress: progress,
    );
  }

  Map<String, dynamic> toJson() => {
        if (projectId != null) 'project_id': projectId,
        'title': title.trim(),
        'description': description,
        'assignee': assignee.trim(),
        'status': status,
        'priority': priority,
        'due': due.trim(),
        'progress': status == kStatusDone ? 100 : progress,
      };

  TaskItem copy() => TaskItem(
        id: id,
        projectId: projectId,
        title: title,
        description: description,
        assignee: assignee,
        status: status,
        priority: priority,
        due: due,
        progress: progress,
      );
}

// ---------------------------------------------------------------------------
// Pure helpers (mirror of task_manager.py)
// ---------------------------------------------------------------------------

DateTime? tmParseDue(String due) {
  if (due.trim().isEmpty) return null;
  var s = due.trim();
  if (s.endsWith('Z')) s = s.substring(0, s.length - 1);
  var d = DateTime.tryParse(s);
  d ??= DateTime.tryParse('${s}T00:00:00');
  return d;
}

/// Honest overdue: not done, real due date, strictly before [now].
bool isOverdue(TaskItem t, DateTime now) {
  if (t.status == kStatusDone) return false;
  final due = tmParseDue(t.due);
  if (due == null) return false;
  return due.isBefore(now);
}

String _sortKey(TaskItem t, DateTime now) {
  final done = t.status == kStatusDone ? 1 : 0;
  final overdue = isOverdue(t, now) ? 0 : 1;
  final weight = 9 - (_priorityWeight[t.priority] ?? 1); // ascending
  final due = tmParseDue(t.due);
  final dueKey = due?.toIso8601String() ?? _noDue;
  return '$done$overdue$weight|$dueKey|${t.title.toLowerCase()}';
}

/// Ordered list (LIST view): overdue → priority → due → title; done last.
List<TaskItem> orderTasks(List<TaskItem> tasks, DateTime now) {
  final list = [...tasks];
  list.sort((a, b) => _sortKey(a, now).compareTo(_sortKey(b, now)));
  return list;
}

String _asgKey(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Keep tasks matching the optional status + assignee filters.
List<TaskItem> filterTasks(List<TaskItem> tasks,
    {String? status, String? assignee}) {
  final wantStatus =
      (status != null && kBoardColumns.contains(status)) ? status : null;
  final wantAsg = (assignee != null && assignee.trim().isNotEmpty)
      ? _asgKey(assignee)
      : null;
  return tasks.where((t) {
    if (wantStatus != null && t.status != wantStatus) return false;
    if (wantAsg != null && _asgKey(t.assignee) != wantAsg) return false;
    return true;
  }).toList();
}

List<TaskItem> filterUnassigned(List<TaskItem> tasks) =>
    tasks.where((t) => t.assignee.trim().isEmpty).toList();

/// Distinct, sorted (case-insensitive) assignee names for the filter dropdown.
List<String> assigneesOf(List<TaskItem> tasks) {
  final seen = <String, String>{};
  for (final t in tasks) {
    final n = t.assignee.trim();
    if (n.isNotEmpty && !seen.containsKey(n.toLowerCase())) {
      seen[n.toLowerCase()] = n;
    }
  }
  final keys = seen.keys.toList()..sort();
  return [for (final k in keys) seen[k]!];
}

/// Bucket tasks into the three board columns, each internally ordered.
Map<String, List<TaskItem>> boardColumns(List<TaskItem> tasks, DateTime now) {
  final cols = {for (final c in kBoardColumns) c: <TaskItem>[]};
  for (final t in tasks) {
    (cols[t.status] ?? cols[kStatusTodo]!).add(t);
  }
  for (final c in cols.keys) {
    cols[c]!.sort((a, b) => _sortKey(a, now).compareTo(_sortKey(b, now)));
  }
  return cols;
}

/// Progress rollup for a project: counts + honest overdue + percent done.
class ProgressSummary {
  final int total, todo, doing, done, overdue, percentDone;
  const ProgressSummary(
      this.total, this.todo, this.doing, this.done, this.overdue, this.percentDone);

  factory ProgressSummary.of(List<TaskItem> tasks, DateTime now) {
    var todo = 0, doing = 0, done = 0, overdue = 0;
    for (final t in tasks) {
      if (t.status == kStatusTodo) {
        todo++;
      } else if (t.status == kStatusDoing) {
        doing++;
      } else if (t.status == kStatusDone) {
        done++;
      }
      if (isOverdue(t, now)) overdue++;
    }
    final total = tasks.length;
    final percent = total == 0 ? 0 : (done * 100) ~/ total;
    return ProgressSummary(total, todo, doing, done, overdue, percent);
  }
}

// ---------------------------------------------------------------------------
// Bilingual string table (bn, en). Mirror of up_taskmgr_arb.json. Bangla as
// \u codepoints only — ZERO raw Bangla glyphs in this .dart file.
// ---------------------------------------------------------------------------
const Map<String, List<String>> _strings = {
  // screen / nav
  'tmTitle': ['\u099F\u09BE\u09B8\u09CD\u0995 \u09AE\u09CD\u09AF\u09BE\u09A8\u09C7\u099C\u09BE\u09B0', 'Task Manager'],
  'tmProjects': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F', 'Projects'],
  // projects
  'tmNewProject': ['\u09A8\u09A4\u09C1\u09A8 \u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F', 'New project'],
  'tmEditProject': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09B8\u09AE\u09CD\u09AA\u09BE\u09A6\u09A8\u09BE', 'Edit project'],
  'tmProjectName': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F\u09C7\u09B0 \u09A8\u09BE\u09AE', 'Project name'],
  'tmProjectNameHint': ['\u09AF\u09C7\u09AE\u09A8, \u0998\u09B0 \u09B8\u09BE\u099C\u09BE\u09A8\u09CB', 'e.g. Home renovation'],
  'tmProjectDesc': ['\u09AC\u09BF\u09AC\u09B0\u09A3 (\u0990\u099A\u09CD\u099B\u09BF\u0995)', 'Description (optional)'],
  'tmDeleteProjectQ': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09AE\u09C1\u099B\u09AC\u09C7\u09A8?', 'Delete project?'],
  'tmDeleteProjectBody': ['\u098F\u0987 \u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F\u09C7\u09B0 \u09B8\u09AC \u099F\u09BE\u09B8\u09CD\u0995\u0993 \u09AE\u09C1\u099B\u09C7 \u09AF\u09BE\u09AC\u09C7। \u098F\u099F\u09BF \u09AB\u09BF\u09B0\u09BF\u09AF\u09BC\u09C7 \u0986\u09A8\u09BE \u09AF\u09BE\u09AC\u09C7 \u09A8\u09BE।', 'All tasks in this project will be deleted too. This cannot be undone.'],
  'tmProjectSaved': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Project saved'],
  'tmProjectDeleted': ['\u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Project deleted'],
  // projects empty / welcome
  'tmWelcomeTitle': ['\u0995\u09BE\u099C \u0997\u09C1\u099B\u09BF\u09AF\u09BC\u09C7 \u09B0\u09BE\u0996\u09C1\u09A8', 'Organise your work'],
  'tmWelcomeBody': ['\u098F\u0995\u099F\u09BF \u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09A6\u09BF\u09AF\u09BC\u09C7 \u09B6\u09C1\u09B0\u09C1 \u0995\u09B0\u09C1\u09A8, \u09A4\u09BE\u09B0\u09AA\u09B0 \u099F\u09BE\u09B8\u09CD\u0995 \u09AF\u09CB\u0997 \u0995\u09B0\u09C7 \u09AC\u09CB\u09B0\u09CD\u09A1\u09C7 \u09B8\u09BE\u099C\u09BE\u09A8।', 'Start with a project, then add tasks and track them on a board.'],
  'tmCreateFirstProject': ['\u09AA\u09CD\u09B0\u09A5\u09AE \u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F \u09A4\u09C8\u09B0\u09BF \u0995\u09B0\u09C1\u09A8', 'Create your first project'],
  // tasks
  'tmTasks': ['\u099F\u09BE\u09B8\u09CD\u0995', 'Tasks'],
  'tmNewTask': ['\u09A8\u09A4\u09C1\u09A8 \u099F\u09BE\u09B8\u09CD\u0995', 'New task'],
  'tmEditTask': ['\u099F\u09BE\u09B8\u09CD\u0995 \u09B8\u09AE\u09CD\u09AA\u09BE\u09A6\u09A8\u09BE', 'Edit task'],
  'tmTaskTitle': ['\u099F\u09BE\u09B8\u09CD\u0995\u09C7\u09B0 \u09A8\u09BE\u09AE', 'Task title'],
  'tmTaskTitleHint': ['\u0995\u09BF \u0995\u09B0\u09A4\u09C7 \u09B9\u09AC\u09C7?', 'What needs doing?'],
  'tmTaskDesc': ['\u09AC\u09BF\u09AC\u09B0\u09A3 (\u0990\u099A\u09CD\u099B\u09BF\u0995)', 'Details (optional)'],
  'tmAssignee': ['\u09A6\u09BE\u09AF\u09BC\u09BF\u09A4\u09CD\u09AC', 'Assignee'],
  'tmAssigneeHint': ['\u09A8\u09BE\u09AE \u09B2\u09BF\u0996\u09C1\u09A8 \u09AC\u09BE \u09B8\u09BE\u09B0\u09CD\u0995\u09C7\u09B2 \u09B8\u09A6\u09B8\u09CD\u09AF \u09AC\u09C7\u099B\u09C7 \u09A8\u09BF\u09A8', 'Type a name or pick a Circle member'],
  'tmUnassigned': ['\u0995\u09BE\u0989\u0995\u09C7 \u09A6\u09C7\u0993\u09AF\u09BC\u09BE \u09B9\u09AF\u09BC\u09A8\u09BF', 'Unassigned'],
  'tmDueDate': ['\u09B6\u09C7\u09B7 \u09A4\u09BE\u09B0\u09BF\u0996', 'Due date'],
  'tmNoDue': ['\u0995\u09CB\u09A8\u09CB \u09B6\u09C7\u09B7 \u09A4\u09BE\u09B0\u09BF\u0996 \u09A8\u09C7\u0987', 'No due date'],
  'tmPriority': ['\u0985\u0997\u09CD\u09B0\u09BE\u09A7\u09BF\u0995\u09BE\u09B0', 'Priority'],
  'tmProgress': ['\u0985\u0997\u09CD\u09B0\u0997\u09A4\u09BF', 'Progress'],
  'tmStatus': ['\u0985\u09AC\u09B8\u09CD\u09A5\u09BE', 'Status'],
  'tmDeleteTaskQ': ['\u099F\u09BE\u09B8\u09CD\u0995 \u09AE\u09C1\u099B\u09AC\u09C7\u09A8?', 'Delete task?'],
  'tmTaskSaved': ['\u099F\u09BE\u09B8\u09CD\u0995 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Task saved'],
  'tmTaskDeleted': ['\u099F\u09BE\u09B8\u09CD\u0995 \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Task deleted'],
  'tmNoTasksYet': ['\u098F\u0996\u09A8\u09CB \u0995\u09CB\u09A8\u09CB \u099F\u09BE\u09B8\u09CD\u0995 \u09A8\u09C7\u0987', 'No tasks yet'],
  'tmNoTasksBody': ['\u098F\u0987 \u09AA\u09CD\u09B0\u099C\u09C7\u0995\u09CD\u099F\u09C7 \u09AA\u09CD\u09B0\u09A5\u09AE \u099F\u09BE\u09B8\u09CD\u0995 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8।', 'Add the first task to this project.'],
  'tmNoMatch': ['\u0995\u09CB\u09A8\u09CB \u099F\u09BE\u09B8\u09CD\u0995 \u09AE\u09C7\u09B2\u09C7\u09A8\u09BF', 'No matching tasks'],
  'tmNoMatchBody': ['\u09AB\u09BF\u09B2\u09CD\u099F\u09BE\u09B0 \u09AC\u09A6\u09B2\u09C7 \u0986\u09AC\u09BE\u09B0 \u09A6\u09C7\u0996\u09C1\u09A8।', 'Try changing the filters.'],
  // statuses
  'tmStatusTodo': ['\u0995\u09B0\u09A4\u09C7 \u09B9\u09AC\u09C7', 'To-do'],
  'tmStatusDoing': ['\u099A\u09B2\u099B\u09C7', 'Doing'],
  'tmStatusDone': ['\u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Done'],
  // priorities
  'tmPriorityUrgent': ['\u099C\u09B0\u09C1\u09B0\u09BF', 'Urgent'],
  'tmPriorityHigh': ['\u0989\u099A\u09CD\u099A', 'High'],
  'tmPriorityNormal': ['\u09B8\u09BE\u09A7\u09BE\u09B0\u09A3', 'Normal'],
  'tmPriorityLow': ['\u0995\u09AE', 'Low'],
  // board / list toggle
  'tmViewBoard': ['\u09AC\u09CB\u09B0\u09CD\u09A1', 'Board'],
  'tmViewList': ['\u09A4\u09BE\u09B2\u09BF\u0995\u09BE', 'List'],
  'tmMoveTo': ['\u09B8\u09B0\u09BE\u09A8', 'Move to'],
  // filters
  'tmFilter': ['\u09AB\u09BF\u09B2\u09CD\u099F\u09BE\u09B0', 'Filter'],
  'tmAll': ['\u09B8\u09AC', 'All'],
  'tmByStatus': ['\u0985\u09AC\u09B8\u09CD\u09A5\u09BE \u0985\u09A8\u09C1\u09AF\u09BE\u09AF\u09BC\u09C0', 'By status'],
  'tmByAssignee': ['\u09A6\u09BE\u09AF\u09BC\u09BF\u09A4\u09CD\u09AC \u0985\u09A8\u09C1\u09AF\u09BE\u09AF\u09BC\u09C0', 'By assignee'],
  'tmClearFilters': ['\u09AB\u09BF\u09B2\u09CD\u099F\u09BE\u09B0 \u09AE\u09C1\u099B\u09C1\u09A8', 'Clear filters'],
  // progress summary / badges
  'tmOverdue': ['\u09AE\u09C7\u09AF\u09BC\u09BE\u09A6 \u09AA\u09C7\u09B0\u09BF\u09AF\u09BC\u09C7\u099B\u09C7', 'Overdue'],
  'tmDueToday': ['\u0986\u099C \u09B6\u09C7\u09B7 \u09A4\u09BE\u09B0\u09BF\u0996', 'Due today'],
  'tmPercentDone': ['{n}% \u09B6\u09C7\u09B7', '{n}% done'],
  'tmSummaryLine': ['{n}\u099F\u09BF \u099F\u09BE\u09B8\u09CD\u0995', '{n} tasks'],
  'tmOverdueCount': ['{n}\u099F\u09BF \u09AE\u09C7\u09AF\u09BC\u09BE\u09A6\u09CB\u09A4\u09CD\u09A4\u09C0\u09B0\u09CD\u09A3', '{n} overdue'],
  // generic actions / states
  'tmSave': ['\u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09A3', 'Save'],
  'tmCancel': ['\u09AC\u09BE\u09A4\u09BF\u09B2', 'Cancel'],
  'tmDelete': ['\u09AE\u09C1\u099B\u09C1\u09A8', 'Delete'],
  'tmEdit': ['\u09B8\u09AE\u09CD\u09AA\u09BE\u09A6\u09A8\u09BE', 'Edit'],
  'tmRetry': ['\u0986\u09AC\u09BE\u09B0 \u099A\u09C7\u09B7\u09CD\u099F\u09BE', 'Retry'],
  'tmLoadFailed': ['\u09B2\u09CB\u09A1 \u0995\u09B0\u09BE \u09AF\u09BE\u09AF\u09BC\u09A8\u09BF', 'Could not load'],
  'tmLoadFailedBody': ['\u0987\u09A8\u09CD\u099F\u09BE\u09B0\u09A8\u09C7\u099F \u09AA\u09B0\u09C0\u0995\u09CD\u09B7\u09BE \u0995\u09B0\u09C7 \u0986\u09AC\u09BE\u09B0 \u099A\u09C7\u09B7\u09CD\u099F\u09BE \u0995\u09B0\u09C1\u09A8।', 'Check your connection and try again.'],
  'tmTitleRequired': ['\u09A8\u09BE\u09AE \u09A6\u09BF\u09A4\u09C7 \u09B9\u09AC\u09C7', 'A title is required'],
  'tmNameRequired': ['\u09A8\u09BE\u09AE \u09A6\u09BF\u09A4\u09C7 \u09B9\u09AC\u09C7', 'A name is required'],
  'tmPickDate': ['\u09A4\u09BE\u09B0\u09BF\u0996 \u09AC\u09C7\u099B\u09C7 \u09A8\u09BF\u09A8', 'Pick a date'],
  'tmSavedOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4', 'Saved offline'],
  'tmOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8 — \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A4\u09A5\u09CD\u09AF \u09A6\u09C7\u0996\u09BE\u09A8\u09CB \u09B9\u099A\u09CD\u099B\u09C7', 'Offline — showing saved data'],
};
