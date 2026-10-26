import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/bn_day_periods.dart' show appDateLocale;
import 'booking_source.dart';
import 'booking_widgets.dart';

/// booking-bot — the 3-step setup wizard: 1 services, 2 weekly hours + days
/// off, 3 rules (capacity, staff, confirm, cancel window, chat bot, link) and
/// switching online booking on. Every step saves to the server for real.
class BookingSetupScreen extends StatefulWidget {
  final BookingSource source;
  final Map<String, dynamic> initial;
  final int initialStep;
  const BookingSetupScreen({super.key, required this.source, required this.initial, this.initialStep = 0});

  @override
  State<BookingSetupScreen> createState() => _BookingSetupScreenState();
}

const _durations = [15, 20, 30, 45, 60, 90, 120];
const _buffers = [0, 5, 10, 15, 30];
const _cancelHours = [0, 1, 2, 4, 12, 24];

class _BookingSetupScreenState extends State<BookingSetupScreen> {
  late int _step = widget.initialStep;
  late List<Map<String, dynamic>> _services = bkList(widget.initial['services']);
  late List<Map<String, dynamic>> _staff = bkList(widget.initial['staff']);
  late final Map<int, List<String>?> _hours = _initHours();
  late final List<String> _daysOff = [...(widget.initial['days_off'] as List? ?? const []).map((e) => e.toString())];
  late int _capacity = (widget.initial['capacity'] as num?)?.toInt() ?? 1;
  late bool _auto = widget.initial['auto_confirm'] == true;
  late int _cancel = (widget.initial['cancel_hours'] as num?)?.toInt() ?? 2;
  late bool _bot = widget.initial['chat_bot'] != false;
  late bool _sms = widget.initial['sms_reminders'] == true;
  late bool _enabled = widget.initial['enabled'] == true || bkList(widget.initial['services']).isEmpty;
  late final _slug = TextEditingController(text: (widget.initial['slug'] ?? '').toString());
  final _svcName = TextEditingController();
  final _svcPrice = TextEditingController();
  final _staffName = TextEditingController();
  int _svcDur = 30;
  int _svcBuf = 0;
  bool _busy = false;
  String? _err;

  Map<int, List<String>?> _initHours() {
    final raw = bkMap(widget.initial['weekly_hours']);
    final out = <int, List<String>?>{};
    for (var d = 0; d < 7; d++) {
      final iv = raw['$d'];
      if (iv is List && iv.isNotEmpty && iv.first is List) {
        final f = (iv.first as List).map((e) => e.toString()).toList();
        out[d] = [f[0], f[1]];
      } else if (raw.isEmpty) {
        out[d] = d == 4 ? null : ['10:00', '20:00']; // Friday off by default
      } else {
        out[d] = null;
      }
    }
    return out;
  }

  @override
  void dispose() {
    _slug.dispose();
    _svcName.dispose();
    _svcPrice.dispose();
    _staffName.dispose();
    super.dispose();
  }

  String _msg(Object e) {
    final t = AppLocalizations.of(context);
    if (bkOffline(e)) return t.bkgOfflineBody;
    return bkError(e) ?? t.bkgErrorBody;
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await f();
    } catch (e) {
      _err = _msg(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addService() async {
    final t = AppLocalizations.of(context);
    if (_svcName.text.trim().isEmpty) {
      setState(() => _err = t.bkgServiceNameNeeded);
      return;
    }
    await _run(() async {
      final s = await widget.source.addService({
        'name': _svcName.text.trim(),
        'duration_min': _svcDur,
        'buffer_min': _svcBuf,
        'price_bdt': int.tryParse(_svcPrice.text.trim()) ?? 0,
      });
      _services = [..._services, s];
      _svcName.clear();
      _svcPrice.clear();
    });
  }

  Future<void> _deleteService(Map<String, dynamic> s) async {
    await _run(() async {
      await widget.source.deleteService(s['id'] as int);
      _services = _services.where((x) => x['id'] != s['id']).toList();
    });
  }

  Future<void> _addStaff() async {
    if (_staffName.text.trim().isEmpty) {
      setState(() => _err = AppLocalizations.of(context).bkgStaffNameNeeded);
      return;
    }
    await _run(() async {
      final s = await widget.source.addStaff(_staffName.text.trim());
      _staff = [..._staff, s];
      _staffName.clear();
    });
  }

  Future<void> _deleteStaff(Map<String, dynamic> s) async {
    await _run(() async {
      await widget.source.deleteStaff(s['id'] as int);
      _staff = _staff.where((x) => x['id'] != s['id']).toList();
    });
  }

  Map<String, dynamic> _hoursBody() => {
        for (final e in _hours.entries)
          if (e.value != null) '${e.key}': [e.value],
      };

  Future<void> _saveHours() async {
    await _run(() async {
      await widget.source.savePage({'weekly_hours': _hoursBody(), 'days_off': _daysOff});
      _step = 2;
    });
  }

  Future<void> _finish() async {
    await _run(() async {
      await widget.source.savePage({
        'capacity': _capacity,
        'auto_confirm': _auto,
        'cancel_hours': _cancel,
        'chat_bot': _bot,
        'sms_reminders': _sms,
        if (_slug.text.trim().isNotEmpty) 'slug': _slug.text.trim(),
        'enabled': _enabled,
      });
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = bkLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bkgSetupTitle)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
                  child: LinearProgressIndicator(value: i <= _step ? 1 : 0, minHeight: 6),
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(t.bkgStepOf(bkDigits(lang, _step + 1), bkDigits(lang, 3)),
                style: Theme.of(context).textTheme.labelLarge),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
            if (_step == 0) ..._servicesStep(t, lang),
            if (_step == 1) ..._hoursStep(t, lang),
            if (_step == 2) ..._rulesStep(t, lang),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: Row(children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
                    onPressed: _busy ? null : () => setState(() => _step--),
                    child: Text(t.bkgBack),
                  ),
                ),
              if (_step > 0) const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                  onPressed: _busy
                      ? null
                      : () {
                          if (_step == 0) {
                            if (_services.isEmpty) {
                              setState(() => _err = t.bkgAddOneService);
                            } else {
                              setState(() {
                                _err = null;
                                _step = 1;
                              });
                            }
                          } else if (_step == 1) {
                            _saveHours();
                          } else {
                            _finish();
                          }
                        },
                  child: Text(_step == 2 ? t.bkgFinish : t.bkgNext),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  List<Widget> _servicesStep(AppLocalizations t, String lang) => [
        Text(t.bkgStep1Title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.bkgStep1Body),
        const SizedBox(height: Gap.md),
        for (final s in _services)
          Card(
            child: ListTile(
              minVerticalPadding: Gap.md,
              title: Text(s['name'].toString()),
              subtitle: Text([
                t.bkgMinutes(bkDigits(lang, s['duration_min'] ?? 0)),
                if ((s['buffer_min'] ?? 0) != 0) t.bkgBufferShort(bkDigits(lang, s['buffer_min'])),
                if ((s['price_bdt'] ?? 0) != 0) t.bkgPriceShort(bkDigits(lang, s['price_bdt'])),
              ].join(' · ')),
              trailing: IconButton(
                tooltip: t.bkgRemove,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: _busy ? null : () => _deleteService(s),
              ),
            ),
          ),
        const SizedBox(height: Gap.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.bkgAddService, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.sm),
              TextField(
                  controller: _svcName,
                  inputFormatters: [LengthLimitingTextInputFormatter(80)],
                  decoration: InputDecoration(labelText: t.bkgServiceName, hintText: t.bkgServiceHint)),
              DropdownButtonFormField<int>(
                initialValue: _svcDur,
                isExpanded: true,
                decoration: InputDecoration(labelText: t.bkgDuration),
                items: [
                  for (final d in _durations)
                    DropdownMenuItem(value: d, child: Text(t.bkgMinutes(bkDigits(lang, d)))),
                ],
                onChanged: (v) => setState(() => _svcDur = v ?? 30),
              ),
              const SizedBox(height: Gap.sm),
              DropdownButtonFormField<int>(
                initialValue: _svcBuf,
                isExpanded: true,
                decoration: InputDecoration(labelText: t.bkgBuffer, helperText: t.bkgBufferHelp, helperMaxLines: 3),
                items: [
                  for (final d in _buffers)
                    DropdownMenuItem(value: d, child: Text(t.bkgMinutes(bkDigits(lang, d)))),
                ],
                onChanged: (v) => setState(() => _svcBuf = v ?? 0),
              ),
              const SizedBox(height: Gap.sm),
              TextField(
                  controller: _svcPrice,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t.bkgPrice, helperText: t.bkgPriceHelp, helperMaxLines: 3)),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.bkgAddService),
                onPressed: _busy ? null : _addService,
              ),
            ]),
          ),
        ),
      ];

  String _dayName(int d) =>
      // 2024-01-01 was a Monday (Mon = 0, like the server)
      DateFormat('EEEE', appDateLocale(context)).format(DateTime(2024, 1, 1 + d));

  Future<void> _pickTime(int d, int which) async {
    final cur = _hours[d]![which].split(':');
    final picked = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: int.parse(cur[0]), minute: int.parse(cur[1])));
    if (picked == null) return;
    final m = (picked.minute ~/ 5) * 5;
    final v = '${picked.hour.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    setState(() => _hours[d]![which] = v);
  }

  List<Widget> _hoursStep(AppLocalizations t, String lang) => [
        Text(t.bkgStep2Title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.bkgStep2Body),
        const SizedBox(height: Gap.md),
        for (var d = 0; d < 7; d++)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_dayName(d)),
                  subtitle: Text(_hours[d] == null ? t.bkgClosed : t.bkgOpen),
                  value: _hours[d] != null,
                  onChanged: (v) => setState(() => _hours[d] = v ? ['10:00', '20:00'] : null),
                ),
                if (_hours[d] != null)
                  Wrap(spacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                      onPressed: () => _pickTime(d, 0),
                      child: Text(t.bkgOpensAt(bkDigits(lang, _hours[d]![0]))),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                      onPressed: () => _pickTime(d, 1),
                      child: Text(t.bkgClosesAt(bkDigits(lang, _hours[d]![1]))),
                    ),
                  ]),
              ]),
            ),
          ),
        const SizedBox(height: Gap.md),
        Text(t.bkgDaysOff, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        Text(t.bkgDaysOffBody),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final d in _daysOff)
            InputChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(bkDayLabel(context, DateTime.parse(d))),
              onDeleted: () => setState(() => _daysOff.remove(d)),
              deleteButtonTooltipMessage: t.bkgRemove,
            ),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.event_busy_rounded),
            label: Text(t.bkgAddDayOff),
            onPressed: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: bkToday().add(const Duration(days: 1)),
                  firstDate: bkToday(),
                  lastDate: bkToday().add(const Duration(days: 365)));
              if (d != null && !_daysOff.contains(bkIsoDay(d))) {
                setState(() => _daysOff
                  ..add(bkIsoDay(d))
                  ..sort());
              }
            },
          ),
        ),
      ];

  List<Widget> _rulesStep(AppLocalizations t, String lang) => [
        Text(t.bkgStep3Title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.bkgStep3Body),
        const SizedBox(height: Gap.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.bkgStaffTitle, style: Theme.of(context).textTheme.titleSmall),
              Text(t.bkgStaffBody),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                for (final s in _staff)
                  InputChip(
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(s['name'].toString()),
                    onDeleted: _busy ? null : () => _deleteStaff(s),
                    deleteButtonTooltipMessage: t.bkgRemove,
                  ),
              ]),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: _staffName,
                        inputFormatters: [LengthLimitingTextInputFormatter(80)],
                        decoration: InputDecoration(labelText: t.bkgStaffName))),
                IconButton(
                    tooltip: t.bkgAddStaff,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    onPressed: _busy ? null : _addStaff),
              ]),
              if (_staff.isEmpty) ...[
                const SizedBox(height: Gap.sm),
                Text(t.bkgCapacity, style: Theme.of(context).textTheme.titleSmall),
                Text(t.bkgCapacityBody),
                Row(children: [
                  IconButton(
                      tooltip: t.bkgLess,
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                      onPressed: _capacity > 1 ? () => setState(() => _capacity--) : null),
                  Text(bkDigits(lang, _capacity), style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                      tooltip: t.bkgMore,
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      onPressed: _capacity < 20 ? () => setState(() => _capacity++) : null),
                ]),
              ],
            ]),
          ),
        ),
        SwitchListTile(
          title: Text(t.bkgAutoConfirm),
          subtitle: Text(t.bkgAutoConfirmBody),
          value: _auto,
          onChanged: (v) => setState(() => _auto = v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: DropdownButtonFormField<int>(
            initialValue: _cancelHours.contains(_cancel) ? _cancel : 2,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.bkgCancelWindow, helperText: t.bkgCancelWindowBody, helperMaxLines: 3),
            items: [
              for (final h in _cancelHours)
                DropdownMenuItem(value: h, child: Text(h == 0 ? t.bkgAnyTime : t.bkgHoursBefore(bkDigits(lang, h)))),
            ],
            onChanged: (v) => setState(() => _cancel = v ?? 2),
          ),
        ),
        SwitchListTile(
          title: Text(t.bkgChatBot),
          subtitle: Text(t.bkgChatBotBody),
          value: _bot,
          onChanged: (v) => setState(() => _bot = v),
        ),
        SwitchListTile(
          title: Text(t.bkgSms),
          subtitle: Text(widget.initial['sms_available'] == true ? t.bkgSmsBody : t.bkgSmsUnavailable),
          value: _sms && widget.initial['sms_available'] == true,
          onChanged: widget.initial['sms_available'] == true ? (v) => setState(() => _sms = v) : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: TextField(
            controller: _slug,
            inputFormatters: [LengthLimitingTextInputFormatter(40)],
            decoration: InputDecoration(
                labelText: t.bkgLinkName, helperText: t.bkgLinkNameBody, helperMaxLines: 3, prefixText: '/b/'),
          ),
        ),
        SwitchListTile(
          title: Text(t.bkgTakeBookings),
          subtitle: Text(widget.initial['plan_ok'] == false ? t.bkgNeedsPlan : t.bkgTakeBookingsBody),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
      ];
}
