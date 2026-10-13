import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
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
      title: Text(AppLocalizations.of(context).familyScamCheckerTitle),
      content: TextField(controller: ctrl, maxLines: 4,
          decoration: InputDecoration(labelText: AppLocalizations.of(context).familyScamPasteHint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).cancel)),
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
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppLocalizations.of(context).ok))]));
          } catch (_) {}
        }, child: Text(AppLocalizations.of(context).commonVerify)),
      ]));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(length: 4, child: Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).familyCareTitle), actions: [
        IconButton(onPressed: _scamCheck, icon: const Icon(Icons.shield_outlined), tooltip: AppLocalizations.of(context).familyScamCheckTooltip),
        IconButton(onPressed: _load, icon: const Icon(Icons.sync)),
      ], bottom: TabBar(isScrollable: true, tabs: [
        Tab(text: AppLocalizations.of(context).familyTabToday), Tab(text: AppLocalizations.of(context).familyTabMedicines), Tab(text: AppLocalizations.of(context).moduleFamily), Tab(text: AppLocalizations.of(context).familySchoolTitle),
      ])),
      body: loading ? const Center(child: CircularProgressIndicator())
        : TabBarView(children: [_todayTab(), _medsTab(), _membersTab(), _schoolTab()]),
    ));
  }

  Widget _todayTab() {
    if (today.isEmpty) {
      return Center(child: Padding(padding: EdgeInsets.all(24),
        child: Text(AppLocalizations.of(context).familyNoDosesToday,
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
            if (d['refill_date'] != null) AppLocalizations.of(context).familyRefillValue(d['refill_date']),
          ].join('  ·  ')),
        )),
      Padding(padding: EdgeInsets.all(12),
        child: Text(AppLocalizations.of(context).familyCheckToConfirm,
            style: TextStyle(fontSize: 12, color: Colors.grey))),
    ]);
  }

  Future<void> _addMed() async {
    final name = TextEditingController();
    final dose = TextEditingController();
    final times = TextEditingController(text: '08:00, 20:00');
    final refill = TextEditingController();
    // follow-up config (owner's requirement) — per-medicine, with defaults
    final repeat = TextEditingController(text: '15');
    final retries = TextEditingController(text: '2');
    final caregiver = TextEditingController(text: '30');
    final quietStart = TextEditingController();
    final quietEnd = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(AppLocalizations.of(context).familyAddMedicineTitle),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyMedicineNameLabel)),
        TextField(controller: dose, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyDosageLabel)),
        TextField(controller: times, decoration: InputDecoration(
            labelText: AppLocalizations.of(context).familyTimesLabel, hintText: '08:00, 20:00')),
        TextField(controller: refill, decoration: InputDecoration(
            labelText: AppLocalizations.of(context).familyRefillDateLabel)),
        Padding(padding: EdgeInsets.only(top: 12, bottom: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(AppLocalizations.of(context).familyReminderFollowupHeading,
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)))),
        TextField(controller: repeat, keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).familyFollowupRepeatLabel)),
        TextField(controller: retries, keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).familyFollowupRetriesLabel)),
        TextField(controller: caregiver, keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).familyCaregiverAlertLabel)),
        Row(children: [
          Expanded(child: TextField(controller: quietStart,
              decoration: InputDecoration(labelText: AppLocalizations.of(context).familyQuietStartLabel))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: quietEnd,
              decoration: InputDecoration(labelText: AppLocalizations.of(context).familyQuietEndLabel))),
        ]),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).save)),
      ]));
    if (ok == true && name.text.trim().isNotEmpty) {
      final slots = times.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      await context.read<AppState>().api.createItem('medicines', {
        'name': name.text.trim(), 'dosage': dose.text.trim(), 'times': slots,
        if (refill.text.trim().isNotEmpty) 'refill_date': refill.text.trim(),
        'followup_repeat_min': int.tryParse(repeat.text.trim()) ?? 15,
        'followup_retries': int.tryParse(retries.text.trim()) ?? 2,
        'caregiver_alert_min': int.tryParse(caregiver.text.trim()) ?? 30,
        'quiet_start': quietStart.text.trim(),
        'quiet_end': quietEnd.text.trim(),
      });
      _load();
    }
  }

  Widget _medsTab() {
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _addMed, child: const Icon(Icons.add)),
      body: meds.isEmpty
        ? Center(child: Text(AppLocalizations.of(context).familyAddMedicinesEmpty, style: TextStyle(color: Colors.grey)))
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
      title: Text(AppLocalizations.of(context).familyMemberTitle),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: InputDecoration(labelText: AppLocalizations.of(context).name)),
        TextField(controller: rel, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyRelationLabel)),
        TextField(controller: phone, keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).phoneOptional)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).save)),
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
        ? Center(child: Text(AppLocalizations.of(context).familyAddMemberEmpty, style: TextStyle(color: Colors.grey)))
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
        title: Text(AppLocalizations.of(context).familySchoolTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: child, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyChildNameLabel)),
          DropdownButtonFormField<String>(value: kind,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).moneyFieldType),
            items: [DropdownMenuItem(value: 'fee', child: Text(AppLocalizations.of(context).familyKindFee)),
              DropdownMenuItem(value: 'exam', child: Text(AppLocalizations.of(context).familyKindExam)),
              DropdownMenuItem(value: 'meeting', child: Text(AppLocalizations.of(context).familyKindMeeting))],
            onChanged: (v) => setD(() => kind = v ?? 'fee')),
          TextField(controller: title, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyDescriptionLabel)),
          TextField(controller: date, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyDateLabel)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).save)),
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
        ? Center(child: Text(AppLocalizations.of(context).familyAddSchoolEmpty, style: TextStyle(color: Colors.grey)))
        : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
            for (final s in school)
              Card(child: ListTile(
                leading: Icon({
                  'fee': Icons.payments_outlined,
                  'exam': Icons.edit_note_outlined,
                  'meeting': Icons.groups_outlined,
                }[s['kind']] ?? Icons.push_pin_outlined),
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
