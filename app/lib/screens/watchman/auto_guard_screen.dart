import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../cctvx/auto_guard_source.dart';
import '../../cctvx/home_presence_sync.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../shop_live_screen.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvarm (owner CCTV order 3 Nov, W5) — AUTO GUARD for one place.
///
/// Owner: guard on when everyone who agreed has left Home, indoor privacy
/// when someone is back, guard on when the shop is closed, "no movement by
/// a set time" per camera, and SOS-at-home live for the family. Every
/// automatic change is listed (and pushed to the owner by the server).
/// Family member: their OWN yes / no for using whether they are at home.
/// Nothing is guessed: a stale phone shows "Not known".
class AutoGuardScreen extends StatefulWidget {
  final AutoGuardSource? source;
  final int siteId;
  final bool owner;

  /// Asked once when a member says yes (tests inject a no-op).
  final Future<void> Function()? onConsentYes;
  const AutoGuardScreen(
      {super.key, this.source, required this.siteId, this.owner = true, this.onConsentYes});

  @override
  State<AutoGuardScreen> createState() => _AutoGuardScreenState();
}

class _AutoGuardScreenState extends State<AutoGuardScreen> {
  AutoGuardSource? _src;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, dynamic> _d = const {};
  Map<String, dynamic>? _mine; // member view: my row for this place

  @override
  void initState() {
    super.initState();
    _src = widget.source;
    if (_src == null) {
      try {
        _src = ApiAutoGuardSource(context.read<AppState>().api);
      } catch (_) {}
    }
    _load();
  }

  Future<void> _load() async {
    final src = _src;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (src == null) {
      setState(() {
        _loading = false;
        _error = '';
      });
      return;
    }
    try {
      if (widget.owner) {
        _d = await src.load(widget.siteId);
      } else {
        final m = await src.mine();
        _mine = wmList(m['sites']).where((s) => s['site'] == widget.siteId).firstOrNull;
      }
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final d = await _src!.save(widget.siteId, body);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _consent(bool yes) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await _src!.consent(widget.siteId, yes);
      if (yes) {
        final hook = widget.onConsentYes ?? _askLocationAndSync;
        unawaited(hook());
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text((r['message'] ?? t.carmSaved).toString())));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  /// The ONE place the location permission is asked: right after "Yes".
  Future<void> _askLocationAndSync() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
        await HomePresenceSync.maybeSend(null, source: _src, force: true);
      }
    } catch (_) {}
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
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: widget.owner ? _ownerCards(t) : _memberCards(t),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.carmTitle)),
      body: AbsorbPointer(absorbing: _busy, child: body),
    );
  }

  // ------------------------------------------------------------ member
  List<Widget> _memberCards(AppLocalizations t) {
    final lang = wmLang(context);
    final m = _mine;
    if (m == null) {
      return [
        CvEmptyBlock(
          icon: Icons.home_work_outlined,
          title: t.carmNotAskedTitle,
          benefit: t.carmNotAskedBody,
        ),
      ];
    }
    final yes = m['consent'] == true;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.carmAskTitle((m['owner_name'] ?? '').toString()),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t.carmAskBody),
            const SizedBox(height: 8),
            Text(t.carmLimitNote, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (yes) ...[
              _statePill(t, (m['state'] ?? 'unknown').toString()),
              const SizedBox(height: 4),
              Text(t.carmYouAgreed),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('carm-withdraw'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.location_off_outlined),
                label: Text(t.carmWithdraw),
                onPressed: () => _consent(false),
              ),
            ] else
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  key: const ValueKey('carm-yes'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t.carmYes),
                  onPressed: () => _consent(true),
                ),
                OutlinedButton(
                  key: const ValueKey('carm-no'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t.carmNo),
                ),
              ]),
            const SizedBox(height: 4),
            Text(t.carmStaleRule(wmDigits(lang, 30)), style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------- owner
  Map<String, dynamic> get _cfg => wmMap(_d['config']);
  Map<String, dynamic> get _st => wmMap(_d['status']);

  List<Widget> _ownerCards(AppLocalizations t) => [
        _statusCard(t),
        _familyCard(t),
        _closedCard(t),
        _nomoveCard(t),
        _sosCard(t),
        _logCard(t),
      ];

  Widget _statePill(AppLocalizations t, String s) => switch (s) {
        'home' => WmPill(label: t.carmStHome, icon: Icons.home_rounded, color: wmOk()),
        'away' => WmPill(label: t.carmStAway, icon: Icons.directions_walk_rounded, color: wmWarn()),
        'no_consent' =>
          WmPill(label: t.carmStNoConsent, icon: Icons.hourglass_empty_rounded, color: Colors.grey),
        _ => WmPill(label: t.carmStUnknown, icon: Icons.help_outline_rounded, color: Colors.grey),
      };

  Widget _statusCard(AppLocalizations t) {
    final on = _st['auto_armed'] == true;
    final reason = (_st['reason'] ?? '').toString();
    final summary = (_st['summary'] ?? 'off').toString();
    final privacy = _st['privacy'] == true;
    final sos = _st['sos_until'] != null;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('carm-status'),
      color: on ? scheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(on ? Icons.shield_rounded : Icons.shield_outlined,
                color: on ? scheme.onPrimaryContainer : null),
            const SizedBox(width: 8),
            Expanded(
                child: Text(on ? t.carmStatusOn : t.carmStatusOff,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: on ? scheme.onPrimaryContainer : null))),
          ]),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(reason == 'family_away' ? t.carmReasonFamily : t.carmReasonClosed,
                style: TextStyle(color: on ? scheme.onPrimaryContainer : null)),
          ],
          if (_cfg['family_on'] == true) ...[
            const SizedBox(height: 4),
            Text(switch (summary) {
              'someone_home' => t.carmSumHome,
              'all_away' => t.carmSumAway,
              'unknown' => t.carmSumUnknown,
              _ => t.carmSumOff,
            }, style: TextStyle(color: on ? scheme.onPrimaryContainer : null)),
          ],
          if (privacy) ...[
            const SizedBox(height: 8),
            Text(t.carmPrivacyActive),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.videocam_outlined),
              label: Text(t.carmPrivacyPause),
              onPressed: () => _save({'privacy_pause': true}),
            ),
          ],
          if (sos) ...[
            const SizedBox(height: 8),
            Text(t.carmSosActive, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }

  Widget _switchTile(String key, String title, String body, bool value, ValueChanged<bool> on) =>
      SwitchListTile(
        key: ValueKey(key),
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(body),
        value: value,
        onChanged: on,
      );

  Widget _familyCard(AppLocalizations t) {
    final lang = wmLang(context);
    final on = _cfg['family_on'] == true;
    final home = wmMap(_cfg['home']);
    final places = wmList(_d['home_places']);
    final members = wmList(_d['members']);
    final cams = wmList(_d['cameras']);
    final radius = (_cfg['radius_m'] as num?)?.toInt() ?? 150;
    final exit = (_cfg['exit_m'] as num?)?.toInt() ?? radius + 150;
    final me = members.where((m) => m['is_me'] == true).firstOrNull;
    final others = members.where((m) => m['is_me'] != true).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _switchTile('carm-family', t.carmFamilyTitle, t.carmFamilyBenefit, on,
              (v) => _save({'family_on': v})),
          Text(t.carmFamilyRules(wmDigits(lang, 30)), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (places.isEmpty && home.isEmpty)
            Text(t.carmHomeMissing, style: TextStyle(color: wmBad()))
          else
            Text(t.carmHomeLabel((home['name'] ?? places.first['name'] ?? '').toString())),
          if (on) ...[
            const SizedBox(height: 8),
            Text(t.carmRadius(wmDigits(lang, radius), wmDigits(lang, exit))),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              for (final r in const [100, 150, 250])
                ChoiceChip(
                  label: Text(t.carmMeters(wmDigits(lang, r))),
                  selected: r == radius,
                  onSelected: (_) => _save({'radius_m': r}),
                ),
            ]),
            const Divider(height: 24),
            Text(t.carmMembers, style: Theme.of(context).textTheme.titleSmall),
            SwitchListTile(
              key: const ValueKey('carm-me'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.carmMyConsent),
              subtitle: me == null || me['consent'] != true
                  ? null
                  : Align(alignment: Alignment.centerLeft, child: _statePill(t, (me['state'] ?? '').toString())),
              value: me?['consent'] == true,
              onChanged: (v) async {
                await _save({'my_consent': v});
                if (v) unawaited((widget.onConsentYes ?? _askLocationAndSync)());
              },
            ),
            for (final m in others)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text((m['name'] ?? '').toString()),
                subtitle: Align(
                    alignment: Alignment.centerLeft,
                    child: _statePill(t, (m['state'] ?? '').toString())),
                trailing: IconButton(
                  tooltip: t.carmRemove,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => _save({
                    'remove': [m['uid']]
                  }),
                ),
              ),
            OutlinedButton.icon(
              key: const ValueKey('carm-add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.group_add_outlined),
              label: Text(t.carmAddPeople),
              onPressed: () => _pickPeople(t),
            ),
            const Divider(height: 24),
            _switchTile('carm-privacy', t.carmPrivacyTitle, t.carmPrivacyBody,
                _cfg['privacy_on'] == true, (v) => _save({'privacy_on': v})),
            if (_cfg['privacy_on'] == true) ...[
              Text(t.carmIndoorPick),
              const SizedBox(height: 4),
              if (cams.isEmpty)
                Text(t.carmNoCameras)
              else
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final c in cams)
                    FilterChip(
                      label: Text((c['name'] ?? '').toString()),
                      selected: c['indoor'] == true,
                      onSelected: (v) {
                        final ids = cams
                            .where((x) => x['id'] == c['id'] ? v : x['indoor'] == true)
                            .map((x) => x['id'])
                            .toList();
                        _save({'indoor': ids});
                      },
                    ),
                ]),
            ],
          ],
        ]),
      ),
    );
  }

  Future<void> _pickPeople(AppLocalizations t) async {
    final cands = wmList(_d['candidates']);
    final picked = await showAppSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: cands.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: CvEmptyBlock(
                  compact: true,
                  icon: Icons.group_outlined,
                  title: t.carmNoCandidatesTitle,
                  benefit: t.carmNoCandidatesBody,
                ),
              )
            : ListView(shrinkWrap: true, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(t.carmAddPeople, style: Theme.of(ctx).textTheme.titleMedium),
                ),
                for (final c in cands)
                  ListTile(
                    minTileHeight: 56,
                    leading: Icon(c['family'] == true
                        ? Icons.family_restroom_rounded
                        : Icons.person_outline_rounded),
                    title: Text((c['name'] ?? '').toString()),
                    onTap: () => Navigator.of(ctx).pop((c['uid'] as num).toInt()),
                  ),
              ]),
      ),
    );
    if (picked == null || !mounted) return;
    await _save({
      'invite': [picked]
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.carmInvited)));
    }
  }

  Widget _closedCard(AppLocalizations t) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _switchTile('carm-closed', t.carmClosedTitle, t.carmClosedBody, _cfg['closed_on'] == true,
                (v) => _save({'closed_on': v})),
            if (_cfg['closed_on'] == true && _d['hours_set'] != true)
              Text(t.carmHoursMissing, style: TextStyle(color: wmWarn())),
          ]),
        ),
      );

  String _hhmm(TimeOfDay v) =>
      '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';

  TimeOfDay _tod(String s, TimeOfDay d) {
    final p = s.split(':');
    if (p.length != 2) return d;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return h == null || m == null ? d : TimeOfDay(hour: h, minute: m);
  }

  Widget _nomoveCard(AppLocalizations t) {
    final lang = wmLang(context);
    final cams = wmList(_d['cameras']);
    final people = <int, String>{
      for (final m in wmList(_d['members']))
        if (m['is_me'] != true) (m['uid'] as num).toInt(): (m['name'] ?? '').toString(),
      for (final c in wmList(_d['candidates'])) (c['uid'] as num).toInt(): (c['name'] ?? '').toString(),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.carmNomoveTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(t.carmNomoveBody),
          if (cams.isEmpty) ...[const SizedBox(height: 8), Text(t.carmNoCameras)],
          for (final c in cams) ...[
            const Divider(height: 20),
            _nomoveRow(t, lang, c, people),
          ],
        ]),
      ),
    );
  }

  Widget _nomoveRow(AppLocalizations t, String lang, Map<String, dynamic> c, Map<int, String> people) {
    final nm = wmMap(c['nomove']);
    final id = (c['id'] as num).toInt();
    final on = nm['on'] == true;
    final from = (nm['from'] ?? '06:00').toString();
    final by = (nm['by'] ?? '10:00').toString();
    final chosen = (nm['people'] is List ? nm['people'] as List : const [])
        .map((x) => (x as num).toInt())
        .toSet();
    Map<String, dynamic> body(Map<String, dynamic> change) => {
          'nomove': {
            '$id': {'on': on, 'from': from, 'by': by, 'people': chosen.toList(), ...change}
          }
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        key: ValueKey('carm-nomove-$id'),
        contentPadding: EdgeInsets.zero,
        title: Text((c['name'] ?? '').toString()),
        subtitle: Text(c['online'] == true ? t.carmNomoveBy(wmDigits(lang, by)) : t.carmCamOffline),
        value: on,
        onChanged: (v) => _save(body({'on': v})),
      ),
      if (on) ...[
        Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.wb_twilight_rounded),
            label: Text(t.carmNomoveFrom(wmDigits(lang, from))),
            onPressed: () async {
              final v = await showTimePicker(
                  context: context, initialTime: _tod(from, const TimeOfDay(hour: 6, minute: 0)));
              if (v != null) await _save(body({'from': _hhmm(v)}));
            },
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.schedule_rounded),
            label: Text(t.carmNomoveBy(wmDigits(lang, by))),
            onPressed: () async {
              final v = await showTimePicker(
                  context: context, initialTime: _tod(by, const TimeOfDay(hour: 10, minute: 0)));
              if (v != null) await _save(body({'by': _hhmm(v)}));
            },
          ),
        ]),
        if (people.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(t.carmNomoveWho),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final e in people.entries)
              FilterChip(
                label: Text(e.value),
                selected: chosen.contains(e.key),
                onSelected: (v) {
                  final next = {...chosen};
                  v ? next.add(e.key) : next.remove(e.key);
                  _save(body({'people': next.toList()}));
                },
              ),
          ]),
        ],
      ],
    ]);
  }

  Widget _sosCard(AppLocalizations t) {
    final lang = wmLang(context);
    final min = (wmMap(_d['rules'])['sos_live_min'] as num?)?.toInt() ?? 30;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _switchTile('carm-sos', t.carmSosTitle, t.carmSosBody(wmDigits(lang, min)),
            _cfg['sos_live'] == true, (v) => _save({'sos_live': v})),
      ),
    );
  }

  Widget _logCard(AppLocalizations t) {
    final rows = wmList(_d['log']);
    final lang = wmLang(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.carmLogTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          if (rows.isEmpty) Text(t.carmLogEmpty),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${_when(lang, (r['at'] ?? '').toString())} · ${r['text'] ?? ''}'),
            ),
        ]),
      ),
    );
  }

  String _when(String lang, String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final s = '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return wmDigits(lang, s);
  }
}

/// cctvarm E9 — the home cameras an SOS opened for ME (a family member the
/// owner allows). Live is picture only; sound never starts by itself.
class SosLiveScreen extends StatefulWidget {
  final AutoGuardSource? source;
  const SosLiveScreen({super.key, this.source});

  @override
  State<SosLiveScreen> createState() => _SosLiveScreenState();
}

class _SosLiveScreenState extends State<SosLiveScreen> {
  AutoGuardSource? _src;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _grants = const [];

  @override
  void initState() {
    super.initState();
    _src = widget.source;
    if (_src == null) {
      try {
        _src = ApiAutoGuardSource(context.read<AppState>().api);
      } catch (_) {}
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _grants = wmList((await _src!.sosLive())['grants']);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
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
    } else if (_grants.isEmpty) {
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(16)), children: [
        CvEmptyBlock(
          icon: Icons.videocam_outlined,
          title: t.carmSosNoneTitle,
          benefit: t.carmSosNoneBody,
          primaryIcon: Icons.refresh_rounded,
          primaryLabel: t.wmRetry,
          onPrimary: _load,
          steps: [t.carmSosStep1, t.carmSosStep2],
        ),
      ]);
    } else {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: [
          for (final g in _grants)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.carmSosFrom((g['by_name'] ?? '').toString()),
                      style: Theme.of(context).textTheme.titleMedium),
                  Text((g['name'] ?? '').toString()),
                  const SizedBox(height: 4),
                  Text(t.carmCall999, style: TextStyle(color: wmBad(), fontWeight: FontWeight.w600)),
                  for (final c in wmList(g['cameras']))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.videocam_rounded),
                      title: Text((c['name'] ?? '').toString()),
                      subtitle: c['online'] != true
                          ? Text(t.carmCamOffline)
                          : (c['live'] != true ? Text(t.carmCamNoLive) : null),
                      trailing: FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: c['online'] == true && c['live'] == true
                            ? () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => ShopLiveScreen(
                                    cameraId: (c['id'] as num).toInt(),
                                    cameraName: (c['name'] ?? '').toString())))
                            : null,
                        child: Text(t.carmWatchLive),
                      ),
                    ),
                ]),
              ),
            ),
        ],
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.carmSosLiveTitle)), body: body);
  }
}
