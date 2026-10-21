import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/student_gpa_engine.dart';

/// STUDENT CORNER — ADVANCED (#192, SPEC v2.1 §20).
///
/// Thin, honest tools for a Bangladeshi student, all computed on-device and
/// mirrored VERBATIM from backend/core/logic/student_corner.py:
///   • Class routine / timetable  — periods grouped by weekday, honest overlap
///     flag.
///   • Assignment / exam tracker   — due dates with HONEST overdue (from the
///     device clock; a done or undated item is never overdue).
///   • CGPA / result calculator    — credit-weighted GPA on the STANDARD
///     Bangladeshi 4.00 scale (UGC uniform grading), with the grade→point table
///     and every course's (point × credit) contribution shown transparently.
///   • Study-goal checklist        — done/total progress.
///
/// Honest states: welcome (first use) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter; ৳ is a currency glyph only.
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('student/routine')     → [{id, day, start, end, subject, room}]
///   listItems('student/assignments') → [{id, title, kind, due_date, done}]
///   listItems('student/courses')     → [{id, title, credit, letter|marks}]
///   listItems('student/goals')       → [{id, title, done}]
/// create/update/deleteItem on the same paths; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
class StudentCornerScreen extends StatefulWidget {
  const StudentCornerScreen({super.key});
  @override
  State<StudentCornerScreen> createState() => _StudentCornerScreenState();
}

const String _routinePath = 'student/routine';
const String _assignPath = 'student/assignments';
const String _coursePath = 'student/courses';
const String _goalPath = 'student/goals';

class _StudentCornerScreenState extends State<StudentCornerScreen> {
  List<Map<String, dynamic>> _routine = [];
  List<Map<String, dynamic>> _assignments = [];
  List<Map<String, dynamic>> _courses = [];
  List<Map<String, dynamic>> _goals = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.listItems(_routinePath),
        api.listItems(_assignPath),
        api.listItems(_coursePath),
        api.listItems(_goalPath),
      ]);
      _routine = res[0];
      _assignments = res[1];
      _courses = res[2];
      _goals = res[3];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _empty =>
      _routine.isEmpty &&
      _assignments.isEmpty &&
      _courses.isEmpty &&
      _goals.isEmpty;

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.studentTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.studentTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.studentLoadError,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }
    if (_empty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.studentTitle)),
        body: StateMessage(
          icon: Icons.school_outlined,
          title: tr.studentWelcomeTitle,
          message: tr.studentWelcomeBody,
          action: FilledButton.icon(
            onPressed: () => _addCourse(context),
            icon: const Icon(Icons.calculate_outlined),
            label: Text(tr.studentAddCourse),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.studentTitle),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: tr.studentTabRoutine),
            Tab(text: tr.studentTabTracker),
            Tab(text: tr.studentTabCgpa),
            Tab(text: tr.studentTabGoals),
          ]),
        ),
        body: TabBarView(children: [
          _RoutineTab(periods: _routine, onChanged: _load),
          _TrackerTab(items: _assignments, onChanged: _load),
          _CgpaTab(courses: _courses, onChanged: _load, onAdd: _addCourse),
          _GoalsTab(goals: _goals, onChanged: _load),
        ]),
      ),
    );
  }

  Future<void> _addCourse(BuildContext context) async {
    final changed = await _showCourseEditor(context, null);
    if (changed == true) await _load();
  }
}

// ======================= helpers =======================
void _toast(BuildContext context, String m) =>
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));

Future<bool> _confirmDelete(
    BuildContext context, String path, dynamic id, String body) async {
  final tr = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final api = context.read<AppState>().api;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr.studentDeleteTitle),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr.delete),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  if (id is int) await api.deleteItem(path, id);
  return true;
}

// ======================= ROUTINE =======================
class _RoutineTab extends StatelessWidget {
  final List<Map<String, dynamic>> periods;
  final Future<void> Function() onChanged;
  const _RoutineTab({required this.periods, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final days = StudentEngine.routineByDay(periods);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: Text(tr.studentAddPeriod),
      ),
      body: days.isEmpty
          ? StateMessage(
              icon: Icons.calendar_view_week_outlined,
              title: tr.studentRoutineEmptyTitle,
              message: tr.studentRoutineEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  for (final d in days) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      child: Row(children: [
                        Text(_dayLabel(tr, d.key),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        if (d.overlaps) ...[
                          const SizedBox(width: Gap.sm),
                          Icon(Icons.warning_amber_rounded,
                              size: 18, color: scheme.error),
                        ],
                      ]),
                    ),
                    for (final p in d.periods)
                      Card(
                        margin: const EdgeInsets.only(bottom: Gap.sm),
                        child: ListTile(
                          leading: Icon(Icons.schedule,
                              color: p.conflict ? scheme.error : scheme.primary),
                          title: Text(
                              p.subject.isEmpty ? tr.studentUntitled : p.subject,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_periodSub(tr, p)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: tr.delete,
                            onPressed: () async {
                              if (await _confirmDelete(context, _routinePath,
                                  p.id, tr.studentDeletePeriodBody)) {
                                await onChanged();
                              }
                            },
                          ),
                          onTap: () => _edit(context, _rawOf(p.id)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Map<String, dynamic>? _rawOf(dynamic id) {
    for (final p in periods) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  String _periodSub(AppLocalizations tr, RoutinePeriod p) {
    final time = (p.start.isEmpty && p.end.isEmpty)
        ? tr.studentNoTime
        : '${p.start.isEmpty ? '—' : p.start} – ${p.end.isEmpty ? '—' : p.end}';
    if (p.room.isEmpty) return time;
    return '$time · ${p.room}';
  }

  String _dayLabel(AppLocalizations tr, String key) {
    switch (key) {
      case 'sat':
        return tr.studentDaySat;
      case 'sun':
        return tr.studentDaySun;
      case 'mon':
        return tr.studentDayMon;
      case 'tue':
        return tr.studentDayTue;
      case 'wed':
        return tr.studentDayWed;
      case 'thu':
        return tr.studentDayThu;
      case 'fri':
        return tr.studentDayFri;
      default:
        return tr.studentDayOther;
    }
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PeriodEditor(existing: existing),
    );
    if (changed == true) await onChanged();
  }
}

class _PeriodEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _PeriodEditor({this.existing});
  @override
  State<_PeriodEditor> createState() => _PeriodEditorState();
}

class _PeriodEditorState extends State<_PeriodEditor> {
  late final TextEditingController _subject;
  late final TextEditingController _room;
  late final TextEditingController _start;
  late final TextEditingController _end;
  String _day = 'sat';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _subject = TextEditingController(text: (e?['subject'] ?? '').toString());
    _room = TextEditingController(text: (e?['room'] ?? '').toString());
    _start = TextEditingController(text: (e?['start'] ?? '').toString());
    _end = TextEditingController(text: (e?['end'] ?? '').toString());
    final d = e?['day'];
    if (d is String && StudentEngine.dayKeys.contains(d)) _day = d;
  }

  @override
  void dispose() {
    _subject.dispose();
    _room.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _pickTime(TextEditingController c) async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.now());
    if (t != null) {
      c.text =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.studentAddPeriod
                : tr.studentEditPeriod,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        DropdownButtonFormField<String>(
          initialValue: _day,
          decoration: InputDecoration(labelText: tr.studentDayLabel),
          items: [
            for (final k in StudentEngine.dayKeys)
              DropdownMenuItem(value: k, child: Text(_dayText(tr, k))),
          ],
          onChanged: (v) => setState(() => _day = v ?? 'sat'),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _subject,
          decoration: InputDecoration(labelText: tr.studentSubjectLabel),
        ),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _start,
              readOnly: true,
              onTap: () => _pickTime(_start),
              decoration: InputDecoration(
                  labelText: tr.studentStartLabel,
                  suffixIcon: const Icon(Icons.schedule)),
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: TextField(
              controller: _end,
              readOnly: true,
              onTap: () => _pickTime(_end),
              decoration: InputDecoration(
                  labelText: tr.studentEndLabel,
                  suffixIcon: const Icon(Icons.schedule)),
            ),
          ),
        ]),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _room,
          decoration: InputDecoration(labelText: tr.studentRoomLabel),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  String _dayText(AppLocalizations tr, String k) {
    switch (k) {
      case 'sat':
        return tr.studentDaySat;
      case 'sun':
        return tr.studentDaySun;
      case 'mon':
        return tr.studentDayMon;
      case 'tue':
        return tr.studentDayTue;
      case 'wed':
        return tr.studentDayWed;
      case 'thu':
        return tr.studentDayThu;
      default:
        return tr.studentDayFri;
    }
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _saving = true);
    final body = {
      'day': _day,
      'subject': _subject.text.trim(),
      'room': _room.text.trim(),
      'start': _start.text.trim(),
      'end': _end.text.trim(),
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_routinePath, id, body);
      } else {
        await api.createItem(_routinePath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= TRACKER =======================
class _TrackerTab extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Future<void> Function() onChanged;
  const _TrackerTab({required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final board = StudentEngine.trackerBoard(items, DateTime.now());
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add_task),
        label: Text(tr.studentAddAssignment),
      ),
      body: board.all.isEmpty
          ? StateMessage(
              icon: Icons.assignment_outlined,
              title: tr.studentTrackerEmptyTitle,
              message: tr.studentTrackerEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  if (board.overdueCount > 0)
                    _overdueBanner(context, board.overdueCount),
                  for (final s in board.all)
                    _TrackerCard(
                      status: s,
                      onToggle: () => _toggle(context, s),
                      onDelete: () async {
                        if (await _confirmDelete(context, _assignPath, s.id,
                            tr.studentDeleteAssignmentBody)) {
                          await onChanged();
                        }
                      },
                      onTap: () => _edit(context, _rawOf(s.id)),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _overdueBanner(BuildContext context, int n) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(tr.studentOverdueBanner(n),
                style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ]),
      ),
    );
  }

  Map<String, dynamic>? _rawOf(dynamic id) {
    for (final r in items) {
      if (r['id'] == id) return r;
    }
    return null;
  }

  Future<void> _toggle(BuildContext context, AssignmentStatus s) async {
    final api = context.read<AppState>().api;
    final raw = _rawOf(s.id);
    if (raw == null || raw['id'] is! int) return;
    try {
      await api.updateItem(_assignPath, raw['id'] as int, {
        'title': raw['title'],
        'kind': raw['kind'] ?? 'assignment',
        'due_date': raw['due_date'],
        'done': !s.done,
      });
      await onChanged();
    } catch (_) {
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context).saveFailed);
      }
    }
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssignmentEditor(existing: existing),
    );
    if (changed == true) await onChanged();
  }
}

class _TrackerCard extends StatelessWidget {
  final AssignmentStatus status;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTap;
  const _TrackerCard(
      {required this.status,
      required this.onToggle,
      required this.onDelete,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = _badge(tr, scheme, status);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Checkbox(value: status.done, onChanged: (_) => onToggle()),
        title: Text(
          status.title.isEmpty ? tr.studentUntitled : status.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            decoration:
                status.done ? TextDecoration.lineThrough : TextDecoration.none,
          ),
        ),
        subtitle: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: Gap.sm),
          Flexible(
            child: Text(
              status.kind == 'exam' ? tr.studentKindExam : tr.studentKindAssignment,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ]),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: tr.delete,
          onPressed: onDelete,
        ),
        onTap: onTap,
      ),
    );
  }

  (String, Color) _badge(
      AppLocalizations tr, ColorScheme scheme, AssignmentStatus s) {
    switch (s.state) {
      case 'done':
        return (tr.studentStateDone, scheme.primary);
      case 'overdue':
        return (tr.studentOverdueDays(-s.days!), scheme.error);
      case 'due_today':
        return (tr.studentDueToday, scheme.tertiary);
      case 'upcoming':
        return (tr.studentDueInDays(s.days!), scheme.secondary);
      default:
        return (tr.studentNoDue, scheme.onSurfaceVariant);
    }
  }
}

class _AssignmentEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _AssignmentEditor({this.existing});
  @override
  State<_AssignmentEditor> createState() => _AssignmentEditorState();
}

class _AssignmentEditorState extends State<_AssignmentEditor> {
  late final TextEditingController _title;
  String _kind = 'assignment';
  DateTime? _due;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    if (e?['kind'] == 'exam') _kind = 'exam';
    _due = StudentEngine.parseDate(e?['due_date']);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _due = d);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.studentAddAssignment
                : tr.studentEditAssignment,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: tr.studentTitleLabel),
        ),
        const SizedBox(height: Gap.md),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
                value: 'assignment', label: Text(tr.studentKindAssignment)),
            ButtonSegment(value: 'exam', label: Text(tr.studentKindExam)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: Gap.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(_due == null
              ? tr.studentNoDue
              : StudentEngine.isoDate(_due!)),
          trailing: _due == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _due = null)),
          onTap: _pickDate,
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    if (_title.text.trim().isEmpty) {
      _toast(context, tr.studentTitleRequired);
      return;
    }
    setState(() => _saving = true);
    final body = {
      'title': _title.text.trim(),
      'kind': _kind,
      'due_date': _due == null ? null : StudentEngine.isoDate(_due!),
      'done': widget.existing?['done'] ?? false,
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_assignPath, id, body);
      } else {
        await api.createItem(_assignPath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= CGPA =======================
class _CgpaTab extends StatelessWidget {
  final List<Map<String, dynamic>> courses;
  final Future<void> Function() onChanged;
  final Future<void> Function(BuildContext) onAdd;
  const _CgpaTab(
      {required this.courses, required this.onChanged, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = StudentEngine.computeCgpa(courses);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => onAdd(context),
        icon: const Icon(Icons.add),
        label: Text(tr.studentAddCourse),
      ),
      body: RefreshIndicator(
        onRefresh: onChanged,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            // headline CGPA card
            Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(children: [
                  Text(tr.studentCgpaLabel,
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                  const SizedBox(height: Gap.xs),
                  Text(r.honest ? '—' : r.cgpaDisplay,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: Gap.xs),
                  Text(
                      r.honest
                          ? tr.studentCgpaNoGrade
                          : tr.studentCreditsSummary(/* (band, credits) */
                              _bandText(tr, r.classBand), _fmtNum(r.gradedCredits)),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
            if (courses.isEmpty)
              StateMessage(
                icon: Icons.calculate_outlined,
                title: tr.studentCgpaEmptyTitle,
                message: tr.studentCgpaEmptyBody,
              )
            else ...[
              // transparent per-course contribution
              for (final c in r.courses)
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.sm),
                  child: ListTile(
                    title: Text(
                        c.title.isEmpty ? tr.studentUntitled : c.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.graded
                        ? tr.studentCourseMath(/* (contribution, credit, letter, point) */
                            c.contributionDisplay, _fmtNum(c.credit),
                            c.letter, c.pointDisplay)
                        : tr.studentCourseNoGrade(_fmtNum(c.credit))),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(context, _rawOf(c)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (await _confirmDelete(context, _coursePath, c.id,
                              tr.studentDeleteCourseBody)) {
                            await onChanged();
                          }
                        },
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: Gap.sm),
              _formulaNote(context, r),
            ],
            const SizedBox(height: Gap.md),
            _scaleTable(context),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _rawOf(CourseRow c) {
    for (final raw in courses) {
      if (raw['id'] == c.id) return raw;
    }
    return null;
  }

  Widget _formulaNote(BuildContext context, CgpaResult r) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr.studentFormulaTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(tr.studentFormulaBody(/* (cgpa, credits, quality) */ r.cgpaDisplay,
            _fmtNum(r.gradedCredits), r.qualityPointsDisplay)),
      ]),
    );
  }

  Widget _scaleTable(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr.studentScaleTitle,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(tr.studentScaleSubtitle,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      children: [
        Table(
          border: TableBorder.all(
              color: scheme.outlineVariant, borderRadius: BorderRadius.circular(Radii.xs)),
          columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.4)},
          children: [
            TableRow(
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
              children: [
                _cell(tr.studentScaleMarks, bold: true),
                _cell(tr.studentScaleGrade, bold: true),
                _cell(tr.studentScalePoint, bold: true),
              ],
            ),
            for (final row in StudentEngine.scaleRows)
              TableRow(children: [
                _cell(row.band),
                _cell(row.letter),
                _cell(row.pointDisplay),
              ]),
          ],
        ),
      ],
    );
  }

  Widget _cell(String s, {bool bold = false}) => Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Text(s,
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
      );

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await _showCourseEditor(context, existing);
    if (changed == true) await onChanged();
  }
}

Future<bool?> _showCourseEditor(
    BuildContext context, Map<String, dynamic>? existing) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CourseEditor(existing: existing),
  );
}

class _CourseEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _CourseEditor({this.existing});
  @override
  State<_CourseEditor> createState() => _CourseEditorState();
}

class _CourseEditorState extends State<_CourseEditor> {
  late final TextEditingController _title;
  late final TextEditingController _credit;
  String? _letter;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _credit = TextEditingController(text: (e?['credit'] ?? '').toString());
    final lt = (e?['letter'] ?? '').toString().toUpperCase();
    if (StudentEngine.letters.contains(lt)) _letter = lt;
  }

  @override
  void dispose() {
    _title.dispose();
    _credit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.studentAddCourse
                : tr.studentEditCourse,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: tr.studentCourseTitleLabel),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _credit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr.studentCreditLabel),
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          initialValue: _letter,
          decoration: InputDecoration(labelText: tr.studentGradeLabel),
          items: [
            for (final l in StudentEngine.letters)
              DropdownMenuItem(
                  value: l,
                  child: Text('$l  ·  ${StudentEngine.pointForLetter(l)}')),
          ],
          onChanged: (v) => setState(() => _letter = v),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final credit = double.tryParse(_credit.text.trim());
    if (_title.text.trim().isEmpty) {
      _toast(context, tr.studentTitleRequired);
      return;
    }
    if (credit == null || credit <= 0) {
      _toast(context, tr.studentCreditInvalid);
      return;
    }
    setState(() => _saving = true);
    final body = {
      'title': _title.text.trim(),
      'credit': credit,
      'letter': _letter,
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_coursePath, id, body);
      } else {
        await api.createItem(_coursePath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= GOALS =======================
class _GoalsTab extends StatelessWidget {
  final List<Map<String, dynamic>> goals;
  final Future<void> Function() onChanged;
  const _GoalsTab({required this.goals, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = StudentEngine.goalProgress(goals);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: Text(tr.studentAddGoal),
      ),
      body: goals.isEmpty
          ? StateMessage(
              icon: Icons.checklist_rtl_outlined,
              title: tr.studentGoalsEmptyTitle,
              message: tr.studentGoalsEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(tr.studentGoalProgress(p.done, p.total),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Text('${p.percent}%',
                                style:
                                    TextStyle(color: scheme.primary, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: Gap.sm),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          child: LinearProgressIndicator(
                              value: p.total == 0 ? 0 : p.done / p.total,
                              minHeight: 8),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  for (final g in goals)
                    Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        leading: Checkbox(
                          value: g['done'] == true,
                          onChanged: (_) => _toggle(context, g),
                        ),
                        title: Text(
                          (g['title'] ?? '').toString().isEmpty
                              ? tr.studentUntitled
                              : g['title'].toString(),
                          style: TextStyle(
                            decoration: g['done'] == true
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await _confirmDelete(context, _goalPath,
                                g['id'], tr.studentDeleteGoalBody)) {
                              await onChanged();
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _toggle(BuildContext context, Map<String, dynamic> g) async {
    final api = context.read<AppState>().api;
    if (g['id'] is! int) return;
    try {
      await api.updateItem(_goalPath, g['id'] as int,
          {'title': g['title'], 'done': g['done'] != true});
      await onChanged();
    } catch (_) {
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context).saveFailed);
      }
    }
  }

  Future<void> _add(BuildContext context) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.studentAddGoal),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr.studentGoalLabel),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(tr.save)),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await api.createItem(_goalPath, {'title': text.trim(), 'done': false});
      await onChanged();
    } catch (_) {
      if (context.mounted) _toast(context, tr.saveFailed);
    }
  }
}

String _fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

String _bandText(AppLocalizations tr, String key) {
  switch (key) {
    case 'outstanding':
      return tr.studentBandOutstanding;
    case 'very_good':
      return tr.studentBandVeryGood;
    case 'satisfactory':
      return tr.studentBandSatisfactory;
    case 'needs_improvement':
      return tr.studentBandNeedsImprovement;
    default:
      return tr.studentCgpaNoGrade;
  }
}
