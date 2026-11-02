import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../screens/money_common.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Input sheets for the BUDGET module (#50): the add/edit budget dialog and the
/// 50-30-20 template sheet. These are PRESENTATIONAL — they collect values and
/// return them; the screen owns persistence (the SyncedRepo call) so the
/// widgets stay free of app-state coupling.

/// Result of the add/edit budget dialog.
class BudgetInput {
  final String category;
  final String monthlyLimit;
  final bool rollover;
  const BudgetInput(this.category, this.monthlyLimit, this.rollover);
}

/// The family category keys every budget picker offers (shown in the UI
/// language via [moneyCatLabel]; the same keys Budget and Remittance writes).
const kBudgetFamilyKeys = ['food', 'rent', 'education', 'health', 'loan', 'other'];

/// remhbud: the categories to offer as one-tap chips — the ones the user
/// ACTUALLY wrote on expenses first (most used first, so the budget matches
/// their spending exactly), then the family keys; no duplicates (a typed
/// "Food" and the key "food" are one chip), minus the ones already budgeted.
List<String> budgetCategoryChoices(Iterable<Map> txns, {Iterable<String> taken = const []}) {
  final count = <String, int>{};
  for (final it in txns) {
    final d = it['data'] is Map ? it['data'] as Map : it;
    if ('${d['kind'] ?? 'expense'}' != 'expense') continue;
    final c = '${d['category'] ?? ''}'.trim();
    if (c.isEmpty) continue;
    count[c] = (count[c] ?? 0) + 1;
  }
  final used = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
  final seen = <String>{for (final x in taken) x.trim().toLowerCase()};
  final out = <String>[];
  for (final c in [...used.take(8), ...kBudgetFamilyKeys]) {
    if (seen.add(c.toLowerCase())) out.add(c);
  }
  return out;
}

/// Add or edit a budget. Pass [initial] to pre-fill for editing; the category
/// is then fixed (a budget is keyed by its category). [choices] are one-tap
/// category chips (see [budgetCategoryChoices]); a custom name can be typed.
/// remhbud: a bottom sheet (above the nav bar), Bangla digits accepted, and
/// Save says what is missing instead of silently doing nothing.
Future<BudgetInput?> showBudgetSheet(BuildContext context,
    {Map<String, dynamic>? initial, List<String> choices = const []}) {
  return showAppSheet<BudgetInput>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _BudgetSheet(initial: initial, choices: choices),
    ),
  );
}

class _BudgetSheet extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final List<String> choices;
  const _BudgetSheet({this.initial, this.choices = const []});
  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late final bool _editing = widget.initial != null && '${widget.initial!['category'] ?? ''}'.isNotEmpty;
  late String _cat = '${widget.initial?['category'] ?? ''}';
  late final _custom = TextEditingController(
      text: _editing || widget.choices.contains(_cat) ? '' : _cat);
  late final _lim = TextEditingController(
      text: widget.initial == null ? '' : _plain(widget.initial!['monthly_limit']));
  late bool _rollover = widget.initial?['rollover'] == true;
  String? _catErr, _limErr;

  @override
  void dispose() {
    _custom.dispose();
    _lim.dispose();
    super.dispose();
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final c = _editing ? _cat : (_custom.text.trim().isNotEmpty ? _custom.text.trim() : _cat);
    final l = moneyAscii(_lim.text);
    setState(() {
      _catErr = c.isEmpty ? t.rhbErrCategory : null;
      _limErr = (double.tryParse(l) ?? 0) <= 0 ? t.rhbErrLimit : null;
    });
    if (_catErr != null || _limErr != null) return;
    Navigator.pop(context, BudgetInput(c, l, _rollover));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      children: [
        Semantics(
          header: true,
          child: Text(_editing ? t.budgetEdit : t.budgetNew,
              style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: Gap.md),
        Text(t.budgetFieldCategory, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        if (_editing)
          Text(moneyCatLabel(t, _cat), style: const TextStyle(fontWeight: FontWeight.w700))
        else ...[
          if (widget.choices.isNotEmpty)
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                for (final c in widget.choices)
                  ChoiceChip(
                    key: ValueKey('rhb_cat_$c'),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(moneyCatLabel(t, c)),
                    selected: _cat == c && _custom.text.trim().isEmpty,
                    onSelected: (_) => setState(() {
                      _cat = c;
                      _custom.clear();
                      _catErr = null;
                    }),
                  ),
              ],
            ),
          TextField(
            key: const ValueKey('rhb_cat_custom'),
            controller: _custom,
            maxLength: 40,
            onChanged: (_) => setState(() => _catErr = null),
            decoration: InputDecoration(
              labelText: widget.choices.isEmpty ? t.budgetFieldCategory : t.rhbCategoryOther,
              helperText: t.rhbCategoryHelp,
              helperMaxLines: 3,
              errorText: _catErr,
              errorMaxLines: 2,
            ),
          ),
        ],
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('rhb_limit'),
          controller: _lim,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) {
            if (_limErr != null) setState(() => _limErr = null);
          },
          decoration: InputDecoration(
            labelText: t.budgetFieldLimit,
            prefixText: '\u09F3 ',
            errorText: _limErr,
            errorMaxLines: 2,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _rollover,
          title: Text(t.budgetRollover),
          subtitle: Text(t.budgetRolloverHint, style: TextStyle(color: scheme.onSurfaceVariant)),
          onChanged: (v) => setState(() => _rollover = v),
        ),
        const SizedBox(height: Gap.sm),
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
              key: const ValueKey('rhb_budget_save'),
              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: _save,
              child: Text(t.save),
            ),
          ],
        ),
      ],
    );
  }
}

/// The 50-30-20 template sheet: enter a monthly income, preview needs/wants/
/// savings (fetched from the server so the split is residue-free).
/// remhbud: this is a GUIDE — it creates nothing. The old "Apply template"
/// button closed the sheet and did nothing (a showpiece); now the sheet says
/// honestly how to use the numbers (set category limits with +) and its one
/// button is "Close". Amounts and percents in the UI digits; Bangla digits
/// accepted; a failed fetch says so. [fetchTemplate] hits
/// BudgetApi.budgetTemplate — a callback so this widget needs no ApiClient.
Future<void> showTemplateSheet(
  BuildContext context, {
  required Future<Map<String, dynamic>> Function(String income) fetchTemplate,
}) {
  final t = AppLocalizations.of(context);
  final income = TextEditingController();
  Map<String, dynamic>? preview;
  bool busy = false;
  bool failed = false;
  int seq = 0;

  String label(String bucket) {
    switch (bucket) {
      case 'needs':
        return t.budgetBucketNeeds;
      case 'wants':
        return t.budgetBucketWants;
      default:
        return t.budgetBucketSavings;
    }
  }

  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          children: [
            Semantics(
              header: true,
              child: Text(t.budgetTemplateTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.titleLarge),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.budgetTemplateBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('rhb_tpl_income'),
              controller: income,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t.budgetTemplateIncome,
                  prefixText: '\u09F3 ',
                  errorText: failed ? t.budgetOffline : null,
                  errorMaxLines: 3),
              onChanged: (_) async {
                final v = moneyAscii(income.text);
                final my = ++seq;
                if ((double.tryParse(v) ?? 0) <= 0) {
                  setD(() {
                    preview = null;
                    failed = false;
                  });
                  return;
                }
                setD(() => busy = true);
                try {
                  final r = await fetchTemplate(v);
                  if (my != seq) return; // a newer keystroke is in flight
                  setD(() {
                    preview = r;
                    busy = false;
                    failed = false;
                  });
                } catch (_) {
                  if (my != seq) return;
                  setD(() {
                    busy = false;
                    failed = true;
                  });
                }
              },
            ),
            const SizedBox(height: Gap.md),
            if (busy) const LinearProgressIndicator(),
            if (preview != null) ...[
              for (final b in (preview!['buckets'] as List? ?? []).cast<Map>())
                MergeSemantics(
                  child: ListTile(
                    leading: const Icon(Icons.pie_chart_outline_rounded),
                    title: Text('${label(b['bucket']?.toString() ?? '')}'
                        ' · ${pctOf(ctx, b['percent'])}'),
                    trailing: Text(tkOf(ctx, b['amount']),
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular)),
                  ),
                ),
              const SizedBox(height: Gap.xs),
              Text(t.rhbTemplateHow,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('rhb_tpl_close'),
                style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.close),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// remhbud: a new savings goal (title + target) from the Budget page, so "no
/// goal yet" is never a dead end. Returns null when cancelled.
class GoalDraft {
  final String title;
  final String target;
  const GoalDraft(this.title, this.target);
}

Future<GoalDraft?> showGoalCreateSheet(BuildContext context) => showAppSheet<GoalDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: const _GoalSheet(),
      ),
    );

class _GoalSheet extends StatefulWidget {
  const _GoalSheet();
  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  final _title = TextEditingController();
  final _target = TextEditingController();
  String? _titleErr, _targetErr;

  @override
  void dispose() {
    _title.dispose();
    _target.dispose();
    super.dispose();
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final v = moneyAscii(_target.text);
    setState(() {
      _titleErr = _title.text.trim().isEmpty ? t.rhbErrGoalTitle : null;
      _targetErr = (double.tryParse(v) ?? 0) <= 0 ? t.rhbErrLimit : null;
    });
    if (_titleErr != null || _targetErr != null) return;
    Navigator.pop(context, GoalDraft(_title.text.trim(), v));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      children: [
        Semantics(
          header: true,
          child: Text(t.rhbGoalCreate, style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.rhbGoalWhy),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('rhb_goal_title'),
          controller: _title,
          maxLength: 80,
          decoration: InputDecoration(
              labelText: t.moneyFieldGoalPurpose, errorText: _titleErr, errorMaxLines: 2),
        ),
        TextField(
          key: const ValueKey('rhb_goal_target'),
          controller: _target,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: t.moneyFieldTargetTaka,
              prefixText: '\u09F3 ',
              errorText: _targetErr,
              errorMaxLines: 2),
        ),
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
              key: const ValueKey('rhb_goal_save'),
              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: _save,
              child: Text(t.save),
            ),
          ],
        ),
      ],
    );
  }
}

/// Strip a server money string back to a plain editable number (drops any
/// trailing ".00" noise would be surprising in an edit field, so keep as-is).
String _plain(dynamic v) {
  final s = '${v ?? ''}';
  return s;
}
