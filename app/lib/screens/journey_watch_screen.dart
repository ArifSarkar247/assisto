import 'dart:async';

import '../widgets/journey_mode_section.dart';
import 'train/train_tracker_screen.dart' show TrainLiveScreen;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../services/journey_tracker.dart' show journeyMapsLink;
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_ride.dart';
import 'journey_start_screen.dart';
import 'safe_journey/sj_during_api.dart'; // sjduring
import 'safe_journey/sj_watch_board.dart'; // sjduring
import 'package:assisto/widgets/app_sheet.dart' show withNavBarInset;
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

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

class _JourneyWatchScreenState extends State<JourneyWatchScreen>
    with AdBlockedState<JourneyWatchScreen> {
  List<Map<String, dynamic>> _rows = [];
  // sjduring: V2 state / level / badges per journey id (GET /journey/watch-board)
  Map<int, Map<String, dynamic>> _board = {};
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
      final api = context.read<AppState>().api;
      final r = await api.journeysWatching();
      final board = <int, Map<String, dynamic>>{};
      try {
        final b = await api.sjWatchBoard();
        for (final list in [b['active'], b['finished']]) {
          for (final c in (list as List? ?? const [])) {
            if (c is Map && c['id'] is num) {
              board[(c['id'] as num).toInt()] = c.cast<String, dynamic>();
            }
          }
        }
      } catch (_) {
        // best-effort: older server — the journey100 card still shows
      }
      if (!mounted) return;
      setState(() {
        _rows = r;
        _board = board;
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
      return (label: t.j100StSos, color: DsTokens.of(context).dangerInk, icon: Icons.sos_rounded);
    }
    switch (j['status']) {
      case 'arrived':
        return (label: t.j100StArrived, color: Brand.successFill, icon: Icons.check_circle_rounded);
      case 'active':
        break;
      default:
        return (label: t.j100StEnded, color: DsTokens.of(context).muted, icon: Icons.flag_rounded);
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
    return (label: t.j100StLost(jDigits(context, (age / 60).round())), color: DsTokens.of(context).dangerInk, icon: Icons.location_off_rounded);
  }

  Widget _card(AppLocalizations t, Map<String, dynamic> j) {
    final b = _board[(j['id'] as num?)?.toInt() ?? -1];
    var st = _state(t, j);
    // sjduring: the V2 state (late while moving = Slow in traffic, never
    // "late" in red); SOS stays the SOS look
    if (b != null && j['status'] == 'active' && j['sos'] != true) {
      final v = sjStateLook(context, t, b);
      st = (label: v.label, color: v.color, icon: v.icon);
    }
    final late = b == null && (j['overdue_state'] == 'ask' || j['overdue_state'] == 'alert');
    final level = '${b?['level'] ?? ''}';
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    final eta = DateTime.tryParse('${j['eta'] ?? ''}')?.toLocal();
    final dest = (j['destination'] ?? '').toString();
    final url = (j['url'] ?? '').toString();
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('sjd_card_${j['id']}'),
      shape: level.isEmpty
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              side: BorderSide(
                  width: 2, color: level == 'red' ? DsTokens.of(context).dangerInk : Brand.warnInk(context))),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (b != null) ...[
              Icon(sjModeIcon('${b['mode'] ?? ''}'), color: cs.primary),
              const SizedBox(width: Gap.xs),
            ],
            Icon(st.icon, color: st.color),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text((j['name'] ?? '').toString(),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(st.label, style: AType.bodyMedium.copyWith(color: st.color, fontWeight: FontWeight.w600)),
          if (b != null) SjBoardExtras(card: b), // sjduring
          if (late && j['status'] == 'active')
            Text(t.j100StLate,
                style: AType.bodyMedium.copyWith(color: DsTokens.of(context).dangerInk)),
          if (dest.isNotEmpty) Text(t.journeyToward(dest), style: AType.bodyMedium),
          if (eta != null && j['status'] == 'active')
            Text(t.journeyEtaBy(TimeOfDay.fromDateTime(eta).format(context)),
                style: AType.bodyMedium),
          // sjp0 (owner P0 9 Nov): with an arrival window (SjBoardExtras shows
          // "Arrive between A and B" + the earliest time) there is no
          // straight-line distance / typical-speed guess; without one they
          // stay as a small, honestly labelled fallback.
          if (j['distance_m'] is num && j['status'] == 'active' && !_hasWindow(b))
            Text(t.j2ToGo(jKm(context, j['distance_m'] as num)),
                style: AType.bodySmall),
          // journey100b: rough time left — from their own recent speed when
          // the server had enough fixes, else a typical speed (never traffic)
          if (j['rough_min'] is num && j['status'] == 'active' && !_hasWindow(b))
            Text(
                j['eta_basis'] == 'speed'
                    ? t.j100bRoughSpeed(jDigits(context, (j['rough_min'] as num).toInt()))
                    : t.j100bRoughTypical(jDigits(context, (j['rough_min'] as num).toInt())),
                key: const ValueKey('j100b_rough'),
                style: AType.bodySmall),
          // journey100b: the honest likely reason when no location comes in
          if (j['why'] == 'killed' || j['why'] == 'battery')
            Text(
                j['why'] == 'battery'
                    ? t.j100bWhyBattery(jDigits(context, (j['why_battery'] as num? ?? 0).toInt()))
                    : t.j100bWhyKilled,
                key: const ValueKey('j100b_why'),
                style: AType.bodyMedium.copyWith(color: DsTokens.of(context).dangerInk)),
          if (j['ride'] is Map && jRideLine(t, j['ride'] as Map).isNotEmpty)
            Text(jRideLine(t, j['ride'] as Map), style: AType.bodyMedium),
          if (j['ride'] is Map && '${(j['ride'] as Map)['driver_name'] ?? ''}'.isNotEmpty)
            Text(t.j2Driver('${(j['ride'] as Map)['driver_name']}'), style: AType.bodyMedium),
          // gap-safejourney: the number-plate / ride photo the traveller took
          // (was only on the web page) — live trips only, tap to enlarge
          if (j['status'] == 'active')
            if (sjRidePhotoUrl(j['ride_photo']) case final u?)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: SjRidePhotoThumb(url: u, label: t.j100VehiclePhoto),
              ),
          // journeymode: where their train is (estimate, says so)
          if (j['train'] is Map && j['status'] == 'active')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: JourneyTrainInfo(
                  train: j['train'] as Map,
                  onOpen: jmTrainOn
                      ? () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => TrainLiveScreen(
                              showAds: false,
                              no: '${(j['train'] as Map)['no']}',
                              date: '${(j['train'] as Map)['date']}')))
                      : null),
            ),
          if (j['battery'] != null)
            Text(t.j100Battery(jDigits(context, (j['battery'] as num).toInt())),
                style: AType.bodySmall)
          else if (j['battery_last'] is num)
            Text(t.j100bBatteryLast(jDigits(context, (j['battery_last'] as num).toInt())),
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
            if (j['sos'] == true || late || level == 'red')
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
      body = ListView(padding: const EdgeInsets.all(Gap.md), children: [
        for (var i = 0; i < 2; i++)
          Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: DsSkeleton.card(lines: 3)),
      ]);
    } else if (_error && _rows.isEmpty) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        DsEmptyState(
            icon: Icons.cloud_off_rounded, title: t.j100WatchError, actionLabel: t.retry, onAction: _load),
      ]);
    } else if (_rows.isEmpty) {
      // journey2: an empty state with the benefit, how it works and one
      // big action — not a dead end
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        KeyedSubtree(
          key: const ValueKey('j2_watch_empty'),
          child: DsEmptyState(
            icon: Icons.family_restroom_rounded,
            title: t.j100WatchEmpty,
            benefit: t.j2WatchEmptyBenefit,
            howTo: [t.j2WatchEmptyHow],
            actionLabel: t.j2WatchStartOwn,
            actionKey: const ValueKey('j2_watch_start_own'),
            onAction: () {
              final nav = Navigator.of(context);
              if (widget.fromStart && nav.canPop()) {
                nav.pop(); // back to the start form it was opened from
              } else {
                nav.pushReplacement(
                    MaterialPageRoute(builder: (_) => const JourneyStartScreen()));
              }
            },
          ),
        ),
      ]);
    } else {
      // sjduring: Active journeys (with a count) and Finished journeys
      bool live(Map<String, dynamic> j) =>
          j['status'] == 'active' ||
          _board[(j['id'] as num?)?.toInt() ?? -1]?['status'] == 'active';
      final act = [for (final j in _rows) if (live(j)) j];
      final done = [for (final j in _rows) if (!live(j)) j];
      Widget head(String s, Key k) => Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.sm, Gap.xs, Gap.xs),
            child: Semantics(
                header: true,
                child: Text(s,
                    key: k,
                    style: AType.titleMedium.copyWith(
                        fontWeight: FontWeight.w700, color: DsTokens.of(context).text))),
          );
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)), children: [
        head(t.sjdActiveCount(jDigits(context, act.length)), const ValueKey('sjd_active_head')),
        for (final j in act) _card(t, j),
        if (done.isNotEmpty) head(t.sjdFinished, const ValueKey('sjd_finished_head')),
        for (final j in done) _card(t, j),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.j100Following)),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}

/// sjp0: does this watcher-board card carry an arrival window?
bool _hasWindow(Map? b) =>
    b != null && '${b['window_from'] ?? ''}'.isNotEmpty && '${b['window_to'] ?? ''}'.isNotEmpty;


/// gap-safejourney: the server's signed photo path -> a full URL (null when
/// there is no photo).
String? sjRidePhotoUrl(Object? raw) {
  final s = '${raw ?? ''}'.trim();
  if (s.isEmpty || s == 'null') return null;
  if (s.startsWith('http')) return s;
  return '${AppConfig.apiBase}${s.startsWith('/') ? '' : '/'}$s';
}

/// gap-safejourney: a 72 dp thumbnail of the ride photo; a tap shows it big.
/// A broken / expired link shows a plain icon, never an error.
class SjRidePhotoThumb extends StatelessWidget {
  const SjRidePhotoThumb({super.key, required this.url, required this.label});
  final String url, label;

  Widget _img(BoxFit fit) => Image.network(url,
      fit: fit,
      semanticLabel: label,
      errorBuilder: (c, _, __) => ColoredBox(
          color: Theme.of(c).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.directions_car_filled_rounded,
              color: Theme.of(c).colorScheme.onSurfaceVariant)));

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        key: const ValueKey('gsj_ride_photo'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            key: const ValueKey('gsj_ride_photo_big'),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: InteractiveViewer(child: _img(BoxFit.contain))),
              TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(MaterialLocalizations.of(ctx).closeButtonLabel)),
            ]),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: SizedBox(width: 72, height: 72, child: _img(BoxFit.cover)),
          ),
          const SizedBox(width: Gap.sm),
          Flexible(child: Text(label, style: AType.bodyMedium)),
        ]),
      ),
    );
  }
}
