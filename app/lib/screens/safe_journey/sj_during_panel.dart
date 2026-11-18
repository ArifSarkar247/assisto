import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/journey_ride.dart' show jKm;
import '../../widgets/password_field.dart';
import '../journey_watch_screen.dart';
import 'sj_danger_audio.dart';
import 'sj_during_api.dart';
import 'sj_private_ask_screen.dart';

/// sjduring — the traveller's DURING panel on the live journey screen:
///  * the one state (Moving / Slow in traffic / Stopped N min / Off route /
///    Nearly there / Phone off / Arrived) — late while moving is only
///    "Slow in traffic", never an alarm;
///  * the PRIVATE ask: opens [SjPrivateAskScreen] by itself (once per ask)
///    and stays as a banner until answered;
///  * the PIN on an abnormal arrival (too early / after a route change or a
///    long stop / always): safe PIN -> Arrived ("Confirmed with PIN" for
///    the family); danger PIN -> the SAME Arrived here, while the family
///    silently gets red + live location + a quiet 30 s clip;
///  * night trips: a note that Assisto checks in more often;
///  * "You are also watching": other journeys at once (husband and wife on
///    different routes watch each other).
/// Polls GET /journey/<id>/during every 30 s (the server sweeper decides;
/// this only shows it).
class SjDuringPanel extends StatefulWidget {
  final int journeyId;

  /// The trip is over on this phone. [keepTracking] is true after a danger
  /// PIN: the screen shows Arrived but the location service keeps going
  /// for the watchers (the server ends it).
  final void Function(bool keepTracking) onArrived;

  /// "Danger" on the private screen -> the SOS screen (fcsos).
  final VoidCallback onDanger;

  /// Tests: no periodic poll.
  final bool poll;

  /// gap-safejourney: false when the screen above already shows "km left"
  /// from the phone's own fresh fix — two different numbers on one screen
  /// (phone vs server) confused travellers.
  final bool showDistance;
  const SjDuringPanel(
      {super.key,
      required this.journeyId,
      required this.onArrived,
      required this.onDanger,
      this.poll = true,
      this.showDistance = true});

  @override
  State<SjDuringPanel> createState() => _SjDuringPanelState();
}

class _SjDuringPanelState extends State<SjDuringPanel> with WidgetsBindingObserver {
  Map<String, dynamic> _d = const {};
  List<Map<String, dynamic>> _watching = const [];
  Timer? _timer;
  String? _shownAsk;
  String? _shownPin;
  bool _pinOpen = false;
  bool _askOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    if (widget.poll) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final api = context.read<AppState>().api;
    try {
      final d = await api.sjDuring(widget.journeyId);
      if (!mounted) return;
      setState(() => _d = d);
    } catch (_) {
      return; // offline: the tracker's own state still shows
    }
    try {
      final b = await api.sjWatchBoard();
      if (mounted) {
        setState(() => _watching = [
              for (final r in (b['active'] as List? ?? const []))
                if (r is Map) r.cast<String, dynamic>()
            ]);
      }
    } catch (_) {
      // best-effort: the "also watching" list is extra
    }
    if (mounted) _react(); // sosfam-crm-proof: the journey screen may close meanwhile
  }

  void _react() {
    if (!mounted) return; // reality 44220546983: context after unmount
    final ask = _d['ask'];
    if (ask is Map && !_askOpen && _shownAsk != '${ask['id']}') {
      _shownAsk = '${ask['id']}';
      unawaited(_openAsk(ask.cast<String, dynamic>()));
      return;
    }
    final pw = _d['pin_wait'];
    // sjproof: a manual "I've arrived" tap now also sets pin_wait — the live
    // screen's own PIN box is already open then; never stack a second one
    // (asked again on the next poll if that box was closed without a PIN)
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (pw is Map && !_pinOpen && onTop && _shownPin != '${pw['at']}') {
      _shownPin = '${pw['at']}';
      unawaited(_askPin());
    }
  }

  Future<void> _openAsk(Map<String, dynamic> ask) async {
    _askOpen = true;
    final r = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => SjPrivateAskScreen(journeyId: widget.journeyId, ask: ask)));
    _askOpen = false;
    if (!mounted) return;
    if (r == 'danger') {
      widget.onDanger();
      return;
    }
    if (r != null) unawaited(_load());
  }

  String _pinWhy(AppLocalizations t) {
    final why = ((_d['pin_wait'] as Map?)?['why'] as List?)?.map((e) => '$e').toList() ?? const [];
    if (why.contains('too_early')) return t.sjdPinWhyEarly;
    if (why.contains('off_route') || why.contains('long_stop')) return t.sjdPinWhyRoute;
    return t.sjdPinWhyAlways;
  }

  Future<void> _askPin() async {
    _pinOpen = true;
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    String? err;
    while (mounted) {
      final ctrl = TextEditingController();
      final pin = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.sjdPinTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_pinWhy(t), style: AType.bodyMedium),
            if (err != null) ...[
              const SizedBox(height: Gap.xs),
              Text(err, style: AType.bodyMedium.copyWith(color: Theme.of(ctx).colorScheme.error)),
            ],
            const SizedBox(height: Gap.sm),
            ObscureTextField(
              key: const ValueKey('sjd_pin_field'),
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(labelText: t.sosPinLabel),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: Text(t.cancel)),
            FilledButton(
                key: const ValueKey('sjd_pin_ok'),
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(t.sjdPinConfirm)),
          ],
        ),
      );
      if (pin == null || pin.isEmpty || !mounted) break;
      Map<String, dynamic> r;
      try {
        r = await api.sjArrivePin(widget.journeyId, pin);
      } catch (_) {
        err = t.grpActionFailed;
        continue;
      }
      if (r['pin'] == 'wrong') {
        err = t.sjdPinWrong;
        continue;
      }
      if (r['pin'] == 'locked') {
        err = t.sjdPinLocked;
        continue;
      }
      if (r['status'] == 'arrived') {
        // identical screen for the safe and the danger PIN
        final danger = r['k'] == 1;
        if (danger) unawaited(sjRecordDangerClip(api, widget.journeyId));
        _pinOpen = false;
        widget.onArrived(danger);
        return;
      }
      break;
    }
    _pinOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    if (_d.isEmpty) return const SizedBox.shrink();
    final look = sjStateLook(context, t, _d);
    final why = sjPhoneOffWhy(t, _d);
    final dist = _d['distance_m'] as num?;
    final ask = _d['ask'];
    final early = DateTime.tryParse('${_d['earliest_at'] ?? ''}');
    final tooEarly = _d['state'] == 'nearly' && early != null && early.isAfter(DateTime.now());
    final others = _watching;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: Gap.md),
      Semantics(
        container: true,
        label: look.label,
        child: Container(
          key: const ValueKey('sjd_state'),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: look.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Radii.md)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(look.icon, color: look.color),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(look.label,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
            ]),
            if (dist != null && widget.showDistance)
              Text(t.j2ToGo(jKm(context, dist)),
                  key: const ValueKey('sjd_state_dist'), style: AType.bodyMedium),
            if (why.isNotEmpty) Text(why, style: AType.bodyMedium),
            if (_d['near_note'] == true)
              Text(t.sjdNearNote, style: AType.bodyMedium.copyWith(color: Brand.successFill)),
            if (tooEarly)
              Text(t.sjdEarlyNote, key: const ValueKey('sjd_early'), style: AType.bodyMedium),
            if (_d['night'] == true)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(children: [
                  Icon(Icons.nightlight_round, size: 18, color: cs.primary),
                  const SizedBox(width: Gap.xs),
                  Expanded(child: Text(t.sjdNightOn, style: AType.bodySmall)),
                ]),
              ),
          ]),
        ),
      ),
      if (ask is Map) ...[
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('sjd_ask_banner'),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: Brand.warnInk(context),
              foregroundColor: cs.surface),
          icon: const Icon(Icons.lock_rounded),
          label: Text(t.sjdOnlyYourPhone),
          onPressed: () => _openAsk(ask.cast<String, dynamic>()),
        ),
      ],
      if (_d['pin_wait'] is Map) ...[
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('sjd_pin_banner'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.pin_rounded),
          label: Text(t.sjdPinTitle),
          onPressed: _pinOpen ? null : _askPin,
        ),
      ],
      if (_d['pin_configured'] == true)
        SwitchListTile(
          key: const ValueKey('sjd_pin_always'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.sjdPinAlways),
          subtitle: Text(t.sjdPinAlwaysSub),
          value: _d['arrive_always'] == true,
          onChanged: (v) async {
            final api = context.read<AppState>().api;
            setState(() => _d = {..._d, 'arrive_always': v});
            try {
              await api.sjSetPinPref(v);
            } catch (_) {
              if (mounted) setState(() => _d = {..._d, 'arrive_always': !v});
            }
          },
        ),
      if (others.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(t.sjdAlsoWatching, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
        for (final o in others)
          ListTile(
            key: ValueKey('sjd_also_${o['id']}'),
            contentPadding: EdgeInsets.zero,
            minTileHeight: 48,
            leading: Icon(sjModeIcon('${o['mode'] ?? ''}'), color: cs.primary),
            title: Text('${o['name'] ?? ''}'),
            subtitle: Text([
              sjStateLook(context, t, o).label,
              if (o['distance_m'] is num) t.j2ToGo(jKm(context, o['distance_m'] as num)),
            ].join(' · ')),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen())),
          ),
      ],
    ]);
  }
}
