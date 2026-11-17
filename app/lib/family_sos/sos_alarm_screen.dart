import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../nearby/emergency_numbers.dart';
import '../push/lock_screen_guard.dart';
import '../push/push_notifier.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../train/dest_alarm_sound.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'sos_api.dart';
import 'sos_widgets.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// fcsos — Family Care v3 SCREEN 3: the SOS RECEIVER. Opens full screen from
/// the SOS push (also over the lock screen, for that one launch — the same
/// per-launch rule as calls and Care Call), keeps an alarm sounding on the
/// alarm stream until the person acts, and shows on ONE page: who, when,
/// where (live while the sender's SOS screen is open), the 30 s sound, who is
/// going, the nearest police + hospital from Assisto's own Nearby list,
/// optional emergency info (blood group, contacts — only if the sender shares
/// it) and the actions: I am going (red, main), Call, the country's
/// emergency number. Free, never an ad.
class SosAlarmScreen extends StatefulWidget {
  const SosAlarmScreen({
    super.key,
    required this.data,
    this.api,
    this.sound,
    this.openUri,
    this.pollEvery = const Duration(seconds: 5),
    this.autoAlarm = true,
  });

  /// The push payload (delivery_id, from_name, lat, lng, alert_kind, ...).
  final Map<String, String> data;
  final FcSosApi? api;
  final DestAlarmSound? sound;
  final Future<void> Function(Uri uri)? openUri;
  final Duration pollEvery;
  final bool autoAlarm;

  static const route = '/sos_alarm';

  /// Delivery ids whose alarm page is on screen (cold route + push tap).
  static final Set<int> open = {};

  static int deliveryOf(Map<String, String> d) => int.tryParse(d['delivery_id'] ?? '') ?? 0;

  /// An SOS / fall alarm push for this phone (not the all-clear etc.).
  static bool wants(Map<String, String> d) {
    if ((d['kind'] ?? '') != 'sos' || deliveryOf(d) <= 0) return false;
    final k = d['alert_kind'] ?? 'sos';
    return k == 'sos' || k == 'fall';
  }

  static Route<void> pageRoute(Map<String, String> data, {RouteSettings? settings}) =>
      MaterialPageRoute<void>(
          settings: settings ?? const RouteSettings(name: route),
          fullscreenDialog: true,
          builder: (_) => SosAlarmScreen(data: data));

  /// MaterialApp.onGenerateRoute hook: '/sos_alarm?p=<payload json>'.
  static Route<dynamic>? onGenerateRoute(RouteSettings s) {
    final name = s.name ?? '';
    if (!name.startsWith(route)) return null;
    try {
      final raw = jsonDecode(Uri.parse(name).queryParameters['p'] ?? '');
      if (raw is! Map) return null;
      final d = {for (final e in raw.entries) '${e.key}': '${e.value}'};
      if (!wants(d) || open.contains(deliveryOf(d))) return null;
      return pageRoute(d, settings: s);
    } catch (_) {
      return null;
    }
  }

  /// Open once per delivery (warm start / foreground push / tap).
  static bool openOnce(NavigatorState? nav, Map<String, String> data) {
    if (nav == null || !wants(data)) return false;
    if (open.contains(deliveryOf(data))) return true;
    unawaited(nav.push(pageRoute(data)));
    return true;
  }

  @override
  State<SosAlarmScreen> createState() => _SosAlarmScreenState();
}

class _SosAlarmScreenState extends State<SosAlarmScreen>
    with AdBlockedState<SosAlarmScreen> {
  late final DestAlarmSound _sound = widget.sound ?? NativeDestAlarmSound();
  Map<String, dynamic>? _d;
  bool _failed = false;
  bool _alarm = false;
  bool _busyGoing = false;
  bool _playing = false;
  Timer? _poll;

  int get _id => SosAlarmScreen.deliveryOf(widget.data);
  FcSosApi get _api => widget.api ?? HttpFcSosApi(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    SosAlarmScreen.open.add(_id);
    // the page is up: the insistent notification ring stops, the page's own
    // alarm (STREAM_ALARM, loud on silent) takes over until the person acts
    unawaited(PushNotifier.cancelFor(widget.data));
    if (widget.autoAlarm) unawaited(_startAlarm());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_api.seen(_id).catchError((_) {}));
      _load();
    });
    _poll = Timer.periodic(widget.pollEvery, (_) => _load());
  }

  Future<void> _startAlarm() async {
    final ok = await _sound.start(sound: true, vibrate: true);
    if (mounted) setState(() => _alarm = ok);
  }

  Future<void> _stopAlarm() async {
    try {
      await _sound.stop();
    } catch (_) {
      // best-effort: the alarm may already be silent
    }
    if (mounted && _alarm) setState(() => _alarm = false);
  }

  Future<void> _load() async {
    try {
      final d = await _api.event(_id);
      if (!mounted) return;
      setState(() {
        _d = d;
        _failed = false;
      });
      if ('${d['state']}' != 'active') {
        _poll?.cancel();
        unawaited(_stopAlarm());
      }
    } catch (_) {
      if (mounted && _d == null) setState(() => _failed = true);
    }
  }

  Future<void> _going() async {
    setState(() => _busyGoing = true);
    unawaited(_stopAlarm());
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    try {
      await _api.going(_id);
      await _load();
      m?.showSnackBar(SnackBar(content: Text(t.fcsGoingSent)));
    } catch (_) {
      m?.showSnackBar(SnackBar(content: Text(t.fcsGoingFailed)));
    } finally {
      if (mounted) setState(() => _busyGoing = false);
    }
  }

  Future<void> _open(Uri u, String where) async {
    unawaited(_stopAlarm());
    if (widget.openUri != null) return widget.openUri!(u);
    await openForUser(context, u, where: where);
  }

  Future<void> _play() async {
    await _stopAlarm();
    setState(() => _playing = true);
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    try {
      final b = await _api.eventAudio(_id);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/sos_in_$_id.m4a');
      await f.writeAsBytes(b, flush: true);
      final ok = await _sound.playClip(f.path);
      if (!ok) m?.showSnackBar(SnackBar(content: Text(t.fcsSoundPlayFailed)));
    } catch (_) {
      m?.showSnackBar(SnackBar(content: Text(t.fcsSoundPlayFailed)));
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    SosAlarmScreen.open.remove(_id);
    _poll?.cancel();
    unawaited(_sound.stop().catchError((_) {}));
    unawaited(LockScreenGuard.release());
    super.dispose();
  }

  String _dg(String s) => notifLocalizeDigits(context, s);

  TextStyle get _base => Theme.of(context).textTheme.bodyMedium!;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final d = _d;
    final name = '${(d?['sender'] as Map?)?['name'] ?? widget.data['from_name'] ?? ''}';
    final fall = '${d?['kind'] ?? widget.data['alert_kind'] ?? 'sos'}' == 'fall';
    final state = '${d?['state'] ?? 'active'}';
    final phone = '${(d?['sender'] as Map?)?['phone'] ?? ''}';
    final em = emergencyFor('${d?['country'] ?? ''}'.isEmpty ? null : '${d?['country']}');
    final meGoing = d?['me_going'] == true;
    return Scaffold(
      key: const ValueKey('fcs-alarm'),
      backgroundColor: ds.bg,
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, EdgeInsets.zero),
          children: [
            _header(t, name, fall, d),
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (state == 'mistake' || state == 'safe') ...[
                  SosBanner(
                    key: const ValueKey('fcs-alarm-ended'),
                    icon: Icons.verified_rounded,
                    color: Brand.success,
                    title: state == 'mistake' ? t.fcsAlarmMistake(name) : t.fcsAlarmSafe(name),
                    body: state == 'mistake' ? t.fcsAlarmMistakeBody : null,
                  ),
                  const SizedBox(height: Gap.md),
                ],
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.md),
                    child: SosBanner(
                        icon: Icons.wifi_off_rounded,
                        color: Brand.warning,
                        title: t.fcsAlarmLoadFailed),
                  ),
                if (state == 'active') ...[
                  SosBigButton(
                    key: const ValueKey('fcs-going-btn'),
                    icon: meGoing ? Icons.check_circle_rounded : Icons.directions_run_rounded,
                    label: meGoing ? t.fcsGoingYou : t.fcsIamGoing,
                    color: meGoing ? Brand.success : kSosRed,
                    fg: Colors.white,
                    height: 68,
                    onTap: meGoing || _busyGoing ? null : _going,
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  if (phone.isNotEmpty)
                    _half(
                        SosBigButton(
                          key: const ValueKey('fcs-call-sender'),
                          icon: Icons.call_rounded,
                          label: t.fcsCallName(name),
                          color: ds.primary,
                          fg: ds.onPrimary,
                          onTap: () => _open(Uri.parse('tel:$phone'), 'fcsos.call'),
                        )),
                  _half(SosBigButton(
                    key: const ValueKey('fcs-call-emergency'),
                    icon: Icons.local_police_rounded,
                    label: _dg(t.fcsCallEmergency(em.primary.number)),
                    color: ds.card,
                    fg: ds.text,
                    onTap: () => _open(Uri.parse('tel:${em.primary.dial}'), 'fcsos.emergency'),
                  )),
                ]),
                if (_alarm) ...[
                  const SizedBox(height: Gap.sm),
                  TextButton.icon(
                    key: const ValueKey('fcs-alarm-silence'),
                    onPressed: _stopAlarm,
                    icon: const Icon(Icons.volume_off_rounded),
                    label: Text(t.fcsSilence),
                  ),
                ],
                const SizedBox(height: Gap.md),
                _where(t, ds, d),
                const SizedBox(height: Gap.md),
                _soundCard(t, ds, d, state),
                const SizedBox(height: Gap.md),
                SosGoingList(
                  going: ((d?['going'] as List?) ?? const [])
                      .whereType<Map>()
                      .map((e) => e.cast<String, dynamic>())
                      .toList(),
                  title: t.fcsGoingTitle,
                  empty: t.fcsGoingNobody,
                ),
                const SizedBox(height: Gap.md),
                _nearby(t, ds, d),
                if (d?['info'] is Map) ...[
                  const SizedBox(height: Gap.md),
                  _info(t, ds, (d!['info'] as Map).cast<String, dynamic>()),
                ],
                const SizedBox(height: Gap.md),
                Text(t.fcsAlarmFree, style: _base.copyWith(fontSize: 12, color: ds.muted)),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _half(Widget w) => LayoutBuilder(
        builder: (ctx, c) => SizedBox(
          width: MediaQuery.textScalerOf(ctx).scale(14) > 20 || c.maxWidth < 360
              ? c.maxWidth
              : (c.maxWidth - Gap.sm) / 2,
          child: w,
        ),
      );

  Widget _header(AppLocalizations t, String name, bool fall, Map<String, dynamic>? d) {
    final sent = '${d?['sent_at'] ?? ''}';
    final age = (d?['age_s'] as num?)?.toInt();
    // over (mistake / safe): calm header — no red alarm look
    final over = '${d?['state'] ?? 'active'}' != 'active';
    final ds = DsTokens.of(context);
    final fg = over ? ds.text : Colors.white;
    return Container(
      color: over ? ds.card : kSosRed,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(over ? Icons.verified_rounded : Icons.sos_rounded, color: over ? Brand.success : fg, size: 40),
          const Spacer(),
          IconButton(
            tooltip: t.fcsClose,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.close_rounded, color: fg),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(
            fall ? t.fcsAlarmFallTitle(name) : t.fcsAlarmTitle(name),
            style: _base.copyWith(color: fg, fontSize: 28, fontWeight: FontWeight.w900),
          ),
        ),
        if (sent.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Text(
            t.fcsAlarmWhen(sosClock(context, sent), sosAge(context, age ?? 0)),
            style: _base.copyWith(color: fg, fontSize: 16),
          ),
        ],
      ]),
    );
  }

  Widget _where(AppLocalizations t, DsTokens ds, Map<String, dynamic>? d) {
    final loc = d?['location'] as Map?;
    var lat = (loc?['lat'] as num?)?.toDouble();
    var lng = (loc?['lng'] as num?)?.toDouble();
    // gap-sos (P1): the page could not load (weak internet on THIS phone) —
    // the push itself carried the place at send time; show it, never "no
    // location" while we have one.
    if ((lat == null || lng == null) && loc == null) {
      lat = double.tryParse(widget.data['lat'] ?? '');
      lng = double.tryParse(widget.data['lng'] ?? '');
    }
    if (lat == null || lng == null) {
      return SosBanner(
        icon: Icons.location_off_rounded,
        color: Brand.warning,
        title: t.fcsNoLocation,
        body: t.fcsNoLocationBody,
      );
    }
    final at = DateTime.tryParse('${loc?['at'] ?? ''}');
    final serverNow = DateTime.tryParse('${d?['server_now'] ?? ''}');
    final ago = (at != null && serverNow != null) ? serverNow.difference(at).inSeconds : null;
    final live = loc?['live'] == true;
    return DsCard(
      key: const ValueKey('fcs-where'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.place_rounded, color: ds.primaryInk),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.fcsWhereTitle,
                    style: _base.copyWith(fontSize: 17, fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            ago == null
                ? t.fcsWhereAtSend
                : (live ? t.fcsWhereLive(sosAge(context, ago)) : t.fcsWhereAtSendAgo(sosAge(context, ago))),
            style: _base.copyWith(color: ds.muted),
          ),
          Text(_dg('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
              style: _base.copyWith(fontSize: 13, color: ds.muted)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton.icon(
              key: const ValueKey('fcs-open-map'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _open(Uri.parse('https://maps.google.com/?q=$lat,$lng'), 'fcsos.map'),
              icon: const Icon(Icons.map_rounded),
              label: Text(t.fcsOpenMap),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () =>
                  _open(Uri.parse('https://maps.google.com/?daddr=$lat,$lng'), 'fcsos.directions'),
              icon: const Icon(Icons.directions_rounded),
              label: Text(t.fcsDirections),
            ),
          ]),
        ]),
    );
  }

  Widget _soundCard(AppLocalizations t, DsTokens ds, Map<String, dynamic>? d, String state) {
    final sec = (d?['audio_sec'] as num?)?.toInt() ?? 0;
    if (sec <= 0) {
      if (state != 'active') return const SizedBox.shrink();
      return SosBanner(
          icon: Icons.mic_none_rounded, color: ds.muted, title: t.fcsSoundNotYet);
    }
    return SosBigButton(
      key: const ValueKey('fcs-play-sound'),
      icon: _playing ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
      label: t.fcsPlaySound(_dg('$sec')),
      color: ds.primarySoft,
      fg: ds.primaryInk,
      onTap: _playing ? null : _play,
    );
  }

  Widget _nearby(AppLocalizations t, DsTokens ds, Map<String, dynamic>? d) {
    final n = (d?['nearby'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rows = <(String, Map<String, dynamic>)>[
      for (final c in const ['police', 'hospital'])
        for (final r in ((n[c] as List?) ?? const []).whereType<Map>())
          (c, r.cast<String, dynamic>()),
    ];
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    return DsCard(
      key: const ValueKey('fcs-nearby'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.fcsNearbyTitle, style: _base.copyWith(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          if (d != null && rows.isEmpty)
            Text(d['location'] == null ? t.fcsNearbyNeedLocation : t.fcsNearbyNone,
                style: _base.copyWith(color: ds.muted)),
          for (final (cat, r) in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(cat == 'police' ? Icons.local_police_rounded : Icons.local_hospital_rounded,
                  color: cat == 'police' ? ds.primaryInk : Brand.danger),
              title: Text('${(bn ? r['name'] : r['name_en']) ?? r['name'] ?? ''}'),
              subtitle: Text(_dg(t.fcsKmAway(
                  (((r['distance_m'] as num?) ?? 0) / 1000).toStringAsFixed(1)))),
              trailing: Wrap(children: [
                if ('${r['phone'] ?? ''}'.trim().isNotEmpty)
                  IconButton(
                    tooltip: t.fcsCall,
                    icon: const Icon(Icons.call_rounded),
                    onPressed: () => _open(Uri.parse('tel:${'${r['phone']}'.replaceAll(RegExp(r'[^0-9+]'), '')}'),
                        'fcsos.nearby.call'),
                  ),
                IconButton(
                  tooltip: t.fcsDirections,
                  icon: const Icon(Icons.directions_rounded),
                  onPressed: () => _open(
                      Uri.parse('https://maps.google.com/?daddr=${r['lat']},${r['lng']}'),
                      'fcsos.nearby.map'),
                ),
              ]),
            ),
          if (rows.isNotEmpty)
            Text('${n['attribution'] ?? ''}', style: _base.copyWith(fontSize: 11, color: ds.muted)),
        ]),
    );
  }

  Widget _info(AppLocalizations t, DsTokens ds, Map<String, dynamic> i) {
    final contacts = ((i['contacts'] as List?) ?? const []).whereType<Map>().toList();
    return DsCard(
      key: const ValueKey('fcs-info'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.fcsInfoTitle, style: _base.copyWith(fontSize: 17, fontWeight: FontWeight.w800)),
          if ('${i['blood_group'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.fcsBloodGroup('${i['blood_group']}'),
                  style: _base.copyWith(fontSize: 20, fontWeight: FontWeight.w900, color: ds.dangerInk)),
            ),
          if ('${i['allergies'] ?? ''}'.isNotEmpty) Text(t.fcsAllergies('${i['allergies']}')),
          if ('${i['conditions'] ?? ''}'.isNotEmpty) Text(t.fcsConditions('${i['conditions']}')),
          for (final c in contacts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.contact_phone_rounded),
              title: Text('${c['name'] ?? ''}'),
              subtitle: Text(_dg('${c['phone'] ?? ''}')),
              trailing: IconButton(
                tooltip: t.fcsCall,
                icon: const Icon(Icons.call_rounded),
                onPressed: () => _open(Uri.parse('tel:${c['phone']}'), 'fcsos.info.call'),
              ),
            ),
        ]),
    );
  }
}
