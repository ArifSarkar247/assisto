import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/media/media_prep.dart' show ensureMediaPermission;
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// kidswatch — a short voice note. For a WATCH reply it records AMR-NB
/// (8 kHz, the only format these watches play, max 15 s); for the phone
/// check-in it records AAC. The recorder is created only when this sheet
/// opens, after the microphone permission; nothing runs at launch, every
/// plugin call is crash-guarded.
abstract class KwRecorder {
  Future<void> start(String path, {required bool amr});
  Future<String?> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class KwRecordPlugin implements KwRecorder {
  AudioRecorder? _r;
  AudioRecorder get _rec => _r ??= AudioRecorder();

  @override
  Future<void> start(String path, {required bool amr}) => _rec.start(
      amr
          ? const RecordConfig(
              encoder: AudioEncoder.amrNb, bitRate: 12200, sampleRate: 8000, numChannels: 1)
          : const RecordConfig(
              encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
      path: path);
  @override
  Future<String?> stop() => _rec.stop();
  @override
  Future<void> cancel() => _rec.cancel();
  @override
  Future<void> dispose() async => _r?.dispose();
}

/// Tests swap this.
KwRecorder Function() kwRecorderFactory = KwRecordPlugin.new;

/// Opens the recorder; returns the recorded bytes, or null.
Future<List<int>?> showKwRecorder(BuildContext context, {required bool amr}) async {
  final t = AppLocalizations.of(context);
  final ok = await ensureMediaPermission(context, Permission.microphone,
      title: t.md1PermMicTitle, body: t.md1PermMicBody, denied: t.md1PermDeniedMic);
  if (!ok || !context.mounted) return null;
  return showAppSheet<List<int>>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => KwRecorderSheet(amr: amr),
  );
}

class KwRecorderSheet extends StatefulWidget {
  const KwRecorderSheet({super.key, required this.amr});
  final bool amr;

  static const maxSeconds = 15;

  @override
  State<KwRecorderSheet> createState() => _KwRecorderSheetState();
}

class _KwRecorderSheetState extends State<KwRecorderSheet> {
  KwRecorder? _rec;
  Timer? _tick;
  final _sw = Stopwatch();
  String _path = '';
  bool _recording = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final rec = kwRecorderFactory();
      _rec = rec;
      _path = '${Directory.systemTemp.path}/kw_${DateTime.now().millisecondsSinceEpoch}'
          '.${widget.amr ? 'amr' : 'm4a'}';
      await rec.start(_path, amr: widget.amr);
      _sw.start();
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (_sw.elapsed.inSeconds >= KwRecorderSheet.maxSeconds) {
          unawaited(_finish());
        } else {
          setState(() {});
        }
      });
      if (mounted) setState(() => _recording = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _finish() async {
    _tick?.cancel();
    _sw.stop();
    List<int>? bytes;
    try {
      final p = await _rec?.stop();
      final f = File(p ?? _path);
      if (await f.exists()) {
        bytes = await f.readAsBytes();
        unawaited(f.delete().then((_) {}, onError: (_) {}));
      }
    } catch (_) {
      bytes = null;
    }
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty || _sw.elapsed.inMilliseconds < 800) {
      setState(() {
        _recording = false;
        _failed = true;
      });
      return;
    }
    Navigator.of(context).pop(bytes);
  }

  Future<void> _discard() async {
    _tick?.cancel();
    try {
      await _rec?.cancel();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    final r = _rec;
    if (r != null) unawaited(r.dispose().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final secs = notifLocalizeDigits(context, '${_sw.elapsed.inSeconds}');
    final max = notifLocalizeDigits(context, '${KwRecorderSheet.maxSeconds}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.amr ? t.kwRecordReplyTitle : t.kwRecordNoteTitle,
              style: AType.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          Icon(_failed ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 56, color: _failed ? scheme.error : scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(
            _failed ? t.kwRecordFailed : (_recording ? t.kwRecordingOf(secs, max) : t.kwRecordStarting),
            textAlign: TextAlign.center,
            style: AType.bodyLarge,
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _discard,
                icon: const Icon(Icons.close_rounded),
                label: Text(t.kwDiscard),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _recording ? _finish : null,
                icon: const Icon(Icons.send_rounded),
                label: Text(t.kwSendVoice),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
