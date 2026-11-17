/// lpaudio — IELTS listening like the real computer-delivered test: recorded
/// audio (made by our own open-source TTS in CI, several voices per
/// conversation), streamed from a signed link or played from the offline
/// download. EXAM mode: one Start tap, then for every part — time to read the
/// questions (countdown) -> the recording plays ONCE (no pause) -> time to check
/// -> the next part starts by itself; after the last part the learner checks
/// and submits. PRACTICE mode: play / pause / replay, then "Next part".
/// The phone never gets the script or the answers (server keeps them).
/// No ads here (lp2_ads_test). Audio only via AudioRouteService.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../audio/audio_route_service.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/local_digits.dart';
import 'lp_data.dart' show lpList, lpStrs;
import 'lp_engine.dart' show clock;
import 'lp_ui.dart' show lpToast;

/// Tests: replaces the real audio player (no plugin in widget tests).
@visibleForTesting
Future<void> Function(String url)? debugLpPlay;

/// Tests: a scripted player (completion on demand).
@visibleForTesting
LpAudioEngine Function()? debugLpEngine;

/// The few player calls the listening flow needs (real one = audioplayers).
abstract class LpAudioEngine {
  Future<void> load(String src);
  Future<void> play();
  Future<void> pause();
  Future<void> restart();
  Stream<Duration> get position;
  Stream<void> get completed;
  Future<void> dispose();
}

LpAudioEngine lpAudioEngine() {
  if (debugLpEngine != null) return debugLpEngine!();
  if (debugLpPlay != null) return _HookEngine(debugLpPlay!);
  return _PlayerEngine();
}

class _PlayerEngine implements LpAudioEngine {
  AudioPlayer? _p; // LAZY: created on the first load (never at screen open)
  final _pos = StreamController<Duration>.broadcast();
  final _done = StreamController<void>.broadcast();
  final List<StreamSubscription> _subs = [];

  AudioPlayer _player() {
    if (_p != null) return _p!;
    final p = AudioPlayer();
    _subs.add(p.onPositionChanged.listen(_pos.add));
    _subs.add(p.onPlayerComplete.listen((_) => _done.add(null)));
    return _p = p;
  }

  @override
  Future<void> load(String src) async {
    await AudioRouteService.instance.preparePlayback(AudioUse.media);
    await _player().setSource(src.startsWith('http') ? UrlSource(src) : DeviceFileSource(src));
  }

  @override
  Future<void> play() => _player().resume();
  @override
  Future<void> pause() async => _p?.pause();
  @override
  Future<void> restart() async {
    await _player().seek(Duration.zero);
    await _player().resume();
  }

  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _p?.dispose();
    await _pos.close();
    await _done.close();
  }
}

/// Older widget tests: play is a no-op hook and the audio never ends.
class _HookEngine implements LpAudioEngine {
  final Future<void> Function(String url) hook;
  String _src = '';
  _HookEngine(this.hook);
  @override
  Future<void> load(String src) async => _src = src;
  @override
  Future<void> play() => hook(_src);
  @override
  Future<void> pause() async {}
  @override
  Future<void> restart() => hook(_src);
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

enum LpListenPhase { idle, preview, play, check, done }

class LpListenPanel extends StatefulWidget {
  final List<Map<String, dynamic>> parts;
  final int part;
  final bool replay;
  final ValueChanged<int> onPart;
  final ValueChanged<bool>? onRunning;
  const LpListenPanel(
      {super.key, required this.parts, required this.part, required this.replay, required this.onPart, this.onRunning});
  @override
  State<LpListenPanel> createState() => _LpListenPanelState();
}

class _LpListenPanelState extends State<LpListenPanel> {
  LpAudioEngine? _e;
  final List<StreamSubscription> _subs = [];
  Timer? _tick;
  LpListenPhase _phase = LpListenPhase.idle;
  int _at = 0; // the part the recording belongs to
  int _left = 0;
  Duration _pos = Duration.zero;
  bool _playing = false, _failed = false, _ended = false;

  Map<String, dynamic> get _p => widget.parts[_at.clamp(0, widget.parts.length - 1)];
  String _url(Map p) => '${p['audio_url'] ?? ''}';
  bool get _allAudio => widget.parts.isNotEmpty && widget.parts.every((p) => _url(p).isNotEmpty);
  int _sec(Map p, String k, int d) => (p[k] as num?)?.toInt() ?? d;

  @override
  void didUpdateWidget(LpListenPanel old) {
    super.didUpdateWidget(old);
    // practice: the learner picked another part -> its own recording
    if (widget.replay && widget.part != _at) _switchPractice(widget.part);
  }

  @override
  void initState() {
    super.initState();
    _at = widget.part;
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _e?.dispose();
    super.dispose();
  }

  LpAudioEngine _engine() {
    if (_e != null) return _e!;
    final e = lpAudioEngine();
    _subs.add(e.position.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(e.completed.listen((_) => _onComplete()));
    return _e = e;
  }

  void _countdown(int secs, VoidCallback then) {
    _tick?.cancel();
    setState(() => _left = secs);
    if (secs <= 0) return then();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _left--);
      if (_left <= 0) {
        t.cancel();
        then();
      }
    });
  }

  // ------------------------------------------------------------ exam flow
  Future<void> _start() async {
    widget.onRunning?.call(true);
    await _beginPart(0);
  }

  Future<void> _beginPart(int i) async {
    setState(() {
      _at = i;
      _phase = LpListenPhase.preview;
      _pos = Duration.zero;
      _failed = false;
      _ended = false;
    });
    widget.onPart(i);
    try {
      await _engine().load(_url(_p)); // buffers during the question time
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
    if (!mounted) return;
    _countdown(_sec(_p, 'preview_sec', 30), _play);
  }

  Future<void> _play() async {
    final tr = AppLocalizations.of(context);
    final reload = _failed;
    setState(() {
      _phase = LpListenPhase.play;
      _failed = false;
    });
    try {
      if (reload) await _engine().load(_url(_p));
      await _engine().play();
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _playing = false;
        });
        lpToast(context, tr.lp2AudioFail);
      }
    }
  }

  void _onComplete() {
    if (!mounted) return;
    setState(() {
      _playing = false;
      _ended = true;
    });
    if (widget.replay) return; // practice: the learner decides
    setState(() => _phase = LpListenPhase.check);
    final last = _at + 1 >= widget.parts.length;
    _countdown(_sec(_p, 'check_sec', last ? 120 : 30), () {
      if (!mounted) return;
      if (last) {
        setState(() => _phase = LpListenPhase.done);
        widget.onRunning?.call(false);
      } else {
        _beginPart(_at + 1);
      }
    });
  }

  // ------------------------------------------------------------- practice
  Future<void> _switchPractice(int i) async {
    _tick?.cancel();
    await _e?.pause();
    setState(() {
      _at = i;
      _phase = LpListenPhase.idle;
      _playing = false;
      _ended = false;
      _pos = Duration.zero;
    });
  }

  Future<void> _togglePractice() async {
    final tr = AppLocalizations.of(context);
    try {
      if (_playing) {
        await _engine().pause();
        setState(() => _playing = false);
        return;
      }
      if (_phase == LpListenPhase.idle) {
        await _engine().load(_url(_p));
        setState(() => _phase = LpListenPhase.play);
        await _engine().play();
      } else if (_ended) {
        _ended = false;
        await _engine().restart();
      } else {
        await _engine().play();
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) lpToast(context, tr.lp2AudioFail);
    }
  }

  // ---------------------------------------------------------------- view
  String _range(BuildContext context, Map p) {
    final ns = lpList(p['questions']).map((q) => (q['n'] as num?)?.toInt() ?? 0).where((n) => n > 0).toList();
    if (ns.isEmpty) return '';
    ns.sort();
    return '${ld(context, ns.first)}–${ld(context, ns.last)}';
  }

  String _accents(AppLocalizations tr) {
    final a = lpStrs(_p['accents']);
    return [
      if (a.contains('en-GB')) tr.lp2AccentGb,
      if (a.contains('en-US')) tr.lp2AccentUs,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if ((!widget.replay && !_allAudio) ||
        (widget.replay && _url(widget.parts[widget.part.clamp(0, widget.parts.length - 1)]).isEmpty)) {
      return DsCard(
        padding: EdgeInsets.zero,
        child: ListTile(
            key: const Key('lp2-audio-missing'),
            leading: const Icon(Icons.volume_off_rounded),
            title: Text(tr.lp2AudioMissing)),
      );
    }
    final total = widget.parts.length;
    final dur = (_p['duration_sec'] as num?)?.toDouble() ?? 0;
    final frac = dur > 0 ? (_pos.inMilliseconds / 1000 / dur).clamp(0.0, 1.0) : null;
    final accents = _accents(tr);
    final head = tr.lp2ListenPartOf(ld(context, _at + 1), ld(context, total));
    final children = <Widget>[];
    if (!widget.replay && _phase == LpListenPhase.idle) {
      final mins = (widget.parts.fold<double>(0, (a, p) => a + ((p['duration_sec'] as num?)?.toDouble() ?? 0)) / 60).ceil();
      children.addAll([
        Text(tr.lp2ListenIntro, style: AType.bodyMedium),
        if (mins > 0) ...[
          const SizedBox(height: Gap.xs),
          Text(tr.lp2ListenMinutes(ld(context, mins)), style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        ],
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const Key('lp2-listen-start'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
          onPressed: _start,
          icon: const Icon(Icons.headphones_rounded),
          label: Text(tr.lp2ListenStart),
        ),
      ]);
    } else if (!widget.replay) {
      final (String label, IconData icon) = switch (_phase) {
        LpListenPhase.preview => (tr.lp2ListenPreview(_range(context, _p)), Icons.menu_book_rounded),
        LpListenPhase.play => (_failed ? tr.lp2AudioFail : tr.lp2AudioPlaying, Icons.graphic_eq_rounded),
        LpListenPhase.check => (tr.lp2ListenCheck, Icons.fact_check_rounded),
        _ => (tr.lp2ListenDone, Icons.check_circle_rounded),
      };
      children.addAll([
        Row(children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(label,
                  key: const Key('lp2-listen-phase'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600))),
          if (_phase == LpListenPhase.preview || _phase == LpListenPhase.check)
            Text(ld(context, clock(_left)),
                key: const Key('lp2-listen-left'), style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        ]),
        if (_phase == LpListenPhase.play) ...[
          const SizedBox(height: Gap.sm),
          LinearProgressIndicator(value: frac, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          if (_failed) ...[
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              key: const Key('lp2-listen-retry'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
              onPressed: _play,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry),
            ),
          ],
        ],
      ]);
    } else {
      children.add(Row(children: [
        IconButton.filled(
          key: const Key('lp2-play'),
          tooltip: _playing ? tr.lp2Pause : tr.lp2PlayAudio,
          constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
          onPressed: _togglePractice,
          icon: Icon(_playing ? Icons.pause_rounded : (_ended ? Icons.replay_rounded : Icons.play_arrow_rounded)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_playing ? tr.lp2AudioPlaying : tr.lp2PlayAudio,
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
            if (_pos > Duration.zero) Text(ld(context, clock(_pos.inSeconds)), style: AType.bodySmall),
          ]),
        ),
      ]));
      if (_phase != LpListenPhase.idle) {
        children.addAll([
          const SizedBox(height: Gap.sm),
          LinearProgressIndicator(value: frac, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        ]);
      }
      if (_ended && widget.part + 1 < total) {
        children.addAll([
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            key: const Key('lp2-listen-next'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => widget.onPart(widget.part + 1),
            icon: const Icon(Icons.skip_next_rounded),
            label: Text(tr.lp2ListenNextPart),
          ),
        ]);
      }
    }
    return DsSurface(
      color: scheme.ds.cardHigh,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(head, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: Gap.xs),
        ...children,
        const SizedBox(height: Gap.sm),
        Text(widget.replay ? tr.lp2AudioPractice : tr.lp2AudioOnce,
            style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        if (accents.isNotEmpty)
          Text(tr.lp2ListenVoices(accents), style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
      ]),
    );
  }
}
