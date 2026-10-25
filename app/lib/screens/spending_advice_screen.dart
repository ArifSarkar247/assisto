import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2
// qa1: the insight engine builds Latin-digit strings; show them in the UI's digits.
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// AI SPENDING ADVICE — ADVANCED (#51, SPEC v2.1 §21).
///
/// Deterministic, rule-based OBSERVATIONS over the user's OWN summarised
/// category totals — NEVER financial advice. The user enters category totals
/// (and, optionally, a monthly budget per category + the previous month's
/// total) and the screen computes, on-device:
///
///   * top category + its share of spend
///   * big-share flag when one category dominates (≥30%)
///   * month-over-month change on total spend (only with real previous data)
///   * the biggest mover category
///   * overspend flags vs the budgets the USER set
///   * a neutral, factual savings pointer ("X is Y% of your spend")
///
/// Every figure is derived from numbers the user entered — we NEVER invent a
/// transaction or guess an amount. The screen always shows the honest
/// "general observations, not financial advice" disclaimer. Deeper, written
/// AI advice is a key-gated SEAM (Integrations → Anthropic / core.ai.generate):
/// shown as an honest "connect an AI key for a written summary" card, not a
/// fabricated narrative.
///
/// `_SMath` mirrors backend/core/logic/spending_advice.py VERBATIM (integer
/// poisha, half-up percents) so the numbers are identical to the backend and
/// the tests. ZERO Bangla literals — every string is an AppLocalizations
/// getter; the ৳ glyph is a currency sign (gate-exempt).
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('spending/notes') → [{id, category, amount, budget?,
///                                    previous?, note?}]
/// create/update/deleteItem on the same path; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection. `amount` is the
/// CURRENT-period total for the category; `budget` the user's own monthly
/// limit; `previous` the previous-period total for the same category (all
/// optional except amount). No live AI, no key needed to run the observations.
class SpendingAdviceScreen extends StatefulWidget {
  const SpendingAdviceScreen({super.key});
  @override
  State<SpendingAdviceScreen> createState() => _SpendingAdviceScreenState();
}

const String _notesPath = 'spending/notes';

class _SpendingAdviceScreenState extends State<SpendingAdviceScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _rows = await api.listItems(_notesPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _entrySheet(context, null);
    if (res == null) return;
    try {
      await api.createItem(_notesPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _entrySheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_notesPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(
        context, tr.spendDeleteTitle, tr.spendDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_notesPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.spendTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.spendTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.spendLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final result = _SMath.analyse(_rows);

    return Scaffold(
      appBar: AppBar(title: Text(tr.spendTitle)),
      floatingActionButton: _rows.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text(tr.spendAddCategory),
            ),
      body: _rows.isEmpty
          ? StateMessage(
              icon: Icons.insights_outlined,
              title: tr.spendWelcomeTitle,
              message: tr.spendWelcomeBody,
              action: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: Text(tr.spendAddCategory),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                // ALWAYS-ON honest disclaimer
                _disclaimerCard(context, tr),
                const SizedBox(height: Gap.md),
                if (result.enoughData) ...[
                  _totalsCard(context, tr, result),
                  const SizedBox(height: Gap.md),
                  Text(tr.spendObservations,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.sm),
                  ...result.observations
                      .map((o) => _obsCard(context, tr, o)),
                  const SizedBox(height: Gap.md),
                  Text(tr.spendByCategory,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.sm),
                  ...result.categories.map(
                      (c) => _categoryCard(context, tr, c, _edit, _delete)),
                  const SizedBox(height: Gap.md),
                  // key-gated AI seam — honest, never a fabricated narrative
                  _aiSeamCard(context, tr),
                ] else ...[
                  // entered rows exist but no positive spend yet
                  StateMessage(
                    icon: Icons.insights_outlined,
                    title: tr.spendNotEnoughTitle,
                    message: tr.spendNotEnoughBody,
                  ),
                  const SizedBox(height: Gap.md),
                  Text(tr.spendByCategory,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.sm),
                  ..._rows.map((r) => _rawRowCard(context, tr, r, _edit, _delete)),
                ],
              ],
            ),
    );
  }

  Widget _disclaimerCard(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.verified_user_outlined,
              size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.spendDisclaimer,
                style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onTertiaryContainer)),
          ),
        ]),
      ),
    );
  }

  Widget _totalsCard(
      BuildContext context, AppLocalizations tr, _SResult r) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.spendTotalSpent,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xxs),
            Text(notifLocalizeDigits(context, r.totalSpentDisplay),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800, color: scheme.primary)),
            if (r.totalDeltaDisplay != null) ...[
              const SizedBox(height: Gap.sm),
              Row(children: [
                Icon(
                    r.totalUp == true
                        ? Icons.trending_up
                        : (r.totalUp == false
                            ? Icons.trending_down
                            : Icons.trending_flat),
                    size: 18,
                    color: r.totalUp == true ? scheme.error : scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    notifLocalizeDigits(context, tr.spendVsPrevious(
                        r.totalDeltaDisplay!, r.totalDeltaPct.abs())),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _obsCard(
      BuildContext context, AppLocalizations tr, _SObservation o) {
    final scheme = Theme.of(context).colorScheme;
    final over = o.key == 'over_budget';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(over ? Icons.warning_amber_rounded : Icons.lightbulb_outline,
              size: 20, color: over ? scheme.error : scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(notifLocalizeDigits(context, _obsText(tr, o)),
                style: const TextStyle(height: 1.4)),
          ),
        ]),
      ),
    );
  }

  Widget _categoryCard(BuildContext context, AppLocalizations tr, _SCategory c,
      Future<void> Function(Map<String, dynamic>) onEdit,
      Future<void> Function(Map<String, dynamic>) onDelete) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(c.category,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            Text(notifLocalizeDigits(context, c.spentDisplay),
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.primary)),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') onEdit(c.raw);
                if (v == 'delete') onDelete(c.raw);
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (c.sharePct / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: c.overBudget ? scheme.error : scheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _chip(context, tr.spendShareChip(c.sharePct), scheme.primary),
            if (c.budgetDisplay != null)
              _chip(
                  context,
                  c.overBudget
                      ? tr.spendOverBudgetChip(c.overByDisplay ?? '')
                      : tr.spendBudgetChip(c.budgetDisplay!),
                  c.overBudget ? scheme.error : scheme.onSurfaceVariant),
            if (c.deltaDisplay != null)
              _chip(
                  context,
                  tr.spendChangeChip(c.deltaDisplay!, c.deltaPct.abs()),
                  c.up == true ? scheme.error : scheme.primary),
          ]),
        ]),
      ),
    );
  }

  Widget _rawRowCard(BuildContext context, AppLocalizations tr,
      Map<String, dynamic> r,
      Future<void> Function(Map<String, dynamic>) onEdit,
      Future<void> Function(Map<String, dynamic>) onDelete) {
    return Card(
      child: ListTile(
        title: Text((r['category'] ?? '').toString(),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle:
            Text(notifLocalizeDigits(context, _SMath.fmtBdt(_SMath.toMinor(r['amount'])))),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') onEdit(r);
            if (v == 'delete') onDelete(r);
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
            PopupMenuItem(value: 'delete', child: Text(tr.delete)),
          ],
        ),
      ),
    );
  }

  Widget _aiSeamCard(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.spendAiSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr.spendAiSeamBody,
              style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Text(notifLocalizeDigits(context, label),
          style: AType.bodySmall.copyWith(fontWeight: FontWeight.w600, color: color)),
    );
  }
}

String _obsText(AppLocalizations tr, _SObservation o) {
  final p = o.params;
  // args follow the generated signature (ARB metadata order), not the text order
  switch (o.key) {
    case 'top_category':
      return tr.spendObsTopCategory(
          p['amount'].toString(), p['category'].toString(), p['pct'] as int);
    case 'big_share':
      return tr.spendObsBigShare(p['category'].toString(), p['pct'] as int);
    case 'total_mom_up':
      return tr.spendObsMomUp(p['amount'].toString(), p['pct'] as int);
    case 'total_mom_down':
      return tr.spendObsMomDown(p['amount'].toString(), p['pct'] as int);
    case 'total_mom_flat':
      return tr.spendObsMomFlat;
    case 'category_mover_up':
      return tr.spendObsMoverUp(
          p['amount'].toString(), p['category'].toString(), p['pct'] as int);
    case 'category_mover_down':
      return tr.spendObsMoverDown(
          p['amount'].toString(), p['category'].toString(), p['pct'] as int);
    case 'over_budget':
      return tr.spendObsOverBudget(p['amount'].toString(),
          p['budget'].toString(), p['category'].toString());
    case 'savings_pointer':
      return tr.spendObsSavingsPointer(
          p['category'].toString(), p['pct'] as int);
    default:
      return '';
  }
}

// ---- entry sheet ------------------------------------------------------------

Future<Map<String, dynamic>?> _entrySheet(
    BuildContext context, Map<String, dynamic>? existing) {
  final tr = AppLocalizations.of(context);
  final catCtl =
      TextEditingController(text: (existing?['category'] ?? '').toString());
  final amtCtl = TextEditingController(
      text: existing?['amount'] == null ? '' : existing!['amount'].toString());
  final budgetCtl = TextEditingController(
      text: existing?['budget'] == null ? '' : existing!['budget'].toString());
  final prevCtl = TextEditingController(
      text: existing?['previous'] == null
          ? ''
          : existing!['previous'].toString());
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return Padding(
        padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            top: Gap.lg,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(existing == null ? tr.spendAddCategory : tr.spendEditCategory,
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: catCtl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.spendFieldCategory,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: amtCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr.spendFieldAmount,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: budgetCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr.spendFieldBudget,
                helperText: tr.spendFieldBudgetHelp,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: prevCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr.spendFieldPrevious,
                helperText: tr.spendFieldPreviousHelp,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Text(tr.spendEntryNote,
              style:
                  AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                final cat = catCtl.text.trim();
                if (cat.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                final out = <String, dynamic>{
                  'category': cat,
                  'amount': amtCtl.text.trim(),
                };
                if (budgetCtl.text.trim().isNotEmpty) {
                  out['budget'] = budgetCtl.text.trim();
                }
                if (prevCtl.text.trim().isNotEmpty) {
                  out['previous'] = prevCtl.text.trim();
                }
                Navigator.pop(ctx, out);
              },
              child: Text(tr.save),
            ),
          ),
        ]),
      );
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}

// =============================================================================
// _SMath — VERBATIM mirror of backend/core/logic/spending_advice.py.
// Integer poisha, half-up percents. Same inputs → same output as the backend.
// =============================================================================

class _SObservation {
  final String key;
  final Map<String, dynamic> params;
  _SObservation(this.key, this.params);
}

class _SCategory {
  final Map<String, dynamic> raw;
  final String category;
  final int spent;
  final String spentDisplay;
  final int sharePct;
  final String? deltaDisplay;
  final int deltaPct;
  final bool? up;
  final String? budgetDisplay;
  final bool overBudget;
  final String? overByDisplay;
  _SCategory(this.raw, this.category, this.spent, this.spentDisplay,
      this.sharePct, this.deltaDisplay, this.deltaPct, this.up,
      this.budgetDisplay, this.overBudget, this.overByDisplay);
}

class _SResult {
  final bool enoughData;
  final int totalSpent;
  final String totalSpentDisplay;
  final String? totalDeltaDisplay;
  final int totalDeltaPct;
  final bool? totalUp;
  final List<_SCategory> categories;
  final List<_SObservation> observations;
  _SResult(this.enoughData, this.totalSpent, this.totalSpentDisplay,
      this.totalDeltaDisplay, this.totalDeltaPct, this.totalUp,
      this.categories, this.observations);
}

class _SMath {
  static const int bigSharePct = 30;

  static int toMinor(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) return (v * 100).round();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.length > 1 ? parts[1] : '';
    } else {
      whole = s;
      frac = '';
    }
    whole = whole.isEmpty ? '0' : whole;
    frac = (frac + '00').substring(0, 3);
    final major = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (major == null || milli == null) return 0;
    var minor = major * 100 + milli ~/ 10;
    if (milli % 10 >= 5) minor += 1;
    return neg ? -minor : minor;
  }

  static String _group(int n) {
    var s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtBdt(int poisha) {
    final neg = poisha < 0;
    poisha = poisha.abs();
    final taka = poisha ~/ 100;
    final paisa = poisha % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  static int _pct(int part, int whole) {
    if (whole <= 0) return 0;
    return (part * 100 + whole ~/ 2) ~/ whole;
  }

  static List<Map<String, dynamic>> _normalise(
      List<Map<String, dynamic>> rows) {
    final agg = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      var cat = (r['category'] ?? 'uncategorized').toString().trim();
      if (cat.isEmpty) cat = 'uncategorized';
      final spent = toMinor(r['amount'] ?? r['spent']);
      final s = spent < 0 ? 0 : spent;
      final bRaw = r['budget'];
      int? budget;
      if (bRaw != null && bRaw != '') {
        final b = toMinor(bRaw);
        budget = b < 0 ? null : b;
      }
      final cur = agg[cat];
      if (cur == null) {
        agg[cat] = {'category': cat, 'spent': s, 'budget': budget, 'raw': r};
      } else {
        cur['spent'] = (cur['spent'] as int) + s;
        if (cur['budget'] == null && budget != null) cur['budget'] = budget;
      }
    }
    final out = agg.values
        .where((v) => (v['spent'] as int) > 0 || v['budget'] != null)
        .toList();
    out.sort((a, b) {
      final d = (b['spent'] as int).compareTo(a['spent'] as int);
      return d != 0 ? d : (a['category'] as String).compareTo(b['category']);
    });
    return out;
  }

  static _SResult analyse(List<Map<String, dynamic>> rows,
      {Map<String, int>? previous}) {
    final cats = _normalise(rows);
    final spending = cats.where((c) => (c['spent'] as int) > 0).toList();
    final total =
        spending.fold<int>(0, (a, c) => a + (c['spent'] as int));

    if (spending.isEmpty || total <= 0) {
      return _SResult(false, 0, fmtBdt(0), null, 0, null, [], []);
    }

    // previous-period lookup from each row's own `previous` field
    final prevMap = <String, int>{};
    for (final r in rows) {
      final p = r['previous'];
      if (p != null && p != '') {
        var cat = (r['category'] ?? 'uncategorized').toString().trim();
        if (cat.isEmpty) cat = 'uncategorized';
        final v = toMinor(p);
        prevMap[cat] = (prevMap[cat] ?? 0) + (v < 0 ? 0 : v);
      }
    }
    if (previous != null) {
      previous.forEach((k, v) => prevMap[k] = (prevMap[k] ?? 0) + v);
    }

    final catRows = <_SCategory>[];
    final overspend = <_SCategory>[];
    for (final c in spending) {
      final spent = c['spent'] as int;
      final share = _pct(spent, total);
      final prev = prevMap[c['category']];
      final delta = prev != null ? spent - prev : null;
      int deltaPct = 0;
      if (prev != null && prev > 0 && delta != null && delta != 0) {
        deltaPct = _pct(delta.abs(), prev) * (delta > 0 ? 1 : -1);
      }
      final budget = c['budget'] as int?;
      final over = (budget != null && budget > 0) ? spent - budget : null;
      final overBudget = over != null && over > 0;
      final row = _SCategory(
        c['raw'] as Map<String, dynamic>,
        c['category'] as String,
        spent,
        fmtBdt(spent),
        share,
        delta != null ? fmtBdt(delta) : null,
        deltaPct,
        delta != null ? delta > 0 : null,
        budget != null ? fmtBdt(budget) : null,
        overBudget,
        overBudget ? fmtBdt(over) : null,
      );
      catRows.add(row);
      if (overBudget) overspend.add(row);
    }

    final prevTotal = prevMap.isNotEmpty
        ? prevMap.values.fold<int>(0, (a, b) => a + b)
        : null;
    final totalDelta = prevTotal != null ? total - prevTotal : null;
    int totalDeltaPct = 0;
    if (prevTotal != null && prevTotal > 0 && totalDelta != null &&
        totalDelta != 0) {
      totalDeltaPct = _pct(totalDelta.abs(), prevTotal) *
          (totalDelta > 0 ? 1 : -1);
    }

    final top = catRows.first;
    final obs = <_SObservation>[];
    obs.add(_SObservation('top_category', {
      'category': top.category,
      'amount': top.spentDisplay,
      'pct': top.sharePct,
    }));
    if (top.sharePct >= bigSharePct) {
      obs.add(_SObservation(
          'big_share', {'category': top.category, 'pct': top.sharePct}));
    }
    if (totalDelta != null && prevTotal != null && prevTotal > 0) {
      obs.add(_SObservation(
          totalDelta > 0
              ? 'total_mom_up'
              : (totalDelta < 0 ? 'total_mom_down' : 'total_mom_flat'),
          {'pct': totalDeltaPct.abs(), 'amount': fmtBdt(totalDelta.abs())}));
    }
    final movers = catRows.where((c) {
      final raw = prevMap[c.category];
      return raw != null && c.deltaDisplay != null && c.deltaPct != 0;
    }).toList();
    if (movers.isNotEmpty) {
      movers.sort((a, b) {
        final da = (a.spent - (prevMap[a.category] ?? 0)).abs();
        final db = (b.spent - (prevMap[b.category] ?? 0)).abs();
        final d = db.compareTo(da);
        return d != 0 ? d : a.category.compareTo(b.category);
      });
      final m = movers.first;
      final mdelta = m.spent - (prevMap[m.category] ?? 0);
      obs.add(_SObservation(
          mdelta > 0 ? 'category_mover_up' : 'category_mover_down', {
        'category': m.category,
        'amount': fmtBdt(mdelta.abs()),
        'pct': m.deltaPct.abs(),
      }));
    }
    for (final r in overspend) {
      obs.add(_SObservation('over_budget', {
        'category': r.category,
        'amount': r.overByDisplay ?? '',
        'budget': r.budgetDisplay ?? '',
      }));
    }
    obs.add(_SObservation('savings_pointer', {
      'category': top.category,
      'pct': top.sharePct,
    }));

    return _SResult(
      true,
      total,
      fmtBdt(total),
      totalDelta != null ? fmtBdt(totalDelta) : null,
      totalDeltaPct,
      totalDelta != null ? totalDelta > 0 : null,
      catRows,
      obs,
    );
  }
}
