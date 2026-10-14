import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/task_manager_model.dart';

/// Task Manager (feature #21, SPEC v2.1 §21 ADVANCED).
///
/// Projects → tasks on a board. Create/edit/delete projects; each project has a
/// Kanban board (To-do / Doing / Done) with tasks movable between columns, plus
/// a list view and status/assignee filters. Tasks carry title, description,
/// assignee (free-text name or a Circle member), due date, priority and a
/// progress %. Honest overdue flags and a per-project progress summary.
///
/// Persistence uses the proven generic REST-collection pattern: two owner-
/// scoped collections, `tasks_projects` and `tasks_items` (the integrator
/// registers the matching OwnedViewSets — see up_taskmgr_integration.md). This
/// screen only calls the existing ApiClient generic helpers (listItems /
/// createItem / updateItem / deleteItem); it does NOT edit api.dart.
///
/// §21: offline-first cache, skeleton loading, honest empty/welcome/error+retry
/// states, confirm gates on every destructive action, bilingual (zero Bangla
/// literals — all strings via tmStr), no clipped text at 360dp.
class TaskManagerScreen extends StatefulWidget {
  const TaskManagerScreen({super.key});
  @override
  State<TaskManagerScreen> createState() => _TaskManagerScreenState();
}

class _TaskManagerScreenState extends State<TaskManagerScreen> {
  static const _projPath = 'tasks_projects';
  static const _taskPath = 'tasks_items';
  static const _cacheKey = 'taskmgr_cache_v1';

  List<Project> _projects = [];
  List<TaskItem> _tasks = [];
  bool _loading = true, _error = false, _offline = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  DateTime get _now => DateTime.now();

  // -------------------------------------------------- load / cache
  Future<void> _bootstrap() async {
    final cached = await _readCache();
    if (cached != null && mounted) {
      setState(() {
        _projects = cached.$1;
        _tasks = cached.$2;
        _loading = false;
      });
    }
    await _load(silent: cached != null);
  }

  Future<(List<Project>, List<TaskItem>)?> _readCache() async {
    try {
      final raw = await Settings.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final p = (m['projects'] as List).cast<Map<String, dynamic>>();
      final t = (m['tasks'] as List).cast<Map<String, dynamic>>();
      return (
        p.map(Project.fromJson).toList(),
        t.map(TaskItem.fromJson).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache() async {
    try {
      await Settings.setString(
        _cacheKey,
        jsonEncode({
          'projects': _projects.map((p) => {'id': p.id, ...p.toJson()}).toList(),
          'tasks': _tasks.map((t) => {'id': t.id, ...t.toJson()}).toList(),
        }),
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = false;
      });
    }
    final api = context.read<AppState>().api;
    try {
      final pr = await api.listItems(_projPath);
      final tk = await api.listItems(_taskPath);
      _projects = pr.map(Project.fromJson).toList();
      _tasks = tk.map(TaskItem.fromJson).toList();
      _offline = false;
      _error = false;
      await _writeCache();
    } catch (_) {
      _offline = true;
      if (_projects.isEmpty && _tasks.isEmpty) _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------- project CRUD
  Future<void> _saveProject(Project p) async {
    final api = context.read<AppState>().api;
    try {
      if (p.id == null) {
        final created = await api.createItem(_projPath, p.toJson());
        p.id = Project.fromJson(created).id;
        _projects = [..._projects, p];
      } else {
        await api.updateItem(_projPath, p.id!, p.toJson());
        _projects = [for (final x in _projects) if (x.id == p.id) p else x];
      }
      _toast(tmStr(context, 'tmProjectSaved'));
    } catch (_) {
      if (p.id == null) _projects = [..._projects, p];
      _toast(tmStr(context, 'tmSavedOffline'));
    }
    await _writeCache();
    if (mounted) setState(() {});
  }

  Future<void> _deleteProject(Project p) async {
    final api = context.read<AppState>().api;
    final doomedTasks = _tasks.where((t) => t.projectId == p.id).toList();
    try {
      for (final t in doomedTasks) {
        if (t.id != null) await api.deleteItem(_taskPath, t.id!);
      }
      if (p.id != null) await api.deleteItem(_projPath, p.id!);
    } catch (_) {/* offline: drop locally anyway */}
    _tasks = _tasks.where((t) => t.projectId != p.id).toList();
    _projects = _projects.where((x) => x.id != p.id).toList();
    await _writeCache();
    _toast(tmStr(context, 'tmProjectDeleted'));
    if (mounted) setState(() {});
  }

  // -------------------------------------------------- task CRUD
  Future<void> _saveTask(TaskItem t) async {
    final api = context.read<AppState>().api;
    try {
      if (t.id == null) {
        final created = await api.createItem(_taskPath, t.toJson());
        t.id = TaskItem.fromJson(created).id;
        _tasks = [..._tasks, t];
      } else {
        await api.updateItem(_taskPath, t.id!, t.toJson());
        _tasks = [for (final x in _tasks) if (x.id == t.id) t else x];
      }
      _toast(tmStr(context, 'tmTaskSaved'));
    } catch (_) {
      if (t.id == null) _tasks = [..._tasks, t];
      _toast(tmStr(context, 'tmSavedOffline'));
    }
    await _writeCache();
    if (mounted) setState(() {});
  }

  Future<void> _deleteTask(TaskItem t) async {
    final api = context.read<AppState>().api;
    try {
      if (t.id != null) await api.deleteItem(_taskPath, t.id!);
    } catch (_) {/* offline */}
    _tasks = _tasks.where((x) => x.id != t.id).toList();
    await _writeCache();
    _toast(tmStr(context, 'tmTaskDeleted'));
    if (mounted) setState(() {});
  }

  Future<void> _moveTask(TaskItem t, String toStatus) async {
    if (!kBoardColumns.contains(toStatus) || t.status == toStatus) return;
    final updated = t.copy();
    final wasDone = updated.status == kStatusDone;
    updated.status = toStatus;
    if (toStatus == kStatusDone) {
      updated.progress = 100;
    } else if (wasDone && updated.progress == 100) {
      updated.progress = 0;
    }
    await _saveTask(updated);
  }

  // -------------------------------------------------- confirm gates
  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tmStr(ctx, 'tmCancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(tmStr(ctx, 'tmDelete')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // -------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tmStr(context, 'tmTitle'))),
      body: _body(),
      floatingActionButton: (!_loading && !_error && _projects.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: _openProjectEditor,
              icon: const Icon(Icons.add),
              label: Text(tmStr(context, 'tmNewProject')),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(count: 5);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: tmStr(context, 'tmLoadFailed'),
        message: tmStr(context, 'tmLoadFailedBody'),
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(tmStr(context, 'tmRetry')),
        ),
      );
    }
    if (_projects.isEmpty) return _welcome();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        children: [
          if (_offline) _offlineBanner(),
          for (final p in _projects) ...[
            _ProjectCard(
              project: p,
              summary: ProgressSummary.of(
                  _tasks.where((t) => t.projectId == p.id).toList(), _now),
              onOpen: () => _openProject(p),
              onEdit: () => _openProjectEditor(existing: p),
              onDelete: () => _confirmDeleteProject(p),
            ),
            const SizedBox(height: Gap.md),
          ],
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        const Icon(Icons.wifi_off, size: 18, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(tmStr(context, 'tmOffline'),
                style: TextStyle(color: scheme.onSurface))),
      ]),
    );
  }

  Widget _welcome() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      children: [
        const SizedBox(height: 48),
        Center(
          child: Container(
            height: 84,
            width: 84,
            decoration: const BoxDecoration(
                gradient: Brand.gradient, shape: BoxShape.circle),
            child: const Icon(Icons.dashboard_customize_outlined,
                size: 40, color: Colors.white),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
          child: Column(children: [
            Text(tmStr(context, 'tmWelcomeTitle'),
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Text(tmStr(context, 'tmWelcomeBody'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
            const SizedBox(height: Gap.xl),
            FilledButton.icon(
              onPressed: _openProjectEditor,
              icon: const Icon(Icons.add),
              label: Text(tmStr(context, 'tmCreateFirstProject')),
            ),
          ]),
        ),
      ],
    );
  }

  // -------------------------------------------------- navigation
  Future<void> _openProject(Project p) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ProjectBoardScreen(
        project: p,
        // A live getter (not a snapshot): the parent reassigns `_tasks` on every
        // save/move, so the board must always read the CURRENT list.
        tasksOf: () => _tasks,
        onSaveTask: _saveTask,
        onMoveTask: _moveTask,
        onDeleteTask: (t) async {
          final ok = await _confirm(tmStr(context, 'tmDeleteTaskQ'), t.title);
          if (ok) await _deleteTask(t);
          return ok;
        },
      ),
    ));
    // Returning from the board may have mutated tasks; reflect it.
    if (mounted) setState(() {});
  }

  Future<void> _confirmDeleteProject(Project p) async {
    final ok = await _confirm(
        tmStr(context, 'tmDeleteProjectQ'), tmStr(context, 'tmDeleteProjectBody'));
    if (ok) await _deleteProject(p);
  }

  Future<void> _openProjectEditor({Project? existing}) async {
    final result = await showModalBottomSheet<Project>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProjectEditor(existing: existing),
    );
    if (result != null) await _saveProject(result);
  }
}

// ===========================================================================
// Project card (list row with inline progress summary)
// ===========================================================================
class _ProjectCard extends StatelessWidget {
  final Project project;
  final ProgressSummary summary;
  final VoidCallback onOpen, onEdit, onDelete;
  const _ProjectCard({
    required this.project,
    required this.summary,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(project.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(tmStr(context, 'tmEdit'))),
                  PopupMenuItem(
                      value: 'delete', child: Text(tmStr(context, 'tmDelete'))),
                ],
              ),
            ]),
            if (project.description.trim().isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(project.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: LinearProgressIndicator(
                    value: summary.total == 0 ? 0 : summary.percentDone / 100,
                    minHeight: 8,
                    backgroundColor: scheme.surfaceContainerHighest,
                    color: Brand.success,
                  ),
                ),
              ),
              const SizedBox(width: Gap.md),
              Text(tmStrNum(context, 'tmPercentDone', summary.percentDone),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              _pill(context, Icons.list_alt_outlined,
                  tmStrNum(context, 'tmSummaryLine', summary.total), null),
              if (summary.overdue > 0)
                _pill(context, Icons.warning_amber_rounded,
                    tmStrNum(context, 'tmOverdueCount', summary.overdue),
                    Brand.danger),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _pill(BuildContext c, IconData icon, String label, Color? tint) {
    final color = tint ?? Theme.of(c).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: color, fontSize: 12.5)),
    ]);
  }
}

// ===========================================================================
// Project editor sheet
// ===========================================================================
class _ProjectEditor extends StatefulWidget {
  final Project? existing;
  const _ProjectEditor({this.existing});
  @override
  State<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<_ProjectEditor> {
  late final _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final _desc =
      TextEditingController(text: widget.existing?.description ?? '');
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = tmStr(context, 'tmNameRequired'));
      return;
    }
    final p = widget.existing ?? Project();
    p.name = _name.text.trim();
    p.description = _desc.text.trim();
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tmStr(context, 'tmNewProject')
                : tmStr(context, 'tmEditProject'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          decoration: InputDecoration(
            labelText: tmStr(context, 'tmProjectName'),
            hintText: tmStr(context, 'tmProjectNameHint'),
            errorText: _nameError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _desc,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: tmStr(context, 'tmProjectDesc'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
              onPressed: _submit, child: Text(tmStr(context, 'tmSave'))),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Per-project board / list screen with filters
// ===========================================================================
class _ProjectBoardScreen extends StatefulWidget {
  final Project project;
  final List<TaskItem> Function() tasksOf;
  final Future<void> Function(TaskItem) onSaveTask;
  final Future<void> Function(TaskItem, String) onMoveTask;
  final Future<bool> Function(TaskItem) onDeleteTask;
  const _ProjectBoardScreen({
    required this.project,
    required this.tasksOf,
    required this.onSaveTask,
    required this.onMoveTask,
    required this.onDeleteTask,
  });
  @override
  State<_ProjectBoardScreen> createState() => _ProjectBoardScreenState();
}

class _ProjectBoardScreenState extends State<_ProjectBoardScreen> {
  bool _board = true;
  String? _statusFilter;
  String? _assigneeFilter; // '' sentinel = unassigned

  DateTime get _now => DateTime.now();

  List<TaskItem> get _projectTasks =>
      widget.tasksOf().where((t) => t.projectId == widget.project.id).toList();

  List<TaskItem> get _filtered {
    var list = _projectTasks;
    if (_assigneeFilter == '') {
      list = filterUnassigned(list);
    } else if (_assigneeFilter != null) {
      list = filterTasks(list, assignee: _assigneeFilter);
    }
    if (_statusFilter != null) {
      list = filterTasks(list, status: _statusFilter);
    }
    return list;
  }

  bool get _hasFilter => _statusFilter != null || _assigneeFilter != null;

  @override
  Widget build(BuildContext context) {
    final summary = ProgressSummary.of(_projectTasks, _now);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _board
                ? tmStr(context, 'tmViewList')
                : tmStr(context, 'tmViewBoard'),
            icon: Icon(_board ? Icons.view_list_outlined : Icons.view_column_outlined),
            onPressed: () => setState(() => _board = !_board),
          ),
          _filterMenu(),
        ],
      ),
      body: Column(children: [
        _summaryBar(summary),
        if (_hasFilter) _activeFilterBar(),
        Expanded(child: _projectTasks.isEmpty
            ? _emptyTasks()
            : (_filtered.isEmpty ? _noMatch() : _content())),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTaskEditor(),
        icon: const Icon(Icons.add_task),
        label: Text(tmStr(context, 'tmNewTask')),
      ),
    );
  }

  Widget _summaryBar(ProgressSummary s) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: s.total == 0 ? 0 : s.percentDone / 100,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: Brand.success,
            ),
          ),
        ),
        const SizedBox(width: Gap.md),
        Text(tmStrNum(context, 'tmPercentDone', s.percentDone),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        if (s.overdue > 0) ...[
          const SizedBox(width: Gap.md),
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: Brand.danger),
          const SizedBox(width: 4),
          Text(tmNum(context, s.overdue),
              style: const TextStyle(
                  color: Brand.danger, fontWeight: FontWeight.w700)),
        ],
      ]),
    );
  }

  Widget _activeFilterBar() {
    final scheme = Theme.of(context).colorScheme;
    final chips = <String>[];
    if (_statusFilter != null) chips.add(statusLabel(context, _statusFilter!));
    if (_assigneeFilter == '') {
      chips.add(tmStr(context, 'tmUnassigned'));
    } else if (_assigneeFilter != null) {
      chips.add(_assigneeFilter!);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
      child: Row(children: [
        const Icon(Icons.filter_alt_outlined, size: 16),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(chips.join('  •  '),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        TextButton(
          onPressed: () => setState(() {
            _statusFilter = null;
            _assigneeFilter = null;
          }),
          child: Text(tmStr(context, 'tmClearFilters')),
        ),
      ]),
    );
  }

  Widget _filterMenu() {
    final names = assigneesOf(_projectTasks);
    final hasUnassigned = _projectTasks.any((t) => t.assignee.trim().isEmpty);
    return PopupMenuButton<String>(
      tooltip: tmStr(context, 'tmFilter'),
      icon: Icon(_hasFilter ? Icons.filter_alt : Icons.filter_alt_outlined),
      onSelected: (v) {
        setState(() {
          if (v == 'all') {
            _statusFilter = null;
            _assigneeFilter = null;
          } else if (v.startsWith('s:')) {
            _statusFilter = v == 's:all' ? null : v.substring(2);
          } else if (v.startsWith('a:')) {
            final raw = v.substring(2);
            _assigneeFilter = raw == 'all' ? null : (raw == 'unassigned' ? '' : raw);
          }
        });
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'all', child: Text(tmStr(context, 'tmClearFilters'))),
        const PopupMenuDivider(),
        PopupMenuItem(
            enabled: false,
            child: Text(tmStr(context, 'tmByStatus'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
        for (final s in kBoardColumns)
          CheckedPopupMenuItem(
              value: 's:$s',
              checked: _statusFilter == s,
              child: Text(statusLabel(context, s))),
        if (names.isNotEmpty || hasUnassigned) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
              enabled: false,
              child: Text(tmStr(context, 'tmByAssignee'),
                  style:
                      const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          if (hasUnassigned)
            CheckedPopupMenuItem(
                value: 'a:unassigned',
                checked: _assigneeFilter == '',
                child: Text(tmStr(context, 'tmUnassigned'))),
          for (final n in names)
            CheckedPopupMenuItem(
                value: 'a:$n',
                checked: _assigneeFilter == n,
                child: Text(n, overflow: TextOverflow.ellipsis)),
        ],
      ],
    );
  }

  Widget _emptyTasks() => StateMessage(
        icon: Icons.add_task,
        title: tmStr(context, 'tmNoTasksYet'),
        message: tmStr(context, 'tmNoTasksBody'),
        action: FilledButton.icon(
          onPressed: () => _openTaskEditor(),
          icon: const Icon(Icons.add),
          label: Text(tmStr(context, 'tmNewTask')),
        ),
      );

  Widget _noMatch() => StateMessage(
        icon: Icons.filter_alt_off_outlined,
        title: tmStr(context, 'tmNoMatch'),
        message: tmStr(context, 'tmNoMatchBody'),
        action: TextButton(
          onPressed: () => setState(() {
            _statusFilter = null;
            _assigneeFilter = null;
          }),
          child: Text(tmStr(context, 'tmClearFilters')),
        ),
      );

  Widget _content() => _board ? _boardView() : _listView();

  Widget _listView() {
    final ordered = orderTasks(_filtered, _now);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
      itemCount: ordered.length,
      separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
      itemBuilder: (_, i) => _TaskTile(
        task: ordered[i],
        now: _now,
        onTap: () => _openTaskEditor(existing: ordered[i]),
        onMove: (s) => widget.onMoveTask(ordered[i], s).then((_) => _refresh()),
      ),
    );
  }

  Widget _boardView() {
    final cols = boardColumns(_filtered, _now);
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
      children: [
        for (final s in kBoardColumns)
          _BoardColumn(
            status: s,
            tasks: cols[s] ?? const [],
            now: _now,
            onTapTask: (t) => _openTaskEditor(existing: t),
            onMove: (t, to) => widget.onMoveTask(t, to).then((_) => _refresh()),
          ),
      ],
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openTaskEditor({TaskItem? existing}) async {
    final names = assigneesOf(widget.tasksOf());
    final result = await showModalBottomSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TaskEditor(
        existing: existing,
        projectId: widget.project.id,
        knownAssignees: names,
      ),
    );
    if (result == null) return;
    if (result.deleted && existing != null) {
      final ok = await widget.onDeleteTask(existing);
      if (ok) _refresh();
      return;
    }
    if (result.task != null) {
      await widget.onSaveTask(result.task!);
      _refresh();
    }
  }
}

// ===========================================================================
// Board column
// ===========================================================================
class _BoardColumn extends StatelessWidget {
  final String status;
  final List<TaskItem> tasks;
  final DateTime now;
  final void Function(TaskItem) onTapTask;
  final void Function(TaskItem, String) onMove;
  const _BoardColumn({
    required this.status,
    required this.tasks,
    required this.now,
    required this.onTapTask,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = statusColor(context, status);
    return Container(
      width: 280,
      margin: const EdgeInsets.only(right: Gap.md),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.sm),
          child: Row(children: [
            Container(width: 10, height: 10,
                decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
            const SizedBox(width: Gap.sm),
            Text(statusLabel(context, status),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: Gap.sm),
            Text(tmNum(context, tasks.length),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        ),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Text('—',
                      style: TextStyle(color: scheme.onSurfaceVariant)))
              : ListView.separated(
                  padding: const EdgeInsets.all(Gap.xs),
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (_, i) => _TaskTile(
                    task: tasks[i],
                    now: now,
                    compact: true,
                    onTap: () => onTapTask(tasks[i]),
                    onMove: (s) => onMove(tasks[i], s),
                  ),
                ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Task tile (shared by list + board)
// ===========================================================================
class _TaskTile extends StatelessWidget {
  final TaskItem task;
  final DateTime now;
  final bool compact;
  final VoidCallback onTap;
  final void Function(String) onMove;
  const _TaskTile({
    required this.task,
    required this.now,
    required this.onTap,
    required this.onMove,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overdue = isOverdue(task, now);
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(priorityIcon(task.priority),
                  size: 16, color: priorityColor(context, task.priority)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(task.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: task.status == kStatusDone
                          ? TextDecoration.lineThrough
                          : null,
                      color: task.status == kStatusDone
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    )),
              ),
              PopupMenuButton<String>(
                tooltip: tmStr(context, 'tmMoveTo'),
                icon: Icon(Icons.more_vert,
                    size: 18, color: scheme.onSurfaceVariant),
                onSelected: onMove,
                itemBuilder: (_) => [
                  for (final s in kBoardColumns)
                    if (s != task.status)
                      PopupMenuItem(
                        value: s,
                        child: Row(children: [
                          Icon(Icons.arrow_right_alt,
                              size: 16, color: statusColor(context, s)),
                          const SizedBox(width: Gap.sm),
                          Text(statusLabel(context, s)),
                        ]),
                      ),
                ],
              ),
            ]),
            if (!compact && task.description.trim().isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(task.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            if (task.status == kStatusDoing && task.progress > 0) ...[
              const SizedBox(height: Gap.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: LinearProgressIndicator(
                  value: task.progress / 100,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: Brand.blue,
                ),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              if (task.assignee.trim().isNotEmpty)
                _chip(context, Icons.person_outline, task.assignee, null),
              if (task.due.trim().isNotEmpty)
                _chip(
                    context,
                    overdue ? Icons.event_busy : Icons.event_outlined,
                    _dueLabel(context),
                    overdue ? Brand.danger : null),
              if (overdue)
                _chip(context, Icons.warning_amber_rounded,
                    tmStr(context, 'tmOverdue'), Brand.danger),
            ]),
          ]),
        ),
      ),
    );
  }

  String _dueLabel(BuildContext c) {
    final d = tmParseDue(task.due);
    if (d == null) return task.due;
    final y = tmNum(c, d.year);
    final m = tmNum(c, d.month);
    final day = tmNum(c, d.day);
    return '$y-$m-$day';
  }

  Widget _chip(BuildContext c, IconData icon, String label, Color? tint) {
    final scheme = Theme.of(c).colorScheme;
    final color = tint ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12)),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Task editor sheet
// ===========================================================================
class _TaskEditorResult {
  final TaskItem? task;
  final bool deleted;
  const _TaskEditorResult({this.task, this.deleted = false});
}

class _TaskEditor extends StatefulWidget {
  final TaskItem? existing;
  final int? projectId;
  final List<String> knownAssignees;
  const _TaskEditor({this.existing, this.projectId, required this.knownAssignees});
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late final _desc =
      TextEditingController(text: widget.existing?.description ?? '');
  late final _assignee =
      TextEditingController(text: widget.existing?.assignee ?? '');
  late String _status = widget.existing?.status ?? kStatusTodo;
  late String _priority = widget.existing?.priority ?? kPriorityNormal;
  late int _progress = widget.existing?.progress ?? 0;
  late DateTime? _due = tmParseDue(widget.existing?.due ?? '');
  String? _titleError;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _assignee.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final base = _due ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _due = picked);
  }

  void _submit() {
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = tmStr(context, 'tmTitleRequired'));
      return;
    }
    final t = widget.existing ?? TaskItem();
    t.projectId = widget.projectId;
    t.title = _title.text.trim();
    t.description = _desc.text.trim();
    t.assignee = _assignee.text.trim();
    t.status = _status;
    t.priority = _priority;
    t.due = _due == null
        ? ''
        : DateTime(_due!.year, _due!.month, _due!.day).toIso8601String();
    t.progress = _status == kStatusDone ? 100 : _progress;
    Navigator.pop(context, _TaskEditorResult(task: t));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Text(
                  widget.existing == null
                      ? tmStr(context, 'tmNewTask')
                      : tmStr(context, 'tmEditTask'),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (widget.existing != null)
              IconButton(
                tooltip: tmStr(context, 'tmDelete'),
                icon: const Icon(Icons.delete_outline, color: Brand.danger),
                onPressed: () => Navigator.pop(
                    context, const _TaskEditorResult(deleted: true)),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _title,
            autofocus: widget.existing == null,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) {
              if (_titleError != null) setState(() => _titleError = null);
            },
            decoration: InputDecoration(
              labelText: tmStr(context, 'tmTaskTitle'),
              hintText: tmStr(context, 'tmTaskTitleHint'),
              errorText: _titleError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _desc,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tmStr(context, 'tmTaskDesc'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _assignee,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: tmStr(context, 'tmAssignee'),
              hintText: tmStr(context, 'tmAssigneeHint'),
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.knownAssignees.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(spacing: Gap.sm, children: [
                for (final n in widget.knownAssignees.take(8))
                  ActionChip(
                    label: Text(n, overflow: TextOverflow.ellipsis),
                    onPressed: () => setState(() => _assignee.text = n),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: Gap.md),
          // status
          _label(context, tmStr(context, 'tmStatus')),
          Wrap(spacing: Gap.sm, children: [
            for (final s in kBoardColumns)
              ChoiceChip(
                label: Text(statusLabel(context, s)),
                selected: _status == s,
                onSelected: (_) => setState(() {
                  _status = s;
                  if (s == kStatusDone) _progress = 100;
                }),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // priority
          _label(context, tmStr(context, 'tmPriority')),
          Wrap(spacing: Gap.sm, children: [
            for (final p in kPriorities)
              ChoiceChip(
                avatar: Icon(priorityIcon(p),
                    size: 16, color: priorityColor(context, p)),
                label: Text(priorityLabel(context, p)),
                selected: _priority == p,
                onSelected: (_) => setState(() => _priority = p),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // due date
          _label(context, tmStr(context, 'tmDueDate')),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  _due == null
                      ? tmStr(context, 'tmPickDate')
                      : '${tmNum(context, _due!.year)}-${tmNum(context, _due!.month)}-${tmNum(context, _due!.day)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (_due != null)
              IconButton(
                tooltip: tmStr(context, 'tmNoDue'),
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() => _due = null),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // progress (only meaningful while not done; done is pinned to 100)
          _label(context,
              '${tmStr(context, 'tmProgress')} · ${tmNum(context, _status == kStatusDone ? 100 : _progress)}%'),
          Slider(
            value: (_status == kStatusDone ? 100 : _progress).toDouble(),
            min: 0,
            max: 100,
            divisions: 20,
            label: '${_status == kStatusDone ? 100 : _progress}%',
            onChanged: _status == kStatusDone
                ? null
                : (v) => setState(() => _progress = v.round()),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: _submit, child: Text(tmStr(context, 'tmSave'))),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ]),
      ),
    );
  }

  Widget _label(BuildContext c, String text) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Text(text,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(c).colorScheme.onSurfaceVariant)),
        ),
      );
}
