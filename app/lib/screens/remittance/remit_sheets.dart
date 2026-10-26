import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'remit_source.dart';
import 'remit_widgets.dart';

/// budget-remittance bottom sheets: the family budget plan, one spending,
/// the savings goal, a bill, the expected monthly money, and the My Circle
/// member picker for a user-initiated share. Every sheet returns its values;
/// the screen does the server call (and the offline queue).

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
    child: child,
  ),
);

String? _moneyRule(AppLocalizations t, String? v, {bool allowZero = false}) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return allowZero ? null : t.rmtErrAmount;
  final d = double.tryParse(s.replaceAll(',', ''));
  if (d == null || d < 0 || (!allowZero && d == 0) || d > 100000000) return t.rmtErrAmount;
  return null;
}

class _SheetFrame extends StatelessWidget {
  final String title;
  final String? body;
  final List<Widget> children;
  final String saveLabel;
  final VoidCallback onSave;
  final GlobalKey<FormState> form;
  const _SheetFrame({
    required this.title,
    this.body,
    required this.children,
    required this.saveLabel,
    required this.onSave,
    required this.form,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Form(
      key: form,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        children: [
          Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          if (body != null) ...[const SizedBox(height: Gap.xs), Text(body!)],
          const SizedBox(height: Gap.md),
          ...children,
          const SizedBox(height: Gap.md),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => Navigator.pop(context),
                child: Text(t.cancel),
              ),
              FilledButton(
                key: const ValueKey('rmt_sheet_save'),
                style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                onPressed: onSave,
                child: Text(saveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The plan: one amount per category -> {key: "amount"} ("0" removes).
Future<Map<String, String>?> showPlanSheet(BuildContext context, Map<String, double> current) {
  return _sheet(context, _PlanSheet(current: current));
}

class _PlanSheet extends StatefulWidget {
  final Map<String, double> current;
  const _PlanSheet({required this.current});
  @override
  State<_PlanSheet> createState() => _PlanSheetState();
}

class _PlanSheetState extends State<_PlanSheet> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    for (final k in kRmCategories)
      k: TextEditingController(text: (widget.current[k] ?? 0) > 0 ? rmPlain(widget.current[k]!) : ''),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: t.rmtPlanEditTitle,
      body: t.rmtPlanEditBody,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, {
          for (final e in _c.entries) e.key: e.value.text.trim().isEmpty ? '0' : e.value.text.trim(),
        });
      },
      children: [
        for (final k in kRmCategories)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: TextFormField(
              key: ValueKey('rmt_plan_$k'),
              controller: _c[k],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: rmCategory(t, k), prefixIcon: Icon(rmCategoryIcon(k))),
              validator: (v) => _moneyRule(t, v, allowZero: true),
            ),
          ),
      ],
    );
  }
}

/// One spending: {category, amount, note}.
Future<Map<String, String>?> showSpendSheet(BuildContext context, {String category = 'food'}) =>
    _sheet(context, _SpendSheet(category: category));

class _SpendSheet extends StatefulWidget {
  final String category;
  const _SpendSheet({required this.category});
  @override
  State<_SpendSheet> createState() => _SpendSheetState();
}

class _SpendSheetState extends State<_SpendSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  late String _cat = widget.category;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: t.rmtSpendTitle,
      body: t.rmtSpendBody,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, {'category': _cat, 'amount': _amount.text.trim(), 'note': _note.text.trim()});
      },
      children: [
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          children: [
            for (final k in kRmCategories)
              ChoiceChip(
                key: ValueKey('rmt_spend_$k'),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                avatar: Icon(rmCategoryIcon(k), size: 18),
                label: Text(rmCategory(t, k)),
                selected: _cat == k,
                onSelected: (_) => setState(() => _cat = k),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        TextFormField(
          key: const ValueKey('rmt_spend_amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.rmtFieldAmountTaka),
          validator: (v) => _moneyRule(t, v),
        ),
        const SizedBox(height: Gap.sm),
        TextFormField(
          controller: _note,
          maxLength: 200,
          decoration: InputDecoration(labelText: t.rmtFieldNote),
        ),
      ],
    );
  }
}

/// A single amount (add to savings): returns the amount string.
Future<String?> showAmountSheet(BuildContext context, {required String title, String? body}) =>
    _sheet(context, _AmountSheet(title: title, body: body));

class _AmountSheet extends StatefulWidget {
  final String title;
  final String? body;
  const _AmountSheet({required this.title, this.body});
  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: widget.title,
      body: widget.body,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, _amount.text.trim());
      },
      children: [
        TextFormField(
          key: const ValueKey('rmt_amount_only'),
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.rmtFieldAmountTaka),
          validator: (v) => _moneyRule(t, v),
        ),
      ],
    );
  }
}

/// The savings goal: {title, target}.
Future<Map<String, String>?> showGoalSheet(BuildContext context, {Map<String, dynamic>? goal}) =>
    _sheet(context, _GoalSheet(goal: goal));

class _GoalSheet extends StatefulWidget {
  final Map<String, dynamic>? goal;
  const _GoalSheet({this.goal});
  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: '${widget.goal?['title'] ?? ''}');
  late final _target = TextEditingController(text: widget.goal == null ? '' : rmPlain(rmNum(widget.goal!['target'])));

  @override
  void dispose() {
    _title.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: t.rmtGoalSetTitle,
      body: t.rmtGoalSetBody,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, {'title': _title.text.trim(), 'target': _target.text.trim()});
      },
      children: [
        TextFormField(
          key: const ValueKey('rmt_goal_title'),
          controller: _title,
          maxLength: 120,
          decoration: InputDecoration(labelText: t.rmtGoalName, hintText: t.rmtGoalNameHint),
        ),
        TextFormField(
          key: const ValueKey('rmt_goal_target'),
          controller: _target,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.rmtGoalTarget),
          validator: (v) => _moneyRule(t, v),
        ),
      ],
    );
  }
}

/// A bill paid from the remittance: {name, amount, due_day, category}.
Future<Map<String, dynamic>?> showBillSheet(BuildContext context, {Map<String, dynamic>? bill}) =>
    _sheet(context, _BillSheet(bill: bill));

class _BillSheet extends StatefulWidget {
  final Map<String, dynamic>? bill;
  const _BillSheet({this.bill});
  @override
  State<_BillSheet> createState() => _BillSheetState();
}

class _BillSheetState extends State<_BillSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: '${widget.bill?['name'] ?? ''}');
  late final _amount = TextEditingController(text: widget.bill == null ? '' : rmPlain(rmNum(widget.bill!['amount'])));
  late final _day = TextEditingController(text: '${widget.bill?['due_day'] ?? ''}');
  late String _cat = '${widget.bill?['category'] ?? 'other'}';

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _day.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: widget.bill == null ? t.rmtBillAddTitle : t.rmtBillEditTitle,
      body: t.rmtBillBody,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, {
          'name': _name.text.trim(),
          'amount': _amount.text.trim(),
          'due_day': int.tryParse(_day.text.trim()) ?? 1,
          'category': _cat,
        });
      },
      children: [
        TextFormField(
          key: const ValueKey('rmt_bill_name'),
          controller: _name,
          maxLength: 60,
          decoration: InputDecoration(labelText: t.rmtBillName, hintText: t.rmtBillNameHint),
          validator: (v) => (v ?? '').trim().isEmpty ? t.rmtErrBillName : null,
        ),
        TextFormField(
          key: const ValueKey('rmt_bill_amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.rmtFieldAmountTaka),
          validator: (v) => _moneyRule(t, v),
        ),
        const SizedBox(height: Gap.sm),
        TextFormField(
          key: const ValueKey('rmt_bill_day'),
          controller: _day,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t.rmtBillDueDay, helperText: t.rmtDayHelp),
          validator: (v) {
            final d = int.tryParse((v ?? '').trim());
            return d == null || d < 1 || d > 31 ? t.rmtErrDay : null;
          },
        ),
        const SizedBox(height: Gap.sm),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          children: [
            for (final k in kRmCategories)
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(rmCategory(t, k)),
                selected: _cat == k,
                onSelected: (_) => setState(() => _cat = k),
              ),
          ],
        ),
      ],
    );
  }
}

/// The money expected every month: {expected_taka, expected_day, expected_sender}.
Future<Map<String, dynamic>?> showExpectedSheet(BuildContext context, Map<String, dynamic> expected) =>
    _sheet(context, _ExpectedSheet(expected: expected));

class _ExpectedSheet extends StatefulWidget {
  final Map<String, dynamic> expected;
  const _ExpectedSheet({required this.expected});
  @override
  State<_ExpectedSheet> createState() => _ExpectedSheetState();
}

class _ExpectedSheetState extends State<_ExpectedSheet> {
  final _form = GlobalKey<FormState>();
  late final _taka = TextEditingController(
    text: rmNum(widget.expected['taka']) > 0 ? rmPlain(rmNum(widget.expected['taka'])) : '',
  );
  late final _day = TextEditingController(
    text: (int.tryParse('${widget.expected['day'] ?? 0}') ?? 0) > 0 ? '${widget.expected['day']}' : '',
  );
  late final _sender = TextEditingController(text: '${widget.expected['sender'] ?? ''}');

  @override
  void dispose() {
    _taka.dispose();
    _day.dispose();
    _sender.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _SheetFrame(
      form: _form,
      title: t.rmtExpectedTitle,
      body: t.rmtExpectedBody,
      saveLabel: t.rmtSave,
      onSave: () {
        if (!(_form.currentState?.validate() ?? false)) return;
        Navigator.pop(context, {
          'expected_taka': _taka.text.trim().isEmpty ? '0' : _taka.text.trim(),
          'expected_day': int.tryParse(_day.text.trim()) ?? 0,
          'expected_sender': _sender.text.trim(),
        });
      },
      children: [
        TextFormField(
          key: const ValueKey('rmt_exp_taka'),
          controller: _taka,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.rmtExpectedAmount, helperText: t.rmtExpectedOffHelp),
          validator: (v) => _moneyRule(t, v, allowZero: true),
        ),
        const SizedBox(height: Gap.sm),
        TextFormField(
          key: const ValueKey('rmt_exp_day'),
          controller: _day,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t.rmtExpectedDay, helperText: t.rmtDayHelp),
          validator: (v) {
            if ((v ?? '').trim().isEmpty) return rmNum(_taka.text) > 0 ? t.rmtErrDay : null;
            final d = int.tryParse((v ?? '').trim());
            return d == null || d < 1 || d > 31 ? t.rmtErrDay : null;
          },
        ),
        const SizedBox(height: Gap.sm),
        TextFormField(
          controller: _sender,
          maxLength: 80,
          decoration: InputDecoration(labelText: t.rmtExpectedFrom),
        ),
      ],
    );
  }
}

/// Pick ONE My Circle member to share the report with.
Future<Map<String, dynamic>?> showMemberPicker(BuildContext context, List<Map<String, dynamic>> members) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) {
      final t = AppLocalizations.of(c);
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: Gap.lg),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Semantics(header: true, child: Text(t.rmtShareWho, style: Theme.of(c).textTheme.titleLarge)),
          ),
          if (members.isEmpty) Padding(padding: const EdgeInsets.all(Gap.lg), child: Text(t.rmtShareNoMembers)),
          for (final m in members)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline_rounded)),
              title: Text('${m['name'] ?? ''}'),
              onTap: () => Navigator.pop(c, m),
            ),
        ],
      );
    },
  );
}

/// "Are you sure?" with the danger button.
Future<bool> rmConfirm(BuildContext context, String title, String body, String yes) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
        FilledButton(
          key: const ValueKey('rmt_confirm_yes'),
          style: Brand.dangerButton(),
          onPressed: () => Navigator.pop(c, true),
          child: Text(yes),
        ),
      ],
    ),
  );
  return ok == true;
}
