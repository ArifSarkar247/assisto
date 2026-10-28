import 'package:flutter/material.dart';
import '../theme.dart';
import '../famacct_api.dart';
import '../l10n/app_localizations.dart';

/// Dialogs for FAMILY ACCOUNTING (#61, SPEC v2.1 §21): add-expense (payer +
/// amount + category + split mode + member picker), a single-amount sheet
/// (pool target / contribute), and a member picker. All amounts are parsed to
/// INTEGER POISHA via FamAcctLocal.takaToPoisha — the UI never holds a float.
///
/// The returned expense body matches the POST contract in famacct_api.dart:
///   {payer, total_poisha, category, note, mode, members:[id] | parts:[...]}

const _billCategories = ['rent', 'utility', 'groceries', 'internet',
    'transport', 'health', 'education', 'other'];

const Map<String, List<String>> _catLabels = {
  // slug: [bn, en] — kept in sync with famacct_engine.BILL_CATEGORIES. \u only.
  'rent': ['\u09AC\u09BE\u09B8\u09BE \u09AD\u09BE\u09A1\u09BC\u09BE', 'Rent'],
  'utility': ['\u0987\u0989\u099F\u09BF\u09B2\u09BF\u099F\u09BF \u09AC\u09BF\u09B2', 'Utilities'],
  'groceries': ['\u09AC\u09BE\u099C\u09BE\u09B0', 'Groceries'],
  'internet': ['\u0987\u09A8\u09CD\u099F\u09BE\u09B0\u09A8\u09C7\u099F', 'Internet'],
  'transport': ['\u09AF\u09BE\u09A4\u09BE\u09AF\u09BC\u09BE\u09A4', 'Transport'],
  'health': ['\u09B8\u09CD\u09AC\u09BE\u09B8\u09CD\u09A5\u09CD\u09AF', 'Health'],
  'education': ['\u09B6\u09BF\u0995\u09CD\u09B7\u09BE', 'Education'],
  'other': ['\u0985\u09A8\u09CD\u09AF\u09BE\u09A8\u09CD\u09AF', 'Other'],
};

String _catLabel(BuildContext c, String slug) {
  final pair = _catLabels[slug];
  if (pair == null) return slug;
  return Localizations.localeOf(c).languageCode == 'bn' ? pair[0] : pair[1];
}

/// Returns a POST body for famAcctAddExpense, or null if cancelled.
Future<Map<String, dynamic>?> showAddExpenseSheet(
    BuildContext context, List<Map<String, dynamic>> members) {
  final amount = TextEditingController();
  final note = TextEditingController();
  // payer/participant ids: 'self' plus each family member id.
  final pickable = <Map<String, dynamic>>[
    {'id': 'self', 'name': AppLocalizations.of(context).medForSelf},
    ...members.map((m) => {'id': m['id'], 'name': (m['name'] ?? '').toString()}),
  ];
  dynamic payer = pickable.first['id'];
  String category = 'groceries';
  String mode = 'equal';
  final selected = <dynamic>{for (final p in pickable) p['id']}; // default: all

  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(AppLocalizations.of(context).faAddExpense),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<dynamic>(
              initialValue: payer,
              decoration: InputDecoration(labelText: AppLocalizations.of(context).faPayer),
              items: [
                for (final p in pickable)
                  DropdownMenuItem(value: p['id'], child: Text(p['name'])),
              ],
              onChanged: (v) => setD(() => payer = v),
            ),
            TextField(
              controller: amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: AppLocalizations.of(context).faAmount),
            ),
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration:
                  InputDecoration(labelText: AppLocalizations.of(context).faCategory),
              items: [
                for (final slug in _billCategories)
                  DropdownMenuItem(
                      value: slug, child: Text(_catLabel(context, slug))),
              ],
              onChanged: (v) => setD(() => category = v ?? 'other'),
            ),
            TextField(
              controller: note,
              decoration: InputDecoration(labelText: AppLocalizations.of(context).faNote),
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(AppLocalizations.of(context).faSplitMode,
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'equal',
                    label: Text(AppLocalizations.of(context).faSplitEqual)),
                ButtonSegment(
                    value: 'exact',
                    label: Text(AppLocalizations.of(context).faSplitExact)),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setD(() => mode = s.first),
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(AppLocalizations.of(context).faSplitAmong,
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            for (final p in pickable)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: selected.contains(p['id']),
                title: Text(p['name']),
                onChanged: (v) => setD(() {
                  if (v == true) {
                    selected.add(p['id']);
                  } else {
                    selected.remove(p['id']);
                  }
                }),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(
            onPressed: () {
              final total = FamAcctLocal.takaToPoisha(amount.text);
              if (total <= 0 || selected.isEmpty) return;
              final body = <String, dynamic>{
                'payer': payer,
                'total_poisha': total,
                'category': category,
                'note': note.text.trim(),
                'mode': mode,
                'shared': true,
              };
              if (mode == 'exact') {
                // Exact mode: split the total equally as a sane default across
                // the selected members (the per-head exact UI is a later pass);
                // integer-poisha remainder still lands exactly.
                final ids = selected.toList();
                final split = FamAcctLocal.splitEqual(total, ids.length);
                body['parts'] = [
                  for (var i = 0; i < ids.length; i++)
                    {'member': ids[i], 'amount_poisha': split[i]}
                ];
              } else {
                body['members'] = selected.toList();
              }
              Navigator.pop(ctx, body);
            },
            child: Text(AppLocalizations.of(context).save),
          ),
        ],
      ),
    ),
  );
}

/// Single taka amount -> INTEGER poisha (pool target / contribution). null if
/// cancelled or non-positive.
Future<int?> showAmountSheet(BuildContext context, String title) {
  final ctrl = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: AppLocalizations.of(context).faAmount),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(
          onPressed: () {
            final p = FamAcctLocal.takaToPoisha(ctrl.text);
            if (p <= 0) return;
            Navigator.pop(ctx, p);
          },
          child: Text(AppLocalizations.of(context).save),
        ),
      ],
    ),
  );
}

/// Pick one member (returns the id: 'self' or a family member id). null if
/// cancelled.
Future<dynamic> showMemberPicker(
    BuildContext context, List<Map<String, dynamic>> members) {
  final pickable = <Map<String, dynamic>>[
    {'id': 'self', 'name': AppLocalizations.of(context).medForSelf},
    ...members.map((m) => {'id': m['id'], 'name': (m['name'] ?? '').toString()}),
  ];
  return showDialog<dynamic>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(AppLocalizations.of(context).faPayer),
      children: [
        for (final p in pickable)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p['id']),
            child: Text(p['name']),
          ),
      ],
    ),
  );
}
