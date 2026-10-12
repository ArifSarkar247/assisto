import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../theme.dart';
import '../sync_repo.dart';

final _tk = NumberFormat('#,##,###.##', 'en');
String _tkFmt(dynamic v) {
  final d = double.tryParse('${v ?? 0}') ?? 0;
  return '৳${_tk.format(d)}';
}

const _accTypes = {
  'cash': 'ক্যাশ', 'bkash': 'বিকাশ', 'nagad': 'নগদ', 'rocket': 'রকেট',
  'bank': 'ব্যাংক', 'card': 'কার্ড',
};

class MoneyScreen extends StatefulWidget {
  const MoneyScreen({super.key});
  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  Map<String, dynamic>? _summary;

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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('জীবনের হিসাব'),
          actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.sync))],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'সারাংশ'), Tab(text: 'অ্যাকাউন্ট'), Tab(text: 'লেনদেন'),
            Tab(text: 'বাজেট'), Tab(text: 'ধার/সঞ্চয়'),
          ]),
        ),
        body: TabBarView(children: [
          _SummaryTab(summary: _summary),
          const _AccountsTab(),
          _TxnsTab(onChange: _refresh),
          _BudgetsTab(summary: _summary),
          const _LoansSavingsTab(),
        ]),
      ),
    );
  }
}

// ---------------- summary ----------------
class _SummaryTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  const _SummaryTab({this.summary});
  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (s == null) {
      return const Center(child: Text('অনলাইনে এলে সারাংশ দেখাবে।',
          style: TextStyle(color: Colors.grey)));
    }
    final cats = (s['expense_by_category'] as Map).cast<String, dynamic>();
    final maxVal = cats.values.fold<double>(0,
        (p, v) => (double.tryParse('$v') ?? 0) > p ? (double.tryParse('$v') ?? 0) : p);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('মোট ব্যালেন্স', style: TextStyle(color: Colors.white70)),
            Text(_tkFmt(s['total_balance']),
                style: const TextStyle(
                    color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
          ]),
        )),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _stat('এ মাসে আয়', _tkFmt(s['month_income']), Colors.green)),
        const SizedBox(width: 8),
        Expanded(child: _stat('এ মাসে খরচ', _tkFmt(s['month_expense']), Colors.red)),
      ]),
      const SizedBox(height: 8),
      _stat('এ মাসে বাকি (নিট)', _tkFmt(s['month_net']),
          (double.tryParse('${s['month_net']}') ?? 0) >= 0 ? Colors.teal : Colors.red),
      const SizedBox(height: 16),
      if (cats.isNotEmpty) ...[
        const Text('খরচের ভাগ (এ মাসে)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final e in cats.entries)
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(e.key), Text(_tkFmt(e.value)),
              ]),
              const SizedBox(height: 2),
              LinearProgressIndicator(
                value: maxVal > 0 ? (double.tryParse('${e.value}') ?? 0) / maxVal : 0,
                minHeight: 7),
            ])),
      ],
    ]);
  }

  Widget _stat(String label, String val, Color c) => Card(child: Padding(
    padding: const EdgeInsets.all(14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      Text(val, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: c)),
    ])));
}

// ---------------- accounts ----------------
class _AccountsTab extends StatelessWidget {
  const _AccountsTab();

  Future<void> _add(BuildContext context) async {
    final app = context.read<AppState>();
    final name = TextEditingController();
    final bal = TextEditingController(text: '0');
    String type = 'cash';
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('নতুন অ্যাকাউন্ট'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'নাম')),
          DropdownButtonFormField<String>(value: type,
            decoration: const InputDecoration(labelText: 'ধরন'),
            items: _accTypes.entries.map((e) =>
                DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) => setD(() => type = v ?? 'cash')),
          TextField(controller: bal, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'শুরুর ব্যালেন্স')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ])));
    if (ok == true && name.text.trim().isNotEmpty) {
      await app.accounts.add({'name': name.text.trim(), 'acc_type': type,
        'opening_balance': bal.text.trim().isEmpty ? '0' : bal.text.trim()});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final items = app.accounts.items;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? const Center(child: Text('অ্যাকাউন্ট যোগ করুন (ক্যাশ, বিকাশ, নগদ, ব্যাংক...)',
              style: TextStyle(color: Colors.grey)))
          : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
              for (final it in items)
                Card(child: ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: Text(it['data']['name'] ?? ''),
                  subtitle: Text(_accTypes[it['data']['acc_type']] ?? ''),
                  trailing: Text('শুরু: ${_tkFmt(it['data']['opening_balance'])}',
                      style: const TextStyle(fontSize: 12)),
                  onLongPress: () => app.accounts.remove(it),
                )),
            ]),
    );
  }
}

// ---------------- transactions ----------------
class _TxnsTab extends StatelessWidget {
  final VoidCallback onChange;
  const _TxnsTab({required this.onChange});

  Future<void> _add(BuildContext context) async {
    final app = context.read<AppState>();
    final accs = app.accounts.items.where((a) => a['serverId'] != null).toList();
    if (accs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('আগে একটি অ্যাকাউন্ট যোগ করুন (অনলাইনে)।')));
      return;
    }
    final amount = TextEditingController();
    final cat = TextEditingController();
    final note = TextEditingController();
    String kind = 'expense';
    int accId = accs.first['serverId'];
    DateTime date = DateTime.now();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('নতুন লেনদেন'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<String>(segments: const [
            ButtonSegment(value: 'expense', label: Text('খরচ')),
            ButtonSegment(value: 'income', label: Text('আয়')),
          ], selected: {kind}, onSelectionChanged: (s) => setD(() => kind = s.first)),
          const SizedBox(height: 8),
          TextField(controller: amount, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'পরিমাণ *')),
          DropdownButtonFormField<int>(value: accId,
            decoration: const InputDecoration(labelText: 'অ্যাকাউন্ট'),
            items: accs.map((a) => DropdownMenuItem<int>(
                value: a['serverId'], child: Text(a['data']['name'] ?? ''))).toList(),
            onChanged: (v) => setD(() => accId = v ?? accId)),
          TextField(controller: cat, decoration: const InputDecoration(labelText: 'খাত (খাবার, যাতায়াত...)')),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'নোট (ঐচ্ছিক)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ])));
    if (ok == true && (double.tryParse(amount.text.trim()) ?? 0) > 0) {
      await app.txns.add({'account': accId, 'kind': kind, 'amount': amount.text.trim(),
        'category': cat.text.trim(), 'note': note.text.trim(),
        'date': DateFormat('yyyy-MM-dd').format(date)});
      onChange();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final items = app.txns.items;
    final fmt = DateFormat('d MMM');
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(context), icon: const Icon(Icons.add),
          label: const Text('লেনদেন')),
      body: items.isEmpty
          ? const Center(child: Text('কোনো লেনদেন নেই।', style: TextStyle(color: Colors.grey)))
          : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
              for (final it in items)
                Card(child: ListTile(
                  leading: Icon(it['data']['kind'] == 'income'
                      ? Icons.arrow_downward : Icons.arrow_upward,
                      color: it['data']['kind'] == 'income' ? Colors.green : Colors.red),
                  title: Text(it['data']['category']?.toString().isNotEmpty == true
                      ? it['data']['category'] : (it['data']['note'] ?? 'লেনদেন')),
                  subtitle: Text(it['data']['date'] != null
                      ? fmt.format(DateTime.tryParse(it['data']['date']) ?? DateTime.now()) : ''),
                  trailing: Text(
                      '${it['data']['kind'] == 'income' ? '+' : '-'}${_tkFmt(it['data']['amount'])}',
                      style: TextStyle(fontWeight: FontWeight.bold,
                          color: it['data']['kind'] == 'income' ? Colors.green : Colors.red)),
                  onLongPress: () { app.txns.remove(it); onChange(); },
                )),
            ]),
    );
  }
}

// ---------------- budgets ----------------
class _BudgetsTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  const _BudgetsTab({this.summary});

  Future<void> _add(BuildContext context) async {
    final app = context.read<AppState>();
    final cat = TextEditingController();
    final lim = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('নতুন বাজেট'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: cat, decoration: const InputDecoration(labelText: 'খাত')),
          TextField(controller: lim, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'মাসিক সীমা')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ]));
    if (ok == true && cat.text.trim().isNotEmpty) {
      await app.budgets.add({'category': cat.text.trim(), 'monthly_limit': lim.text.trim()});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final budgets = (summary?['budgets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: budgets.isEmpty
          ? Center(child: Text(app.budgets.items.isEmpty
              ? 'বাজেট যোগ করুন (৮০% ও ১০০%-এ সতর্ক করব)।'
              : 'অনলাইনে এলে খরচ দেখাবে।', style: const TextStyle(color: Colors.grey)))
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final b in budgets)
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(b['category'], style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('${_tkFmt(b['spent'])} / ${_tkFmt(b['limit'])}'),
                    ]),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: (b['pct'] as int).clamp(0, 100) / 100,
                      minHeight: 8,
                      color: b['warn'] == 'over' ? Colors.red
                          : b['warn'] == 'near' ? Colors.orange : Colors.green),
                    if (b['warn'] == 'over')
                      const Padding(padding: EdgeInsets.only(top: 4),
                        child: Text('বাজেট শেষ!', style: TextStyle(color: Colors.red, fontSize: 12)))
                    else if (b['warn'] == 'near')
                      const Padding(padding: EdgeInsets.only(top: 4),
                        child: Text('৮০% পার', style: TextStyle(color: Colors.orange, fontSize: 12))),
                  ]))),
            ]),
    );
  }
}

// ---------------- loans + savings ----------------
class _LoansSavingsTab extends StatelessWidget {
  const _LoansSavingsTab();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('ধার', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(onPressed: () => _addLoan(context),
            icon: const Icon(Icons.add), label: const Text('যোগ')),
      ]),
      if (app.loans.items.isEmpty)
        const Padding(padding: EdgeInsets.all(8),
          child: Text('কাকে দিয়েছেন / কার কাছে নিয়েছেন — এখানে রাখুন।',
              style: TextStyle(color: Colors.grey))),
      for (final it in app.loans.items)
        Card(child: ListTile(
          leading: Icon(it['data']['kind'] == 'given' ? Icons.call_made : Icons.call_received,
              color: it['data']['kind'] == 'given' ? Colors.orange : Colors.blue),
          title: Text('${it['data']['person']} · ${_tkFmt(it['data']['amount'])}'),
          subtitle: Text(it['data']['kind'] == 'given' ? 'আমি দিয়েছি' : 'আমি নিয়েছি'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (it['data']['settled'] != true)
              TextButton(onPressed: () => _reminderDraft(context, it['data']),
                  child: const Text('রিমাইন্ডার')),
            Checkbox(value: it['data']['settled'] == true,
                onChanged: (v) => app.loans.update(it, {'settled': v ?? false})),
          ]),
        )),
      const Divider(height: 28),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('সঞ্চয় লক্ষ্য', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(onPressed: () => _addGoal(context),
            icon: const Icon(Icons.add), label: const Text('যোগ')),
      ]),
      for (final it in app.goals.items)
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(it['data']['title'] ?? ''),
              Text('${_tkFmt(it['data']['saved_amount'])} / ${_tkFmt(it['data']['target_amount'])}'),
            ]),
            const SizedBox(height: 6),
            LinearProgressIndicator(minHeight: 8,
              value: (double.tryParse('${it['data']['target_amount']}') ?? 1) > 0
                  ? ((double.tryParse('${it['data']['saved_amount']}') ?? 0) /
                      (double.tryParse('${it['data']['target_amount']}') ?? 1)).clamp(0, 1)
                  : 0),
            Align(alignment: Alignment.centerRight, child: TextButton(
              onPressed: () => _addToGoal(context, it), child: const Text('জমা যোগ'))),
          ]))),
    ]);
  }

  Future<void> _addLoan(BuildContext context) async {
    final app = context.read<AppState>();
    final person = TextEditingController();
    final amount = TextEditingController();
    String kind = 'given';
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('নতুন ধার'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<String>(segments: const [
            ButtonSegment(value: 'given', label: Text('দিয়েছি')),
            ButtonSegment(value: 'taken', label: Text('নিয়েছি')),
          ], selected: {kind}, onSelectionChanged: (s) => setD(() => kind = s.first)),
          TextField(controller: person, decoration: const InputDecoration(labelText: 'কার নাম')),
          TextField(controller: amount, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'পরিমাণ')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ])));
    if (ok == true && person.text.trim().isNotEmpty) {
      await app.loans.add({'kind': kind, 'person': person.text.trim(),
        'amount': amount.text.trim(), 'settled': false});
    }
  }

  void _reminderDraft(BuildContext context, Map data) {
    final msg = data['kind'] == 'given'
        ? 'আসসালামু আলাইকুম ${data['person']} ভাই, একটু ব্যস্ততায় মনে করিয়ে দিচ্ছি — '
            '${_tkFmt(data['amount'])} টাকা সুবিধামতো ফেরত দিলে উপকার হতো। ধন্যবাদ।'
        : '${data['person']} এর কাছে আমার ${_tkFmt(data['amount'])} টাকা ধার আছে — ফেরত দিতে হবে।';
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('রিমাইন্ডার খসড়া'),
      content: SelectableText(msg),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে'))]));
  }

  Future<void> _addGoal(BuildContext context) async {
    final app = context.read<AppState>();
    final title = TextEditingController();
    final target = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('সঞ্চয় লক্ষ্য'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'কীসের জন্য')),
          TextField(controller: target, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'লক্ষ্য (টাকা)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ]));
    if (ok == true && title.text.trim().isNotEmpty) {
      await app.goals.add({'title': title.text.trim(),
        'target_amount': target.text.trim(), 'saved_amount': '0'});
    }
  }

  Future<void> _addToGoal(BuildContext context, Map<String, dynamic> it) async {
    final app = context.read<AppState>();
    final add = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('জমা যোগ'),
        content: TextField(controller: add, keyboardType: TextInputType.number, autofocus: true,
            decoration: const InputDecoration(labelText: 'কত জমা করলেন')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('যোগ')),
        ]));
    if (ok == true) {
      final cur = double.tryParse('${it['data']['saved_amount']}') ?? 0;
      final plus = double.tryParse(add.text.trim()) ?? 0;
      await app.goals.update(it, {'saved_amount': (cur + plus).toString()});
    }
  }
}
