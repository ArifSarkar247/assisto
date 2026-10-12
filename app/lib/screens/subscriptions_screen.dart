import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  List<Map<String, dynamic>> _subs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _subs = await context.read<AppState>().api.listItems('subscriptions');
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  double get _monthly {
    var total = 0.0;
    for (final s in _subs) {
      final amt = double.tryParse('${s['amount']}') ?? 0;
      total += (s['cycle'] == 'yearly') ? amt / 12 : amt;
    }
    return total;
  }

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    final name = TextEditingController();
    final amount = TextEditingController();
    String cycle = 'monthly';
    DateTime? due;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t.addSubscription),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name,
                  decoration: InputDecoration(labelText: t.name)),
              const SizedBox(height: 10),
              TextField(controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t.amount)),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'monthly', label: Text(t.cycleMonthly)),
                  ButtonSegment(value: 'yearly', label: Text(t.cycleYearly)),
                ],
                selected: {cycle},
                onSelectionChanged: (s) => setD(() => cycle = s.first),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.event, size: 18),
                label: Text(due == null
                    ? t.nextDue
                    : DateFormat('d MMM yyyy').format(due!)),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100));
                  if (d != null) setD(() => due = d);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok == true &&
        name.text.trim().isNotEmpty &&
        (double.tryParse(amount.text.trim()) ?? 0) > 0) {
      await context.read<AppState>().api.createItem('subscriptions', {
        'name': name.text.trim(),
        'amount': amount.text.trim(),
        'cycle': cycle,
        if (due != null) 'next_due': DateFormat('yyyy-MM-dd').format(due!),
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final money = NumberFormat.currency(symbol: '৳', decimalDigits: 0);
    return Scaffold(
      appBar: AppBar(title: Text(t.subscriptions)),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: Text(t.addSubscription)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _subs.isEmpty
              ? Center(
                  child: Padding(
                  padding: const EdgeInsets.all(Gap.xxl),
                  child: Text(t.subscriptionsEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
                  children: [
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Row(children: [
                          const Icon(Icons.autorenew),
                          const SizedBox(width: Gap.md),
                          Text(t.monthlyTotal(money.format(_monthly)),
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: Gap.sm),
                    for (final s in _subs)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.subscriptions_outlined),
                          title: Text(s['name'] ?? ''),
                          subtitle: Text([
                            money.format(double.tryParse('${s['amount']}') ?? 0),
                            s['cycle'] == 'yearly' ? t.cycleYearly : t.cycleMonthly,
                            if (s['next_due'] != null) '${t.nextDue}: ${s['next_due']}',
                          ].join('  ·  ')),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await context
                                  .read<AppState>()
                                  .api
                                  .deleteItem('subscriptions', s['id']);
                              _load();
                            },
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
