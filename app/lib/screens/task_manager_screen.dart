import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/task_manager_model.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2
import '../feature_flags.dart' show FeatureFlags; // p2plan
import '../widgets/rn_bits.dart' show pickCircleMember; // p2plan
import '../widgets/voice_input.dart'; // p2plan: Bangla voice quick-add
import '../widgets/reminders_nlp.dart' show parseReminder; // p2plan offline
import 'day_planner_screen.dart'; // p2plan

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
  // p2plan: lists other people shared WITH me (+ their tasks, loaded on open)
  List<Project> _sharedLists = [];
  List<TaskItem> _sharedTasks = [];
  bool _loading = true, _error = false, _offline = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
          'projects': _projects
              .map((p) => {
                    'id': p.id,
                    ...p.toJson(),
                    // p2plan: keep "shared" across an offline start
                    'people': p.people,
                    'role': p.role,
                  })
              .toList(),
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
    } catch (e) {
      _offline = true;
      if (_projects.isEmpty && _tasks.isEmpty) _error = true; _failCause = e;
    }
    await _loadShared();
    if (mounted) setState(() => _loading = false);
  }

  /// p2plan: lists shared with me. Not fatal — my own lists still show.
  Future<void> _loadShared() async {
    try {
      final r = await context.read<AppState>().api.getJson('/tasks/shared');
      final rows = (r['lists'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Project.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      _sharedLists = rows;
      // the cards show real progress: read each list (a few at most)
      for (final p in rows.take(10)) {
        try {
          await _loadSharedTasks(p);
        } catch (_) {/* that card shows its last known state */}
      }
    } catch (_) {/* offline / older server: section simply absent */}
  }

  Future<void> _loadSharedTasks(Project p) async {
    final r = await context.read<AppState>().api.getJson('/tasks/lists/${p.id}');
    final tasks = (r['tasks'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => TaskItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final fresh = Project.fromJson(Map<String, dynamic>.from(r));
    p.people = fresh.people;
    p.role = fresh.role;
    p.ownerName = fresh.ownerName;
    if (p.role == 'member') {
      _sharedTasks = [
        ..._sharedTasks.where((t) => t.projectId != p.id),
        ...tasks,
      ];
    } else {
      _tasks = [..._tasks.where((t) => t.projectId != p.id), ...tasks];
    }
  }

  Project? _projFor(int? id) {
    for (final p in [..._projects, ..._sharedLists]) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<TaskItem> get _allTasks => [..._tasks, ..._sharedTasks];

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// lifebar: honest failure with a Retry that re-sends the same input.
  void _notSaved(VoidCallback retry) {
    if (!mounted) return;
    final tr = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(tr.lbWTmNotSaved),
        action: SnackBarAction(label: tr.retry, onPressed: retry),
      ));
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
      // lifebar: never "saved offline" — nothing queues it. Keep the user's
      // input in memory and offer Retry instead.
      _notSaved(() => _saveProject(p));
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
    } catch (_) {
      // q1-seams: never "deleted" while the server still has it (it came back
      // on the next sync). Reload the real state instead.
      _toast(AppLocalizations.of(context).grpActionFailed);
      await _load(silent: true);
      return;
    }
    _tasks = _tasks.where((t) => t.projectId != p.id).toList();
    _projects = _projects.where((x) => x.id != p.id).toList();
    await _writeCache();
    _toast(tmStr(context, 'tmProjectDeleted'));
    if (mounted) setState(() {});
  }

  // -------------------------------------------------- task CRUD
  Future<void> _saveTask(TaskItem t) async {
    final api = context.read<AppState>().api;
    final proj = _projFor(t.projectId);
    if (proj != null && proj.isShared) return _saveShared(proj, t);
    TaskItem? before;
    for (final x in _tasks) {
      if (x.id != null && x.id == t.id) before = x;
    }
    final becameDone = t.status == kStatusDone &&
        (before == null || before.status != kStatusDone);
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
      // p2plan: a repeating task marked done brings its next occurrence
      final nxt = becameDone ? spawnNext(t, _now) : null;
      if (nxt != null) {
        final created = await api.createItem(_taskPath, nxt.toJson());
        nxt.id = TaskItem.fromJson(created).id;
        _tasks = [..._tasks, nxt];
        _toast(tmStr(context, 'tmNextAdded'));
      }
    } catch (_) {
      // lifebar: honest — the edit/move did NOT happen; Retry keeps the input
      _notSaved(() => _saveTask(t));
    }
    await _writeCache();
    if (mounted) setState(() {});
  }

  /// p2plan: a shared list writes through the server so the other people get
  /// "assigned" / "done" notifications and repeats spawn there.
  Future<void> _saveShared(Project p, TaskItem t) async {
    final api = context.read<AppState>().api;
    final member = p.role == 'member';
    try {
      final res = t.id == null
          ? await api.postJson('/tasks/lists/${p.id}/tasks', t.toJson())
          : await api.patchJson('/tasks/lists/${p.id}/tasks/${t.id}', t.toJson());
      final saved = TaskItem.fromJson(res);
      final spawned = res['spawned'] is Map
          ? TaskItem.fromJson(Map<String, dynamic>.from(res['spawned'] as Map))
          : null;
      List<TaskItem> upd(List<TaskItem> l) => [
            ...l.where((x) => x.id != saved.id),
            saved,
            if (spawned != null) spawned,
          ];
      if (member) {
        _sharedTasks = upd(_sharedTasks);
      } else {
        _tasks = upd(_tasks);
      }
      _toast(tmStr(context, spawned != null ? 'tmNextAdded' : 'tmTaskSaved'));
    } catch (_) {
      _notSaved(() => _saveShared(p, t));
    }
    if (!member) await _writeCache();
    if (mounted) setState(() {});
  }

  Future<void> _deleteTask(TaskItem t) async {
    final api = context.read<AppState>().api;
    final proj = _projFor(t.projectId);
    final subs = subtasksOf(_allTasks, t.id);
    try {
      if (proj != null && proj.isShared) {
        // the server removes the steps with their task
        if (t.id != null) await api.deleteJson('/tasks/lists/${proj.id}/tasks/${t.id}');
      } else {
        for (final s in subs) {
          if (s.id != null) await api.deleteItem(_taskPath, s.id!);
        }
        if (t.id != null) await api.deleteItem(_taskPath, t.id!);
      }
    } catch (_) {
      _toast(AppLocalizations.of(context).grpActionFailed); // q1-seams
      return;
    }
    final gone = {t.id, ...subs.map((s) => s.id)};
    _sharedTasks = _sharedTasks.where((x) => !gone.contains(x.id)).toList();
    _tasks = _tasks.where((x) => !gone.contains(x.id)).toList();
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
        scrollable: true, // insets: 200% text / keyboard
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
      appBar: AppBar(title: Text(tmStr(context, 'tmTitle')), actions: [
        if (FeatureFlags.instance.isOn('ai_daily_planner'))
          IconButton(
            tooltip: tmStr(context, 'tmOpenPlanner'),
            icon: const Icon(Icons.today_rounded),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DayPlannerScreen())),
          ),
      ]),
      body: _body(),
      floatingActionButton: (!_loading && !_error && _projects.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: _openProjectEditor,
              icon: const Icon(Icons.add_rounded),
              label: Text(tmStr(context, 'tmNewProject')),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(count: 5);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: tmStr(context, 'tmLoadFailed'),
        message: honestFailText(AppLocalizations.of(context), _failCause,
            otherwise: tmStr(context, 'tmLoadFailedBody')),
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(tmStr(context, 'tmRetry')),
        ),
      );
    }
    if (_projects.isEmpty && _sharedLists.isEmpty) return _welcome();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96)),
        children: [
          if (_offline) _offlineBanner(),
          if (_projects.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: FilledButton.icon(
                onPressed: _openProjectEditor,
                icon: const Icon(Icons.add_rounded),
                label: Text(tmStr(context, 'tmCreateFirstProject')),
              ),
            ),
          for (final p in _projects) ...[
            _ProjectCard(
              project: p,
              summary: ProgressSummary.of(
                  topLevel(_tasks.where((t) => t.projectId == p.id).toList()), _now),
              onOpen: () => _openProject(p),
              onEdit: () => _openProjectEditor(existing: p),
              onDelete: () => _confirmDeleteProject(p),
              onShare: () => _shareProject(p),
              onPeople: p.sharedCount > 0 ? () => _openPeople(p) : null,
            ),
            const SizedBox(height: Gap.md),
          ],
          if (_sharedLists.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
              child: Semantics(
                header: true,
                child: Text(tmStr(context, 'tmSharedWithMe'),
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ),
            for (final p in _sharedLists) ...[
              _ProjectCard(
                project: p,
                summary: ProgressSummary.of(
                    topLevel(_sharedTasks.where((t) => t.projectId == p.id).toList()),
                    _now),
                onOpen: () => _openProject(p),
                onLeave: () => _leaveList(p),
              ),
              const SizedBox(height: Gap.md),
            ],
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
        const Icon(Icons.wifi_off_rounded, size: 18, color: Brand.warning),
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
        const SizedBox(height: Gap.xxxl),
        Center(
          child: Container(
            height: 84,
            width: 84,
            decoration: const BoxDecoration(
                gradient: Brand.gradient, shape: BoxShape.circle),
            child: const Icon(Icons.dashboard_customize_rounded,
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
              icon: const Icon(Icons.add_rounded),
              label: Text(tmStr(context, 'tmCreateFirstProject')),
            ),
          ]),
        ),
      ],
    );
  }

  // -------------------------------------------------- navigation
  Future<void> _openProject(Project p) async {
    if (p.isShared) {
      // p2plan: shared lists are read fresh from the server (who is on it,
      // what changed since) — honest message when offline.
      try {
        await _loadSharedTasks(p);
      } catch (_) {
        if (p.role == 'member') {
          _toast(tmStr(context, 'tmNeedsInternet'));
          return;
        }
      }
      if (!mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ProjectBoardScreen(
        project: p,
        // A live getter (not a snapshot): the parent reassigns `_tasks` on every
        // save/move, so the board must always read the CURRENT list.
        tasksOf: () => _allTasks,
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

  // -------------------------------------------------- p2plan: sharing
  Future<void> _shareProject(Project p) async {
    if (p.id == null) return;
    final picked = await pickCircleMember(context,
        title: tmStr(context, 'tmShareTitle'),
        subtitle: tmStr(context, 'tmShareSub'));
    if (picked == null || !mounted) return;
    try {
      final r = await context.read<AppState>().api.postJson(
          '/tasks/lists/${p.id}/share', {'circle_ids': [picked['circle_id']]});
      final fresh = Project.fromJson({...r, 'id': p.id, 'role': 'owner'});
      p.people = fresh.people;
      p.role = 'owner';
      final skipped = (r['skipped'] as List? ?? const []);
      _toast(tmStr(context, skipped.isNotEmpty ? 'tmShareNotOnApp' : 'tmShared'));
      await _writeCache();
    } catch (_) {
      _toast(AppLocalizations.of(context).grpActionFailed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _unshare(Project p, int uid) async {
    try {
      final r = await context
          .read<AppState>()
          .api
          .postJson('/tasks/lists/${p.id}/unshare', {'uid': uid});
      p.people = Project.fromJson({...r, 'id': p.id}).people;
      if (p.sharedCount == 0) p.role = '';
      await _writeCache();
    } catch (_) {
      _toast(AppLocalizations.of(context).grpActionFailed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _openPeople(Project p) async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => ListView(
          shrinkWrap: true,
          padding: withNavBarInset(ctx, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
          children: [
            Text(tmStr(ctx, 'tmPeople'),
                style: Theme.of(ctx)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            for (final m in p.people.where((x) => x['role'] == 'member'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text('${m['name'] ?? ''}'),
                trailing: IconButton(
                  tooltip: tmStr(ctx, 'tmRemovePerson'),
                  icon: const Icon(Icons.person_remove_outlined),
                  onPressed: () async {
                    final uid = m['uid'] is int ? m['uid'] as int : int.tryParse('${m['uid']}');
                    if (uid == null) return;
                    await _unshare(p, uid);
                    setSheet(() {});
                  },
                ),
              ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              onPressed: () async {
                await _shareProject(p);
                setSheet(() {});
              },
              icon: const Icon(Icons.group_add_outlined),
              label: Text(tmStr(ctx, 'tmShare')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _leaveList(Project p) async {
    final ok = await _confirmAction(tmStr(context, 'tmLeaveQ'), tmStr(context, 'tmLeaveBody'),
        tmStr(context, 'tmLeave'));
    if (!ok || !mounted) return;
    try {
      await context.read<AppState>().api.postJson('/tasks/lists/${p.id}/unshare', {});
      _sharedLists = _sharedLists.where((x) => x.id != p.id).toList();
      _sharedTasks = _sharedTasks.where((t) => t.projectId != p.id).toList();
    } catch (_) {
      _toast(AppLocalizations.of(context).grpActionFailed);
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirmAction(String title, String body, String yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tmStr(ctx, 'tmCancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _confirmDeleteProject(Project p) async {
    final ok = await _confirm(
        tmStr(context, 'tmDeleteProjectQ'), tmStr(context, 'tmDeleteProjectBody'));
    if (ok) await _deleteProject(p);
  }

  Future<void> _openProjectEditor({Project? existing}) async {
    final result = await showAppSheet<Project>(
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
  final VoidCallback onOpen;
  // p2plan: my list -> edit / delete / share (+ people); a list shared WITH
  // me -> leave only.
  final VoidCallback? onEdit, onDelete, onShare, onPeople, onLeave;
  const _ProjectCard({
    required this.project,
    required this.summary,
    required this.onOpen,
    this.onEdit,
    this.onDelete,
    this.onShare,
    this.onPeople,
    this.onLeave,
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
                onSelected: (v) {
                  final cb = {
                    'edit': onEdit,
                    'delete': onDelete,
                    'share': onShare,
                    'people': onPeople,
                    'leave': onLeave,
                  }[v];
                  cb?.call();
                },
                itemBuilder: (_) => [
                  if (onShare != null)
                    PopupMenuItem(value: 'share', child: Text(tmStr(context, 'tmShare'))),
                  if (onPeople != null)
                    PopupMenuItem(value: 'people', child: Text(tmStr(context, 'tmPeople'))),
                  if (onEdit != null)
                    PopupMenuItem(value: 'edit', child: Text(tmStr(context, 'tmEdit'))),
                  if (onDelete != null)
                    PopupMenuItem(
                        value: 'delete', child: Text(tmStr(context, 'tmDelete'))),
                  if (onLeave != null)
                    PopupMenuItem(value: 'leave', child: Text(tmStr(context, 'tmLeave'))),
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
              _pill(context, Icons.list_alt_rounded,
                  tmStrNum(context, 'tmSummaryLine', summary.total), null),
              if (summary.overdue > 0)
                _pill(context, Icons.warning_amber_rounded,
                    tmStrNum(context, 'tmOverdueCount', summary.overdue),
                    Brand.danger),
              if (project.role == 'member' && project.ownerName.isNotEmpty)
                _pill(context, Icons.group_outlined,
                    tmStrName(context, 'tmSharedBy', project.ownerName), null)
              else if (project.sharedCount > 0)
                _pill(context, Icons.group_outlined,
                    tmStrNum(context, 'tmSharedCount', project.sharedCount), null),
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
      const SizedBox(width: Gap.xs),
      Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: AType.bodySmall.copyWith(color: color))),
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

  // p2plan: steps (subtasks) live inside their task, not on the board
  List<TaskItem> get _projectTasks => topLevel(
      widget.tasksOf().where((t) => t.projectId == widget.project.id).toList());

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
            tooltip: tmStr(context, 'tmQuickAdd'),
            icon: const Icon(Icons.keyboard_voice_outlined),
            onPressed: _quickAdd,
          ),
          IconButton(
            tooltip: _board
                ? tmStr(context, 'tmViewList')
                : tmStr(context, 'tmViewBoard'),
            icon: Icon(_board ? Icons.view_list_rounded : Icons.view_column_rounded),
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
        icon: const Icon(Icons.add_task_rounded),
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
          const SizedBox(width: Gap.xs),
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
        const Icon(Icons.filter_alt_rounded, size: 16),
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
      icon: Icon(_hasFilter ? Icons.filter_alt_rounded : Icons.filter_alt_outlined),
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
                style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700))),
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
                      AType.bodySmall.copyWith(fontWeight: FontWeight.w700))),
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
        icon: Icons.add_task_rounded,
        title: tmStr(context, 'tmNoTasksYet'),
        message: tmStr(context, 'tmNoTasksBody'),
        action: FilledButton.icon(
          onPressed: () => _openTaskEditor(),
          icon: const Icon(Icons.add_rounded),
          label: Text(tmStr(context, 'tmNewTask')),
        ),
      );

  Widget _noMatch() => StateMessage(
        icon: Icons.filter_alt_off_rounded,
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
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96)),
      itemCount: ordered.length,
      separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
      itemBuilder: (_, i) => _TaskTile(
        task: ordered[i],
        now: _now,
        steps: stepCount(widget.tasksOf(), ordered[i].id),
        onTap: () => _openTaskEditor(existing: ordered[i]),
        onMove: (s) => widget.onMoveTask(ordered[i], s).then((_) => _refresh()),
      ),
    );
  }

  Widget _boardView() {
    final cols = boardColumns(_filtered, _now);
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96)),
      children: [
        for (final s in kBoardColumns)
          _BoardColumn(
            status: s,
            tasks: cols[s] ?? const [],
            stepsOf: (t) => stepCount(widget.tasksOf(), t.id),
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

  /// p2plan: Bangla (or English) voice/text quick-add — the server parser
  /// (same as reminders) with an offline fallback; opens the form pre-filled,
  /// never saves on its own.
  Future<void> _quickAdd() async {
    final text = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _QuickAddSheet(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    final t = TaskItem(projectId: widget.project.id);
    try {
      final r = await context.read<AppState>().api.postJson('/tasks/parse', {'text': text});
      t.title = '${r['title'] ?? text}'.trim();
      t.due = '${r['due'] ?? ''}'.trim();
      t.repeat = kRepeats.contains('${r['repeat'] ?? ''}') ? '${r['repeat']}' : '';
      t.priority = kPriorities.contains('${r['priority']}') ? '${r['priority']}' : kPriorityNormal;
    } catch (_) {
      // offline: the on-device mirror of the same parser
      final p = parseReminder(text);
      t.title = p.cleanTitle.isNotEmpty ? p.cleanTitle : text.trim();
      if (p.dateTime != null) t.due = p.dateTime!.toIso8601String();
      final freq = p.recurrence?.freq ?? '';
      t.repeat = kRepeats.contains(freq) && t.due.isNotEmpty ? freq : '';
    }
    if (!mounted) return;
    await _openTaskEditor(prefill: t);
  }

  Future<void> _openTaskEditor({TaskItem? existing, TaskItem? prefill}) async {
    final names = assigneesOf(widget.tasksOf());
    final result = await showAppSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TaskEditor(
        existing: existing,
        prefill: prefill,
        projectId: widget.project.id,
        knownAssignees: names,
        people: widget.project.isShared ? widget.project.people : const [],
        stepsOf: () => subtasksOf(widget.tasksOf(), existing?.id),
        onAddStep: (title) async {
          if (existing?.id == null) return;
          await widget.onSaveTask(TaskItem(
              projectId: widget.project.id, parentId: existing!.id, title: title));
          _refresh();
        },
        onToggleStep: (st) async {
          await widget.onMoveTask(st, st.status == kStatusDone ? kStatusTodo : kStatusDone);
          _refresh();
        },
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
  final (int, int) Function(TaskItem) stepsOf;
  final DateTime now;
  final void Function(TaskItem) onTapTask;
  final void Function(TaskItem, String) onMove;
  const _BoardColumn({
    required this.status,
    required this.tasks,
    required this.stepsOf,
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
            Flexible(
              child: Text(statusLabel(context, status),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
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
                    steps: stepsOf(tasks[i]),
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
  final (int, int) steps; // p2plan: (done, total) subtasks
  final bool compact;
  final VoidCallback onTap;
  final void Function(String) onMove;
  const _TaskTile({
    required this.task,
    required this.now,
    required this.onTap,
    required this.onMove,
    this.steps = (0, 0),
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
                icon: Icon(Icons.more_vert_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                onSelected: onMove,
                itemBuilder: (_) => [
                  for (final s in kBoardColumns)
                    if (s != task.status)
                      PopupMenuItem(
                        value: s,
                        child: Row(children: [
                          Icon(Icons.arrow_right_alt_rounded,
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
                _chip(context, Icons.person_outline_rounded, task.assignee, null),
              if (task.due.trim().isNotEmpty)
                _chip(
                    context,
                    overdue ? Icons.event_busy_rounded : Icons.event_rounded,
                    _dueLabel(context),
                    overdue ? Brand.danger : null),
              if (overdue)
                _chip(context, Icons.warning_amber_rounded,
                    tmStr(context, 'tmOverdue'), Brand.danger),
              if (steps.$2 > 0)
                _chip(context, Icons.checklist_rounded,
                    '${tmNum(context, steps.$1)}/${tmStrNum(context, 'tmStepsCount', steps.$2)}',
                    steps.$1 == steps.$2 ? Brand.success : null),
              if (task.repeat.isNotEmpty)
                _chip(context, Icons.repeat_rounded, repeatLabel(context, task.repeat), null),
              if (task.estMin > 0)
                _chip(context, Icons.timer_outlined,
                    tmStrNum(context, 'tmMinutes', task.estMin), null),
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
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: Gap.xs),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: AType.bodySmall.copyWith(color: color)),
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
  final TaskItem? prefill; // p2plan: from the voice/text quick-add
  final int? projectId;
  final List<String> knownAssignees;
  // p2plan: people on a SHARED list (uid + name); empty for a private list
  final List<Map<String, dynamic>> people;
  final List<TaskItem> Function() stepsOf;
  final Future<void> Function(String title) onAddStep;
  final Future<void> Function(TaskItem step) onToggleStep;
  const _TaskEditor({
    this.existing,
    this.prefill,
    this.projectId,
    required this.knownAssignees,
    this.people = const [],
    required this.stepsOf,
    required this.onAddStep,
    required this.onToggleStep,
  });
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final TaskItem? _seed = widget.existing ?? widget.prefill;
  late final _title = TextEditingController(text: _seed?.title ?? '');
  late final _desc = TextEditingController(text: _seed?.description ?? '');
  late final _assignee = TextEditingController(text: _seed?.assignee ?? '');
  late String _status = _seed?.status ?? kStatusTodo;
  late String _priority = _seed?.priority ?? kPriorityNormal;
  late int _progress = _seed?.progress ?? 0;
  late DateTime? _due = tmParseDue(_seed?.due ?? '');
  late String _repeat = _seed?.repeat ?? kRepeatNone;
  late int _estMin = _seed?.estMin ?? 0;
  late int? _assigneeUid = _seed?.assigneeUid;
  final _step = TextEditingController();
  String? _titleError, _repeatError;
  bool _stepBusy = false;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _assignee.dispose();
    _step.dispose();
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
    // p2plan: keep a spoken/typed time of day when only the date changes
    if (picked != null) {
      setState(() {
        _due = DateTime(picked.year, picked.month, picked.day, _due?.hour ?? 0,
            _due?.minute ?? 0);
        _repeatError = null;
      });
    }
  }

  Future<void> _pickFromCircle() async {
    final m = await pickCircleMember(context, title: tmStr(context, 'tmFromCircle'));
    if (m != null && mounted) {
      setState(() => _assignee.text = '${m['name'] ?? ''}'.trim());
    }
  }

  Future<void> _addStep() async {
    final title = _step.text.trim();
    if (title.isEmpty || _stepBusy) return;
    setState(() => _stepBusy = true);
    await widget.onAddStep(title);
    if (!mounted) return;
    _step.clear();
    setState(() => _stepBusy = false);
  }

  void _submit() {
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = tmStr(context, 'tmTitleRequired'));
      return;
    }
    if (_repeat.isNotEmpty && _due == null) {
      setState(() => _repeatError = tmStr(context, 'tmRepeatNeedsDue'));
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
        : DateTime(_due!.year, _due!.month, _due!.day, _due!.hour, _due!.minute)
            .toIso8601String();
    t.progress = _status == kStatusDone ? 100 : _progress;
    t.repeat = _repeat;
    t.estMin = _estMin;
    t.assigneeUid = widget.people.isEmpty ? null : _assigneeUid;
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
                icon: const Icon(Icons.delete_outline_rounded, color: Brand.danger),
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
          if (widget.people.isNotEmpty) ...[
            // p2plan: on a shared list you give a task to a PERSON on the
            // list — they get a notification (server-checked).
            _label(context, tmStr(context, 'tmAssignTo')),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                ChoiceChip(
                  label: Text(tmStr(context, 'tmUnassigned')),
                  selected: _assigneeUid == null,
                  onSelected: (_) => setState(() {
                    _assigneeUid = null;
                    _assignee.text = '';
                  }),
                ),
                for (final m in widget.people)
                  if (m['uid'] != null)
                    ChoiceChip(
                      label: Text('${m['name'] ?? ''}', overflow: TextOverflow.ellipsis),
                      selected: '$_assigneeUid' == '${m['uid']}',
                      onSelected: (_) => setState(() {
                        _assigneeUid =
                            m['uid'] is int ? m['uid'] as int : int.tryParse('${m['uid']}');
                        _assignee.text = '${m['name'] ?? ''}';
                      }),
                    ),
              ]),
            ),
          ] else ...[
          TextField(
            controller: _assignee,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: tmStr(context, 'tmAssignee'),
              hintText: tmStr(context, 'tmAssigneeHint'),
              border: const OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _pickFromCircle,
              icon: const Icon(Icons.group_outlined),
              label: Text(tmStr(context, 'tmFromCircle')),
            ),
          ),
          ],
          if (widget.people.isEmpty && widget.knownAssignees.isNotEmpty) ...[
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
                icon: const Icon(Icons.event_rounded),
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
                icon: const Icon(Icons.clear_rounded),
                onPressed: () => setState(() => _due = null),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // p2plan: repeat
          _label(context, tmStr(context, 'tmRepeat')),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final r in kRepeats)
                ChoiceChip(
                  label: Text(repeatLabel(context, r)),
                  selected: _repeat == r,
                  onSelected: (_) => setState(() {
                    _repeat = r;
                    _repeatError = null;
                  }),
                ),
            ]),
          ),
          if (_repeatError != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(_repeatError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: Gap.md),
          // p2plan: time needed (the daily planner uses it)
          _label(context, tmStr(context, 'tmEstimate')),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              ChoiceChip(
                label: Text(tmStr(context, 'tmEstNone')),
                selected: _estMin == 0,
                onSelected: (_) => setState(() => _estMin = 0),
              ),
              for (final m in kEstChoices)
                ChoiceChip(
                  label: Text(tmStrNum(context, 'tmMinutes', m)),
                  selected: _estMin == m,
                  onSelected: (_) => setState(() => _estMin = m),
                ),
            ]),
          ),
          const SizedBox(height: Gap.md),
          // p2plan: steps (subtasks) — only a saved task can hold steps
          if (widget.existing?.parentId == null) ...[
            _label(context, tmStr(context, 'tmSteps')),
            if (widget.existing?.id == null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(tmStr(context, 'tmStepsAfterSave'),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            else ...[
              for (final st in widget.stepsOf())
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: st.status == kStatusDone,
                  title: Text(st.title,
                      style: TextStyle(
                          decoration: st.status == kStatusDone
                              ? TextDecoration.lineThrough
                              : null)),
                  onChanged: (_) async {
                    await widget.onToggleStep(st);
                    if (mounted) setState(() {});
                  },
                ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _step,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _addStep(),
                    decoration: InputDecoration(
                      labelText: tmStr(context, 'tmAddStep'),
                      hintText: tmStr(context, 'tmAddStepHint'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tmStr(context, 'tmAddStep'),
                  onPressed: _stepBusy ? null : _addStep,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
              ]),
            ],
            const SizedBox(height: Gap.md),
          ],
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


// ===========================================================================
// p2plan: voice / text quick-add sheet (Bangla first). Returns the phrase;
// the board parses it and opens the pre-filled form — nothing auto-saves.
// ===========================================================================
class _QuickAddSheet extends StatefulWidget {
  const _QuickAddSheet();
  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  final _c = TextEditingController();
  final _voice = VoiceDictation();

  @override
  void dispose() {
    _voice.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + bottom + MediaQuery.of(context).padding.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tmStr(context, 'tmQuickAdd'),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tmStr(context, 'tmQuickAddHelp'),
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _c,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: tmStr(context, 'tmQuickAddHint'),
              border: const OutlineInputBorder(),
              suffixIcon: VoiceMicButton(voice: _voice, input: _c),
            ),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context, _c.text),
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: Text(tmStr(context, 'tmUnderstand')),
            ),
          ),
        ]),
      ),
    );
  }
}
