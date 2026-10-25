import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'voice_played.dart';
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

  /// wa-polish2: a received note not played yet — WhatsApp's dot.
  final bool unplayed;

  /// wa-polish2: seeds the stand-in bars when [wave] is empty.
  final int? waveSeed;
  const VoiceNoteBody({
    super.key,
    required this.path,
    required this.durationMs,
    required this.wave,
    required this.fg,
    this.leading,
    this.onPlayed,
    this.unplayed = false,
    this.waveSeed,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // wa-polish2: no samples (older sender) -> stable seeded bars, not flat
    final bars = wave.isNotEmpty ? wave : seededWave(waveSeed ?? durationMs);
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
                    icon: Icon(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
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
                                bars, frac, fg, fg.withValues(alpha: 0.35)),
                          ),
                        ),
                      ),
                    ),
                    Row(children: [
                      Text(
                        notifLocalizeDigits(
                            context, mediaDurationLabel(playing || pos > 0 ? pos : dur)),
                        style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.8)),
                      ),
                      // wa-polish2: WhatsApp's "not played yet" dot
                      if (unplayed && !mine) ...[
                        const SizedBox(width: 6),
                        Semantics(
                          label: t.wa2VoiceUnplayed,
                          child: Container(
                            key: const Key('wa2-voice-unplayed'),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: scheme.primary, shape: BoxShape.circle),
                          ),
                        ),
                      ],
                      // e-gaps: playback speed (shown once this note plays)
                      if (mine && (playing || pos > 0)) ...[
                        const SizedBox(width: 8),
                        VoiceRatePill(fg: fg),
                      ],
                    ]),
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

/// e-gaps: the 1x / 1.5x / 2x pill — one tap cycles the speed.
class VoiceRatePill extends StatelessWidget {
  final Color fg;
  const VoiceRatePill({super.key, required this.fg});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: VoicePlayer.instance.rate,
      builder: (context, r, _) => Semantics(
        button: true,
        label: t.eVoiceSpeed,
        child: InkWell(
          key: const Key('e-voice-rate'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => VoicePlayer.instance.cycleRate(),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 24),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              notifLocalizeDigits(context, voiceRateLabel(r)),
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
