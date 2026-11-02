import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../services/journey_tracker.dart' show journeyMapsLink;
import '../state.dart';
import '../theme.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_ride.dart';
import 'package:assisto/widgets/app_sheet.dart' show withNavBarInset;
import 'guardian_request_screen.dart';
import 'journey_live_screen.dart';

/// Owner idea 1 — guardian-requested journeys, both sides on one screen:
///  * asked of me: "Baba wants to follow your trip — Chattogram, 15:00–21:00"
///    with one-tap Accept / Decline (consent every time for adults);
///  * accepted, window open: sharing starts by itself while this screen is
///    open (Android does not let an app start location in the background
///    without the "all the time" permission Assisto never asks for — so a
///    notification asks for one tap otherwise; the screen says so);
///  * running: "<name> is watching your trip" with a one-tap Stop;
///  * asked by me: status, live distance / last seen, cancel, the audit log.
/// Free on every plan; no ads here.
class GuardianJourneyScreen extends StatefulWidget {
  const GuardianJourneyScreen({super.key});
  @override
  State<GuardianJourneyScreen> createState() => _GuardianJourneyScreenState();
}

class _GuardianJourneyScreenState extends State<GuardianJourneyScreen> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  bool _error = false;
  bool _busy = false;
  final Set<int> _autoTried = {};
  Timer? _timer;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> _list(String k) => ((_data[k] ?? const []) as List)
      .whereType<Map>()
      .map((m) => m.cast<String, dynamic>())
      .toList();

  Future<void> _load() async {
    try {
      final r = await _api.journeyRequests();
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
        _error = false;
      });
      _autoStart();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  /// The app is open and an accepted window has begun: start sharing now
  /// (once per request per screen visit; the traveller already consented).
  void _autoStart() {
    for (final r in _list('incoming')) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null || _autoTried.contains(id)) continue;
      if (r['status'] == 'accepted' && r['in_window'] == true && r['journey_id'] == null) {
        _autoTried.add(id);
        unawaited(_act(id, 'start'));
        return;
      }
    }
  }

  Future<void> _act(int id, String action) async {
    final t = AppLocalizations.of(context);
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.journeyRequestAction(id, action);
      if (!mounted) return;
      setState(() => _busy = false);
      final jid = (r['journey_id'] as num?)?.toInt();
      if ((action == 'start' || action == 'accept') && jid != null) {
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => JourneyLiveScreen(journeyId: jid)));
      } else {
        final msg = switch (action) {
          'accept' => t.gjAccepted,
          'decline' => t.gjDeclined,
          'stop' => t.gjStopped,
          'cancel' => t.gjCancelled,
          _ => null,
        };
        if (msg != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showActionFailed(context, 'guardian.$action', e);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showActionFailed(context, 'guardian.$action', e);
      }
    }
    if (mounted) await _load();
  }

  String _time(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    return d == null ? '' : TimeOfDay.fromDateTime(d).format(context);
  }

  String _day(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    return MaterialLocalizations.of(context).formatMediumDate(d);
  }

  String _window(AppLocalizations t, Map<String, dynamic> r) {
    if (r['standing'] == true) {
      final s = (r['schedule'] as Map?) ?? const {};
      return t.gjSchoolWindow(jDigits(context, '${s['start'] ?? ''}'),
          jDigits(context, '${s['end'] ?? ''}'));
    }
    return t.gjWindow(_day(r['window_start'] as String?), _time(r['window_start'] as String?),
        _time(r['window_end'] as String?));
  }

  String _dest(AppLocalizations t, Map<String, dynamic> r) {
    final d = (r['destination'] as Map?) ?? const {};
    final n = '${d['name'] ?? ''}'.trim();
    return n.isEmpty ? t.journeyDestPinned : n;
  }

  String _status(AppLocalizations t, Map<String, dynamic> r) => switch ('${r['status']}') {
        'pending' => t.gjStPending,
        'accepted' => t.gjStAccepted,
        'active' => t.gjStActive,
        'arrived' => t.gjStArrived,
        'declined' => t.gjStDeclined,
        'expired' => t.gjStExpired,
        _ => switch ('${r['outcome']}') {
            'stopped_by_traveller' => t.gjStStopped,
            'window_end' => t.gjStWindowEnd,
            'not_started' => t.gjStNotStarted,
            'cancelled' => t.gjStCancelled,
            'withdrawn' => t.gjStWithdrawn,
            _ => t.gjStEnded,
          },
      };

  Widget _incoming(AppLocalizations t, Map<String, dynamic> r) {
    final cs = Theme.of(context).colorScheme;
    final id = (r['id'] as num).toInt();
    final name = '${r['name'] ?? ''}';
    final st = '${r['status']}';
    final note = '${r['note'] ?? ''}'.trim();
    return Card(
      key: ValueKey('gj_in_$id'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(st == 'active' ? Icons.visibility_rounded : Icons.family_restroom_rounded,
                color: st == 'active' ? Brand.warnInk(context) : cs.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                  st == 'active'
                      ? t.gjWatchingYou(name)
                      : (r['standing'] == true ? t.gjAskSchool(name) : t.gjAsk(name)),
                  style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text('${_dest(t, r)} · ${_window(t, r)}', style: AType.bodyMedium),
          if (note.isNotEmpty)
            Text('"$note"', style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(st == 'pending' ? t.gjConsentNote : t.gjBannerNote,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (st == 'pending')
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              FilledButton.icon(
                  key: ValueKey('gj_accept_$id'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t.gjAccept),
                  onPressed: _busy ? null : () => _act(id, 'accept')),
              OutlinedButton.icon(
                  key: ValueKey('gj_decline_$id'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.close_rounded),
                  label: Text(t.gjDecline),
                  onPressed: _busy ? null : () => _act(id, 'decline')),
            ])
          else ...[
            if (st == 'accepted' && r['in_window'] == true)
              FilledButton.icon(
                  key: ValueKey('gj_start_$id'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.navigation_rounded),
                  label: Text(t.gjStartNow),
                  onPressed: _busy ? null : () => _act(id, 'start')),
            if (st == 'active' && r['journey_id'] != null)
              FilledButton.icon(
                  key: ValueKey('gj_open_$id'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(t.gjOpenTrip),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => JourneyLiveScreen(
                          journeyId: (r['journey_id'] as num).toInt())))),
            const SizedBox(height: Gap.xs),
            OutlinedButton.icon(
                key: ValueKey('gj_stop_$id'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48), foregroundColor: cs.error),
                icon: const Icon(Icons.stop_circle_rounded),
                label: Text(st == 'active' ? t.gjStopSharing : t.gjWithdraw),
                onPressed: _busy ? null : () => _act(id, 'stop')),
          ],
        ]),
      ),
    );
  }

  Widget _outgoing(AppLocalizations t, Map<String, dynamic> r) {
    final cs = Theme.of(context).colorScheme;
    final id = (r['id'] as num).toInt();
    final live = (r['live'] as Map?)?.cast<String, dynamic>();
    final lat = (live?['lat'] as num?)?.toDouble();
    final lng = (live?['lng'] as num?)?.toDouble();
    final age = (live?['fix_age_s'] as num?)?.toInt();
    return Card(
      key: ValueKey('gj_out_$id'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${r['name'] ?? ''}', style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
          Text('${_dest(t, r)} · ${_window(t, r)}', style: AType.bodyMedium),
          const SizedBox(height: Gap.xs),
          Text(_status(t, r),
              style: AType.bodyMedium.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
          if (age != null)
            Text(age <= 120 ? t.j100StLive : t.j100StStale(jDigits(context, (age / 60).round())),
                style: AType.bodySmall),
          if (live?['distance_m'] is num)
            Text(t.j2ToGo(jKm(context, live!['distance_m'] as num)), style: AType.bodySmall),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (lat != null && lng != null)
              FilledButton.icon(
                  icon: const Icon(Icons.map_rounded),
                  label: Text(t.j100OpenMap),
                  onPressed: () => openForUser(context, Uri.parse(journeyMapsLink(lat, lng)),
                      where: 'guardian.map', mode: LaunchMode.externalApplication)),
            OutlinedButton.icon(
                key: ValueKey('gj_cancel_$id'),
                icon: const Icon(Icons.cancel_rounded),
                label: Text(r['standing'] == true ? t.gjSchoolOff : t.gjCancel),
                onPressed: _busy ? null : () => _act(id, 'cancel')),
          ]),
          _logTile(t, r),
        ]),
      ),
    );
  }

  Widget _logTile(AppLocalizations t, Map<String, dynamic> r) {
    final rows = ((r['log'] ?? const []) as List).whereType<Map>().toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(t.gjLog, style: AType.bodyMedium),
      children: [
        for (final e in rows.reversed)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('${_time(e['at'] as String?)} · ${_logWhat(t, '${e['what']}')}',
                style: AType.bodySmall),
          ),
      ],
    );
  }

  String _logWhat(AppLocalizations t, String w) => switch (w) {
        'asked' => t.gjLogAsked,
        'accepted' => t.gjLogAccepted,
        'declined' => t.gjStDeclined,
        'started' => t.gjLogStarted,
        'start_reminder' => t.gjLogReminder,
        'arrived' => t.gjStArrived,
        'escalated' => t.gjLogEscalated,
        'stopped_by_traveller' => t.gjStStopped,
        'window_end' => t.gjStWindowEnd,
        'expired' => t.gjStExpired,
        'not_started' => t.gjStNotStarted,
        'cancelled' => t.gjStCancelled,
        'withdrawn' => t.gjStWithdrawn,
        _ => t.gjStEnded,
      };

  Future<void> _ask() async {
    final people = _list('people');
    final sent = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => GuardianRequestScreen(people: people)));
    if (sent == true && mounted) await _load();
  }

  Widget _empty(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    return Column(key: const ValueKey('gj_empty'), children: [
      Icon(Icons.family_restroom_rounded, size: 56, color: cs.primary),
      const SizedBox(height: Gap.md),
      Text(t.gjEmptyTitle,
          textAlign: TextAlign.center,
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.sm),
      Text(t.gjEmptyBody, textAlign: TextAlign.center, style: AType.bodyLarge),
      const SizedBox(height: Gap.sm),
      Text(t.gjEmptyHow,
          textAlign: TextAlign.center,
          style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final inc = _list('incoming'), out = _list('outgoing'), hist = _list('history');
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error && _data.isEmpty) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Text(t.j100WatchError, style: AType.bodyLarge),
        const SizedBox(height: Gap.md),
        Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(onPressed: _load, child: Text(t.retry))),
      ]);
    } else {
      body = ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          children: [
            if (inc.isEmpty && out.isEmpty) _empty(t),
            if (inc.isNotEmpty) ...[
              Text(t.gjAskedOfMe, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: Gap.xs),
              Text(t.gjAutoStartNote,
                  style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
              for (final r in inc) _incoming(t, r),
              const SizedBox(height: Gap.md),
            ],
            if (out.isNotEmpty) ...[
              Text(t.gjAskedByMe, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
              for (final r in out) _outgoing(t, r),
              const SizedBox(height: Gap.md),
            ],
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const ValueKey('gj_ask'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.add_location_alt_rounded),
              label: Text(t.gjAskButton),
              onPressed: _ask,
            ),
            const SizedBox(height: Gap.sm),
            Text(t.gjFreeNote,
                textAlign: TextAlign.center,
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            if (hist.isNotEmpty) ...[
              const SizedBox(height: Gap.lg),
              Text(t.gjHistory, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
              for (final r in hist)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${r['name'] ?? ''} · ${_dest(t, r)}'),
                  subtitle: Text('${_status(t, r)} · ${_window(t, r)}'),
                ),
            ],
          ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.gjTitle)),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}
