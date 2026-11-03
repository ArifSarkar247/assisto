import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/day_planner_strings.dart';
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';
import 'reminders_screen.dart';
import 'task_manager_screen.dart';

/// AI DAILY PLANNER (owner PART 2, flag `ai_daily_planner`, OFF until proven).
///
/// GET /planner/today returns today's time-blocked plan, built by RULES on the
/// server (core/logic/day_planner.py) from the user's own Task Manager tasks,
/// Personal Secretary meetings, reminders and bills, with optional prayer
/// times — 0 credits, works with no AI key. "Polish with AI" adds a few lines
/// of advice through the AI router (charged credits, shown first); it never
/// moves a block. Prefs (day window, prayer) sync across phones.
class DayPlannerScreen extends StatefulWidget {
  const DayPlannerScreen({super.key});
  @override
  State<DayPlannerScreen> createState() => _DayPlannerScreenState();
}

class _DayPlannerScreenState extends State<DayPlannerScreen> {
  Map<String, dynamic>? _plan;
  bool _loading = true;
  Object? _error;
  // AI advice
  bool _aiBusy = false;
  List<String> _advice = const [];
  String? _aiMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _plan == null;
      _error = null;
    });
    try {
      final p = await context.read<AppState>().api.getJson('/planner/today');
      if (!mounted) return;
      setState(() {
        _plan = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _polish() async {
    setState(() {
      _aiBusy = true;
      _aiMessage = null;
    });
    try {
      final r = await context.read<AppState>().api.postJson('/planner/today/polish');
      final lines = (r['advice'] as List? ?? const []).map((e) => '$e').toList();
      if (!mounted) return;
      setState(() => _advice = lines);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _aiMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _aiMessage = AppLocalizations.of(context).qaLoadFailedRetry);
    }
    if (mounted) setState(() => _aiBusy = false);
  }

  Future<void> _openSettings() async {
    final prefs = Map<String, dynamic>.from((_plan?['prefs'] as Map?) ?? const {});
    final saved = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PrefsSheet(prefs: prefs),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(dpStr(context, 'dpSaved'))));
      _advice = const [];
      await _load();
    }
  }

  Future<void> _openTasks() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const TaskManagerScreen()));
    if (mounted) _load();
  }

  Future<void> _openReminders() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const RemindersScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(dpStr(context, 'dpTitle'), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: dpStr(context, 'dpRefresh'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
          IconButton(
            tooltip: dpStr(context, 'dpSettings'),
            icon: const Icon(Icons.tune_rounded),
            onPressed: _plan == null ? null : _openSettings,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(count: 6);
    if (_error != null && _plan == null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: dpStr(context, 'dpLoadFailed'),
        message: honestFailText(AppLocalizations.of(context), _error),
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(dpStr(context, 'dpRetry')),
        ),
      );
    }
    final p = _plan!;
    if (p['empty'] == true) return _empty();
    final blocks = (p['blocks'] as List? ?? const []).whereType<Map>().toList();
    final unscheduled = (p['unscheduled'] as List? ?? const []).whereType<Map>().toList();
    final bills = (p['bills'] as List? ?? const []).whereType<Map>().toList();
    final tips = (p['tips'] as List? ?? const []).whereType<Map>().toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
        children: [
          _header(p),
          if (tips.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _section(dpStr(context, 'dpTips'), [
              for (final t in tips) _bullet(_pick(t)),
            ]),
          ],
          const SizedBox(height: Gap.md),
          _aiCard(p),
          const SizedBox(height: Gap.lg),
          _heading(dpStr(context, 'dpTimeline')),
          for (final b in blocks) _BlockRow(
            block: Map<String, dynamic>.from(b),
            onTap: _tapFor(Map<String, dynamic>.from(b)),
          ),
          if (unscheduled.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _section(dpStr(context, 'dpNoFit'), [
              Text(dpStr(context, 'dpNoFitBody'),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.sm),
              for (final u in unscheduled)
                _bullet('${u['title']} · ${ld(context, dpFill(context, 'dpMin', {'n': '${u['minutes']}'}))}'),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                onPressed: _openTasks,
                icon: const Icon(Icons.view_kanban_rounded),
                label: Text(dpStr(context, 'dpOpenTasks')),
              ),
            ]),
          ],
          if (bills.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _section(dpStr(context, 'dpBills'), [
              for (final b in bills) _bullet(_pick(b)),
            ]),
          ],
        ],
      ),
    );
  }

  VoidCallback? _tapFor(Map<String, dynamic> b) {
    final kind = '${(b['src'] as Map?)?['kind'] ?? ''}';
    if (kind == 'task') return _openTasks;
    if (kind == 'reminder') return _openReminders;
    return null; // meetings / prayers are information rows, not buttons
  }

  String _pick(Map m) => '${dpIsBn(context) ? (m['bn'] ?? '') : (m['en'] ?? '')}';

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
      children: [
        const SizedBox(height: Gap.xl),
        Center(
          child: Container(
            height: 84,
            width: 84,
            decoration: const BoxDecoration(gradient: Brand.gradient, shape: BoxShape.circle),
            child: const Icon(Icons.today_rounded, size: 40, color: Colors.white),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(dpStr(context, 'dpEmptyTitle'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        Text(dpStr(context, 'dpEmptyBody'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
        const SizedBox(height: Gap.xl),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _openTasks,
            icon: const Icon(Icons.add_task_rounded),
            label: Text(dpStr(context, 'dpAddFirst')),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(dpStr(context, 'dpEmptyHow'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
    );
  }

  Widget _header(Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final w = (p['window'] as Map?) ?? const {};
    final c = (p['counts'] as Map?) ?? const {};
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ld(context, dpFill(context, 'dpWindow', {'a': '${w['start'] ?? ''}', 'b': '${w['end'] ?? ''}'})),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(
            ld(
                context,
                dpFill(context, 'dpSummary', {
                  't': '${c['tasks_planned'] ?? 0}',
                  'm': '${c['meetings'] ?? 0}',
                  'r': '${c['reminders'] ?? 0}',
                })),
            style: TextStyle(color: scheme.onSurface)),
      ]),
    );
  }

  Widget _aiCard(Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final cost = p['polish_credits'];
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(dpStr(context, 'dpAiNote'),
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.md),
        FilledButton.tonalIcon(
          onPressed: _aiBusy ? null : _polish,
          icon: _aiBusy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome_rounded),
          label: Text(cost == null
              ? dpStr(context, 'dpAi')
              : '${dpStr(context, 'dpAi')} · ${ld(context, dpFill(context, 'dpAiCost', {'n': '$cost'}))}'),
        ),
        if (_aiMessage != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_aiMessage!, style: TextStyle(color: scheme.error)),
        ],
        if (_advice.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Text(dpStr(context, 'dpAiTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          for (final a in _advice) _bullet(ld(context, a)),
        ],
      ]),
    );
  }

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Semantics(
          header: true,
          child: Text(t,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        ),
      );

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_heading(title), ...children],
      );

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: Gap.sm),
            child: Icon(Icons.circle, size: 6),
          ),
          Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
        ]),
      );
}

/// One time block: time range, kind icon, title, honest chips.
class _BlockRow extends StatelessWidget {
  final Map<String, dynamic> block;
  final VoidCallback? onTap;
  const _BlockRow({required this.block, this.onTap});

  static const _icons = {
    'task': Icons.check_circle_outline_rounded,
    'meeting': Icons.groups_rounded,
    'reminder': Icons.alarm_rounded,
    'prayer': Icons.mosque_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = '${block['kind'] ?? 'task'}';
    final past = block['past'] == true;
    final title = kind == 'prayer'
        ? '${dpIsBn(context) ? (block['title_bn'] ?? block['title']) : (block['title_en'] ?? block['title'])}'
        : '${block['title'] ?? ''}';
    final kindLabel = dpStr(context, {
          'task': 'dpKindTask',
          'meeting': 'dpKindMeeting',
          'reminder': 'dpKindReminder',
          'prayer': 'dpKindPrayer',
        }[kind] ??
        'dpKindTask');
    final chips = <(String, Color)>[
      if (block['overdue'] == true) (dpStr(context, 'dpOverdue'), Brand.danger),
      if (block['clash'] == true) (dpStr(context, 'dpClash'), Brand.warning),
      if (past) (dpStr(context, 'dpDone'), scheme.onSurfaceVariant),
    ];
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 64,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ld(context, block['start']), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(ld(context, block['end']),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, right: Gap.sm),
          child: Icon(_icons[kind] ?? Icons.circle_outlined,
              size: 20, color: past ? scheme.onSurfaceVariant : scheme.primary),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: past ? scheme.onSurfaceVariant : scheme.onSurface)),
            const SizedBox(height: 2),
            Wrap(spacing: Gap.sm, runSpacing: 2, children: [
              Text(kindLabel, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              for (final c in chips)
                Text(c.$1, style: AType.bodySmall.copyWith(color: c.$2, fontWeight: FontWeight.w700)),
            ]),
          ]),
        ),
        if (onTap != null)
          Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
      ]),
    );
    final child = ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: row);
    return onTap == null
        ? Semantics(container: true, child: child)
        : InkWell(borderRadius: BorderRadius.circular(Radii.md), onTap: onTap, child: child);
  }
}

/// Day window + prayer toggle; saved on the server (all phones agree).
class _PrefsSheet extends StatefulWidget {
  final Map<String, dynamic> prefs;
  const _PrefsSheet({required this.prefs});
  @override
  State<_PrefsSheet> createState() => _PrefsSheetState();
}

class _PrefsSheetState extends State<_PrefsSheet> {
  late String _start = '${widget.prefs['day_start'] ?? '08:00'}';
  late String _end = '${widget.prefs['day_end'] ?? '22:00'}';
  late bool _prayer = widget.prefs['prayer'] == true;
  bool _busy = false;
  String? _error;

  TimeOfDay _tod(String hhmm) {
    final parts = hhmm.split(':');
    return TimeOfDay(
        hour: int.tryParse(parts.first) ?? 8,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(bool start) async {
    final t = await showTimePicker(context: context, initialTime: _tod(start ? _start : _end));
    if (t == null) return;
    setState(() => start ? _start = _fmt(t) : _end = _fmt(t));
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().api.postJson(
          '/planner/prefs', {'day_start': _start, 'day_end': _end, 'prayer': _prayer});
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = dpStr(context, 'dpNotSaved');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(dpStr(context, 'dpSettings'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.wb_sunny_outlined),
          title: Text(dpStr(context, 'dpDayStart')),
          trailing: Text(ld(context, _start), style: const TextStyle(fontWeight: FontWeight.w700)),
          onTap: () => _pick(true),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.nightlight_outlined),
          title: Text(dpStr(context, 'dpDayEnd')),
          trailing: Text(ld(context, _end), style: const TextStyle(fontWeight: FontWeight.w700)),
          onTap: () => _pick(false),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _prayer,
          onChanged: (v) => setState(() => _prayer = v),
          title: Text(dpStr(context, 'dpPrayer')),
          subtitle: Text(dpStr(context, 'dpPrayerSub')),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(dpStr(context, 'dpSave')),
        ),
      ]),
    );
  }
}
