import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../budget_api.dart';
import '../widgets/skeleton.dart';
import '../widgets/budget_card.dart';
import '../widgets/budget_insights.dart';
import '../widgets/budget_sheets.dart';
import '../widgets/fam_empty.dart';
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

  /// remhbud: "now" for the month list (tests pass a fixed clock); default is
  /// the Asia/Dhaka wall clock so months match the server's.
  final DateTime? now;

  /// Which tab opens first (0 this month, 1 history, 2 plan).
  final int initialTab;
  const MoneyBudgetScreen({super.key, this.category, this.now, this.initialTab = 0});
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
      initialIndex: widget.initialTab.clamp(0, 2),
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
        body: TabBarView(children: [
          const _ThisMonthTab(),
          _HistoryTab(now: widget.now),
          const _PlanTab(),
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
    final res = await showBudgetSheet(context,
        initial: item?['data'] ?? line,
        choices: budgetCategoryChoices(
            app.txns.items.whereType<Map>(),
            taken: [for (final b in app.budgets.items) '${b['data']['category'] ?? ''}']));
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

  /// remhbud: "no savings goal" used to be a dead end on this page.
  Future<void> _createGoal(BuildContext context) async {
    final app = context.read<AppState>();
    final g = await showGoalCreateSheet(context);
    if (g == null) return;
    await app.goals.add({'title': g.title, 'target_amount': g.target, 'saved_amount': '0'});
    if (mounted) setState(() {});
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
      // remhbud: benefit line + big button + how-to (the app-wide shape).
      return Scaffold(
        body: FamEmptyState(
          key: const ValueKey('rhb_budget_empty'),
          icon: Icons.donut_large_rounded,
          title: t.budgetEmptyTitle,
          benefit: t.budgetEmptyBody,
          primaryLabel: t.budgetAddFirst,
          onPrimary: () => _addOrEdit(context),
          steps: [t.rhbBudgetHow1, t.rhbBudgetHow2, t.rhbBudgetHow3],
          header: _offline
              ? Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_off_rounded),
                    title: Text(t.budgetOffline),
                  ),
                )
              : null,
        ),
      );
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton(
          tooltip: t.budgetNew, // remhbud: TalkBack name
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
              onCreateGoal: () => _createGoal(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= HISTORY =======================
class _HistoryTab extends StatefulWidget {
  final DateTime? now;
  const _HistoryTab({this.now});
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
    _month = moneyMonthKey(_now);
    _load();
  }

  // remhbud: Asia/Dhaka months (the server's), or the injected test clock.
  DateTime get _now => widget.now ?? dhakaNow();

  /// The last 6 months, newest first (DateTime(y, m - i, 1) rolls the year).
  List<String> _recentMonths() {
    final now = _now;
    return [
      for (int i = 0; i < 6; i++) moneyMonthKey(DateTime(now.year, now.month - i, 1))
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
        // remhbud: a scrolling Row (all 6 months built, height follows the
        // text size — the fixed 40px row clipped chips at 200%)
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final m in _recentMonths())
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    key: ValueKey('rhb_month_$m'),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    // remhbud: "October 2026" in the UI language, not "2026-10"
                    label: Text(moneyMonth(context, m)),
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
                        title: t.rhbHistoryEmpty(moneyMonth(context, _month)),
                        message: t.budgetEmptyBody,
                        action: FilledButton.icon(
                          key: const ValueKey('rhb_history_go'),
                          style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                          onPressed: () => DefaultTabController.of(context).animateTo(0),
                          icon: const Icon(Icons.donut_large_rounded),
                          label: Text(t.budgetTabThisMonth),
                        ),
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
    final done = t.rhbSuggestionUsed(moneyCatLabel(t, cat), tkOf(context, limit));
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
    // remhbud: say WHAT was set (was a bare "Save" toast).
    messenger.showSnackBar(SnackBar(content: Text(done)));
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
              message: t.rhbPlanEmpty,
            )
          else
            for (final s in suggestions)
              // remhbud: a wrapping card — the old ListTile squeezed the
              // amount + button into a 56px trailing slot (overflow at any
              // text size with a Bangla label).
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(moneyCatLabel(t, s['category']),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${t.budgetPlanAvg}: ${tkOf(context, s['avg_spent'])}'),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: Gap.sm,
                        children: [
                          Text(tkOf(context, s['suggested_limit']),
                              style: const TextStyle(
                                  fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700, fontSize: 18)),
                          TextButton(
                              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                              onPressed: () => _useSuggestion(context, s),
                              child: Text(t.budgetPlanUse)),
                        ],
                      ),
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
      appBar: AppBar(title: Text(moneyCatLabel(t, widget.category)), actions: [
        IconButton(
            tooltip: AppLocalizations.of(context).refresh,onPressed: _load, icon: const Icon(Icons.sync_rounded)),
      ]),
      body: _loading
          ? const SkeletonList(count: 4)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: moneyCatLabel(t, widget.category),
                  message: honestFailText(t, _failCause, otherwise: t.budgetOffline),
                  action:
                      FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  Row(children: [
                    Icon(rollover ? Icons.autorenew_rounded : Icons.block_rounded, size: 18),
                    const SizedBox(width: Gap.sm),
                    Expanded( // remhbud: wraps at 200% instead of overflowing
                      child: Text(rollover ? t.budgetRolloverOn : t.budgetRolloverOff,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
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
                        trailing: Text(tkOf(context, carry),
                            style: TextStyle(fontFeatures: AFonts.tabular,
                                fontWeight: FontWeight.bold,
                                color: scheme.onSecondaryContainer)),
                      ),
                    ),
                  const SizedBox(height: Gap.md),
                  // one card per month; show the month as the card heading
                  for (final m in months)
                    BudgetCard(
                      // remhbud: the month as the heading, in the UI language
                      title: moneyMonth(context, m['month']),
                      line: {
                        ...m,
                        'category': widget.category,
                        'rollover': rollover,
                      },
                    ),
                ]),
    );
  }
}
