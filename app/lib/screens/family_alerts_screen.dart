import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../family_alerts_api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/family_push_banner.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits, notifWhen;

/// family100 — where an SOS / family-alert push lands (deep link
/// `safety/sos`, `family/alerts`), and the family's alert history.
///
///  * "Alerts for you": every alert the server pushed to this user in the
///    last 7 days (SOS in red first while active). Each one: who, when, what,
///    "See on map" when the sender shares location (SOS always), "I've seen
///    it" -> the sender sees "seen".
///  * "Alerts you sent": each event with every member's honest status —
///    seen / reached the phone / sent / no notification / quiet hours /
///    capped / push not set up — and "I'm safe now" after an SOS.
///  * The notifications-off banner (Android 13+ permission) + battery guide.
///  * Real data only: loading, empty, error + retry states; pull to refresh.
class FamilyAlertsScreen extends StatefulWidget {
  const FamilyAlertsScreen(
      {super.key, this.load, this.seen, this.resolve, this.pushEnabled});

  /// Test seams (default: the signed-in ApiClient).
  final Future<Map<String, dynamic>> Function()? load;
  final Future<void> Function(int id)? seen;
  final Future<Map<String, dynamic>> Function()? resolve;
  final Future<bool> Function()? pushEnabled;

  @override
  State<FamilyAlertsScreen> createState() => _FamilyAlertsScreenState();
}

class _FamilyAlertsScreenState extends State<FamilyAlertsScreen> {
  bool _loading = true;
  bool _failed = false;
  bool _resolving = false;
  List<Map<String, dynamic>> _received = const [];
  List<Map<String, dynamic>> _sent = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await (widget.load ??
          () => context.read<AppState>().api.familyAlerts())();
      List<Map<String, dynamic>> rows(Object? v) => [
            for (final e in (v as List? ?? const []))
              if (e is Map) Map<String, dynamic>.from(e)
          ];
      _received = rows(r['received']);
      _sent = rows(r['sent']);
      _failed = false;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markSeen(Map<String, dynamic> a) async {
    final id = (a['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await (widget.seen ??
          (int i) => context.read<AppState>().api.familyAlertSeen(i))(id);
      if (mounted) setState(() => a['seen'] = true);
    } catch (e) {
      if (mounted) showActionFailed(context, 'family_alert.seen', e);
    }
  }

  Future<void> _safeNow() async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.of(context);
    setState(() => _resolving = true);
    try {
      await (widget.resolve ??
          () => context.read<AppState>().api.familySosResolve())();
      m.showSnackBar(SnackBar(content: Text(t.fa100SafeSent)));
      await _load();
    } catch (_) {
      m.showSnackBar(SnackBar(content: Text(t.fa100SafeFailed)));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// An SOS I sent in the last 24 h that I have not resolved since.
  bool get _ownSosActive {
    for (final e in _sent) {
      final k = '${e['kind']}';
      if (k == 'sos_resolved') return false;
      if (k == 'sos') {
        final at = DateTime.tryParse('${e['at'] ?? ''}');
        return at != null &&
            DateTime.now().difference(at.toLocal()) < const Duration(hours: 24);
      }
    }
    return false;
  }

  String _kindLabel(AppLocalizations t, String k) => switch (k) {
        'sos' => t.fa100KindSos,
        'sos_resolved' => t.fa100KindSafe,
        'checkin_overdue' => t.fa100KindCheckin,
        'wellness_alert' => t.fa100KindWellness,
        'scam_report' => t.fa100KindScam,
        _ => t.fa100KindOther,
      };

  String _statusLabel(AppLocalizations t, Map r) {
    if (r['seen'] == true) return t.fa100StSeen;
    if (r['received'] == true) return t.fa100StReceived;
    return switch ('${r['status']}') {
      'sent' => t.fa100StSent,
      'no_device' => t.fa100StNoDevice,
      'held' => t.fa100StHeld,
      'rate_limited' => t.fa100StLimited,
      'push_off' => t.fa100StOff,
      _ => t.fa100StSent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      FamilyPushBanner(isEnabled: widget.pushEnabled),
    ];
    if (_loading && _received.isEmpty && _sent.isEmpty) {
      children.add(const Padding(
          padding: EdgeInsets.all(Gap.xxl),
          child: Center(child: CircularProgressIndicator())));
    } else if (_failed) {
      children.add(_ErrorCard(onRetry: _load));
    } else {
      if (_ownSosActive) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: FilledButton.icon(
            key: const ValueKey('fa100-safe-now'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: Brand.success,
                foregroundColor: Colors.white),
            onPressed: _resolving ? null : _safeNow,
            icon: const Icon(Icons.verified_user_rounded),
            label: Text(t.fa100SafeNow),
          ),
        ));
      }
      children.add(_Header(t.fa100Received));
      if (_received.isEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: Text(t.fa100Empty,
              key: const ValueKey('fa100-empty'),
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
        ));
      }
      for (final a in _received) {
        children.add(_AlertCard(
          alert: a,
          kindLabel: _kindLabel(t, '${a['kind']}'),
          onSeen: () => _markSeen(a),
        ));
      }
      if (_sent.isNotEmpty) {
        children.add(const SizedBox(height: Gap.lg));
        children.add(_Header(t.fa100Sent));
        for (final e in _sent) {
          final rec = [
            for (final r in (e['recipients'] as List? ?? const []))
              if (r is Map) r
          ];
          children.add(Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${_kindLabel(t, '${e['kind']}')} · ${notifWhen(context, '${e['at'] ?? ''}')}',
                        style: AType.titleSmall
                            .copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: Gap.xs),
                    for (final r in rec)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.xs),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                  r['seen'] == true
                                      ? Icons.done_all_rounded
                                      : Icons.done_rounded,
                                  size: 18,
                                  color: r['seen'] == true
                                      ? Brand.success
                                      : scheme.onSurfaceVariant),
                              const SizedBox(width: Gap.sm),
                              Expanded(
                                  child: Text(
                                      '${r['name']}: ${_statusLabel(t, r)}',
                                      style: AType.bodyMedium)),
                            ]),
                      ),
                  ]),
            ),
          ));
        }
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.fa100Title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(Gap.lg),
          children: children,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Text(text,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      key: const ValueKey('fa100-error'),
      padding: const EdgeInsets.symmetric(vertical: Gap.xl),
      child: Column(children: [
        Icon(Icons.cloud_off_rounded,
            size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.sm),
        Text(t.fa100Error, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onRetry,
          child: Text(t.fa100Retry),
        ),
      ]),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard(
      {required this.alert, required this.kindLabel, required this.onSeen});
  final Map<String, dynamic> alert;
  final String kindLabel;
  final VoidCallback onSeen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isSos = alert['kind'] == 'sos' && alert['active'] == true;
    final seen = alert['seen'] == true;
    final lat = alert['lat'];
    final lng = alert['lng'];
    final hasLoc = lat != null && lng != null && '$lat' != '' && '$lng' != '';
    final fg = isSos ? scheme.onErrorContainer : scheme.onSurface;
    return Card(
      key: ValueKey('fa100-alert-${alert['id']}'),
      color: isSos ? scheme.errorContainer : null,
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(isSos ? Icons.sos_rounded : Icons.notifications_rounded,
                color: isSos ? Brand.danger : scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(kindLabel,
                  style: AType.labelLarge
                      .copyWith(fontWeight: FontWeight.w700, color: fg)),
            ),
            Text(notifWhen(context, '${alert['at'] ?? ''}'),
                style: AType.bodySmall.copyWith(color: fg)),
          ]),
          const SizedBox(height: Gap.xs),
          Text('${alert['title'] ?? ''}',
              style: AType.titleMedium
                  .copyWith(fontWeight: FontWeight.w700, color: fg)),
          if ('${alert['body'] ?? ''}'.isNotEmpty)
            Text(notifLocalizeDigits(context, '${alert['body']}'),
                style: AType.bodyMedium.copyWith(color: fg)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (hasLoc)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(
                    context,
                    Uri.parse('https://maps.google.com/?q=$lat,$lng'),
                    where: 'family_alert.map'),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.fa100OpenMap),
              ),
            if (seen)
              Semantics(
                label: t.fa100Seen,
                child: Chip(
                  avatar: const Icon(Icons.done_all_rounded, size: 18),
                  label: Text(t.fa100Seen),
                ),
              )
            else
              FilledButton(
                key: ValueKey('fa100-seen-${alert['id']}'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onSeen,
                child: Text(t.fa100MarkSeen),
              ),
          ]),
        ]),
      ),
    );
  }
}
