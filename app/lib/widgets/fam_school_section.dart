import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'fam_empty.dart';

/// famcare — the School tab (fees, exams, meetings for a child).
///
/// Fixed vs the old tab: the date was free text (a wrong format failed
/// SILENTLY on the server) -> a date picker; amount, done tick and edit
/// added; "remind me the day before" creates a REAL reminder; the child is
/// picked from the family list (typed only if not there); every failure says
/// so. Empty tab: benefit + big button + how-to.
class FamSchoolSection extends StatefulWidget {
  const FamSchoolSection({super.key, required this.items, required this.members,
      required this.onChanged});

  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> members;
  final Future<void> Function() onChanged;

  @override
  State<FamSchoolSection> createState() => _FamSchoolSectionState();
}

class _FamSchoolSectionState extends State<FamSchoolSection> {
  ApiClient get _api => context.read<AppState>().api;

  Future<void> _open([Map<String, dynamic>? existing]) async {
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SchoolForm(existing: existing, members: widget.members),
    );
    if (ok == true) await widget.onChanged();
  }

  Future<void> _toggle(Map<String, dynamic> s) async {
    try {
      await _api.updateItem('school', s['id'] as int, {'done': !(s['done'] == true)});
      await widget.onChanged();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.fcSchoolDeleteQ),
        content: Text('${s['title'] ?? ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fcRemove)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _api.deleteItem('school', s['id'] as int);
      await widget.onChanged();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  void _fail(Object e) {
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (widget.items.isEmpty) {
      return FamEmptyState(
        icon: Icons.school_rounded,
        title: t.fcSchoolEmptyTitle,
        benefit: t.fcSchoolEmptyBenefit,
        primaryLabel: t.fcSchoolAdd,
        onPrimary: () => _open(),
        steps: [t.fcSchoolStep1, t.fcSchoolStep2, t.fcSchoolStep3],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final open = widget.items.where((s) => s['done'] != true).toList();
    final done = widget.items.where((s) => s['done'] == true).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          heroTag: 'fc-school-fab',
          onPressed: () => _open(),
          icon: const Icon(Icons.add_rounded),
          label: Text(t.fcSchoolAdd)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96)),
        children: [
          for (final s in open) _tile(s, scheme, t),
          if (done.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xs),
              child: Text(t.fcSchoolDoneHeading,
                  style: AType.titleSmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
            for (final s in done) _tile(s, scheme, t),
          ],
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> s, ColorScheme scheme, AppLocalizations t) {
    final kind = '${s['kind'] ?? 'fee'}';
    final done = s['done'] == true;
    final date = DateTime.tryParse('${s['date'] ?? ''}');
    final amount = num.tryParse('${s['amount'] ?? ''}');
    final today = DateTime.now();
    final overdue = !done && date != null &&
        date.isBefore(DateTime(today.year, today.month, today.day));
    final sub = [
      '${s['child_name'] ?? ''}',
      _kindLabel(t, kind),
      if (date != null) famDate(context, date),
      if (amount != null && amount > 0) famDigits(context, '৳${amount.toStringAsFixed(0)}'),
    ].where((e) => e.trim().isNotEmpty).join(' · ');
    return Card(
      key: ValueKey('fc-school-${s['id']}'),
      child: ListTile(
        minTileHeight: 64,
        leading: IconButton(
          tooltip: done ? t.fcMarkNotDone : t.fcMarkDone,
          icon: Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: done ? Brand.success : scheme.onSurfaceVariant),
          onPressed: () => _toggle(s),
        ),
        title: Text('${s['title'] ?? ''}',
            style: done ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
        subtitle: Text(overdue ? '$sub · ${t.fcOverdue}' : sub,
            style: overdue ? const TextStyle(color: Brand.danger) : null),
        onTap: () => _open(s),
        trailing: IconButton(
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _delete(s)),
      ),
    );
  }
}

String _kindLabel(AppLocalizations t, String kind) => switch (kind) {
      'exam' => t.familyKindExam,
      'meeting' => t.familyKindMeeting,
      _ => t.familyKindFee,
    };

class _SchoolForm extends StatefulWidget {
  const _SchoolForm({this.existing, required this.members});
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> members;
  @override
  State<_SchoolForm> createState() => _SchoolFormState();
}

class _SchoolFormState extends State<_SchoolForm> {
  late final _child = TextEditingController(text: '${widget.existing?['child_name'] ?? ''}');
  late final _title = TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final _amount = TextEditingController(
      text: num.tryParse('${widget.existing?['amount'] ?? ''}')?.toStringAsFixed(0) ?? '');
  late String _kind = '${widget.existing?['kind'] ?? 'fee'}';
  late DateTime? _date = DateTime.tryParse('${widget.existing?['date'] ?? ''}');
  bool _remind = true;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _child.dispose();
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: _date ?? now,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 2));
    if (d != null) setState(() => _date = d);
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final amt = num.tryParse(_amount.text.trim());
    final body = <String, dynamic>{
      'child_name': _child.text.trim(),
      'kind': _kind,
      'title': title,
      'date': _date == null ? null : _iso(_date!),
      'amount': amt,
    };
    setState(() => _saving = true);
    try {
      if (_editing) {
        await api.updateItem('school', widget.existing!['id'] as int, body);
      } else {
        await api.createItem('school', body);
      }
      var msg = t.fcSaved;
      final d = _date;
      if (!_editing && _remind && d != null) {
        final at = DateTime(d.year, d.month, d.day, 19).subtract(const Duration(days: 1));
        if (at.isAfter(DateTime.now())) {
          try {
            await api.createItem('reminders', {
              'title': '${_kindLabel(t, _kind)}: $title',
              'due_at': at.toIso8601String(),
              'notes': _child.text.trim(),
            });
            msg = t.fcSchoolSavedReminder;
          } catch (_) {
            msg = t.fcSchoolReminderFailed;
          }
        }
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final names = widget.members.map((m) => '${m['name'] ?? ''}').where((s) => s.isNotEmpty).toList();
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
            key: const ValueKey('fc-school-save'),
            onPressed: _saving ? null : _save,
            child: Text(t.save)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_editing ? t.edit : t.fcSchoolAdd,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'fee', label: Text(t.familyKindFee)),
            ButtonSegment(value: 'exam', label: Text(t.familyKindExam)),
            ButtonSegment(value: 'meeting', label: Text(t.familyKindMeeting)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: Gap.md),
        TextField(
            key: const ValueKey('fc-school-title'),
            controller: _title,
            decoration: InputDecoration(labelText: t.familyDescriptionLabel)),
        const SizedBox(height: Gap.sm),
        TextField(controller: _child, decoration: InputDecoration(labelText: t.familyChildNameLabel)),
        if (names.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final n in names)
              ActionChip(label: Text(n), onPressed: () => setState(() => _child.text = n)),
          ]),
        ],
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          key: const ValueKey('fc-school-date'),
          onPressed: _pickDate,
          icon: const Icon(Icons.event_rounded),
          label: Text(_date == null ? t.familyDateLabel : famDate(context, _date)),
        ),
        if (_kind == 'fee') ...[
          const SizedBox(height: Gap.sm),
          TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.fcAmountTaka, prefixText: '৳ ')),
        ],
        if (!_editing)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _remind && _date != null,
            onChanged: _date == null ? null : (v) => setState(() => _remind = v),
            title: Text(t.fcSchoolRemind),
          ),
      ]),
    );
  }
}
