import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import 'ladder_common.dart' show fmtInt;

/// Owner AI chat rebuild (4 Nov 01:02): the AI never writes anything by
/// itself. When the user asks to save an expense, reminder, note or their
/// name, the answer carries this card — "Set reminder tomorrow 09:00? Yes /
/// No" — and only Yes writes it (POST agent/confirm).
class AiConfirmCard extends StatefulWidget {
  final Map<String, dynamic> card;

  /// Tests: replace the server call (pendingId, yes) -> body.
  final Future<Map<String, dynamic>> Function(String pendingId, bool yes)? send;
  const AiConfirmCard(this.card, {super.key, this.send});

  @override
  State<AiConfirmCard> createState() => _AiConfirmCardState();
}

class _AiConfirmCardState extends State<AiConfirmCard> {
  bool _busy = false;
  String? _done; // the server's sentence once answered

  Future<void> _answer(bool yes) async {
    setState(() => _busy = true);
    final id = '${widget.card['pending_id'] ?? ''}';
    String msg;
    try {
      final r = await (widget.send ??
          (p, y) => context
              .read<AppState>()
              .api
              .postJson('/agent/confirm', {'pending_id': p, 'yes': y}))(id, yes);
      msg = '${r['message'] ?? ''}';
      if (yes && r['done'] == true && mounted) {
        final app = context.read<AppState>();
        app.reminders.sync();
        app.txns.sync();
      }
    } catch (_) {
      msg = AppLocalizations.of(context).aiConfirmFailed;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _done = msg.isEmpty ? AppLocalizations.of(context).aiConfirmFailed : msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.card;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${c['title'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (_done != null)
          Text(_done!, key: const Key('ai-confirm-done'))
        else
          Wrap(spacing: 8, children: [
            FilledButton(
              key: const Key('ai-confirm-yes'),
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _busy ? null : () => _answer(true),
              child: Text('${c['yes'] ?? 'Yes'}'),
            ),
            OutlinedButton(
              key: const Key('ai-confirm-no'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _busy ? null : () => _answer(false),
              child: Text('${c['no'] ?? 'No'}'),
            ),
          ]),
      ]),
    );
  }
}

/// The one-tap clean-up: entries the AI chat wrote (source = ai), with
/// "Delete all" — for the false expenses the old parser wrote.
class AiEntriesSheet extends StatefulWidget {
  const AiEntriesSheet({super.key});
  @override
  State<AiEntriesSheet> createState() => _AiEntriesSheetState();
}

class _AiEntriesSheetState extends State<AiEntriesSheet> {
  List<Map<String, dynamic>>? _items;
  bool _busy = false;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.getJson('/agent/ai-entries');
      final l = (r['items'] as List? ?? const []).cast<Map>();
      if (mounted) setState(() => _items = [for (final m in l) m.cast<String, dynamic>()]);
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  Future<void> _deleteAll() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final app = context.read<AppState>();
      final r = await app.api.postJson('/agent/ai-entries', {'items': 'all'});
      app.reminders.sync();
      app.txns.sync();
      if (!mounted) return;
      _msg = t.aiEntriesDeleted(fmtInt(context, (r['deleted'] as num?)?.toInt() ?? 0));
      _items = const [];
    } catch (_) {
      _msg = t.aiConfirmFailed;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = _items;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text(t.aiEntriesTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (items == null)
          const Center(child: CircularProgressIndicator())
        else if (items.isEmpty)
          Text(_msg.isNotEmpty ? _msg : t.aiEntriesNone)
        else ...[
          for (final it in items.take(30))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(it['model'] == 'txn'
                  ? Icons.receipt_long_rounded
                  : Icons.notifications_rounded),
              title: Text('${it['title'] ?? ''}'),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('ai-entries-delete-all'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _deleteAll,
            icon: const Icon(Icons.delete_sweep_rounded),
            label: Text(t.aiEntriesDeleteAll),
          ),
        ],
      ]),
    );
  }
}
