import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../theme.dart';
import '../date_separators.dart' show localDigits;
import 'video_ctl.dart';

/// "1:05" / "12:09" / "1:02:03".
String videoTimeLabel(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Open a decrypted video full screen.
Future<void> openVideoPlayer(BuildContext context, File file, {String caption = ''}) =>
    Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VideoPlayerScreen(file: file, caption: caption)));

/// mc-media2 — the full-screen player: play / pause, seek bar with times,
/// mute, an honest error with "Open with another app". The decrypted file
/// stays in the app's private cache (md1 MediaCache).
class VideoPlayerScreen extends StatefulWidget {
  final File file;
  final String caption;
  final bool autoplay;
  const VideoPlayerScreen({super.key, required this.file, this.caption = '', this.autoplay = true});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoCtl? _ctl;
  String _loadError = '';
  bool _controls = true;
  double? _dragMs;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final c = await VideoCtls.factory(widget.file);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ctl = c);
      await c.init();
      if (!mounted) return;
      if (widget.autoplay && c.state.value.error.isEmpty) {
        await c.play();
        _scheduleHide();
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && (_ctl?.state.value.playing ?? false)) setState(() => _controls = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    final c = _ctl;
    if (c != null) unawaited(c.dispose());
    super.dispose();
  }

  Future<void> _toggle(VideoCtlState s) async {
    final c = _ctl;
    if (c == null || !s.initialized) return;
    if (s.playing) {
      await c.pause();
    } else {
      await c.play();
      _scheduleHide();
    }
  }

  Future<void> _openElsewhere() async {
    try {
      final r = await OpenFilex.open(widget.file.path, type: 'video/*');
      if (r.type != ResultType.done && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).mc2ActionFailed)));
      }
    } catch (e) {
      if (mounted) showActionFailed(context, 'mc2_video_open_with', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final c = _ctl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.caption.isEmpty
            ? null
            : Text(widget.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: c == null
          ? (_loadError.isNotEmpty ? _error(t) : _loading(t))
          : ValueListenableBuilder<VideoCtlState>(
              valueListenable: c.state,
              builder: (context, s, _) {
                if (s.error.isNotEmpty || _loadError.isNotEmpty) return _error(t);
                if (!s.initialized) return _loading(t);
                final posMs = _dragMs ?? s.position.inMilliseconds.toDouble();
                final durMs = s.duration.inMilliseconds.toDouble();
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _controls = !_controls);
                    if (_controls) _scheduleHide();
                  },
                  child: Stack(children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: s.aspect,
                        child: KeyedSubtree(key: const Key('mc2-video-view'), child: c.view()),
                      ),
                    ),
                    if (s.buffering)
                      const Center(child: CircularProgressIndicator(color: Colors.white)),
                    if (_controls || !s.playing) ...[
                      Center(
                        child: Material(
                          color: Colors.black45,
                          shape: const CircleBorder(),
                          child: IconButton(
                            key: const Key('mc2-video-toggle'),
                            iconSize: 56,
                            color: Colors.white,
                            tooltip: s.playing ? t.md1Pause : t.md1Play,
                            onPressed: () => _toggle(s),
                            icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SafeArea(
                          top: false,
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                            child: Row(children: [
                              Text(localDigits(videoTimeLabel(Duration(milliseconds: posMs.round())), lang),
                                  key: const Key('mc2-video-pos'),
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                              Expanded(
                                child: Slider(
                                  key: const Key('mc2-video-seek'),
                                  value: durMs <= 0 ? 0 : posMs.clamp(0, durMs),
                                  max: durMs <= 0 ? 1 : durMs,
                                  onChanged: durMs <= 0 ? null : (v) => setState(() => _dragMs = v),
                                  onChangeEnd: durMs <= 0
                                      ? null
                                      : (v) async {
                                          await c.seekTo(Duration(milliseconds: v.round()));
                                          if (mounted) setState(() => _dragMs = null);
                                        },
                                ),
                              ),
                              Text(localDigits(videoTimeLabel(s.duration), lang),
                                  key: const Key('mc2-video-dur'),
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                              IconButton(
                                key: const Key('mc2-video-mute'),
                                color: Colors.white,
                                tooltip: s.muted ? t.mc2Unmute : t.mc2Mute,
                                onPressed: () => c.setMuted(!s.muted),
                                icon: Icon(s.muted ? Icons.volume_off : Icons.volume_up),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  ]),
                );
              },
            ),
    );
  }

  Widget _loading(AppLocalizations t) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: Gap.md),
          Text(t.mc2VideoLoading, style: const TextStyle(color: Colors.white70)),
        ]),
      );

  Widget _error(AppLocalizations t) => Center(
        key: const Key('mc2-video-error'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_outlined, color: Colors.white70, size: 48),
            const SizedBox(height: Gap.md),
            Text(t.mc2VideoFailed,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const Key('mc2-video-open-with'),
              onPressed: _openElsewhere,
              icon: const Icon(Icons.open_in_new),
              label: Text(t.mc2OpenWith),
            ),
          ]),
        ),
      );
}
