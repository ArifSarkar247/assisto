import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart' show showAppSheet;
import '../../widgets/local_counter.dart';
import 'watchman_source.dart';

/// cctvdet (CCTV Guard V3 part C): the settings of ONE zone drawn on the
/// camera picture — its name, loitering (alert after N minutes in the zone),
/// for a shutter / gate "alert if left open" + "the gate is closed now"
/// (the box / phone remembers that picture), for a counter / post the hours
/// someone must be there + after how many empty minutes to alert.
/// Saved with the zones (core/logic/watchman.py validates every value).

const kPostDefaultSchedule = {
  'days': [0, 1, 2, 3, 4, 5, 6],
  'start': '10:00',
  'end': '21:00',
};

typedef ZoneOptions = ({String label, Map<String, dynamic>? schedule, Map<String, dynamic> opts});

const _dwellChoices = [0, 1, 2, 5, 10];
const _openChoices = [5, 10, 15, 30, 60];
const _absentChoices = [2, 5, 10, 15, 30];
const _crowdChoices = [0, 3, 5, 8, 12];
const _overstayChoices = [15, 30, 60, 120, 240];
const _wrongChoices = [1, 2, 5, 10];

String _lang(BuildContext c) => Localizations.localeOf(c).languageCode;

TimeOfDay? _tod(Object? v) {
  final p = (v ?? '').toString().split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  return (h == null || m == null) ? null : TimeOfDay(hour: h, minute: m);
}

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _min(BuildContext c, int n) => AppLocalizations.of(c).cdetMinutes(wmDigits(_lang(c), n));

/// One line under the zone in the list: what it will alert about.
Widget? zoneSummary(BuildContext context, String type, Map<String, dynamic> opts, Map<String, dynamic>? schedule) {
  final t = AppLocalizations.of(context);
  final parts = <String>[];
  if (type == 'gate') {
    parts.add(t.cdetSumGatePerson);
    if (opts['watch_open'] == true) {
      parts.add(t.cdetSumGateOpen(_min(context, (opts['open_min'] as num?)?.toInt() ?? 10)));
    }
  }
  if (type == 'post') {
    final s = _tod(schedule?['start']), e = _tod(schedule?['end']);
    final loc = MaterialLocalizations.of(context);
    parts.add(t.cdetSumPost(_min(context, (opts['absent_min'] as num?)?.toInt() ?? 5),
        s == null || e == null ? '' : wmDigits(_lang(context), '${loc.formatTimeOfDay(s)} - ${loc.formatTimeOfDay(e)}')));
  }
  final dwell = (opts['dwell_s'] as num?)?.toInt() ?? 0;
  if (dwell > 0) parts.add(t.cdetSumLoiter(_min(context, (dwell / 60).round())));
  final crowd = (opts['crowd_n'] as num?)?.toInt() ?? 0;
  if (crowd > 0) parts.add(t.cdetSumCrowd(wmDigits(_lang(context), crowd)));
  if (type == 'parking') {
    parts.add(t.cdetSumOverstay(_min(context, (opts['overstay_min'] as num?)?.toInt() ?? 60)));
  }
  if (type == 'no_parking') {
    parts.add(t.cdetSumWrong(_min(context, (((opts['wrong_s'] as num?) ?? 120) / 60).round())));
  }
  if (type == 'entry_line' && opts['vehicles'] == true) {
    parts.add(opts['notify'] == true ? t.cdetSumLineNotify : t.cdetSumLineLog);
  }
  if (parts.isEmpty) return null;
  return Text(parts.join(' · '), maxLines: 3, overflow: TextOverflow.ellipsis);
}

Future<ZoneOptions?> showZoneOptions(BuildContext context,
    {required String type,
    required String name,
    required String label,
    required Map<String, dynamic>? schedule,
    required Map<String, dynamic> opts}) {
  return showAppSheet<ZoneOptions>(
    context: context,
    builder: (ctx) => ZoneOptionsBody(type: type, name: name, label: label, schedule: schedule, opts: opts),
  );
}

class ZoneOptionsBody extends StatefulWidget {
  final String type, name, label;
  final Map<String, dynamic>? schedule;
  final Map<String, dynamic> opts;
  const ZoneOptionsBody(
      {required this.type, required this.name, required this.label, required this.schedule, required this.opts});

  @override
  State<ZoneOptionsBody> createState() => ZoneOptionsBodyState();
}

class ZoneOptionsBodyState extends State<ZoneOptionsBody> {
  late final TextEditingController _label = TextEditingController(text: widget.label);
  late int _dwellMin = (((widget.opts['dwell_s'] as num?) ?? 0) / 60).round();
  late bool _watchOpen = widget.opts['watch_open'] == true;
  late int _openMin = (widget.opts['open_min'] as num?)?.toInt() ?? 10;
  late double? _closedAt = (widget.opts['closed_at'] as num?)?.toDouble();
  late int _absentMin = (widget.opts['absent_min'] as num?)?.toInt() ?? 5;
  late int _crowdN = (widget.opts['crowd_n'] as num?)?.toInt() ?? 0;
  late int _overstayMin = (widget.opts['overstay_min'] as num?)?.toInt() ?? 60;
  late int _wrongMin = ((((widget.opts['wrong_s'] as num?) ?? 120) / 60).round()).clamp(1, 60).toInt();
  late bool _vehicles = widget.opts['vehicles'] == true;
  late bool _notify = widget.opts['notify'] == true;
  late bool _inRight = widget.opts['in_side'] == 'right';
  late TimeOfDay _start = _tod(widget.schedule?['start'] ?? kPostDefaultSchedule['start']) ??
      const TimeOfDay(hour: 10, minute: 0);
  late TimeOfDay _end =
      _tod(widget.schedule?['end'] ?? kPostDefaultSchedule['end']) ?? const TimeOfDay(hour: 21, minute: 0);
  bool _closedJustNow = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Widget _chips(List<int> values, int selected, ValueChanged<int> onPick, {bool offFirst = false}) {
    final t = AppLocalizations.of(context);
    return Wrap(spacing: 8, runSpacing: 4, children: [
      for (final v in values)
        ChoiceChip(
          label: Text(offFirst && v == 0 ? t.cdetOff : _min(context, v)),
          selected: selected == v,
          onSelected: (_) => setState(() => onPick(v)),
        ),
    ]);
  }

  void _done() {
    final opts = <String, dynamic>{};
    final poly = const {'restricted', 'gate', 'post'}.contains(widget.type);
    if (_dwellMin > 0 && poly && widget.type != 'post') opts['dwell_s'] = _dwellMin * 60;
    if (_crowdN > 0 && poly) opts['crowd_n'] = _crowdN;
    if (widget.type == 'parking') opts['overstay_min'] = _overstayMin;
    if (widget.type == 'no_parking') opts['wrong_s'] = _wrongMin * 60;
    // cctvdet3: parking alerts are a log + daily report unless the owner asks
    if ((widget.type == 'parking' || widget.type == 'no_parking') && _notify) opts['notify'] = true;
    if (widget.type == 'entry_line' && _vehicles) {
      opts['vehicles'] = true;
      if (_notify) opts['notify'] = true;
      if (_inRight) opts['in_side'] = 'right';
    }
    Map<String, dynamic>? schedule = widget.schedule;
    if (widget.type == 'gate') {
      if (_watchOpen) {
        opts['watch_open'] = true;
        opts['open_min'] = _openMin;
      }
      if (_closedAt != null) opts['closed_at'] = _closedAt;
    }
    if (widget.type == 'post') {
      opts['absent_min'] = _absentMin;
      schedule = {
        'days': (widget.schedule?['days'] as List?) ?? kPostDefaultSchedule['days'],
        'start': _hhmm(_start),
        'end': _hhmm(_end),
      };
    }
    Navigator.of(context).pop<ZoneOptions>((label: _label.text.trim(), schedule: schedule, opts: opts));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final loc = MaterialLocalizations.of(context);
    final lang = _lang(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cdetOptionsTitle(widget.name), style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _label,
            maxLength: 40,
            buildCounter: localCounter,
            decoration: InputDecoration(labelText: t.cdetLabel, border: const OutlineInputBorder()),
          ),
          if (widget.type == 'gate') ...[
            const SizedBox(height: 8),
            Text(t.cdetGatePersonBody, style: theme.textTheme.bodyMedium),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cdetOpenTitle),
              subtitle: Text(t.cdetOpenBody),
              value: _watchOpen,
              onChanged: (v) => setState(() => _watchOpen = v),
            ),
            if (_watchOpen) ...[
              Text(t.cdetOpenAfter, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              _chips(_openChoices, _openMin, (v) => _openMin = v),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.door_front_door_outlined),
                label: Text(t.cdetClosedNow),
                onPressed: () => setState(() {
                  _closedAt = (DateTime.now().millisecondsSinceEpoch / 1000).roundToDouble();
                  _closedJustNow = true;
                }),
              ),
              const SizedBox(height: 4),
              Text(
                  _closedJustNow
                      ? t.cdetClosedSaved
                      : (_closedAt == null ? t.cdetClosedNeeded : t.cdetClosedKnown),
                  style: theme.textTheme.bodySmall),
            ],
          ],
          if (widget.type == 'post') ...[
            const SizedBox(height: 8),
            Text(t.cdetPostHours, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () async {
                  final v = await showTimePicker(context: context, initialTime: _start);
                  if (v != null) setState(() => _start = v);
                },
                child: Text(t.wmFrom(wmDigits(lang, loc.formatTimeOfDay(_start)))),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () async {
                  final v = await showTimePicker(context: context, initialTime: _end);
                  if (v != null) setState(() => _end = v);
                },
                child: Text(t.wmTo(wmDigits(lang, loc.formatTimeOfDay(_end)))),
              ),
            ]),
            const SizedBox(height: 12),
            Text(t.cdetPostAbsent, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _chips(_absentChoices, _absentMin, (v) => _absentMin = v),
          ],
          if (widget.type == 'restricted' || widget.type == 'gate') ...[
            const Divider(height: 24),
            Text(t.cdetLoiterTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _chips(_dwellChoices, _dwellMin, (v) => _dwellMin = v, offFirst: true),
          ],
          // stage 2: crowd / queue count (people only, never who)
          if (const {'restricted', 'gate', 'post'}.contains(widget.type)) ...[
            const Divider(height: 24),
            Text(t.cdetCrowdTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final v in _crowdChoices)
                ChoiceChip(
                  label: Text(v == 0 ? t.cdetOff : t.gcvPlPeople(v, wmDigits(lang, v))),
                  selected: _crowdN == v,
                  onSelected: (_) => setState(() => _crowdN = v),
                ),
            ]),
          ],
          if (widget.type == 'parking') ...[
            const SizedBox(height: 8),
            Text(t.cdetOverstayTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _chips(_overstayChoices, _overstayMin, (v) => _overstayMin = v),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cdetLineNotify),
              value: _notify,
              onChanged: (v) => setState(() => _notify = v),
            ),
          ],
          if (widget.type == 'no_parking') ...[
            const SizedBox(height: 8),
            Text(t.cdetWrongTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _chips(_wrongChoices, _wrongMin, (v) => _wrongMin = v),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cdetLineNotify),
              value: _notify,
              onChanged: (v) => setState(() => _notify = v),
            ),
          ],
          if (widget.type == 'entry_line') ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cdetLineVehicles),
              subtitle: Text(t.cdetLineVehiclesBody),
              value: _vehicles,
              onChanged: (v) => setState(() => _vehicles = v),
            ),
            if (_vehicles) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.cdetLineNotify),
                value: _notify,
                onChanged: (v) => setState(() => _notify = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.cdetLineFlip),
                subtitle: Text(t.cdetLineFlipBody),
                value: _inRight,
                onChanged: (v) => setState(() => _inRight = v),
              ),
            ],
          ],
          if (widget.type == 'parking' || widget.type == 'no_parking' || widget.type == 'entry_line')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t.cdetVehicleNote, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          Text(t.cdetNeedsAi, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _done,
              child: Text(t.cdetDone),
            ),
          ),
        ]),
      ),
    );
  }
}
