import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctv1 ALERTS: every alert reads "Suspicious — please check" (never an
/// accusation), with its ONE snapshot, what was seen, how many times
/// (grouped), the confidence, and — for the owner — Correct / Wrong. Each
/// answer tunes that camera a little (bounded). Family viewers read only.
class WatchmanAlertsScreen extends StatefulWidget {
  final WatchmanSource source;
  final int siteId;
  final bool owner;
  const WatchmanAlertsScreen({super.key, required this.source, required this.siteId, required this.owner});

  @override
  State<WatchmanAlertsScreen> createState() => _WatchmanAlertsScreenState();
}

class _WatchmanAlertsScreenState extends State<WatchmanAlertsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = const [];
  int _held = 0;
  final Set<int> _busy = {};

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
      final r = await widget.source.events(widget.siteId);
      _events = wmList(r['events']);
      _held = (r['held_today'] as num?)?.toInt() ?? 0;
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _mark(Map<String, dynamic> e, String verdict) async {
    final t = AppLocalizations.of(context);
    final id = (e['id'] as num).toInt();
    setState(() => _busy.add(id));
    try {
      final r = await widget.source.mark(id, verdict);
      e['status'] = r['status'];
      e['verdict'] = r['verdict'];
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(verdict == 'wrong' ? t.wmMarkedWrong : t.wmMarkedCorrect)));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(err) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
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
              child: Text(t.wmRetry)),
        ),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (!widget.owner)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(t.wmViewerReadOnly, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_held > 0)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(t.wmHeldToday(wmDigits(lang, _held))),
              ),
            ),
          if (_events.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Column(children: [
                Icon(Icons.verified_user_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text(t.wmNoAlertsTitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(t.wmNoAlertsBody, textAlign: TextAlign.center),
              ]),
            ),
          for (final e in _events) _alertCard(t, lang, e),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.wmAlerts)), body: body);
  }

  Widget _alertCard(AppLocalizations t, String lang, Map<String, dynamic> e) {
    final loc = MaterialLocalizations.of(context);
    final dt = DateTime.tryParse((e['last_at'] ?? e['created'] ?? '').toString())?.toLocal();
    final when = dt == null
        ? ''
        : '${loc.formatShortDate(dt)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt))}';
    final count = (e['count'] as num?)?.toInt() ?? 1;
    final pct = (((e['confidence'] as num?) ?? 0) * 100).round();
    final verdict = e['verdict'];
    final id = (e['id'] as num).toInt();
    final snap = (e['snapshot_url'] ?? '').toString();
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
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(12),
                        child: Text(t.wmSnapshotGone, textAlign: TextAlign.center),
                      )),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WmPill(label: t.wmSuspiciousLabel, icon: Icons.visibility_rounded, color: wmWarn()),
            const SizedBox(height: 8),
            Text(wmEventWhat(t, (e['type'] ?? '').toString()),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text([
              if ((e['camera_name'] ?? '').toString().isNotEmpty) e['camera_name'].toString(),
              when,
            ].join(' · ')),
            const SizedBox(height: 2),
            Text(
              [
                t.wmConfidence(wmDigits(lang, pct)),
                if (count > 1) t.wmSeenTimes(wmDigits(lang, count)),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (snap.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(t.wmNoSnapshot, style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            if (verdict != null)
              WmPill(
                label: verdict == 'wrong' ? t.wmVerdictWrong : t.wmVerdictCorrect,
                icon: verdict == 'wrong' ? Icons.thumb_down_alt_outlined : Icons.thumb_up_alt_outlined,
                color: verdict == 'wrong' ? wmBad() : wmOk(),
              ),
            if (widget.owner) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.thumb_up_alt_outlined),
                    label: Text(t.wmCorrect),
                    onPressed: _busy.contains(id) || verdict == 'correct' ? null : () => _mark(e, 'correct'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.thumb_down_alt_outlined),
                    label: Text(t.wmWrong),
                    onPressed: _busy.contains(id) || verdict == 'wrong' ? null : () => _mark(e, 'wrong'),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}
