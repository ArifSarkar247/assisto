import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'bday_model.dart';

/// Add / edit a birthday or memorable day (ADVANCED). Captures:
///   name · kind · date · relation (quick-pick chips + free text) · notes ·
///   yearly toggle · configurable pre-reminders (1 week / 3 days / 1 day /
///   on-the-day, multi-select) · optional phone (for one-tap wish).
///
/// Returns a body map for api.birthdayCreate / update (the integrator maps it);
/// `lead_days` is emitted as a LIST of ints which birthdays.reminder_dates()
/// already accepts. Pure-widget: no Bangla glyphs (strings via [bStr] / ARB).
class BdayAddSheet extends StatefulWidget {
  final List<Map<String, dynamic>> kinds;
  final Map<String, dynamic>? existing; // non-null => edit
  final VoidCallback? onImportContacts;
  const BdayAddSheet({
    super.key,
    required this.kinds,
    this.existing,
    this.onImportContacts,
  });

  @override
  State<BdayAddSheet> createState() => _BdayAddSheetState();
}

class _BdayAddSheetState extends State<BdayAddSheet> {
  final _name = TextEditingController();
  final _relation = TextEditingController();
  final _notes = TextEditingController();
  final _phone = TextEditingController();
  String _kind = 'birthday';
  DateTime? _date;
  bool _yearly = true;
  final Set<int> _leads = {1, 0}; // default: 1 day before + on the day
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (widget.kinds.isNotEmpty) {
      _kind = (widget.kinds.first['id'] ?? 'birthday').toString();
    }
    final e = widget.existing;
    if (e != null) {
      _name.text = (e['name'] ?? '').toString();
      _relation.text = (e['relation'] ?? '').toString();
      _notes.text = (e['notes'] ?? '').toString();
      _phone.text = (e['phone'] ?? '').toString();
      _kind = (e['kind'] ?? _kind).toString();
      _yearly = e['yearly'] != false;
      _date = bParseDate(e['date']?.toString());
      final raw = e['lead_days'];
      if (raw is List) {
        _leads
          ..clear()
          ..addAll(raw.whereType<int>());
      } else if (raw is int) {
        _leads
          ..clear()
          ..add(raw);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _relation.dispose();
    _notes.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(now.year - 120),
      lastDate: DateTime(now.year + 2, 12, 31),
    );
    if (picked != null) setState(() => _date = picked);
  }

  bool get _canSave =>
      !_saving && _name.text.trim().isNotEmpty && _date != null;

  Map<String, dynamic> _buildBody() {
    final d = _date!;
    final iso = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final leads = _leads.toList()..sort((a, b) => b.compareTo(a));
    return {
      'name': _name.text.trim(),
      'date': iso,
      'kind': _kind,
      'yearly': _yearly,
      'lead_days': leads.isEmpty ? [0] : leads,
      if (_relation.text.trim().isNotEmpty) 'relation': _relation.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
      if (_isEdit && widget.existing!['id'] != null) 'id': widget.existing!['id'],
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(_isEdit ? bStr(context, 'bEdit') : t.birthdaysAdd,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                if (!_isEdit && widget.onImportContacts != null)
                  TextButton.icon(
                    icon: const Icon(Icons.contacts_rounded, size: 18),
                    label: Text(bStr(context, 'bImportContacts')),
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onImportContacts!();
                    },
                  ),
              ]),
              const SizedBox(height: Gap.sm),
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: t.birthdayNameLabel),
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gap.md),
              // kind chips
              if (widget.kinds.isNotEmpty)
                Wrap(spacing: Gap.sm, children: [
                  for (final k in widget.kinds)
                    ChoiceChip(
                      label: Text(
                          (k['label'] ?? k['name'] ?? k['id']).toString()),
                      selected: _kind == (k['id']).toString(),
                      onSelected: (_) =>
                          setState(() => _kind = k['id'].toString()),
                    ),
                ]),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_rounded, size: 18),
                label: Text(_date == null
                    ? t.birthdayPickDate
                    : t.birthdayDateChosen(
                        '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}')),
                onPressed: _pickDate,
              ),
              const SizedBox(height: Gap.md),
              // relation
              TextField(
                controller: _relation,
                decoration:
                    InputDecoration(labelText: bStr(context, 'bRelationLabel')),
              ),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, children: [
                for (final rel in kRelationChips)
                  ActionChip(
                    label: Text(bStr(context, rel[0])),
                    onPressed: () =>
                        setState(() => _relation.text = bStr(context, rel[0])),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              // notes
              TextField(
                controller: _notes,
                decoration:
                    InputDecoration(labelText: bStr(context, 'bNotesLabel')),
                maxLines: 2,
              ),
              const SizedBox(height: Gap.md),
              // phone (one-tap wish)
              TextField(
                controller: _phone,
                decoration:
                    InputDecoration(labelText: bStr(context, 'bPhoneLabel')),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: Gap.sm),
              // yearly
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(bStr(context, 'bYearly')),
                value: _yearly,
                onChanged: (v) => setState(() => _yearly = v),
              ),
              const SizedBox(height: Gap.xs),
              // pre-reminders (multi-select)
              Text(bStr(context, 'bPreReminders'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final opt in kPreReminderOptions)
                  FilterChip(
                    label: Text(bStr(context, opt.stringKey)),
                    selected: _leads.contains(opt.leadDays),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _leads.add(opt.leadDays);
                      } else {
                        _leads.remove(opt.leadDays);
                      }
                    }),
                  ),
              ]),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _canSave
                      ? () {
                          setState(() => _saving = true);
                          Navigator.of(context).pop(_buildBody());
                        }
                      : null,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.save),
                ),
              ),
            ]),
      ),
    );
  }
}
