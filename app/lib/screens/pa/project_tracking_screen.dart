import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE — CORPORATE PROJECT TRACKING (#120, §14, ADVANCED).
///
/// The PA tracks the projects the BOSS oversees: PROJECTS (name, owner, status,
/// % complete, due), per-project MILESTONES (title, date, status), RISKS /
/// ISSUES (severity + status), and a deterministic PORTFOLIO summary
/// (on-track / at-risk / overdue counts). "Overdue" is computed from today's
/// date passed in — identical to backend/core/logic/pa_projects.py.
///
/// MANUAL-FIRST, HONEST AI SEAM (NEVER FABRICATES):
///   * A narrative "status synthesis" (prose update for the boss) is a
///     DOCUMENTED key-gated seam shown as an honest "connect an AI key" card
///     (_AiSeamCard). This screen NEVER fabricates a status narrative. The
///     deterministic portfolio roll-up is always available with no key.
///
/// Honest states: welcome (no projects) · loading · error. ZERO Bangla
/// literals — every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/projects') → mixed rows tagged by {kind}:
///     {id, kind:'project', name, owner, status, percent, due, note}
///     {id, kind:'risk',    project_id, label, severity, status, note}
///   listItems('pa/milestones') → milestone rows {project_id}:
///     {id, project_id, title, date, status, note}
///   create/update/delete on both paths; rows round-trip as {id, ...data}
///   through the PaCollectionItem flexible per-user JSON store.
class ProjectTrackingScreen extends StatefulWidget {
  const ProjectTrackingScreen({super.key});
  @override
  State<ProjectTrackingScreen> createState() => _ProjectTrackingScreenState();
}

const String _projectsPath = 'pa/projects';
const String _milestonesPath = 'pa/milestones';

const List<String> _projectStates = [
  'planned', 'active', 'on_hold', 'done', 'cancelled'
];
const List<String> _milestoneStates = ['pending', 'done', 'missed'];
const List<String> _riskSeverities = ['low', 'med', 'high'];
const List<String> _riskStates = ['open', 'closed'];

const List<String> _closedStates = ['done', 'cancelled'];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

DateTime? _parse(String s) {
  var x = s.trim();
  if (x.isEmpty) return null;
  if (x.endsWith('Z')) x = x.substring(0, x.length - 1);
  return DateTime.tryParse(x) ?? DateTime.tryParse('${x}T00:00:00');
}

int _pct(dynamic v) {
  final n = v is num ? v.round() : int.tryParse('$v'.trim());
  if (n == null) return 0;
  return n < 0 ? 0 : (n > 100 ? 100 : n);
}

bool _isOpen(Map<String, dynamic> p) =>
    !_closedStates.contains('${p['status']}');

bool _isOverdue(Map<String, dynamic> p, String todayIso) {
  if (!_isOpen(p)) return false;
  final due = _parse('${p['due'] ?? ''}');
  final now = _parse(todayIso);
  if (due == null || now == null) return false;
  return DateTime(due.year, due.month, due.day)
      .isBefore(DateTime(now.year, now.month, now.day));
}

int? _daysToDue(Map<String, dynamic> p, String todayIso) {
  final due = _parse('${p['due'] ?? ''}');
  final now = _parse(todayIso);
  if (due == null || now == null) return null;
  return DateTime(due.year, due.month, due.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
}

/// Mirrors pa_projects.classify_project → exactly one health bucket.
String _classify(Map<String, dynamic> p, String todayIso,
    List<Map<String, dynamic>> milestones, List<Map<String, dynamic>> risks) {
  final status = '${p['status']}';
  if (status == 'done') return 'done';
  if (status == 'cancelled') return 'cancelled';
  if (_isOverdue(p, todayIso)) return 'overdue';
  final openHigh = risks.any(
      (r) => '${r['status']}' == 'open' && '${r['severity']}' == 'high');
  final anyMissed = milestones.any((m) => '${m['status']}' == 'missed');
  if (openHigh || anyMissed) return 'at_risk';
  return 'on_track';
}

class _ProjectTrackingScreenState extends State<ProjectTrackingScreen> {
  List<Map<String, dynamic>> _rows = []; // project + risk rows
  List<Map<String, dynamic>> _milestones = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  AppLocalizations get t => AppLocalizations.of(context);

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
      _rows = await api.listItems(_projectsPath);
      _milestones = await api.listItems(_milestonesPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _projects =>
      _rows.where((r) => '${r['kind']}' == 'project').toList();

  List<Map<String, dynamic>> get _risks =>
      _rows.where((r) => '${r['kind']}' == 'risk').toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openProjectEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProjectEditor(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_projectsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_projectsPath, {...result, 'kind': 'project'});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'active':
        return t.paProjStatusActive;
      case 'on_hold':
        return t.paProjStatusOnHold;
      case 'done':
        return t.paProjStatusDone;
      case 'cancelled':
        return t.paProjStatusCancelled;
      default:
        return t.paProjStatusPlanned;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.paProjTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.paProjTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.paProjLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry)),
        ),
      );
    }

    final projects = _projects;
    final risks = _risks;
    final today = _today();

    // deterministic portfolio roll-up (mirror pa_projects.portfolio_summary)
    int onTrack = 0, atRisk = 0, overdue = 0, done = 0, cancelled = 0;
    final openPcts = <int>[];
    final classified = <Map<String, dynamic>>[];
    for (final p in projects) {
      final pid = p['id'];
      final ms = _milestones.where((m) => m['project_id'] == pid).toList();
      final rk = risks.where((r) => r['project_id'] == pid).toList();
      final health = _classify(p, today, ms, rk);
      switch (health) {
        case 'overdue':
          overdue++;
          break;
        case 'at_risk':
          atRisk++;
          break;
        case 'on_track':
          onTrack++;
          break;
        case 'done':
          done++;
          break;
        case 'cancelled':
          cancelled++;
          break;
      }
      if (_isOpen(p)) openPcts.add(_pct(p['percent']));
      classified.add({'project': p, 'health': health});
    }
    final avgPct = openPcts.isEmpty
        ? 0
        : openPcts.reduce((a, b) => a + b) ~/ openPcts.length;

    // worst-health first, then due date
    const order = {
      'overdue': 0,
      'at_risk': 1,
      'on_track': 2,
      'done': 3,
      'cancelled': 4
    };
    classified.sort((a, b) {
      final oa = order[a['health']] ?? 9;
      final ob = order[b['health']] ?? 9;
      if (oa != ob) return oa.compareTo(ob);
      final da = _parse('${(a['project'] as Map)['due'] ?? ''}')
              ?.toIso8601String() ??
          '9999';
      final db = _parse('${(b['project'] as Map)['due'] ?? ''}')
              ?.toIso8601String() ??
          '9999';
      return da.compareTo(db);
    });

    return Scaffold(
      appBar: AppBar(title: Text(t.paProjTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProjectEditor(),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.paProjNewProject),
      ),
      body: projects.isEmpty
          ? StateMessage(
              icon: Icons.account_tree_rounded,
              tint: Brand.blue,
              title: t.paProjWelcomeTitle,
              message: t.paProjWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _openProjectEditor(),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.paProjNewProject),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  _PortfolioCard(
                    total: projects.length,
                    onTrack: onTrack,
                    atRisk: atRisk,
                    overdue: overdue,
                    done: done,
                    cancelled: cancelled,
                    avgPercent: avgPct,
                  ),
                  const SizedBox(height: Gap.sm),
                  const _AiSeamCard(),
                  const SizedBox(height: Gap.sm),
                  for (final c in classified)
                    _ProjectCard(
                      project: c['project'] as Map<String, dynamic>,
                      health: '${c['health']}',
                      statusLabel:
                          _statusLabel('${(c['project'] as Map)['status']}'),
                      daysToDue:
                          _daysToDue(c['project'] as Map<String, dynamic>,
                              today),
                      onOpen: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => _ProjectDetailScreen(
                              project: c['project'] as Map<String, dynamic>),
                        ));
                        await _load();
                      },
                      onEdit: () => _openProjectEditor(
                          c['project'] as Map<String, dynamic>),
                    ),
                ],
              ),
            ),
    );
  }
}

// ======================= portfolio summary card =======================
class _PortfolioCard extends StatelessWidget {
  final int total, onTrack, atRisk, overdue, done, cancelled, avgPercent;
  const _PortfolioCard(
      {required this.total,
      required this.onTrack,
      required this.atRisk,
      required this.overdue,
      required this.done,
      required this.cancelled,
      required this.avgPercent});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.insights_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.paProjPortfolioTitle,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
            ),
            Text(t.paProjPortfolioCount(total),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (overdue > 0)
              _stat(t.paProjStatOverdue(overdue), scheme.error),
            if (atRisk > 0) _stat(t.paProjStatAtRisk(atRisk), Brand.warning),
            _stat(t.paProjStatOnTrack(onTrack), Brand.success),
            if (done > 0) _stat(t.paProjStatDone(done), scheme.secondary),
            if (cancelled > 0)
              _stat(t.paProjStatCancelled(cancelled), scheme.outline),
          ]),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: LinearProgressIndicator(
                    value: avgPercent / 100,
                    minHeight: 8,
                    backgroundColor: scheme.surfaceContainerHighest),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Text(t.paProjAvgProgress(avgPercent),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(label,
            style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700, color: c)),
      );
}

// ======================= AI seam (key-gated) =======================
class _AiSeamCard extends StatelessWidget {
  const _AiSeamCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.auto_awesome_rounded,
              size: 20, color: scheme.tertiary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.paProjAiSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              Text(t.paProjAiSeamBody,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= project card =======================
class _ProjectCard extends StatelessWidget {
  final Map<String, dynamic> project;
  final String health, statusLabel;
  final int? daysToDue;
  final VoidCallback onOpen, onEdit;
  const _ProjectCard(
      {required this.project,
      required this.health,
      required this.statusLabel,
      required this.daysToDue,
      required this.onOpen,
      required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pct = _pct(project['percent']);
    final owner = '${project['owner'] ?? ''}'.trim();
    final due = '${project['due'] ?? ''}'.trim();
    Color hc;
    String hLabel;
    switch (health) {
      case 'overdue':
        hc = scheme.error;
        hLabel = t.paProjHealthOverdue;
        break;
      case 'at_risk':
        hc = Brand.warning;
        hLabel = t.paProjHealthAtRisk;
        break;
      case 'done':
        hc = scheme.secondary;
        hLabel = t.paProjHealthDone;
        break;
      case 'cancelled':
        hc = scheme.outline;
        hLabel = t.paProjHealthCancelled;
        break;
      default:
        hc = Brand.success;
        hLabel = t.paProjHealthOnTrack;
    }
    String? dueText;
    if (due.isNotEmpty && daysToDue != null) {
      if (daysToDue! > 0) {
        dueText = t.paProjDueIn(daysToDue!);
      } else if (daysToDue == 0) {
        dueText = t.paProjDueToday;
      } else {
        dueText = t.paProjDueOverdue(-daysToDue!);
      }
    }
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('${project['name'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                        color: hc.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(Radii.pill)),
                    child: Text(hLabel,
                        style: AType.labelSmall.copyWith(fontWeight: FontWeight.w800, color: hc)),
                  ),
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_rounded, size: 20),
                      tooltip: t.edit,
                      onPressed: onEdit),
                ]),
                if (owner.isNotEmpty || due.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.xs),
                    child: Text(
                        [
                          if (owner.isNotEmpty) t.paProjOwnerPrefix(owner),
                          statusLabel,
                          if (dueText != null) dueText,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      child: LinearProgressIndicator(
                          value: pct / 100,
                          minHeight: 7,
                          backgroundColor: scheme.surfaceContainerHighest),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Text('$pct%',
                      style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700)),
                ]),
              ]),
        ),
      ),
    );
  }
}

// ======================= project detail =======================
class _ProjectDetailScreen extends StatefulWidget {
  final Map<String, dynamic> project;
  const _ProjectDetailScreen({required this.project});
  @override
  State<_ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<_ProjectDetailScreen> {
  List<Map<String, dynamic>> _risks = [];
  List<Map<String, dynamic>> _milestones = [];
  bool _loading = true;

  AppLocalizations get t => AppLocalizations.of(context);
  int get _projectId => widget.project['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = context.read<AppState>().api;
    try {
      final all = await api.listItems(_projectsPath);
      _risks = all
          .where((r) =>
              '${r['kind']}' == 'risk' && r['project_id'] == _projectId)
          .toList();
    } catch (_) {
      _risks = [];
    }
    try {
      final ms = await api.listItems(_milestonesPath);
      _milestones = ms.where((m) => m['project_id'] == _projectId).toList();
    } catch (_) {
      _milestones = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _createRisk(Map<String, dynamic> body) async {
    try {
      await context.read<AppState>().api.createItem(
          _projectsPath, {...body, 'kind': 'risk', 'project_id': _projectId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _updateRisk(int id, Map<String, dynamic> body) async {
    try {
      await context.read<AppState>().api.updateItem(
          _projectsPath, id, {...body, 'kind': 'risk', 'project_id': _projectId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteRisk(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_projectsPath, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _createMilestone(Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .createItem(_milestonesPath, {...body, 'project_id': _projectId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _updateMilestone(int id, Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .updateItem(_milestonesPath, id, {...body, 'project_id': _projectId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteMilestone(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_milestonesPath, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  String _msLabel(String s) {
    switch (s) {
      case 'done':
        return t.paProjMsDone;
      case 'missed':
        return t.paProjMsMissed;
      default:
        return t.paProjMsPending;
    }
  }

  String _sevLabel(String s) {
    switch (s) {
      case 'low':
        return t.paProjSevLow;
      case 'high':
        return t.paProjSevHigh;
      default:
        return t.paProjSevMed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final milestones = List<Map<String, dynamic>>.from(_milestones)
      ..sort((a, b) =>
          (_parse('${a['date'] ?? ''}')?.toIso8601String() ?? '9999')
              .compareTo(
                  _parse('${b['date'] ?? ''}')?.toIso8601String() ?? '9999'));
    final msDone = milestones.where((m) => '${m['status']}' == 'done').length;
    final msPct =
        milestones.isEmpty ? 0 : (msDone * 100 ~/ milestones.length);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.project['name'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 40),
                children: [
                  const _AiSeamCard(),
                  const SizedBox(height: Gap.lg),

                  // ---- milestones ----
                  _SectionHeader(
                      icon: Icons.flag_rounded,
                      label: t.paProjMilestonesHeader,
                      onAdd: () => _editMilestone()),
                  if (milestones.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                      child: Row(children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.pill),
                            child: LinearProgressIndicator(
                                value: msPct / 100,
                                minHeight: 8,
                                backgroundColor:
                                    scheme.surfaceContainerHighest),
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Text(t.paProjMsProgress(msDone, milestones.length),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  if (milestones.isEmpty)
                    _EmptyLine(t.paProjNoMilestones)
                  else
                    for (final m in milestones)
                      _MilestoneTile(
                        milestone: m,
                        statusLabel: _msLabel('${m['status']}'),
                        onEdit: () => _editMilestone(m),
                        onDelete: () => _deleteMilestone(m['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- risks / issues ----
                  _SectionHeader(
                      icon: Icons.warning_amber_rounded,
                      label: t.paProjRisksHeader,
                      onAdd: () => _editRisk()),
                  if (_risks.isEmpty)
                    _EmptyLine(t.paProjNoRisks)
                  else
                    for (final r in _risks)
                      _RiskTile(
                        risk: r,
                        sevLabel: _sevLabel('${r['severity']}'),
                        statusText: '${r['status']}' == 'closed'
                            ? t.paProjRiskClosed
                            : t.paProjRiskOpen,
                        onEdit: () => _editRisk(r),
                        onDelete: () => _deleteRisk(r['id'] as int),
                      ),
                ],
              ),
            ),
    );
  }

  Future<void> _editMilestone([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MilestoneEditor(existing: e, statusLabel: _msLabel),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _updateMilestone(e['id'] as int, r);
    } else {
      await _createMilestone(r);
    }
  }

  Future<void> _editRisk([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RiskEditor(existing: e, sevLabel: _sevLabel),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _updateRisk(e['id'] as int, r);
    } else {
      await _createRisk(r);
    }
  }
}

// ======================= tiles =======================
class _MilestoneTile extends StatelessWidget {
  final Map<String, dynamic> milestone;
  final String statusLabel;
  final VoidCallback onEdit, onDelete;
  const _MilestoneTile(
      {required this.milestone,
      required this.statusLabel,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = '${milestone['status']}';
    Color sc;
    IconData icon;
    switch (status) {
      case 'done':
        sc = Brand.success;
        icon = Icons.check_circle_outline_rounded;
        break;
      case 'missed':
        sc = scheme.error;
        icon = Icons.cancel_rounded;
        break;
      default:
        sc = Brand.warning;
        icon = Icons.radio_button_unchecked_rounded;
    }
    final date = '${milestone['date'] ?? ''}'.trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, color: sc),
      title: Text('${milestone['title'] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([statusLabel, if (date.isNotEmpty) date].join(' · '),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(t.edit)),
          PopupMenuItem(value: 'delete', child: Text(t.delete)),
        ],
      ),
    );
  }
}

class _RiskTile extends StatelessWidget {
  final Map<String, dynamic> risk;
  final String sevLabel, statusText;
  final VoidCallback onEdit, onDelete;
  const _RiskTile(
      {required this.risk,
      required this.sevLabel,
      required this.statusText,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sev = '${risk['severity']}';
    final closed = '${risk['status']}' == 'closed';
    Color sc;
    switch (sev) {
      case 'high':
        sc = scheme.error;
        break;
      case 'low':
        sc = scheme.secondary;
        break;
      default:
        sc = Brand.warning;
    }
    if (closed) sc = scheme.outline;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(Icons.report_problem_rounded, color: sc),
      title: Text('${risk['label'] ?? ''}',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('$sevLabel · $statusText',
          style: TextStyle(color: sc, fontWeight: FontWeight.w600)),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(t.edit)),
          PopupMenuItem(value: 'delete', child: Text(t.delete)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onAdd;
  const _SectionHeader(
      {required this.icon, required this.label, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: scheme.primary),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: Text(label,
              style:
                  AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
      IconButton(
          icon: const Icon(Icons.add_circle_outline_rounded),
          tooltip: AppLocalizations.of(context).add,
          onPressed: onAdd),
    ]);
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;
  const _EmptyLine(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(text,
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

// ======================= editors =======================
class _ProjectEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _ProjectEditor({this.existing});
  @override
  State<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<_ProjectEditor> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.existing?['name'] ?? ''}');
  late final TextEditingController _owner =
      TextEditingController(text: '${widget.existing?['owner'] ?? ''}');
  late final TextEditingController _note =
      TextEditingController(text: '${widget.existing?['note'] ?? ''}');
  late String _status = _projectStates.contains('${widget.existing?['status']}')
      ? '${widget.existing!['status']}'
      : 'planned';
  late double _percent = _pct(widget.existing?['percent']).toDouble();
  late String _due = '${widget.existing?['due'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  String _statusLabel(String s) {
    switch (s) {
      case 'active':
        return t.paProjStatusActive;
      case 'on_hold':
        return t.paProjStatusOnHold;
      case 'done':
        return t.paProjStatusDone;
      case 'cancelled':
        return t.paProjStatusCancelled;
      default:
        return t.paProjStatusPlanned;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paProjNameRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'project',
      'name': _name.text.trim(),
      'owner': _owner.text.trim(),
      'status': _status,
      'percent': _percent.round(),
      'due': _due,
      'note': _note.text.trim(),
    });
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
              Center(
                child: Text(
                    widget.existing == null ? t.paProjNewProject : t.edit,
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                    labelText: t.paProjNameLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _owner,
                decoration: InputDecoration(
                    labelText: t.paProjOwnerLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Text(t.paProjStatusFieldLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final s in _projectStates)
                  ChoiceChip(
                    label: Text(_statusLabel(s)),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              Row(children: [
                Text(t.paProjPercentLabel,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('${_percent.round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: AFonts.tabular)),
              ]),
              Slider(
                value: _percent,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${_percent.round()}%',
                onChanged: (v) => setState(() => _percent = v),
              ),
              const SizedBox(height: Gap.xs),
              _DateField(
                  label: t.paProjDueLabel,
                  value: _due,
                  onPick: (v) => setState(() => _due = v)),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: InputDecoration(
                    labelText: t.paProjNoteLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                  width: double.infinity,
                  child:
                      FilledButton(onPressed: _save, child: Text(t.save))),
            ]),
      ),
    );
  }
}

class _MilestoneEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(String) statusLabel;
  const _MilestoneEditor({this.existing, required this.statusLabel});
  @override
  State<_MilestoneEditor> createState() => _MilestoneEditorState();
}

class _MilestoneEditorState extends State<_MilestoneEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late String _status =
      _milestoneStates.contains('${widget.existing?['status']}')
          ? '${widget.existing!['status']}'
          : 'pending';
  late String _date = '${widget.existing?['date'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'title': _title.text.trim(),
      'date': _date,
      'status': _status,
    });
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
              Center(
                child: Text(t.paProjMilestonesHeader,
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: t.paProjMsTitleLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              _DateField(
                  label: t.paProjMsDateLabel,
                  value: _date,
                  onPick: (v) => setState(() => _date = v)),
              const SizedBox(height: Gap.md),
              Text(t.paProjMsStatusLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final s in _milestoneStates)
                  ChoiceChip(
                    label: Text(widget.statusLabel(s)),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ]),
              const SizedBox(height: Gap.lg),
              SizedBox(
                  width: double.infinity,
                  child:
                      FilledButton(onPressed: _save, child: Text(t.save))),
            ]),
      ),
    );
  }
}

class _RiskEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(String) sevLabel;
  const _RiskEditor({this.existing, required this.sevLabel});
  @override
  State<_RiskEditor> createState() => _RiskEditorState();
}

class _RiskEditorState extends State<_RiskEditor> {
  late final TextEditingController _label =
      TextEditingController(text: '${widget.existing?['label'] ?? ''}');
  late String _sev = _riskSeverities.contains('${widget.existing?['severity']}')
      ? '${widget.existing!['severity']}'
      : 'med';
  late String _status = _riskStates.contains('${widget.existing?['status']}')
      ? '${widget.existing!['status']}'
      : 'open';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _save() {
    if (_label.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'label': _label.text.trim(),
      'severity': _sev,
      'status': _status,
    });
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
              Center(
                child: Text(t.paProjRisksHeader,
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _label,
                  autofocus: true,
                  maxLines: 2,
                  decoration: InputDecoration(
                      labelText: t.paProjRiskLabelLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              Text(t.paProjSeverityLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final s in _riskSeverities)
                  ChoiceChip(
                    label: Text(widget.sevLabel(s)),
                    selected: _sev == s,
                    onSelected: (_) => setState(() => _sev = s),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              Row(children: [
                Text(t.paProjRiskStatusLabel,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Switch(
                  value: _status == 'closed',
                  onChanged: (v) =>
                      setState(() => _status = v ? 'closed' : 'open'),
                ),
                Text(_status == 'closed' ? t.paProjRiskClosed : t.paProjRiskOpen),
              ]),
              const SizedBox(height: Gap.lg),
              SizedBox(
                  width: double.infinity,
                  child:
                      FilledButton(onPressed: _save, child: Text(t.save))),
            ]),
      ),
    );
  }
}

// ======================= date field =======================
class _DateField extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onPick;
  const _DateField(
      {required this.label, required this.value, required this.onPick});
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.event_rounded, size: 18),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(value.isEmpty ? label : '$label: $value'),
      ),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          alignment: Alignment.centerLeft),
      onPressed: () async {
        final now = DateTime.now();
        final initial = _parse(value) ?? now;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(now.year - 2),
          lastDate: DateTime(now.year + 5),
        );
        if (picked == null) return;
        final y = picked.year.toString().padLeft(4, '0');
        final mo = picked.month.toString().padLeft(2, '0');
        final d = picked.day.toString().padLeft(2, '0');
        onPick('$y-$mo-$d');
      },
    );
  }
}
