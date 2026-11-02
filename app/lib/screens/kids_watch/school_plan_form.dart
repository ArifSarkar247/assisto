import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// kidswatch — create / edit a School Mode plan (full-screen form sheet).
/// For a WATCH plan the child is the watch; for a PHONE plan the child is a
/// Circle member who must accept it on their own phone before anything runs.
Future<bool?> showSchoolPlanForm(BuildContext context,
        {Map<String, dynamic>? plan, Map<String, dynamic>? watch}) =>
    showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SchoolPlanForm(plan: plan, watch: watch),
    );

/// The plan's history (arrived, left, late, SOS ...).
Future<void> showSchoolEvents(BuildContext context, Map<String, dynamic> plan) =>
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SchoolEventsSheet(plan: plan),
    );

const _kDays = [6, 0, 1, 2, 3, 4, 5]; // Sun..Sat (Python weekday numbers)

class SchoolPlanForm extends StatefulWidget {
  const SchoolPlanForm({super.key, this.plan, this.watch});
  final Map<String, dynamic>? plan;
  final Map<String, dynamic>? watch;

  @override
  State<SchoolPlanForm> createState() => _SchoolPlanFormState();
}

class _SchoolPlanFormState extends State<SchoolPlanForm> {
  ApiClient get _api => context.read<AppState>().api;
  List<Map<String, dynamic>> _people = const [];
  List<Map<String, dynamic>> _places = const [];
  int? _child;
  final Set<int> _watchers = {};
  Map<String, dynamic>? _home;
  Map<String, dynamic>? _school;
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 13, minute: 30);
  int _late = 15;
  int _commute = 40;
  final Set<int> _days = {6, 0, 1, 2, 3};
  bool _classMode = false;
  bool _busy = false;
  String _error = '';

  bool get _isWatch => widget.watch != null || widget.plan?['mode'] == 'watch';
  bool get _editing => widget.plan != null;

  @override
  void initState() {
    super.initState();
    final cfg = (widget.plan?['config'] as Map?)?.cast<String, dynamic>();
    if (cfg != null) {
      _start = _tod(cfg['start']) ?? _start;
      _end = _tod(cfg['end']) ?? _end;
      _late = (cfg['late_min'] as num?)?.toInt() ?? _late;
      _commute = (cfg['commute_min'] as num?)?.toInt() ?? _commute;
      _days
        ..clear()
        ..addAll(((cfg['days'] as List?) ?? const []).whereType<num>().map((e) => e.toInt()));
      _home = (cfg['home'] as Map?)?.cast<String, dynamic>();
      _school = (cfg['school'] as Map?)?.cast<String, dynamic>();
      _classMode = cfg['class_mode'] == true;
    }
    for (final w in kwRows(widget.plan, 'watchers')) {
      if (w['owner'] != true) _watchers.add(w['id'] as int);
    }
    unawaited(_loadLists());
  }

  TimeOfDay? _tod(Object? s) {
    final p = '$s'.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return h == null || m == null ? null : TimeOfDay(hour: h, minute: m);
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _loadLists() async {
    try {
      final r = await Future.wait([_api.smPeople(), _api.smPlaces()]);
      if (!mounted) return;
      setState(() {
        _people = kwRows(r[0], 'people');
        _places = kwRows(r[1], 'places');
      });
    } catch (_) {}
  }

  Future<void> _pickPlace(bool school) async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.my_location_rounded),
            title: Text(t.kwUseHereNow),
            subtitle: Text(t.kwUseHereNowSub),
            onTap: () => Navigator.pop(ctx, {'here': true}),
          ),
          for (final p in _places)
            ListTile(
              leading: const Icon(Icons.place_rounded),
              title: Text('${p['label'] ?? ''}'.isNotEmpty ? '${p['label']}' : '${p['name']}'),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    Map<String, dynamic>? place;
    if (pick['here'] == true) {
      final pos = await _here();
      if (pos == null) {
        if (mounted) setState(() => _error = t.kwLocationUnavailable);
        return;
      }
      place = {'lat': pos.latitude, 'lng': pos.longitude,
               'name': school ? t.kwSchool : t.kwHome};
    } else {
      place = {'lat': pick['lat'], 'lng': pick['lng'],
               'name': '${pick['label'] ?? pick['name'] ?? ''}'};
    }
    setState(() {
      _error = '';
      if (school) {
        _school = {...place!, 'radius_m': 150};
      } else {
        _home = {...place!, 'radius_m': 150};
      }
    });
  }

  Future<Position?> _here() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  Future<void> _time(bool start) async {
    final v = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (v == null || !mounted) return;
    setState(() {
      if (start) {
        _start = v;
      } else {
        _end = v;
      }
    });
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (!_editing && !_isWatch && _child == null) {
      setState(() => _error = t.kwPickChild);
      return;
    }
    if (_home == null || _school == null) {
      setState(() => _error = t.kwPlacesRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final body = <String, dynamic>{
      'start': _hhmm(_start),
      'end': _hhmm(_end),
      'late_min': _late,
      'commute_min': _commute,
      'days': _days.toList(),
      'home': _home,
      'school': _school,
      'watcher_ids': _watchers.toList(),
      if (_isWatch) 'class_mode': _classMode,
    };
    try {
      if (_editing) {
        await _api.smUpdate(widget.plan!['id'] as int, body);
      } else {
        await _api.smCreate({
          ...body,
          if (widget.watch != null) 'watch_id': widget.watch!['id'],
          if (widget.watch == null) 'child_user_id': _child,
        });
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.message.isNotEmpty ? e.message : t.kwActionFailed;
      });
    }
  }

  String _dayName(AppLocalizations t, int d) => switch (d) {
        6 => t.kwDaySun,
        0 => t.kwDayMon,
        1 => t.kwDayTue,
        2 => t.kwDayWed,
        3 => t.kwDayThu,
        4 => t.kwDayFri,
        _ => t.kwDaySat,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String d(String s) => notifLocalizeDigits(context, s);
    return SingleChildScrollView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwSchoolModeTitle, style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(_isWatch ? t.kwPlanWatchIntro : t.kwPlanPhoneIntro, style: AType.bodyMedium),
        if (!_editing && !_isWatch) ...[
          const SizedBox(height: Gap.md),
          Text(t.kwWhichChild, style: AType.titleSmall),
          if (_people.isEmpty)
            Text(t.kwNoCirclePeople, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          for (final p in _people)
            RadioListTile<int>(
              value: p['id'] as int,
              groupValue: _child,
              title: Text('${p['name']}'),
              onChanged: (v) => setState(() => _child = v),
            ),
        ],
        const SizedBox(height: Gap.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.home_rounded),
          title: Text(t.kwHome),
          subtitle: Text(_home == null ? t.kwNotSet : '${_home!['name'] ?? t.kwSet}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickPlace(false),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.school_rounded),
          title: Text(t.kwSchool),
          subtitle: Text(_school == null ? t.kwNotSet : '${_school!['name'] ?? t.kwSet}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickPlace(true),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule_rounded),
          title: Text(t.kwSchoolStarts),
          trailing: Text(d(_start.format(context))),
          onTap: () => _time(true),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule_rounded),
          title: Text(t.kwSchoolEnds),
          trailing: Text(d(_end.format(context))),
          onTap: () => _time(false),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.kwSchoolDays, style: AType.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
          for (final day in _kDays)
            FilterChip(
              label: Text(_dayName(t, day)),
              selected: _days.contains(day),
              onSelected: (v) => setState(() {
                if (v) {
                  _days.add(day);
                } else {
                  _days.remove(day);
                }
              }),
            ),
        ]),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<int>(
          value: const [10, 15, 20, 30, 45, 60].contains(_late) ? _late : 15,
          decoration: InputDecoration(labelText: t.kwLateAfter, border: const OutlineInputBorder()),
          items: [
            for (final m in const [10, 15, 20, 30, 45, 60])
              DropdownMenuItem(value: m, child: Text(t.kwMinutes(d('$m')))),
          ],
          onChanged: (v) => setState(() => _late = v ?? _late),
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<int>(
          value: const [15, 20, 30, 40, 60, 90].contains(_commute) ? _commute : 40,
          decoration: InputDecoration(labelText: t.kwCommute, border: const OutlineInputBorder()),
          items: [
            for (final m in const [15, 20, 30, 40, 60, 90])
              DropdownMenuItem(value: m, child: Text(t.kwMinutes(d('$m')))),
          ],
          onChanged: (v) => setState(() => _commute = v ?? _commute),
        ),
        if (_isWatch)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _classMode,
            title: Text(t.kwClassMode),
            subtitle: Text(t.kwClassModeSub),
            onChanged: (v) => setState(() => _classMode = v),
          ),
        if (_people.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(t.kwWhoElseSees, style: AType.titleSmall),
          for (final p in _people.where((p) => p['id'] != _child))
            CheckboxListTile(
              value: _watchers.contains(p['id']),
              title: Text('${p['name']}'),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _watchers.add(p['id'] as int);
                } else {
                  _watchers.remove(p['id']);
                }
              }),
            ),
        ],
        const SizedBox(height: Gap.sm),
        Text(_isWatch ? t.kwPlanWatchHonest : t.kwPlanPhoneHonest,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(_error, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: Gap.lg),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _save,
          child: Text(_editing ? t.kwSave : (_isWatch ? t.kwTurnOn : t.kwSendToChild)),
        ),
      ]),
    );
  }
}

class SchoolEventsSheet extends StatefulWidget {
  const SchoolEventsSheet({super.key, required this.plan, this.canClear = true});
  final Map<String, dynamic> plan;
  final bool canClear;

  @override
  State<SchoolEventsSheet> createState() => _SchoolEventsSheetState();
}

class _SchoolEventsSheetState extends State<SchoolEventsSheet> {
  List<Map<String, dynamic>> _events = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.smEvents(widget.plan['id'] as int);
      if (mounted) setState(() => _events = kwRows(r, 'events'));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _clear() async {
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.smClearHistory(widget.plan['id'] as int);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.kwHistoryCleared)));
      setState(() => _events = const []);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.kwActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwHistory, style: AType.titleLarge),
        const SizedBox(height: Gap.sm),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_events.isEmpty)
          Text(t.kwHistoryEmpty, style: AType.bodyMedium)
        else
          for (final e in _events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(kwEventIcon('${e['kind']}')),
              title: Text(kwEventLabel(t, '${e['kind']}')),
              subtitle: Text(notifLocalizeDigits(context, kwClock(e['at']))),
            ),
        if (widget.canClear && _events.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.delete_sweep_rounded),
              label: Text(t.kwClearHistory)),
        ],
      ]),
    );
  }
}

IconData kwEventIcon(String k) => switch (k) {
      'left_home' || 'left_school' => Icons.directions_walk_rounded,
      'arrived_school' || 'back_in_school' => Icons.school_rounded,
      'reached_home' => Icons.home_rounded,
      'late_school' || 'late_home' || 'left_school_early' => Icons.warning_amber_rounded,
      'sos' => Icons.sos_rounded,
      _ => Icons.circle_outlined,
    };

String kwEventLabel(AppLocalizations t, String k) => switch (k) {
      'left_home' => t.kwEvLeftHome,
      'arrived_school' => t.kwEvArrivedSchool,
      'left_school_early' => t.kwEvLeftSchoolEarly,
      'back_in_school' => t.kwEvBackInSchool,
      'left_school' => t.kwEvLeftSchool,
      'reached_home' => t.kwEvReachedHome,
      'late_school' => t.kwEvLateSchool,
      'late_home' => t.kwEvLateHome,
      'child_ok' => t.kwEvChildOk,
      'ask_ok' => t.kwEvAskOk,
      'sos' => t.kwEvSos,
      'school_over' => t.kwEvSchoolOver,
      _ => k,
    };
