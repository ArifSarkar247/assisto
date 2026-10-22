import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'voice_player.dart';

/// Waveform bars (levels 0..31); bars left of [progress] use [played].
class WavePainter extends CustomPainter {
  final List<int> levels;
  final double progress;
  final Color played;
  final Color rest;
  WavePainter(this.levels, this.progress, this.played, this.rest);

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.isEmpty ? 32 : levels.length;
    final gap = 2.0;
    final w = ((size.width - gap * (n - 1)) / n).clamp(1.0, 6.0);
    final p = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final lv = levels.isEmpty ? 6 : levels[i];
      final h = (size.height * (0.12 + 0.88 * lv / 31)).clamp(2.0, size.height);
      final x = i * (w + gap);
      p.color = (i + 0.5) / n <= progress ? played : rest;
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, w, h), Radius.circular(w / 2));
      canvas.drawRRect(r, p);
    }
  }

  @override
  bool shouldRepaint(WavePainter o) =>
      o.progress != progress || o.levels != levels || o.played != played || o.rest != rest;
}

/// A playable voice note: play/pause, waveform with tap/drag seek, time.
class VoiceNoteBody extends StatelessWidget {
  final String? path; // decrypted file; null = not downloaded yet
  final int durationMs;
  final List<int> wave;
  final Color fg;
  final Widget? leading; // download / progress control when [path] is null
  final void Function(bool ok)? onPlayed;
  const VoiceNoteBody({
    super.key,
    required this.path,
    required this.durationMs,
    required this.wave,
    required this.fg,
    this.leading,
    this.onPlayed,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ValueListenableBuilder<VoiceState>(
      valueListenable: VoicePlayer.instance.state,
      builder: (context, s, _) {
        final mine = path != null && s.path == path;
        final dur = mine && s.durationMs > 0 ? s.durationMs : durationMs;
        final pos = mine ? s.positionMs : 0;
        final frac = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
        final playing = mine && s.playing;
        return SizedBox(
          width: 230,
          child: Row(
            children: [
              leading ??
                  IconButton(
                    key: const Key('md1-voice-play'),
                    tooltip: playing ? t.md1Pause : t.md1Play,
                    icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                        size: 36, color: fg),
                    onPressed: path == null
                        ? null
                        : () async {
                            final ok = await VoicePlayer.instance
                                .toggle(path!, durationMs: durationMs);
                            onPlayed?.call(ok);
                          },
                  ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (context, c) => GestureDetector(
                        key: const Key('md1-voice-wave'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: path == null
                            ? null
                            : (d) => VoicePlayer.instance.seekFraction(
                                path!, d.localPosition.dx / c.maxWidth, durationMs),
                        onHorizontalDragUpdate: path == null
                            ? null
                            : (d) => VoicePlayer.instance.seekFraction(
                                path!, d.localPosition.dx / c.maxWidth, durationMs),
                        child: SizedBox(
                          height: 30,
                          width: c.maxWidth,
                          child: CustomPaint(
                            painter: WavePainter(
                                wave, frac, fg, fg.withValues(alpha: 0.35)),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      notifLocalizeDigits(
                          context, mediaDurationLabel(playing || pos > 0 ? pos : dur)),
                      style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.8)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
