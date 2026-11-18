// flag-cctv-e2e — the alert card's ONE photo, honest on a slow or broken
// network. Before: Image.network with no loading state (a blank box on 2G)
// and ANY failure said "The photo was deleted after the keep period" — also
// when the phone was simply offline. Now:
//   loading  -> a progress bar (bytes when known) + "slow network" after 3 s
//   network  -> "did not load" + Try again, and it retries by itself
//               (5 s, 15 s, 30 s) so the photo appears once the network is back
//   gone     -> the old "deleted after the keep period" ONLY when the server
//               answered 403 / 404 / 410 (the signed link expired / removed)
// The picture is decoded at card width (cacheWidth) — less memory on 2 GB
// phones.
// cctv-preview: with [AlertSnapshot.previewUrl] (the server's <= 20 KB
// version of the same signed photo) the small picture shows FIRST and the
// full photo replaces it when it arrives — on 2G the alert is readable in
// seconds; a full photo that fails keeps the preview + a small Try again.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class AlertSnapshot extends StatefulWidget {
  final String url;

  /// cctv-preview: the small (<= 20 KB) version, shown first.
  final String? previewUrl;

  /// Tests: a fake image instead of the network.
  final ImageProvider? debugImage;
  final ImageProvider? debugPreview;

  /// cctv-preview: the emulator flow times the phases ('preview', 'full',
  /// 'failed') to the millisecond. Never set in the shipped app.
  static void Function(String phase)? debugOnPhase;

  /// Automatic retries after a network error (seconds after each failure).
  static List<int> retryAfterS = const [5, 15, 30];

  /// How long before "slow network" shows under the progress bar.
  static Duration slowAfter = const Duration(seconds: 3);

  const AlertSnapshot(
      {super.key, required this.url, this.previewUrl, this.debugImage, this.debugPreview});

  @override
  State<AlertSnapshot> createState() => _AlertSnapshotState();
}

enum _SnapState { loading, shown, failed, gone }

class _AlertSnapshotState extends State<AlertSnapshot> {
  int _attempt = 0;
  int _autoTries = 0;
  bool _slow = false;
  Timer? _slowTimer;
  Timer? _retryTimer;
  _SnapState _state = _SnapState.loading;
  ImageProvider? _last; // the exact (resized) provider on screen
  bool _previewShown = false;

  bool get _hasPreview =>
      widget.debugPreview != null || (widget.previewUrl ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _armSlow();
  }

  @override
  void didUpdateWidget(AlertSnapshot old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _retry(auto: false);
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  void _armSlow() {
    _slowTimer?.cancel();
    _slow = false;
    _slowTimer = Timer(AlertSnapshot.slowAfter, () {
      if (mounted && _state == _SnapState.loading) setState(() => _slow = true);
    });
  }

  void _retry({required bool auto}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) return;
    if (!auto) _autoTries = 0;
    // drop the failed copy from the image cache, then fetch again
    final p = _last;
    if (p != null) unawaited(p.evict()); // evict never throws for a cached key
    setState(() {
      _attempt++;
      _state = _SnapState.loading;
    });
    _armSlow();
  }

  ImageProvider _provider() => widget.debugImage ?? NetworkImage(widget.url);

  void _onError(Object error) {
    final code = error is NetworkImageLoadException ? error.statusCode : 0;
    final gone = code == 403 || code == 404 || code == 410;
    // set after the frame: errorBuilder runs during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final want = gone ? _SnapState.gone : _SnapState.failed;
      if (_state != want) {
        AlertSnapshot.debugOnPhase?.call('failed');
        setState(() => _state = want);
      }
      if (!gone && _autoTries < AlertSnapshot.retryAfterS.length && _retryTimer == null) {
        final wait = AlertSnapshot.retryAfterS[_autoTries++];
        _retryTimer = Timer(Duration(seconds: wait), () {
          _retryTimer = null;
          _retry(auto: true);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth.isFinite ? (box.maxWidth * dpr).round().clamp(320, 1280).toInt() : 960;
      final full = Image(
          key: ValueKey('wm-snap-img-$_attempt'),
          image: _last = ResizeImage.resizeIfNeeded(w, null, _provider()),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, sync) {
            if (frame == null) return _loading(t, cs, null);
            if (_state != _SnapState.shown) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _state != _SnapState.shown) {
                  _slowTimer?.cancel();
                  AlertSnapshot.debugOnPhase?.call('full');
                  setState(() => _state = _SnapState.shown);
                }
              });
            }
            return KeyedSubtree(key: const ValueKey('wm-snap-ok'), child: child);
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final total = progress.expectedTotalBytes;
            return _loading(t, cs, total == null || total == 0
                ? null
                : progress.cumulativeBytesLoaded / total);
          },
          errorBuilder: (context, error, _) {
            _onError(error);
            final code = error is NetworkImageLoadException ? error.statusCode : 0;
            if (code == 403 || code == 404 || code == 410) return _gone(t, cs);
            return _failed(t, cs);
          },
        );
      return Semantics(
        label: t.wmSnapshotLabel,
        image: true,
        child: !_hasPreview
            ? full
            : Stack(fit: StackFit.expand, children: [
                if (_state != _SnapState.shown) _preview(),
                full,
              ]),
      );
    });
  }

  /// cctv-preview: the small photo under the full one (transparent until it
  /// has a frame; a failed preview just stays out of the way).
  Widget _preview() => Image(
        key: const ValueKey('wm-snap-preview-img'),
        image: widget.debugPreview ?? NetworkImage(widget.previewUrl!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, sync) {
          if (frame == null) return const SizedBox.expand();
          if (!_previewShown) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_previewShown) {
                AlertSnapshot.debugOnPhase?.call('preview');
                setState(() => _previewShown = true);
              }
            });
          }
          return KeyedSubtree(key: const ValueKey('wm-snap-preview'), child: child);
        },
        errorBuilder: (context, error, _) => const SizedBox.expand(),
      );

  Widget _loading(AppLocalizations t, ColorScheme cs, double? value) => _previewShown
      // the preview is readable: only a thin bar says the full photo comes
      ? Align(
          key: const ValueKey('wm-snap-loading-full'),
          alignment: Alignment.bottomCenter,
          child: LinearProgressIndicator(value: value, minHeight: 3),
        )
      : Container(
        key: const ValueKey('wm-snap-loading'),
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 160, child: LinearProgressIndicator(value: value)),
          if (_slow) ...[
            const SizedBox(height: 10),
            Text(t.caeSnapSlow,
                key: const ValueKey('wm-snap-slow'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ]),
      );

  Widget _failed(AppLocalizations t, ColorScheme cs) => _previewShown
      // keep the preview; a small retry for the sharp photo
      ? Align(
          key: const ValueKey('wm-snap-error'),
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton.tonalIcon(
              key: const ValueKey('wm-snap-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.wmRetry),
              onPressed: () => _retry(auto: false),
            ),
          ),
        )
      : Container(
        key: const ValueKey('wm-snap-error'),
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.wifi_off_rounded, color: cs.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(t.caeSnapFailed, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('wm-snap-retry'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.wmRetry),
              onPressed: () => _retry(auto: false),
            ),
          ]),
        ),
      );

  Widget _gone(AppLocalizations t, ColorScheme cs) => Container(
        key: const ValueKey('wm-snap-gone'),
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: Text(t.wmSnapshotGone, textAlign: TextAlign.center),
      );
}
