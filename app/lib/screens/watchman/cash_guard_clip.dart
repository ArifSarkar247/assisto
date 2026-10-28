import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../cashguard/cashguard_source.dart';
import '../../cashguard/clip_crypto.dart';
import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// cashguard — the 3-5 s clip of a cash alert, opened ON THIS PHONE.
///
/// Flow: GET the envelope (only my wrapped key) -> download the ciphertext
/// from its signed link -> decrypt in a background isolate with this phone's
/// private key -> play the JPEG frames. Nothing is written to disk; closing
/// the sheet drops it from memory. The OWNER's first full watch tells the
/// server, which deletes its copy at once (a family viewer's watch does not).
/// Honest states: still coming / already deleted / not sealed for this phone
/// / damaged / network.
class CashClipSheet extends StatefulWidget {
  final CashGuardSource source;
  final int eventId;
  final bool owner;

  /// Tests / gallery: start with this decoded clip (no network, no crypto).
  final CashClip? preview;
  const CashClipSheet({super.key, required this.source, required this.eventId, required this.owner, this.preview});

  static Future<void> show(BuildContext context, CashGuardSource source, int eventId, bool owner) =>
      showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => CashClipSheet(source: source, eventId: eventId, owner: owner),
      );

  @override
  State<CashClipSheet> createState() => _CashClipSheetState();
}

enum _St { loading, pending, gone, notSealed, failed, ready }

class _CashClipSheetState extends State<CashClipSheet> {
  _St _st = _St.loading;
  String _msg = '';
  CashClip? _clip;
  int _i = 0;
  bool _playing = false;
  bool _reportedViewed = false;
  bool _deletedOnServer = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _clip = widget.preview;
      _st = _St.ready;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clip = null; // dropped from memory — never written anywhere
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _st = _St.loading;
      _msg = '';
    });
    try {
      final env = await widget.source.clip(widget.eventId);
      final status = (env['status'] ?? '').toString();
      if (status == 'pending') {
        if (mounted) setState(() => _st = _St.pending);
        return;
      }
      final url = (env['url'] ?? '').toString();
      final meta = wmMap(env['meta']);
      final bytes = await widget.source.download(url);
      final keys = await widget.source.myKeys();
      CashClip clip;
      try {
        // a small clip opens inline; a real one (~0.3-1 MB) in an isolate
        clip = bytes.length < 64 * 1024
            ? openClip(meta: meta, ciphertext: bytes, keys: keys)
            : await openClipInIsolate(meta: meta, ciphertext: bytes, keys: keys);
      } on ClipOpenError catch (e) {
        if (mounted) {
          setState(() => _st = e.code == 'no_key' ? _St.notSealed : _St.failed);
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _clip = clip;
        _st = _St.ready;
      });
      _play();
    } catch (e) {
      final code = wmStatus(e);
      if (!mounted) return;
      setState(() {
        _msg = wmError(e) ?? '';
        _st = code == 410
            ? _St.gone
            : code == 409
                ? _St.notSealed
                : _St.failed;
      });
    }
  }

  void _play() {
    final c = _clip;
    if (c == null || c.frames.isEmpty) return;
    _timer?.cancel();
    if (_i >= c.frames.length - 1) _i = 0;
    final ms = (1000 / c.fps).round().clamp(60, 1000);
    setState(() => _playing = true);
    _timer = Timer.periodic(Duration(milliseconds: ms), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_i >= c.frames.length - 1) {
        t.cancel();
        setState(() => _playing = false);
        _watchedOnce();
        return;
      }
      setState(() => _i++);
    });
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _playing = false);
  }

  Future<void> _watchedOnce() async {
    if (_reportedViewed || !widget.owner || widget.preview != null) return;
    _reportedViewed = true;
    try {
      final r = await widget.source.clipViewed(widget.eventId);
      if (mounted) setState(() => _deletedOnServer = r['deleted'] == true);
    } catch (_) {
      // best-effort: the server deletes it after 24 h anyway
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    switch (_st) {
      case _St.loading:
        body = _note(context, null, t.cgClipOpening, busy: true);
      case _St.pending:
        body = _note(context, Icons.hourglass_top_rounded, t.cgClipPending,
            action: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry)));
      case _St.gone:
        body = _note(context, Icons.delete_sweep_outlined, _msg.isNotEmpty ? _msg : t.cgClipGone);
      case _St.notSealed:
        body = _note(context, Icons.key_off_outlined, t.cgClipNotSealed);
      case _St.failed:
        body = _note(context, Icons.error_outline_rounded, _msg.isNotEmpty ? _msg : t.cgClipFailed,
            action: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _load,
                child: Text(t.wmRetry)));
      case _St.ready:
        final c = _clip!;
        final secs = c.durationS.round();
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Semantics(
              label: t.cgClipLabel(wmDigits(lang, secs)),
              image: true,
              child: ColoredBox(
                color: Colors.black,
                child: c.frames.isEmpty
                    ? const SizedBox.shrink()
                    : Image.memory(c.frames[_i], fit: BoxFit.contain, gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Center(
                            child: Text(t.cgClipFailed, style: const TextStyle(color: Colors.white)))),
              ),
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: c.frames.length <= 1 ? 1 : _i / (c.frames.length - 1),
            semanticsLabel: t.cgClipProgress,
          ),
          const SizedBox(height: 8),
          Row(children: [
            IconButton.filledTonal(
              iconSize: 28,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: _playing ? t.cgPause : t.cgPlay,
              onPressed: _playing ? _pause : _play,
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(t.cgClipSeconds(wmDigits(lang, secs)),
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            widget.owner
                ? (_deletedOnServer ? t.cgClipDeletedNow : t.cgClipDeleteOnView)
                : t.cgClipViewerNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]);
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.cgDecideTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.lock_rounded, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(t.cgClipE2e, style: Theme.of(context).textTheme.bodySmall)),
          ]),
          const SizedBox(height: 12),
          body,
        ]),
      ),
    );
  }

  Widget _note(BuildContext context, IconData? icon, String text, {bool busy = false, Widget? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(children: [
        if (busy) const CircularProgressIndicator() else Icon(icon, size: 44),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 12), action],
      ]),
    );
  }
}

/// Synthetic frames for tests / the gallery (no camera, no crypto).
CashClip cashClipPreview(List<Uint8List> frames, {double fps = 5}) =>
    CashClip(fps, frames, [for (var i = 0; i < frames.length; i++) i / fps]);
