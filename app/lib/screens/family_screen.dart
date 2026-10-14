import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/famacct_section.dart';
import 'medicine_history_screen.dart';

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
  List<Map<String, dynamic>> doctors = [];
  List<Map<String, dynamic>> prescriptions = [];
  Map<String, dynamic>? caregiver;
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
      doctors = await api.listItems('doctors');
      prescriptions = await api.listItems('prescriptions');
      caregiver = await api.caregiverDashboard();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  AppLocalizations get _t => AppLocalizations.of(context);

  String _foodLabel(String? rel) {
    switch (rel) {
      case 'before':
        return _t.medFoodBefore;
      case 'after':
        return _t.medFoodAfter;
      case 'with':
        return _t.medFoodWith;
      default:
        return '';
    }
  }

  Future<void> _scamCheck() async {
    final ctrl = TextEditingController();
    final api = context.read<AppState>().api;
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(_t.familyScamCheckerTitle),
              content: TextField(
                  controller: ctrl,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: _t.familyScamPasteHint)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
                FilledButton(
                    onPressed: () async {
                      if (ctrl.text.trim().isEmpty) return;
                      try {
                        final r = await api.scamCheck(ctrl.text.trim());
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                                    title: Text('${r['emoji']} ${r['label']}'),
                                    content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          for (final reason in (r['reasons'] as List))
                                            Text('• $reason'),
                                          const SizedBox(height: Gap.sm),
                                          Text(r['advice'] ?? '',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600)),
                                        ]),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: Text(_t.ok))
                                    ]));
                      } catch (_) {}
                    },
                    child: Text(_t.commonVerify)),
              ],
            ));
  }

  Future<void> _downloadDoctorPdf() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await app.api.getBytes('/medicines/doctor-pdf');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-doctor-visit.pdf');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_t.exportFailed(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return DefaultTabController(
        length: 7,
        child: Scaffold(
          appBar: AppBar(title: Text(t.familyCareTitle), actions: [
            IconButton(
                onPressed: _scamCheck,
                icon: const Icon(Icons.shield_outlined),
                tooltip: t.familyScamCheckTooltip),
            IconButton(onPressed: _load, icon: const Icon(Icons.sync)),
          ], bottom: TabBar(isScrollable: true, tabs: [
            Tab(child: Text(t.familyTabToday, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.familyTabMedicines, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.medTabCaregiver, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.medTabPrescriptions, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.moduleFamily, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            // ---- FAMILY ACCOUNTING (#61, SPEC v2.1 §21) — isolated section ----
            Tab(child: Text(AppLocalizations.of(context).faTitle, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.familySchoolTitle, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ])),
          body: loading
              ? const SkeletonList()
              : TabBarView(children: [
                  _todayTab(),
                  _medsTab(),
                  _caregiverTab(),
                  _prescriptionsTab(),
                  _membersTab(),
                  // FAMILY ACCOUNTING — reuses the family/circle contacts
                  // already loaded (`members`); fully self-contained widget.
                  FamAcctSection(members: members),
                  _schoolTab(),
                ]),
        ));
  }

  // ---------------- TODAY ----------------
  Widget _todayTab() {
    final t = _t;
    if (today.isEmpty) {
      return StateMessage(
        icon: Icons.medication_liquid_outlined,
        title: t.familyNoDosesToday,
      );
    }
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      for (final d in today) _doseCard(d),
      Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.familyCheckToConfirm,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))),
    ]);
  }

  Widget _doseCard(Map<String, dynamic> d) {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final taken = d['taken'] == true;
    final skipped = d['skipped'] == true;
    final prn = d['prn'] == true;
    // A PRN 'log another' row is the one still untaken (slot == 'prn').
    final prnLogAnother = prn && d['slot'] == 'prn';
    final prnAt = (d['prn_at'] ?? '').toString();
    final api = context.read<AppState>().api;
    final subtitle = <String>[
      if ((d['dosage'] ?? '').toString().isNotEmpty) d['dosage'].toString(),
      if (_foodLabel(d['food_relation']).isNotEmpty) _foodLabel(d['food_relation']),
      if (d['member_name'] != null) '${_t.medForWhomLabel}: ${d['member_name']}',
      if (d['days_left'] != null) t.medDaysLeftValue(d['days_left']),
    ].join('  ·  ');
    // PRN label: logged event shows its time; the open row says 'log as-needed'.
    final doseLabel = prn
        ? (prnLogAnother
            ? t.medLogAsNeeded
            : (prnAt.isNotEmpty ? '${t.medAsNeededShort} · $prnAt' : t.medAsNeededShort))
        : d['slot'].toString();

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: taken
              ? Brand.success.withValues(alpha: 0.15)
              : scheme.surfaceContainerHighest,
          child: Icon(
              taken
                  ? Icons.check
                  : skipped
                      ? Icons.remove
                      : Icons.medication_outlined,
              color: taken ? Brand.success : scheme.onSurfaceVariant),
        ),
        title: Row(children: [
          Expanded(child: Text('${d['name']} · $doseLabel')),
        ]),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: taken
            ? TextButton(
                onPressed: () async {
                  await api.medicineTaken(d['medicine_id'], d['slot'], taken: false);
                  _load();
                },
                child: Text(t.medUndo))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                // PRN 'log another' row: just a logging action (no skip — PRN
                // doses are not scheduled, so there's nothing to skip).
                if (!prnLogAnother)
                  TextButton(
                      onPressed: () async {
                        await api.medicineTaken(d['medicine_id'], d['slot'], skipped: true);
                        _load();
                      },
                      child: Text(t.medSkip)),
                FilledButton(
                    onPressed: () async {
                      await api.medicineTaken(d['medicine_id'], d['slot'], taken: true);
                      _load();
                    },
                    child: Text(prnLogAnother ? t.medLogAsNeeded : t.medTakeNow)),
              ]),
      ),
    );
  }

  // ---------------- MEDICINES ----------------
  Future<void> _addMed({Map<String, dynamic>? existing}) async {
    final editing = existing != null;
    final name = TextEditingController(text: existing?['name']?.toString() ?? '');
    final dose = TextEditingController(text: existing?['dosage']?.toString() ?? '');
    final times = TextEditingController(
        text: ((existing?['times'] as List?)?.join(', ')) ?? '08:00, 20:00');
    final qty = TextEditingController(
        text: existing?['dose_qty']?.toString() ?? '1');
    final stock = TextEditingController(
        text: existing?['stock_count']?.toString() ?? '');
    final duration = TextEditingController(
        text: existing?['duration_days']?.toString() ?? '');
    final refill = TextEditingController(
        text: existing?['refill_date']?.toString() ?? '');
    final repeat = TextEditingController(
        text: existing?['followup_repeat_min']?.toString() ?? '15');
    final retries = TextEditingController(
        text: existing?['followup_retries']?.toString() ?? '2');
    final caregiverMin = TextEditingController(
        text: existing?['caregiver_alert_min']?.toString() ?? '30');
    final quietStart = TextEditingController(
        text: existing?['quiet_start']?.toString() ?? '');
    final quietEnd = TextEditingController(
        text: existing?['quiet_end']?.toString() ?? '');
    String food = existing?['food_relation']?.toString() ?? 'any';
    bool prn = existing?['as_needed'] == true;
    int? memberId = existing?['member'] as int?;
    final t = _t;

    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(editing ? t.medEditMedicineTitle : t.familyAddMedicineTitle),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: name,
                        decoration: InputDecoration(labelText: t.familyMedicineNameLabel)),
                    TextField(
                        controller: dose,
                        decoration: InputDecoration(labelText: t.familyDosageLabel)),
                    DropdownButtonFormField<int?>(
                        initialValue: memberId,
                        decoration: InputDecoration(labelText: t.medForWhomLabel),
                        items: [
                          DropdownMenuItem(value: null, child: Text(t.medForSelf)),
                          for (final m in members)
                            DropdownMenuItem(
                                value: m['id'] as int, child: Text(m['name'] ?? '')),
                        ],
                        onChanged: (v) => setD(() => memberId = v)),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: prn,
                        title: Text(t.medAsNeeded),
                        onChanged: (v) => setD(() => prn = v)),
                    if (!prn)
                      TextField(
                          controller: times,
                          decoration: InputDecoration(
                              labelText: t.familyTimesLabel, hintText: '08:00, 20:00')),
                    DropdownButtonFormField<String>(
                        initialValue: food,
                        decoration: InputDecoration(labelText: t.medFoodLabel),
                        items: [
                          DropdownMenuItem(value: 'any', child: Text(t.medFoodAny)),
                          DropdownMenuItem(value: 'before', child: Text(t.medFoodBefore)),
                          DropdownMenuItem(value: 'after', child: Text(t.medFoodAfter)),
                          DropdownMenuItem(value: 'with', child: Text(t.medFoodWith)),
                        ],
                        onChanged: (v) => setD(() => food = v ?? 'any')),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: qty,
                              keyboardType: TextInputType.number,
                              decoration:
                                  InputDecoration(labelText: t.medDoseQtyLabel))),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: TextField(
                              controller: stock,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(labelText: t.medStockLabel))),
                    ]),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: duration,
                              keyboardType: TextInputType.number,
                              decoration:
                                  InputDecoration(labelText: t.medDurationLabel))),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: TextField(
                              controller: refill,
                              decoration:
                                  InputDecoration(labelText: t.familyRefillDateLabel))),
                    ]),
                    Padding(
                        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
                        child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(t.familyReminderFollowupHeading,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)))),
                    TextField(
                        controller: repeat,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: t.familyFollowupRepeatLabel)),
                    TextField(
                        controller: retries,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: t.familyFollowupRetriesLabel)),
                    TextField(
                        controller: caregiverMin,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: t.familyCaregiverAlertLabel)),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: quietStart,
                              decoration:
                                  InputDecoration(labelText: t.familyQuietStartLabel))),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: TextField(
                              controller: quietEnd,
                              decoration:
                                  InputDecoration(labelText: t.familyQuietEndLabel))),
                    ]),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
                  ],
                )));
    if (ok == true && name.text.trim().isNotEmpty) {
      final slots = prn
          ? <String>[]
          : times.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final body = <String, dynamic>{
        'name': name.text.trim(),
        'dosage': dose.text.trim(),
        'times': slots,
        'as_needed': prn,
        'food_relation': food,
        'dose_qty': qty.text.trim().isEmpty ? '1' : qty.text.trim(),
        // send member on edit too so it can be cleared/changed
        'member': memberId,
        // clearable: send the key even when empty so the server unsets it
        'stock_count':
            stock.text.trim().isEmpty ? null : num.tryParse(stock.text.trim()),
        'duration_days': duration.text.trim().isEmpty
            ? null
            : int.tryParse(duration.text.trim()),
        'refill_date': refill.text.trim().isEmpty ? null : refill.text.trim(),
        'followup_repeat_min': int.tryParse(repeat.text.trim()) ?? 15,
        'followup_retries': int.tryParse(retries.text.trim()) ?? 2,
        'caregiver_alert_min': int.tryParse(caregiverMin.text.trim()) ?? 30,
        'quiet_start': quietStart.text.trim(),
        'quiet_end': quietEnd.text.trim(),
      };
      final api = context.read<AppState>().api;
      // Editing keeps the MedicineLog history (delete would cascade it away).
      if (editing) {
        await api.updateItem('medicines', existing['id'] as int, body);
      } else {
        await api.createItem('medicines', body);
      }
      _load();
    }
  }

  Future<void> _showEscalation(Map<String, dynamic> m) async {
    final t = _t;
    final api = context.read<AppState>().api;
    Map<String, dynamic> esc;
    try {
      esc = await api.medicineEscalation(m['id']);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final events = (esc['events'] as List? ?? []).cast<Map<String, dynamic>>();
    final pushReady = esc['push_ready'] == true;
    String kindLabel(String k) => {
          'reminder': t.medEscalationReminder,
          'reremind': t.medEscalationReremind,
          'caregiver_alert': t.medEscalationCaregiver,
        }[k] ??
        k;
    showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(t.medEscalationTitle),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final e in events)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Text(e['at'] ?? ''),
                    title: Text(kindLabel(e['kind'] ?? '')),
                    subtitle: e['suppressed'] == true
                        ? Text(t.medEscalationQuietNote)
                        : null,
                  ),
                if (!pushReady)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.sm),
                    child: Text(t.medPushGatedNote,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.ok))
              ],
            ));
  }

  Widget _medsTab() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton:
          FloatingActionButton(onPressed: _addMed, child: const Icon(Icons.add)),
      body: meds.isEmpty
          ? StateMessage(
              icon: Icons.medication_outlined,
              title: t.familyAddMedicinesEmpty,
              action: FilledButton.icon(
                  onPressed: _addMed,
                  icon: const Icon(Icons.add),
                  label: Text(t.familyAddMedicineTitle)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                for (final m in meds) _medManageCard(m, t, scheme),
              ]),
    );
  }

  Widget _medManageCard(Map<String, dynamic> m, AppLocalizations t, ColorScheme scheme) {
    final prn = m['as_needed'] == true;
    final status = m['refill_status']?.toString() ?? 'ok';
    final daysLeft = m['days_left'];
    final adh = (m['adherence_30d'] as num?)?.toInt();
    final sub = <String>[
      if ((m['dosage'] ?? '').toString().isNotEmpty) m['dosage'].toString(),
      if (prn) t.medAsNeededShort else ((m['times'] ?? []) as List).join(', '),
      if (_foodLabel(m['food_relation']).isNotEmpty) _foodLabel(m['food_relation']),
    ].where((e) => e.isNotEmpty).join(' · ');

    Color? stockColor;
    String? stockText;
    if (status == 'out') {
      stockColor = Brand.danger;
      stockText = t.medOutOfStockOne(m['name'] ?? '');
    } else if (status == 'soon' && daysLeft != null) {
      stockColor = Brand.warning;
      stockText = t.medDaysLeftValue(daysLeft);
    } else if (daysLeft != null) {
      stockText = t.medDaysLeftValue(daysLeft);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.medication_outlined),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m['name'] ?? '',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (sub.isNotEmpty)
                    Text(sub, style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (adh != null && !prn)
                Text('$adh%',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: adh >= 85
                            ? Brand.success
                            : adh >= 60
                                ? Brand.warning
                                : Brand.danger)),
              IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: t.edit,
                  onPressed: () => _addMed(existing: m)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await context.read<AppState>().api.deleteItem('medicines', m['id']);
                    _load();
                  }),
            ]),
            if (stockText != null) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(Icons.inventory_2_outlined, size: 16, color: stockColor),
                const SizedBox(width: Gap.xs),
                Text(stockText, style: TextStyle(color: stockColor)),
              ]),
            ],
            if ((m['predicted_refill'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(Icons.event_repeat_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.xs),
                Text(t.medPredictedRefill(m['predicted_refill'].toString()),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ]),
            ],
            const SizedBox(height: Gap.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showEscalation(m),
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: Text(t.medViewEscalation),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------------- CAREGIVER OVERVIEW ----------------
  Widget _caregiverTab() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final people = (caregiver?['people'] as List? ?? []).cast<Map<String, dynamic>>();
    final pushReady = caregiver?['push_ready'] == true;
    if (people.isEmpty) {
      return StateMessage(
        icon: Icons.favorite_outline,
        title: t.medCaregiverTitle,
        message: t.medCaregiverEmpty,
      );
    }
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      _brandHeader(t.medCaregiverTitle),
      const SizedBox(height: Gap.md),
      for (final p in people) _personCard(p, t, scheme),
      const SizedBox(height: Gap.sm),
      Card(
        color: scheme.surfaceContainerHighest,
        child: ListTile(
          leading: const Icon(Icons.picture_as_pdf_outlined),
          title: Text(t.medDoctorPdf),
          subtitle: Text(t.medDoctorPdfSubtitle),
          onTap: _downloadDoctorPdf,
        ),
      ),
      if (!pushReady)
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.medPushGatedNote,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
          ]),
        ),
    ]);
  }

  Widget _brandHeader(String title) {
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(children: [
        const Icon(Icons.volunteer_activism_outlined, color: Colors.white),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(title,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        ),
      ]),
    );
  }

  Widget _personCard(Map<String, dynamic> p, AppLocalizations t, ColorScheme scheme) {
    final due = (p['doses_today'] as num?)?.toInt() ?? 0;
    final taken = (p['taken_today'] as num?)?.toInt() ?? 0;
    final pending = (p['pending_today'] as num?)?.toInt() ?? 0;
    final adh = (p['adherence_30d'] as num?)?.toInt() ?? 0;
    final lowStock = (p['low_stock'] as List? ?? []).cast<Map<String, dynamic>>();
    final nextDue = p['next_due'];
    final isSelf = p['relation'] == 'self';

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Icon(isSelf ? Icons.person : Icons.elderly,
                    color: scheme.onSecondaryContainer),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(isSelf ? t.medForSelf : (p['name'] ?? ''),
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(t.medTakenOfTotal(taken, due),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
              _adhChip(adh),
            ]),
            const SizedBox(height: Gap.md),
            if (pending == 0 && due > 0)
              Row(children: [
                const Icon(Icons.check_circle_outline, size: 18, color: Brand.success),
                const SizedBox(width: Gap.sm),
                Text(t.medAllDoneToday, style: const TextStyle(color: Brand.success)),
              ])
            else if (nextDue != null)
              Row(children: [
                Icon(Icons.schedule, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Text(t.medNextDose(nextDue)),
              ]),
            if (lowStock.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(t.medLowStockHeading,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: Brand.warning)),
              for (final ls in lowStock)
                Text(
                  ls['status'] == 'out'
                      ? t.medOutOfStockOne(ls['name'] ?? '')
                      : t.medLowStockOne(ls['name'] ?? '', ls['days_left'] ?? 0),
                  style: TextStyle(
                      fontSize: 13,
                      color: ls['status'] == 'out' ? Brand.danger : Brand.warning),
                ),
            ],
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => MedicineHistoryScreen(
                            member: p['member']?.toString() ?? 'self',
                            personName: isSelf ? t.medForSelf : p['name']))),
                icon: const Icon(Icons.bar_chart_outlined, size: 18),
                label: Text(t.medHistoryTitle),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _adhChip(int adh) {
    final c = adh >= 85
        ? Brand.success
        : adh >= 60
            ? Brand.warning
            : Brand.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text('$adh%', style: TextStyle(fontWeight: FontWeight.w700, color: c)),
    );
  }

  // ---------------- PRESCRIPTIONS ----------------
  Future<void> _addPrescription({Map<String, dynamic>? existing}) async {
    final t = _t;
    final editing = existing != null;
    final doctorName =
        TextEditingController(text: existing?['doctor_name']?.toString() ?? '');
    final diagnosis =
        TextEditingController(text: existing?['diagnosis']?.toString() ?? '');
    final date = TextEditingController(text: existing?['date']?.toString() ?? '');
    final medsText = TextEditingController(
        text: ((existing?['meds'] as List?)
                ?.map((m) => (m is Map ? (m['name'] ?? '') : m).toString())
                .where((e) => e.isNotEmpty)
                .join('\n')) ??
            '');
    int? doctorId = existing?['doctor'] as int?;
    int? memberId = existing?['member'] as int?;

    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(editing ? t.medEditPrescription : t.medAddPrescription),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (doctors.isNotEmpty)
                      DropdownButtonFormField<int?>(
                          initialValue: doctorId,
                          decoration: InputDecoration(labelText: t.medDoctorLabel),
                          items: [
                            DropdownMenuItem(value: null, child: Text(t.medNoDoctor)),
                            for (final d in doctors)
                              DropdownMenuItem(
                                  value: d['id'] as int, child: Text(d['name'] ?? '')),
                          ],
                          onChanged: (v) => setD(() => doctorId = v)),
                    if (doctors.isEmpty)
                      TextField(
                          controller: doctorName,
                          decoration: InputDecoration(labelText: t.medDoctorNameLabel)),
                    DropdownButtonFormField<int?>(
                        initialValue: memberId,
                        decoration: InputDecoration(labelText: t.medForWhomLabel),
                        items: [
                          DropdownMenuItem(value: null, child: Text(t.medForSelf)),
                          for (final m in members)
                            DropdownMenuItem(
                                value: m['id'] as int, child: Text(m['name'] ?? '')),
                        ],
                        onChanged: (v) => setD(() => memberId = v)),
                    TextField(
                        controller: date,
                        decoration:
                            InputDecoration(labelText: t.medPrescriptionDateLabel)),
                    TextField(
                        controller: diagnosis,
                        decoration: InputDecoration(labelText: t.medDiagnosisLabel)),
                    TextField(
                        controller: medsText,
                        maxLines: 4,
                        decoration:
                            InputDecoration(labelText: t.medPrescriptionMedsLabel)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
                  ],
                )));
    if (ok == true) {
      final medsList = medsText.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map((e) => {'name': e})
          .toList();
      final body = <String, dynamic>{
        'doctor': doctorId,
        if (doctorId == null && doctorName.text.trim().isNotEmpty)
          'doctor_name': doctorName.text.trim(),
        'member': memberId,
        'date': date.text.trim().isEmpty ? null : date.text.trim(),
        'diagnosis': diagnosis.text.trim(),
        'meds': medsList,
      };
      final api = context.read<AppState>().api;
      if (editing) {
        await api.updateItem('prescriptions', existing['id'] as int, body);
      } else {
        await api.createItem('prescriptions', body);
      }
      _load();
    }
  }

  Future<void> _addDoctor({Map<String, dynamic>? existing}) async {
    final t = _t;
    final editing = existing != null;
    final name = TextEditingController(text: existing?['name']?.toString() ?? '');
    final specialty =
        TextEditingController(text: existing?['specialty']?.toString() ?? '');
    final hospital =
        TextEditingController(text: existing?['hospital']?.toString() ?? '');
    final phone = TextEditingController(text: existing?['phone']?.toString() ?? '');
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(editing ? t.medEditDoctor : t.medAddDoctor),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration: InputDecoration(labelText: t.medDoctorNameLabel)),
                TextField(
                    controller: specialty,
                    decoration: InputDecoration(labelText: t.medSpecialtyLabel)),
                TextField(
                    controller: hospital,
                    decoration: InputDecoration(labelText: t.medHospitalLabel)),
                TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(labelText: t.phoneOptional)),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
              ],
            ));
    if (ok == true && name.text.trim().isNotEmpty) {
      final body = {
        'name': name.text.trim(),
        'specialty': specialty.text.trim(),
        'hospital': hospital.text.trim(),
        'phone': phone.text.trim(),
      };
      final api = context.read<AppState>().api;
      if (editing) {
        await api.updateItem('doctors', existing['id'] as int, body);
      } else {
        await api.createItem('doctors', body);
      }
      _load();
    }
  }

  Widget _prescriptionsTab() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: _addPrescription, child: const Icon(Icons.add)),
      body: prescriptions.isEmpty
          ? StateMessage(
              icon: Icons.description_outlined,
              title: t.medPrescriptionsTitle,
              message: t.medPrescriptionsEmpty,
              action: Wrap(spacing: Gap.sm, children: [
                OutlinedButton.icon(
                    onPressed: _addDoctor,
                    icon: const Icon(Icons.person_add_alt),
                    label: Text(t.medAddDoctor)),
                FilledButton.icon(
                    onPressed: _addPrescription,
                    icon: const Icon(Icons.add),
                    label: Text(t.medAddPrescription)),
              ]))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                      onPressed: _addDoctor,
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: Text(t.medAddDoctor)),
                ),
                for (final p in prescriptions) _prescriptionCard(p, t, scheme),
              ]),
    );
  }

  Widget _prescriptionCard(Map<String, dynamic> p, AppLocalizations t, ColorScheme scheme) {
    final meds = (p['meds'] as List? ?? []);
    final doctor = p['doctor_display']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.local_hospital_outlined),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(doctor.isEmpty ? t.medNoDoctor : doctor,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (p['date'] != null)
                Text(p['date'].toString(),
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: t.edit,
                  onPressed: () => _addPrescription(existing: p)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await context.read<AppState>().api.deleteItem('prescriptions', p['id']);
                    _load();
                  }),
            ]),
            if ((p['diagnosis'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(p['diagnosis']),
            ],
            if (meds.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              for (final m in meds)
                Row(children: [
                  const Icon(Icons.circle, size: 6),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text((m is Map ? (m['name'] ?? '') : m).toString())),
                ]),
            ],
          ]),
        ),
      ),
    );
  }

  // ---------------- FAMILY MEMBERS ----------------
  Future<void> _addMember({Map<String, dynamic>? existing}) async {
    final t = _t;
    final editing = existing != null;
    final name = TextEditingController(text: existing?['name']?.toString() ?? '');
    final rel = TextEditingController(text: existing?['relation']?.toString() ?? '');
    final phone = TextEditingController(text: existing?['phone']?.toString() ?? '');
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(editing ? t.medEditMember : t.familyMemberTitle),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, decoration: InputDecoration(labelText: t.name)),
                TextField(
                    controller: rel,
                    decoration: InputDecoration(labelText: t.familyRelationLabel)),
                TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(labelText: t.phoneOptional)),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
              ],
            ));
    if (ok == true && name.text.trim().isNotEmpty) {
      final body = {
        'name': name.text.trim(),
        'relation': rel.text.trim(),
        'phone': phone.text.trim()
      };
      final api = context.read<AppState>().api;
      if (editing) {
        await api.updateItem('family', existing['id'] as int, body);
      } else {
        await api.createItem('family', body);
      }
      _load();
    }
  }

  Widget _membersTab() {
    final t = _t;
    return Scaffold(
      floatingActionButton:
          FloatingActionButton(onPressed: _addMember, child: const Icon(Icons.add)),
      body: members.isEmpty
          ? StateMessage(icon: Icons.group_outlined, title: t.familyAddMemberEmpty)
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                for (final m in members)
                  Card(
                      child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(m['name'] ?? ''),
                    subtitle: Text([(m['relation'] ?? ''), (m['phone'] ?? '')]
                        .where((e) => e.toString().isNotEmpty)
                        .join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: t.edit,
                          onPressed: () => _addMember(existing: m)),
                      IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await context.read<AppState>().api.deleteItem('family', m['id']);
                            _load();
                          }),
                    ]),
                  )),
              ]),
    );
  }

  // ---------------- SCHOOL ----------------
  Future<void> _addSchool() async {
    final t = _t;
    final child = TextEditingController();
    final title = TextEditingController();
    final date = TextEditingController();
    String kind = 'fee';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.familySchoolTitle),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: child,
                        decoration: InputDecoration(labelText: t.familyChildNameLabel)),
                    DropdownButtonFormField<String>(
                        initialValue: kind,
                        decoration: InputDecoration(labelText: t.moneyFieldType),
                        items: [
                          DropdownMenuItem(value: 'fee', child: Text(t.familyKindFee)),
                          DropdownMenuItem(value: 'exam', child: Text(t.familyKindExam)),
                          DropdownMenuItem(
                              value: 'meeting', child: Text(t.familyKindMeeting))
                        ],
                        onChanged: (v) => setD(() => kind = v ?? 'fee')),
                    TextField(
                        controller: title,
                        decoration: InputDecoration(labelText: t.familyDescriptionLabel)),
                    TextField(
                        controller: date,
                        decoration: InputDecoration(labelText: t.familyDateLabel)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
                  ],
                )));
    if (ok == true && title.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('school', {
        'child_name': child.text.trim(),
        'kind': kind,
        'title': title.text.trim(),
        if (date.text.trim().isNotEmpty) 'date': date.text.trim()
      });
      _load();
    }
  }

  Widget _schoolTab() {
    final t = _t;
    return Scaffold(
      floatingActionButton:
          FloatingActionButton(onPressed: _addSchool, child: const Icon(Icons.add)),
      body: school.isEmpty
          ? StateMessage(icon: Icons.school_outlined, title: t.familyAddSchoolEmpty)
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [
                for (final s in school)
                  Card(
                      child: ListTile(
                    leading: Icon({
                          'fee': Icons.payments_outlined,
                          'exam': Icons.edit_note_outlined,
                          'meeting': Icons.groups_outlined,
                        }[s['kind']] ??
                        Icons.push_pin_outlined),
                    title: Text(s['title'] ?? ''),
                    subtitle: Text([(s['child_name'] ?? ''), (s['date'] ?? '')]
                        .where((e) => e.toString().isNotEmpty)
                        .join(' · ')),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await context.read<AppState>().api.deleteItem('school', s['id']);
                          _load();
                        }),
                  )),
              ]),
    );
  }
}
