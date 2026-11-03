import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';

import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/dest_alarm_decide.dart';
import '../../train/dest_alarm_math.dart';
import '../../train/dest_alarm_service.dart';
import '../../train/dest_alarm_sound.dart';
import '../../train/dest_voice_recorder.dart';
import '../../train/train_api.dart';
import '../../vehicle/veh_map.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart' show pickCirclePerson;
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/permission_reason.dart';
import '../journey_map_pick_screen.dart';
import 'trip_recorder_screen.dart';

/// train: DESTINATION ALARM (flag `dest_alarm`, owner final order 2 Nov).
/// Pick how you travel (city bus / long bus / train / Dhaka Metro / launch),
/// where to get off, and how early. It rings BEFORE the stop — never late
/// (poor GPS rings earlier) — works without internet, is loud on silent and
/// keeps going until "I'm awake". Alerts are remembered per travel mode.
class DestAlarmScreen extends StatefulWidget {
  /// Stops of the train the user came from, IN ORDER (train mode).
  final List<Map<String, dynamic>> suggested;
  final List<String> suggestedIds;

  /// The train's own line ([[lat, lng], ...]) — finds the real station
  /// before yours (journeymode), also stations it only passes.
  final List<List<double>> path;

  /// sjalarm: "Set alarm at this station" (Train Tracker) — this stop of
  /// [suggested] is already picked when the screen opens.
  final String? initialStationId;

  /// Test seams: places without the asset bundle.
  static List<DestStation>? debugStations, debugBusStops;
  static List<MetroStation>? debugMetro;

  const DestAlarmScreen(
      {super.key,
      this.suggestedIds = const [],
      this.suggested = const [],
      this.path = const [],
      this.initialStationId});

  @override
  State<DestAlarmScreen> createState() => _DestAlarmScreenState();
}

const String _kSavedKey = 'dest_alarm_saved_places';

/// sjalarm: the people told "arrived" (remembered on the phone).
const String _kNotifyKey = 'dest_alarm_notify_people';

/// The owner-only trip recorder: hidden for everybody except the owner /
/// staff / Owner Admin allow-list (a server "preview" of `trip_recorder`).
bool tripRecorderVisible() {
  final f = FeatureFlags.instance;
  return f.isOn('trip_recorder') && f.isPreview('trip_recorder');
}

/// The alarm's words in the UI language — ONE builder for the standalone
/// alarm and the alarm inside Safe Journey (journeymode).
DestAlarmTexts destAlarmTexts(BuildContext context, AppLocalizations t, String targetName) {
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  String d(String s) => notifLocalizeDigits(context, s);
  String spokenDist(double m) {
    final (km, n) = spokenDistanceParts(m);
    return d(km ? t.trSpokenKm(n) : t.trSpokenMetres(n));
  }

  return DestAlarmTexts(
    distance: spokenDist,
    notifTitle: t.trAlarmNotifTitle,
    notifText: t.trAlarmNotifText(targetName),
    stop: t.trStop,
    lang: bn ? 'bn' : 'en',
    spoken: (stop, dist) => dist.isEmpty ? t.trAlarmSpoken(stop) : t.trAlarmSpokenDist(stop, dist),
    ready: (stop, dist) => t.trAlarmReady(stop, dist),
  );
}

class _DestAlarmScreenState extends State<DestAlarmScreen> {
  final _q = TextEditingController();
  List<DestStation> _stations = const [], _bus = const [], _saved = const [];
  List<MetroStation> _metro = const [];
  TransportMode _mode = TransportMode.train;
  DestTarget? _target;
  DestTarget? _prev;
  int _setM = 2000;
  AlertPrefs _alerts = const AlertPrefs();
  int _metroFrom = 0, _metroTo = 1;
  bool _recording = false;

  /// sjalarm: "Custom" open (slider) / family notice.
  bool _custom = false, _notify = false;
  List<({int id, String name})> _people = const [];

  DestAlarmController get _c => DestAlarmController.I;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _mode = widget.suggested.isNotEmpty ? TransportMode.train : TransportMode.cityBus;
    unawaited(_loadAll());
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _q.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<List<DestStation>> _asset(String name, List<DestStation>? dbg) async {
    if (dbg != null) return dbg;
    try {
      return parseStations(await rootBundle.loadString('assets/train/$name'));
    } catch (_) {
      return const []; // best-effort: "pick on map" still works
    }
  }

  Future<void> _loadAll() async {
    final st = await _asset('stations_bd.json', DestAlarmScreen.debugStations);
    final bus = await _asset('bus_stops_bd.json', DestAlarmScreen.debugBusStops);
    var metro = DestAlarmScreen.debugMetro ?? const <MetroStation>[];
    if (DestAlarmScreen.debugMetro == null) {
      try {
        metro = parseMetro(await rootBundle.loadString('assets/train/metro_dhaka.json'));
      } catch (_) {
        metro = const []; // best-effort: metro mode then says it is unavailable
      }
    }
    var saved = const <DestStation>[];
    try {
      final raw = await Settings.getString(_kSavedKey);
      if (raw != null && raw.isNotEmpty) saved = parseStations(raw);
    } catch (_) {
      saved = const []; // best-effort: none saved
    }
    if (!mounted) return;
    setState(() {
      _stations = st;
      _bus = bus;
      _metro = metro;
      _saved = saved;
      _metroTo = metro.length > 1 ? metro.length - 1 : 0;
    });
    var people = const <({int id, String name})>[];
    var notify = false;
    try {
      final raw = await Settings.getString(_kNotifyKey);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        notify = j['on'] == true;
        people = [
          for (final p in (j['people'] as List? ?? const []))
            if (p is Map && p['id'] is num) (id: (p['id'] as num).toInt(), name: '${p['name'] ?? ''}')
        ];
      }
    } catch (_) {
      people = const []; // best-effort: nobody picked
    }
    if (!mounted) return;
    setState(() {
      _people = people;
      _notify = notify && people.isNotEmpty;
    });
    await _loadMode(_mode);
    _pickInitialStation();
  }

  /// "Set alarm at this station" from the Train Tracker.
  void _pickInitialStation() {
    final id = widget.initialStationId;
    if (id == null || !mounted || _mode != TransportMode.train) return;
    final stops = _trainStops();
    final i = stops.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final st = stops[i];
    final pv = prevStationOnPath(widget.path, _stations, st, listedStops: stops);
    setState(() {
      _target = DestTarget(st.name(_bn), st.lat, st.lng);
      _prev = pv == null ? null : DestTarget(pv.name(_bn), pv.lat, pv.lng);
    });
  }

  List<DestStation> _trainStops() => [
        for (final m in widget.suggested)
          if (m['lat'] is num && m['lng'] is num)
            DestStation('${m['id']}', '${m['en'] ?? ''}', '${m['bn'] ?? ''}',
                (m['lat'] as num).toDouble(), (m['lng'] as num).toDouble())
      ];

  Future<void> _saveNotify() => Settings.setString(
      _kNotifyKey,
      jsonEncode({
        'on': _notify,
        'people': [for (final p in _people) {'id': p.id, 'name': p.name}]
      }));

  Future<void> _addPerson() async {
    final t = AppLocalizations.of(context);
    final row = await pickCirclePerson(context, title: t.sjaPickPerson);
    if (row == null || !mounted) return;
    final id = (row['circle_id'] as num?)?.toInt();
    if (id == null || _people.any((p) => p.id == id)) return;
    setState(() {
      _people = [..._people, (id: id, name: '${row['name'] ?? ''}')];
      _notify = true;
    });
    await _saveNotify();
  }

  Future<void> _loadMode(TransportMode m) async {
    final (setM, alerts) = await DestModeMemory.load(m);
    if (!mounted) return;
    setState(() {
      _mode = m;
      _setM = setM;
      _alerts = alerts;
      _custom = !presetsFor(m).contains(setM);
      _target = null;
      _prev = null;
      _q.clear();
    });
  }

  Future<void> _remember() => DestModeMemory.save(_mode, _setM, _alerts);

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';
  String _d(String s) => notifLocalizeDigits(context, s);

  String _dist(AppLocalizations t, double m) =>
      _d(m >= 1000 ? t.trKm((m / 1000).toStringAsFixed(1)) : t.trMetres(m.round().toString()));

  String _modeLabel(AppLocalizations t, TransportMode m) => switch (m) {
        TransportMode.cityBus => t.trModeCityBus,
        TransportMode.longBus => t.trModeLongBus,
        TransportMode.train => t.trModeTrain,
        TransportMode.metro => t.trModeMetro,
        TransportMode.launch => t.trModeLaunch,
      };

  IconData _modeIcon(TransportMode m) => switch (m) {
        TransportMode.cityBus => Icons.directions_bus_rounded,
        TransportMode.longBus => Icons.airport_shuttle_rounded,
        TransportMode.train => Icons.train_rounded,
        TransportMode.metro => Icons.subway_rounded,
        TransportMode.launch => Icons.directions_boat_rounded,
      };

  Future<void> _pickMap() async {
    final t = AppLocalizations.of(context);
    VehMapConfig cfg = const VehMapConfig();
    try {
      final r = await context.read<AppState>().api.trainConfig();
      if (r['map'] is Map) cfg = VehMapConfig.fromJson(Map<String, dynamic>.from(r['map'] as Map));
    } catch (_) {
      // best-effort: offline -> no map; the snackbar below says so
    }
    if (!mounted) return;
    if (!cfg.hasTiles) {
      // the map picker only opens when map tiles are configured (journey2 rule)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.trMapNoTiles)));
      return;
    }
    if (!mounted) return;
    final p = await Navigator.push<({double lat, double lng})>(
        context, MaterialPageRoute(builder: (_) => JourneyMapPickScreen(config: cfg)));
    if (p == null || !mounted) return;
    setState(() => _target = DestTarget(t.trMapPlace, p.lat, p.lng));
  }

  /// User-saved stops (city bus): kept on the phone only.
  Future<void> _saveTarget() async {
    final tg = _target;
    if (tg == null) return;
    final t = AppLocalizations.of(context);
    final ctl = TextEditingController(text: tg.name == t.trMapPlace ? '' : tg.name);
    final name = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: ctl,
              autofocus: true,
              decoration: InputDecoration(labelText: t.trStopName, border: const OutlineInputBorder())),
          const SizedBox(height: Gap.sm),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(t.trSaveStop),
          ),
        ]),
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final list = [
      ..._saved,
      DestStation('s${DateTime.now().millisecondsSinceEpoch}', name, name, tg.lat, tg.lng)
    ];
    await Settings.setString(
        _kSavedKey,
        jsonEncode({
          'stations': [
            for (final s in list) {'id': s.id, 'en': s.en, 'bn': s.bn, 'lat': s.lat, 'lng': s.lng}
          ]
        }));
    setState(() {
      _saved = list;
      _target = DestTarget(name, tg.lat, tg.lng);
    });
  }


  DestAlarmTexts _texts(AppLocalizations t, String targetName) =>
      destAlarmTexts(context, t, targetName);

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    await _remember();
    final ids = _notify ? [for (final p in _people) p.id] : const <int>[];
    if (ids.isNotEmpty) {
      final api = context.read<AppState>().api;
      // only after "I am awake" — the alarm itself never uses the network
      DestAlarmController.arrivedNotifier = (plan) async {
        final r = await api.postJson('/train/alarm/arrived',
            {'stop': plan.target.name, 'circle_ids': plan.notifyCircleIds});
        return r['ok'] == true;
      };
    }
    if (_mode == TransportMode.metro) {
      if (_metro.length < 2 || _metroFrom == _metroTo) return;
      final to = _metro[_metroTo];
      final tg = DestTarget(to.name(_bn), to.lat, to.lng);
      await _c.start(
          DestPlan(
              mode: _mode,
              target: tg,
              setM: 0,
              alerts: _alerts,
              metro: _metro,
              metroFrom: _metroFrom,
              metroTo: _metroTo,
              metroLeftAt: DateTime.now(),
              notifyCircleIds: ids),
          _texts(t, tg.name));
      return;
    }
    final tg = _target;
    if (tg == null) return;
    await _c.start(
        DestPlan(
            mode: _mode,
            target: tg,
            setM: clampFor(_mode, _setM),
            alerts: _alerts,
            prevStation: _mode == TransportMode.train ? _prev : null,
            notifyCircleIds: ids),
        _texts(t, tg.name));
  }

  Future<void> _record() async {
    final rec = destVoiceRecorderFactory();
    if (!_recording) {
      // Play: in-app disclosure before Android's microphone prompt
      if (!await destVoiceMicGranted() &&
          !await showPermissionReason(context, PermKind.mic)) {
        return;
      }
      if (!mounted) return;
      final ok = await rec.start(_mode);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).trMicDenied)));
        return;
      }
      setState(() => _recording = true);
      _recTimer = Timer(kMaxClip, () => unawaited(_record()));
      _activeRec = rec;
      return;
    }
    _recTimer?.cancel();
    final path = await (_activeRec ?? rec).stop();
    _activeRec = null;
    if (!mounted) return;
    setState(() {
      _recording = false;
      if (path != null && path.isNotEmpty) {
        _alerts = _alerts.withClip(path).toggle(AlertKind.voice, true);
      }
    });
    await _remember();
  }

  Timer? _recTimer;
  DestVoiceRecorder? _activeRec;

  Future<void> _deleteClip() async {
    final p = _alerts.personalClip;
    if (p != null) await destVoiceRecorderFactory().delete(p);
    setState(() => _alerts = _alerts.withClip(null));
    await _remember();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _c.value;
    return Scaffold(
      appBar: AppBar(title: Text(t.sjlNameAlarm), actions: [
        if (tripRecorderVisible())
          IconButton(
            tooltip: t.sjaRecorderTitle,
            icon: const Icon(Icons.route_rounded),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const TripRecorderScreen())),
          ),
      ]),
      body: s.phase == DestAlarmPhase.off ? _setup(t) : _running(t, s),
    );
  }

  Widget _running(AppLocalizations t, DestAlarmState s) {
    final cs = Theme.of(context).colorScheme;
    final ringing = s.phase == DestAlarmPhase.ringing;
    final p = s.plan!;
    final name = p.target.name;
    if (ringing) {
      return Padding(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Spacer(),
          Semantics(
            liveRegion: true,
            child: Text(t.trAlarmRinging(name),
                textAlign: TextAlign.center, style: AType.headlineMedium),
          ),
          if (s.distanceM != null)
            Text(_dist(t, s.distanceM!), textAlign: TextAlign.center, style: AType.titleLarge),
          if (s.reason == RingReason.eta)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(t.sjaRangBySpeed, textAlign: TextAlign.center, style: AType.bodyMedium),
            ),
          if (s.snoozedUntil != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_d(t.sjaSnoozed(_hm(s.snoozedUntil!))),
                  textAlign: TextAlign.center, style: AType.titleSmall),
            ),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(120),
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
                textStyle: AType.headlineSmall),
            icon: const Icon(Icons.check_circle_rounded, size: 36),
            label: Text(t.trImAwake),
            onPressed: () => _c.confirmAwake(),
          ),
          const SizedBox(height: Gap.md),
          if (s.snoozedUntil == null)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              icon: const Icon(Icons.snooze_rounded),
              label: Text(t.sjaSnooze),
              onPressed: () => _c.snooze(),
            ),
          const SizedBox(height: Gap.xl),
        ]),
      );
    }
    final metro = p.mode == TransportMode.metro;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        Semantics(
          liveRegion: true,
          child: Text(t.trAlarmWatching(name), style: AType.headlineSmall),
        ),
        Text(_modeLabel(t, p.mode), style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        if (metro && s.metroAt != null && p.metro.isNotEmpty) ...[
          Text(t.trMetroNow(p.metro[s.metroAt!].name(_bn)), style: AType.bodyLarge),
          if (s.metroRingAt != null)
            Text(_d(t.trMetroRingAt(_hm(s.metroRingAt!))), style: AType.bodyMedium),
          Text(t.trMetroNoGps, style: AType.bodySmall),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.sync_rounded),
            label: Text(t.trMetroResync),
            onPressed: () => _metroResyncSheet(t, p),
          ),
        ],
        if (!metro && s.distanceM != null)
          Text(t.trAlarmDistance(_dist(t, s.distanceM!), _dist(t, p.setM.toDouble())),
              style: AType.bodyLarge),
        if (!metro && s.accuracyM != null && s.accuracyM! > p.setM)
          Text(t.trNeverLate, style: AType.bodySmall),
        if (!metro && s.speedMps >= kStillMps)
          Text(_d(t.sjaSpeedNow((s.speedMps * 3.6).round().toString())), style: AType.bodyMedium),
        if (!metro) Text(t.sjaGpsNote, style: AType.bodySmall),
        if (!metro && s.locationOff)
          Text(t.trAlarmLocationOff, style: AType.bodyMedium.copyWith(color: cs.error)),
        if (!metro) Text(_d(t.trAlarmInterval('${s.interval.inSeconds}')), style: AType.bodySmall),
        if (!s.serviceOn)
          Text(t.trAlarmKeepOpen, style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
        const SizedBox(height: Gap.xl),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: cs.error,
              foregroundColor: cs.onError),
          icon: const Icon(Icons.alarm_off_rounded),
          label: Text(t.trAlarmStop),
          onPressed: () => _c.stop(),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.trAlarmOffline, style: AType.bodySmall),
      ],
    );
  }

  String _hm(DateTime d) {
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _metroResyncSheet(AppLocalizations t, DestPlan p) async {
    final step = p.metroTo > p.metroFrom ? 1 : -1;
    final idx = <int>[for (var i = p.metroFrom; i != p.metroTo; i += step) i];
    final pick = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ListView(shrinkWrap: true, children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.trMetroResyncQ, style: AType.titleSmall),
        ),
        for (final i in idx)
          ListTile(title: Text(p.metro[i].name(_bn)), onTap: () => Navigator.pop(ctx, i)),
      ]),
    );
    if (pick != null) await _c.metroResync(pick);
  }

  List<DestStation> _placesForMode() {
    switch (_mode) {
      case TransportMode.cityBus:
        return [..._saved, ..._bus];
      case TransportMode.train:
        return _stations;
      case TransportMode.longBus:
      case TransportMode.launch:
        return [..._saved, ..._stations, ..._bus];
      case TransportMode.metro:
        return const [];
    }
  }

  Widget _setup(AppLocalizations t) {
    final spec = kModeSpecs[_mode]!;
    final trainStops = _trainStops();
    final sent = _c.value.arrivedSent;
    final fromTrain = _mode == TransportMode.train && trainStops.isNotEmpty && _q.text.trim().isEmpty;
    final list = fromTrain ? trainStops : searchStations(_placesForMode(), _q.text, limit: 30);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
      children: [
        if (sent != null)
          Card(
            color: sent
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Semantics(
                liveRegion: true,
                child: Text(sent ? t.sjaArrivedSent : t.sjaArrivedFailed,
                    style: AType.bodyMedium.copyWith(
                        color: sent
                            ? Theme.of(context).colorScheme.onSecondaryContainer
                            : Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ),
        Text(t.trAlarmBenefit, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        Text(t.trHowTravel, style: AType.titleSmall),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final m in TransportMode.values)
            ChoiceChip(
              avatar: Icon(_modeIcon(m), size: 18),
              label: Text(_modeLabel(t, m)),
              selected: _mode == m,
              onSelected: (_) => _loadMode(m),
            ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Text(_modeHelp(t), style: AType.bodySmall),
        ),
        const SizedBox(height: Gap.sm),
        if (_mode == TransportMode.metro)
          ..._metroPicker(t)
        else ...[
          Text(t.trAlarmWhere, style: AType.titleSmall),
          if (_target != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.flag_rounded),
                title: Text(_target!.name),
                subtitle: _mode == TransportMode.train
                    ? Text(_prev == null ? t.trTrainNoPrev : t.trTrainPrev(_prev!.name))
                    : null,
                trailing: IconButton(
                    tooltip: t.trChange,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                          _target = null;
                          _prev = null;
                        })),
              ),
            ),
          if (_target != null && _mode == TransportMode.cityBus && !_saved.any((s) => s.lat == _target!.lat))
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.bookmark_add_rounded),
              label: Text(t.trSaveStop),
              onPressed: _saveTarget,
            ),
          if (_target == null) ...[
            TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  labelText: _mode == TransportMode.cityBus ? t.trBusStopSearch : t.trStationSearch,
                  border: const OutlineInputBorder()),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.map_rounded),
              label: Text(t.trPickOnMap),
              onPressed: _pickMap,
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Gap.sm),
                child: Text(t.trNoPlaces, style: AType.bodySmall),
              ),
            for (var i = 0; i < list.length; i++)
              ListTile(
                leading: Icon(_modeIcon(_mode)),
                title: Text(list[i].name(_bn)),
                onTap: () => setState(() {
                  _target = DestTarget(list[i].name(_bn), list[i].lat, list[i].lng);
                  final pv = fromTrain
                      ? prevStationOnPath(widget.path, _stations, list[i], listedStops: list)
                      : null;
                  _prev = pv == null ? null : DestTarget(pv.name(_bn), pv.lat, pv.lng);
                }),
              ),
          ],
          const SizedBox(height: Gap.md),
          Text(_mode == TransportMode.train ? t.trTrainFallbackDist : t.trAlarmRadius,
              style: AType.titleSmall),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final m in presetsFor(_mode))
              ChoiceChip(
                label: Text(m == spec.defaultM
                    ? t.sjaPresetDefault(_dist(t, m.toDouble()))
                    : _dist(t, m.toDouble())),
                selected: !_custom && _setM == m,
                onSelected: (_) {
                  setState(() {
                    _setM = m;
                    _custom = false;
                  });
                  unawaited(_remember());
                },
              ),
            ChoiceChip(
              avatar: const Icon(Icons.tune_rounded, size: 18),
              label: Text(t.sjaCustom),
              selected: _custom,
              onSelected: (_) => setState(() => _custom = true),
            ),
          ]),
          if (_custom) ...[
          Text(_dist(t, _setM.toDouble()), style: AType.titleMedium),
          Slider(
            value: _setM.toDouble().clamp(spec.minM.toDouble(), spec.maxM.toDouble()),
            min: spec.minM.toDouble(),
            max: spec.maxM.toDouble(),
            divisions: ((spec.maxM - spec.minM) / (spec.maxM > 5000 ? 500 : 10)).round(),
            label: _dist(t, _setM.toDouble()),
            semanticFormatterCallback: (v) => _dist(t, v),
            onChanged: (v) => setState(() => _setM = v.round()),
            onChangeEnd: (_) => _remember(),
          ),
          ],
          Text(t.sjaGpsNote, style: AType.bodySmall),
        ],
        const SizedBox(height: Gap.md),
        ..._alertControls(t),
        const SizedBox(height: Gap.md),
        ..._familyControls(t),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(Icons.alarm_on_rounded),
          label: Text(t.trAlarmStart),
          onPressed: (_mode == TransportMode.metro ? _metroFrom != _metroTo && _metro.length > 1 : _target != null)
              ? _start
              : null,
        ),
        if (_mode != TransportMode.metro && _target == null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.trPickFirst, style: AType.bodySmall),
          ),
        const SizedBox(height: Gap.sm),
        Text(t.trAlarmOffline, style: AType.bodySmall),
        Text(_mode == TransportMode.metro ? t.trMetroSource : t.trOsmAttribution,
            style: AType.bodySmall),
      ],
    );
  }

  String _modeHelp(AppLocalizations t) => switch (_mode) {
        TransportMode.cityBus => t.trHelpCityBus,
        TransportMode.longBus => t.trHelpLongBus,
        TransportMode.train => t.trHelpTrain,
        TransportMode.metro => t.trHelpMetro,
        TransportMode.launch => t.trHelpLaunch,
      };

  List<Widget> _metroPicker(AppLocalizations t) {
    if (_metro.length < 2) return [Text(t.trNoPlaces, style: AType.bodySmall)];
    DropdownButtonFormField<int> dd(String label, int v, void Function(int) on) =>
        DropdownButtonFormField<int>(
          initialValue: v,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [
            for (var i = 0; i < _metro.length; i++)
              DropdownMenuItem(value: i, child: Text(_metro[i].name(_bn)))
          ],
          onChanged: (x) {
            if (x != null) setState(() => on(x));
          },
        );
    return [
      dd(t.trMetroFrom, _metroFrom, (x) => _metroFrom = x),
      const SizedBox(height: Gap.sm),
      dd(t.trMetroTo, _metroTo, (x) => _metroTo = x),
      if (_metroFrom == _metroTo)
        Text(t.trMetroSame, style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.error)),
    ];
  }

  /// Optional: tell chosen My Circle people "arrived" after "I am awake".
  List<Widget> _familyControls(AppLocalizations t) => [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.sjaNotifyFamily),
          subtitle: Text(t.sjaNotifyFamilySub),
          value: _notify,
          onChanged: (v) async {
            if (v && _people.isEmpty) {
              await _addPerson();
              return;
            }
            setState(() => _notify = v);
            await _saveNotify();
          },
        ),
        if (_notify)
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final p in _people)
              InputChip(
                avatar: const Icon(Icons.person_rounded, size: 18),
                label: Text(p.name),
                deleteButtonTooltipMessage: t.trDelete,
                onDeleted: () async {
                  setState(() {
                    _people = [for (final x in _people) if (x.id != p.id) x];
                    if (_people.isEmpty) _notify = false;
                  });
                  await _saveNotify();
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text(t.sjaAddPerson),
              onPressed: _addPerson,
            ),
          ]),
      ];

  List<Widget> _alertControls(AppLocalizations t) {
    Widget sw(AlertKind k, String title, String sub) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(_alerts.isLastOn(k) ? t.trAlertLastOn : sub),
          value: _alerts.get(k),
          // the last alert that is ON cannot be turned off
          onChanged: _alerts.isLastOn(k)
              ? null
              : (v) {
                  setState(() => _alerts = _alerts.toggle(k, v));
                  unawaited(_remember());
                },
        );
    final clip = _alerts.personalClip;
    return [
      Text(t.trAlertsTitle, style: AType.titleSmall),
      sw(AlertKind.voice, t.trAlertVoice, t.trAlertVoiceSub),
      sw(AlertKind.sound, t.trAlertSound, t.trAlertSoundSub),
      sw(AlertKind.vibrate, t.trAlertVibrate, t.trAlertVibrateSub),
      const SizedBox(height: Gap.xs),
      Text(t.trPersonalVoice, style: AType.titleSmall),
      Text(t.trPersonalVoiceSub, style: AType.bodySmall),
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_recording ? t.trRecordStop : (clip == null ? t.trRecord : t.trRecordAgain)),
          onPressed: _record,
        ),
        if (clip != null && !_recording) ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(t.trPlay),
            onPressed: () async {
              final s = NativeDestAlarmSound();
              await s.playClip(clip);
            },
          ),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(t.trDelete),
            onPressed: _deleteClip,
          ),
        ],
      ]),
    ];
  }
}
