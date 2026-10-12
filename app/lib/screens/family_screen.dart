import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';

class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});
  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  List<Map<String, dynamic>> today = [];
  List<Map<String, dynamic>> meds = [];
  List<Map<String, dynamic>> members = [];
  List<Map<String, dynamic>> school = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      today = await api.medicinesToday();
      meds = await api.listItems('medicines');
      members = await api.listItems('family');
      school = await api.listItems('school');
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _scamCheck() async {
    final ctrl = TextEditingController();
    final api = context.read<AppState>().api;
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('🛡️ স্ক্যাম চেকার'),
      content: TextField(controller: ctrl, maxLines: 4,
          decoration: const InputDecoration(labelText: 'সন্দেহজনক মেসেজ পেস্ট করুন')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
        FilledButton(onPressed: () async {
          if (ctrl.text.trim().isEmpty) return;
          try {
            final r = await api.scamCheck(ctrl.text.trim());
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            showDialog(context: context, builder: (_) => AlertDialog(
              title: Text('${r['emoji']} ${r['label']}'),
              content: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final reason in (r['reasons'] as List)) Text('• $reason'),
                  const SizedBox(height: 8),
                  Text(r['advice'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে'))]));
          } catch (_) {}
        }, child: const Text('যাচাই')),
      ]));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(length: 4, child: Scaffold(
      appBar: AppBar(title: const Text('ফ্যামিলি কেয়ার'), actions: [
        IconButton(onPressed: _scamCheck, icon: const Icon(Icons.shield_outlined), tooltip: 'স্ক্যাম চেক'),
        IconButton(onPressed: _load, icon: const Icon(Icons.sync)),
      ], bottom: const TabBar(isScrollable: true, tabs: [
        Tab(text: 'আজকের ওষুধ'), Tab(text: 'ওষুধ'), Tab(text: 'পরিবার'), Tab(text: 'স্কুল'),
      ])),
      body: loading ? const Center(child: CircularProgressIndicator())
        : TabBarView(children: [_todayTab(), _medsTab(), _membersTab(), _schoolTab()]),
    ));
  }

  Widget _todayTab() {
    if (today.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(24),
        child: Text('আজ কোনো ওষুধের সময় নেই।\nওষুধ ট্যাবে যোগ করুন।',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))));
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final d in today)
        Card(child: CheckboxListTile(
          value: d['taken'] == true,
          onChanged: (v) async {
            await context.read<AppState>().api.medicineTaken(
                d['medicine_id'], d['slot'], taken: v ?? false);
            _load();
          },
          title: Text('${d['name']} · ${d['slot']}'),
          subtitle: Text([
            if ((d['dosage'] ?? '').toString().isNotEmpty) d['dosage'],
            if (d['refill_date'] != null) '🔄 রিফিল: ${d['refill_date']}',
          ].join('  ')),
        )),
      const Padding(padding: EdgeInsets.all(12),
        child: Text('✅ "খেয়েছি" চাপলে কনফার্ম হবে। মিস হলে পরিবারকে জানানোর সুবিধা পরে আসছে।',
            style: TextStyle(fontSize: 12, color: Colors.grey))),
    ]);
  }

  Future<void> _addMed() async {
    final name = TextEditingController();
    final dose = TextEditingController();
    final times = TextEditingController(text: '08:00, 20:00');
    final refill = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('ওষুধ যোগ'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'ওষুধের নাম *')),
        TextField(controller: dose, decoration: const InputDecoration(labelText: 'ডোজ (যেমন ১টা)')),
        TextField(controller: times, decoration: const InputDecoration(
            labelText: 'সময় (HH:MM, কমা দিয়ে)', hintText: '08:00, 20:00')),
        TextField(controller: refill, decoration: const InputDecoration(
            labelText: 'রিফিল তারিখ (YYYY-MM-DD, ঐচ্ছিক)')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
      ]));
    if (ok == true && name.text.trim().isNotEmpty) {
      final slots = times.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      await context.read<AppState>().api.createItem('medicines', {
        'name': name.text.trim(), 'dosage': dose.text.trim(), 'times': slots,
        if (refill.text.trim().isNotEmpty) 'refill_date': refill.text.trim(),
      });
      _load();
    }
  }

  Widget _medsTab() {
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _addMed, child: const Icon(Icons.add)),
      body: meds.isEmpty
        ? const Center(child: Text('ওষুধ যোগ করুন।', style: TextStyle(color: Colors.grey)))
        : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
            for (final m in meds)
              Card(child: ListTile(
                leading: const Icon(Icons.medication_outlined),
                title: Text(m['name'] ?? ''),
                subtitle: Text([(m['dosage'] ?? ''), ((m['times'] ?? []) as List).join(', ')]
                    .where((e) => e.toString().isNotEmpty).join(' · ')),
                trailing: IconButton(icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await context.read<AppState>().api.deleteItem('medicines', m['id']); _load();
                    }),
              )),
          ]),
    );
  }

  Future<void> _addMember() async {
    final name = TextEditingController();
    final rel = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('পরিবারের সদস্য'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'নাম')),
        TextField(controller: rel, decoration: const InputDecoration(labelText: 'সম্পর্ক')),
        TextField(controller: phone, keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'ফোন (ঐচ্ছিক)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
      ]));
    if (ok == true && name.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('family', {
        'name': name.text.trim(), 'relation': rel.text.trim(), 'phone': phone.text.trim()});
      _load();
    }
  }

  Widget _membersTab() {
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _addMember, child: const Icon(Icons.add)),
      body: members.isEmpty
        ? const Center(child: Text('পরিবারের সদস্য যোগ করুন।', style: TextStyle(color: Colors.grey)))
        : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
            for (final m in members)
              Card(child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(m['name'] ?? ''),
                subtitle: Text([(m['relation'] ?? ''), (m['phone'] ?? '')]
                    .where((e) => e.toString().isNotEmpty).join(' · ')),
                trailing: IconButton(icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await context.read<AppState>().api.deleteItem('family', m['id']); _load();
                    }),
              )),
          ]),
    );
  }

  Future<void> _addSchool() async {
    final child = TextEditingController();
    final title = TextEditingController();
    final date = TextEditingController();
    String kind = 'fee';
    final ok = await showDialog<bool>(context: context, builder: (ctx) =>
      StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('স্কুল'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: child, decoration: const InputDecoration(labelText: 'বাচ্চার নাম')),
          DropdownButtonFormField<String>(value: kind,
            decoration: const InputDecoration(labelText: 'ধরন'),
            items: const [DropdownMenuItem(value: 'fee', child: Text('ফি')),
              DropdownMenuItem(value: 'exam', child: Text('পরীক্ষা')),
              DropdownMenuItem(value: 'meeting', child: Text('মিটিং'))],
            onChanged: (v) => setD(() => kind = v ?? 'fee')),
          TextField(controller: title, decoration: const InputDecoration(labelText: 'বিবরণ')),
          TextField(controller: date, decoration: const InputDecoration(labelText: 'তারিখ (YYYY-MM-DD)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ])));
    if (ok == true && title.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('school', {
        'child_name': child.text.trim(), 'kind': kind, 'title': title.text.trim(),
        if (date.text.trim().isNotEmpty) 'date': date.text.trim()});
      _load();
    }
  }

  Widget _schoolTab() {
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _addSchool, child: const Icon(Icons.add)),
      body: school.isEmpty
        ? const Center(child: Text('ফি, পরীক্ষা, মিটিং যোগ করুন।', style: TextStyle(color: Colors.grey)))
        : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
            for (final s in school)
              Card(child: ListTile(
                leading: Text({'fee': '💵', 'exam': '📝', 'meeting': '👥'}[s['kind']] ?? '📌',
                    style: const TextStyle(fontSize: 22)),
                title: Text(s['title'] ?? ''),
                subtitle: Text([(s['child_name'] ?? ''), (s['date'] ?? '')]
                    .where((e) => e.toString().isNotEmpty).join(' · ')),
                trailing: IconButton(icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await context.read<AppState>().api.deleteItem('school', s['id']); _load();
                    }),
              )),
          ]),
    );
  }
}
