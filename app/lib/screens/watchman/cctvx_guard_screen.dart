import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../cctvx/cctvx_source.dart';
import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvx — GUARD SETTINGS for one place (owner order 28 Oct): the no-sale
/// drawer window (1-10 min, server-bounded), who gets an alert the owner has
/// not opened (an ordered chain of up to 3 Circle people), offline alerts,
/// shop opening hours + "shop opened" / late-opening notices, closed days and
/// the shop's phone number (the "Call the shop" action). Every change is
/// saved at once; the server clamps every number. No ads on this screen.
class GuardSettingsScreen extends StatefulWidget {
  final CctvxSource source;
  final int siteId;

  /// For the opening hours (PATCH shop/sites/<id>), when available.
  final WatchmanSource? watchman;
  final Map<String, dynamic> hours;
  const GuardSettingsScreen(
      {super.key, required this.source, required this.siteId, this.watchman, this.hours = const {}});

  @override
  State<GuardSettingsScreen> createState() => _GuardSettingsScreenState();
}

class _GuardSettingsScreenState extends State<GuardSettingsScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};
  Map<String, dynamic> _s = {};
  bool _busy = false;
  final _phone = TextEditingController();
  late Map<String, dynamic> _hours = Map.of(widget.hours);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _apply(Map<String, dynamic> d) {
    _d = d;
    _s = Map.of(wmMap(d['settings']));
    _phone.text = (_s['shop_phone'] ?? '').toString();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _apply(await widget.source.guard(widget.siteId));
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _save(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    var ok = true;
    setState(() {
      _busy = true;
      _s.addAll(body);
    });
    try {
      _apply(await widget.source.saveGuard(widget.siteId, body));
    } catch (e) {
      ok = false;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
      await _load();
    }
    if (mounted) setState(() => _busy = false);
    return ok;
  }

  List<int> _b(String key, List<int> fallback) {
    final v = wmMap(_d['bounds'])[key];
    if (v is List && v.length == 2) return [(v[0] as num).toInt(), (v[1] as num).toInt()];
    return fallback;
  }

  int _i(String key, int d) => (_s[key] as num?)?.toInt() ?? d;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(32), children: [
        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
            child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry))),
      ]);
    } else {
      body = ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        _noSaleCard(t),
        _escalationCard(t),
        _offlineCard(t),
        _hoursCard(t),
        _phoneCard(t),
        _usageCard(t),
      ]);
    }
    return Scaffold(appBar: AppBar(title: Text(t.cxSettingsTitle)), body: body);
  }

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );

  Widget _title(IconData icon, String text) => Row(children: [
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
      ]);

  Widget _minutes(String key, int value, List<int> b, String Function(String) label,
      {int step = 1}) {
    final lang = wmLang(context);
    final divisions = ((b[1] - b[0]) ~/ step).clamp(1, 100);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label(wmDigits(lang, value))),
      Slider(
        min: b[0].toDouble(),
        max: b[1].toDouble(),
        divisions: divisions,
        value: value.clamp(b[0], b[1]).toDouble(),
        label: wmDigits(lang, value),
        semanticFormatterCallback: (v) => label(wmDigits(lang, v.round())),
        onChanged: _busy ? null : (v) => setState(() => _s[key] = v.round()),
        onChangeEnd: _busy ? null : (v) => _save({key: v.round()}),
      ),
    ]);
  }

  Widget _noSaleCard(AppLocalizations t) {
    final on = _s['nosale_on'] != false;
    return _card([
      _title(Icons.point_of_sale_rounded, t.cxNoSaleTitle),
      const SizedBox(height: 6),
      Text(t.cxNoSaleBody),
      if (_d['uses_records'] == false) ...[
        const SizedBox(height: 6),
        Text(t.cxNoSaleNoRecords, style: Theme.of(context).textTheme.bodySmall),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.cxNoSaleSwitch),
        value: on,
        onChanged: _busy ? null : (v) => _save({'nosale_on': v}),
      ),
      if (on) _minutes('nosale_min', _i('nosale_min', 2), _b('nosale_min', [1, 10]), t.cxNoSaleWindow),
      if (_d['tip'] == 'raise_window')
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.cxNoSaleTip, style: Theme.of(context).textTheme.bodySmall),
        ),
    ]);
  }

  Widget _escalationCard(AppLocalizations t) {
    final circle = wmList(_d['circle']);
    final chain = [for (final u in (_s['escalation'] as List? ?? const [])) (u as num).toInt()];
    final names = {for (final p in circle) (p['uid'] as num).toInt(): (p['name'] ?? '').toString()};
    final maxChain = (_d['max_chain'] as num?)?.toInt() ?? 3;
    final lang = wmLang(context);
    final free = circle.where((p) => !chain.contains((p['uid'] as num).toInt())).toList();
    return _card([
      _title(Icons.groups_rounded, t.cxEscalationTitle),
      const SizedBox(height: 6),
      Text(t.cxEscalationBody),
      const SizedBox(height: 8),
      if (circle.isEmpty) Text(t.cxEscalationNoCircle, style: Theme.of(context).textTheme.bodySmall),
      for (var i = 0; i < chain.length; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          minTileHeight: 52,
          leading: CircleAvatar(child: Text(wmDigits(lang, i + 1))),
          title: Text(names[chain[i]] ?? '—'),
          subtitle: Text(t.cxEscalationAfter(wmDigits(lang, _i('escalate_min', 2) * (i + 1)))),
          trailing: Wrap(children: [
            if (i > 0)
              IconButton(
                tooltip: t.cxMoveUp,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.arrow_upward_rounded),
                onPressed: _busy
                    ? null
                    : () {
                        final c = [...chain];
                        final x = c.removeAt(i);
                        c.insert(i - 1, x);
                        _save({'escalation': c});
                      },
              ),
            IconButton(
              tooltip: t.cxRemove,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.close_rounded),
              onPressed: _busy ? null : () => _save({'escalation': [...chain]..removeAt(i)}),
            ),
          ]),
        ),
      if (chain.length < maxChain && free.isNotEmpty)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(t.cxEscalationAdd),
            onPressed: _busy
                ? null
                : () async {
                    final uid = await showModalBottomSheet<int>(
                      context: context,
                      showDragHandle: true,
                      builder: (ctx) => SafeArea(
                        child: SingleChildScrollView(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            for (final p in free)
                              ListTile(
                                minTileHeight: 52,
                                leading: const Icon(Icons.person_rounded),
                                title: Text((p['name'] ?? '').toString()),
                                onTap: () => Navigator.pop(ctx, (p['uid'] as num).toInt()),
                              ),
                          ]),
                        ),
                      ),
                    );
                    if (uid != null) await _save({'escalation': [...chain, uid]});
                  },
          ),
        ),
      if (chain.isNotEmpty)
        _minutes('escalate_min', _i('escalate_min', 2), _b('escalate_min', [1, 10]), t.cxEscalationWait),
    ]);
  }

  Widget _offlineCard(AppLocalizations t) {
    final on = _s['offline_on'] != false;
    return _card([
      _title(Icons.power_off_rounded, t.cxOfflineTitle),
      const SizedBox(height: 6),
      Text(t.cxOfflineBody),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.cxOfflineSwitch),
        value: on,
        onChanged: _busy ? null : (v) => _save({'offline_on': v}),
      ),
      if (on)
        _minutes('offline_min', _i('offline_min', 10), _b('offline_min', [5, 60]), t.cxOfflineAfter,
            step: 5),
    ]);
  }

  Future<void> _pickHour(bool open) async {
    final t = AppLocalizations.of(context);
    TimeOfDay? parse(Object? v) {
      final p = (v ?? '').toString().split(':');
      if (p.length != 2) return null;
      final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
      return (h == null || m == null) ? null : TimeOfDay(hour: h, minute: m);
    }

    final cur = parse(_hours[open ? 'open' : 'close']) ??
        (open ? const TimeOfDay(hour: 9, minute: 0) : const TimeOfDay(hour: 21, minute: 0));
    final v = await showTimePicker(context: context, initialTime: cur);
    if (v == null || widget.watchman == null) return;
    String hm(TimeOfDay x) => '${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
    final next = {
      'open': open ? hm(v) : (_hours['open'] ?? '09:00'),
      'close': open ? (_hours['close'] ?? '21:00') : hm(v),
    };
    try {
      await widget.watchman!.patchSite(widget.siteId, {'hours': next});
      setState(() => _hours = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
  }

  Widget _hoursCard(AppLocalizations t) {
    final lang = wmLang(context);
    final days = [for (final d in (_s['closed_days'] as List? ?? const [])) (d as num).toInt()];
    String day(int wd) => DateFormat.E(lang).format(DateTime(2026, 10, 26 + wd)); // 26 Oct 2026 = Monday
    final has = (_hours['open'] ?? '').toString().isNotEmpty;
    return _card([
      _title(Icons.storefront_rounded, t.cxHoursTitle),
      const SizedBox(height: 6),
      Text(t.cxHoursBody),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: widget.watchman == null ? null : () => _pickHour(true),
          child: Text(t.cxOpensAt(wmDigits(lang, (_hours['open'] ?? '—').toString()))),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: widget.watchman == null ? null : () => _pickHour(false),
          child: Text(t.cxClosesAt(wmDigits(lang, (_hours['close'] ?? '—').toString()))),
        ),
      ]),
      if (!has)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(t.cxHoursMissing, style: Theme.of(context).textTheme.bodySmall),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.cxOpenedSwitch),
        value: _s['opened_on'] != false,
        onChanged: _busy ? null : (v) => _save({'opened_on': v}),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.cxLateSwitch),
        value: _s['late_on'] != false,
        onChanged: _busy ? null : (v) => _save({'late_on': v}),
      ),
      if (_s['late_on'] != false)
        _minutes('late_min', _i('late_min', 30), _b('late_min', [10, 180]), t.cxLateAfter, step: 10),
      const SizedBox(height: 4),
      Text(t.cxClosedDays),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (var wd = 0; wd < 7; wd++)
          FilterChip(
            label: Text(day(wd)),
            selected: days.contains(wd),
            onSelected: _busy
                ? null
                : (sel) {
                    final next = {...days};
                    sel ? next.add(wd) : next.remove(wd);
                    _save({'closed_days': next.toList()..sort()});
                  },
          ),
      ]),
    ]);
  }

  Widget _phoneCard(AppLocalizations t) => _card([
        _title(Icons.call_rounded, t.cxPhoneTitle),
        const SizedBox(height: 6),
        Text(t.cxPhoneBody),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t.cxPhoneLabel, border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: _busy
                ? null
                : () async {
                    final ok = await _save({'shop_phone': _phone.text.trim()});
                    if (ok && mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(t.cxPhoneSaved)));
                    }
                  },
            child: Text(t.cxSave),
          ),
        ]),
      ]);

  Widget _usageCard(AppLocalizations t) {
    final lang = wmLang(context);
    final caps = wmMap(_d['caps']);
    final use = wmMap(_d['usage']);
    String d(Map<String, dynamic> m, String k) => wmDigits(lang, (m[k] as num?)?.toInt() ?? 0);
    return _card([
      _title(Icons.speed_rounded, t.cxCapsTitle),
      const SizedBox(height: 6),
      Text(t.cxCapsLine(d(use, 'escalations_day'), d(caps, 'escalations_day'),
          d(use, 'offline_day'), d(caps, 'offline_day'), d(use, 'sirens_day'), d(caps, 'sirens_day'))),
      const SizedBox(height: 4),
      Text(t.cxCapsNote, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

/// cctvx — TODAY'S GUARD REPORT card (the evening brief's section, live).
class GuardReportCard extends StatefulWidget {
  final CctvxSource source;
  final int siteId;
  const GuardReportCard({super.key, required this.source, required this.siteId});

  @override
  State<GuardReportCard> createState() => _GuardReportCardState();
}

class _GuardReportCardState extends State<GuardReportCard> {
  List<String>? _lines;

  @override
  void initState() {
    super.initState();
    widget.source.report(widget.siteId).then((r) {
      if (mounted) setState(() => _lines = [for (final l in (r['lines'] as List? ?? const [])) l.toString()]);
    }).catchError((_) {
      if (mounted) setState(() => _lines = const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.summarize_rounded),
            const SizedBox(width: 8),
            Expanded(child: Text(t.cxReportTitle, style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 6),
          if (_lines == null)
            const LinearProgressIndicator()
          else if (_lines!.isEmpty)
            Text(t.cxReportEmpty)
          else
            for (final l in _lines!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(l),
              ),
          const SizedBox(height: 6),
          Text(t.cxReportNote, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
