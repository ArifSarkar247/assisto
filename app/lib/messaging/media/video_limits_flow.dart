import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'media_limits.dart';
import 'media_prep.dart';
import 'media_store.dart';

/// viewonce — owner My Circle order 3 Nov 16:30, part F, for VIDEO:
/// at most [MediaLimits.videoSeconds] (3 min) — longer clips open the trim
/// screen first — compressed ON THE PHONE so the short side is at most
/// [MediaLimits.videoHeight] (720p) and the file stays under
/// [MediaLimits.video] (25 MB). The size is shown before Send (the send
/// confirm reads the prepared draft). The server re-checks size + length.

/// Raw clips up to this may be picked (they are compressed before sending).
const int kRawVideoPickMax = 2 * 1024 * 1024 * 1024 - 1;

/// What happens to a picked clip before it can be sent.
enum VideoPlan { sendAsIs, compress, trimThenCompress }

/// PURE (tests): the plan for a clip of [durationMs] / [size] / [w]x[h].
VideoPlan planVideo({int? durationMs, required int size, int? width, int? height}) {
  if (MediaLimits.needsTrim(durationMs)) return VideoPlan.trimThenCompress;
  final shortSide = (width != null && height != null) ? math.min(width, height) : null;
  if (size > MediaLimits.video) return VideoPlan.compress;
  if (shortSide == null || shortSide > MediaLimits.videoHeight) return VideoPlan.compress;
  return VideoPlan.sendAsIs;
}

/// PURE (tests): keep a trim window inside [0, total] and at most [max] long
/// (the thumb the user did NOT move follows the one they did).
({int start, int end}) clampTrim(int start, int end, int total, int max,
    {bool movedStart = false}) {
  var s = start.clamp(0, total);
  var e = end.clamp(0, total);
  if (e < s) {
    if (movedStart) {
      e = s;
    } else {
      s = e;
    }
  }
  if (e - s > max) {
    if (movedStart) {
      e = s + max;
    } else {
      s = e - max;
    }
  }
  return (start: s, end: e);
}

class VideoCompressOut {
  final String path;
  final int size;
  const VideoCompressOut(this.path, this.size);
}

/// Seam for the native compressor (fake in tests).
abstract class VideoCompressor {
  /// null = the phone can't compress (no encoder / no native side / failed).
  Future<VideoCompressOut?> compress(
      {required String src,
      required String dst,
      required int startMs,
      required int endMs,
      required int shortSide,
      required int bitrate});

  /// 0..100, or -1 when unknown.
  Future<int> progress();
  Future<void> cancel();
}

class ChannelVideoCompressor implements VideoCompressor {
  const ChannelVideoCompressor();
  static const _ch = MethodChannel('com.assisto/video_compress');

  @override
  Future<VideoCompressOut?> compress(
      {required String src,
      required String dst,
      required int startMs,
      required int endMs,
      required int shortSide,
      required int bitrate}) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('compress', {
        'src': src,
        'dst': dst,
        'startMs': startMs,
        'endMs': endMs,
        'shortSide': shortSide,
        'bitrate': bitrate,
      });
      final p = '${r?['path'] ?? ''}';
      if (r?['ok'] != true || p.isEmpty) return null;
      return VideoCompressOut(p, (r?['size'] as num?)?.toInt() ?? File(p).lengthSync());
    } on PlatformException catch (e) {
      if (e.code != 'cancelled') reportNonFatal('vo_video_compress', e);
      return null;
    } on MissingPluginException {
      return null; // an older native side: the caller falls back honestly
    }
  }

  @override
  Future<int> progress() async {
    try {
      return await _ch.invokeMethod<int>('progress') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _ch.invokeMethod<bool>('cancel');
    } catch (_) {}
  }
}

/// Tests swap this.
VideoCompressor videoCompressor = const ChannelVideoCompressor();

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (e) {
    reportNonFatal('vo_video_cleanup', e);
  }
}

String _mins(BuildContext context, int seconds) => notifLocalizeDigits(
    context, seconds % 60 == 0 ? '${seconds ~/ 60}' : (seconds / 60).toStringAsFixed(1));

/// Trim (when too long) + compress a picked clip. null = cancelled or it
/// can't be sent (an honest message was shown; the picked copy is deleted).
Future<MediaDraft?> prepareVideoForSend(BuildContext context, MediaDraft d) async {
  final t = AppLocalizations.of(context);
  final plan = planVideo(
      durationMs: d.durationMs, size: d.size, width: d.width, height: d.height);
  if (plan == VideoPlan.sendAsIs) return d;
  var start = 0, end = -1;
  if (plan == VideoPlan.trimThenCompress) {
    final w = await Navigator.of(context).push<({int start, int end})>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VideoTrimScreen(durationMs: d.durationMs!, thumbB64: d.thumbB64)));
    if (w == null) {
      _deleteQuietly(d.path);
      return null;
    }
    start = w.start;
    end = w.end;
  }
  if (!context.mounted) {
    _deleteQuietly(d.path);
    return null;
  }
  final lenMs = end > 0 ? end - start : (d.durationMs ?? 0);
  final dst = '${(await MediaDirs.sub('out')).path}/${newMediaId()}.mp4';
  if (!context.mounted) return null;
  final out = await showDialog<VideoCompressOut?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CompressDialog(
      run: () => videoCompressor.compress(
          src: d.path,
          dst: dst,
          startMs: start,
          endMs: end,
          shortSide: MediaLimits.videoHeight,
          bitrate: MediaLimits.videoBitrateFor((lenMs / 1000).ceil())),
    ),
  );
  if (out == null) {
    _deleteQuietly(dst);
    // the clip itself is within the limits: send it as picked (honest:
    // nothing was cut, it already fits)
    if (plan == VideoPlan.compress && d.size <= MediaLimits.video) return d;
    _deleteQuietly(d.path);
    if (context.mounted) {
      _toast(
          context,
          t.vo1CompressFailed(_mins(context, MediaLimits.videoSeconds),
              notifLocalizeDigits(context, '${MediaLimits.video ~/ (1024 * 1024)}')));
    }
    return null;
  }
  if (out.size > MediaLimits.video) {
    _deleteQuietly(out.path);
    _deleteQuietly(d.path);
    if (context.mounted) {
      _toast(context,
          t.md1TooBig(notifLocalizeDigits(context, '${MediaLimits.video ~/ (1024 * 1024)}')));
    }
    return null;
  }
  _deleteQuietly(d.path);
  final shortSide = (d.width != null && d.height != null) ? math.min(d.width!, d.height!) : 0;
  final scale = shortSide > MediaLimits.videoHeight ? MediaLimits.videoHeight / shortSide : 1.0;
  final name = d.name.contains('.')
      ? '${d.name.substring(0, d.name.lastIndexOf('.'))}.mp4'
      : '${d.name}.mp4';
  return MediaDraft(
    kind: 'video',
    path: out.path,
    name: name,
    mime: 'video/mp4',
    size: out.size,
    width: d.width == null ? null : (d.width! * scale).round(),
    height: d.height == null ? null : (d.height! * scale).round(),
    durationMs: lenMs > 0 ? lenMs : d.durationMs,
    thumbB64: d.thumbB64,
  );
}

/// "Making the video smaller (720p)…" with a real progress bar + Cancel.
class _CompressDialog extends StatefulWidget {
  final Future<VideoCompressOut?> Function() run;
  const _CompressDialog({required this.run});

  @override
  State<_CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<_CompressDialog> {
  Timer? _poll;
  int _pct = -1;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      final p = await videoCompressor.progress();
      if (mounted && p != _pct) setState(() => _pct = p);
    });
    unawaited(widget.run().then((r) {
      if (mounted && !_cancelled) Navigator.of(context).pop(r);
    }));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(t.vo1Compressing),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(
            key: const Key('vo1-compress-progress'),
            value: _pct < 0 ? null : _pct / 100),
        const SizedBox(height: Gap.sm),
        if (_pct >= 0) Text(notifLocalizeDigits(context, '$_pct%')),
      ]),
      actions: [
        TextButton(
          key: const Key('vo1-compress-cancel'),
          onPressed: () {
            _cancelled = true;
            unawaited(videoCompressor.cancel());
            Navigator.of(context).pop(null);
          },
          child: Text(t.md1Cancel),
        ),
      ],
    );
  }
}

/// The trim screen: a clip longer than the owner's limit — choose the part
/// (at most [MediaLimits.videoSeconds]) to send. Returns {start, end} ms.
class VideoTrimScreen extends StatefulWidget {
  final int durationMs;
  final String thumbB64;
  const VideoTrimScreen({super.key, required this.durationMs, this.thumbB64 = ''});

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  late int _start = 0;
  late int _end = math.min(widget.durationMs, MediaLimits.videoSeconds * 1000);

  int get _max => MediaLimits.videoSeconds * 1000;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final total = widget.durationMs;
    final len = _end - _start;
    // an honest size estimate at the bitrate the compressor will use
    final estBytes = ((MediaLimits.videoBitrateFor((len / 1000).ceil()) + 64000) * (len / 1000) / 8).round();
    String dur(int ms) => notifLocalizeDigits(context, mediaDurationLabel(ms));
    Widget? thumb;
    if (widget.thumbB64.isNotEmpty) {
      try {
        thumb = Image.memory(base64Decode(widget.thumbB64),
            fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium);
      } catch (_) {}
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.vo1TrimTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (thumb != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg),
              child: AspectRatio(aspectRatio: 16 / 9, child: thumb),
            ),
          const SizedBox(height: Gap.lg),
          Text(t.vo1TrimBody(_mins(context, MediaLimits.videoSeconds)),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: Gap.md),
          RangeSlider(
            key: const Key('vo1-trim-range'),
            min: 0,
            max: total.toDouble(),
            values: RangeValues(_start.toDouble(), _end.toDouble()),
            labels: RangeLabels(dur(_start), dur(_end)),
            divisions: total > 1000 ? math.min(total ~/ 1000, 2000) : null,
            onChanged: (v) {
              final movedStart = v.start.round() != _start;
              final w = clampTrim(v.start.round(), v.end.round(), total, _max,
                  movedStart: movedStart);
              setState(() {
                _start = w.start;
                _end = w.end;
              });
            },
          ),
          Row(children: [
            Text(dur(_start), key: const Key('vo1-trim-start')),
            const Spacer(),
            Text(dur(_end), key: const Key('vo1-trim-end')),
          ]),
          const SizedBox(height: Gap.md),
          Text(t.vo1TrimSelected(dur(len), notifLocalizeDigits(context, mediaSizeLabel(estBytes))),
              key: const Key('vo1-trim-selected'),
              style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: Gap.xl),
          SizedBox(
            height: 48,
            child: FilledButton(
              key: const Key('vo1-trim-done'),
              onPressed: len >= 1000
                  ? () => Navigator.pop(context, (start: _start, end: _end))
                  : null,
              child: Text(t.vo1TrimDone),
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.md1Cancel),
            ),
          ),
        ],
      ),
    );
  }
}
