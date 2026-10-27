import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business_khata_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show fmtDate, localDigits;
import '../../services/action_feedback.dart';
import '../../services/error_kind.dart';
import '../../state.dart';
import '../../theme.dart';

/// ledger100 — schedule a tagada for ONE customer: a date + time, once or
/// "every N days" (until paid by default), and HOW: a free push to the owner
/// ("time to remind X", one-tap send) or Assisto SMS (credits; never sent at
/// 0 credits — the owner gets the push instead). Fired by the server's
/// `tagada_sweep` cron; quiet hours 9 pm–9 am are respected.
Future<bool?> showTagadaScheduleSheet(BuildContext context,
    {required Map<String, dynamic> business,
    required Map<String, dynamic> party}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TagadaScheduleSheet(business: business, party: party),
  );
}

class TagadaScheduleSheet extends StatefulWidget {
  final Map<String, dynamic> business;
  final Map<String, dynamic> party;
  const TagadaScheduleSheet(
      {super.key, required this.business, required this.party});
  @override
  State<TagadaScheduleSheet> createState() => _TagadaScheduleSheetState();
}

class _TagadaScheduleSheetState extends State<TagadaScheduleSheet> {
  static const _intervals = [1, 3, 7, 15, 30];
  bool _loading = true;
  bool _saving = false;
  Object? _loadFail;
  Map<String, dynamic>? _existing;
  Map<String, dynamic> _sms = const {};
  late DateTime _when;
  int _interval = 7; // 0 = once
  bool _untilPaid = true;
  String _mode = 'push';

  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  int get _partyId => (widget.party['id'] as num?)?.toInt() ?? 0;
  String get _lang => Localizations.localeOf(context).languageCode;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now().add(const Duration(days: 1));
    _when = DateTime(n.year, n.month, n.day, 10, 0);
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context
          .read<AppState>()
          .api
          .getJson('/business/khata/tagada/schedule?business=$_bizId&party=$_partyId');
      final list = ((r['schedules'] ?? []) as List).cast<Map<String, dynamic>>();
      _sms = ((r['sms'] ?? const {}) as Map).cast<String, dynamic>();
      if (list.isNotEmpty) {
        final s = list.first;
        _existing = s;
        _when = DateTime.tryParse('${s['next_at']}')?.toLocal() ?? _when;
        _interval = (s['interval_days'] as num?)?.toInt() ?? 7;
        _untilPaid = s['until_paid'] != false;
        _mode = s['mode'] == 'sms' ? 'sms' : 'push';
      }
    } catch (e) {
      _loadFail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _inQuiet => _when.hour >= 21 || _when.hour < 9;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _when.isBefore(now) ? now : _when,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) {
      setState(() => _when = DateTime(d.year, d.month, d.day, _when.hour, _when.minute));
    }
  }

  Future<void> _pickTime() async {
    final tm = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (tm != null) {
      setState(() =>
          _when = DateTime(_when.year, _when.month, _when.day, tm.hour, tm.minute));
    }
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.tagadaSaveSchedule({
        'business': _bizId,
        'party': _partyId,
        'next_at': _when.toUtc().toIso8601String(),
        'interval_days': _interval,
        'until_paid': _interval == 0 ? true : _untilPaid,
        'channel': _mode == 'sms' ? 'sms' : 'push',
        'preset': 'reminder',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ldgSchedSaved)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionFailed(context, 'khata.scheduleSave', e);
    }
  }

  Future<void> _delete() async {
    final t = AppLocalizations.of(context);
    final id = (_existing?['id'] as num?)?.toInt();
    if (id == null) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.tagadaDeleteSchedule(_bizId, id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ldgSchedDeleted)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionFailed(context, 'khata.scheduleDelete', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = '${widget.party['name'] ?? ''}';
    Widget body;
    if (_loading) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xxl),
          child: Center(child: CircularProgressIndicator()));
    } else if (_loadFail != null) {
      body = Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(failKindOf(_loadFail!) == FailKind.network
              ? t.ldgSchedNeedsOnline
              : honestFailText(t, _loadFail)),
          const SizedBox(height: Gap.md),
          FilledButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _loadFail = null;
                });
                _load();
              },
              child: Text(t.retry)),
        ]),
      );
    } else {
      final smsReady = _sms['available'] == true;
      final perSeg = (_sms['per_segment'] as num?)?.toInt() ?? 1;
      body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.ldgSchedWhen, style: Theme.of(context).textTheme.titleSmall),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_rounded),
                  label: Text(fmtDate('d MMM y', _when, _lang),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: _pickDate,
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(
                      localDigits(TimeOfDay.fromDateTime(_when).format(context), _lang),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onPressed: _pickTime,
                ),
              ),
            ]),
            if (_inQuiet) ...[
              const SizedBox(height: Gap.xs),
              Text(t.ldgSchedQuiet,
                  style: AType.bodySmall.copyWith(color: scheme.error)),
            ],
            const SizedBox(height: Gap.md),
            Text(t.ldgSchedRepeat, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              ChoiceChip(
                  label: Text(t.ldgSchedOnce),
                  selected: _interval == 0,
                  onSelected: (_) => setState(() => _interval = 0)),
              for (final n in _intervals)
                ChoiceChip(
                    label: Text(t.ldgSchedEvery(localDigits('$n', _lang))),
                    selected: _interval == n,
                    onSelected: (_) => setState(() => _interval = n)),
            ]),
            if (_interval > 0)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _untilPaid,
                title: Text(t.ldgSchedUntilPaid),
                onChanged: (v) => setState(() => _untilPaid = v),
              ),
            const SizedBox(height: Gap.sm),
            Text(t.ldgSchedHow, style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v ?? 'push'),
              child: Column(children: [
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'push',
                  title: Text(t.ldgSchedModePush),
                  subtitle: Text(t.ldgSchedModePushSub),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'sms',
                  enabled: smsReady,
                  title: Text(t.ldgSchedModeSms),
                  subtitle: Text(smsReady
                      ? t.ldgSchedModeSmsSub(localDigits('$perSeg', _lang))
                      : t.ldgSmsNotReady),
                ),
              ]),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.ldgSchedQuietAlways,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('ldg-sched-save'),
                icon: const Icon(Icons.alarm_add_rounded),
                label: Text(t.ldgSchedSave),
                onPressed: _saving ? null : _save,
              ),
            ),
            if (_existing != null) ...[
              const SizedBox(height: Gap.sm),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  icon: const Icon(Icons.alarm_off_rounded),
                  label: Text(t.ldgSchedDelete),
                  onPressed: _saving ? null : _delete,
                ),
              ),
            ],
          ]);
    }
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.sm,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.ldgSchedTitleFor(name),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.md),
              body,
            ]),
      ),
    );
  }
}
