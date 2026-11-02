import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../train/dest_alarm_math.dart';
import '../train/dest_alarm_service.dart';
import '../train/journey_transit.dart';
import 'notif_models.dart' show notifLocalizeDigits;

/// journeymode (owner order 2 Nov 17:40) — the Safe Journey parts of "how
/// are you going?": the travel chips, the train (train tracker's picker),
/// the destination alarm switch + its mode settings, and the train card the
/// traveller and the watchers see. Train parts need the flag
/// `train_tracker`, alarm parts `dest_alarm`; without them the journey works
/// exactly as before (nothing dead is shown).

bool get jmTrainOn => FeatureFlags.instance.isOn('train_tracker');
bool get jmAlarmOn => FeatureFlags.instance.isOn('dest_alarm');

String jTravelLabel(AppLocalizations t, String m) => switch (m) {
      'local_bus' => t.jmModeLocalBus,
      'long_bus' => t.trModeLongBus,
      'train' => t.trModeTrain,
      'metro' => t.trModeMetro,
      'launch' => t.trModeLaunch,
      'car' => t.journeyModeCar,
      'cng' => t.journeyModeCng,
      _ => '',
    };

IconData jTravelIcon(String m) => switch (m) {
      'local_bus' => Icons.directions_bus_rounded,
      'long_bus' => Icons.airport_shuttle_rounded,
      'train' => Icons.train_rounded,
      'metro' => Icons.subway_rounded,
      'launch' => Icons.directions_boat_rounded,
      'car' => Icons.directions_car_rounded,
      _ => Icons.local_taxi_rounded,
    };

String jmDist(BuildContext context, AppLocalizations t, double m) => notifLocalizeDigits(
    context, m >= 1000 ? t.trKm((m / 1000).toStringAsFixed(1)) : t.trMetres(m.round().toString()));

String _hm(BuildContext context, DateTime d) => TimeOfDay.fromDateTime(d).format(context);

/// The journey's travel choice + alarm settings (owned by the start screen).
class JourneyModeController extends ChangeNotifier {
  /// Test seams: places without the asset bundle.
  static List<DestStation>? debugStations;
  static List<MetroStation>? debugMetro;

  /// Gallery seam: a train already picked (as after the picker).
  static JourneyTrainPick? debugTrain;

  String? travel;
  JourneyTrainPick? train;
  bool alarmOn = false;
  int alarmM = 0;
  AlertPrefs alerts = const AlertPrefs();
  List<DestStation> stations = const [];
  List<MetroStation> metro = const [];
  int? metroFrom, metroTo;
  bool _assets = false;

  TransportMode? get alarmMode => alarmModeFor(travel);

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners(); // async loads may end after the screen closed
  }

  Future<void> init() async {
    travel = await loadTravelMode();
    await _loadAlarm();
    if (travel == 'train') train = debugTrain;
    notifyListeners();
  }

  Future<void> select(String m) async {
    travel = m;
    if (m != 'train') train = null;
    unawaited(saveTravelMode(m));
    await _loadAlarm();
    notifyListeners();
  }

  Future<void> _loadAlarm() async {
    final (setM, a) = await alarmMemoryFor(travel);
    alarmM = setM;
    alerts = a;
    alarmOn = alarmOnByDefault(travel);
    if (travel == 'train' || travel == 'metro') await _loadAssets();
  }

  Future<void> _loadAssets() async {
    if (_assets) return;
    _assets = true;
    stations = debugStations ?? const [];
    metro = debugMetro ?? const [];
    try {
      if (debugStations == null) {
        stations = parseStations(await rootBundle.loadString('assets/train/stations_bd.json'));
      }
      if (debugMetro == null) {
        metro = parseMetro(await rootBundle.loadString('assets/train/metro_dhaka.json'));
      }
    } catch (_) {
      // best-effort: the train alarm then uses the listed stops / GPS rule
    }
  }

  void setTrain(JourneyTrainPick? p) {
    train = p;
    notifyListeners();
  }

  void setAlarmOn(bool v) {
    alarmOn = v;
    notifyListeners();
  }

  void setAlarmM(int m, {bool save = false}) {
    final mode = alarmMode;
    if (mode == null) return;
    alarmM = clampFor(mode, m);
    if (save) unawaited(DestModeMemory.save(mode, alarmM, alerts));
    notifyListeners();
  }

  void setMetro({int? from, int? to}) {
    if (from != null) metroFrom = from;
    if (to != null) metroTo = to;
    notifyListeners();
  }

  /// Metro: guess the stations from here / the destination (both editable).
  void guessMetro({double? hereLat, double? hereLng, double? destLat, double? destLng}) {
    if (metro.isEmpty) return;
    metroFrom ??= nearestMetro(metro, hereLat, hereLng);
    metroTo ??= nearestMetro(metro, destLat, destLng);
  }

  /// The alarm to arm at start, or null (off / flag off / nothing to ring for).
  DestPlan? plan({required String destName, double? destLat, double? destLng, required bool bn}) {
    if (!alarmOn || !jmAlarmOn) return null;
    return preview(destName: destName, destLat: destLat, destLng: destLng, bn: bn);
  }

  /// The plan as it would be with the alarm on (for the explanation line).
  DestPlan? preview({required String destName, double? destLat, double? destLng, required bool bn}) {
    return journeyAlarmPlan(
        travel: travel,
        destName: destName,
        destLat: destLat,
        destLng: destLng,
        setM: alarmM,
        alerts: alerts,
        train: jmTrainOn ? train : null,
        stations: stations,
        bn: bn,
        metro: metro,
        metroFrom: metroFrom,
        metroTo: metroTo);
  }
}

/// "How are you going?" — chips, the train, the alarm.
class JourneyModePicker extends StatelessWidget {
  final JourneyModeController c;
  final bool destPinned;
  final String destName;
  final double? destLat, destLng;
  final ValueChanged<String> onMode;
  final VoidCallback onPickTrain;
  const JourneyModePicker(
      {super.key,
      required this.c,
      required this.destPinned,
      required this.destName,
      required this.onMode,
      required this.onPickTrain,
      this.destLat,
      this.destLng});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: c, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final travel = c.travel;
    final mode = c.alarmMode;
    final tr = c.train;
    final showTrain = travel == 'train' && jmTrainOn;
    final showAlarm = mode != null && jmAlarmOn;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.jmHowGoing, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
      Text(t.jmHowGoingHelp, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(height: Gap.sm),
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (final m in kTravelModes)
          ChoiceChip(
            key: ValueKey('jm_mode_$m'),
            avatar: Icon(jTravelIcon(m), size: 18),
            label: Text(jTravelLabel(t, m)),
            selected: travel == m,
            onSelected: (_) {
              unawaited(c.select(m));
              onMode(m);
            },
          ),
      ]),
      if (showTrain) ...[
        const SizedBox(height: Gap.sm),
        if (tr == null) ...[
          FilledButton.tonalIcon(
            key: const ValueKey('jm_pick_train'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.train_rounded),
            label: Text(t.jmPickTrain),
            onPressed: onPickTrain,
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxs),
            child: Text(t.jmPickTrainHelp, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          ),
        ] else
          Card(
            key: const ValueKey('jm_train_card'),
            child: ListTile(
              minVerticalPadding: Gap.sm,
              leading: const Icon(Icons.train_rounded),
              title: Text(notifLocalizeDigits(context, t.jmTrainTitle(tr.no, tr.nameBn))),
              subtitle: Text(tr.stationAt == null
                  ? t.jmGetOffAt(tr.station.name(bn))
                  : t.jmGetOffAtTime(tr.station.name(bn), _hm(context, tr.stationAt!))),
              trailing: TextButton(
                  key: const ValueKey('jm_train_change'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onPickTrain,
                  child: Text(t.trChange)),
            ),
          ),
      ],
      if (showAlarm) ...[
        const SizedBox(height: Gap.xs),
        SwitchListTile(
          key: const ValueKey('jm_alarm'),
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.alarm_on_rounded),
          title: Text(t.jmAlarmSwitch),
          subtitle: Text(_alarmLine(context, t, bn, mode)),
          value: c.alarmOn,
          onChanged: c.setAlarmOn,
        ),
        if (c.alarmOn) ..._alarmSettings(context, t, cs, bn, mode),
      ],
    ]);
  }

  String _alarmLine(BuildContext context, AppLocalizations t, bool bn, TransportMode mode) {
    switch (mode) {
      case TransportMode.metro:
        return t.jmAlarmMetro;
      case TransportMode.train:
        final p = c.preview(destName: destName, destLat: destLat, destLng: destLng, bn: bn);
        final prev = p?.prevStation;
        if (prev != null &&
            trainLegUsable(prev.lat, prev.lng, p!.target.lat, p.target.lng)) {
          return t.jmAlarmTrainPrev(prev.name);
        }
        return t.jmAlarmTrainGps(jmDist(context, t, c.alarmM.toDouble()));
      default:
        return t.jmAlarmBus(jmDist(context, t, c.alarmM.toDouble()));
    }
  }

  List<Widget> _alarmSettings(
      BuildContext context, AppLocalizations t, ColorScheme cs, bool bn, TransportMode mode) {
    final spec = kModeSpecs[mode]!;
    final out = <Widget>[];
    if (mode == TransportMode.metro) {
      if (c.metro.length >= 2) {
        out.addAll([
          for (final from in [true, false])
            Padding(
              key: ValueKey('jm_metro_${from}_${from ? c.metroFrom : c.metroTo}'),
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: DropdownButtonFormField<int>(
                key: ValueKey(from ? 'jm_metro_from' : 'jm_metro_to'),
                initialValue: from ? c.metroFrom : c.metroTo,
                isExpanded: true,
                decoration: InputDecoration(labelText: from ? t.jmMetroFrom : t.jmMetroTo),
                items: [
                  for (var i = 0; i < c.metro.length; i++)
                    DropdownMenuItem(value: i, child: Text(c.metro[i].name(bn))),
                ],
                onChanged: (v) => from ? c.setMetro(from: v) : c.setMetro(to: v),
              ),
            ),
        ]);
      }
      if (c.metroFrom == null || c.metroTo == null || c.metroFrom == c.metroTo) {
        out.add(Text(t.jmMetroPick,
            key: const ValueKey('jm_metro_pick'),
            style: AType.bodySmall.copyWith(color: Brand.warnInk(context))));
      }
    } else {
      if (mode != TransportMode.train || c.train == null) {
        out.add(Semantics(
          label: t.jmAlarmSwitch,
          child: Slider(
            key: const ValueKey('jm_alarm_m'),
            value: c.alarmM.toDouble().clamp(spec.minM.toDouble(), spec.maxM.toDouble()),
            min: spec.minM.toDouble(),
            max: spec.maxM.toDouble(),
            divisions: ((spec.maxM - spec.minM) / (spec.maxM > 5000 ? 500 : 10)).round(),
            label: jmDist(context, t, c.alarmM.toDouble()),
            semanticFormatterCallback: (v) => jmDist(context, t, v),
            onChanged: (v) => c.setAlarmM(v.round()),
            onChangeEnd: (v) => c.setAlarmM(v.round(), save: true),
          ),
        ));
      }
      final hasTarget = destPinned || (mode == TransportMode.train && c.train != null);
      if (!hasTarget) {
        out.add(Text(t.jmAlarmNeedsPin,
            key: const ValueKey('jm_alarm_needs_pin'),
            style: AType.bodySmall.copyWith(color: Brand.warnInk(context))));
      }
    }
    out.add(Text(t.jmAlarmPhoneOnly, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)));
    return out;
  }
}

/// Where the linked train is — for the traveller AND the watchers (the
/// server's `train` block; every time is an estimate and says so).
class JourneyTrainInfo extends StatelessWidget {
  final Map train;
  final VoidCallback? onOpen;
  const JourneyTrainInfo({super.key, required this.train, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    String d(String s) => notifLocalizeDigits(context, s);
    String st(Object? m) {
      if (m is! Map) return '';
      final b = '${m['bn'] ?? ''}', e = '${m['en'] ?? ''}';
      return bn && b.isNotEmpty ? b : (e.isNotEmpty ? e : b);
    }

    final basis = '${train['basis'] ?? 'timetable'}';
    final next = st(train['next_stop']);
    final to = st(train['to']);
    final eta = DateTime.tryParse('${train['to_eta'] ?? ''}')?.toLocal();
    final delay = (train['delay_min'] as num?)?.toInt();
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('jm_train_info'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.train_rounded, color: cs.onTertiaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(d(t.jmTrainTitle('${train['no'] ?? ''}', '${train['name_bn'] ?? ''}')),
                  style: AType.titleSmall.copyWith(
                      color: cs.onTertiaryContainer, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.xxs),
          if (train['passed'] == true && to.isNotEmpty)
            Text(t.jmTrainPassed(to), style: AType.bodyMedium.copyWith(color: cs.onTertiaryContainer))
          else ...[
            if (next.isNotEmpty)
              Text(t.jmNextStation(next), style: AType.bodyMedium.copyWith(color: cs.onTertiaryContainer)),
            if (eta != null && to.isNotEmpty)
              Text(t.jmReachesAt(to, _hm(context, eta)),
                  style: AType.bodyMedium.copyWith(color: cs.onTertiaryContainer)),
          ],
          if (delay != null && delay > 0)
            Text(d(t.jmTrainLate('$delay')),
                style: AType.bodyMedium.copyWith(color: cs.onTertiaryContainer, fontWeight: FontWeight.w600)),
          Text(
              basis == 'own'
                  ? t.jmBasisOwn
                  : (basis == 'live' ? t.jmBasisLive : t.jmBasisTimetable),
              style: AType.bodySmall.copyWith(color: cs.onTertiaryContainer)),
          if (onOpen != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('jm_open_train'),
                style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48), foregroundColor: cs.onTertiaryContainer),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.jmOpenTrain),
                onPressed: onOpen,
              ),
            ),
        ]),
      ),
    );
  }
}

/// The alarm a journey armed: on / ringing ("I'm awake") / off button.
class JourneyAlarmStatus extends StatelessWidget {
  final int journeyId;
  final JourneyAlarmLink link;
  const JourneyAlarmStatus({super.key, required this.journeyId, required this.link});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([link, link.c]),
        builder: (context, _) {
          if (!link.armedFor(journeyId)) return const SizedBox.shrink();
          final t = AppLocalizations.of(context);
          final cs = Theme.of(context).colorScheme;
          final s = link.c.value;
          final ringing = s.phase == DestAlarmPhase.ringing;
          return Card(
            key: const ValueKey('jm_alarm_status'),
            color: ringing ? cs.errorContainer : null,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(ringing ? Icons.alarm_rounded : Icons.alarm_on_rounded,
                      color: ringing ? cs.onErrorContainer : null),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(ringing ? t.jmAlarmRinging : t.jmAlarmOnLive,
                        style: AType.titleSmall.copyWith(
                            fontWeight: FontWeight.w700,
                            color: ringing ? cs.onErrorContainer : null)),
                  ),
                ]),
                if (s.plan != null && !ringing)
                  Text(t.jmGetOffAt(s.plan!.target.name), style: AType.bodySmall),
                const SizedBox(height: Gap.sm),
                ringing
                    ? FilledButton.icon(
                        key: const ValueKey('jm_awake'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                        icon: const Icon(Icons.check_circle_rounded),
                        label: Text(t.trImAwake),
                        onPressed: () => link.disarm(journeyId),
                      )
                    : OutlinedButton.icon(
                        key: const ValueKey('jm_alarm_off'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        icon: const Icon(Icons.alarm_off_rounded),
                        label: Text(t.jmAlarmOff),
                        onPressed: () => link.disarm(journeyId),
                      ),
              ]),
            ),
          );
        },
      );
}
