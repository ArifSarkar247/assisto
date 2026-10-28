import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../widgets/skeleton.dart';

/// veh100: one vehicle's DAILY or MONTHLY trip + distance report, computed on
/// the server from the tracker's own positions (no estimates): distance,
/// trips, driving / idling time, top speed, time over the limit, harsh
/// braking / acceleration and the driving score (with its honest limits),
/// per driver, and a CSV export for a spreadsheet.
class VehicleReportScreen extends StatefulWidget {
  final int trackerId;
  final String name;

  /// When set, the month view shows ONE driver's share.
  final int? driverId;
  const VehicleReportScreen(
      {super.key, required this.trackerId, this.name = '', this.driverId});

  @override
  State<VehicleReportScreen> createState() => _VehicleReportScreenState();
}

class _VehicleReportScreenState extends State<VehicleReportScreen> {
  bool _month = false;
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _rep;
  bool _loading = true, _error = false, _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _dayIso => DateFormat('yyyy-MM-dd').format(_day);
  String get _monthIso => DateFormat('yyyy-MM').format(_day);

  bool get _isCurrent {
    final n = DateTime.now();
    return _month
        ? (_day.year == n.year && _day.month == n.month)
        : DateUtils.isSameDay(_day, n);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.vehReport(widget.trackerId,
          period: _month ? 'month' : 'day',
          date: _month ? null : _dayIso,
          month: _month ? _monthIso : null,
          driverId: widget.driverId);
      if (mounted) setState(() => _rep = r);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _shift(int dir) {
    setState(() {
      _day = _month
          ? DateTime(_day.year, _day.month + dir, 1)
          : _day.add(Duration(days: dir));
    });
    _load();
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: _day,
        firstDate: now.subtract(const Duration(days: 400)),
        lastDate: now);
    if (d != null) {
      setState(() => _day = d);
      _load();
    }
  }

  Future<void> _export() async {
    final tr = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';
    setState(() => _exporting = true);
    try {
      final bytes = await context.read<AppState>().api.vehReportCsv(widget.trackerId, lang,
          period: _month ? 'month' : 'day',
          date: _month ? null : _dayIso,
          month: _month ? _monthIso : null);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-vehicle-${widget.trackerId}-'
          '${_month ? _monthIso : _dayIso}.csv');
      await f.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')],
          text: tr.v100ReportShareText);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(vehReasonText(tr, e))));
      }
    }
    if (mounted) setState(() => _exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lc = Localizations.localeOf(context).languageCode;
    final periodLabel = _month
        ? DateFormat.yMMMM(lc).format(_day)
        : DateFormat.yMMMEd(lc).format(_day);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name.trim().isEmpty ? tr.v100ReportTitle : widget.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('veh-report-export'),
            tooltip: tr.v100ReportExport,
            onPressed: (_loading || _error || _exporting) ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_download_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr.v100ReportDay),
                  icon: const Icon(Icons.today_rounded)),
              ButtonSegment(value: true, label: Text(tr.v100ReportMonth),
                  icon: const Icon(Icons.calendar_month_rounded)),
            ],
            selected: {_month},
            onSelectionChanged: (v) {
              setState(() => _month = v.first);
              _load();
            },
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            IconButton(
              tooltip: tr.v100ReportPrev,
              onPressed: _loading ? null : () => _shift(-1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _month ? null : _pickDay,
                child: Text(periodLabel,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            IconButton(
              tooltip: tr.v100ReportNext,
              onPressed: (_loading || _isCurrent) ? null : () => _shift(1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          if (_loading && _rep == null)
            const SkeletonList()
          else if (_error)
            StateMessage(
              icon: Icons.cloud_off_rounded,
              tint: scheme.error,
              title: tr.loadFailed,
              message: tr.vehLoadError,
              action: FilledButton.tonalIcon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(tr.retry)),
            )
          else
            ..._content(tr, scheme),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon, ColorScheme scheme) => Container(
        constraints: const BoxConstraints(minWidth: 140),
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              Text(label,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );

  String _band(AppLocalizations tr, String band) => switch (band) {
        'good' => tr.v100ScoreGood,
        'ok' => tr.v100ScoreOk,
        'improve' => tr.v100ScoreImprove,
        _ => tr.v100ScoreNone,
      };

  List<Widget> _content(AppLocalizations tr, ColorScheme scheme) {
    final r = _rep ?? const {};
    final tot = vehMap(r['totals']);
    final km = vehNum(tot['km']) ?? 0;
    final trips = vehInt(tot['trips']) ?? 0;
    final score = vehInt(tot['score']);
    final band = '${r['band'] ?? 'none'}';
    final limit = vehInt(r['speed_limit_kmh']) ?? 80;
    final empty = km <= 0 && trips == 0;
    final out = <Widget>[];
    if (empty) {
      out.add(StateMessage(
        icon: Icons.directions_car_outlined,
        tint: scheme.primary,
        title: tr.v100ReportEmptyTitle,
        message: r['in_retention'] == false ? tr.v100ReportOld : tr.v100ReportEmptyBody,
      ));
      return out;
    }
    out.add(Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
      _stat(tr.vehDistance, tr.vehKm(vehNumStr(context, km, decimals: 1)),
          Icons.straighten_rounded, scheme),
      _stat(tr.vehTrips, vehNumStr(context, trips), Icons.route_rounded, scheme),
      _stat(tr.vehDriving, vehDuration(context, tr, vehInt(tot['moving_s']) ?? 0),
          Icons.timer_rounded, scheme),
      _stat(tr.v100Idling, vehDuration(context, tr, vehInt(tot['idle_s']) ?? 0),
          Icons.hourglass_bottom_rounded, scheme),
      _stat(tr.vehTopSpeed, tr.vehKmh(vehNumStr(context, vehNum(tot['max_kmh']) ?? 0)),
          Icons.speed_rounded, scheme),
      _stat(tr.v100OverLimit(vehNumStr(context, limit)),
          vehDuration(context, tr, vehInt(tot['overspeed_s']) ?? 0),
          Icons.warning_amber_rounded, scheme),
      _stat(tr.v100HarshBrake, vehNumStr(context, vehInt(tot['harsh_brake']) ?? 0),
          Icons.trending_down_rounded, scheme),
      _stat(tr.v100HarshAccel, vehNumStr(context, vehInt(tot['harsh_accel']) ?? 0),
          Icons.trending_up_rounded, scheme),
      if (_month)
        _stat(tr.v100DaysDriven, vehNumStr(context, vehInt(tot['days_driven']) ?? 0),
            Icons.event_available_rounded, scheme),
    ]));
    out.add(const SizedBox(height: Gap.md));
    out.add(Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            label: tr.v100ScoreA11y(score == null ? '-' : vehNumStr(context, score),
                _band(tr, band)),
            child: ExcludeSemantics(
              child: Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: band == 'good'
                      ? Brand.success
                      : (band == 'ok'
                          ? Brand.warning
                          : (band == 'improve' ? scheme.error : scheme.outline)),
                ),
                child: Text(score == null ? '-' : vehNumStr(context, score),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.v100ScoreTitle, style: Theme.of(context).textTheme.titleMedium),
              Text(_band(tr, band), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.xs),
              Text(tr.v100ScoreHow,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
              if ((vehNum(tot['coverage']) ?? 1) < 0.5 && !_month)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(tr.v100ScoreLimited,
                      style: AType.bodySmall.copyWith(color: Brand.warning, height: 1.35)),
                ),
              if (r['limit_default'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(tr.v100LimitDefault(vehNumStr(context, limit)),
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
        ]),
      ),
    ));
    if (!_month) {
      final list = vehList(r['trips']);
      if (list.isNotEmpty) {
        out.add(const SizedBox(height: Gap.md));
        out.add(Text(tr.vehTrips, style: Theme.of(context).textTheme.titleMedium));
        for (final tp in list.reversed) {
          out.add(ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
                tp['night'] == true ? Icons.nightlight_round_rounded : Icons.route_rounded),
            title: Text(
                '${vehTime(context, vehDate(tp['start']))} – ${vehTime(context, vehDate(tp['end']))}',
                style: const TextStyle(fontFeatures: AFonts.tabular)),
            subtitle: Text(
                '${tr.vehKm(vehNumStr(context, vehNum(tp['km']) ?? 0, decimals: 1))} · '
                '${tr.vehKmh(vehNumStr(context, vehNum(tp['max_kmh']) ?? 0))}',
                maxLines: 2),
          ));
        }
      }
      final drivers = vehList(r['drivers']);
      if (drivers.isNotEmpty) {
        out.add(const SizedBox(height: Gap.md));
        out.add(Text(tr.v100ByDriver, style: Theme.of(context).textTheme.titleMedium));
        for (final d in drivers) {
          final sc = vehInt(d['score']);
          out.add(ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.badge_rounded),
            title: Text('${d['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${tr.vehKm(vehNumStr(context, vehNum(d['km']) ?? 0, decimals: 1))} · '
                '${tr.v100ScoreShort(sc == null ? '-' : vehNumStr(context, sc))}',
                maxLines: 2),
          ));
        }
      }
    } else {
      final days = vehList(r['days']);
      out.add(const SizedBox(height: Gap.md));
      out.add(Text(tr.v100ReportDays, style: Theme.of(context).textTheme.titleMedium));
      final lc = Localizations.localeOf(context).languageCode;
      for (final d in days.reversed) {
        final dt = DateTime.tryParse('${d['day']}');
        final sc = vehInt(d['score']);
        out.add(ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(dt == null ? '' : DateFormat.MMMEd(lc).format(dt)),
          subtitle: Text(
              '${tr.vehKm(vehNumStr(context, vehNum(d['km']) ?? 0, decimals: 1))} · '
              '${tr.v100TripsN(vehNumStr(context, vehInt(d['trips']) ?? 0))} · '
              '${tr.v100ScoreShort(sc == null ? '-' : vehNumStr(context, sc))}',
              maxLines: 2),
          onTap: dt == null
              ? null
              : () {
                  setState(() {
                    _month = false;
                    _day = dt;
                  });
                  _load();
                },
        ));
      }
    }
    out.add(const SizedBox(height: Gap.md));
    out.add(Text(tr.v100ReportSource,
        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)));
    out.add(const SizedBox(height: Gap.xl));
    return out;
  }
}
