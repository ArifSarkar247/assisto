import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'subs_common.dart';
import 'bn_day_periods.dart' show appDateLocale;

/// Advanced add/edit bottom sheet for a subscription.
///
/// Collects the full modern field set (name, amount, cycle incl. custom days,
/// next due, category, payment method, free-trial end, auto-renew, notes,
/// status). Returns the edited map, or null on cancel. Persistence of each
/// field is the caller's concern — see .phaseB/up_subs_integration.md for what
/// the current endpoint stores vs. what needs backend support.
class SubsEditSheet extends StatefulWidget {
  final Map<String, dynamic>? initial; // null = add
  const SubsEditSheet({super.key, this.initial});

  @override
  State<SubsEditSheet> createState() => _SubsEditSheetState();
}

class _SubsEditSheetState extends State<SubsEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _interval;
  late final TextEditingController _notes;
  String _cycle = 'monthly';
  String _category = 'streaming';
  String _payment = 'bkash';
  bool _autoRenew = true;
  String _status = 'active';
  DateTime? _due;
  DateTime? _trialEnd;

  @override
  void initState() {
    super.initState();
    final s = widget.initial ?? {};
    _name = TextEditingController(text: '${s['name'] ?? ''}');
    _amount = TextEditingController(
        text: s['amount'] != null ? '${s['amount']}' : '');
    _interval = TextEditingController(text: '${s['interval_days'] ?? ''}');
    _notes = TextEditingController(text: '${s['notes'] ?? ''}');
    _cycle = cycleNorm(s['cycle']);
    if (s['category'] != null) _category = '${s['category']}';
    if (s['payment_method'] != null) _payment = '${s['payment_method']}';
    _autoRenew = s['auto_renew'] != false;
    _status = '${s['status'] ?? 'active'}';
    _due = parseDate(s['next_due']);
    _trialEnd = parseDate(s['trial_end']);
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _interval.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty || takaToPoisha(_amount.text) <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.subsValidation)));
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'name': _name.text.trim(),
      'amount': _amount.text.trim(),
      'amount_poisha': takaToPoisha(_amount.text),
      'cycle': _cycle,
      if (_cycle == 'custom')
        'interval_days': int.tryParse(_ascii(_interval.text)) ?? 30,
      if (_due != null) 'next_due': DateFormat('yyyy-MM-dd').format(_due!),
      'category': _category,
      'payment_method': _payment,
      if (_trialEnd != null)
        'trial_end': DateFormat('yyyy-MM-dd').format(_trialEnd!),
      'auto_renew': _autoRenew,
      'notes': _notes.text.trim(),
      'status': _status,
    });
  }

  String _ascii(String s) {
    const z = 0x09E6;
    final b = StringBuffer();
    for (final ch in s.runes) {
      b.write(ch >= z && ch <= z + 9 ? '${ch - z}' : String.fromCharCode(ch));
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final editing = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: Gap.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
              ),
            ),
            Text(editing ? t.subsEditTitle : t.addSubscription,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: t.name, prefixIcon: const Icon(Icons.label_outline)),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t.amount,
                  prefixText: '\u09F3 ',
                  prefixIcon: const Icon(Icons.payments_outlined)),
            ),
            const SizedBox(height: Gap.lg),
            _label(t.subsCycle),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final c in kCycles)
                  ChoiceChip(
                    label: Text(cycleLabel(t, c)),
                    selected: _cycle == c,
                    onSelected: (_) => setState(() => _cycle = c),
                  ),
              ],
            ),
            if (_cycle == 'custom') ...[
              const SizedBox(height: Gap.md),
              TextField(
                controller: _interval,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: t.subsCustomDays,
                    prefixIcon: const Icon(Icons.repeat)),
              ),
            ],
            const SizedBox(height: Gap.lg),
            _dateRow(context, t.nextDue, Icons.event, _due,
                (d) => setState(() => _due = d)),
            const SizedBox(height: Gap.sm),
            _dateRow(context, t.subsTrialEnd, Icons.hourglass_bottom,
                _trialEnd, (d) => setState(() => _trialEnd = d)),
            const SizedBox(height: Gap.lg),
            _label(t.subsCategory),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                for (final c in kCategories)
                  ChoiceChip(
                    avatar: Icon(categoryIcon(c),
                        size: 16, color: subColor(context, c)),
                    label: Text(categoryLabel(t, c)),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            _label(t.subsPaymentMethod),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                for (final p in kPaymentMethods)
                  ChoiceChip(
                    avatar: Icon(paymentIcon(p), size: 16),
                    label: Text(paymentLabel(t, p)),
                    selected: _payment == p,
                    onSelected: (_) => setState(() => _payment = p),
                  ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.subsAutoRenew),
              subtitle: Text(t.subsAutoRenewHint),
              value: _autoRenew,
              onChanged: (v) => setState(() => _autoRenew = v),
            ),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: InputDecoration(
                  labelText: t.subsNotes,
                  prefixIcon: const Icon(Icons.notes)),
            ),
            if (editing) ...[
              const SizedBox(height: Gap.lg),
              _label(t.subsStatus),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'active', label: Text(t.subsStatusActive)),
                  ButtonSegment(
                      value: 'paused', label: Text(t.subsStatusPaused)),
                  ButtonSegment(
                      value: 'cancelled', label: Text(t.subsStatusCancelled)),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
            ],
            const SizedBox(height: Gap.xl),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.cancel),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.check),
                  label: Text(t.save),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(s,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );

  Widget _dateRow(BuildContext context, String label, IconData icon,
      DateTime? value, ValueChanged<DateTime?> onPick) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 18),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(48),
      ),
      label: Row(children: [
        Expanded(
          child: Text(value == null
              ? label
              : '$label: ${DateFormat('d MMM yyyy', appDateLocale(context)).format(value)}'),
        ),
        if (value != null)
          GestureDetector(
            onTap: () => onPick(null),
            child: const Icon(Icons.clear, size: 18),
          ),
      ]),
      onPressed: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (d != null) onPick(d);
      },
    );
  }
}
