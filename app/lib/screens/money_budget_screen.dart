import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../budget_api.dart';
import '../widgets/skeleton.dart';
import '../widgets/budget_card.dart';
import '../widgets/budget_insights.dart';
import '../widgets/budget_sheets.dart';
import 'money_common.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// BUDGET module (#50) — advanced per-category budgeting.
///
/// Opens two ways:
///   * as the Budget MODULE (no [category]) — three tabs: This month (budget
///     cards + total + insights + goal link), History (month picker), Plan
///     (next-month suggestions from real history + 50-30-20 template).
///   * as a category DRILL-DOWN ([category] set — how money_screen opens it) —
///     a focused rollover history for that one category.
///
/// Every "spent" number is server-computed by budget.py from the user's REAL
/// transactions (read-only reuse of the money data); limits are user-set and
/// sync through the existing `budgets` SyncedRepo. Offline, the saved limits
/// stay on device and a clear offline state explains that spend needs the
/// server. All money is formatted via tkFmt — no float maths on amounts here.
class MoneyBudgetScreen extends StatefulWidget {
  /// When non-null/non-empty, opens the single-category drill-down.
  final String? category;
  const MoneyBudgetScreen({super.key, this.category});
  @override
  State<MoneyBudgetScreen> createState() => _MoneyBudgetScreenState();
}

class _MoneyBudgetScreenState extends State<MoneyBudgetScreen> {
  bool get _drill => (widget.category ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_drill) {
      return _CategoryHistory(category: widget.category!);
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        // banners-everywhere (owner 26 Oct): one bottom banner, Free only
        bottomNavigationBar: const AdBannerSlot(screen: 'budget'),
        appBar: AppBar(
          title: Text(t.budgetTitle),
          bottom: TabBar(
              isScrollable: MediaQuery.textScalerOf(context).scale(10) > 11.5,
              tabAlignment: MediaQuery.textScalerOf(context).scale(10) > 11.5
                  ? TabAlignment.start
                  : null,
              tabs: [
            Tab(text: t.budgetTabThisMonth),
            Tab(text: t.budgetTabHistory),
            Tab(text: t.budgetTabPlan),
          ]),
        ),
        body: const TabBarView(children: [
          _ThisMonthTab(),
          _HistoryTab(),
          _PlanTab(),
        ]),
      ),
    );
  }
}

// ======================= THIS MONTH =======================
class _ThisMonthTab extends StatefulWidget {
  const _ThisMonthTab();
  @override
  State<_ThisMonthTab> createState() => _ThisMonthTabState();
}

class _ThisMonthTabState extends State<_ThisMonthTab> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _goalResult;
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    // rt1 (reality audit): repo.sync() notifies AppState listeners
    // synchronously — from initState that is "markNeedsBuild() called during
    // build" (FlutterError on opening Money). Start after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _offline = false;
    });
    await app.budgets.sync();
    await app.goals.sync();
    try {
      final d = await app.api.budgetMonth();
      if (mounted) setState(() => _data = d);
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addOrEdit(BuildContext context, {Map<String, dynamic>? line}) async {
    final app = context.read<AppState>();
    // find the local repo item backing this category (if editing)
    Map<String, dynamic>? item;
    if (line != null) {
      for (final it in app.budgets.items) {
        if (it['data']['category'] == line['category']) {
          item = it;
          break;
        }
      }
    }
    final res = await showBudgetSheet(context, initial: item?['data'] ?? line);
    if (res == null) return;
    if (item != null) {
      await app.budgets.update(item,
          {'monthly_limit': res.monthlyLimit, 'rollover': res.rollover});
    } else {
      await app.budgets.add({
        'category': res.category,
        'monthly_limit': res.monthlyLimit,
        'rollover': res.rollover,
      });
    }
    await _refresh();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> line) async {
    final app = context.read<AppState>();
    for (final it in app.budgets.items) {
      if (it['data']['category'] == line['category']) {
        await confirmDelete(context, () => app.budgets.remove(it));
        break;
      }
    }
    await _refresh();
  }

  Future<void> _linkGoal(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final t = AppLocalizations.of(context);
    try {
      final r = await app.api.budgetGoalLink();
      if (mounted) setState(() => _goalResult = r);
      await app.goals.sync();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.budgetOffline)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    if (_loading && _data == null) return const SkeletonList(count: 5);

    final lines =
        (_data?['lines'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final insights =
        (_data?['insights'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totals =
        (_data?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hasGoal = app.goals.items.isNotEmpty;

    if (lines.isEmpty && app.budgets.items.isEmpty) {
      return Scaffold(
        body: StateMessage(
          icon: Icons.donut_large_rounded,
          title: t.budgetEmptyTitle,
          message: t.budgetEmptyBody,
          action: FilledButton.icon(
              onPressed: () => _addOrEdit(context),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.budgetAddFirst)),
        ),
      );
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _addOrEdit(context), child: const Icon(Icons.add_rounded)),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 88),
          children: [
            if (totals.isNotEmpty) BudgetTotalHeader(totals: totals),
            if (_offline)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_off_rounded),
                    title: Text(t.budgetOffline),
                  ),
                ),
              ),
            const SizedBox(height: Gap.md),
            if (insights.isNotEmpty) ...[
              BudgetInsights(insights: insights),
              const SizedBox(height: Gap.md),
            ],
            for (final line in lines)
              BudgetCard(
                line: line,
                onTap: () => _addOrEdit(context, line: line),
                onLongPress: () => _delete(context, line),
              ),
            // show locally-known budgets the server hasn't echoed yet (offline)
            if (_offline)
              for (final it in app.budgets.items)
                if (!lines.any((l) => l['category'] == it['data']['category']))
                  BudgetCard(
                    line: {
                      'category': it['data']['category'],
                      'spent': '0',
                      'effective_limit': it['data']['monthly_limit'],
                      'remaining': it['data']['monthly_limit'],
                      'pct': 0,
                      'bar_pct': 0,
                      'state': 'none',
                      'over_by': '0',
                      'rollover': it['data']['rollover'] == true,
                    },
                    onTap: () => _addOrEdit(context,
                        line: it['data'].cast<String, dynamic>()),
                  ),
            const SizedBox(height: Gap.md),
            BudgetGoalLinkCard(
              result: _goalResult,
              hasGoal: hasGoal,
              onLink: hasGoal ? () => _linkGoal(context) : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= HISTORY =======================
class _HistoryTab extends StatefulWidget {
  const _HistoryTab();
  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  late String _month;
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _month = DateFormat('yyyy-MM').format(DateTime.now());
    _load();
  }

  List<String> _recentMonths() {
    final now = DateTime.now();
    return [
      for (int i = 0; i < 6; i++)
        DateFormat('yyyy-MM').format(DateTime(now.year, now.month - i, 1))
    ];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offline = false;
    });
    try {
      final d = await context.read<AppState>().api.budgetMonth(month: _month);
      if (mounted) setState(() => _data = d);
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lines =
        (_data?['lines'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totals =
        (_data?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
        child: SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final m in _recentMonths())
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    label: Text(m),
                    selected: _month == m,
                    onSelected: (_) {
                      setState(() => _month = m);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      Expanded(
        child: _loading
            ? const SkeletonList(count: 4)
            : _offline
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    title: t.budgetLoadFailed,
                    message: t.budgetOffline,
                    action:
                        FilledButton(onPressed: _load, child: Text(t.retry)),
                  )
                : lines.isEmpty
                    ? StateMessage(
                        icon: Icons.history_rounded,
                        title: t.budgetEmptyTitle,
                        message: t.budgetEmptyBody,
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(
                              Gap.lg, 0, Gap.lg, Gap.xl),
                          children: [
                            if (totals.isNotEmpty)
                              BudgetTotalHeader(totals: totals),
                            const SizedBox(height: Gap.md),
                            for (final line in lines) BudgetCard(line: line),
                          ],
                        ),
                      ),
      ),
    ]);
  }
}

// ======================= PLAN =======================
class _PlanTab extends StatefulWidget {
  const _PlanTab();
  @override
  State<_PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends State<_PlanTab> {
  Map<String, dynamic>? _plan;
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offline = false;
    });
    try {
      final p = await context.read<AppState>().api.budgetPlan();
      if (mounted) setState(() => _plan = p);
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useSuggestion(
      BuildContext context, Map<String, dynamic> s) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final t = AppLocalizations.of(context);
    final cat = s['category']?.toString() ?? '';
    final limit = '${s['suggested_limit'] ?? ''}';
    Map<String, dynamic>? existing;
    for (final it in app.budgets.items) {
      if (it['data']['category'] == cat) {
        existing = it;
        break;
      }
    }
    if (existing != null) {
      await app.budgets.update(existing, {'monthly_limit': limit});
    } else {
      await app.budgets
          .add({'category': cat, 'monthly_limit': limit, 'rollover': false});
    }
    messenger.showSnackBar(SnackBar(content: Text(t.save)));
  }

  Future<void> _template(BuildContext context) async {
    final app = context.read<AppState>();
    await showTemplateSheet(context,
        fetchTemplate: (income) => app.api.budgetTemplate(income));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final suggestions =
        (_plan?['suggestions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.pie_chart_outline_rounded),
              title: Text(t.budgetTemplateTitle),
              subtitle: Text(t.budgetTemplateBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _template(context),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(t.budgetPlanTitle,
              style:
                  AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: Gap.xs),
          Text(t.budgetPlanBody,
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (_loading)
            const SkeletonList(count: 3)
          else if (_offline)
            StateMessage(
              icon: Icons.cloud_off_rounded,
              title: t.budgetLoadFailed,
              message: t.budgetOffline,
              action: FilledButton(onPressed: _load, child: Text(t.retry)),
            )
          else if (suggestions.isEmpty)
            StateMessage(
              icon: Icons.insights_rounded,
              title: t.budgetPlanTitle,
              message: t.budgetEmptyBody,
            )
          else
            for (final s in suggestions)
              Card(
                child: ListTile(
                  title: Text(s['category']?.toString() ?? ''),
                  subtitle: Text(
                      '${t.budgetPlanAvg}: ${tkFmt(s['avg_spent'])}'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(tkFmt(s['suggested_limit']),
                          style:
                              const TextStyle(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
                      TextButton(
                          onPressed: () => _useSuggestion(context, s),
                          child: Text(t.budgetPlanUse)),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

// ======================= CATEGORY DRILL-DOWN =======================
class _CategoryHistory extends StatefulWidget {
  final String category;
  const _CategoryHistory({required this.category});
  @override
  State<_CategoryHistory> createState() => _CategoryHistoryState();
}

class _CategoryHistoryState extends State<_CategoryHistory> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      _data = await context.read<AppState>().api.budgetHistory(widget.category);
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rollover = _data?['rollover'] == true;
    final months =
        (_data?['months'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final carry = dbl(_data?['carry_forward']);
    return Scaffold(
      appBar: AppBar(title: Text(widget.category), actions: [
        IconButton(
            tooltip: AppLocalizations.of(context).refresh,onPressed: _load, icon: const Icon(Icons.sync_rounded)),
      ]),
      body: _loading
          ? const SkeletonList(count: 4)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: widget.category,
                  message: honestFailText(t, _failCause, otherwise: t.budgetOffline),
                  action:
                      FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  Row(children: [
                    Icon(rollover ? Icons.autorenew_rounded : Icons.block_rounded, size: 18),
                    const SizedBox(width: Gap.sm),
                    Text(rollover ? t.budgetRolloverOn : t.budgetRolloverOff,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: Gap.md),
                  if (rollover)
                    Card(
                      color: scheme.secondaryContainer,
                      child: ListTile(
                        leading: Icon(Icons.savings_rounded,
                            color: scheme.onSecondaryContainer),
                        title: Text(t.budgetCarryForward,
                            style: TextStyle(
                                color: scheme.onSecondaryContainer)),
                        trailing: Text(tkFmt(carry),
                            style: TextStyle(fontFeatures: AFonts.tabular,
                                fontWeight: FontWeight.bold,
                                color: scheme.onSecondaryContainer)),
                      ),
                    ),
                  const SizedBox(height: Gap.md),
                  // one card per month; show the month as the card heading
                  for (final m in months)
                    BudgetCard(
                      line: {
                        ...m,
                        'category': m['month'] ?? widget.category,
                        'rollover': rollover,
                      },
                    ),
                ]),
    );
  }
}
