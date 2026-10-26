import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'media_prep.dart';
import 'media_store.dart';
import 'voice_recorder_sheet.dart';

/// wa-polish2 — WhatsApp's composer mic: while the text box is empty the
/// Send button is a Mic. Press and HOLD to record, RELEASE to send, SLIDE
/// LEFT to cancel; a plain TAP opens the existing hands-free recorder sheet
/// (works for anyone who can't hold). Uses the SAME recorder seam
/// ([recorderFactory]), file location, limits and [MediaDraft] as the attach
/// sheet's voice note — the chat queues it through the same E2E media
/// outbox. No new native code, no new permission (the existing mic one).

/// Slide this far left (logical px) to cancel a held recording.
const double kVoiceCancelDx = 110;

/// Test seam: is the mic permission already granted? (No dialog.)
Future<bool> Function() voiceMicGranted = () async {
  final st = await Permission.microphone.status;
  return st.isGranted || st.isLimited;
};

/// The live state of a held recording — the composer shows [VoiceHoldStrip]
/// in place of the text box while [active].
class VoiceHoldController extends ChangeNotifier {
  bool _active = false;
  Duration _elapsed = Duration.zero;
  double _dragDx = 0;

  bool get active => _active;
  Duration get elapsed => _elapsed;

  /// How far the finger slid left (<= 0).
  double get dragDx => _dragDx;

  /// 0..1 of the way to a cancel.
  double get cancelProgress => (-_dragDx / kVoiceCancelDx).clamp(0.0, 1.0);

  /// Gallery / tests: show a recording state without a recorder.
  @visibleForTesting
  void debugShow({Duration elapsed = Duration.zero, double dragDx = 0}) =>
      _set(active: true, elapsed: elapsed, dragDx: dragDx);

  void _set({bool? active, Duration? elapsed, double? dragDx}) {
    _active = active ?? _active;
    _elapsed = elapsed ?? _elapsed;
    _dragDx = dragDx ?? _dragDx;
    notifyListeners();
  }
}

class VoiceHoldMic extends StatefulWidget {
  const VoiceHoldMic({
    super.key,
    required this.controller,
    required this.onDraft,
    required this.onTap,
    this.onRecording,
    this.enabled = true,
  });

  final VoiceHoldController controller;

  /// A finished voice note (>= [kVoiceMin]) to queue like the attach sheet's.
  final Future<void> Function(MediaDraft draft) onDraft;

  /// Plain tap: the hands-free recorder sheet.
  final VoidCallback onTap;

  /// calls-presence: "recording audio…" for the other side.
  final ValueChanged<bool>? onRecording;
  final bool enabled;

  @override
  State<VoiceHoldMic> createState() => _VoiceHoldMicState();
}

class _VoiceHoldMicState extends State<VoiceHoldMic> {
  RecorderBackend? _rec;
  StreamSubscription<double>? _amp;
  Timer? _tick;
  final _sw = Stopwatch();
  final List<int> _levels = [];
  String _path = '';
  bool _holding = false; // finger down (long-press accepted)
  bool _started = false; // recorder really running
  bool _done = false; // finished / cancelled — ignore further events
  bool _signalled = false;

  VoiceHoldController get _c => widget.controller;

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    if (_started && !_done) {
      _done = true;
      unawaited(_quietDiscard());
    }
    _signal(false);
    super.dispose();
  }

  void _signal(bool on) {
    if (on == _signalled) return;
    _signalled = on;
    try {
      widget.onRecording?.call(on);
    } catch (e) {
      reportNonFatal('cp_voice_activity', e);
    }
  }

  Future<void> _onHoldStart() async {
    if (!widget.enabled || (_started && !_done)) return;
    final t = AppLocalizations.of(context);
    _holding = true; // set at once: a quick release before the checks wins
    bool granted;
    try {
      granted = await voiceMicGranted();
    } catch (e) {
      reportNonFatal('wa2_mic_status', e);
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      // the existing explain-then-ask flow; the user holds again after
      _holding = false;
      await ensureMediaPermission(context, Permission.microphone,
          title: t.md1PermMicTitle, body: t.md1PermMicBody, denied: t.md1PermDeniedMic);
      return;
    }
    if (!_holding) return; // already let go
    _done = false;
    _levels.clear();
    _c._set(active: true, elapsed: Duration.zero, dragDx: 0);
    unawaited(HapticFeedback.selectionClick());
    try {
      final rec = recorderFactory();
      _rec = rec;
      _path = '${(await MediaDirs.sub('out')).path}/${newMediaId()}.m4a';
      await rec.start(_path);
      _started = true;
      if (_done) {
        // slid to cancel while the recorder was still starting
        await _quietDiscard();
        return;
      }
      _sw
        ..reset()
        ..start();
      _signal(true);
      _amp = rec.amplitude().listen((db) => _levels.add(levelFromDb(db)));
      _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || _done) return;
        if (_sw.elapsed >= kVoiceMax) {
          unawaited(_finish());
        } else {
          _c._set(elapsed: _sw.elapsed);
        }
      });
      // released (or slid away) while the recorder was still starting
      if (!_holding && !_done) unawaited(_finish());
    } catch (e) {
      reportNonFatal('wa2_voice_hold', e);
      _done = true;
      _holding = false;
      _c._set(active: false);
      if (mounted) _toast(t.md1VoiceFailed);
    }
  }

  void _onMove(LongPressMoveUpdateDetails d) {
    if (!_holding || _done) return;
    final dx = d.offsetFromOrigin.dx.clamp(-kVoiceCancelDx * 1.5, 0.0);
    _c._set(dragDx: dx);
    if (dx <= -kVoiceCancelDx) unawaited(_cancel());
  }

  void _onRelease() {
    if (!_holding) return;
    _holding = false;
    if (_started && !_done) unawaited(_finish());
  }

  Future<void> _stopCommon() async {
    _done = true;
    _holding = false;
    _tick?.cancel();
    await _amp?.cancel();
    _amp = null;
    _sw.stop();
    _signal(false);
    _c._set(active: false, dragDx: 0);
  }

  Future<void> _quietDiscard() async {
    try {
      await _rec?.cancel();
    } catch (e) {
      reportNonFatal('md1_voice_cancel', e);
    }
    _deleteQuietly(_path);
    try {
      await _rec?.dispose();
    } catch (e) {
      reportNonFatal('md1_voice_dispose', e);
    }
    _rec = null;
    _started = false;
  }

  Future<void> _cancel() async {
    if (_done) return;
    await _stopCommon();
    unawaited(HapticFeedback.lightImpact());
    await _quietDiscard();
    if (mounted) _toast(AppLocalizations.of(context).wa2VoiceDiscarded);
  }

  Future<void> _finish() async {
    if (_done) return;
    final elapsed = _sw.elapsed;
    await _stopCommon();
    String? path;
    try {
      path = await _rec?.stop();
    } catch (e) {
      reportNonFatal('md1_voice_stop', e);
    }
    try {
      await _rec?.dispose();
    } catch (e) {
      reportNonFatal('md1_voice_dispose', e);
    }
    _rec = null;
    _started = false;
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    path ??= _path;
    final f = File(path);
    if (elapsed < kVoiceMin || !f.existsSync() || f.lengthSync() == 0) {
      _deleteQuietly(path);
      _toast(t.md1VoiceTooShort);
      return;
    }
    await widget.onDraft(MediaDraft(
      kind: 'voice',
      path: path,
      name: 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      mime: 'audio/mp4',
      size: f.lengthSync(),
      durationMs: elapsed.inMilliseconds,
      wave: compactWave(_levels),
    ));
  }

  void _deleteQuietly(String p) {
    try {
      if (p.isNotEmpty && File(p).existsSync()) File(p).deleteSync();
    } catch (e) {
      reportNonFatal('md1_voice_cleanup', e);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final rec = _c.active;
        return Semantics(
          button: true,
          enabled: widget.enabled,
          label: t.wa2MicLabel,
          hint: t.wa2MicHint,
          onTap: widget.enabled ? widget.onTap : null,
          excludeSemantics: true,
          child: GestureDetector(
            key: const Key('wa2-mic'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onTap : null,
            onLongPressStart: widget.enabled ? (_) => _onHoldStart() : null,
            onLongPressMoveUpdate: widget.enabled ? _onMove : null,
            onLongPressEnd: widget.enabled ? (_) => _onRelease() : null,
            onLongPressCancel: widget.enabled ? _onRelease : null,
            child: SizedBox(
              width: kMinInteractiveDimension,
              height: kMinInteractiveDimension,
              child: Center(
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: rec ? kMinInteractiveDimension : 40,
                  height: rec ? kMinInteractiveDimension : 40,
                  decoration: BoxDecoration(
                    color: widget.enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.mic_rounded,
                      color: widget.enabled
                          ? scheme.onPrimary
                          : scheme.onSurface.withValues(alpha: 0.38)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shown in place of the text box while a held recording runs: red dot, the
/// time (Bangla digits in bn) and "‹ Slide to cancel" that follows the finger.
class VoiceHoldStrip extends StatelessWidget {
  const VoiceHoldStrip({super.key, required this.controller});
  final VoiceHoldController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Container(
        key: const Key('wa2-rec-strip'),
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(children: [
          Icon(Icons.fiber_manual_record_rounded, color: scheme.error, size: 14),
          const SizedBox(width: Gap.sm),
          Text(
            notifLocalizeDigits(
                context, mediaDurationLabel(controller.elapsed.inMilliseconds)),
            key: const Key('wa2-rec-time'),
            style: TextStyle(
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: ClipRect(
              child: Transform.translate(
                offset: Offset(controller.dragDx * 0.6, 0),
                child: Opacity(
                  opacity: 1 - controller.cancelProgress * 0.6,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(Icons.chevron_left_rounded,
                          size: 20, color: scheme.onSurfaceVariant),
                      Flexible(
                        child: Text(t.wa2SlideToCancel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // a11y1: onSurfaceVariant on this strip was 4.45:1.
                            style: TextStyle(color: scheme.onSurface)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
