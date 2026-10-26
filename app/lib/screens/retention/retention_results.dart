import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';

/// retention1 — results of ONE automation: sent / delivered / replied /
/// stopped / purchases after the message (honest last-touch attribution
/// window), why some were not sent, and the recent messages.
class RetentionResultsScreen extends StatefulWidget {
  final RetentionSource source;
  final int automationId;
  const RetentionResultsScreen({super.key, required this.source, required this.automationId});

  @override
  State<RetentionResultsScreen> createState() => _RetentionResultsScreenState();
}

class _RetentionResultsScreenState extends State<RetentionResultsScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};

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
      _d = await widget.source.results(widget.automationId);
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rtResultsTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
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
    final lang = rtLang(context);
    final a = rtMap(_d['automation']);
    final kind = (a['kind'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    String n(String k) => rtDigits(lang, rtInt(_d[k]));
    final reasons = rtMap(_d['not_sent_reasons']);
    final recent = rtList(_d['recent']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Row(children: [
          Icon(rtKindIcon(kind)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name.isNotEmpty ? name : rtKindTitle(t, kind),
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ]),
        const SizedBox(height: 4),
        Text(rtKindWhen(t, lang, kind, rtMap(a['params']))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          RtStat(label: t.rtSent, value: n('sent'), icon: Icons.send_rounded),
          RtStat(label: t.rtDelivered, value: n('delivered'), icon: Icons.done_all_rounded),
          RtStat(label: t.rtReplied, value: n('replied'), icon: Icons.reply_rounded),
          RtStat(label: t.rtStopped, value: n('opted_out'), icon: Icons.block_rounded),
          RtStat(label: t.rtPurchases, value: n('purchases'), icon: Icons.shopping_bag_outlined),
          RtStat(
              label: t.rtRevenue,
              value: '৳${rtTaka(lang, _d['revenue_poisha'])}',
              icon: Icons.payments_outlined),
          if (_d.containsKey('payments_after'))
            RtStat(label: t.rtPaymentsAfter, value: n('payments_after'), icon: Icons.savings_outlined),
          RtStat(label: t.rtCredits, value: n('credits'), icon: Icons.toll_outlined),
        ]),
        const SizedBox(height: 8),
        Text(t.rtAttribution(rtDigits(lang, rtInt(_d['attribution_days'], 7))),
            style: Theme.of(context).textTheme.bodySmall),
        if (reasons.isNotEmpty) ...[
          const Divider(height: 28),
          Text(t.rtNotSent, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final e in reasons.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(rtReason(t, e.key))),
                Text(rtDigits(lang, rtInt(e.value))),
              ]),
            ),
        ],
        const Divider(height: 28),
        Text(t.rtRecent, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        if (recent.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.rtNoSends)),
        for (final s in recent) _SendTile(s: s),
      ]),
    );
  }
}

class _SendTile extends StatelessWidget {
  final Map<String, dynamic> s;
  const _SendTile({required this.s});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = rtLang(context);
    final st = (s['status'] ?? '').toString();
    final reason = (s['reason'] ?? '').toString();
    final name = (s['name'] ?? '').toString();
    final color = Brand.onTint(context, rtStatusColor(st));
    final bits = <String>[
      rtStatusName(t, st),
      if (reason.isNotEmpty) rtReason(t, reason),
      if (s['replied'] == true) t.rtReplied,
      if (s['opted_out'] == true) t.rtStopped,
      if (rtInt(s['purchase_poisha']) > 0) '${t.rtPurchases} ৳${rtTaka(lang, s['purchase_poisha'])}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(rtChannelIcon((s['channel'] ?? '').toString()), size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isNotEmpty ? name : rtDigits(lang, (s['phone'] ?? '').toString()),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(bits.join(' · '), style: TextStyle(color: color)),
            if ((s['reply_text'] ?? '').toString().isNotEmpty)
              Text('“${s['reply_text']}”', style: Theme.of(context).textTheme.bodySmall),
            Text(rtWhen(context, s['at']), style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}
