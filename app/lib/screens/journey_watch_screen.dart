import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../services/journey_tracker.dart' show journeyMapsLink;
import '../state.dart';
import '../theme.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_ride.dart';
import 'journey_start_screen.dart';
import 'package:assisto/widgets/app_sheet.dart' show withNavBarInset;

/// journey100 — "Journeys I'm watching": the in-app side for a WATCHER (a
/// push about someone's journey opens here). Real server state only
/// (GET /journey/watching), refreshed every 30 s; honest stale / lost /
/// SOS / arrived states; the map opens in the phone's maps app and the live
/// page in the browser. Location is never shown after a trip ends.
class JourneyWatchScreen extends StatefulWidget {
  /// Opened from the start form (the empty state's button just goes back).
  final bool fromStart;
  const JourneyWatchScreen({super.key, this.fromStart = false});
  @override
  State<JourneyWatchScreen> createState() => _JourneyWatchScreenState();
}

class _JourneyWatchScreenState extends State<JourneyWatchScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  Timer? _timer;

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

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.journeysWatching();
      if (!mounted) return;
      setState(() {
        _rows = r;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  ({String label, Color color, IconData icon}) _state(
      AppLocalizations t, Map<String, dynamic> j) {
    final cs = Theme.of(context).colorScheme;
    final age = (j['fix_age_s'] as num?)?.toInt();
    if (j['sos'] == true) {
      return (label: t.j100StSos, color: cs.error, icon: Icons.sos_rounded);
    }
    switch (j['status']) {
      case 'arrived':
        return (label: t.j100StArrived, color: Brand.successFill, icon: Icons.check_circle_rounded);
      case 'active':
        break;
      default:
        return (label: t.j100StEnded, color: cs.onSurfaceVariant, icon: Icons.flag_rounded);
    }
    if (age == null) {
      return (label: t.j100StWaiting, color: Brand.warnInk(context), icon: Icons.gps_not_fixed_rounded);
    }
    if (age <= 120) {
      return (label: t.j100StLive, color: Brand.successFill, icon: Icons.navigation_rounded);
    }
    if (age < 15 * 60) {
      return (label: t.j100StStale(jDigits(context, (age / 60).round())), color: Brand.warnInk(context),
          icon: Icons.schedule_rounded);
    }
    return (label: t.j100StLost(jDigits(context, (age / 60).round())), color: cs.error, icon: Icons.location_off_rounded);
  }

  Widget _card(AppLocalizations t, Map<String, dynamic> j) {
    final st = _state(t, j);
    final late = j['overdue_state'] == 'ask' || j['overdue_state'] == 'alert';
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    final eta = DateTime.tryParse('${j['eta'] ?? ''}')?.toLocal();
    final dest = (j['destination'] ?? '').toString();
    final url = (j['url'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(st.icon, color: st.color),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text((j['name'] ?? '').toString(),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(st.label, style: AType.bodyMedium.copyWith(color: st.color, fontWeight: FontWeight.w600)),
          if (late && j['status'] == 'active')
            Text(t.j100StLate,
                style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.error)),
          if (dest.isNotEmpty) Text(t.journeyToward(dest), style: AType.bodyMedium),
          if (eta != null && j['status'] == 'active')
            Text(t.journeyEtaBy(TimeOfDay.fromDateTime(eta).format(context)),
                style: AType.bodyMedium),
          if (j['distance_m'] is num && j['status'] == 'active')
            Text(t.j2ToGo(jKm(context, j['distance_m'] as num)),
                style: AType.bodyMedium),
          if (j['ride'] is Map && jRideLine(t, j['ride'] as Map).isNotEmpty)
            Text(jRideLine(t, j['ride'] as Map), style: AType.bodyMedium),
          if (j['ride'] is Map && '${(j['ride'] as Map)['driver_name'] ?? ''}'.isNotEmpty)
            Text(t.j2Driver('${(j['ride'] as Map)['driver_name']}'), style: AType.bodyMedium),
          if (j['battery'] != null)
            Text(t.j100Battery(jDigits(context, (j['battery'] as num).toInt())),
                style: AType.bodySmall),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (lat != null && lng != null)
              FilledButton.icon(
                  icon: const Icon(Icons.map_rounded),
                  label: Text(t.j100OpenMap),
                  onPressed: () => openForUser(context, Uri.parse(journeyMapsLink(lat, lng)),
                      where: 'journeyWatch.map', mode: LaunchMode.externalApplication)),
            if (url.isNotEmpty && (j['status'] == 'active' || j['sos'] == true))
              OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: Text(t.j100LivePage),
                  onPressed: () => openForUser(context, Uri.parse(url),
                      where: 'journeyWatch.page', mode: LaunchMode.externalApplication)),
            if (j['sos'] == true || late)
              OutlinedButton.icon(
                  icon: const Icon(Icons.call_rounded),
                  label: Text(t.sosCallNow),
                  onPressed: () => openForUser(context, Uri.parse('tel:999'),
                      where: 'journeyWatch.999')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error && _rows.isEmpty) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Text(t.j100WatchError, style: AType.bodyLarge),
        const SizedBox(height: Gap.md),
        Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(onPressed: _load, child: Text(t.retry))),
      ]);
    } else if (_rows.isEmpty) {
      // journey2: an empty state with the benefit, how it works and one
      // big action — not a dead end
      final cs = Theme.of(context).colorScheme;
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        Icon(Icons.family_restroom_rounded, size: 56, color: cs.primary),
        const SizedBox(height: Gap.md),
        Text(t.j100WatchEmpty,
            key: const ValueKey('j2_watch_empty'),
            textAlign: TextAlign.center,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.j2WatchEmptyBenefit, textAlign: TextAlign.center, style: AType.bodyLarge),
        const SizedBox(height: Gap.sm),
        Text(t.j2WatchEmptyHow,
            textAlign: TextAlign.center,
            style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          key: const ValueKey('j2_watch_start_own'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.navigation_rounded),
          label: Text(t.j2WatchStartOwn),
          onPressed: () {
            final nav = Navigator.of(context);
            if (widget.fromStart && nav.canPop()) {
              nav.pop(); // back to the start form it was opened from
            } else {
              nav.pushReplacement(
                  MaterialPageRoute(builder: (_) => const JourneyStartScreen()));
            }
          },
        ),
      ]);
    } else {
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)), children: [
        for (final j in _rows) _card(t, j),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.j100Watching)),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}
