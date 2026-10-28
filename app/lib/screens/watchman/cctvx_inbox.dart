import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cashguard/cashguard_source.dart';
import '../../cctvx/cctvx_source.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import 'cash_guard_clip.dart';
import 'cctvx_actions.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvx — ALERTS PASSED TO ME: a shop owner did not open an alert in time
/// and their chosen chain sent it to me, or they shared a clip with me (last
/// 48 h). Opening this list tells the owner's chain "seen" (it stops). The
/// wording never accuses anyone — the owner decides.
class GuardInboxScreen extends StatefulWidget {
  final CctvxSource? source;
  final CashGuardSource? cash;
  const GuardInboxScreen({super.key, this.source, this.cash});

  @override
  State<GuardInboxScreen> createState() => _GuardInboxScreenState();
}

class _GuardInboxScreenState extends State<GuardInboxScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = const [];
  CctvxSource? _src;
  CashGuardSource? _cash;

  @override
  void initState() {
    super.initState();
    _src = widget.source;
    _cash = widget.cash;
    if (_src == null || _cash == null) {
      try {
        final api = context.read<AppState>().api;
        _src ??= ApiCctvxSource(api);
        _cash ??= ApiCashGuardSource(api);
      } catch (_) {}
    }
    _load();
  }

  Future<void> _load() async {
    final src = _src;
    if (src == null) {
      setState(() {
        _loading = false;
        _error = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await src.inbox();
      _events = wmList(r['events']);
      for (final e in _events) {
        if (e['role'] == 'escalated' && e['opened_at'] == null) {
          try {
            await src.opened((e['id'] as num).toInt());
          } catch (_) {}
        }
      }
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(32), children: [
        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
            child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry))),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Text(t.cxInboxBody, style: Theme.of(context).textTheme.bodySmall),
          if (_events.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Column(children: [
                Icon(Icons.inbox_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text(t.cxInboxEmpty, textAlign: TextAlign.center),
              ]),
            ),
          for (final e in _events) _card(t, e),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.cxInboxTitle)), body: body);
  }

  Widget _card(AppLocalizations t, Map<String, dynamic> e) {
    final loc = MaterialLocalizations.of(context);
    final dt = DateTime.tryParse((e['last_at'] ?? e['created'] ?? '').toString())?.toLocal();
    final when = dt == null
        ? ''
        : '${loc.formatShortDate(dt)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt))}';
    final id = (e['id'] as num).toInt();
    final shared = e['role'] == 'shared';
    final owner = (e['owner_name'] ?? '').toString();
    final snap = (e['snapshot_url'] ?? '').toString();
    final clip = wmMap(e['clip']);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (snap.isNotEmpty)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Semantics(
              label: t.wmSnapshotLabel,
              image: true,
              child: Image.network(snap, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(12),
                        child: Text(t.wmSnapshotGone, textAlign: TextAlign.center),
                      )),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WmPill(
              label: shared ? t.cxInboxShared(owner) : t.cxInboxPassed(owner),
              icon: shared ? Icons.ios_share_rounded : Icons.forward_to_inbox_rounded,
              color: wmWarn(),
            ),
            const SizedBox(height: 8),
            Text(e['nosale'] == true ? t.cxNoSaleTitle : wmEventWhat(t, (e['type'] ?? '').toString()),
                style: Theme.of(context).textTheme.titleMedium),
            Text(t.cgDecideHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text([(e['site_name'] ?? '').toString(), (e['camera_name'] ?? '').toString(), when]
                .where((s) => s.isNotEmpty)
                .join(' · ')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (shared && clip['status'] == 'ready' && _cash != null)
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.play_circle_outline_rounded),
                  label: Text(t.cgWatchClip),
                  onPressed: () async {
                    await CashClipSheet.show(context, _cash!, id, false, reportsView: true);
                    if (mounted) await _load();
                  },
                ),
              if (_src != null)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.bolt_rounded),
                  label: Text(t.cxActions),
                  onPressed: () => AlertActionsSheet.show(context, _src!, id, cash: _cash),
                ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
