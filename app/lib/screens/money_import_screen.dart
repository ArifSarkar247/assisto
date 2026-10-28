import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'money_common.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Import transactions from a pasted/forwarded wallet or bank SMS. The raw text
/// is sent to POST /money/parse (money_parse.parse_batch) which returns parsed,
/// deduped txns; the user reviews/edits category then imports the ones they
/// confirm. This is the manual, privacy-safe path (the native Notification
/// Listener stays OFF by default per the project rules).
class MoneyImportScreen extends StatefulWidget {
  const MoneyImportScreen({super.key});
  @override
  State<MoneyImportScreen> createState() => _MoneyImportScreenState();
}

class _MoneyImportScreenState extends State<MoneyImportScreen> {
  final _input = TextEditingController();
  List<Map<String, dynamic>> _parsed = [];
  final Set<int> _selected = {};
  bool _busy = false;
  String? _error;

  Future<void> _parse() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.read<AppState>().api.moneyParse(_input.text);
      final txns =
          (res['transactions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      setState(() {
        _parsed = txns;
        _selected
          ..clear()
          ..addAll(List.generate(txns.length, (i) => i)
              .where((i) => txns[i]['parsed'] == true));
      });
      if (txns.isEmpty && mounted) {
        setState(() => _error = t.moneyImportNothing);
      }
    } catch (_) {
      if (mounted) setState(() => _error = t.moneySummaryOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    int n = 0;
    for (final i in _selected) {
      final p = _parsed[i];
      if (p['parsed'] != true) continue;
      await app.txns.add({
        'kind': p['type'] == 'credit' ? 'income' : 'expense',
        'amount': '${p['amount']}',
        'category': p['category_guess'] ?? '',
        'note': p['counterparty'] ?? p['channel'] ?? '',
        'date': p['date'],
        'source': 'notification',
        'ref': p['ref'],
      });
      // teach the parser the (possibly corrected) category for this merchant
      if (p['counterparty'] != null &&
          '${p['counterparty']}'.isNotEmpty &&
          p['category_guess'] != null) {
        try {
          await app.api.moneyLearnCategory(
              '${p['counterparty']}', '${p['category_guess']}');
        } catch (_) {} // best-effort: category learning; the import itself succeeded
      }
      n++;
    }
    messenger.showSnackBar(SnackBar(content: Text(t.moneyImported(n))));
    navigator.pop();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.moneyImportTitle)),
      bottomNavigationBar: _parsed.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: FilledButton.icon(
                    onPressed: _selected.isEmpty ? null : _import,
                    icon: const Icon(Icons.download_done_rounded),
                    label: Text(t.moneyImportSelected(_selected.length))),
              ),
            ),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        Text(t.moneyImportHint,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _input,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: t.moneyImportPasteHint,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _busy ? null : _parse,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(t.moneyImportParse)),
        if (_error != null) ...[
          const SizedBox(height: Gap.md),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: Gap.lg),
        for (int i = 0; i < _parsed.length; i++) _reviewCard(context, t, i),
      ]),
    );
  }

  Widget _reviewCard(BuildContext context, AppLocalizations t, int i) {
    final p = _parsed[i];
    final parsed = p['parsed'] == true;
    final credit = p['type'] == 'credit';
    final dup = p['duplicate'] == true;
    return Card(
      child: Opacity(
        opacity: parsed ? 1 : 0.55,
        child: CheckboxListTile(
          value: _selected.contains(i),
          onChanged: parsed
              ? (v) => setState(() =>
                  v == true ? _selected.add(i) : _selected.remove(i))
              : null,
          title: Row(children: [
            Expanded(
              child: Text(
                  parsed
                      ? '${credit ? '+' : '-'}${tkFmt(p['amount'])}'
                      : t.moneyImportUnrecognised,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: !parsed
                          ? null
                          : credit
                              ? AssistoTokens.of(context).success
                              : Theme.of(context).colorScheme.error)),
            ),
            if (dup)
              Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(t.moneyImportDuplicate)),
          ]),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (p['counterparty'] != null)
              Text('${p['counterparty']}'),
            Row(children: [
              if (p['channel'] != null)
                Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${p['channel']}')),
              const SizedBox(width: Gap.sm),
              if (p['category_guess'] != null)
                InkWell(
                  onTap: () => _editCategory(i),
                  child: Chip(
                      avatar: const Icon(Icons.label_outline_rounded, size: 14),
                      visualDensity: VisualDensity.compact,
                      label: Text('${p['category_guess']}')),
                ),
            ]),
            Text(p['raw'] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AType.labelSmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          isThreeLine: true,
        ),
      ),
    );
  }

  Future<void> _editCategory(int i) async {
    final t = AppLocalizations.of(context);
    final c = TextEditingController(text: '${_parsed[i]['category_guess'] ?? ''}');
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              scrollable: true, // insets: 200% text / keyboard
              title: Text(t.moneyFieldCategory),
              content: TextField(controller: c, autofocus: true),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.save)),
              ],
            ));
    if (ok == true) {
      setState(() => _parsed[i]['category_guess'] = c.text.trim());
    }
  }
}
