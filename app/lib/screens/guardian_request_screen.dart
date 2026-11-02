import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_dest_sheets.dart';
import 'package:assisto/widgets/app_sheet.dart' show withNavBarInset;
import 'messenger/messenger_home_screen.dart';

/// Owner idea 1 — ask to follow someone's trip: pick the person from My
/// Circle (one tap), where (name or a pasted Maps link), the day and the time
/// window, an optional note. Child school mode (a standing school-days
/// schedule) is offered ONLY for a person the server confirmed as the
/// requester's child (both sides say parent/child) and only after the
/// parent confirms the child is under 18; the child still accepts once and
/// always sees it. Adults are asked every time.
class GuardianRequestScreen extends StatefulWidget {
  final List<Map<String, dynamic>> people;
  const GuardianRequestScreen({super.key, required this.people});
  @override
  State<GuardianRequestScreen> createState() => _GuardianRequestScreenState();
}

class _GuardianRequestScreenState extends State<GuardianRequestScreen> {
  int? _member;
  final _dest = TextEditingController();
  final _note = TextEditingController();
  double? _lat, _lng;
  DateTime _day = DateTime.now();
  TimeOfDay _from = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 30)));
  TimeOfDay _to = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 4)));
  bool _school = false;
  bool _minor = false;
  final Set<String> _days = {'sun', 'mon', 'tue', 'wed', 'thu'};
  bool _sending = false;

  static const _week = ['sat', 'sun', 'mon', 'tue', 'wed', 'thu', 'fri'];

  @override
  void dispose() {
    _dest.dispose();
    _note.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _person {
    for (final p in widget.people) {
      if ((p['member_id'] as num?)?.toInt() == _member) return p;
    }
    return null;
  }

  bool get _child => _person?['child'] == true;

  String _dayName(AppLocalizations t, String d) => switch (d) {
        'sat' => t.gjDaySat,
        'sun' => t.gjDaySun,
        'mon' => t.gjDayMon,
        'tue' => t.gjDayTue,
        'wed' => t.gjDayWed,
        'thu' => t.gjDayThu,
        _ => t.gjDayFri,
      };

  String _hhmm(TimeOfDay x) =>
      '${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';

  Future<void> _link() async {
    final got = await showJourneyLinkSheet(context, context.read<AppState>().api);
    if (got == null || !mounted) return;
    setState(() {
      if (got.name.isNotEmpty) _dest.text = got.name;
      _lat = got.lat;
      _lng = got.lng;
    });
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_member == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.gjNeedPerson)));
      return;
    }
    if (_dest.text.trim().isEmpty && _lat == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedDest)));
      return;
    }
    final dest = {
      'name': _dest.text.trim(),
      if (_lat != null) 'lat': _lat,
      if (_lng != null) 'lng': _lng,
    };
    final body = <String, dynamic>{'member_id': _member, 'destination': dest,
        'note': _note.text.trim()};
    if (_school && _child) {
      if (!_minor) {
        messenger.showSnackBar(SnackBar(content: Text(t.gjNeedMinor)));
        return;
      }
      body.addAll({
        'standing': true,
        'minor_declared': true,
        'schedule': {'days': _days.toList(), 'start': _hhmm(_from), 'end': _hhmm(_to)},
      });
    } else {
      var s = DateTime(_day.year, _day.month, _day.day, _from.hour, _from.minute);
      var e = DateTime(_day.year, _day.month, _day.day, _to.hour, _to.minute);
      if (!e.isAfter(s)) e = e.add(const Duration(days: 1)); // overnight trip
      body['start'] = s.toUtc().toIso8601String();
      body['end'] = e.toUtc().toIso8601String();
    }
    setState(() => _sending = true);
    try {
      await context.read<AppState>().api.journeyRequestCreate(body);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(t.gjSent)));
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      final msg = switch (e.message) {
        final m when m.contains('window_too_long') => t.gjErrLong,
        final m when m.contains('too_far_ahead') => t.gjErrFar,
        final m when m.contains('bad_window') => t.gjErrWindow,
        final m when m.contains('too_many_pending') || m.contains('daily_limit') => t.gjErrSpam,
        final m when m.contains('not_in_circle') => t.gjErrCircle,
        final m when m.contains('standing') => t.gjErrChild,
        _ => null,
      };
      if (msg != null) {
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      } else {
        showActionFailed(context, 'guardian.ask', e);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showActionFailed(context, 'guardian.ask', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    Widget h(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
        child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)));
    return Scaffold(
      appBar: AppBar(title: Text(t.gjAskTitle)),
      body: ListView(
          cacheExtent: 3000,
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            Text(t.gjAskIntro, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
            h(t.gjWho),
            if (widget.people.isEmpty) ...[
              Text(t.journeyNoWatchers),
              const SizedBox(height: Gap.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(t.truthJourneyAddFamily),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const MessengerHomeScreen(startAdd: true))),
                ),
              ),
            ],
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final p in widget.people)
                ChoiceChip(
                  key: ValueKey('gj_person_${p['member_id']}'),
                  label: Text('${p['name'] ?? ''}'),
                  selected: _member == (p['member_id'] as num?)?.toInt(),
                  onSelected: (_) => setState(() {
                    _member = (p['member_id'] as num?)?.toInt();
                    if (!_child) _school = false;
                  }),
                ),
            ]),
            h(t.journeyDestSection),
            TextField(
                key: const ValueKey('gj_dest'),
                controller: _dest,
                decoration: InputDecoration(labelText: t.journeyDestLabel)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, children: [
              OutlinedButton.icon(
                  icon: const Icon(Icons.link_rounded),
                  label: Text(t.j2PasteLink),
                  onPressed: _link),
              if (_lat != null)
                Chip(
                    avatar: const Icon(Icons.where_to_vote_rounded, color: Brand.successFill),
                    label: Text(t.journeyDestPinned)),
            ]),
            if (_child)
              SwitchListTile(
                key: const ValueKey('gj_school'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.gjSchoolMode),
                subtitle: Text(t.gjSchoolModeDesc),
                value: _school,
                onChanged: (v) => setState(() => _school = v),
              ),
            if (_school && _child) ...[
              CheckboxListTile(
                key: const ValueKey('gj_minor'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.gjMinor),
                value: _minor,
                onChanged: (v) => setState(() => _minor = v == true),
              ),
              Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                for (final d in _week)
                  FilterChip(
                    label: Text(_dayName(t, d)),
                    selected: _days.contains(d),
                    onSelected: (v) => setState(() => v ? _days.add(d) : _days.remove(d)),
                  ),
              ]),
            ],
            h(t.gjWhen),
            if (!(_school && _child))
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded),
                label: Text(MaterialLocalizations.of(context).formatMediumDate(_day)),
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(
                      context: context,
                      initialDate: _day,
                      firstDate: DateTime(now.year, now.month, now.day),
                      lastDate: now.add(const Duration(days: 7)));
                  if (d != null) setState(() => _day = d);
                },
              ),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              OutlinedButton.icon(
                key: const ValueKey('gj_from'),
                icon: const Icon(Icons.schedule_rounded),
                label: Text(t.gjFrom(_from.format(context))),
                onPressed: () async {
                  final p = await showTimePicker(context: context, initialTime: _from);
                  if (p != null) setState(() => _from = p);
                },
              ),
              OutlinedButton.icon(
                key: const ValueKey('gj_to'),
                icon: const Icon(Icons.schedule_rounded),
                label: Text(t.gjTo(_to.format(context))),
                onPressed: () async {
                  final p = await showTimePicker(context: context, initialTime: _to);
                  if (p != null) setState(() => _to = p);
                },
              ),
            ]),
            const SizedBox(height: Gap.sm),
            TextField(
                key: const ValueKey('gj_note'),
                controller: _note,
                maxLength: 200,
                decoration: InputDecoration(labelText: t.gjNote)),
            Text(t.gjRulesNote, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const ValueKey('gj_send'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: Text(t.gjSend),
            ),
          ]),
    );
  }
}

