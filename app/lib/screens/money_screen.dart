import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';
import 'money_trends_screen.dart';
import 'money_networth_screen.dart';
import 'money_loan_detail_screen.dart';
import 'money_budget_screen.dart';
import 'money_import_screen.dart';

/// My Account — advanced personal-finance module.
///
/// Five tabs (Overview / Accounts / Transactions / Budget / Loans+Savings),
/// a notification-import entry point, and drill-down screens for trends, net
/// worth, per-loan repayment history and per-budget rollover. All offline-first
/// through the existing SyncedRepo collections; server-computed figures come
/// from [ApiClient.moneySummary].
class MoneyScreen extends StatefulWidget {
  const MoneyScreen({super.key});
  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  Map<String, dynamic>? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    for (final r in [app.accounts, app.txns, app.budgets, app.loans, app.goals]) {
      await r.sync();
    }
    try {
      final s = await app.api.moneySummary();
      if (mounted) setState(() => _summary = s);
    } catch (_) {
      // offline — tabs fall back to local repo data
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.moduleMoney),
          actions: [
            IconButton(
              tooltip: t.moneyImportTitle,
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MoneyImportScreen())),
              icon: const Icon(Icons.sms_outlined),
            ),
            IconButton(onPressed: _refresh, icon: const Icon(Icons.sync)),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(child: Text(t.moneyTabSummary, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.moneyTabAccounts, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.moneyTransactionFallback, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.moneyTabBudget, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.moneyTabLoansSavings, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: TabBarView(children: [
          _OverviewTab(summary: _summary, loading: _loading, onRefresh: _refresh),
          const _AccountsTab(),
          const _TxnsTab(),
          _BudgetsTab(summary: _summary),
          const _LoansSavingsTab(),
        ]),
      ),
    );
  }
}

// ======================= OVERVIEW =======================
class _OverviewTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  final bool loading;
  final Future<void> Function() onRefresh;
  const _OverviewTab(
      {this.summary, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    if (loading && summary == null) return const SkeletonList(count: 5);
    final s = summary;

    // net worth is computable locally from accounts + loans even offline
    final nw = _localNetWorth(app);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        // Hero balance card
        Container(
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.moneyTotalBalance,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: Gap.xs),
            Text(tkFmt(s?['total_balance'] ?? nw['assets']),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.md),
            Row(children: [
              _heroPill(Icons.trending_up, t.moneyNetWorthLabel,
                  tkFmt(nw['net_worth'])),
              const SizedBox(width: Gap.md),
              _heroPill(Icons.account_balance_outlined, t.moneyAccountsCount,
                  '${app.accounts.items.length}'),
            ]),
          ]),
        ),
        const SizedBox(height: Gap.md),
        // income / expense / net row
        Row(children: [
          Expanded(
              child: statCard(context, t.moneyMonthIncome,
                  tkFmt(s?['month_income'] ?? '0'), Brand.success,
                  Icons.south_west)),
          const SizedBox(width: Gap.md),
          Expanded(
              child: statCard(context, t.moneyMonthExpense,
                  tkFmt(s?['month_expense'] ?? '0'), Brand.danger,
                  Icons.north_east)),
        ]),
        const SizedBox(height: Gap.md),
        statCard(
            context,
            t.moneyMonthNet,
            tkFmt(s?['month_net'] ?? '0'),
            (dbl(s?['month_net']) >= 0) ? scheme.secondary : Brand.danger,
            Icons.savings_outlined),
        const SizedBox(height: Gap.lg),
        // quick links to drill-down screens
        _navTile(context, Icons.insights_outlined, t.moneyTrendsTitle,
            t.moneyTrendsSubtitle,
            () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MoneyTrendsScreen()))),
        _navTile(context, Icons.pie_chart_outline, t.moneyNetWorthTitle,
            t.moneyNetWorthSubtitle,
            () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MoneyNetWorthScreen()))),
        const SizedBox(height: Gap.lg),
        // expense breakdown
        _breakdown(context, s),
      ]),
    );
  }

  Widget _heroPill(IconData icon, String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.md, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 14, color: Colors.white70),
              const SizedBox(width: Gap.xs),
              Flexible(
                  child: Text(label,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11),
                      overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
          ]),
        ),
      );

  Widget _navTile(BuildContext context, IconData icon, String title,
          String subtitle, VoidCallback onTap) =>
      Card(
        child: ListTile(
          leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );

  Widget _breakdown(BuildContext context, Map<String, dynamic>? s) {
    final t = AppLocalizations.of(context);
    final cats = (s?['expense_by_category'] as Map?)?.cast<String, dynamic>() ?? {};
    if (cats.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.lg),
        child: Text(t.moneySummaryOffline,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    final maxVal = cats.values.fold<double>(0, (p, v) => dbl(v) > p ? dbl(v) : p);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.moneyExpenseBreakdown,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: Gap.sm),
      for (final e in cats.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(e.key),
              Text(tkFmt(e.value),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: Gap.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: maxVal > 0 ? dbl(e.value) / maxVal : 0,
                minHeight: 8,
              ),
            ),
          ]),
        ),
    ]);
  }

  Map<String, double> _localNetWorth(AppState app) {
    double assets = 0;
    for (final a in app.accounts.items) {
      assets += dbl(a['data']['opening_balance'] ?? a['data']['balance']);
    }
    double receivable = 0, liabilities = 0;
    for (final l in app.loans.items) {
      if (l['data']['settled'] == true) continue;
      final bal = dbl(l['data']['amount']) - dbl(l['data']['paid']);
      if (l['data']['kind'] == 'given') {
        receivable += bal > 0 ? bal : 0;
      } else {
        liabilities += bal > 0 ? bal : 0;
      }
    }
    return {
      'assets': assets,
      'net_worth': assets + receivable - liabilities,
    };
  }
}

// ======================= ACCOUNTS =======================
class _AccountsTab extends StatelessWidget {
  const _AccountsTab();

  Future<void> _add(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final name = TextEditingController();
    final bal = TextEditingController(text: '0');
    String type = 'cash';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.moneyNewAccount),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: name,
                        decoration: InputDecoration(labelText: t.name)),
                    const SizedBox(height: Gap.sm),
                    DropdownButtonFormField<String>(
                        initialValue: type,
                        decoration:
                            InputDecoration(labelText: t.moneyFieldType),
                        items: accTypes(t)
                            .entries
                            .map((e) => DropdownMenuItem(
                                value: e.key, child: Text(e.value)))
                            .toList(),
                        onChanged: (v) => setD(() => type = v ?? 'cash')),
                    const SizedBox(height: Gap.sm),
                    TextField(
                        controller: bal,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: t.moneyFieldOpeningBalance)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.save)),
                  ],
                )));
    if (ok == true && name.text.trim().isNotEmpty) {
      await app.accounts.add({
        'name': name.text.trim(),
        'acc_type': type,
        'opening_balance': bal.text.trim().isEmpty ? '0' : bal.text.trim(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = app.accounts.items;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? StateMessage(
              icon: Icons.account_balance_wallet_outlined,
              title: t.moneyAccountsEmpty,
              message: t.moneyAccountsEmptyHint,
              action: FilledButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                  label: Text(t.moneyNewAccount)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                for (final it in items)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        child: Icon(accIcon(it['data']['acc_type']),
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer),
                      ),
                      title: Text(it['data']['name'] ?? ''),
                      subtitle: Text(accTypes(t)[it['data']['acc_type']] ?? ''),
                      trailing: Text(
                          tkFmt(it['data']['opening_balance'] ??
                              it['data']['balance']),
                          style: const TextStyle(
                              fontWeight: FontWeight.w700)),
                      onLongPress: () => confirmDelete(
                          context, () => app.accounts.remove(it)),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ======================= TRANSACTIONS =======================
class _TxnsTab extends StatefulWidget {
  const _TxnsTab();
  @override
  State<_TxnsTab> createState() => _TxnsTabState();
}

class _TxnsTabState extends State<_TxnsTab> {
  String _query = '';
  String _filterKind = 'all'; // all|income|expense

  Future<void> _add(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final accs = app.accounts.items.where((a) => a['serverId'] != null).toList();
    if (accs.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.moneyAddAccountFirst)));
      return;
    }
    final amount = TextEditingController();
    final cat = TextEditingController();
    final note = TextEditingController();
    String kind = 'expense';
    int accId = accs.first['serverId'];
    bool split = false;
    final splitWith = TextEditingController();
    DateTime date = DateTime.now();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.moneyNewTransaction),
                  content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SegmentedButton<String>(segments: [
                        ButtonSegment(
                            value: 'expense',
                            label: Text(t.moneyKindExpense)),
                        ButtonSegment(
                            value: 'income', label: Text(t.moneyKindIncome)),
                      ], selected: {
                        kind
                      }, onSelectionChanged: (v) => setD(() => kind = v.first)),
                      const SizedBox(height: Gap.sm),
                      TextField(
                          controller: amount,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: t.moneyFieldAmountRequired)),
                      const SizedBox(height: Gap.sm),
                      DropdownButtonFormField<int>(
                          initialValue: accId,
                          decoration:
                              InputDecoration(labelText: t.moneyTabAccounts),
                          items: accs
                              .map((a) => DropdownMenuItem<int>(
                                  value: a['serverId'],
                                  child: Text(a['data']['name'] ?? '')))
                              .toList(),
                          onChanged: (v) => setD(() => accId = v ?? accId)),
                      const SizedBox(height: Gap.sm),
                      TextField(
                          controller: cat,
                          decoration: InputDecoration(
                              labelText: t.moneyFieldCategoryHint)),
                      TextField(
                          controller: note,
                          decoration: InputDecoration(
                              labelText: t.moneyFieldNoteOptional)),
                      const SizedBox(height: Gap.sm),
                      Row(children: [
                        InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                                context: ctx,
                                initialDate: date,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100));
                            if (picked != null) setD(() => date = picked);
                          },
                          child: Row(children: [
                            const Icon(Icons.calendar_today_outlined, size: 16),
                            const SizedBox(width: Gap.xs),
                            Text(DateFormat('d MMM yyyy').format(date)),
                          ]),
                        ),
                      ]),
                      if (kind == 'expense') ...[
                        const SizedBox(height: Gap.sm),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: split,
                          title: Text(t.moneySplitToggle),
                          onChanged: (v) => setD(() => split = v),
                        ),
                        if (split)
                          TextField(
                              controller: splitWith,
                              decoration: InputDecoration(
                                  labelText: t.moneySplitPeopleHint)),
                      ],
                    ]),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.save)),
                  ],
                )));
    if (ok == true && dbl(amount.text) > 0) {
      final data = <String, dynamic>{
        'account': accId,
        'kind': kind,
        'amount': amount.text.trim(),
        'category': cat.text.trim(),
        'note': note.text.trim(),
        'date': DateFormat('yyyy-MM-dd').format(date),
        'source': 'manual',
      };
      if (split && splitWith.text.trim().isNotEmpty) {
        final names = splitWith.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        data['split_with'] = names;
        data['split_mode'] = 'equal';
      }
      await app.txns.add(data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final fmt = DateFormat('d MMM');
    var items = app.txns.items;
    if (_filterKind != 'all') {
      items = items.where((it) => it['data']['kind'] == _filterKind).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      items = items.where((it) {
        final d = it['data'];
        return '${d['category']} ${d['note']}'.toLowerCase().contains(q);
      }).toList();
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(context),
          icon: const Icon(Icons.add),
          label: Text(t.moneyTransactionFallback)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
          child: Column(children: [
            TextField(
              decoration: InputDecoration(
                hintText: t.moneySearchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: Gap.sm),
            Row(children: [
              for (final f in const ['all', 'income', 'expense'])
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    label: Text(f == 'all'
                        ? t.moneyFilterAll
                        : f == 'income'
                            ? t.moneyKindIncome
                            : t.moneyKindExpense),
                    selected: _filterKind == f,
                    onSelected: (_) => setState(() => _filterKind = f),
                  ),
                ),
            ]),
          ]),
        ),
        Expanded(
          child: items.isEmpty
              ? StateMessage(
                  icon: Icons.receipt_long_outlined,
                  title: t.moneyNoTransactions,
                  message: t.moneyNoTransactionsHint,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 88),
                  children: [
                    for (final it in items)
                      Card(
                        child: ListTile(
                          leading: Icon(
                              it['data']['kind'] == 'income'
                                  ? Icons.arrow_downward
                                  : Icons.arrow_upward,
                              color: it['data']['kind'] == 'income'
                                  ? Brand.success
                                  : Brand.danger),
                          title: Text(
                              (it['data']['category']?.toString().isNotEmpty ==
                                      true)
                                  ? it['data']['category']
                                  : (it['data']['note']?.toString().isNotEmpty ==
                                          true
                                      ? it['data']['note']
                                      : t.moneyTransactionFallback)),
                          subtitle: Row(children: [
                            Text(it['data']['date'] != null
                                ? fmt.format(DateTime.tryParse(
                                        it['data']['date']) ??
                                    DateTime.now())
                                : ''),
                            if (it['data']['source'] == 'notification' ||
                                it['data']['source'] == 'ai') ...[
                              const SizedBox(width: Gap.sm),
                              Icon(Icons.auto_awesome,
                                  size: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .secondary),
                            ],
                            if (it['data']['split_with'] != null) ...[
                              const SizedBox(width: Gap.sm),
                              const Icon(Icons.call_split, size: 12),
                            ],
                          ]),
                          trailing: Text(
                              '${it['data']['kind'] == 'income' ? '+' : '-'}${tkFmt(it['data']['amount'])}',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: it['data']['kind'] == 'income'
                                      ? Brand.success
                                      : Brand.danger)),
                          onLongPress: () => confirmDelete(
                              context, () => app.txns.remove(it)),
                        ),
                      ),
                  ],
                ),
        ),
      ]),
    );
  }
}

// ======================= BUDGETS =======================
class _BudgetsTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  const _BudgetsTab({this.summary});

  Future<void> _add(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final cat = TextEditingController();
    final lim = TextEditingController();
    bool rollover = false;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.moneyNewBudget),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: cat,
                        decoration:
                            InputDecoration(labelText: t.moneyFieldCategory)),
                    const SizedBox(height: Gap.sm),
                    TextField(
                        controller: lim,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: t.moneyFieldMonthlyLimit)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: rollover,
                      title: Text(t.moneyRolloverToggle),
                      subtitle: Text(t.moneyRolloverHint),
                      onChanged: (v) => setD(() => rollover = v),
                    ),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.save)),
                  ],
                )));
    if (ok == true && cat.text.trim().isNotEmpty) {
      await app.budgets.add({
        'category': cat.text.trim(),
        'monthly_limit': lim.text.trim(),
        'rollover': rollover,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final budgets =
        (summary?['budgets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: budgets.isEmpty
          ? StateMessage(
              icon: Icons.donut_large_outlined,
              title: app.budgets.items.isEmpty
                  ? t.moneyBudgetEmpty
                  : t.moneyBudgetSpendOffline,
              message: t.moneyBudgetEmptyHint,
              action: FilledButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                  label: Text(t.moneyNewBudget)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                for (final b in budgets)
                  Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.md),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  MoneyBudgetScreen(category: b['category']))),
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(b['category'] ?? '',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    Text(
                                        '${tkFmt(b['spent'])} / ${tkFmt(b['limit'])}'),
                                  ]),
                              const SizedBox(height: Gap.sm),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(Radii.sm),
                                child: LinearProgressIndicator(
                                  value: ((b['pct'] as num?)?.toInt() ?? 0)
                                          .clamp(0, 100) /
                                      100,
                                  minHeight: 8,
                                  color: b['state'] == 'over'
                                      ? Brand.danger
                                      : b['state'] == 'near'
                                          ? Brand.warning
                                          : Brand.success,
                                ),
                              ),
                              if (b['state'] == 'over')
                                Padding(
                                    padding:
                                        const EdgeInsets.only(top: Gap.xs),
                                    child: Text(t.moneyBudgetOver,
                                        style: const TextStyle(
                                            color: Brand.danger,
                                            fontSize: 12)))
                              else if (b['state'] == 'near')
                                Padding(
                                    padding:
                                        const EdgeInsets.only(top: Gap.xs),
                                    child: Text(t.moneyBudgetNear,
                                        style: const TextStyle(
                                            color: Brand.warning,
                                            fontSize: 12))),
                            ]),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ======================= LOANS + SAVINGS =======================
class _LoansSavingsTab extends StatelessWidget {
  const _LoansSavingsTab();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(t.moneyLoansHeading,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(
            onPressed: () => _addLoan(context),
            icon: const Icon(Icons.add),
            label: Text(t.add)),
      ]),
      if (app.loans.items.isEmpty)
        Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Text(t.moneyLoansEmpty,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
      for (final it in app.loans.items)
        Card(
          child: ListTile(
            leading: Icon(
                it['data']['kind'] == 'given'
                    ? Icons.call_made
                    : Icons.call_received,
                color: it['data']['kind'] == 'given'
                    ? Brand.warning
                    : Brand.blue),
            title: Text(
                '${it['data']['person']} · ${tkFmt(it['data']['amount'])}'),
            subtitle: Text(_loanSubtitle(context, it['data'])),
            trailing: it['data']['settled'] == true
                ? const Icon(Icons.check_circle, color: Brand.success)
                : const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => MoneyLoanDetailScreen(item: it))),
          ),
        ),
      const Divider(height: 28),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(t.moneySavingsGoal,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(
            onPressed: () => _addGoal(context),
            icon: const Icon(Icons.add),
            label: Text(t.add)),
      ]),
      for (final it in app.goals.items)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(it['data']['title'] ?? ''),
                        Text(
                            '${tkFmt(it['data']['saved_amount'])} / ${tkFmt(it['data']['target_amount'])}'),
                      ]),
                  const SizedBox(height: Gap.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: LinearProgressIndicator(
                        minHeight: 8,
                        value: (dbl(it['data']['target_amount']) > 0
                            ? (dbl(it['data']['saved_amount']) /
                                    dbl(it['data']['target_amount']))
                                .clamp(0.0, 1.0)
                            : 0)),
                  ),
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: () => _addToGoal(context, it),
                          child: Text(t.moneyAddDeposit))),
                ]),
          ),
        ),
    ]);
  }

  String _loanSubtitle(BuildContext context, Map data) {
    final t = AppLocalizations.of(context);
    final paid = dbl(data['paid']);
    final base = data['kind'] == 'given' ? t.moneyLoanGiven : t.moneyLoanTaken;
    if (data['settled'] == true) return '$base · ${t.moneyLoanSettled}';
    if (paid > 0) {
      return '$base · ${t.moneyLoanBalanceLabel(tkFmt(dbl(data['amount']) - paid))}';
    }
    return base;
  }

  Future<void> _addLoan(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final person = TextEditingController();
    final amount = TextEditingController();
    String kind = 'given';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.moneyNewLoan),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    SegmentedButton<String>(segments: [
                      ButtonSegment(
                          value: 'given', label: Text(t.moneyLent)),
                      ButtonSegment(
                          value: 'taken', label: Text(t.moneyBorrowed)),
                    ], selected: {
                      kind
                    }, onSelectionChanged: (v) => setD(() => kind = v.first)),
                    TextField(
                        controller: person,
                        decoration: InputDecoration(
                            labelText: t.moneyFieldPersonName)),
                    TextField(
                        controller: amount,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: t.amount)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.save)),
                  ],
                )));
    if (ok == true && person.text.trim().isNotEmpty) {
      await app.loans.add({
        'kind': kind,
        'person': person.text.trim(),
        'amount': amount.text.trim(),
        'settled': false,
        'paid': '0',
        'repayments': <Map<String, dynamic>>[],
      });
    }
  }

  Future<void> _addGoal(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final title = TextEditingController();
    final target = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(t.moneySavingsGoal),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: title,
                    decoration:
                        InputDecoration(labelText: t.moneyFieldGoalPurpose)),
                TextField(
                    controller: target,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: t.moneyFieldTargetTaka)),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.save)),
              ],
            ));
    if (ok == true && title.text.trim().isNotEmpty) {
      await app.goals.add({
        'title': title.text.trim(),
        'target_amount': target.text.trim(),
        'saved_amount': '0',
      });
    }
  }

  Future<void> _addToGoal(
      BuildContext context, Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final add = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(t.moneyAddDeposit),
              content: TextField(
                  controller: add,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration:
                      InputDecoration(labelText: t.moneyFieldDepositAmount)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.add)),
              ],
            ));
    if (ok == true) {
      final cur = dbl(it['data']['saved_amount']);
      final plus = dbl(add.text);
      await app.goals.update(it, {'saved_amount': (cur + plus).toString()});
    }
  }
}
