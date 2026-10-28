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

/// Add or edit a budget. Pass [initial] to pre-fill for editing; the category
/// field is then read-only (a budget is keyed by its category).
Future<BudgetInput?> showBudgetSheet(BuildContext context,
    {Map<String, dynamic>? initial}) {
  final t = AppLocalizations.of(context);
  final editing = initial != null;
  final cat = TextEditingController(text: initial?['category']?.toString() ?? '');
  final lim = TextEditingController(
      text: initial == null ? '' : _plain(initial['monthly_limit']));
  bool rollover = initial?['rollover'] == true;
  return showDialog<BudgetInput>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(editing ? t.budgetEdit : t.budgetNew),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: cat,
            enabled: !editing,
            decoration: InputDecoration(labelText: t.budgetFieldCategory),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: lim,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.budgetFieldLimit, prefixText: '৳ '),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: rollover,
            title: Text(t.budgetRollover),
            subtitle: Text(t.budgetRolloverHint),
            onChanged: (v) => setD(() => rollover = v),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
          FilledButton(
            onPressed: () {
              final c = cat.text.trim();
              final l = lim.text.trim();
              if (c.isEmpty || dbl(l) <= 0) return;
              Navigator.pop(ctx, BudgetInput(c, l, rollover));
            },
            child: Text(t.save),
          ),
        ],
      ),
    ),
  );
}

/// The 50-30-20 template sheet: enter a monthly income, preview needs/wants/
/// savings (fetched from the server so the split is residue-free), then
/// "Apply". Returns the income string when the user applies; null otherwise.
/// [fetchTemplate] hits BudgetApi.budgetTemplate — kept as a callback so this
/// widget needs no ApiClient import.
Future<String?> showTemplateSheet(
  BuildContext context, {
  required Future<Map<String, dynamic>> Function(String income) fetchTemplate,
}) {
  final t = AppLocalizations.of(context);
  final income = TextEditingController();
  Map<String, dynamic>? preview;
  bool busy = false;

  String _label(String bucket) {
    switch (bucket) {
      case 'needs':
        return t.budgetBucketNeeds;
      case 'wants':
        return t.budgetBucketWants;
      default:
        return t.budgetBucketSavings;
    }
  }

  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => Padding(
        padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            top: Gap.lg,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.budgetTemplateTitle,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: Gap.xs),
          Text(t.budgetTemplateBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: income,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.budgetTemplateIncome, prefixText: '৳ '),
            onChanged: (_) async {
              if (dbl(income.text) <= 0) {
                setD(() => preview = null);
                return;
              }
              setD(() => busy = true);
              try {
                final r = await fetchTemplate(income.text.trim());
                setD(() {
                  preview = r;
                  busy = false;
                });
              } catch (_) {
                setD(() => busy = false);
              }
            },
          ),
          const SizedBox(height: Gap.md),
          if (busy) const LinearProgressIndicator(),
          if (preview != null)
            for (final b
                in (preview!['buckets'] as List? ?? []).cast<Map>())
              ListTile(
                dense: true,
                leading: const Icon(Icons.pie_chart_outline_rounded),
                title: Text('${_label(b['bucket']?.toString() ?? '')}'
                    ' · ${b['percent']}%'),
                trailing: Text(tkFmt(b['amount']),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: preview == null
                  ? null
                  : () => Navigator.pop(ctx, income.text.trim()),
              child: Text(t.budgetTemplateApply),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Strip a server money string back to a plain editable number (drops any
/// trailing ".00" noise would be surprising in an edit field, so keep as-is).
String _plain(dynamic v) {
  final s = '${v ?? ''}';
  return s;
}
