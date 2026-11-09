import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'fc_ask_parser.dart' show fcBn;
import 'fc_brain_api.dart';
import 'fc_night_news_card.dart' show fcClockLabel;
import 'fc_watch.dart';

/// fcbrain — "Family privacy & alerts": the member's OWN controls for
/// Family Care v3 BRAIN 2-7, on their own phone.
///
///  * Tell my family when I arrive (on-phone geofences; prominent disclosure
///    before Android's permission box; a notification while on; off any time)
///  * Pause sharing 1 / 2 / 8 h ("Paused" to the family, never a fake place;
///    SOS still works)
///  * Night news: on / off, time, voice, what about ME goes in
///  * Who can see me (+ the monthly reminder is acknowledged here)
///  * Notification budget today (max 3 non-safety; safety always)
///  * Assisto's own battery use today (this phone's counters) + how to read
///    the real % in Android Settings
///  * Leave this family (any time)
class FcBrainSettingsScreen extends StatefulWidget {
  const FcBrainSettingsScreen({super.key, required this.api, this.familyId, this.debugData});
  final ApiClient api;
  final int? familyId;

  /// Gallery / tests: {prefs:{..}, visibility:{..}, counters:{..}} (no network).
  final Map<String, dynamic>? debugData;

  @override
  State<FcBrainSettingsScreen> createState() => _FcBrainSettingsScreenState();
}

class _FcBrainSettingsScreenState extends State<FcBrainSettingsScreen> {
  Map<String, dynamic>? _me;
  Map<String, dynamic>? _vis;
  Map<String, dynamic> _counters = const {};
  bool _running = false;
  bool _busy = false;
  String? _error;

  bool get _debug => widget.debugData != null;

  @override
  void initState() {
    super.initState();
    if (_debug) {
      _me = (widget.debugData!['prefs'] as Map?)?.cast<String, dynamic>();
      _vis = (widget.debugData!['visibility'] as Map?)?.cast<String, dynamic>();
      _counters = (widget.debugData!['counters'] as Map?)?.cast<String, dynamic>() ?? const {};
      _running = widget.debugData!['running'] == true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([widget.api.fcbPrefs(), widget.api.fcbVisibility()]);
      final c = await FcWatch.counters();
      final run = await FcWatch.running();
      if (!mounted) return;
      setState(() {
        _me = r[0];
        _vis = r[1];
        _counters = c;
        _running = run;
        _error = null;
      });
      if (_vis?['reminder_due'] == true) unawaited(widget.api.fcbVisibilitySeen());
    } catch (_) {
      if (mounted) setState(() => _error = 'load');
    }
  }

  Map<String, dynamic> get _prefs => (_me?['prefs'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _night => (_prefs['night'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// Gallery / tests: apply a change on the screen only (no server).
  void _localMerge(Map<String, dynamic> body) {
    final me = Map<String, dynamic>.from(_me ?? const {});
    final p = Map<String, dynamic>.from((me['prefs'] as Map?) ?? const {});
    body.forEach((k, v) {
      if (k == 'night' && v is Map) {
        p['night'] = {...((p['night'] as Map?) ?? const {}), ...v};
      } else {
        p[k] = v;
      }
    });
    me['prefs'] = p;
    setState(() => _me = me);
  }

  Future<void> _save(Map<String, dynamic> body) async {
    if (_debug) {
      _localMerge(body);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await widget.api.fcbSetPrefs(body);
      if (mounted) setState(() => _me = r);
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).fcbSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _toggleArrive(bool on) async {
    final t = AppLocalizations.of(context);
    if (!on) {
      if (_debug) {
      _localMerge({'auto_arrive': false});
      return;
    }
      setState(() => _busy = true);
      await FcWatch.disable(widget.api);
      await _load();
      if (mounted) setState(() => _busy = false);
      return;
    }
    // Play "prominent disclosure": our own words BEFORE Android's box
    final yes = await showAppSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: withNavBarInset(c, const EdgeInsets.all(Gap.lg)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.fcbDiscloseTitle, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            Text(t.fcbDiscloseBody),
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(t.fcbNotNow),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.pop(c, true),
                  child: Text(t.fcbDiscloseYes),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    if (_debug) {
      _localMerge({'auto_arrive': true});
      return;
    }
    setState(() => _busy = true);
    final r = await FcWatch.enable(
        widget.api, FcWatch.texts(title: t.fcbWatchNotifTitle, body: t.fcbWatchNotifBody));
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == 'no_permission') _snack(t.fcbNeedLocation);
    if (r == 'no_places') _snack(t.fcbNeedPlaces);
    if (r == 'error') _snack(t.fcbSaveFailed);
    await _load();
  }

  Future<void> _pause(int h) async {
    if (_debug) {
      setState(() => _me = {
            ...?_me,
            'paused_until': DateTime.now().add(Duration(hours: h)).toUtc().toIso8601String(),
          });
      return;
    }
    try {
      final r = await widget.api.fcbPause(h);
      if (mounted) setState(() => _me = r);
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).fcbSaveFailed);
    }
  }

  Future<void> _resume() async {
    if (_debug) {
      setState(() => _me = {...?_me, 'paused_until': null});
      return;
    }
    try {
      final r = await widget.api.fcbResume();
      if (mounted) setState(() => _me = r);
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).fcbSaveFailed);
    }
  }

  Future<void> _pickTime() async {
    final cur = (_night['time'] ?? '21:30').toString().split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(cur.first) ?? 21, minute: int.tryParse(cur.last) ?? 30),
    );
    if (picked == null) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    await _save({'night': {'time': '$hh:$mm'}});
  }

  Future<void> _leave() async {
    final t = AppLocalizations.of(context);
    final fid = widget.familyId;
    if (fid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.fcbLeaveTitle),
        content: Text(t.fcbLeaveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.fcbNotNow)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.fcbLeaveYes)),
        ],
      ),
    );
    if (ok != true) return;
    if (_debug) {
      if (mounted) Navigator.of(context).maybePop(true);
      return;
    }
    try {
      await widget.api.fcbLeave(fid);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) _snack(t.fcbSaveFailed);
    }
  }

  String _n(BuildContext c, Object v) =>
      Localizations.localeOf(c).languageCode == 'bn' ? fcBn(v) : '$v';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(t.fcbSettingsTitle)),
      body: _me == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(t)
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.only(bottom: Gap.xl)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
                      child: Text(t.fcbSettingsIntro, style: Theme.of(context).textTheme.bodyMedium),
                    ),
                    _arriveSection(t),
                    const Divider(),
                    _pauseSection(t, lang),
                    const Divider(),
                    _nightSection(t, lang),
                    const Divider(),
                    _whoSection(t),
                    const Divider(),
                    _budgetSection(t),
                    const Divider(),
                    _batterySection(t),
                    if (widget.familyId != null) ...[
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: Text(t.fcbLeaveTitle),
                        subtitle: Text(t.fcbLeaveHint),
                        onTap: _leave,
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _errorView(AppLocalizations t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.fcbLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                setState(() => _error = null);
                _load();
              },
              child: Text(t.fcbRetry),
            ),
          ]),
        ),
      );

  Widget _head(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
        child: Text(s, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _arriveSection(AppLocalizations t) {
    final on = _prefs['auto_arrive'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbArriveHead),
      SwitchListTile(
        value: on,
        onChanged: _busy ? null : _toggleArrive,
        title: Text(t.fcbArriveSwitch),
        subtitle: Text(!on
            ? t.fcbArriveHow
            : _running
                ? t.fcbArriveRunning
                : _me?['watch_mode'] == 'foreground'
                    ? t.fcbArriveForeground
                    : t.fcbArriveNotRunning),
      ),
      if (on)
        SwitchListTile(
          value: _prefs['leave_news'] == true,
          onChanged: _busy ? null : (v) => _save({'leave_news': v}),
          title: Text(t.fcbLeaveNews),
        ),
    ]);
  }

  Widget _pauseSection(AppLocalizations t, String lang) {
    final until = DateTime.tryParse((_me?['paused_until'] ?? '').toString())?.toLocal();
    final paused = until != null && until.isAfter(DateTime.now());
    final hours = ((_me?['pause_hours'] as List?) ?? const [1, 2, 8]).map((e) => (e as num).toInt());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbPauseHead),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Text(paused
            ? t.fcbPausedUntil(fcClockLabel(
                '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}', lang))
            : t.fcbPauseHint),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
        child: paused
            ? FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _resume,
                icon: const Icon(Icons.play_arrow),
                label: Text(t.fcbResume),
              )
            : Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final h in hours)
                  ActionChip(
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    avatar: const Icon(Icons.pause, size: 18),
                    label: Text(t.fcbPauseHours(_n(context, h))),
                    onPressed: () => _pause(h),
                  ),
              ]),
      ),
    ]);
  }

  Widget _nightSection(AppLocalizations t, String lang) {
    final on = _night['on'] != false;
    final items = ((_night['items'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final all = ((_me?['night_items'] as List?) ?? const ['place', 'arrivals', 'battery', 'carecall', 'tasks'])
        .map((e) => e.toString());
    String label(String k) => switch (k) {
          'place' => t.fcbItemPlace,
          'arrivals' => t.fcbItemArrivals,
          'battery' => t.fcbItemBattery,
          'carecall' => t.fcbItemCarecall,
          _ => t.fcbItemTasks,
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbNightTitle),
      SwitchListTile(
        value: on,
        onChanged: _busy ? null : (v) => _save({'night': {'on': v}}),
        title: Text(t.fcbNightSwitch),
        subtitle: Text(t.fcbNightHow),
      ),
      if (on) ...[
        ListTile(
          leading: const Icon(Icons.schedule),
          title: Text(t.fcbNightTime),
          trailing: Text(fcClockLabel((_night['time'] ?? '21:30').toString(), lang)),
          onTap: _pickTime,
        ),
        SwitchListTile(
          value: _night['voice'] == true,
          onChanged: _busy ? null : (v) => _save({'night': {'voice': v}}),
          title: Text(t.fcbNightVoice),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Text(t.fcbNightAboutMe, style: Theme.of(context).textTheme.bodyMedium),
        ),
        for (final k in all)
          CheckboxListTile(
            value: items.contains(k),
            onChanged: _busy
                ? null
                : (v) {
                    final next = {...items};
                    v == true ? next.add(k) : next.remove(k);
                    _save({'night': {'items': next.toList()}});
                  },
            title: Text(label(k)),
          ),
      ],
    ]);
  }

  Widget _whoSection(AppLocalizations t) {
    final people = ((_vis?['people'] as List?) ?? const []).whereType<Map>().toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbWhoHead),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Text(people.isEmpty ? t.fcbWhoNobody : t.fcbWhoCount(_n(context, people.length))),
      ),
      for (final p in people)
        ListTile(
          leading: const Icon(Icons.visibility_outlined),
          title: Text((p['name'] ?? '').toString()),
          subtitle: ((p['families'] as List?) ?? const []).isEmpty
              ? null
              : Text(((p['families'] as List)).join(', ')),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
        child: Text(t.fcbWhoAdminNever, style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
  }

  Widget _budgetSection(AppLocalizations t) {
    final b = (_me?['budget'] as Map?) ?? const {};
    final used = (b['used'] as num?)?.toInt() ?? 0;
    final limit = (b['limit'] as num?)?.toInt() ?? 3;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbBudgetHead),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Text(t.fcbBudgetBody(_n(context, limit), _n(context, used))),
      ),
    ]);
  }

  Widget _batterySection(AppLocalizations t) {
    final c = _counters;
    final gps = (c['gps'] as num?)?.toInt() ?? 0;
    final net = ((c['net'] as num?)?.toInt() ?? 0) + ((c['passive'] as num?)?.toInt() ?? 0);
    final pings = (c['pings'] as num?)?.toInt() ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head(t.fcbBatteryHead),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Text(c.isEmpty
            ? t.fcbBatteryNone
            : t.fcbBatteryToday(_n(context, gps), _n(context, net), _n(context, pings))),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Text(t.fcbBatteryHow, style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
  }
}
