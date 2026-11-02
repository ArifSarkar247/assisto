import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/trip_recorder.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/permission_reason.dart';

/// sjalarm PROOF: OWNER-ONLY trip recorder screen (opened from the
/// Destination Alarm's app bar only when `trip_recorder` is an owner / staff /
/// allow-list preview). Saves real GPS traces on the phone; Share or a
/// private upload (server: backend/private/trip_traces/, never public).
class TripRecorderScreen extends StatefulWidget {
  /// Tests: skip the location permission check.
  static bool debugSkipPermission = false;
  const TripRecorderScreen({super.key});

  @override
  State<TripRecorderScreen> createState() => _TripRecorderScreenState();
}

const List<String> _kModes = ['cityBus', 'longBus', 'train', 'metro', 'launch', 'walking'];

class _TripRecorderScreenState extends State<TripRecorderScreen> {
  String _mode = 'cityBus';
  List<File> _files = const [];
  final Set<String> _uploaded = {};
  bool _busy = false;

  TripRecorder get _r => TripRecorder.I;

  @override
  void initState() {
    super.initState();
    _r.addListener(_onChange);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _r.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    List<File> l;
    try {
      l = await _r.saved();
    } catch (_) {
      l = const []; // best-effort: no storage yet
    }
    if (mounted) setState(() => _files = l);
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  String _modeLabel(AppLocalizations t, String m) => switch (m) {
        'longBus' => t.trModeLongBus,
        'train' => t.trModeTrain,
        'metro' => t.trModeMetro,
        'launch' => t.trModeLaunch,
        'walking' => t.sjaModeWalking,
        _ => t.trModeCityBus,
      };

  Future<bool> _locationOk() async {
    if (TripRecorderScreen.debugSkipPermission) return true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        if (!mounted || !await showPermissionReason(context, PermKind.location)) return false;
        p = await Geolocator.requestPermission();
      }
      return p == LocationPermission.always || p == LocationPermission.whileInUse;
    } catch (_) {
      return false; // no plugin: treated as location off
    }
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    if (!await _locationOk()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.trAlarmLocationOff)));
      }
      return;
    }
    await _r.start(_mode, title: t.sjaRecorderTitle, text: t.sjaRecNotif, stopLabel: t.trStop);
  }

  Future<void> _stop() async {
    await _r.stop();
    await _reload();
  }

  Future<void> _share(File f) async {
    final gpx = File(f.path.replaceAll(RegExp(r'\.json$'), '.gpx'));
    try {
      await Share.shareXFiles([XFile(f.path), if (gpx.existsSync()) XFile(gpx.path)]);
    } catch (_) {
      // best-effort: no share target
    }
  }

  Future<void> _upload(File f) async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _busy = true);
    var ok = false;
    try {
      final trace = jsonDecode(await f.readAsString());
      final r = await api.postJson('/train/trace',
          {'name': f.uri.pathSegments.last, 'trace': trace});
      ok = r['ok'] == true;
    } catch (_) {
      ok = false; // offline / not allowed: the file stays on the phone
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _uploaded.add(f.path);
    });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.sjaRecUploaded : t.sjaRecUploadFailed)));
  }

  Future<void> _delete(File f) async {
    await _r.delete(f);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _r.value;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.sjaRecorderTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl)),
        children: [
          Text(t.sjaRecBenefit, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          if (!s.recording) ...[
            Text(t.trHowTravel, style: AType.titleSmall),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final m in _kModes)
                ChoiceChip(
                  label: Text(_modeLabel(t, m)),
                  selected: _mode == m,
                  onSelected: (_) => setState(() => _mode = m),
                ),
            ]),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              icon: const Icon(Icons.fiber_manual_record_rounded),
              label: Text(t.sjaRecStart),
              onPressed: _start,
            ),
          ] else ...[
            Semantics(
              liveRegion: true,
              child: Text(
                  _d(t.sjaRecPoints('${s.points}', s.lastAcc == null ? '-' : '${s.lastAcc!.round()}')),
                  style: AType.titleMedium),
            ),
            Text(_modeLabel(t, s.mode), style: AType.bodyMedium),
            if (s.stopMarked)
              Text(t.sjaRecStopMarked, style: AType.bodyMedium.copyWith(color: cs.primary)),
            const SizedBox(height: Gap.md),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              icon: const Icon(Icons.flag_rounded),
              label: Text(t.sjaRecGotOff),
              onPressed: s.points == 0 ? null : () => setState(() => _r.markStop()),
            ),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError),
              icon: const Icon(Icons.stop_rounded),
              label: Text(t.sjaRecStop),
              onPressed: _stop,
            ),
          ],
          const SizedBox(height: Gap.lg),
          Text(t.sjaRecSaved, style: AType.titleSmall),
          if (_files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Text(t.sjaRecEmpty, style: AType.bodyMedium),
            ),
          for (final f in _files) _fileTile(t, f),
        ],
      ),
    );
  }

  Widget _fileTile(AppLocalizations t, File f) {
    var kb = 0;
    try {
      kb = (f.lengthSync() / 1024).ceil();
    } catch (_) {
      kb = 0; // best-effort: size unknown
    }
    final name = f.uri.pathSegments.last;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: AType.bodyMedium),
          Text(_d('$kb KB'), style: AType.bodySmall),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.share_rounded),
              label: Text(t.sjaRecShare),
              onPressed: () => _share(f),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: Icon(_uploaded.contains(f.path) ? Icons.cloud_done_rounded : Icons.cloud_upload_rounded),
              label: Text(_uploaded.contains(f.path) ? t.sjaRecUploaded : t.sjaRecUpload),
              onPressed: _busy || _uploaded.contains(f.path) ? null : () => _upload(f),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(t.trDelete),
              onPressed: () => _delete(f),
            ),
          ]),
        ]),
      ),
    );
  }
}
