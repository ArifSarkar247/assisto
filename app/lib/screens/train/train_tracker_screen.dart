import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/train_api.dart';
import '../../train/train_share_service.dart';
import '../../vehicle/route_canvas.dart';
import '../../vehicle/veh_map.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/fam_empty.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'dest_alarm_screen.dart';
import 'train_chat_screen.dart';

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

class TrainTrackerScreen extends StatefulWidget {
  const TrainTrackerScreen({super.key});

  @override
  State<TrainTrackerScreen> createState() => _TrainTrackerScreenState();
}

class _TrainTrackerScreenState extends State<TrainTrackerScreen> {
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
    final alarmOn = FeatureFlags.instance.isOn('dest_alarm');
    return Scaffold(
      appBar: AppBar(title: Text(t.trTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
        children: [
          TextField(
            controller: _q,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.trSearchHint,
              border: const OutlineInputBorder(),
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
          if (alarmOn) ...[
            const SizedBox(height: Gap.sm),
            Card(
              child: ListTile(
                minVerticalPadding: Gap.md,
                leading: const Icon(Icons.alarm_on_rounded),
                title: Text(t.trAlarmTitle),
                subtitle: Text(t.trAlarmCardSub),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const DestAlarmScreen())),
              ),
            ),
          ],
          const SizedBox(height: Gap.sm),
          ..._results(t, bn),
          const SizedBox(height: Gap.md),
          Text(t.trDataNote, style: AType.bodySmall),
        ],
      ),
    );
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
          child: FilledButton.icon(
              onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.trRetry)),
        ),
      ];
    }
    if (_trains.isEmpty) {
      return [
        FamEmptyState(
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
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TrainLiveScreen(no: '${tr['no']}', date: _date))),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d('${tr['no']} · ${tr['name_bn']}'), style: AType.titleMedium),
            const SizedBox(height: Gap.xxs),
            Text(route, style: AType.bodyMedium),
            Text(d(t.trDepArr('${tr['dep']}', '${tr['arr']}')), style: AType.bodySmall),
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
  const TrainLiveScreen({super.key, required this.no, required this.date});

  @override
  State<TrainLiveScreen> createState() => _TrainLiveScreenState();
}

class _TrainLiveScreenState extends State<TrainLiveScreen> {
  ApiClient get _api => context.read<AppState>().api;
  Map<String, dynamic>? _v;
  VehMapConfig _map = const VehMapConfig();
  bool _failed = false;
  Timer? _poll;

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
    TrainShareController.I.removeListener(_onShare);
    super.dispose();
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
      setState(() {
        _v = r[0];
        if (r.length > 1 && r[1]['map'] is Map) {
          _map = VehMapConfig.fromJson(Map<String, dynamic>.from(r[1]['map'] as Map));
        }
        _failed = false;
      });
    } catch (_) {
      if (!mounted || quiet) return;
      setState(() => _failed = true);
    }
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  bool get _sharingThis =>
      TrainShareController.I.sharing && TrainShareController.I.value.trainNo == widget.no;

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    if (_sharingThis) {
      await TrainShareController.I.stop();
      return;
    }
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.trShareTitle, style: AType.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.trShareConsent, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.my_location_rounded),
            label: Text(t.trShareStart),
            onPressed: () => Navigator.pop(ctx, true),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.trCancel),
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _api.trainShareStart(widget.no, widget.date);
      final id = ((r['share'] as Map?)?['id'] as num?)?.toInt();
      if (id == null) throw StateError('no share');
      await TrainShareController.I.start(id, widget.no, _api.trainShareFixes,
          stopRemote: (i) async => _api.trainShareStop(i),
          title: t.trShareNotifTitle,
          text: t.trShareNotifText,
          stopLabel: t.trStop);
      unawaited(_load(quiet: true));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.trLoadFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final v = _v;
    return Scaffold(
      appBar: AppBar(title: Text(_d('${t.trTrain} ${widget.no}'))),
      body: v == null
          ? Center(
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(t.trLoadFailed, textAlign: TextAlign.center, style: AType.bodyLarge),
                        const SizedBox(height: Gap.md),
                        FilledButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(t.trRetry)),
                      ]),
                    )
                  : const CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _body(t, bn, v)),
    );
  }

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
    String status;
    if (live != null) {
      final delay = (live['delay_min'] as num?)?.toInt();
      status = t.trLiveLine('${live['sharers']}',
          delay == null ? '' : (delay > 0 ? t.trLate('$delay') : t.trOnTime));
    } else {
      final st = '${est?['state'] ?? ''}';
      status = st == 'not_started'
          ? t.trEstNotStarted
          : (st == 'arrived' ? t.trEstArrived : t.trEstRunning);
    }
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
      children: [
        Text(_d('${tr['name_bn']} · ${trainStation(tr['from'] as Map?, bn)} → ${trainStation(tr['to'] as Map?, bn)}'),
            style: AType.titleMedium),
        if (v['runs'] == false)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.trOffDay, style: AType.bodyMedium.copyWith(color: cs.error)),
          ),
        const SizedBox(height: Gap.sm),
        Semantics(
          container: true,
          label: live != null ? t.trModeLive : t.trModeEstimate,
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: live != null ? cs.primaryContainer : cs.tertiaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(live != null ? t.trModeLive : t.trModeEstimate,
                  style: AType.titleSmall.copyWith(
                      color: live != null ? cs.onPrimaryContainer : cs.onTertiaryContainer,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              Text(_d(status),
                  style: AType.bodyMedium.copyWith(
                      color: live != null ? cs.onPrimaryContainer : cs.onTertiaryContainer)),
              if (live == null)
                Text(t.trEstimateWhy,
                    style: AType.bodySmall.copyWith(color: cs.onTertiaryContainer)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          height: 240,
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
        const SizedBox(height: Gap.md),
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
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
                _d(t.trShareCounts('${TrainShareController.I.value.accepted}',
                    '${TrainShareController.I.value.rejected}')),
                style: AType.bodySmall),
          ),
        const SizedBox(height: Gap.sm),
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
        const SizedBox(height: Gap.sm),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.forum_rounded),
              label: Text(t.trChat),
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
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.alarm_add_rounded),
                label: Text(t.trAlarmShort),
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DestAlarmScreen(
                            suggestedIds: [for (final s in stops) '${s['id']}'],
                            suggested: stops))),
              ),
            ),
          ],
        ]),
        const SizedBox(height: Gap.md),
        Text(t.trStopsTitle, style: AType.titleSmall),
        for (final s in stops)
          ListTile(
            dense: false,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_rounded),
            title: Text(trainStation(s, bn)),
            trailing: Text(_d('${trainHm('${s['at']}')} ${t.trEstShort}'), style: AType.bodySmall),
          ),
        const SizedBox(height: Gap.sm),
        if (tr['approved'] != true)
          Text(t.trUnchecked, style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
        Text(t.trSourceLine, style: AType.bodySmall),
      ],
    );
  }
}
