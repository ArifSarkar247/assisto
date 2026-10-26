import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';

/// retention1 — the CUSTOMER side: automatic messages from shops this person
/// buys from (thank-you, due reminder, back in stock, birthday...). Every
/// message has Reply and Stop; Stop ends every automatic message from that
/// shop at once. Opened from the push / notification centre (route
/// 'retention_inbox') or the drawer.
class RetentionInboxScreen extends StatefulWidget {
  final RetentionSource? source;
  const RetentionInboxScreen({super.key, this.source});

  @override
  State<RetentionInboxScreen> createState() => _RetentionInboxScreenState();
}

class _RetentionInboxScreenState extends State<RetentionInboxScreen> {
  late final RetentionSource _src = widget.source ?? ApiRetentionSource(context.read<AppState>().api);
  bool _loading = true;
  bool _featureOff = false;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _rows = rtList((await _src.inbox())['messages']);
      _featureOff = false;
    } catch (e) {
      if (rtStatus(e) == 403) {
        _featureOff = true;
      } else {
        _error = rtError(e) ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reply(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final text = await showDialog<String>(context: context, builder: (_) => const _ReplyDialog());
    if (text == null || text.isEmpty) return;
    try {
      await _src.reply(rtInt(m['id']), text);
      if (mounted) rtSnack(context, t.rtReplySent);
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  Future<void> _stop(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final shop = (m['shop'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.rtStopTitle(shop)),
        content: Text(t.rtStopBody(shop)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.rtCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.rtStop)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _src.stop(rtInt(m['id']));
      if (mounted) rtSnack(context, t.rtStoppedDone(shop));
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rtInboxTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_featureOff) {
      return RtMessage(icon: Icons.lock_clock_outlined, title: t.rtFeatureOffTitle, body: t.rtFeatureOffBody);
    }
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    if (_rows.isEmpty) {
      return RtMessage(icon: Icons.storefront_outlined, title: t.rtInboxTitle, body: t.rtInboxEmpty);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        for (final m in _rows)
          Card(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.storefront_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text((m['shop'] ?? '').toString(), style: Theme.of(context).textTheme.titleMedium),
                  ),
                ]),
                const SizedBox(height: 6),
                Text((m['text'] ?? '').toString()),
                const SizedBox(height: 4),
                Text(rtWhen(context, m['at']), style: Theme.of(context).textTheme.bodySmall),
                if ((m['reply_text'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('${t.rtYouReplied}: ${m['reply_text']}', style: Theme.of(context).textTheme.bodySmall),
                ],
                const SizedBox(height: 4),
                if (m['stopped'] == true)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(children: [
                      const Icon(Icons.block_rounded, size: 18),
                      const SizedBox(width: 6),
                      Expanded(child: Text(t.rtStoppedLabel)),
                    ]),
                  )
                else
                  Wrap(spacing: 8, children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      icon: const Icon(Icons.reply_rounded),
                      label: Text(t.rtReply),
                      onPressed: () => _reply(m),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      icon: const Icon(Icons.block_rounded),
                      label: Text(t.rtStop),
                      onPressed: () => _stop(m),
                    ),
                  ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Owns its controller so it is disposed only after the dialog is gone.
class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog();

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.rtReply),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 500,
        minLines: 2,
        maxLines: 5,
        decoration: InputDecoration(labelText: t.rtReplyHint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.rtCancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: Text(t.rtSend)),
      ],
    );
  }
}
