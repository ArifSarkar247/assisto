import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// EXPENSE SPLITTING (Splitwise-style) — ADVANCED (#183, SPEC v2.1 §20).
///
/// A group of people, shared expenses (who paid, split equally or by weighted
/// share or by exact amounts), each person's NET balance (owes / is owed), and
/// a "simplify debts" settle-up suggestion — the shortest list of
/// "X pays Y ৳Z" transfers that clears everyone.
///
/// All MONEY is INTEGER POISHA. The on-screen math mirrors backend/core/logic/
/// expense_split.py VERBATIM (largest-remainder split + greedy settle-up) so
/// balances are deterministic and net to EXACTLY zero, online or offline. The
/// app HOLDS NO MONEY — settle-up is a SUGGESTION people act on themselves.
///
/// Honest states: welcome (first use) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter; the ৳ sign is a currency glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('split/people')   → [{id, name}]
///   listItems('split/expenses') → [{id, title, payer, amount, mode,
///                                    participants, parts}]
/// create/update/deleteItem on the same paths; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
class ExpenseSplitScreen extends StatefulWidget {
  const ExpenseSplitScreen({super.key});
  @override
  State<ExpenseSplitScreen> createState() => _ExpenseSplitScreenState();
}

const String _peoplePath = 'split/people';
const String _expensesPath = 'split/expenses';

const String _modeEqual = 'equal';
const String _modeShares = 'shares';
const String _modeExact = 'exact';

class _ExpenseSplitScreenState extends State<ExpenseSplitScreen> {
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _expenses = [];
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
      final res = await Future.wait(
          [api.listItems(_peoplePath), api.listItems(_expensesPath)]);
      _people = res[0];
      _expenses = res[1];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  String _nameOf(dynamic id) {
    for (final p in _people) {
      if (p['id'] == id) return (p['name'] ?? '').toString();
    }
    return '';
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.splitTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.splitTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.splitLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_people.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.splitTitle)),
        body: StateMessage(
          icon: Icons.group_add_outlined,
          title: tr.splitWelcomeTitle,
          message: tr.splitWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addPerson,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(tr.splitAddPerson),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.splitTitle),
          bottom: TabBar(tabs: [
            Tab(text: tr.splitTabPeople),
            Tab(text: tr.splitTabExpenses),
            Tab(text: tr.splitTabSettle),
          ]),
        ),
        body: TabBarView(children: [
          _PeopleTab(people: _people, onAdd: _addPerson, onChanged: _load),
          _ExpensesTab(
            people: _people,
            expenses: _expenses,
            nameOf: _nameOf,
            onChanged: _load,
          ),
          _SettleTab(people: _people, expenses: _expenses),
        ]),
      ),
    );
  }

  Future<void> _addPerson() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final c = TextEditingController();
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr.splitAddPerson, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: c,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.splitPersonName,
                  border: const OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, c.text),
                  child: Text(tr.save)),
            ),
          ]),
        );
      },
    );
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final dup = _people.any((p) =>
        (p['name'] ?? '').toString().toLowerCase() == trimmed.toLowerCase());
    if (dup) {
      _toast(tr.splitDuplicateName);
      return;
    }
    try {
      await api.createItem(_peoplePath, {'name': trimmed});
      await _load();
      if (mounted) _toast(tr.splitSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= PEOPLE =======================
class _PeopleTab extends StatelessWidget {
  final List<Map<String, dynamic>> people;
  final Future<void> Function() onAdd;
  final Future<void> Function() onChanged;
  const _PeopleTab(
      {required this.people, required this.onAdd, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onAdd,
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(tr.splitAddPerson),
      ),
      body: RefreshIndicator(
        onRefresh: onChanged,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          itemCount: people.length,
          separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
          itemBuilder: (_, i) {
            final p = people[i];
            final nm = (p['name'] ?? '').toString();
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                      nm.trim().isEmpty
                          ? '?'
                          : nm.characters.first.toUpperCase(),
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                ),
                title: Text(nm, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: tr.delete,
                  onPressed: () => _confirmDelete(context, p),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, Map<String, dynamic> p) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.splitDeletePersonTitle),
        content: Text(tr.splitDeletePersonBody((p['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = p['id'];
    if (id is int) await api.deleteItem(_peoplePath, id);
    await onChanged();
  }
}

// ======================= EXPENSES =======================
class _ExpensesTab extends StatelessWidget {
  final List<Map<String, dynamic>> people;
  final List<Map<String, dynamic>> expenses;
  final String Function(dynamic) nameOf;
  final Future<void> Function() onChanged;
  const _ExpensesTab(
      {required this.people,
      required this.expenses,
      required this.nameOf,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context),
        icon: const Icon(Icons.add),
        label: Text(tr.splitAddExpense),
      ),
      body: expenses.isEmpty
          ? StateMessage(
              icon: Icons.receipt_long_outlined,
              title: tr.splitNoExpensesTitle,
              message: tr.splitNoExpensesBody,
              action: FilledButton.icon(
                onPressed: () => _addOrEdit(context),
                icon: const Icon(Icons.add),
                label: Text(tr.splitAddExpense),
              ),
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                itemCount: expenses.length,
                separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                itemBuilder: (_, i) {
                  final e = expenses[i];
                  final mode = (e['mode'] ?? _modeEqual).toString();
                  final total = _SplitMath.expenseTotal(e, people);
                  return Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading:
                          Icon(Icons.receipt_outlined, color: scheme.primary),
                      title: Text(
                          (e['title'] ?? tr.splitExpenseGeneric).toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        tr.splitPaidBySplit(
                            nameOf(e['payer']), _modeLabel(tr, mode)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_SplitMath.fmtPoisha(total),
                            style: Theme.of(context).textTheme.titleSmall),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') _addOrEdit(context, existing: e);
                            if (v == 'delete') _delete(context, e);
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                            PopupMenuItem(
                                value: 'delete', child: Text(tr.delete)),
                          ],
                        ),
                      ]),
                      onTap: () => _addOrEdit(context, existing: e),
                    ),
                  );
                },
              ),
            ),
    );
  }

  String _modeLabel(AppLocalizations tr, String m) {
    switch (m) {
      case _modeShares:
        return tr.splitModeShares;
      case _modeExact:
        return tr.splitModeExact;
      default:
        return tr.splitModeEqual;
    }
  }

  Future<void> _addOrEdit(BuildContext context,
      {Map<String, dynamic>? existing}) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ExpenseForm(people: people, existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_expensesPath, existing['id'] as int, result);
      } else {
        await api.createItem(_expensesPath, result);
      }
      await onChanged();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.splitSaved)));
    } catch (_) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.saveFailed)));
    }
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> e) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.splitDeleteExpenseTitle),
        content: Text(tr.splitDeleteExpenseBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = e['id'];
    if (id is int) await api.deleteItem(_expensesPath, id);
    await onChanged();
  }
}

// ======================= SETTLE UP =======================
class _SettleTab extends StatelessWidget {
  final List<Map<String, dynamic>> people;
  final List<Map<String, dynamic>> expenses;
  const _SettleTab({required this.people, required this.expenses});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (expenses.isEmpty) {
      return StateMessage(
        icon: Icons.handshake_outlined,
        title: tr.splitSettleEmptyTitle,
        message: tr.splitSettleEmptyBody,
      );
    }
    final s = _SplitMath.groupSummary(people, expenses);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.summarize_outlined, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(tr.splitTotalSpent,
                      style: Theme.of(context).textTheme.bodyMedium)),
              Text(_SplitMath.fmtPoisha(s.totalSpent),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(tr.splitBalances, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        for (final r in s.rows) _balanceRow(context, r),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Icon(Icons.auto_fix_high_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.splitSettleUp,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 26, bottom: Gap.sm),
          child: Text(tr.splitSettleUpHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        if (s.settlements.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading:
                  const Icon(Icons.check_circle_outline, color: Brand.success),
              title: Text(tr.splitAllSettled),
            ),
          ),
        for (final t in s.settlements)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              leading: const Icon(Icons.east, color: Brand.blue),
              title: Text(
                tr.splitPaysText(t.fromName, t.toName),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(_SplitMath.fmtPoisha(t.amount),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Brand.blue, fontWeight: FontWeight.bold)),
            ),
          ),
        const SizedBox(height: Gap.md),
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(s.reconciles ? Icons.verified_outlined : Icons.info_outline,
                  size: 18,
                  color:
                      s.reconciles ? Brand.success : scheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.splitNoMoneyNote,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _balanceRow(BuildContext context, _SplitPerson r) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color c = r.state == 'is_owed'
        ? Brand.success
        : (r.state == 'owes' ? scheme.error : scheme.onSurfaceVariant);
    final String badge = r.state == 'is_owed'
        ? tr.splitIsOwed
        : (r.state == 'owes' ? tr.splitOwes : tr.splitClear);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                  tr.splitPaidShare(_SplitMath.fmtPoisha(r.paid),
                      _SplitMath.fmtPoisha(r.share)),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_SplitMath.fmtPoisha(r.net.abs()),
                style: TextStyle(color: c, fontWeight: FontWeight.bold)),
            Text(badge, style: TextStyle(color: c, fontSize: 11)),
          ]),
        ]),
      ),
    );
  }
}

/// Add / edit expense form: title, payer, mode, amount, participants / shares /
/// exact amounts. Validation mirrors expense_split.validate_expense.
class _ExpenseForm extends StatefulWidget {
  final List<Map<String, dynamic>> people;
  final Map<String, dynamic>? existing;
  const _ExpenseForm({required this.people, this.existing});
  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _amount =
      TextEditingController(text: widget.existing?['amount']?.toString() ?? '');
  late dynamic _payer;
  late String _mode;
  late Set<dynamic> _participants; // equal mode
  final Map<dynamic, TextEditingController> _weights = {}; // shares
  final Map<dynamic, TextEditingController> _exact = {}; // exact amounts

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _payer = ex?['payer'] ??
        (widget.people.isNotEmpty ? widget.people.first['id'] : null);
    _mode = (ex?['mode'] ?? _modeEqual).toString();
    final part = (ex?['participants'] as List?)?.toList();
    _participants =
        part != null ? part.toSet() : widget.people.map((p) => p['id']).toSet();
    final parts = (ex?['parts'] as List?)?.cast<Map>() ?? const [];
    for (final p in widget.people) {
      final id = p['id'];
      Map? row;
      for (final r in parts) {
        if (r['member'] == id) {
          row = r;
          break;
        }
      }
      _weights[id] =
          TextEditingController(text: (row?['weight'] ?? '1').toString());
      _exact[id] =
          TextEditingController(text: (row?['amount'] ?? '').toString());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    for (final c in _weights.values) {
      c.dispose();
    }
    for (final c in _exact.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid {
    if (_payer == null) return false;
    if (_mode == _modeEqual) {
      return _SplitMath.toPoisha(_amount.text) > 0 && _participants.isNotEmpty;
    }
    if (_mode == _modeShares) {
      final anyWeight =
          _weights.values.any((c) => (int.tryParse(c.text.trim()) ?? 0) > 0);
      return _SplitMath.toPoisha(_amount.text) > 0 && anyWeight;
    }
    // exact
    return _exact.values
            .fold<int>(0, (a, c) => a + _SplitMath.toPoisha(c.text)) >
        0;
  }

  Map<String, dynamic> _result() {
    final base = <String, dynamic>{
      'title': _title.text.trim(),
      'payer': _payer,
      'mode': _mode,
    };
    if (_mode == _modeEqual) {
      base['amount'] = _amount.text.trim();
      base['participants'] = _participants.toList();
    } else if (_mode == _modeShares) {
      base['amount'] = _amount.text.trim();
      base['parts'] = [
        for (final p in widget.people)
          if ((int.tryParse(_weights[p['id']]!.text.trim()) ?? 0) > 0)
            {
              'member': p['id'],
              'weight': int.parse(_weights[p['id']]!.text.trim())
            }
      ];
    } else {
      base['parts'] = [
        for (final p in widget.people)
          if (_SplitMath.toPoisha(_exact[p['id']]!.text) > 0)
            {'member': p['id'], 'amount': _exact[p['id']]!.text.trim()}
      ];
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  widget.existing == null
                      ? tr.splitAddExpense
                      : tr.splitEditExpense,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.splitExpenseTitle,
                    hintText: tr.splitExpenseTitleHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<dynamic>(
                initialValue: _payer,
                decoration: InputDecoration(
                    labelText: tr.splitPaidBy,
                    border: const OutlineInputBorder()),
                items: [
                  for (final p in widget.people)
                    DropdownMenuItem(
                        value: p['id'],
                        child: Text((p['name'] ?? '').toString())),
                ],
                onChanged: (v) => setState(() => _payer = v),
              ),
              const SizedBox(height: Gap.md),
              Text(tr.splitHowToSplit,
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                ChoiceChip(
                    label: Text(tr.splitModeEqual),
                    selected: _mode == _modeEqual,
                    onSelected: (_) => setState(() => _mode = _modeEqual)),
                ChoiceChip(
                    label: Text(tr.splitModeShares),
                    selected: _mode == _modeShares,
                    onSelected: (_) => setState(() => _mode = _modeShares)),
                ChoiceChip(
                    label: Text(tr.splitModeExact),
                    selected: _mode == _modeExact,
                    onSelected: (_) => setState(() => _mode = _modeExact)),
              ]),
              const SizedBox(height: Gap.md),
              if (_mode != _modeExact)
                TextField(
                  controller: _amount,
                  onChanged: (_) => setState(() {}),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: tr.splitAmount,
                      prefixText: '৳ ',
                      border: const OutlineInputBorder()),
                ),
              if (_mode != _modeExact) const SizedBox(height: Gap.md),
              if (_mode == _modeEqual) _equalPicker(tr),
              if (_mode == _modeShares) _sharesPicker(tr),
              if (_mode == _modeExact) _exactPicker(tr),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _valid ? () => Navigator.pop(context, _result()) : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }

  Widget _equalPicker(AppLocalizations tr) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr.splitSplitBetween, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: Gap.xs),
      for (final p in widget.people)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _participants.contains(p['id']),
          title: Text((p['name'] ?? '').toString()),
          onChanged: (v) => setState(() {
            if (v == true) {
              _participants.add(p['id']);
            } else {
              _participants.remove(p['id']);
            }
          }),
        ),
    ]);
  }

  Widget _sharesPicker(AppLocalizations tr) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr.splitSharesHint,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xs),
      for (final p in widget.people)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(children: [
            Expanded(child: Text((p['name'] ?? '').toString())),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _weights[p['id']],
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                    labelText: tr.splitShareUnits,
                    isDense: true,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
        ),
    ]);
  }

  Widget _exactPicker(AppLocalizations tr) {
    final sum =
        _exact.values.fold<int>(0, (a, c) => a + _SplitMath.toPoisha(c.text));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr.splitExactHint,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xs),
      for (final p in widget.people)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(children: [
            Expanded(child: Text((p['name'] ?? '').toString())),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _exact[p['id']],
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    prefixText: '৳ ',
                    isDense: true,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
        ),
      const SizedBox(height: Gap.xs),
      Text(tr.splitExactTotal(_SplitMath.fmtPoisha(sum)),
          style: Theme.of(context).textTheme.labelLarge),
    ]);
  }
}

// ===================================================================
// _SplitMath — deterministic mirror of backend/core/logic/expense_split.py.
// Integer poisha; largest-remainder split; greedy settle-up. Nets sum to 0.
// ===================================================================
class _SplitPerson {
  final dynamic id;
  final String name;
  final int paid;
  final int share;
  final int net;
  final String state; // is_owed | owes | clear
  _SplitPerson(this.id, this.name, this.paid, this.share, this.net, this.state);
}

class _Settlement {
  final dynamic from;
  final dynamic to;
  final int amount;
  final String fromName;
  final String toName;
  _Settlement(this.from, this.to, this.amount, this.fromName, this.toName);
}

class _SplitGroup {
  final int totalSpent;
  final List<_SplitPerson> rows;
  final List<_Settlement> settlements;
  final bool reconciles;
  _SplitGroup(this.totalSpent, this.rows, this.settlements, this.reconciles);
}

class _SplitMath {
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) v = v.toString();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.sublist(1).join();
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = (frac + '00').substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtPoisha(int p) {
    final neg = p < 0;
    p = p.abs();
    return '${neg ? '-' : ''}৳${_group(p ~/ 100)}.${(p % 100).toString().padLeft(2, '0')}';
  }

  static List<MapEntry<dynamic, int>> _splitEqual(
      int total, List<dynamic> ids) {
    final n = ids.length;
    if (n == 0) return [];
    final sign = total < 0 ? -1 : 1;
    final base = total.abs() ~/ n;
    final rem = total.abs() % n;
    return [
      for (var i = 0; i < n; i++)
        MapEntry(ids[i], sign * (base + (i < rem ? 1 : 0)))
    ];
  }

  static List<MapEntry<dynamic, int>> _splitShares(
      int total, List<MapEntry<dynamic, int>> parts) {
    if (parts.isEmpty) return [];
    final weights = parts.map((p) => p.value < 0 ? 0 : p.value).toList();
    final W = weights.fold<int>(0, (a, b) => a + b);
    if (W == 0) return _splitEqual(total, parts.map((p) => p.key).toList());
    final sign = total < 0 ? -1 : 1;
    final t = total.abs();
    final floors = <int>[];
    final rems = <int>[];
    for (final w in weights) {
      floors.add((t * w) ~/ W);
      rems.add((t * w) % W);
    }
    var leftover = t - floors.fold<int>(0, (a, b) => a + b);
    final order = List<int>.generate(parts.length, (i) => i)
      ..sort((a, b) => rems[a] != rems[b] ? rems[b] - rems[a] : a - b);
    for (var k = 0; k < leftover; k++) {
      floors[order[k]] += 1;
    }
    return [
      for (var i = 0; i < parts.length; i++)
        MapEntry(parts[i].key, sign * floors[i])
    ];
  }

  /// Returns (payer, total, shares) for one expense.
  static ({dynamic payer, int total, List<MapEntry<dynamic, int>> shares})
      _normalise(Map<String, dynamic> e, List<dynamic> groupIds) {
    var mode = (e['mode'] ?? _modeEqual).toString();
    if (mode != _modeEqual && mode != _modeShares && mode != _modeExact) {
      mode = _modeEqual;
    }
    final payer = e['payer'];
    if (mode == _modeExact) {
      final parts = (e['parts'] as List?)?.cast<Map>() ?? const [];
      final shares = [
        for (final p in parts) MapEntry(p['member'], toPoisha(p['amount']))
      ];
      final total = shares.fold<int>(0, (a, s) => a + s.value);
      return (payer: payer, total: total, shares: shares);
    } else if (mode == _modeShares) {
      final total = toPoisha(e['amount']);
      final parts = (e['parts'] as List?)?.cast<Map>() ?? const [];
      final wp = [
        for (final p in parts)
          MapEntry(p['member'], (p['weight'] as num?)?.toInt() ?? 0)
      ];
      return (payer: payer, total: total, shares: _splitShares(total, wp));
    } else {
      final total = toPoisha(e['amount']);
      final part = (e['participants'] as List?)?.toList() ?? groupIds;
      return (payer: payer, total: total, shares: _splitEqual(total, part));
    }
  }

  static int expenseTotal(
      Map<String, dynamic> e, List<Map<String, dynamic>> people) {
    return _normalise(e, people.map((p) => p['id']).toList()).total;
  }

  static _SplitGroup groupSummary(
      List<Map<String, dynamic>> people, List<Map<String, dynamic>> expenses) {
    final ids = people.map((p) => p['id']).toList();
    final nameOf = {
      for (final p in people) p['id']: (p['name'] ?? '').toString()
    };
    final net = <dynamic, int>{for (final id in ids) id: 0};
    final paid = <dynamic, int>{for (final id in ids) id: 0};
    final share = <dynamic, int>{for (final id in ids) id: 0};
    int totalSpent = 0;
    for (final e in expenses) {
      final n = _normalise(e, ids);
      totalSpent += n.total;
      if (n.payer != null) {
        net[n.payer] = (net[n.payer] ?? 0) + n.total;
        paid[n.payer] = (paid[n.payer] ?? 0) + n.total;
      }
      for (final s in n.shares) {
        net[s.key] = (net[s.key] ?? 0) - s.value;
        share[s.key] = (share[s.key] ?? 0) + s.value;
      }
    }

    final rows = <_SplitPerson>[];
    for (final id in ids) {
      final v = net[id] ?? 0;
      final state = v > 0 ? 'is_owed' : (v < 0 ? 'owes' : 'clear');
      rows.add(_SplitPerson(
          id, nameOf[id] ?? '', paid[id] ?? 0, share[id] ?? 0, v, state));
    }

    // greedy settle-up
    final creditors = [
      for (final id in ids)
        if ((net[id] ?? 0) > 0) [id, net[id]!]
    ]..sort((a, b) => (b[1] as int) != (a[1] as int)
        ? (b[1] as int) - (a[1] as int)
        : a[0].toString().compareTo(b[0].toString()));
    final debtors = [
      for (final id in ids)
        if ((net[id] ?? 0) < 0) [id, -(net[id]!)]
    ]..sort((a, b) => (b[1] as int) != (a[1] as int)
        ? (b[1] as int) - (a[1] as int)
        : a[0].toString().compareTo(b[0].toString()));

    final settlements = <_Settlement>[];
    var ci = 0, di = 0;
    while (ci < creditors.length && di < debtors.length) {
      final cm = creditors[ci][0];
      final dm = debtors[di][0];
      final ca = creditors[ci][1] as int;
      final da = debtors[di][1] as int;
      final pay = ca < da ? ca : da;
      if (pay > 0) {
        settlements
            .add(_Settlement(dm, cm, pay, nameOf[dm] ?? '', nameOf[cm] ?? ''));
      }
      creditors[ci][1] = ca - pay;
      debtors[di][1] = da - pay;
      if (creditors[ci][1] == 0) ci++;
      if (debtors[di][1] == 0) di++;
    }

    final reconciles = net.values.fold<int>(0, (a, b) => a + b) == 0;
    return _SplitGroup(totalSpent, rows, settlements, reconciles);
  }
}
