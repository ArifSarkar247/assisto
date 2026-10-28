import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/pa_tasks_engine.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// PA SECRETARY MODE — personal-task OVERSIGHT (#115, §14, ADVANCED).
///
/// The PA's view of the owner's personal to-dos it is overseeing: a prioritised
/// list (overdue first, then urgent→low), status (todo / doing / done), due
/// dates with an honest OVERDUE flag (computed from the real `now`), add / edit
/// / complete, and a progress summary header. DELETE raises a confirm gate.
///
/// All ordering / overdue / progress logic lives in `pa_tasks_engine.dart`
/// (mirror of `backend/core/logic/pa_tasks.py`); `now` is always passed in so
/// overdue is honest and deterministic. Managing these tasks is itself a
/// delegated capability — the server gates reads/writes on the delegate's
/// stored scopes (see up_pa3_integration.md).
class PersonalTasksScreen extends StatefulWidget {
  const PersonalTasksScreen({super.key});
  @override
  State<PersonalTasksScreen> createState() => _PersonalTasksScreenState();
}

class _PersonalTasksScreenState extends State<PersonalTasksScreen> {
  List<PaTask> _tasks = [];
  bool _loading = true;
  String? _error;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await PaTasksStore.load();
      if (!mounted) return;
      setState(() {
        _tasks = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _persist() async => PaTasksStore.save(_tasks);

  Future<void> _addOrEdit([PaTask? existing]) async {
    final result = await showAppSheet<PaTask>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _TaskEditor(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (existing == null) {
        _tasks = [..._tasks, result];
      } else {
        _tasks = _tasks.map((x) => x.id == existing.id ? result : x).toList();
      }
    });
    await _persist();
  }

  Future<void> _cycleStatus(PaTask task) async {
    final next = task.status == statusTodo
        ? statusDoing
        : task.status == statusDoing
            ? statusDone
            : statusTodo;
    setState(() {
      _tasks =
          _tasks.map((x) => x.id == task.id ? x.copyWith(status: next) : x).toList();
    });
    await _persist();
  }

  Future<void> _delete(PaTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.delete_outline_rounded, color: Brand.danger),
        title: Text(t.paTaskDeleteTitle),
        content: Text(t.paTaskDeleteBody(task.title)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _tasks = _tasks.where((x) => x.id != task.id).toList());
    await _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.commonDeleted)));
  }

  String _statusLabel(String s) {
    switch (s) {
      case statusDoing:
        return t.paTaskStatusDoing;
      case statusDone:
        return t.paTaskStatusDone;
      default:
        return t.paTaskStatusTodo;
    }
  }

  String _priorityLabel(String p) {
    switch (p) {
      case priorityUrgent:
        return t.paTaskPriorityUrgent;
      case priorityHigh:
        return t.paTaskPriorityHigh;
      case priorityLow:
        return t.paTaskPriorityLow;
      default:
        return t.paTaskPriorityNormal;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.paTasksTitle)),
      floatingActionButton: (_configured && !_loading && _error == null)
          ? FloatingActionButton.extended(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.paTaskAdd),
            )
          : null,
      body: _body(),
    );
  }

  bool get _configured => _tasks.isNotEmpty;

  Widget _body() {
    if (_loading) return const SkeletonList(count: 5);
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: Brand.danger,
        title: t.paTasksLoadError,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_tasks.isEmpty) {
      // First-use welcome state.
      return StateMessage(
        icon: Icons.checklist_rtl_rounded,
        tint: Brand.blue,
        title: t.paTasksWelcomeTitle,
        message: t.paTasksWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(t.paTaskAdd),
        ),
      );
    }

    final now = DateTime.now();
    final ordered = orderTasks(_tasks, now);
    final progress = progressSummary(_tasks, now);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        itemCount: ordered.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          if (i == 0) return _progressHeader(progress);
          final task = ordered[i - 1];
          return _TaskTile(
            task: task,
            overdue: isOverdue(task, now),
            statusLabel: _statusLabel(task.status),
            priorityLabel: _priorityLabel(task.priority),
            overdueLabel: t.paTaskOverdue,
            onToggleStatus: () => _cycleStatus(task),
            onEdit: () => _addOrEdit(task),
            onDelete: () => _delete(task),
          );
        },
      ),
    );
  }

  Widget _progressHeader(PaProgress p) {
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.paProgressDone(p.percentDone),
              style: AType.headlineSmall.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: p.total == 0 ? 0 : p.percentDone / 100.0,
              minHeight: 8,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(height: Gap.md),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            children: [
              _stat(t.paStatTodo(p.todo)),
              _stat(t.paStatDoing(p.doing)),
              _stat(t.paStatDone(p.done)),
              if (p.overdue > 0)
                _stat(t.paStatOverdue(p.overdue), danger: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String text, {bool danger = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: danger
            ? Brand.danger.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(text,
          style: AType.bodySmall.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final PaTask task;
  final bool overdue;
  final String statusLabel;
  final String priorityLabel;
  final String overdueLabel;
  final VoidCallback onToggleStatus;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _TaskTile({
    required this.task,
    required this.overdue,
    required this.statusLabel,
    required this.priorityLabel,
    required this.overdueLabel,
    required this.onToggleStatus,
    required this.onEdit,
    required this.onDelete,
  });

  Color _priorityColor() {
    switch (task.priority) {
      case priorityUrgent:
        return Brand.danger;
      case priorityHigh:
        return Brand.warning;
      case priorityLow:
        return Brand.success;
      default:
        return Brand.blue;
    }
  }

  IconData _statusIcon() {
    switch (task.status) {
      case statusDoing:
        return Icons.timelapse_rounded;
      case statusDone:
        return Icons.check_circle_rounded;
      default:
        return Icons.radio_button_unchecked_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = task.status == statusDone;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border(
            left: BorderSide(color: _priorityColor(), width: 4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              onPressed: onToggleStatus,
              icon: Icon(_statusIcon(),
                  color: done ? Brand.success : scheme.onSurfaceVariant),
              tooltip: statusLabel,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  Text(
                    task.title,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, decoration:
                          done ? TextDecoration.lineThrough : null, color: done ? scheme.onSurfaceVariant : null),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: Gap.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _badge(priorityLabel, _priorityColor()),
                      _badge(statusLabel, scheme.primary),
                      if (task.due.isNotEmpty)
                        _badge(_dueText(task.due),
                            overdue ? Brand.danger : scheme.onSurfaceVariant,
                            icon: Icons.event_rounded),
                      if (overdue)
                        _badge(overdueLabel, Brand.danger,
                            icon: Icons.warning_amber_rounded, filled: true),
                    ],
                  ),
                  if (task.note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(task.note,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (ctx) {
                final t = AppLocalizations.of(ctx);
                return [
                  PopupMenuItem(value: 'edit', child: Text(t.edit)),
                  PopupMenuItem(value: 'delete', child: Text(t.delete)),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  String _dueText(String iso) {
    final d = DateTime.tryParse(iso.endsWith('Z')
        ? iso.substring(0, iso.length - 1)
        : iso);
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Widget _badge(String text, Color color,
      {IconData? icon, bool filled = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.9 : 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: filled ? Colors.white : color),
          const SizedBox(width: 3),
        ],
        Text(text,
            style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700, color: filled ? Colors.white : color)),
      ]),
    );
  }
}

/// Add / edit sheet. Returns a normalized PaTask or null on cancel.
class _TaskEditor extends StatefulWidget {
  final PaTask? existing;
  const _TaskEditor({this.existing});
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.existing?.note ?? '');
  late String _status = widget.existing?.status ?? statusTodo;
  late String _priority = widget.existing?.priority ?? priorityNormal;
  late DateTime? _due =
      widget.existing != null && widget.existing!.due.isNotEmpty
          ? DateTime.tryParse(widget.existing!.due)
          : null;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  String _priorityLabel(String p) {
    switch (p) {
      case priorityUrgent:
        return t.paTaskPriorityUrgent;
      case priorityHigh:
        return t.paTaskPriorityHigh;
      case priorityLow:
        return t.paTaskPriorityLow;
      default:
        return t.paTaskPriorityNormal;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case statusDoing:
        return t.paTaskStatusDoing;
      case statusDone:
        return t.paTaskStatusDone;
      default:
        return t.paTaskStatusTodo;
    }
  }

  void _save() {
    final problems = validateTask(
        title: _title.text, due: _due?.toIso8601String() ?? '');
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.paTaskTitleRequired)));
      return;
    }
    final task = normalizeTask(
      id: widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text,
      status: _status,
      priority: _priority,
      due: _due?.toIso8601String() ?? '',
      note: _note.text.trim(),
    );
    Navigator.pop(context, task);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.existing == null
                    ? t.paTaskAdd
                    : t.paTaskEditTitle,
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t.paTaskTitleLabel,
                hintText: t.paTaskTitleHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.paTaskPriorityLabel,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final p in kPriorities)
                  ChoiceChip(
                    label: Text(_priorityLabel(p)),
                    selected: _priority == p,
                    onSelected: (_) => setState(() => _priority = p),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            Text(t.paTaskStatusLabel,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final s in kStatuses)
                  ChoiceChip(
                    label: Text(_statusLabel(s)),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_rounded, size: 18),
                  label: Text(_due == null
                      ? t.paTaskSetDue
                      : '${_due!.year}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _due ?? now,
                      firstDate: DateTime(now.year - 1),
                      lastDate: DateTime(now.year + 5),
                    );
                    if (picked != null) setState(() => _due = picked);
                  },
                ),
              ),
              if (_due != null)
                IconButton(
                  tooltip: t.paTaskClearDue,
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () => setState(() => _due = null),
                ),
            ]),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t.paTaskNoteLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save)),
            ),
          ],
        ),
      ),
    );
  }
}
