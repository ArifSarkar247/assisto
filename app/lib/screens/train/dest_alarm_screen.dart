import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/dest_alarm_math.dart';
import '../../train/dest_alarm_service.dart';
import '../../train/train_api.dart';
import '../../vehicle/veh_map.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../journey_map_pick_screen.dart';

/// train: DESTINATION ALARM (flag `dest_alarm`). Pick a station (bundled,
/// works offline) or any place on the map, choose 1 km / 500 m / 300 m /
/// 100 m / custom, and the phone wakes you — loud even on silent, also in
/// earphones, with the stop name in Bangla. The distance is computed on the
/// phone (no internet needed); GPS is checked slowly when far and fast when
/// near; a visible notification with Stop is shown only while it is on.
class DestAlarmScreen extends StatefulWidget {
  /// Stops of the train the user came from (shown first).
  final List<String> suggestedIds;
  final List<Map<String, dynamic>> suggested;

  /// Test seam: stations without the asset bundle.
  static List<DestStation>? debugStations;

  const DestAlarmScreen({super.key, this.suggestedIds = const [], this.suggested = const []});

  @override
  State<DestAlarmScreen> createState() => _DestAlarmScreenState();
}

class _DestAlarmScreenState extends State<DestAlarmScreen> {
  final _q = TextEditingController();
  List<DestStation> _all = const [];
  DestTarget? _target;
  int _radius = 1000;
  bool _custom = false;
  double _customM = 700;

  DestAlarmController get _c => DestAlarmController.I;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    unawaited(_loadStations());
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

  Future<void> _loadStations() async {
    final dbg = DestAlarmScreen.debugStations;
    if (dbg != null) {
      setState(() => _all = dbg);
      return;
    }
    try {
      final raw = await rootBundle.loadString('assets/train/stations_bd.json');
      if (mounted) setState(() => _all = parseStations(raw));
    } catch (_) {
      // best-effort: "pick on map" still works
    }
  }

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';
  String _d(String s) => notifLocalizeDigits(context, s);

  String _dist(AppLocalizations t, double m) =>
      _d(m >= 1000 ? t.trKm((m / 1000).toStringAsFixed(1)) : t.trMetres(m.round().toString()));

  Future<void> _pickMap() async {
    VehMapConfig cfg = const VehMapConfig();
    try {
      final r = await context.read<AppState>().api.trainConfig();
      if (r['map'] is Map) cfg = VehMapConfig.fromJson(Map<String, dynamic>.from(r['map'] as Map));
    } catch (_) {
      // offline: the picker shows its own honest no-map state
    }
    if (!mounted) return;
    final p = await Navigator.push<({double lat, double lng})>(
        context, MaterialPageRoute(builder: (_) => JourneyMapPickScreen(config: cfg)));
    if (p != null && mounted) {
      final t = AppLocalizations.of(context);
      setState(() => _target = DestTarget(t.trMapPlace, p.lat, p.lng));
    }
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    final tg = _target;
    if (tg == null) return;
    final r = _custom ? clampRadius(_customM.round()) : _radius;
    await _c.start(
        tg,
        r,
        DestAlarmTexts(
          notifTitle: t.trAlarmNotifTitle,
          notifText: t.trAlarmNotifText(tg.name),
          stop: t.trStop,
          spoken: t.trAlarmSpoken(tg.name),
          lang: _bn ? 'bn' : 'en',
        ));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _c.value;
    return Scaffold(
      appBar: AppBar(title: Text(t.trAlarmTitle)),
      body: s.phase == DestAlarmPhase.off ? _setup(t) : _running(t, s),
    );
  }

  Widget _running(AppLocalizations t, DestAlarmState s) {
    final cs = Theme.of(context).colorScheme;
    final ringing = s.phase == DestAlarmPhase.ringing;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        Semantics(
          liveRegion: true,
          child: Text(ringing ? t.trAlarmRinging(s.target?.name ?? '') : t.trAlarmWatching(s.target?.name ?? ''),
              style: AType.headlineSmall),
        ),
        const SizedBox(height: Gap.sm),
        if (s.distanceM != null)
          Text(t.trAlarmDistance(_dist(t, s.distanceM!), _dist(t, s.radiusM.toDouble())),
              style: AType.bodyLarge),
        if (s.locationOff)
          Text(t.trAlarmLocationOff, style: AType.bodyMedium.copyWith(color: cs.error)),
        Text(_d(t.trAlarmInterval('${s.interval.inSeconds}')), style: AType.bodySmall),
        if (!s.serviceOn)
          Text(t.trAlarmKeepOpen, style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
        const SizedBox(height: Gap.xl),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(ringing ? 96 : 56),
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
              textStyle: ringing ? AType.headlineSmall : AType.titleMedium),
          icon: const Icon(Icons.alarm_off_rounded),
          label: Text(t.trAlarmStop),
          onPressed: () => _c.stop(),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.trAlarmOffline, style: AType.bodySmall),
      ],
    );
  }

  Widget _setup(AppLocalizations t) {
    final suggested = [
      for (final m in widget.suggested)
        if (m['lat'] is num && m['lng'] is num)
          DestStation('${m['id']}', '${m['en'] ?? ''}', '${m['bn'] ?? ''}',
              (m['lat'] as num).toDouble(), (m['lng'] as num).toDouble())
    ];
    final list = _q.text.trim().isEmpty && suggested.isNotEmpty
        ? suggested
        : searchStations(_all, _q.text, limit: 30);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
      children: [
        Text(t.trAlarmBenefit, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        Text(t.trAlarmWhere, style: AType.titleSmall),
        if (_target != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.flag_rounded),
              title: Text(_target!.name),
              trailing: IconButton(
                  tooltip: t.trChange,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _target = null)),
            ),
          )
        else ...[
          TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                labelText: t.trStationSearch,
                border: const OutlineInputBorder()),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.map_rounded),
            label: Text(t.trPickOnMap),
            onPressed: _pickMap,
          ),
          for (final st in list)
            ListTile(
              leading: const Icon(Icons.train_rounded),
              title: Text(st.name(_bn)),
              onTap: () => setState(() => _target = DestTarget(st.name(_bn), st.lat, st.lng)),
            ),
        ],
        const SizedBox(height: Gap.md),
        Text(t.trAlarmRadius, style: AType.titleSmall),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final r in kRadiusPresets)
            ChoiceChip(
              label: Text(_dist(t, r.toDouble())),
              selected: !_custom && _radius == r,
              onSelected: (_) => setState(() {
                _custom = false;
                _radius = r;
              }),
            ),
          ChoiceChip(
            label: Text(t.trCustom),
            selected: _custom,
            onSelected: (_) => setState(() => _custom = true),
          ),
        ]),
        if (_custom)
          Slider(
            value: _customM,
            min: kCustomMin.toDouble(),
            max: kCustomMax.toDouble(),
            divisions: (kCustomMax - kCustomMin) ~/ 50,
            label: _dist(t, _customM),
            semanticFormatterCallback: (v) => _dist(t, v),
            onChanged: (v) => setState(() => _customM = v),
          ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(Icons.alarm_on_rounded),
          label: Text(t.trAlarmStart),
          onPressed: _target == null ? null : _start,
        ),
        const SizedBox(height: Gap.sm),
        Text(t.trAlarmOffline, style: AType.bodySmall),
        Text(t.trOsmAttribution, style: AType.bodySmall),
      ],
    );
  }
}
