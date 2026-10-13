import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';

/// Finance tools (feature 26): net worth, zakat, EMI, investment projection.
/// Pure compute on the backend — never invents numbers (gold price etc. are
/// user inputs).
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});
  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String t(String bn, String e) => en ? e : bn;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('ফিন্যান্স টুল', 'Finance tools')),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t('নেট ওয়ার্থ', 'Net worth')),
            Tab(text: t('যাকাত', 'Zakat')),
            Tab(text: 'EMI'),
            Tab(text: t('বিনিয়োগ', 'Invest')),
          ]),
        ),
        body: TabBarView(children: [
          _NetWorthTab(t: t),
          _CalcTab(tool: 'zakat', t: t, fields: const [
            ('cash', 'নগদ / Cash'), ('gold_value', 'স্বর্ণের দাম / Gold value'),
            ('silver_value', 'রূপার দাম / Silver value'),
            ('investments', 'বিনিয়োগ / Investments'),
            ('debts', 'ঋণ / Debts'), ('nisab', 'নিসাব / Nisab')
          ], resultKeys: const [('zakatable', 'জাকাতযোগ্য / Zakatable'), ('zakat_due', 'যাকাত / Zakat due')]),
          _CalcTab(tool: 'emi', t: t, fields: const [
            ('principal', 'মূল / Principal'), ('rate', 'সুদ %/yr'), ('months', 'মাস / Months')
          ], resultKeys: const [('emi', 'মাসিক EMI'), ('total', 'মোট / Total'), ('interest', 'সুদ / Interest')]),
          _CalcTab(tool: 'invest', t: t, fields: const [
            ('principal', 'মূল / Principal'), ('rate', 'রিটার্ন %/yr'),
            ('years', 'বছর / Years'), ('monthly_add', 'মাসিক যোগ / Monthly add')
          ], resultKeys: const [('future_value', 'ভবিষ্যৎ মূল্য (আনুমানিক) / Future value (est.)')]),
        ]),
      ),
    );
  }
}

class _NetWorthTab extends StatefulWidget {
  final String Function(String, String) t;
  const _NetWorthTab({required this.t});
  @override
  State<_NetWorthTab> createState() => _NetWorthTabState();
}

class _NetWorthTabState extends State<_NetWorthTab> {
  Map<String, dynamic>? _r;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _r = await context.read<AppState>().api.finance('net_worth', {});
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    if (_loading) return const Center(child: CircularProgressIndicator());
    final r = _r ?? {};
    Widget row(String label, String? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(label), Text('৳${v ?? 0}',
                style: const TextStyle(fontWeight: FontWeight.w700))]));
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Card(child: Padding(padding: const EdgeInsets.all(Gap.lg), child: Column(children: [
        row(t('সম্পদ', 'Assets'), r['assets']?.toString()),
        row(t('পাওনা', 'Receivable'), r['receivable']?.toString()),
        row(t('দায়', 'Liabilities'), r['liabilities']?.toString()),
        const Divider(),
        row(t('নেট ওয়ার্থ', 'Net worth'), r['net_worth']?.toString()),
      ]))),
    ]);
  }
}

class _CalcTab extends StatefulWidget {
  final String tool;
  final String Function(String, String) t;
  final List<(String, String)> fields;
  final List<(String, String)> resultKeys;
  const _CalcTab({required this.tool, required this.t, required this.fields,
      required this.resultKeys});
  @override
  State<_CalcTab> createState() => _CalcTabState();
}

class _CalcTabState extends State<_CalcTab> {
  final _ctrls = <String, TextEditingController>{};
  Map<String, dynamic>? _r;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      _ctrls[f.$1] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _calc() async {
    setState(() => _busy = true);
    final args = {for (final f in widget.fields) f.$1: _ctrls[f.$1]!.text.trim()};
    try {
      _r = await context.read<AppState>().api.finance(widget.tool, args);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      for (final f in widget.fields)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: TextField(
            controller: _ctrls[f.$1],
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: f.$2),
          ),
        ),
      FilledButton(
        onPressed: _busy ? null : _calc,
        child: Text(widget.t('হিসাব করুন', 'Calculate')),
      ),
      if (_r != null) ...[
        const SizedBox(height: Gap.lg),
        Card(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(children: [
              for (final rk in widget.resultKeys)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: Text(rk.$2)),
                        Text('৳${_r![rk.$1] ?? 0}',
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                ),
            ]),
          ),
        ),
      ],
    ]);
  }
}
