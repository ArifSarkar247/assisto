import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cctvx/activity_source.dart';
import '../../cctvx/timelapse_gif.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvactivity (W10, owner CCTV order 3 Nov E1 E2 E5 E6 E7 E10 F2) — the
/// ACTIVITY BRAIN of one site: the day in numbers (the same lines the
/// morning summary sends), shop open / close from the camera with a one-tap
/// confirm, visitors per hour next to POS sales (conversion, busiest hours),
/// the hourly watchman check, camera health, the searchable VISITOR LOG
/// (photo + short description; AI only with a key and inside the monthly
/// limit, else labelled automatic text; no face recognition) and the 30-s
/// TIME-LAPSE built on this phone from the day's stored photos.
class ActivityScreen extends StatefulWidget {
  final ActivitySource source;
  final int siteId;
  final String siteName;
  final bool owner;

  /// Tests / gallery: open on this tab (0 summary, 1 visitors, 2 time-lapse).
  final int initialTab;

  /// Tests / gallery: a fixed "today".
  final DateTime? today;
  const ActivityScreen(
      {super.key,
      required this.source,
      required this.siteId,
      this.siteName = '',
      this.owner = true,
      this.initialTab = 0,
      this.today});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _hourLabel(String lang, int h) =>
    wmDigits(lang, '${h.toString().padLeft(2, '0')}:00–${((h + 1) % 24).toString().padLeft(2, '0')}:00');

class _ActivityScreenState extends State<ActivityScreen> {
  late final DateTime _today = widget.today ?? DateTime.now();
  late DateTime _date = DateTime(_today.year, _today.month, _today.day);
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _day = const {};

  bool get _isToday => _ymd(_date) == _ymd(_today);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _day = await widget.source.day(widget.siteId, date: _ymd(_date));
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _shift(int days) {
    final n = _date.add(Duration(days: days));
    if (n.isAfter(DateTime(_today.year, _today.month, _today.day))) return;
    setState(() => _date = n);
    _load();
  }

  Map<String, dynamic> get _settings => wmMap(_day['settings']);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final loc = MaterialLocalizations.of(context);
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.siteName.isEmpty ? t.cactTitle : '${t.cactTitle} · ${widget.siteName}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.owner && _settings.isNotEmpty)
              IconButton(
                key: const ValueKey('cact-settings'),
                tooltip: t.cactSettings,
                icon: const Icon(Icons.tune_rounded),
                onPressed: () => _openSettings(context),
              ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t.cactTabSummary),
            Tab(text: t.cactTabVisitors),
            Tab(text: t.cactTabTimelapse),
          ]),
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [
              IconButton(
                key: const ValueKey('cact-prev'),
                tooltip: t.cactPrevDay,
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => _shift(-1),
              ),
              Expanded(
                child: Text(
                  wmDigits(lang, _isToday ? '${t.cactToday} · ${loc.formatMediumDate(_date)}' : loc.formatFullDate(_date)),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                key: const ValueKey('cact-next'),
                tooltip: t.cactNextDay,
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: _isToday ? null : () => _shift(1),
              ),
            ]),
          ),
          Expanded(
            child: TabBarView(children: [
              _summaryTab(context, t, lang),
              _VisitorLog(
                  key: ValueKey('vis-${_ymd(_date)}'),
                  source: widget.source,
                  siteId: widget.siteId,
                  date: _ymd(_date)),
              _Timelapse(
                  key: ValueKey('tl-${_ymd(_date)}'),
                  source: widget.source,
                  siteId: widget.siteId,
                  date: _date),
            ]),
          ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------- summary
  Widget _summaryTab(BuildContext context, AppLocalizations t, String lang) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(padding: const EdgeInsets.all(32), children: [
        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
            child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry))),
      ]);
    }
    final lines = (_day['lines'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    final s = _settings;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: [
          if (!widget.owner)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(t.cactRole, style: Theme.of(context).textTheme.bodySmall),
            ),
          _card(context, Icons.summarize_rounded, t.cactSummaryTitle, [
            for (final l in lines)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l)),
            if (widget.owner && s.isNotEmpty)
              Text(
                  s['brief_on'] == true
                      ? t.cactSummaryHint(wmDigits(lang, s['brief_hour'] ?? 8))
                      : t.cactSummaryOff,
                  style: Theme.of(context).textTheme.bodySmall),
          ]),
          _openClose(context, t, lang),
          _footfall(context, t, lang),
          _watchman(context, t, lang),
          _health(context, t, lang),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, IconData icon, String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }

  Widget _openClose(BuildContext context, AppLocalizations t, String lang) {
    final oc = wmMap(_day['open_close']);
    final open = (oc['open'] ?? '').toString();
    final close = (oc['close'] ?? '').toString();
    final last = (oc['last_seen'] ?? '').toString();
    final confirmed = oc['confirmed'] == true;
    final children = <Widget>[];
    if (open.isEmpty && close.isEmpty) {
      children.add(Text(t.cactOcNone));
    } else {
      children.add(Text(t.cactOcLine(wmDigits(lang, open.isEmpty ? '—' : open),
          wmDigits(lang, close.isEmpty ? '—' : close))));
      if (close.isEmpty && last.isNotEmpty && _isToday) {
        children.add(Text(t.cactOcStillOpen(wmDigits(lang, last)),
            style: Theme.of(context).textTheme.bodySmall));
      }
      children.add(const SizedBox(height: 4));
      children.add(confirmed
          ? WmPill(label: t.cactOcConfirmed, icon: Icons.verified_rounded, color: wmOk())
          : Text(t.cactOcFromCamera, style: Theme.of(context).textTheme.bodySmall));
    }
    if (widget.owner) {
      children.add(const SizedBox(height: 8));
      children.add(Wrap(spacing: 8, runSpacing: 8, children: [
        if (!confirmed && open.isNotEmpty)
          FilledButton.tonalIcon(
            key: const ValueKey('cact-oc-ok'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.check_rounded),
            label: Text(t.cactOcOk),
            onPressed: () => _confirm(context, open, close.isEmpty ? null : close),
          ),
        OutlinedButton.icon(
          key: const ValueKey('cact-oc-change'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.edit_calendar_rounded),
          label: Text(t.cactOcChange),
          onPressed: () => _changeTimes(context, t, open, close),
        ),
      ]));
    }
    return _card(context, Icons.storefront_rounded, t.cactOcTitle, children);
  }

  TimeOfDay _tod(String hhmm, int fallbackH) {
    final p = hhmm.split(':');
    if (p.length == 2) {
      final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
      if (h != null && m != null) return TimeOfDay(hour: h, minute: m);
    }
    return TimeOfDay(hour: fallbackH, minute: 0);
  }

  String _fmt(TimeOfDay d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _changeTimes(BuildContext context, AppLocalizations t, String open, String close) async {
    final o = await showTimePicker(
        context: context, initialTime: _tod(open, 9), helpText: t.cactOcPickOpen);
    if (o == null || !context.mounted) return;
    final c = await showTimePicker(
        context: context, initialTime: _tod(close, 21), helpText: t.cactOcPickClose);
    if (!context.mounted) return;
    await _confirm(context, _fmt(o), c == null ? null : _fmt(c));
  }

  Future<void> _confirm(BuildContext context, String open, String? close) async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.of(context);
    try {
      await widget.source.confirm(widget.siteId, _ymd(_date), open: open, close: close);
      m.showSnackBar(SnackBar(content: Text(t.cactSaved)));
      await _load();
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmLoadErrorBody)));
    }
  }

  Widget _footfall(BuildContext context, AppLocalizations t, String lang) {
    final f = wmMap(_day['foot']);
    final rows = wmList(f['rows']);
    final src = (_day['foot_src'] ?? 'none').toString();
    if (src == 'none' && (f['sales'] ?? 0) == 0) {
      return Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: CvEmptyBlock(
            compact: true,
            icon: Icons.groups_rounded,
            title: t.cactFootEmptyTitle,
            benefit: t.cactFootEmptyBenefit,
            steps: [t.cactFootStep1, t.cactFootStep2, t.cactFootStep3],
          ),
        ),
      );
    }
    final conv = f['conversion'];
    var maxV = 1;
    for (final r in rows) {
      final v = (r['visitors'] as num? ?? 0).toInt();
      final s = (r['sales'] as num? ?? 0).toInt();
      if (v > maxV) maxV = v;
      if (s > maxV) maxV = s;
    }
    final peaks = (f['peak_hours'] as List?)?.map((e) => (e as num).toInt()).toList() ?? const <int>[];
    final cs = Theme.of(context).colorScheme;
    return _card(context, Icons.groups_rounded, t.cactFootTitle, [
      Text(t.cactFootTotals(wmDigits(lang, f['visitors'] ?? 0), wmDigits(lang, f['sales'] ?? 0),
          conv == null ? '—' : wmDigits(lang, '$conv%'))),
      if (peaks.isNotEmpty)
        Text(t.cactFootPeak(peaks.take(2).map((h) => _hourLabel(lang, h)).join(', '))),
      Text(src == 'line' ? t.cactFootSrcLine : t.cactFootSrcEstimate,
          style: Theme.of(context).textTheme.bodySmall),
      if ((f['sales'] ?? 0) == 0)
        Text(t.cactNoSales, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      Wrap(spacing: 12, children: [
        _legend(context, cs.primary, t.cactFootVisitors),
        _legend(context, cs.tertiary, t.cactFootSales),
      ]),
      const SizedBox(height: 6),
      for (final r in rows)
        Semantics(
          label: t.cactFootRow(_hourLabel(lang, (r['hour'] as num).toInt()),
              wmDigits(lang, r['visitors'] ?? 0), wmDigits(lang, r['sales'] ?? 0)),
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${_hourLabel(lang, (r['hour'] as num).toInt())}  ·  ${wmDigits(lang, r['visitors'] ?? 0)} / ${wmDigits(lang, r['sales'] ?? 0)}'
                  '${r['conversion'] == null ? '' : '  ·  ${wmDigits(lang, '${r['conversion']}%')}'}',
                  style: Theme.of(context).textTheme.bodySmall),
              _bar(context, ((r['visitors'] as num? ?? 0) / maxV).toDouble(), cs.primary),
              const SizedBox(height: 2),
              _bar(context, ((r['sales'] as num? ?? 0) / maxV).toDouble(), cs.tertiary),
            ]),
          ),
        ),
    ]);
  }

  Widget _legend(BuildContext context, Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);

  Widget _bar(BuildContext context, double frac, Color c) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 8,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(widthFactor: frac.clamp(0.0, 1.0), child: Container(color: c)),
        ),
      );

  Widget _watchman(BuildContext context, AppLocalizations t, String lang) {
    final wm = wmMap(_day['watchman']);
    final on = wm['on'] == true;
    if (!on) {
      return _card(context, Icons.nightlight_round, t.cactWmTitle, [
        Text(t.cactWmOffBody),
        if (widget.owner && _settings.isNotEmpty) ...[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const ValueKey('cact-wm-on'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.shield_moon_rounded),
            label: Text(t.cactWmTurnOn),
            onPressed: () => _openSettings(context),
          ),
        ],
      ]);
    }
    final tot = wmMap(wm['totals']);
    final hours = wmList(wm['hours']);
    return _card(context, Icons.nightlight_round, t.cactWmTitle, [
      Text(t.cactWmTotals(wmDigits(lang, tot['ok'] ?? 0), wmDigits(lang, tot['miss'] ?? 0),
          wmDigits(lang, tot['unknown'] ?? 0))),
      const SizedBox(height: 6),
      if (hours.isEmpty) Text(t.cactWmNoneYet, style: Theme.of(context).textTheme.bodySmall),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final h in hours)
          WmPill(
            label: '${_hourLabel(lang, (h['hour'] as num).toInt())} · ${switch (h['result']) {
              'ok' => t.cactWmOk,
              'miss' => t.cactWmMiss,
              _ => t.cactWmUnknown,
            }}',
            icon: switch (h['result']) {
              'ok' => Icons.check_circle_rounded,
              'miss' => Icons.error_rounded,
              _ => Icons.cloud_off_rounded,
            },
            color: switch (h['result']) {
              'ok' => wmOk(),
              'miss' => wmBad(),
              _ => wmWarn(),
            },
          ),
      ]),
    ]);
  }

  Widget _health(BuildContext context, AppLocalizations t, String lang) {
    final rows = wmList(_day['health']);
    if (rows.isEmpty) return const SizedBox.shrink();
    return _card(context, Icons.health_and_safety_rounded, t.cactHealthTitle, [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((r['name'] ?? '').toString(), style: Theme.of(context).textTheme.titleSmall),
            Wrap(spacing: 6, runSpacing: 6, children: [
              (r['offline_min'] as num? ?? 0) > 0
                  ? WmPill(
                      label: t.cactHealthOffline(wmDigits(lang, r['offline_min'])),
                      icon: Icons.wifi_off_rounded,
                      color: wmWarn())
                  : WmPill(label: t.cactHealthOn, icon: Icons.wifi_rounded, color: wmOk()),
              switch (r['sd']) {
                'ok' => WmPill(label: t.cactSdOk, icon: Icons.sd_card_rounded, color: wmOk()),
                'problem' => WmPill(label: t.cactSdProblem, icon: Icons.sd_card_alert_rounded, color: wmBad()),
                'none' => WmPill(label: t.cactSdNone, icon: Icons.sd_card_alert_rounded, color: wmWarn()),
                _ => WmPill(label: t.cactSdUnknown, icon: Icons.help_outline_rounded, color: wmWarn()),
              },
              WmPill(
                  label: (r['last_photo'] ?? '').toString().isEmpty
                      ? t.cactNoPhoto
                      : t.cactLastPhoto(wmDigits(lang, r['last_photo'])),
                  icon: Icons.photo_rounded,
                  color: Theme.of(context).colorScheme.primary),
            ]),
          ]),
        ),
    ]);
  }

  // ------------------------------------------------------------- settings
  Future<void> _openSettings(BuildContext context) async {
    final saved = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SettingsSheet(
          source: widget.source, siteId: widget.siteId, settings: _settings),
    );
    if (saved == true) await _load();
  }
}

class _SettingsSheet extends StatefulWidget {
  final ActivitySource source;
  final int siteId;
  final Map<String, dynamic> settings;
  const _SettingsSheet({required this.source, required this.siteId, required this.settings});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final Map<String, dynamic> _s = Map<String, dynamic>.of(widget.settings);
  bool _saving = false;

  List<int> _ids(String k) =>
      ((_s[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();

  Future<void> _pickTime(String key) async {
    final p = (_s[key] ?? '22:00').toString().split(':');
    final r = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: int.tryParse(p[0]) ?? 22, minute: int.tryParse(p.last) ?? 0));
    if (r != null) {
      setState(() => _s[key] =
          '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      await widget.source.saveSettings(widget.siteId, {
        for (final k in const [
          'brief_on', 'brief_hour', 'shop_cams', 'wm_on', 'wm_start', 'wm_end', 'wm_cams',
          'foot_dir', 'ai_desc'
        ])
          if (_s.containsKey(k)) k: _s[k],
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmLoadErrorBody)));
    }
  }

  Widget _cams(String key, List<Map<String, dynamic>> cams) {
    final t = AppLocalizations.of(context);
    final sel = _ids(key);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      FilterChip(
        label: Text(t.cactSetAllCams),
        selected: sel.isEmpty,
        onSelected: (_) => setState(() => _s[key] = <int>[]),
      ),
      for (final c in cams)
        FilterChip(
          label: Text((c['name'] ?? '').toString()),
          selected: sel.contains((c['id'] as num).toInt()),
          onSelected: (v) => setState(() {
            final id = (c['id'] as num).toInt();
            final n = List<int>.of(sel);
            v ? n.add(id) : n.remove(id);
            _s[key] = n;
          }),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final cams = wmList(_s['cameras']);
    final ai = wmMap(_s['ai']);
    final hour = (_s['brief_hour'] as num? ?? 8).toInt();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Text(t.cactSettings, style: Theme.of(context).textTheme.titleLarge),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cactSetBrief),
              subtitle: Text(t.cactSetBriefSub),
              value: _s['brief_on'] == true,
              onChanged: (v) => setState(() => _s['brief_on'] = v),
            ),
            if (_s['brief_on'] == true)
              Row(children: [
                Expanded(child: Text(t.cactSetBriefHour(wmDigits(lang, hour.toString().padLeft(2, '0'))))),
                IconButton(
                  tooltip: t.cactSetEarlier,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: hour > 0 ? () => setState(() => _s['brief_hour'] = hour - 1) : null,
                ),
                IconButton(
                  tooltip: t.cactSetLater,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: hour < 23 ? () => setState(() => _s['brief_hour'] = hour + 1) : null,
                ),
              ]),
            const Divider(),
            Text(t.cactSetShopCams, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _cams('shop_cams', cams),
            const Divider(),
            SwitchListTile(
              key: const ValueKey('cact-set-wm'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.cactWmTitle),
              subtitle: Text(t.cactWmOffBody),
              value: _s['wm_on'] == true,
              onChanged: (v) => setState(() => _s['wm_on'] = v),
            ),
            if (_s['wm_on'] == true) ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _pickTime('wm_start'),
                  child: Text(t.cactSetWmFrom(wmDigits(lang, _s['wm_start'] ?? '22:00'))),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _pickTime('wm_end'),
                  child: Text(t.cactSetWmTo(wmDigits(lang, _s['wm_end'] ?? '06:00'))),
                ),
              ]),
              const SizedBox(height: 6),
              Text(t.cactSetWmCams, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              _cams('wm_cams', cams),
            ],
            const Divider(),
            Text(t.cactSetDir, style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: (_s['foot_dir'] ?? 'both').toString(),
              onChanged: (v) => setState(() => _s['foot_dir'] = v ?? 'both'),
              child: Column(children: [
                for (final d in const ['both', 'a_to_b', 'b_to_a'])
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: d,
                    title: Text(switch (d) {
                      'a_to_b' => t.cactSetDirAb,
                      'b_to_a' => t.cactSetDirBa,
                      _ => t.cactSetDirBoth,
                    }),
                  ),
              ]),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.cactSetAi),
              subtitle: Text([
                if (ai['ready'] != true) t.cactSetAiNoKey,
                t.cactSetAiUsed(wmDigits(lang, ai['used'] ?? 0), wmDigits(lang, ai['cap'] ?? 0)),
                (ai['note'] ?? '').toString(),
              ].where((s) => s.isNotEmpty).join('\n')),
              value: _s['ai_desc'] != false,
              onChanged: (v) => setState(() => _s['ai_desc'] = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('cact-set-save'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.cactSetSave),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================ visitor log
class _VisitorLog extends StatefulWidget {
  final ActivitySource source;
  final int siteId;
  final String date;
  const _VisitorLog({super.key, required this.source, required this.siteId, required this.date});

  @override
  State<_VisitorLog> createState() => _VisitorLogState();
}

const _ranges = <String, (String?, String?)>{
  'all': (null, null),
  'morning': ('06:00', '12:00'),
  'afternoon': ('12:00', '17:00'),
  'evening': ('17:00', '22:00'),
  'night': ('22:00', '06:00'),
};

class _VisitorLogState extends State<_VisitorLog> with AutomaticKeepAliveClientMixin {
  final _q = TextEditingController();
  String _range = 'all';
  int _days = 1;
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = _ranges[_range]!;
    try {
      _data = await widget.source.visitors(widget.siteId,
          date: widget.date, days: _days, q: _q.text, from: r.$1, to: r.$2);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final rows = wmList(_data['rows']);
    final labels = {
      'all': t.cactVisAll,
      'morning': t.cactVisMorning,
      'afternoon': t.cactVisAfternoon,
      'evening': t.cactVisEvening,
      'night': t.cactVisNight,
    };
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: [
          TextField(
            key: const ValueKey('cact-vis-q'),
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: t.cactVisSearch,
              border: const OutlineInputBorder(),
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t.cactVisClear,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _q.clear();
                        _load();
                      }),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in _ranges.keys)
              ChoiceChip(
                label: Text(labels[k]!),
                selected: _range == k,
                onSelected: (_) {
                  setState(() => _range = k);
                  _load();
                },
              ),
            ChoiceChip(
              label: Text(t.cactVisDay),
              selected: _days == 1,
              onSelected: (_) {
                setState(() => _days = 1);
                _load();
              },
            ),
            ChoiceChip(
              label: Text(t.cactVisWeek),
              selected: _days == 7,
              onSelected: (_) {
                setState(() => _days = 7);
                _load();
              },
            ),
          ]),
          const SizedBox(height: 8),
          if ((_data['label'] ?? '').toString().isNotEmpty)
            Text(_data['label'].toString(), style: Theme.of(context).textTheme.bodySmall),
          if (_loading)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (_error != null) ...[
            const SizedBox(height: 24),
            Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Center(
                child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                    onPressed: _load,
                    child: Text(t.wmRetry))),
          ] else if (rows.isEmpty && _q.text.trim().isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(t.cactVisNoMatch(_q.text.trim()), textAlign: TextAlign.center),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () {
                  _q.clear();
                  _load();
                },
                child: Text(t.cactVisClear),
              ),
            ),
          ] else if (rows.isEmpty)
            CvEmptyBlock(
              icon: Icons.badge_rounded,
              title: t.cactVisEmptyTitle,
              benefit: t.cactVisEmptyBenefit,
              steps: [t.cactVisStep1, t.cactVisStep2, t.cactVisStep3],
            )
          else ...[
            for (final r in rows) _row(context, t, lang, r),
            if (_data['more'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(t.cactVisMore, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AppLocalizations t, String lang, Map<String, dynamic> r) {
    final snap = (r['snapshot_url'] ?? '').toString();
    final ai = r['desc_src'] == 'ai';
    final multiDay = _days > 1;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      clipBehavior: Clip.antiAlias,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 112,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: snap.isEmpty
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.no_photography_rounded))
                : Semantics(
                    label: t.wmSnapshotLabel,
                    image: true,
                    child: Image.network(snap,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image_rounded),
                            )),
                  ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  [
                    if (multiDay) wmDigits(lang, (r['date'] ?? '').toString()),
                    wmDigits(lang, (r['time'] ?? '').toString()),
                    (r['camera_name'] ?? '').toString(),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text((r['desc'] ?? '').toString()),
              const SizedBox(height: 4),
              WmPill(
                label: ai ? t.cactVisAi : t.cactVisTemplate,
                icon: ai ? Icons.auto_awesome_rounded : Icons.notes_rounded,
                color: ai ? Theme.of(context).colorScheme.primary : wmWarn(),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ================================================================ time-lapse
class _Timelapse extends StatefulWidget {
  final ActivitySource source;
  final int siteId;
  final DateTime date;
  const _Timelapse({super.key, required this.source, required this.siteId, required this.date});

  @override
  State<_Timelapse> createState() => _TimelapseState();
}

class _TimelapseState extends State<_Timelapse> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};
  bool _making = false;
  int _done = 0;
  Uint8List? _gif;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await widget.source.timelapse(widget.siteId, date: _ymd(widget.date));
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _make() async {
    final frames = spreadFrames(wmList(_data['frames']), kTlMaxFrames);
    setState(() {
      _making = true;
      _failed = false;
      _done = 0;
      _gif = null;
    });
    final bytes = <Uint8List>[];
    final labels = <String>[];
    for (final f in frames) {
      try {
        bytes.add(await widget.source.download(f['url'].toString()));
        labels.add((f['time'] ?? '').toString());
      } catch (_) {
        // an expired / missing photo is skipped — never replaced by a fake
      }
      if (mounted) setState(() => _done++);
    }
    Uint8List? gif;
    if (bytes.isNotEmpty) {
      try {
        gif = await compute(buildTimelapseGif, <String, Object>{'frames': bytes, 'labels': labels});
      } catch (_) {
        gif = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _making = false;
      _gif = gif;
      _failed = gif == null;
    });
  }

  Future<void> _share() async {
    final gif = _gif;
    if (gif == null) return;
    final t = AppLocalizations.of(context);
    final loc = MaterialLocalizations.of(context);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/assisto_timelapse_${_ymd(widget.date)}.gif');
    await f.writeAsBytes(gif);
    await Share.shareXFiles([XFile(f.path, mimeType: 'image/gif')],
        text: t.cactTlLabel(loc.formatMediumDate(widget.date)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final loc = MaterialLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(padding: const EdgeInsets.all(32), children: [
        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
            child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry))),
      ]);
    }
    final frames = wmList(_data['frames']);
    final n = frames.length > kTlMaxFrames ? kTlMaxFrames : frames.length;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
      children: [
        if (frames.isEmpty)
          CvEmptyBlock(
            icon: Icons.slow_motion_video_rounded,
            title: t.cactTlEmptyTitle,
            benefit: t.cactTlEmptyBenefit,
            steps: [t.cactTlStep1, t.cactTlStep2],
          )
        else ...[
          Text(t.cactTlTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(t.cactTlBody(wmDigits(lang, n))),
          Text(t.cactTlNote, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (_gif != null)
            Semantics(
              label: t.cactTlLabel(wmDigits(lang, loc.formatMediumDate(widget.date))),
              image: true,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                    aspectRatio: kTlWidth / kTlHeight,
                    child: Image.memory(_gif!, fit: BoxFit.contain, gaplessPlayback: true)),
              ),
            ),
          if (_making) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(t.cactTlMaking(wmDigits(lang, _done), wmDigits(lang, n))),
          ],
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t.cactTlFailed, style: TextStyle(color: wmBad())),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              key: const ValueKey('cact-tl-make'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.movie_creation_rounded),
              label: Text(t.cactTlMake),
              onPressed: _making ? null : _make,
            ),
            if (_gif != null)
              OutlinedButton.icon(
                key: const ValueKey('cact-tl-share'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.share_rounded),
                label: Text(t.cactTlShare),
                onPressed: _share,
              ),
          ]),
        ],
      ],
    );
  }
}
