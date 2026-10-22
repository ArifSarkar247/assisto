import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../models.dart';
import '../theme.dart';
import '../action_api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/action_models.dart';
import '../widgets/action_cards.dart';
import '../widgets/action_edit_sheet.dart';

/// ACTION CENTER (SPEC v2.1 §21, feature #9 — "Action Center & audit log").
///
/// A transparent, autonomy-tied view of what the AI/app does on the user's
/// behalf, in two tabs:
///   * PENDING — actions the AI has PREPARED and is holding for approval
///     (autonomy level 3). Each has Approve / Reject / Edit.
///   * DONE — the chronological audit log of actions already taken (what / when
///     / which module / outcome), filterable by module, with Undo where the
///     action is reversible (delete within the server's 180s window).
///
/// A standing banner states the promise — "Assisto only acts within your
/// autonomy setting" — and names the current level.
///
/// Honest states throughout: separate loading / empty / error / offline UIs,
/// and PENDING degrades to an empty "nothing waiting" list when its (new)
/// backend endpoint is not yet deployed (see `action_api.dart`). ZERO Bangla
/// literals — all copy is via `AppLocalizations` (emitted to
/// `.phaseB/up_action_arb.json`).
class ActionCenterScreen extends StatefulWidget {
  const ActionCenterScreen({super.key});

  @override
  State<ActionCenterScreen> createState() => _ActionCenterScreenState();
}

class _ActionCenterScreenState extends State<ActionCenterScreen> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.actionCenterTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: t.actionTabPending),
              Tab(text: t.actionTabDone),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _PendingTab(),
            _DoneTab(),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- shared

Widget _centered(Widget child) => Center(
      child: Padding(padding: const EdgeInsets.all(Gap.xl), child: child),
    );

Widget _emptyState(BuildContext context,
    {required IconData icon,
    required String title,
    required String body,
    Widget? action}) {
  final cs = Theme.of(context).colorScheme;
  return _centered(Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 48, color: cs.onSurfaceVariant),
      const SizedBox(height: Gap.md),
      Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: Gap.xs),
      Text(body,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
      if (action != null) ...[
        const SizedBox(height: Gap.md),
        action,
      ],
    ],
  ));
}

// -------------------------------------------------------------------- PENDING

class _PendingTab extends StatefulWidget {
  const _PendingTab();
  @override
  State<_PendingTab> createState() => _PendingTabState();
}

class _PendingTabState extends State<_PendingTab> {
  late Future<List<PendingAction>> _future;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.pendingActions();
  }

  void _reload() {
    // db1: block body — an arrow returned the Future and setState asserted.
    setState(() {
      _future = context.read<AppState>().api.pendingActions();
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _approve(PendingAction a, {Map<String, dynamic>? edit}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy.add(a.id));
    try {
      await context.read<AppState>().api.approveAction(a.id, edit: edit);
      _snack(t.actionApprovedSnack);
      _reload();
    } catch (e) {
      _snack(t.actionFailedSnack(e.toString()));
      setState(() => _busy.remove(a.id));
    }
  }

  Future<void> _reject(PendingAction a) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy.add(a.id));
    try {
      await context.read<AppState>().api.rejectAction(a.id);
      _snack(t.actionRejectedSnack);
      _reload();
    } catch (e) {
      _snack(t.actionFailedSnack(e.toString()));
      setState(() => _busy.remove(a.id));
    }
  }

  Future<void> _edit(PendingAction a) async {
    final edit = await showActionEditSheet(context, a);
    if (edit == null) return; // dismissed
    await _approve(a, edit: edit.isEmpty ? null : edit);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final level = (app.user?.autonomyLevel ?? 2);
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: FutureBuilder<List<PendingAction>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(children: [
              ActionTransparencyBanner(
                autonomyLevel: level,
                onOpenAutonomy: () => _openAutonomy(context),
              ),
              _emptyState(context,
                  icon: Icons.cloud_off_outlined,
                  title: t.actionErrorTitle,
                  body: t.loadFailedBody,
                  action: FilledButton.tonalIcon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: Text(t.retry),
                  )),
            ]);
          }
          final items = snap.data ?? const <PendingAction>[];
          return ListView(
            children: [
              ActionTransparencyBanner(
                autonomyLevel: level,
                onOpenAutonomy: () => _openAutonomy(context),
              ),
              if (items.isEmpty)
                _emptyState(context,
                    icon: Icons.inbox_outlined,
                    title: t.actionPendingEmptyTitle,
                    body: t.actionPendingEmptyBody)
              else
                for (final a in items)
                  PendingActionCard(
                    item: a,
                    busy: _busy.contains(a.id),
                    onApprove: () => _approve(a),
                    onReject: () => _reject(a),
                    onEdit: () => _edit(a),
                  ),
            ],
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------------- DONE

class _DoneTab extends StatefulWidget {
  const _DoneTab();
  @override
  State<_DoneTab> createState() => _DoneTabState();
}

class _DoneTabState extends State<_DoneTab> {
  late Future<List<AuditEntry>> _future;
  String? _module; // null = all

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.actionHistory();
  }

  void _reload() {
    setState(() {
      _future = context.read<AppState>().api.actionHistory(); // db1
    });
  }

  Future<void> _undo(AuditEntry e) async {
    final t = AppLocalizations.of(context);
    final res = await context.read<AppState>().api.undoLast();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res != null ? t.actionUndoneSnack : t.actionNothingToUndo),
    ));
    if (res != null) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final level = (app.user?.autonomyLevel ?? 2);
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: FutureBuilder<List<AuditEntry>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(children: [
              ActionTransparencyBanner(
                autonomyLevel: level,
                onOpenAutonomy: () => _openAutonomy(context),
              ),
              _emptyState(context,
                  icon: Icons.cloud_off_outlined,
                  title: t.actionErrorTitle,
                  body: t.loadFailedBody,
                  action: FilledButton.tonalIcon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: Text(t.retry),
                  )),
            ]);
          }
          final all = snap.data ?? const <AuditEntry>[];
          // Modules present, in first-seen order (data is newest-first).
          final modules = <String>[];
          for (final e in all) {
            final m = moduleOf(e.action);
            if (!modules.contains(m)) modules.add(m);
          }
          final items = _module == null
              ? all
              : all.where((e) => moduleOf(e.action) == _module).toList();
          return ListView(
            children: [
              ActionTransparencyBanner(
                autonomyLevel: level,
                onOpenAutonomy: () => _openAutonomy(context),
              ),
              if (all.isEmpty)
                _emptyState(context,
                    icon: Icons.history,
                    title: t.actionDoneEmptyTitle,
                    body: t.actionDoneEmptyBody)
              else ...[
                ActionFilterBar(
                  modules: modules,
                  selectedModule: _module,
                  onModule: (m) => setState(() => _module = m),
                ),
                if (items.isEmpty)
                  _emptyState(context,
                      icon: Icons.filter_alt_off_outlined,
                      title: t.actionFilterEmptyTitle,
                      body: t.actionFilterEmptyBody)
                else
                  for (final e in items)
                    DoneActionTile(
                      entry: e,
                      undoable: ActionCenterApi.isUndoable(e),
                      onUndo: () => _undo(e),
                    ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// Open the autonomy dial (it lives inside Settings). We pop back to let the
// user reach Settings rather than deep-linking into a private section widget.
void _openAutonomy(BuildContext context) {
  final t = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(t.actionAutonomyHint)),
  );
}
