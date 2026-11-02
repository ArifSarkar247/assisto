import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../services/journey_tracker.dart';
import '../../services/oem_guide.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/journey_api.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import '../battery_guidance_screen.dart';
import '../guardian_journey_screen.dart';
import '../journey_live_screen.dart';
import '../journey_settings_screen.dart';
import '../journey_start_screen.dart'
    show JourneyStartScreen, journeyNeedsBgSetup, kJourneyBgGuidedKey;
import '../journey_watch_screen.dart';
import '../train/dest_alarm_screen.dart';
import '../train/train_tracker_screen.dart';
import 'sj_child_school_screen.dart';
import 'sj_share_screen.dart';
import 'sj_where_now.dart';

/// The three Safe Journey cards, in order. Card 0 (Live Location) is the
/// default. Cards 1 and 2 are owned by their own screens (agent/sjalarm) and
/// shown only while their feature flag is on — never a dead card.
enum SjCard { live, alarm, train }

/// Which cards this build shows (pure; flags passed in for tests).
List<SjCard> sjVisibleCards({required bool alarmOn, required bool trainOn}) => [
      SjCard.live,
      if (alarmOn) SjCard.alarm,
      if (trainOn) SjCard.train,
    ];

/// sjlive — SAFE JOURNEY (owner final order 3 Nov 02:25): three cards at the
/// top — Live Location (SELECTED BY DEFAULT: filled accent, check mark,
/// bold), Destination Alarm, Train Tracker — the same names everywhere.
/// Card 1 "Live Location": My Trip, Child School, Request Location, Share
/// for a While; below, "Who is where now" (list + map) and "Works in real
/// life" (screen-off service, battery-saver guide, offline buffer, honest
/// accuracy) — every row is the phone's real state.
class SafeJourneyHubScreen extends StatefulWidget {
  final SjCard initial;
  final OemGuideNative? oem;
  const SafeJourneyHubScreen({super.key, this.initial = SjCard.live, this.oem});
  @override
  State<SafeJourneyHubScreen> createState() => _SafeJourneyHubScreenState();
}

class _SafeJourneyHubScreenState extends State<SafeJourneyHubScreen> {
  late SjCard _card = widget.initial;
  Map<String, dynamic>? _active; // my own live journey / share, if any
  OemInfo? _oem;
  bool _guided = false;
  final _where = GlobalKey<SjWhereNowState>();

  @override
  void initState() {
    super.initState();
    _loadActive();
    _probe();
  }

  bool _firstLoad = true;

  Future<void> _loadActive() async {
    try {
      final j = await context.read<AppState>().api.journeyActive();
      if (!mounted) return;
      setState(() => _active = (j['id'] is num) ? j : null);
      // a running trip / share (or the "Are you OK?" push) opens its live
      // screen at once, like before; Back shows the three cards
      if (_firstLoad && _active != null && widget.initial == SjCard.live) {
        _firstLoad = false;
        unawaited(_go(JourneyLiveScreen(journeyId: (j['id'] as num).toInt())));
      }
    } catch (_) {
      // best-effort: offline -> no "you are sharing" banner
    }
    _firstLoad = false;
  }

  Future<void> _probe() async {
    try {
      final info = await (widget.oem ?? const ChannelOemGuideNative()).info();
      final g = await Settings.getBool(kJourneyBgGuidedKey, false);
      if (mounted) {
        setState(() {
          _oem = info;
          _guided = g;
        });
      }
    } catch (_) {
      // best-effort: unknown phone -> the guide row stays generic
    }
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    unawaited(_loadActive());
    unawaited(_where.currentState?.reload());
  }

  void _select(SjCard c) {
    setState(() => _card = c);
    switch (c) {
      case SjCard.alarm:
        unawaited(_go(const DestAlarmScreen()));
      case SjCard.train:
        unawaited(_go(const TrainTrackerScreen()));
      case SjCard.live:
        break;
    }
  }

  Widget _cardTile(AppLocalizations t, SjCard c) {
    final cs = Theme.of(context).colorScheme;
    final on = _card == c;
    final (icon, name, sub) = switch (c) {
      SjCard.live => (Icons.share_location_rounded, t.sjlNameLive, t.sjlSubLive),
      SjCard.alarm => (Icons.alarm_on_rounded, t.sjlNameAlarm, t.sjlSubAlarm),
      SjCard.train => (Icons.train_rounded, t.sjlNameTrain, t.sjlSubTrain),
    };
    final fg = on ? cs.onPrimary : cs.onSurface;
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        key: ValueKey('sjl_card_${c.name}'),
        color: on ? cs.primary : cs.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: on ? BorderSide.none : BorderSide(color: cs.outlineVariant)),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => _select(c),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
              child: Row(children: [
                Icon(icon, color: fg),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name,
                        style: AType.bodyLarge.copyWith(
                            color: fg, fontWeight: on ? FontWeight.w800 : FontWeight.w500)),
                    Text(sub,
                        style: AType.bodySmall.copyWith(
                            color: on ? cs.onPrimary : cs.onSurfaceVariant)),
                  ]),
                ),
                if (on)
                  Icon(Icons.check_circle_rounded,
                      key: ValueKey('sjl_card_check_${c.name}'), color: fg),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bigButton(String key, IconData icon, String label, String hint, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: ValueKey(key),
      color: cs.primaryContainer,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 96),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 30, color: cs.onPrimaryContainer),
                  const SizedBox(height: Gap.xs),
                  Text(label,
                      style: AType.bodyLarge.copyWith(
                          color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
                  Text(hint,
                      style: AType.bodySmall.copyWith(color: cs.onPrimaryContainer)),
                ]),
          ),
        ),
      ),
    );
  }

  Widget _grid(List<Widget> tiles) => LayoutBuilder(builder: (ctx, c) {
        final scale = MediaQuery.textScalerOf(ctx).scale(1);
        final two = c.maxWidth / scale >= 300;
        final w = two ? (c.maxWidth - Gap.sm) / 2 : c.maxWidth;
        return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final x in tiles) SizedBox(width: w, child: x),
        ]);
      });

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
        child: Semantics(
            header: true,
            child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold))),
      );

  Widget _activeBanner(AppLocalizations t) {
    final j = _active!;
    final share = j['share'] == true;
    return Card(
      key: const ValueKey('sjl_active'),
      color: Brand.successFill.withValues(alpha: 0.14),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: const Icon(Icons.navigation_rounded, color: Brand.successFill),
        title: Text(share ? t.sjlActiveShare : t.sjlActiveTrip,
            style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(t.sjlActiveOpen),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _go(JourneyLiveScreen(journeyId: (j['id'] as num).toInt())),
      ),
    );
  }

  Widget _realRow(String key, IconData icon, String title, String body,
      {Color? color, Widget? action}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color ?? cs.primary),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
            Text(body, style: AType.bodyMedium),
            if (action != null) ...[const SizedBox(height: Gap.xs), action],
          ]),
        ),
      ]),
    );
  }

  Widget _realLife(AppLocalizations t) {
    return ValueListenableBuilder<JourneyTrackState>(
      valueListenable: JourneyTracker.I,
      builder: (ctx, s, _) {
        final live = s.journeyId != null && s.status == 'active';
        final needs = journeyNeedsBgSetup(_oem, guidedBefore: _guided);
        final acc = s.lastFix?.acc;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _realRow(
              'sjl_real_bg',
              live && s.serviceOn ? Icons.lock_clock_rounded : Icons.phonelink_lock_rounded,
              t.sjlRealBgTitle,
              live ? (s.serviceOn ? t.sjlRealBgOn : t.j100KeepOpen) : t.sjlRealBgBody,
              color: live && s.serviceOn ? Brand.successFill : null),
          _realRow(
              'sjl_real_oem',
              needs ? Icons.battery_alert_rounded : Icons.battery_charging_full_rounded,
              t.sjlRealOemTitle,
              needs ? t.sjlRealOemNeeds : (_oem == null ? t.sjlRealOemUnknown : t.sjlRealOemOk),
              color: needs ? Brand.warnInk(ctx) : null,
              action: OutlinedButton.icon(
                key: const ValueKey('sjl_real_oem_open'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.build_circle_rounded),
                label: Text(t.sjlRealOemOpen),
                onPressed: () async {
                  await _go(BatteryGuidanceScreen(native: widget.oem));
                  await Settings.setBool(kJourneyBgGuidedKey, true);
                  unawaited(_probe());
                },
              )),
          _realRow(
              'sjl_real_offline',
              s.queued > 0 ? Icons.cloud_upload_rounded : Icons.cloud_off_rounded,
              t.sjlRealOfflineTitle,
              s.queued > 0
                  ? t.sjlRealOfflineQueued(jDigits(ctx, s.queued))
                  : t.sjlRealOfflineBody,
              color: s.queued > 0 ? Brand.warnInk(ctx) : null),
          _realRow(
              'sjl_real_acc',
              Icons.gps_fixed_rounded,
              t.sjlRealAccTitle,
              [
                if (sjAccText(ctx, t, acc) case final a?) t.sjlRealAccLast(a),
                t.sjlRealAccBody,
              ].join(' ')),
        ]);
      },
    );
  }

  Widget _liveBody(AppLocalizations t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the card above already says what Live Location does
      if (_active != null) ...[_activeBanner(t), const SizedBox(height: Gap.md)],
      _grid([
        _bigButton('sjl_btn_trip', Icons.route_rounded, t.sjlBtnTrip, t.sjlHintTrip,
            () => _go(const JourneyStartScreen())),
        _bigButton('sjl_btn_school', Icons.school_rounded, t.sjlBtnSchool, t.sjlHintSchool,
            () => _go(const SjChildSchoolScreen())),
        _bigButton('sjl_btn_request', Icons.person_pin_circle_rounded, t.sjlBtnRequest,
            t.sjlHintRequest, () => _go(const GuardianJourneyScreen(locationOnly: true))),
        _bigButton('sjl_btn_share', Icons.share_location_rounded, t.sjlBtnShare,
            t.sjlHintShare, () => _go(SjShareScreen(oem: widget.oem))),
      ]),
      _h(t.sjlWhereTitle),
      SjWhereNow(
        key: _where,
        onRequest: () => _go(const GuardianJourneyScreen(locationOnly: true)),
        onOpen: (r) => _go(r['kind'] == 'school'
            ? const SjChildSchoolScreen()
            : const JourneyWatchScreen()),
      ),
      _h(t.sjlRealTitle),
      _realLife(t),
    ]);
  }

  Widget _otherBody(AppLocalizations t, SjCard c) {
    final alarm = c == SjCard.alarm;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(alarm ? t.sjlSubAlarm : t.sjlSubTrain, style: AType.bodyLarge),
      const SizedBox(height: Gap.md),
      FilledButton.icon(
        key: ValueKey('sjl_open_${c.name}'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: Icon(alarm ? Icons.alarm_on_rounded : Icons.train_rounded),
        label: Text(t.sjlOpen(alarm ? t.sjlNameAlarm : t.sjlNameTrain)),
        onPressed: () => _go(alarm ? const DestAlarmScreen() : const TrainTrackerScreen()),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ff = FeatureFlags.instance;
    final cards = sjVisibleCards(
        alarmOn: ff.isOn('dest_alarm'), trainOn: ff.isOn('train_tracker'));
    final card = cards.contains(_card) ? _card : SjCard.live;
    return Scaffold(
      appBar: AppBar(title: Text(t.journeyHubTitle), actions: [
        IconButton(
            key: const ValueKey('sjl_watching'),
            icon: const Icon(Icons.visibility_rounded),
            tooltip: t.j100Following,
            onPressed: () => _go(const JourneyWatchScreen())),
        IconButton(
            key: const ValueKey('sjl_settings'),
            icon: const Icon(Icons.tune_rounded),
            tooltip: t.journeySettingsTitle,
            onPressed: () => _go(const JourneySettingsScreen())),
      ]),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadActive();
          await _where.currentState?.reload();
        },
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            for (final c in cards) ...[
              _cardTile(t, c),
              const SizedBox(height: Gap.sm),
            ],
            const SizedBox(height: Gap.sm),
            if (card == SjCard.live) _liveBody(t) else _otherBody(t, card),
          ],
        ),
      ),
    );
  }
}
