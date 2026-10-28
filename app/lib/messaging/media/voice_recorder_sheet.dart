import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../services/error_report.dart';
import '../../theme.dart';
import 'media_descriptor.dart';
import 'media_prep.dart';
import 'media_store.dart';
import 'voice_bubble.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// md1 — record a voice message (AAC-LC .m4a, mono, 32 kbps ≈ 240 KB/min).
/// The recorder is created only when this sheet opens, after the mic
/// permission; nothing runs at launch.
const Duration kVoiceMax = Duration(minutes: 15);
const Duration kVoiceMin = Duration(seconds: 1);

/// Plugin seam (a fake in widget tests).
abstract class RecorderBackend {
  Future<void> start(String path);
  Future<String?> stop();
  Future<void> cancel();
  Stream<double> amplitude(); // dBFS (<= 0)
  Future<void> dispose();
}

class RecordPluginBackend implements RecorderBackend {
  final AudioRecorder _r = AudioRecorder();
  @override
  Future<void> start(String path) => _r.start(
      const RecordConfig(
          encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
      path: path);
  @override
  Future<String?> stop() => _r.stop();
  @override
  Future<void> cancel() => _r.cancel();
  @override
  Stream<double> amplitude() =>
      _r.onAmplitudeChanged(const Duration(milliseconds: 100)).map((a) => a.current);
  @override
  Future<void> dispose() => _r.dispose();
}

RecorderBackend Function() recorderFactory = RecordPluginBackend.new;

/// dBFS (-60..0) -> waveform level 0..31.
int levelFromDb(double db) {
  if (db.isNaN || db.isInfinite) return 0;
  final v = ((db + 60) / 60).clamp(0.0, 1.0);
  return (v * 31).round();
}

/// Down-sample many levels to [n] bars (max of each bucket).
List<int> compactWave(List<int> levels, {int n = 48}) {
  if (levels.isEmpty) return const [];
  if (levels.length <= n) return List<int>.from(levels);
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final s = (i * levels.length / n).floor();
    final e = math.max(s + 1, ((i + 1) * levels.length / n).floor());
    out.add(levels.sublist(s, e).reduce(math.max));
  }
  return out;
}

/// Opens the recorder; returns the prepared voice note, or null.
///
/// [onRecording] (calls-presence): true once the microphone really records,
/// false when it stops (sent / discarded / closed) — the chat shows the other
/// person "recording audio…" in between.
Future<MediaDraft?> showVoiceRecorder(BuildContext context,
    {ValueChanged<bool>? onRecording}) async {
  final t = AppLocalizations.of(context);
  final ok = await ensureMediaPermission(context, Permission.microphone,
      title: t.md1PermMicTitle, body: t.md1PermMicBody, denied: t.md1PermDeniedMic);
  if (!ok || !context.mounted) return null;
  return showAppSheet<MediaDraft>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => VoiceRecorderSheet(onRecording: onRecording),
  );
}

class VoiceRecorderSheet extends StatefulWidget {
  const VoiceRecorderSheet({super.key, this.onRecording});

  /// calls-presence: recording started (true) / stopped (false).
  final ValueChanged<bool>? onRecording;
  @override
  State<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends State<VoiceRecorderSheet> {
  RecorderBackend? _rec;
  StreamSubscription<double>? _amp;
  Timer? _tick;
  final _sw = Stopwatch();
  final List<int> _levels = [];
  String _path = '';
  String _error = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final rec = recorderFactory();
      _rec = rec;
      _path = '${(await MediaDirs.sub('out')).path}/${newMediaId()}.m4a';
      await rec.start(_path);
      _sw.start();
      _signal(true);
      _amp = rec.amplitude().listen((db) {
        if (!mounted) return;
        setState(() => _levels.add(levelFromDb(db)));
      });
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (_sw.elapsed >= kVoiceMax) {
          unawaited(_finish());
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      reportNonFatal('md1_voice_record', e);
      if (mounted) setState(() => _error = AppLocalizations.of(context).md1VoiceFailed);
    }
  }

  bool _signalled = false;
  void _signal(bool on) {
    if (on == _signalled) return;
    _signalled = on;
    try {
      widget.onRecording?.call(on);
    } catch (e) {
      reportNonFatal('cp_voice_activity', e);
    }
  }

  Future<void> _cleanup() async {
    _signal(false);
    _tick?.cancel();
    await _amp?.cancel();
    _sw.stop();
  }

  Future<void> _discard() async {
    await _cleanup();
    try {
      await _rec?.cancel();
    } catch (e) {
      reportNonFatal('md1_voice_cancel', e);
    }
    try {
      if (_path.isNotEmpty && File(_path).existsSync()) File(_path).deleteSync();
    } catch (e) {
      reportNonFatal('md1_voice_cleanup', e);
    }
    await _rec?.dispose();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _finish() async {
    if (_busy) return;
    _busy = true;
    final elapsed = _sw.elapsed;
    await _cleanup();
    String? path;
    try {
      path = await _rec?.stop();
    } catch (e) {
      reportNonFatal('md1_voice_stop', e);
    }
    await _rec?.dispose();
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    path ??= _path;
    final f = File(path);
    if (elapsed < kVoiceMin || !f.existsSync() || f.lengthSync() == 0) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        reportNonFatal('md1_voice_cleanup', e);
      }
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.md1VoiceTooShort)));
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
        context,
        MediaDraft(
          kind: 'voice',
          path: path,
          name: 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
          mime: 'audio/mp4',
          size: f.lengthSync(),
          durationMs: elapsed.inMilliseconds,
          wave: compactWave(_levels),
        ));
  }

  @override
  void dispose() {
    _signal(false);
    _tick?.cancel();
    _amp?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ms = _sw.elapsedMilliseconds;
    final wave = compactWave(_levels.length > 200 ? _levels.sublist(_levels.length - 200) : _levels,
        n: 40);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error.isNotEmpty) ...[
              Icon(Icons.mic_off_rounded, color: scheme.error, size: 36),
              const SizedBox(height: Gap.sm),
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: Gap.md),
              FilledButton(onPressed: _discard, child: Text(t.md1Cancel)),
            ] else ...[
              Row(
                children: [
                  Icon(Icons.fiber_manual_record_rounded, color: scheme.error, size: 14),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.md1VoiceRecording,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                  Text(notifLocalizeDigits(context, mediaDurationLabel(ms)),
                      key: const Key('md1-rec-time'),
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: Gap.md),
              SizedBox(
                height: 40,
                width: double.infinity,
                child: CustomPaint(
                    painter: WavePainter(wave, 1, scheme.primary, scheme.primary)),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.md1VoiceMax,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  IconButton(
                    key: const Key('md1-rec-discard'),
                    tooltip: t.md1VoiceDiscard,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _discard,
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    key: const Key('md1-rec-send'),
                    onPressed: _finish,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(t.md1VoiceStopSend),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
