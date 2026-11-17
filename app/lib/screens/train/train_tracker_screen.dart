import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show LocationPermission; // train-app
import '../../ds/ds.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ads/ad_banner_slot.dart';
import '../../ads/ad_reward_gate.dart'; // adcontrol
import '../../api.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/train_api.dart';
import '../../train/train_offline.dart'; // train-app
import '../../train/train_onboard.dart'; // train-app
import '../../train/train_share_service.dart';
import '../../train/train_sms_parse.dart'; // train-app
import '../../train/train_v2_native.dart'; // train-app
import '../../vehicle/route_canvas.dart';
import '../../vehicle/veh_map.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/fam_empty.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/permission_reason.dart'; // train-app
import 'dest_alarm_screen.dart';
import 'train_chat_screen.dart';
import 'train_line_view.dart'; // sjtrain
import 'train_paste_screen.dart'; // train-app
import 'train_seat_card.dart'; // sjtrain
import 'train_v2_widgets.dart'; // train-app

/// train (owner priority C) — find a train, see it live (crowd) or as an
/// honest timetable ESTIMATE, SMS 16318, train chat, destination alarm.
/// Behind the flag `train_tracker` (route owned by it). Free, no ads.
String trainHm(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String trainIsoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String trainStation(Map? s, bool bn) {
  if (s == null) return '';
  final b = '${s['bn'] ?? ''}', e = '${s['en'] ?? ''}';
  return bn && b.isNotEmpty ? b : (e.isNotEmpty ? e : b);
}

/// The train's own line from a /train/<no>/live answer: [[lat, lng], ...].
List<List<double>> trainPath(Map<String, dynamic>? v) => [
      for (final p in (v?['path'] as List? ?? const []))
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num)
          [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
    ];

/// train-app: a suspended / not-running train (the data lane's status).
bool trainSuspended(Map? tr) =>
    tr != null && (tr['suspended'] == true || const {'suspended', 'withdrawn'}.contains('${tr['status']}'));

/// train-app: the final station (lat, lng) — the rider share stops there.
(double, double)? trainLastStop(Map<String, dynamic>? v) {
  final st = ((v?['line'] as Map?)?['stations'] as List?) ?? (v?['stops'] as List?) ?? const [];
  if (st.isEmpty || st.last is! Map) return null;
  final l = st.last as Map;
  final lat = (l['lat'] as num?)?.toDouble(), lng = (l['lng'] as num?)?.toDouble();
  return lat == null || lng == null ? null : (lat, lng);
}

class TrainTrackerScreen extends StatelessWidget {
  const TrainTrackerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final alarmOn = FeatureFlags.instance.isOn('dest_alarm');
    return Scaffold(
      appBar: AppBar(title: Text(t.sjlNameTrain)),
      // owner fix 3 Nov: ONE adaptive banner, Free users only (the slot
      // follows the central ad rules: child accounts, consent, Serve REAL)
      bottomNavigationBar: const AdBannerSlot(screen: 'train_search'),
      body: TrainSearchPanel(
        leading: [
          if (alarmOn)
            DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
              padding: EdgeInsets.zero,
              child: ListTile(
                minVerticalPadding: Gap.md,
                leading: const Icon(Icons.alarm_on_rounded),
                title: Text(t.sjlNameAlarm),
                subtitle: Text(t.trAlarmCardSub),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const DestAlarmScreen())),
              ),
            ),
        ],
        trailing: [
          // train-app: every timetable + the tower map on the phone, and
          // "share a train update" (16318 reply / group post)
          const SizedBox(height: Gap.md),
          const TrainOfflineSection(),
          const SizedBox(height: Gap.sm),
          DsButton.secondary(
            buttonKey: const ValueKey('tr2_paste_open_list'),
            expand: true,
            icon: Icons.content_paste_go_rounded,
            label: t.tr2PasteButton,
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const TrainPasteScreen())),
          ),
          const SizedBox(height: Gap.md),
          Text(t.trDataNote2, style: AType.bodySmall),
        ],
        // adcontrol (owner 10 Nov): one rewarded ad to see a train live,
        // then free for 15 min (owner-editable); never blocks (no ad -> open)
        onPick: (tr, date) => AdRewardGate.run(context,
            placement: 'train_live_unlock',
            grant: AdGateGrant.window,
            unlockId: 'train_live',
            what: t.adGateWhatTrain,
            action: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => TrainLiveScreen(no: '${tr['no']}', date: date)))),
      ),
    );
  }
}

/// Find a train (search + yesterday / today / tomorrow) — ONE picker for the
/// Train tracker and for Safe Journey's "I'm going by train" (journeymode).
class TrainSearchPanel extends StatefulWidget {
  final List<Widget> leading, trailing;
  final void Function(Map<String, dynamic> train, String date) onPick;
  const TrainSearchPanel(
      {super.key, required this.onPick, this.leading = const [], this.trailing = const []});

  @override
  State<TrainSearchPanel> createState() => _TrainSearchPanelState();
}

class _TrainSearchPanelState extends State<TrainSearchPanel> {
  ApiClient get _api => context.read<AppState>().api;
  final _q = TextEditingController();
  Timer? _deb;
  bool _loading = true, _failed = false;
  List<Map<String, dynamic>> _trains = const [];
  int _day = 0; // -1 yesterday, 0 today, 1 tomorrow

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _deb?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.trainSearch(_q.text);
      if (!mounted) return;
      setState(() {
        _trains = [for (final t in (r['trains'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String get _date => trainIsoDate(DateTime.now().add(Duration(days: _day)));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    return Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _q,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                labelText: t.trSearchHint,
              ),
              onChanged: (_) {
                _deb?.cancel();
                _deb = Timer(const Duration(milliseconds: 350), _load);
              },
            ),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final d in const [-1, 0, 1])
                ChoiceChip(
                  label: Text(d == -1 ? t.trYesterday : (d == 0 ? t.trToday : t.trTomorrow)),
                  selected: _day == d,
                  onSelected: (_) => setState(() => _day = d),
                ),
            ]),
          ]),
        ),
        Expanded(
          child: !_loading && !_failed && _trains.isEmpty
              ? FamEmptyState(
                  icon: Icons.train_rounded,
                  title: t.trEmptyTitle,
                  benefit: t.trEmptyBenefit,
                  primaryLabel: t.trShowAll,
                  primaryIcon: Icons.list_rounded,
                  onPrimary: () {
                    _q.clear();
                    unawaited(_load());
                  },
                  steps: [t.trStep1, t.trStep2, t.trStep3],
                )
              : ListView(
                  padding: withNavBarInset(
                      context, const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xxl)),
                  children: [
                    ...widget.leading,
                    ..._results(t, bn),
                    ...widget.trailing,
                  ],
                ),
        ),
      ]);
  }

  List<Widget> _results(AppLocalizations t, bool bn) {
    if (_loading) {
      return const [Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))];
    }
    if (_failed) {
      return [
        Text(t.trLoadFailed, style: AType.bodyLarge),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: DsButton(onPressed: _load, icon: Icons.refresh_rounded, label: t.trRetry),
        ),
      ];
    }
    return [for (final tr in _trains) _card(t, bn, tr)];
  }

  Widget _card(AppLocalizations t, bool bn, Map<String, dynamic> tr) {
    String d(String s) => notifLocalizeDigits(context, s);
    final route = '${trainStation(tr['from'] as Map?, bn)} → ${trainStation(tr['to'] as Map?, bn)}';
    return Card(
      child: InkWell(
        onTap: () => widget.onPick(tr, _date),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d('${tr['no']} · ${tr['name_bn']}'), style: AType.titleMedium),
            const SizedBox(height: Gap.xxs),
            Text(route, style: AType.bodyMedium),
            Text(d(t.trDepArr('${tr['dep']}', '${tr['arr']}')), style: AType.bodySmall),
            // train-app: suspended trains (e.g. cross-border) say so clearly
            if (trainSuspended(tr))
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.tr2Suspended,
                    key: const ValueKey('tr2_suspended'),
                    style: AType.labelLarge.copyWith(
                        color: Theme.of(context).colorScheme.ds.dangerInk, fontWeight: FontWeight.w700)),
              ),
            if (tr['approved'] != true) ...[
              const SizedBox(height: Gap.xs),
              Text(t.trUnchecked, style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
            ],
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- live

class TrainLiveScreen extends StatefulWidget {
  final String no, date;

  /// adcontrol (owner 10 Nov): false when a family member watches a
  /// relative's ACTIVE train journey or the traveller's own Safe Journey —
  /// no ad there (registry row train_family_watch, default OFF).
  final bool showAds;
  const TrainLiveScreen(
      {super.key, required this.no, required this.date, this.showAds = true});

  @override
  State<TrainLiveScreen> createState() => _TrainLiveScreenState();
}

class _TrainLiveScreenState extends State<TrainLiveScreen> {
  ApiClient get _api => context.read<AppState>().api;
  Map<String, dynamic>? _v;
  VehMapConfig _map = const VehMapConfig();
  bool _failed = false;
  Timer? _poll;

  /// train-app: no internet -> the train from the phone's offline pack
  /// (tower + timetable), clearly labelled.
  Map<String, dynamic>? _off;
  TrainOnboardWatch? _watch;
  DateTime _loadedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
    TrainShareController.I.addListener(_onShare);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _watch?.stop();
    TrainShareController.I.removeListener(_onShare);
    super.dispose();
  }

  /// train-app (B): only while this screen is open and the location
  /// permission was already given: moving along this line at train speed
  /// -> ask ONCE "Are you on this train?".
  void _startWatch(Map<String, dynamic> v) {
    if (_watch != null || TrainNative.disabledForTests) return;
    final path = trainPath(v);
    final runs = v['runs'] != false && '${(v['estimate'] as Map?)?['state'] ?? 'running'}' != 'arrived';
    if (path.length < 2 || !runs || TrainShareController.I.sharing) return;
    _watch = TrainOnboardWatch(
        no: widget.no,
        date: widget.date,
        path: path,
        onAsk: () async {
          if (!mounted || TrainShareController.I.sharing) return;
          final name = '${(v['train'] as Map?)?['name_bn'] ?? widget.no}';
          if (await showTrainOnboardAsk(context, name) && mounted) {
            await _startShare(cell: false, by: 'ask');
          }
        });
    unawaited(_watch!.start());
  }

  /// train-app (D): sync both ways when the internet is back — saved GPS
  /// points of an earlier share, offline check-ins and shared texts.
  Future<void> _syncUp() async {
    try {
      await TrainShareController.I.flushSaved(_api.trainShareFixes);
      await TrainOutbox.I.flush(_api);
    } catch (_) {
      // best-effort: next load tries again
    }
  }

  Future<void> _loadOffline() async {
    unawaited(TrainOutbox.I.refreshCount());
    final p = await TrainOfflineStore.I.load();
    final tr = p?.trains[widget.no];
    if (p == null || tr == null) return;
    final now = DateTime.now();
    final cell = await TrainNative.I.servingCell();
    final pos = towerPosition(p, tr, cell, now) ?? timetablePosition(tr, now);
    if (!mounted) return;
    setState(() => _off = {
          'train': tr,
          'line': trainOfflineLine(tr, pos),
          'fresh': pos.source == 'tower' ? 'offline_tower' : 'offline_timetable',
        });
  }

  void _onShare() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await Future.wait([
        _api.trainLive(widget.no, widget.date),
        if (_v == null) _api.trainConfig(),
      ]);
      if (!mounted) return;
      final wasOff = _off != null || _v == null;
      setState(() {
        _v = r[0];
        if (r.length > 1 && r[1]['map'] is Map) {
          _map = VehMapConfig.fromJson(Map<String, dynamic>.from(r[1]['map'] as Map));
        }
        _failed = false;
        _off = null;
        _loadedAt = DateTime.now();
      });
      if (wasOff) unawaited(_syncUp());
      _startWatch(r[0]);
    } catch (_) {
      if (!mounted) return;
      if (_v == null || _off != null) await _loadOffline();
      if (!mounted) return;
      // quiet poll failed: repaint so the freshness chip ages ("N min ago")
      if (quiet) {
        setState(() {});
        return;
      }
      setState(() => _failed = true);
    }
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  bool get _sharingThis =>
      TrainShareController.I.sharing && TrainShareController.I.value.trainNo == widget.no;

  Future<void> _share() async {
    if (_sharingThis) {
      await TrainShareController.I.stop();
      return;
    }
    final r = await showTrainShareConsent(context);
    if (r == null || !mounted) return;
    await _startShare(cell: r.$2, by: 'user');
  }

  /// train-app (B): start "I am on this train" — location permission with
  /// its reason first (never in the background), then the visible
  /// foreground service; auto-stop at the last station.
  Future<void> _startShare({required bool cell, required String by}) async {
    final t = AppLocalizations.of(context);
    if (!TrainNative.disabledForTests) {
      final perm = await askLocationWithReason(context);
      if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return;
    }
    if (!mounted) return;
    try {
      final r = await _api.trainShareStart(widget.no, widget.date);
      final sh = r['share'] as Map?;
      final id = (sh?['id'] as num?)?.toInt();
      if (id == null) throw StateError('no share');
      await TrainShareController.I.start(id, widget.no, _api.trainShareFixes,
          stopRemote: (i) async => _api.trainShareStop(i),
          title: t.trShareNotifTitle,
          text: t.trShareNotifText,
          stopLabel: t.trStop,
          cell: cell,
          lastStop: trainLastStop(_v),
          endsAt: DateTime.tryParse('${sh?['ends_at'] ?? ''}'),
          by: by);
      unawaited(_load(quiet: true));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.trLoadFailed)));
      }
    }
  }

  /// train-app (E): one-tap check-in at a station (or the get-off alarm).
  Future<void> _onStation(Map<String, dynamic> s, List<Map<String, dynamic>> stops, Map<String, dynamic> v) async {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final alarmOn = FeatureFlags.instance.isOn('dest_alarm');
    final what = await showTrainStationSheet(context, trainLineName(s, bn), alarm: alarmOn);
    if (!mounted || what == null) return;
    if (what == 'alarm') {
      // a passing station is not in the timetable stop list: the alarm
      // screen gets it as an extra suggestion
      final known = stops.any((x) => '${x['id']}' == '${s['id']}');
      final list = known
          ? stops
          : ([
              ...stops,
              {'id': '${s['id']}', 'bn': s['bn'], 'en': s['en'], 'lat': s['lat'], 'lng': s['lng'], 'km': s['km']}
            ]..sort((a, b) => ((a['km'] as num?) ?? 0).compareTo((b['km'] as num?) ?? 0)));
      _openAlarm(list, v, stationId: '${s['id']}');
      return;
    }
    final fix = TrainNative.disabledForTests ? null : await trainForegroundFix();
    final body = <String, dynamic>{
      'date': widget.date,
      'station_id': '${s['id']}',
      'kind': what,
      'at': DateTime.now().toUtc().toIso8601String(),
      if (fix != null) ...{'lat': fix.lat, 'lng': fix.lng, 'acc': fix.acc, 'mock': fix.mock},
    };
    String msg;
    try {
      final r = await _api.trainCheckin(widget.no, body);
      msg = switch ('${r['status']}') {
        'accepted' => t.tr2CheckinThanks,
        'pending' => t.tr2CheckinPending,
        _ => t.tr2CheckinRejected,
      };
      unawaited(_load(quiet: true));
    } catch (_) {
      await TrainOutbox.I.add(TrainOutItem('checkin', widget.no, body));
      msg = t.tr2Queued;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _openPaste(Map<String, dynamic>? line) {
    final st = [
      for (final s in (line?['stations'] as List? ?? const []))
        if (s is Map) TrainSmsStation('${s['id']}', '${s['bn'] ?? ''}', '${s['en'] ?? ''}')
    ];
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TrainPasteScreen(no: widget.no, date: widget.date, stations: st)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final v = _v;
    return Scaffold(
      appBar: AppBar(title: Text(_d('${t.trTrain} ${widget.no}'))),
      // owner fix 3 Nov: ONE banner below the page (Scaffold lays the body,
      // its map and the 999 / 131 buttons out ABOVE it — never covered);
      // the 999 / 131 buttons sit high on the page, far from it
      bottomNavigationBar: widget.showAds
          ? const AdBannerSlot(screen: 'train_detail')
          : SizedBox(height: MediaQuery.paddingOf(context).bottom),
      body: v == null && _off != null
          ? _offlineBody(t, bn, _off!)
          : v == null
          ? Center(
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(t.trLoadFailed, textAlign: TextAlign.center, style: AType.bodyLarge),
                        const SizedBox(height: Gap.md),
                        DsButton(onPressed: _load, icon: Icons.refresh_rounded, label: t.trRetry),
                      ]),
                    )
                  : const CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _body(t, bn, v)),
    );
  }

  /// train-app (D): no internet. The train from the phone's own offline
  /// pack: the serving cell tower in the learned map, else the timetable —
  /// labelled so, never shown as live.
  Widget _offlineBody(AppLocalizations t, bool bn, Map<String, dynamic> o) {
    final tr = o['train'] as OffTrain;
    final line = Map<String, dynamic>.from(o['line'] as Map);
    final cs = Theme.of(context).colorScheme;
    final share = TrainShareController.I.value;
    final now = trainLineStatus(t, line, bn);
    return ListView(
      key: const ValueKey('tr2_offline_body'),
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
      children: [
        Semantics(
          header: true,
          child: Text(_d('${bn || tr.nameEn.isEmpty ? tr.nameBn : tr.nameEn} · ${tr.no}'),
              style: AType.titleLarge),
        ),
        const SizedBox(height: Gap.sm),
        DsOfflineStrip(label: t.tr2OfflineStrip, retryLabel: t.trRetry, onRetry: _load),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          TrainFreshChip(fresh: TrainFresh('${o['fresh']}')),
        ]),
        if (now != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_d(now), key: const ValueKey('sjt_now'), style: AType.titleMedium),
        ] else if (line['state'] == 'suspended') ...[
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _chip(t.tr2Suspended, cs.ds.dangerBg, cs.ds.dangerInk, Icons.block_rounded),
          ),
        ] else if (line['state'] == 'off_day' || line['state'] == 'not_started') ...[
          const SizedBox(height: Gap.sm),
          Text(line['state'] == 'off_day' ? t.trOffDay : t.trEstNotStarted, style: AType.bodyMedium),
        ],
        if (_sharingThis) TrainRiderStatus(state: share),
        ValueListenableBuilder<int>(
          valueListenable: TrainOutbox.I,
          builder: (_, n, __) => n == 0
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(_d(t.tr2Outbox('$n')),
                      key: const ValueKey('tr2_outbox'),
                      style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
                ),
        ),
        const SizedBox(height: Gap.md),
        TrainLineView(
          key: const ValueKey('sjt_line'),
          line: line,
          onStation: (s) => _onStation(s, const [], const {}),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.tr2Disclaimer, style: AType.bodySmall.copyWith(color: cs.ds.muted)),
      ],
    );
  }

  /// sjtrain: open the destination alarm, a station filled in (or not).
  void _openAlarm(List<Map<String, dynamic>> stops, Map<String, dynamic> v, {String? stationId}) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DestAlarmScreen(
                suggestedIds: [for (final s in stops) '${s['id']}'],
                suggested: stops,
                path: trainPath(v),
                initialStationId: stationId,
                trainNo: widget.no,
                trainDate: widget.date,
                onShareYes: () => _startShare(cell: false, by: 'alarm'))));
  }

  Widget _chip(String text, Color bg, Color fg, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: Gap.xs),
          Flexible(
              child: Text(text, style: AType.labelLarge.copyWith(color: fg, fontWeight: FontWeight.w700))),
        ]),
      );

  // sjtrain (Safe Journey V2, TRAIN 6): header (name + number + delay chip),
  // "N passengers sharing live" or "Estimated from timetable", the vertical
  // metro-style station line, seat card; chat + get-off alarm one tap away.
  Widget _body(AppLocalizations t, bool bn, Map<String, dynamic> v) {
    final tr = Map<String, dynamic>.from(v['train'] as Map);
    final live = v['live'] as Map?;
    final est = v['estimate'] as Map?;
    final pos = live ?? est;
    final path = [
      for (final p in (v['path'] as List? ?? const []))
        if (p is List && p.length >= 2) GeoPt((p[0] as num).toDouble(), (p[1] as num).toDouble())
    ];
    final cs = Theme.of(context).colorScheme;
    final sms = Map<String, dynamic>.from(v['sms'] as Map? ?? const {});
    final alarmOn = FeatureFlags.instance.isOn('dest_alarm');
    final stops = [for (final s in (v['stops'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    final line = v['line'] is Map ? Map<String, dynamic>.from(v['line'] as Map) : null;
    final sharers = (v['sharers'] as num?)?.toInt() ?? (live?['sharers'] as num?)?.toInt() ?? 0;
    final delay = (v['delay_min'] as num?)?.toInt() ?? (live?['delay_min'] as num?)?.toInt();
    final chat = v['chat'] is Map ? v['chat'] as Map : null;
    final chatOpen = chat == null || chat['open'] == true;
    final myShare = v['my_share'] is Map ? v['my_share'] as Map : null;
    final estState = '${est?['state'] ?? ''}';
    final tripOver = estState == 'arrived' ||
        (myShare != null && (myShare['status'] == 'arrived' || myShare['status'] == 'ended'));
    final now = trainLineStatus(t, line, bn);
    String chipText;
    Color chipBg, chipFg;
    IconData chipIcon;
    if (live == null) {
      chipText = t.trModeEstimate;
      chipBg = cs.ds.successBg;
      chipFg = cs.ds.successInk;
      chipIcon = Icons.schedule_rounded;
    } else if (delay != null && delay > 2) {
      chipText = _d(t.sjtLateChip('$delay'));
      chipBg = cs.ds.dangerBg;
      chipFg = cs.ds.dangerInk;
      chipIcon = Icons.timer_outlined;
    } else {
      chipText = t.sjtOnTimeChip;
      chipBg = cs.ds.primarySoft;
      chipFg = cs.ds.primaryInk;
      chipIcon = Icons.check_circle_rounded;
    }
    final share = TrainShareController.I.value;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
      children: [
        // ---- header
        Semantics(
          header: true,
          child: Text(_d('${tr['name_bn']} · ${tr['no']}'),
              key: const ValueKey('sjt_header'), style: AType.titleLarge),
        ),
        const SizedBox(height: Gap.xxs),
        Text('${trainStation(tr['from'] as Map?, bn)} → ${trainStation(tr['to'] as Map?, bn)}',
            style: AType.bodyMedium.copyWith(color: cs.ds.muted)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          Semantics(
              label: chipText,
              excludeSemantics: true,
              child: _chip(chipText, chipBg, chipFg, chipIcon)),
          if (trainSuspended(tr))
            _chip(t.tr2Suspended, cs.ds.dangerBg, cs.ds.dangerInk, Icons.block_rounded)
          else if (v['runs'] == false)
            _chip(t.trOffDay, cs.ds.dangerBg, cs.ds.dangerInk, Icons.event_busy_rounded),
          // train-app: always how fresh it is (live / N min ago / predicted / timetable)
          TrainFreshChip(
              fresh: trainFreshOf(v, sinceLoadS: DateTime.now().difference(_loadedAt).inSeconds)),
        ]),
        const SizedBox(height: Gap.sm),
        Semantics(
          container: true,
          liveRegion: true,
          child: Container(
            key: const ValueKey('sjt_mode_card'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: live != null ? cs.ds.primarySoft : cs.ds.successBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(live != null ? Icons.sensors_rounded : Icons.schedule_rounded,
                    color: live != null ? cs.ds.primaryInk : cs.ds.successInk),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                      live != null
                          ? _d(sharers == 1 ? t.sjtSharingOne : t.sjtSharingMany('$sharers'))
                          : t.sjtEstimated,
                      style: AType.titleSmall.copyWith(
                          color: live != null ? cs.ds.primaryInk : cs.ds.successInk,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
              if (now != null) ...[
                const SizedBox(height: Gap.xs),
                Text(_d(now),
                    key: const ValueKey('sjt_now'),
                    style: AType.titleMedium.copyWith(
                        color: live != null ? cs.ds.primaryInk : cs.ds.successInk)),
              ] else if (live == null) ...[
                const SizedBox(height: Gap.xs),
                Text(
                    estState == 'not_started'
                        ? t.trEstNotStarted
                        : (estState == 'arrived' ? t.trEstArrived : t.trEstRunning),
                    style: AType.bodyMedium.copyWith(color: cs.ds.successInk)),
              ],
              if (live == null)
                Text(t.sjtEstimatedWhy, style: AType.bodySmall.copyWith(color: cs.ds.successInk)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        // ---- share
        FilledButton.icon(
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: _sharingThis ? cs.error : null,
              foregroundColor: _sharingThis ? cs.onError : null),
          icon: Icon(_sharingThis ? Icons.stop_circle_rounded : Icons.my_location_rounded),
          label: Text(_sharingThis ? t.trShareStop : t.trImOnTrain),
          onPressed: _share,
        ),
        if (_sharingThis)
          TrainRiderStatus(state: share)
        else if (!tripOver)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.tr2RiderWhy, style: AType.bodySmall.copyWith(color: cs.ds.muted)),
          ),
        const SizedBox(height: Gap.sm),
        // ---- chat + get-off alarm
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('sjt_chat'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: Icon(chatOpen ? Icons.forum_rounded : Icons.lock_clock_rounded),
              label: Text(chatOpen ? t.trChat : t.sjtChatClosedShort),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => TrainChatScreen(
                          no: widget.no, date: widget.date, title: '${tr['name_bn']}'))),
            ),
          ),
          if (alarmOn) ...[
            const SizedBox(width: Gap.sm),
            Expanded(
              child: FilledButton.tonalIcon(
                key: const ValueKey('sjt_getoff'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.alarm_add_rounded),
                label: Text(t.sjtGetOffAlarm),
                onPressed: () => _openAlarm(stops, v),
              ),
            ),
          ],
        ]),
        const SizedBox(height: Gap.sm),
        // ---- SMS 16318 (official; the user sends it)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.sms_rounded),
          label: Text(_d(t.trSmsButton('${sms['body'] ?? 'TR ${widget.no}'}', '${sms['to'] ?? '16318'}'))),
          onPressed: () => launchUrl(trainSmsUri(widget.no)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.xxs),
          child: Text(_d(t.trSmsCost('${sms['cost_bdt'] ?? 4}')), style: AType.bodySmall),
        ),
        // train-app (F): got the 16318 reply or a group post? share it here
        const SizedBox(height: Gap.sm),
        DsButton.secondary(
          buttonKey: const ValueKey('tr2_paste_open'),
          expand: true,
          icon: Icons.content_paste_go_rounded,
          label: t.tr2PasteButton,
          onPressed: () => _openPaste(line),
        ),
        const SizedBox(height: Gap.md),
        // sjalarm: 999 / 131 always one tap away (opens the dialer; you press call)
        Text(t.trEmergencyTitle, key: const ValueKey('train_hotlines'), style: AType.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48), backgroundColor: cs.error, foregroundColor: cs.onError),
            icon: const Icon(Icons.call_rounded),
            label: Text(_d(t.trCall999)),
            onPressed: () => launchUrl(trainTelUri('999')),
          ),
          DsButton.secondary(onPressed: () => launchUrl(trainTelUri('131')), icon: Icons.train_rounded, label: _d(t.trCall131)),
        ]),
        const SizedBox(height: Gap.lg),
        // ---- the metro-style line
        Text(t.sjtLineTitle, style: AType.titleMedium),
        Text(t.tr2LineTapHint, style: AType.bodySmall.copyWith(color: cs.ds.muted)),
        const SizedBox(height: Gap.xs),
        if (line != null && (line['stations'] as List? ?? const []).isNotEmpty)
          TrainLineView(
            key: const ValueKey('sjt_line'),
            line: line,
            live: live != null,
            speedKmh: (live?['speed_kmh'] as num?)?.round(),
            riders: sharers,
            onStation: (s) => _onStation(s, stops, v),
          )
        else
          for (final s in stops)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_rounded),
              title: Text(trainStation(s, bn)),
              subtitle: Text(_d('${trainHm('${s['at']}')} ${t.trEstShort}'), style: AType.bodySmall),
            ),
        const SizedBox(height: Gap.md),
        // ---- seat card (crowd, unverified until 3 agree)
        TrainSeatCard(no: widget.no, date: widget.date, tripOver: tripOver),
        const SizedBox(height: Gap.md),
        // ---- 2D map (no 3D)
        SizedBox(
          height: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: VehMap(
              config: _map,
              route: path,
              live: pos == null
                  ? null
                  : GeoPt((pos['lat'] as num).toDouble(), (pos['lng'] as num).toDouble()),
              semanticsLabel: t.trMapA11y,
              emptyLabel: t.trMapEmpty,
              tileProvider: VehMap.debugTileProvider,
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        if (tr['approved'] != true)
          Text(t.trUnchecked, style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
        Text(t.tr2Disclaimer, style: AType.bodySmall),
        Text(t.trSourceLine, style: AType.bodySmall),
        Text(t.sjtLineSource, style: AType.bodySmall),
      ],
    );
  }
}

/// train-app (D): "Use without internet" on the train list — the size is
/// asked from the server first and shown on the button; a refresh is
/// offered when the phone's copy is a week old.
class TrainOfflineSection extends StatefulWidget {
  const TrainOfflineSection({super.key});

  @override
  State<TrainOfflineSection> createState() => _TrainOfflineSectionState();
}

class _TrainOfflineSectionState extends State<TrainOfflineSection> {
  int? _size;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    await TrainOfflineStore.I.load();
    if (!mounted) return;
    try {
      final m = await context.read<AppState>().api.trainOfflineMeta();
      if (mounted) setState(() => _size = (m['size_bytes'] as num?)?.toInt());
    } catch (_) {
      // offline / not deployed yet: the button shows no size
    }
  }

  Future<void> _download() async {
    final api = context.read<AppState>().api;
    setState(() => _failed = false);
    final ok = await TrainOfflineStore.I.download(api.trainOfflinePack);
    if (mounted) setState(() => _failed = !ok);
  }

  @override
  Widget build(BuildContext context) =>
      TrainOfflineCard(store: TrainOfflineStore.I, sizeBytes: _size, onDownload: _download, failed: _failed);
}
