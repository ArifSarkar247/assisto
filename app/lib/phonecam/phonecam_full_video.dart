import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../cashguard/clip_crypto.dart' show ClipOpenError;
import '../l10n/app_localizations.dart';
import '../messaging/media/video_ctl.dart';
import '../screens/watchman/watchman_source.dart';
import 'phonecam_clips.dart';

/// cctvplay — the "full video from the camera phone" panel inside the alert
/// clip sheet. Honest limits first (length, size, this month's budget left,
/// camera phone online or not, 24 h keep), then one button. While the camera
/// phone answers (its heartbeat is every 10 s) the panel checks every 4 s for
/// up to ~3 minutes; the video is opened ON THIS PHONE (isolate), played from
/// a temp file and the file is deleted when the sheet closes.
class PhoneCamFullVideo extends StatefulWidget {
  final PhoneCamClipSource source;
  final int eventId;

  /// The "full" block of the preview envelope (saves one call), if any.
  final Map<String, dynamic>? initial;

  /// Tests: how often / how long to check while the phone answers.
  final Duration every;
  final int maxChecks;

  /// Tests: where the opened video is written while it plays.
  final Future<Directory> Function()? tempDir;

  /// item 4: a recorded minute instead of an alert's clip.
  final String? title;
  final int defaultSeconds;
  const PhoneCamFullVideo(
      {super.key,
      required this.source,
      required this.eventId,
      this.initial,
      this.every = const Duration(seconds: 4),
      this.maxChecks = 45,
      this.tempDir,
      this.title,
      this.defaultSeconds = kPhoneClipSeconds});

  @override
  State<PhoneCamFullVideo> createState() => _PhoneCamFullVideoState();
}

enum _F { loading, idle, ready, asking, waiting, waitingLong, opening, playing, missing, expired, failed, notSealed, blocked }

class _PhoneCamFullVideoState extends State<PhoneCamFullVideo> {
  _F _st = _F.loading;
  Map<String, dynamic> _s = const {};
  String _msg = '';
  Timer? _poll;
  int _checks = 0;
  VideoCtl? _ctl;
  File? _tmp;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null && init.isNotEmpty) {
      _s = init;
      _st = _stateFor(init, waiting: false);
      if (_st == _F.waiting) _schedule();
    } else {
      _refresh(waiting: false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    final c = _ctl;
    _ctl = null;
    if (c != null) unawaited(c.dispose());
    final f = _tmp;
    _tmp = null;
    if (f != null) {
      // never kept: the plain video lives only while the sheet is open
      unawaited(f.delete().then((_) {}, onError: (_) {}));
    }
    super.dispose();
  }

  _F _stateFor(Map<String, dynamic> s, {required bool waiting}) =>
      switch ((s['status'] ?? 'none').toString()) {
        // someone waiting for it -> open at once; else one tap to play
        'ready' => waiting ? _F.opening : _F.ready,
        'requested' => _checks >= widget.maxChecks ? _F.waitingLong : _F.waiting,
        'missing' => _F.missing,
        'expired' => _F.expired,
        _ => _F.idle,
      };

  /// [waiting]: this screen asked and is waiting -> a ready video opens.
  void _apply(Map<String, dynamic> s, {bool waiting = true}) {
    final st = _stateFor(s, waiting: waiting);
    setState(() {
      _s = s;
      _st = st;
    });
    if (st == _F.waiting) _schedule();
    if (st == _F.opening) unawaited(_open());
  }

  void _schedule() {
    _poll?.cancel();
    _poll = Timer(widget.every, () async {
      if (!mounted) return;
      _checks++;
      await _refresh();
    });
  }

  Future<void> _refresh({bool waiting = true}) async {
    try {
      final s = await widget.source.fullState(widget.eventId);
      if (!mounted) return;
      _apply(s, waiting: waiting);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    final code = wmStatus(e);
    setState(() {
      _msg = wmError(e) ?? '';
      _st = (code == 402 || code == 404) ? _F.blocked : _F.failed;
    });
  }

  Future<void> _ask() async {
    setState(() {
      _st = _F.asking;
      _checks = 0;
    });
    try {
      final s = await widget.source.requestFull(widget.eventId);
      if (!mounted) return;
      _apply(s);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _open() async {
    final url = (_s['url'] ?? '').toString();
    if (url.isEmpty) {
      setState(() => _st = _F.failed);
      return;
    }
    if (_s['sealed_for_you'] == false) {
      setState(() => _st = _F.notSealed);
      return;
    }
    setState(() => _st = _F.opening);
    try {
      final ct = await widget.source.download(url);
      final keys = await widget.source.myKeys();
      final Uint8List mp4;
      try {
        mp4 = await openVideoInIsolate(meta: wmMap(_s['meta']), ciphertext: ct, keys: keys);
      } on ClipOpenError catch (e) {
        if (mounted) setState(() => _st = e.code == 'no_key' ? _F.notSealed : _F.failed);
        return;
      }
      if (!mounted) return;
      final dir = await (widget.tempDir ?? getTemporaryDirectory)();
      final f = File('${dir.path}/pcfull_${widget.eventId}_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await f.writeAsBytes(mp4, flush: true);
      _tmp = f;
      final c = await VideoCtls.factory(f);
      await c.init();
      if (!mounted) {
        await c.dispose();
        try {
          await f.delete();
        } catch (_) {}
        return;
      }
      _ctl = c;
      setState(() => _st = _F.playing);
      // item 4: a recorded segment starts at the second the viewer picked
      final t = (_s['t'] as num?)?.toInt();
      final s0 = (wmMap(_s['meta'])['start_ts'] as num?)?.toInt();
      if (t != null && s0 != null && t > s0) await c.seekTo(Duration(seconds: t - s0 - 2 < 0 ? 0 : t - s0 - 2));
      await c.play();
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final tt = Theme.of(context).textTheme;
    final b = wmMap(_s['budget']);
    final secs = ((_s['clip_s'] as num?) ?? widget.defaultSeconds).toInt();
    final mb = ((_s['est_mb'] as num?) ?? 1.5).toDouble();
    final keepH = ((_s['keep_h'] as num?) ?? 24).toInt();
    final online = _s['camera_online'] == true;
    final limits = <Widget>[
      Text(t.pcpFullLimits(wmDigits(lang, secs), wmDigits(lang, mb.toStringAsFixed(1)), wmDigits(lang, keepH)),
          style: tt.bodySmall),
      if (b.isNotEmpty && ((b['cap_mb'] as num?) ?? 0) > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              t.pcpBudgetLeft(wmDigits(lang, ((b['left_mb'] as num?) ?? 0).round()),
                  wmDigits(lang, ((b['cap_mb'] as num?) ?? 0).round())),
              style: tt.bodySmall),
        ),
      if (_st == _F.idle || _st == _F.waiting || _st == _F.waitingLong || _st == _F.asking)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Icon(online ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text(online ? t.pcpCamOnline : t.pcpCamOffline, style: tt.bodySmall)),
          ]),
        ),
    ];
    Widget ask(String label) => FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.download_rounded),
          label: Text(label),
          onPressed: _ask,
        );
    Widget body;
    switch (_st) {
      case _F.loading:
      case _F.asking:
      case _F.opening:
        body = Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 12),
          Expanded(child: Text(_st == _F.opening ? t.pcpOpening : t.pcpWaiting)),
        ]);
      case _F.idle:
        body = Align(alignment: AlignmentDirectional.centerStart, child: ask(t.pcpGetFull));
      case _F.ready:
        body = Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(t.pcpPlayFull),
              onPressed: () => _refresh(),
            ));
      case _F.waiting:
        body = Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 12),
          Expanded(child: Text(t.pcpWaiting)),
        ]);
      case _F.waitingLong:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.pcpWaitingLong),
          const SizedBox(height: 8),
          OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: () {
                _checks = 0;
                _refresh();
              },
              child: Text(t.wmRetry)),
        ]);
      case _F.missing:
        body = Text(t.pcpMissing);
      case _F.expired:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.pcpExpired),
          const SizedBox(height: 8),
          ask(t.pcpGetFull),
        ]);
      case _F.notSealed:
        body = Text(t.cgClipNotSealed);
      case _F.blocked:
        body = Text(_msg.isNotEmpty ? _msg : t.pcpFailed);
      case _F.failed:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_msg.isNotEmpty ? _msg : t.pcpFailed),
          const SizedBox(height: 8),
          OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: _refresh,
              child: Text(t.wmRetry)),
        ]);
      case _F.playing:
        body = _player(t);
    }
    return Semantics(
      container: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.title ?? t.pcpFullTitle, style: tt.titleSmall),
        const SizedBox(height: 4),
        ...limits,
        const SizedBox(height: 10),
        body,
      ]),
    );
  }

  Widget _player(AppLocalizations t) {
    final c = _ctl;
    if (c == null) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoCtlState>(
      valueListenable: c.state,
      builder: (context, v, _) {
        final total = v.duration.inMilliseconds;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: v.aspect,
            child: ColoredBox(color: Colors.black, child: c.view()),
          ),
          if (v.error.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(t.pcpFailed)),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: total <= 0 ? 0 : (v.position.inMilliseconds / total).clamp(0.0, 1.0),
            semanticsLabel: t.cgClipProgress,
          ),
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: IconButton.filledTonal(
              iconSize: 28,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: v.playing ? t.cgPause : t.cgPlay,
              onPressed: () async {
                if (v.playing) {
                  await c.pause();
                } else {
                  if (v.ended) await c.seekTo(Duration.zero);
                  await c.play();
                }
              },
              icon: Icon(v.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
          ),
        ]);
      },
    );
  }
}
