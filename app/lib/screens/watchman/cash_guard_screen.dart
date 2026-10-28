import 'package:flutter/material.dart';

import '../../cashguard/cashguard_source.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import 'guard_box_screen.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// cashguard — SMART CASH GUARD for one place: owner-away mode ("I'm away"
/// for N hours, or every day from-to), the 2-minute setup checklist, what the
/// plan includes (server-enforced caps), how the clip is protected, and the
/// honest "hand-to-pocket: not measured" line. No ads on this screen.
class CashGuardScreen extends StatefulWidget {
  final CashGuardSource source;
  final int siteId;

  /// Open the zone editor of a camera (the cash zone is drawn there).
  final VoidCallback? onDrawZone;
  const CashGuardScreen({super.key, required this.source, required this.siteId, this.onDrawZone});

  @override
  State<CashGuardScreen> createState() => _CashGuardScreenState();
}

class _CashGuardScreenState extends State<CashGuardScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};
  bool _busy = false;
  bool _sched = false;
  TimeOfDay _from = const TimeOfDay(hour: 13, minute: 0);
  TimeOfDay _to = const TimeOfDay(hour: 15, minute: 0);

  static const _hours = [2, 4, 8, 12, 24];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> get _site => wmList(_data['sites'])
      .firstWhere((s) => (s['site'] as num?)?.toInt() == widget.siteId, orElse: () => const {});

  static TimeOfDay? _tod(Object? v) {
    final p = (v ?? '').toString().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return (h == null || m == null) ? null : TimeOfDay(hour: h, minute: m);
  }

  static String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await widget.source.overview();
      final s = wmMap(_site['schedule']);
      _sched = s.isNotEmpty;
      _from = _tod(s['start']) ?? _from;
      _to = _tod(s['end']) ?? _to;
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _away(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await widget.source.setAway(widget.siteId, body);
      final sites = wmList(_data['sites']);
      for (final s in sites) {
        if ((s['site'] as num?)?.toInt() == widget.siteId) s.addAll(r);
      }
      _data = {..._data, 'sites': sites};
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['active'] == true ? t.cgAwayOnSaved : t.cgAwayOffSaved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickHours() async {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final h = await showAppSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(t.cgAwayHowLong, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final n in _hours)
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.timer_outlined),
              title: Text(t.cgAwayHours(wmDigits(lang, n))),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ]),
      ),
    );
    if (h != null) await _away({'on': true, 'hours': h});
  }

  Future<void> _saveSchedule(bool on) async {
    setState(() => _sched = on);
    await _away({
      'schedule': on ? {'days': [0, 1, 2, 3, 4, 5, 6], 'start': _hhmm(_from), 'end': _hhmm(_to)} : null,
    });
  }

  Future<void> _time(bool from) async {
    final v = await showTimePicker(context: context, initialTime: from ? _from : _to);
    if (v == null) return;
    setState(() {
      if (from) {
        _from = v;
      } else {
        _to = v;
      }
    });
    if (_sched) await _saveSchedule(true);
  }

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
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          _awayCard(t),
          _setupCard(t),
          _planCard(t),
          _privacyCard(t),
          if (FeatureFlags.instance.isOn('guard_box_mode')) _guardBoxCard(t),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.cgTitle)), body: body);
  }

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );

  Widget _awayCard(AppLocalizations t) {
    final loc = MaterialLocalizations.of(context);
    final s = _site;
    final active = s['active'] == true;
    final until = DateTime.tryParse((s['until'] ?? '').toString())?.toLocal();
    final untilTxt = until == null
        ? ''
        : '${loc.formatShortDate(until)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(until))}';
    return _card([
      Row(children: [
        Icon(active ? Icons.directions_walk_rounded : Icons.storefront_rounded,
            color: active ? wmWarn() : null),
        const SizedBox(width: 8),
        Expanded(child: Text(t.cgAwayTitle, style: Theme.of(context).textTheme.titleMedium)),
      ]),
      const SizedBox(height: 6),
      Text(t.cgAwayBody),
      const SizedBox(height: 10),
      if (active) WmPill(label: untilTxt.isEmpty ? t.cgAwayActive : t.cgAwayUntil(untilTxt),
          icon: Icons.notifications_active_rounded, color: wmWarn()),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (!active || until != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.directions_walk_rounded),
            label: Text(t.cgImAway),
            onPressed: _busy ? null : _pickHours,
          ),
        if (until != null)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.home_rounded),
            label: Text(t.cgImBack),
            onPressed: _busy ? null : () => _away({'on': false}),
          ),
      ]),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.cgAwayEveryDay),
        subtitle: Text(t.cgAwayEveryDayBody),
        value: _sched,
        onChanged: _busy ? null : _saveSchedule,
      ),
      if (_sched)
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : () => _time(true),
            child: Text(t.wmFrom(loc.formatTimeOfDay(_from))),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : () => _time(false),
            child: Text(t.wmTo(loc.formatTimeOfDay(_to))),
          ),
        ]),
    ]);
  }

  Widget _setupCard(AppLocalizations t) {
    final s = _site;
    final keys = (s['clip_recipients'] as num?)?.toInt() ?? 0;
    Widget step(bool done, String text, {VoidCallback? onTap, String? action}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: done ? wmOk() : null),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
            if (onTap != null && action != null)
              TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onTap,
                  child: Text(action)),
          ]),
        );
    return _card([
      Text(t.cgSetupTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      step(false, t.cgSetupStepZone, onTap: widget.onDrawZone, action: t.cgDrawZone),
      step(true, t.cgSetupStepCamera),
      step(keys > 0, keys > 0 ? t.cgSetupStepKeyOk : t.cgSetupStepKeyMissing),
    ]);
  }

  Widget _planCard(AppLocalizations t) {
    final lang = wmLang(context);
    final caps = wmMap(_data['caps']);
    final use = wmMap(_data['usage']);
    String d(Object? v) => wmDigits(lang, (v as num?)?.toInt() ?? 0);
    final tier = (caps['tier'] ?? 'free').toString();
    return _card([
      Text(t.cgPlanTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      Text(switch (tier) {
        'business' => t.cgPlanBusiness,
        'premium' => t.cgPlanPremium,
        _ => t.cgPlanFree,
      }),
      const SizedBox(height: 6),
      Text(t.cgPlanCaps(d(caps['cameras']), d(caps['alerts_day']), d(caps['clips_day']))),
      Text(t.cgPlanUsed(d(use['cameras']), d(use['clips_today'])),
          style: Theme.of(context).textTheme.bodySmall),
      if (tier != 'business') ...[
        const SizedBox(height: 6),
        Text(t.cgPlanUpsell, style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
  }

  Widget _privacyCard(AppLocalizations t) {
    final h2p = wmMap(_data['hand_to_pocket']);
    return _card([
      Row(children: [
        const Icon(Icons.lock_rounded),
        const SizedBox(width: 8),
        Expanded(child: Text(t.cgPrivacyTitle, style: Theme.of(context).textTheme.titleMedium)),
      ]),
      const SizedBox(height: 6),
      Text(t.cgPrivacyBody),
      const SizedBox(height: 8),
      Text(t.cgNeverAccuse, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      Text(h2p['enabled'] == true ? t.cgHandPocketOn : t.cgHandPocketOff,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _guardBoxCard(AppLocalizations t) => _card([
        Text(t.gbTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(t.gbIntro),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.phone_android_rounded),
            label: Text(t.gbOpen),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const GuardBoxScreen())),
          ),
        ),
      ]);
}
