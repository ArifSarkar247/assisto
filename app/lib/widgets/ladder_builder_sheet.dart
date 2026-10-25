import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ladder_common.dart';

/// Advanced add/edit sheet for a debt + its escalation ladder. Collects the
/// party, amount (→ integer poisha), due date, recurring interval, the
/// stop-on-payment rule, and the per-step ladder (timing + action + channel).
///
/// Returns a `{debt: {...}, ladder: {...}}` map on save, or null on cancel. It
/// never moves money; the key-gated `pay_key` action is only offered for the
/// payable kind and shown as honest (downgrades to a manual wallet open if the
/// owner has no licensed key — see ladder_common.resolvePayAction).
class LadderBuilderSheet extends StatefulWidget {
  final String kind; // receivable | payable
  final Map<String, dynamic>? debt;
  final Map<String, dynamic>? ladder;
  const LadderBuilderSheet({super.key, required this.kind, this.debt, this.ladder});

  @override
  State<LadderBuilderSheet> createState() => _LadderBuilderSheetState();
}

class _LadderBuilderSheetState extends State<LadderBuilderSheet> {
  late final TextEditingController _party;
  late final TextEditingController _amount;
  late final TextEditingController _paid;
  late final TextEditingController _recurring;
  DateTime? _dueDate;
  bool _stopOnPayment = true;
  bool _showError = false;
  late List<Map<String, dynamic>> _steps;

  bool get _receivable => widget.kind == kKindReceivable;

  @override
  void initState() {
    super.initState();
    final d = widget.debt ?? const {};
    _party = TextEditingController(text: '${d['party'] ?? ''}');
    _amount = TextEditingController(
        text: d.isEmpty ? '' : (outstandingPoishaInitial(d) / 100).toString());
    _paid = TextEditingController(
        text: (d['paid_poisha'] != null)
            ? (poishaOf(d, poishaKey: 'paid_poisha', takaKey: 'paid') / 100).toString()
            : '');
    _recurring = TextEditingController(text: '${d['recurring_days'] ?? ''}');
    _dueDate = parseDate(d['due_date']);
    final lad = widget.ladder ?? defaultLadder(widget.kind);
    _stopOnPayment = (lad['stop_on_payment'] ?? true) == true;
    _steps = [
      for (final s in (lad['steps'] as List? ?? const []))
        Map<String, dynamic>.from(s as Map)
    ];
    if (_steps.isEmpty) {
      _steps = [
        for (final s in defaultLadder(widget.kind)['steps'] as List)
          Map<String, dynamic>.from(s as Map)
      ];
    }
  }

  int outstandingPoishaInitial(Map d) {
    // Show the full amount (not the remainder) in the amount field; paid is edited separately.
    return poishaOf(d);
  }

  @override
  void dispose() {
    _party.dispose();
    _amount.dispose();
    _paid.dispose();
    _recurring.dispose();
    super.dispose();
  }

  void _useDefault() {
    setState(() {
      _steps = [
        for (final s in defaultLadder(widget.kind)['steps'] as List)
          Map<String, dynamic>.from(s as Map)
      ];
    });
  }

  void _addStep() {
    final nextOffset =
        _steps.isEmpty ? 0 : (_steps.map((s) => s['offset_days'] as int).reduce((a, b) => a > b ? a : b) + 3);
    setState(() => _steps.add({
          'offset_days': nextOffset,
          'action': _receivable ? 'remind_firm' : 'overdue',
          'channel': 'in_app',
        }));
  }

  Map<String, dynamic> _buildDebt() => {
        if (widget.debt?['id'] != null) 'id': widget.debt!['id'],
        'kind': widget.kind,
        'party': _party.text.trim(),
        'amount_poisha': takaToPoisha(_amount.text),
        'paid_poisha': takaToPoisha(_paid.text),
        if (_dueDate != null) 'due_date': iso(_dueDate!),
        'recurring_days': int.tryParse(_recurring.text.trim()) ?? 0,
        'paused': widget.debt?['paused'] == true,
      };

  Map<String, dynamic> _buildLadder() => {
        if (widget.ladder?['id'] != null) 'id': widget.ladder!['id'],
        'kind': widget.kind,
        'stop_on_payment': _stopOnPayment,
        'has_payment_key': widget.ladder?['has_payment_key'] == true,
        'steps': [
          for (final s in _steps)
            {
              'offset_days': s['offset_days'],
              'action': s['action'],
              'channel': s['channel'],
            }
        ],
      };

  void _save() {
    final debt = _buildDebt();
    final ladder = _buildLadder();
    final valid = _party.text.trim().isNotEmpty &&
        takaToPoisha(_amount.text) > 0 &&
        validateLadder(ladder).isEmpty;
    if (!valid) {
      setState(() => _showError = true);
      return;
    }
    Navigator.pop(context, {'debt': debt, 'ladder': ladder});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.96,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: Gap.md),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.pill)),
              ),
            ),
            Text(widget.debt == null ? t.plNewLadder : t.plEditLadder,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.lg),

            // Party
            TextField(
              controller: _party,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: t.plParty,
                hintText: _receivable ? t.plPartyHintReceivable : t.plPartyHintPayable,
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: Gap.md),

            // Amount + paid
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: t.plAmount,
                    hintText: t.plAmountHint,
                    prefixIcon: const Icon(Icons.payments_rounded),
                  ),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: TextField(
                  controller: _paid,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t.plPaid),
                ),
              ),
            ]),
            const SizedBox(height: Gap.md),

            // Due date
            InkWell(
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _dueDate ?? now,
                  firstDate: DateTime(now.year - 2),
                  lastDate: DateTime(now.year + 5),
                );
                if (picked != null) setState(() => _dueDate = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: t.plDueDate,
                  prefixIcon: const Icon(Icons.event_rounded),
                ),
                child: Text(_dueDate != null ? iso(_dueDate!) : t.plPickDate),
              ),
            ),
            const SizedBox(height: Gap.md),

            // Recurring (payable bills)
            if (!_receivable)
              TextField(
                controller: _recurring,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.plRecurring,
                  hintText: t.plRecurringHint,
                  prefixIcon: const Icon(Icons.repeat_rounded),
                ),
              ),
            if (!_receivable) const SizedBox(height: Gap.md),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _stopOnPayment,
              onChanged: (v) => setState(() => _stopOnPayment = v),
              title: Text(t.plStopOnPayment),
            ),

            const Divider(height: Gap.xl),

            // Steps
            Row(children: [
              Expanded(
                child: Text(t.plSteps,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: _useDefault,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(t.plUseDefault),
              ),
            ]),
            const SizedBox(height: Gap.sm),

            for (var i = 0; i < _steps.length; i++) _stepEditor(t, i),

            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              onPressed: _addStep,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.plAddStep),
            ),

            if (_showError) ...[
              const SizedBox(height: Gap.md),
              Text(t.plValidation, style: TextStyle(color: cs.error)),
            ],

            const SizedBox(height: Gap.lg),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(t.plSave),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.plFooterHint,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline)),
          ],
        ),
      ),
    );
  }

  Widget _stepEditor(AppLocalizations t, int i) {
    final s = _steps[i];
    final offset = s['offset_days'] as int;
    final actions = actionsFor(widget.kind);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(actionIcon('${s['action']}'),
                size: 18, color: actionTint('${s['action']}')),
            const SizedBox(width: Gap.sm),
            Text(t.plStepN(fmtInt(context, i + 1)),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_steps.length > 1)
              IconButton(
                tooltip: t.plRemoveStep,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => setState(() => _steps.removeAt(i)),
              ),
          ]),
          // Timing — a slider over day offsets; label shows before/on/after.
          Text('${t.plOffsetDays}:  ${offsetLabel(t, context, offset)}',
              style: Theme.of(context).textTheme.bodyMedium),
          Slider(
            value: offset.toDouble().clamp(-14, 60),
            min: _receivable ? 0 : -14,
            max: 60,
            divisions: _receivable ? 60 : 74,
            label: offsetLabel(t, context, offset),
            onChanged: (v) => setState(() => _steps[i]['offset_days'] = v.round()),
          ),
          // Action
          DropdownButtonFormField<String>(
            initialValue: actions.contains(s['action']) ? '${s['action']}' : actions.first,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.plActionLabel),
            items: [
              for (final a in actions)
                DropdownMenuItem(value: a, child: Text(actionLabel(t, a)))
            ],
            onChanged: (v) => setState(() => _steps[i]['action'] = v),
          ),
          const SizedBox(height: Gap.sm),
          // Channel
          DropdownButtonFormField<String>(
            initialValue: kChannels.contains(s['channel']) ? '${s['channel']}' : 'in_app',
            isExpanded: true,
            decoration: InputDecoration(labelText: t.plChannel),
            items: [
              for (final c in kChannels)
                DropdownMenuItem(
                  value: c,
                  child: Row(children: [
                    Icon(channelIcon(c), size: 16),
                    const SizedBox(width: Gap.sm),
                    Flexible(child: Text(channelLabel(t, c))),
                  ]),
                )
            ],
            onChanged: (v) => setState(() => _steps[i]['channel'] = v),
          ),
        ]),
      ),
    );
  }
}
