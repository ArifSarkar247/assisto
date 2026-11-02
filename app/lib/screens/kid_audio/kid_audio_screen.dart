import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../kid_audio_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../messenger/messenger_home_screen.dart';

/// kidaudio (owner 2 Nov PART 1 b) — Child emergency audio: the advance
/// consent (parent sets it, the child agrees on their own phone), the
/// emergency "Listen now" / "Call the watch" buttons, and the log BOTH sides
/// see. Every rule is on the server (backend/core/kid_audio.py); this screen
/// only explains it in plain words and shows the honest reason when refused.
class KidAudioScreen extends StatefulWidget {
  const KidAudioScreen({super.key, this.dial});

  /// Test seam: how the parent's phone dials the watch.
  final Future<void> Function(String number)? dial;

  @override
  State<KidAudioScreen> createState() => _KidAudioScreenState();
}

/// Server reason code -> one honest sentence.
String kauReason(AppLocalizations t, String? r) {
  switch (r) {
    case 'no_emergency':
      return t.kauRNoEmergency;
    case 'adult':
      return t.kauRAdult;
    case 'not_guardian':
      return t.kauRNotGuardian;
    case 'no_consent':
      return t.kauRNoConsent;
    case 'session_cap':
      return t.kauRCap;
    case 'busy':
      return t.kauRBusy;
    case 'no_watch':
      return t.kauRNoWatch;
    case 'flag_off':
      return t.kauRFlag;
    case 'year_mismatch':
      return t.kauRYear;
    case 'time_limit':
      return t.kauEndLimit;
    case 'stopped':
      return t.kauEndStopped;
    case 'emergency_over':
      return t.kauEndOver;
    case 'notice_failed':
    case 'notice_required':
      return t.kauEndNotice;
    case 'call_ended':
      return t.kauEndCall;
    case 'revoked':
      return t.kauStateRevoked;
    case 'not_started':
      return t.kauEndNotStarted;
  }
  return t.kauRGeneric;
}

String kauStatus(AppLocalizations t, String? s) {
  switch (s) {
    case 'refused':
      return t.kauStRefused;
    case 'requested':
      return t.kauStRequested;
    case 'live':
      return t.kauStLive;
    case 'ended':
      return t.kauStEnded;
    case 'missed':
      return t.kauStMissed;
    case 'dialled':
      return t.kauStDialled;
  }
  return s ?? '';
}

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String key) => [
      for (final x in (r[key] is List ? r[key] as List : const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];

class _KidAudioScreenState extends State<KidAudioScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  Map<String, dynamic> _cfg = const {};
  List<Map<String, dynamic>> _log = const [];

  // parent set-up form
  int? _childId;
  int? _year;
  int? _watchId;
  final _watchPhone = TextEditingController();
  // child confirmation (per consent id)
  final Map<int, int> _confirmYear = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _watchPhone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final c = await _api.kauConfig();
      final l = await _api.kauLog();
      if (!mounted) return;
      setState(() {
        _cfg = c;
        _log = _rows(l, 'sessions');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  String _d(String s) => notifLocalizeDigits(context, s);

  List<Map<String, dynamic>> _consents(String role) =>
      _rows(_cfg, 'consents').where((c) => c['role'] == role).toList();

  Future<void> _act(Future<Map<String, dynamic>> Function() call,
      {String? okText, void Function(Map<String, dynamic> r)? onOk}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await call();
      if (!mounted) return;
      if (r['ok'] == true) {
        onOk?.call(r);
        if (okText != null) _snack(okText);
      } else {
        _snack(kauReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (mounted) _snack(t.kauRGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _saveSetup() async {
    final t = AppLocalizations.of(context);
    if (_childId == null || _year == null) {
      _snack(t.kauPickChildYear);
      return;
    }
    await _act(() => _api.kauSetConsent({
          'child_id': _childId,
          'birth_year': _year,
          if (_watchId != null) 'watch_id': _watchId,
          if (_watchId != null) 'watch_phone': _watchPhone.text.trim(),
        }), okText: t.kauSaved);
  }

  Future<void> _listen(Map<String, dynamic> c, String channel) async {
    final t = AppLocalizations.of(context);
    await _act(() => _api.kauListen(c['id'] as int, channel), onOk: (r) {
      final dial = '${r['dial'] ?? ''}';
      if (channel == 'watch' && dial.isNotEmpty) {
        final d = widget.dial ??
            (n) async {
              await launchUrl(Uri(scheme: 'tel', path: n));
            };
        unawaited(d(dial));
      } else {
        _snack(t.kauListenSent('${c['other_name'] ?? ''}'));
      }
    });
  }

  String _stateText(AppLocalizations t, Map<String, dynamic> c) {
    if (c['minor'] != true) return t.kauStateAdult;
    if (c['revoked_at'] != null) return t.kauStateRevoked;
    if (c['active'] == true) return t.kauStateActive;
    return t.kauStateWaiting;
  }

  List<int> get _years {
    final now = DateTime.now().year;
    return [for (var y = now - 1; y >= now - 17; y--) y];
  }

  Widget _big(String label, VoidCallback? onPressed, {Key? key, IconData? icon, bool outlined = false}) {
    final child = Text(label, textAlign: TextAlign.center);
    final b = outlined
        ? OutlinedButton.icon(key: key, onPressed: onPressed, icon: Icon(icon ?? Icons.check_rounded), label: child)
        : FilledButton.icon(key: key, onPressed: onPressed, icon: Icon(icon ?? Icons.check_rounded), label: child);
    return ConstrainedBox(constraints: const BoxConstraints(minHeight: 52, minWidth: double.infinity), child: b);
  }

  Widget _yearPicker(Key key, int? value, ValueChanged<int?> onChanged, String label) =>
      DropdownButtonFormField<int>(
        key: key,
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [for (final y in _years) DropdownMenuItem(value: y, child: Text(_d('$y')))],
        onChanged: onChanged,
      );

  Widget _parentCard(AppLocalizations t, Map<String, dynamic> c) {
    final active = c['active'] == true;
    return Card(
      key: ValueKey('kau-parent-${c['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${c['other_name'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(_stateText(t, c)),
          const SizedBox(height: Gap.sm),
          if (active) ...[
            _big(t.kauListen, _busy ? null : () => _listen(c, 'phone'),
                key: ValueKey('kau-listen-${c['id']}'), icon: Icons.hearing_rounded),
            if (c['has_watch_phone'] == true) ...[
              const SizedBox(height: Gap.sm),
              _big(t.kauCallWatch, _busy ? null : () => _listen(c, 'watch'),
                  key: ValueKey('kau-watch-${c['id']}'), icon: Icons.watch_rounded, outlined: true),
            ],
            const SizedBox(height: Gap.xs),
            Text(t.kauListenHelp, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (c['revoked_at'] == null)
            TextButton(
              key: ValueKey('kau-off-${c['id']}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => _act(() => _api.kauRevoke(c['id'] as int), okText: t.kauStateRevoked),
              child: Text(t.kauTurnOff),
            ),
        ]),
      ),
    );
  }

  Widget _childCard(AppLocalizations t, Map<String, dynamic> c) {
    final id = c['id'] as int;
    final asked = c['child_ok_at'] == null && c['revoked_at'] == null && c['parent_ok_at'] != null;
    return Card(
      key: ValueKey('kau-child-$id'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.kauAskTitle('${c['other_name'] ?? ''}'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          if (asked) ...[
            Text(t.kauAskBody),
            const SizedBox(height: Gap.sm),
            _yearPicker(ValueKey('kau-confirm-year-$id'), _confirmYear[id],
                (v) => setState(() {
                  if (v == null) {
                    _confirmYear.remove(id);
                  } else {
                    _confirmYear[id] = v;
                  }
                }),
                t.kauConfirmYear),
            const SizedBox(height: Gap.sm),
            _big(t.kauAgree, _busy || _confirmYear[id] == null
                    ? null
                    : () => _act(() => _api.kauAgree(id, _confirmYear[id]!), okText: t.kauStateActive),
                key: ValueKey('kau-agree-$id')),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => _act(() => _api.kauRevoke(id), okText: t.kauStateRevoked),
              child: Text(t.kauDecline),
            ),
          ] else ...[
            Text(_stateText(t, c)),
            if (c['revoked_at'] == null)
              TextButton(
                key: ValueKey('kau-child-off-$id'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : () => _act(() => _api.kauRevoke(id), okText: t.kauStateRevoked),
                child: Text(t.kauTurnOff),
              ),
          ],
        ]),
      ),
    );
  }

  Widget _setup(AppLocalizations t) {
    final kids = _rows(_cfg, 'children');
    final watches = _rows(_cfg, 'watches').where((w) => w['child_user_id'] == _childId).toList();
    if (kids.isEmpty) {
      return Card(
        key: const ValueKey('kau-empty'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.kauEmptyBenefit, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.sm),
            _big(t.kauOpenCircle, () => Navigator.push(context,
                    MaterialPageRoute<void>(builder: (_) => const MessengerHomeScreen())),
                key: const ValueKey('kau-open-circle'), icon: Icons.group_add_rounded),
            const SizedBox(height: Gap.sm),
            Text(t.kauEmptyHow, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.kauSetupTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final k in kids)
              ChoiceChip(
                key: ValueKey('kau-kid-${k['id']}'),
                label: Text('${k['name'] ?? ''}'),
                selected: _childId == k['id'],
                onSelected: (_) => setState(() {
                  _childId = k['id'] as int?;
                  _watchId = null;
                }),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          _yearPicker(const ValueKey('kau-year'), _year, (v) => setState(() => _year = v), t.kauBirthYear),
          if (watches.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            DropdownButtonFormField<int?>(
              key: const ValueKey('kau-watch'),
              initialValue: _watchId,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.kauWatch, border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem<int?>(value: null, child: Text(t.kauWatchNone)),
                for (final w in watches)
                  DropdownMenuItem<int?>(value: w['id'] as int?, child: Text('${w['child_name'] ?? ''}')),
              ],
              onChanged: (v) => setState(() => _watchId = v),
            ),
            if (_watchId != null) ...[
              const SizedBox(height: Gap.sm),
              TextField(
                key: const ValueKey('kau-watch-phone'),
                controller: _watchPhone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: t.kauWatchPhone, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.kauWatchPhoneHelp, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
          const SizedBox(height: Gap.md),
          _big(t.kauSave, _busy ? null : _saveSetup, key: const ValueKey('kau-save')),
        ]),
      ),
    );
  }

  Widget _logList(AppLocalizations t) {
    if (_log.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(t.kauLogEmpty, key: const ValueKey('kau-log-empty')),
      );
    }
    return Column(children: [
      for (final s in _log)
        ListTile(
          key: ValueKey('kau-log-${s['id']}'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(s['channel'] == 'watch' ? Icons.watch_rounded : Icons.hearing_rounded),
          title: Text(s['role'] == 'guardian'
              ? '${s['child_name'] ?? ''}'
              : t.kauLogBy('${s['guardian_name'] ?? ''}')),
          subtitle: Text([
            kauStatus(t, s['status'] as String?),
            _when('${s['requested_at'] ?? ''}'),
            if (s['seconds'] is int) t.kauSeconds(_d('${s['seconds']}')),
            if ('${s['reason'] ?? ''}'.isNotEmpty) kauReason(t, s['reason'] as String?),
          ].where((x) => x.isNotEmpty).join(' · ')),
        ),
    ]);
  }

  String _when(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return _d('${d.day}/${d.month} ${two(d.hour)}:${two(d.minute)}');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final mine = _consents('guardian');
    final asks = _consents('child');
    return Scaffold(
      appBar: AppBar(title: Text(t.kauTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(
                  child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(t.kauLoadFailed, textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    FilledButton(onPressed: _load, child: Text(t.kauRetry)),
                  ]),
                ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                    children: [
                      Text(t.kauIntro, style: text.bodyMedium),
                      const SizedBox(height: Gap.md),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.md),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Text(t.kauRulesTitle, style: text.titleSmall),
                            const SizedBox(height: Gap.xs),
                            Text(t.kauRules, key: const ValueKey('kau-rules')),
                          ]),
                        ),
                      ),
                      if (asks.isNotEmpty) ...[
                        const SizedBox(height: Gap.lg),
                        Text(t.kauChildSection, style: text.titleMedium),
                        for (final c in asks) _childCard(t, c),
                      ],
                      if (_cfg['enabled'] == true) ...[
                        const SizedBox(height: Gap.lg),
                        Text(t.kauParentSection, style: text.titleMedium),
                        for (final c in mine) _parentCard(t, c),
                        const SizedBox(height: Gap.sm),
                        _setup(t),
                      ],
                      const SizedBox(height: Gap.lg),
                      Text(t.kauLogTitle, style: text.titleMedium),
                      _logList(t),
                    ],
                  ),
                ),
    );
  }
}
