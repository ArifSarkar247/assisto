import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../ds/ds.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../screens/watchman/watchman_source.dart';
import '../theme.dart' show Brand;
import '../widgets/app_sheet.dart' show withNavBarInset;
import 'phonecam_clips.dart';
import 'phonecam_full_video.dart';

/// cctvplay item 4 — the phone camera's optional CONTINUOUS recording, seen
/// from the owner's (or an allowed family member's) phone: the switch (OFF
/// by default, owner only), honest state (recording / paused and why /
/// storage), the last 24 hours as hour rows with recorded minutes and alert
/// marks, and on-demand viewing of one recorded minute — the camera phone
/// seals that segment and sends it (the same path as an alert's full video).
abstract class PhoneCamRecSource {
  Future<Map<String, dynamic>> recording(int cameraId);
  Future<Map<String, dynamic>> setRecording(int cameraId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> clipState(int cameraId, String key);
  Future<Map<String, dynamic>> requestClip(int cameraId, int t);
  Future<Uint8List> download(String url);
  Future<List<IdentityKeyPair>> myKeys();
}

class ApiPhoneCamRecSource implements PhoneCamRecSource {
  final ApiClient api;
  ApiPhoneCamRecSource(this.api);

  @override
  Future<Map<String, dynamic>> recording(int cameraId) =>
      api.getJson('/shop/phonecam/$cameraId/recording');

  @override
  Future<Map<String, dynamic>> setRecording(int cameraId, Map<String, dynamic> body) =>
      api.patchJson('/shop/phonecam/$cameraId/recording', body);

  @override
  Future<Map<String, dynamic>> clipState(int cameraId, String key) =>
      api.getJson('/shop/phonecam/$cameraId/recording/clip?key=$key');

  @override
  Future<Map<String, dynamic>> requestClip(int cameraId, int t) =>
      api.postJson('/shop/phonecam/$cameraId/recording/clip', {'t': t});

  @override
  Future<Uint8List> download(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) throw ApiException('Error ${r.statusCode}', r.statusCode);
    if (r.bodyBytes.length > kVideoMaxBytes + 4096) throw ApiException('Error 413', 413);
    return r.bodyBytes;
  }

  @override
  Future<List<IdentityKeyPair>> myKeys() => IdentityVault.instance.ring();
}

/// The recorded minute around second [t] through the full-video panel.
class _MinuteSource implements PhoneCamClipSource {
  final PhoneCamRecSource src;
  final int cameraId;
  final int t;
  _MinuteSource(this.src, this.cameraId, this.t);

  @override
  Future<Map<String, dynamic>> fullState(int _) => src.clipState(cameraId, 's$t');
  @override
  Future<Map<String, dynamic>> requestFull(int _) => src.requestClip(cameraId, t);
  @override
  Future<Uint8List> download(String url) => src.download(url);
  @override
  Future<List<IdentityKeyPair>> myKeys() => src.myKeys();
}

class PhoneCamTimelineScreen extends StatefulWidget {
  final int cameraId;
  final String cameraName;
  final PhoneCamRecSource source;

  /// Tests / gallery: a fixed "now" so the hour rows are stable.
  final DateTime? now;
  const PhoneCamTimelineScreen(
      {super.key, required this.cameraId, required this.cameraName, required this.source, this.now});

  @override
  State<PhoneCamTimelineScreen> createState() => _PhoneCamTimelineScreenState();
}

class _PhoneCamTimelineScreenState extends State<PhoneCamTimelineScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};
  int? _sel; // the second picked on the timeline
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.recording(widget.cameraId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = wmError(e) ?? AppLocalizations.of(context).pcpFailed;
        _loading = false;
      });
    }
  }

  Future<void> _set(Map<String, dynamic> body) async {
    setState(() => _saving = true);
    try {
      final d = await widget.source.setRecording(widget.cameraId, body);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(wmError(e) ?? AppLocalizations.of(context).pcpFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<List<int>> get _spans => [
        for (final s in (wmMap(_d['timeline'])['spans'] as List? ?? const []))
          if (s is List && s.length >= 2) [(s[0] as num).toInt(), (s[1] as num).toInt()]
      ];

  List<int> get _alerts => [
        for (final a in (wmMap(_d['timeline'])['alerts'] as List? ?? const []))
          if (a is num) a.toInt()
      ];

  bool _covered(int t) => _spans.any((s) => s[0] <= t && t < s[1]);

  String _stateLine(AppLocalizations t, String lang) {
    final tl = wmMap(_d['timeline']);
    final on = wmMap(_d['settings'])['on'] == true;
    if (!on) return t.pcrStateOff;
    final used = wmDigits(lang, ((tl['used_mb'] as num?) ?? 0).toInt());
    final cap = wmDigits(lang, ((wmMap(_d['settings'])['cap_mb'] as num?) ?? 0).toInt());
    return switch ((tl['state'] ?? '').toString()) {
      'recording' => t.pcrOnLine(used, cap),
      _ => switch ((tl['reason'] ?? '').toString()) {
          'hot' => t.pcrPausedHot,
          'battery' => t.pcrPausedBattery,
          'storage' => t.pcrPausedStorage,
          'live' => t.pcrPausedLive,
          'unsupported' => t.pcrUnsupported,
          _ => t.pcrWaitingPhone,
        },
    };
  }

  String _clock(BuildContext context, String lang, int sec) {
    final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return wmDigits(lang, MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(dt)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final tt = Theme.of(context).textTheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        Text(_error!),
        const SizedBox(height: 12),
        OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            child: Text(t.wmRetry)),
      ]);
    } else {
      final owner = _d['can_change'] == true;
      final set = wmMap(_d['settings']);
      final on = set['on'] == true;
      final caps = [for (final c in (_d['cap_choices_mb'] as List? ?? const [])) if (c is num) c.toInt()];
      final cap = ((set['cap_mb'] as num?) ?? 2000).toInt();
      final online = _d['camera_online'] == true;
      final now = (widget.now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
      final hourNow = now - now % 3600;
      final spans = _spans;
      final hours = [
        for (var h = 0; h < 24; h++) hourNow - h * 3600,
      ].where((hs) => spans.any((s) => s[1] > hs && s[0] < hs + 3600) || _alerts.any((a) => a >= hs && a < hs + 3600)).toList();
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(16)), children: [
          DsCard(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(on ? Icons.fiber_manual_record_rounded : Icons.stop_circle_outlined,
                      color: on ? Brand.danger : null),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_stateLine(t, lang), style: tt.titleSmall)),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(online ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: Text(online ? t.pcrPhoneOnline : t.pcrPhoneOffline, style: tt.bodySmall)),
                ]),
              ]),
          ),
          const SizedBox(height: 8),
          if (owner) ...[
            SwitchListTile(
              key: const Key('pcrSwitch'),
              contentPadding: EdgeInsets.zero,
              value: on,
              onChanged: _saving ? null : (v) => _set({'on': v}),
              title: Text(t.pcrTitle),
              subtitle: Text(t.pcrOwnerBody),
            ),
            if (caps.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.pcrCapTitle),
                trailing: DropdownButton<int>(
                  value: caps.contains(cap) ? cap : caps.first,
                  onChanged: _saving ? null : (v) => v == null ? null : _set({'cap_mb': v}),
                  items: [
                    for (final c in caps)
                      DropdownMenuItem(value: c, child: Text(t.pcCapMb(wmDigits(lang, c)))),
                  ],
                ),
              ),
          ] else
            Text(t.pcrViewerNote, style: tt.bodySmall),
          const SizedBox(height: 12),
          Text(t.pcrTimelineTitle, style: tt.titleMedium),
          const SizedBox(height: 6),
          if (hours.isEmpty)
            _empty(t, owner, on)
          else ...[
            Text(t.pcrTapHint, style: tt.bodySmall),
            const SizedBox(height: 8),
            for (final hs in hours) _hourRow(context, t, lang, hs),
          ],
          if (_sel != null) ...[
            const Divider(height: 28),
            Row(children: [
              IconButton.outlined(
                tooltip: t.pcrPrevMinute,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _covered(_sel! - 60) ? () => setState(() => _sel = _sel! - 60) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(t.pcrSelected(_clock(context, lang, _sel!)),
                    textAlign: TextAlign.center, style: tt.titleSmall),
              ),
              IconButton.outlined(
                tooltip: t.pcrNextMinute,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _covered(_sel! + 60) ? () => setState(() => _sel = _sel! + 60) : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ]),
            const SizedBox(height: 8),
            PhoneCamFullVideo(
              key: ValueKey('pcr-${_sel!}'),
              source: _MinuteSource(widget.source, widget.cameraId, _sel!),
              eventId: 0,
              title: t.pcrMinuteTitle,
              defaultSeconds: 60,
              initial: {
                'status': ((_d['views'] as Map?) ?? const {})['s${_sel!}'] ?? 'none',
                'camera_online': online,
                'est_mb': _d['est_mb'],
                'keep_h': _d['keep_h'],
                'budget': _d['budget'],
                'clip_s': _d['segment_s'],
              },
            ),
          ],
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.cameraName.isEmpty ? t.pcrTimelineTitle : widget.cameraName,
              overflow: TextOverflow.ellipsis)),
      body: body,
    );
  }

  Widget _empty(AppLocalizations t, bool owner, bool on) {
    return DsCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.video_library_outlined, size: 40),
          const SizedBox(height: 8),
          Text(t.pcrEmptyBenefit, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          if (owner && !on)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _saving ? null : () => _set({'on': true}),
              icon: const Icon(Icons.fiber_manual_record_rounded),
              label: Text(t.pcrTurnOn),
            ),
          const SizedBox(height: 8),
          Text(on ? t.pcrEmptyWaiting : t.pcrEmptyHow, style: Theme.of(context).textTheme.bodySmall),
        ]),
    );
  }

  Widget _hourRow(BuildContext context, AppLocalizations t, String lang, int hs) {
    final spans = [for (final s in _spans) if (s[1] > hs && s[0] < hs + 3600) s];
    final alerts = [for (final a in _alerts) if (a >= hs && a < hs + 3600) a];
    var mins = 0;
    for (var m = 0; m < 60; m++) {
      if (_covered(hs + m * 60 + 30)) mins++;
    }
    final firstAlert = alerts.where(_covered).firstOrNull;
    final firstRec = [for (var m = 0; m < 60; m++) hs + m * 60 + 30].where(_covered).firstOrNull;
    final pick = firstAlert ?? firstRec;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: pick != null,
      label: t.pcrHourLabel(_clock(context, lang, hs), wmDigits(lang, mins), wmDigits(lang, alerts.length)),
      onTap: pick == null ? null : () => setState(() => _sel = pick),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
              width: 72,
              child: Text(_clock(context, lang, hs), style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final m = (d.localPosition.dx / box.maxWidth * 60).floor().clamp(0, 59);
                  final sec = hs + m * 60 + 30;
                  if (_covered(sec)) {
                    setState(() => _sel = sec);
                  } else {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(t.pcrNotRecorded)));
                  }
                },
                child: SizedBox(
                  height: 48,
                  child: CustomPaint(
                    painter: _HourPainter(
                      hs: hs,
                      spans: spans,
                      alerts: alerts,
                      sel: _sel,
                      rec: scheme.primary,
                      empty: scheme.surfaceContainerHighest,
                      alert: Brand.danger,
                      selColor: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _HourPainter extends CustomPainter {
  final int hs;
  final List<List<int>> spans;
  final List<int> alerts;
  final int? sel;
  final Color rec, empty, alert, selColor;
  _HourPainter(
      {required this.hs,
      required this.spans,
      required this.alerts,
      required this.sel,
      required this.rec,
      required this.empty,
      required this.alert,
      required this.selColor});

  @override
  void paint(Canvas canvas, Size size) {
    final top = size.height * 0.3, h = size.height * 0.4;
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, h), const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = empty);
    double x(int sec) => ((sec - hs) / 3600.0).clamp(0.0, 1.0) * size.width;
    final p = Paint()..color = rec;
    for (final s in spans) {
      canvas.drawRect(Rect.fromLTRB(x(s[0]), top, x(s[1]), top + h), p);
    }
    final a = Paint()..color = alert;
    for (final t in alerts) {
      canvas.drawCircle(Offset(x(t), top - 4), 4, a);
    }
    final s = sel;
    if (s != null && s >= hs && s < hs + 3600) {
      canvas.drawRect(Rect.fromLTWH(x(s) - 1.5, 2, 3, size.height - 4), Paint()..color = selColor);
    }
  }

  @override
  bool shouldRepaint(_HourPainter o) =>
      o.sel != sel || o.spans != spans || o.alerts != alerts || o.rec != rec;
}
