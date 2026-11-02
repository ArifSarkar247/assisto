import 'dart:ui' show AppLifecycleState;

/// callpip (owner phone test 2 Nov: "Back / Home / Facebook during a video
/// call makes the video disappear"): every decision about leaving the call
/// screen lives here as plain Dart, so CI tests it. The native side
/// (CallsChannel.kt) only executes what these functions decide — Kotlin is
/// compiled only by the daily APK build.

/// Android shrinks the call into picture-in-picture when the user leaves
/// Assisto (Home, Recents, another app, Back on the last screen) — only for a
/// LIVE video call. A voice call keeps running with its notification.
bool wantAutoPip(
        {required bool videoOn, required bool live, required bool ended}) =>
    videoOn && live && !ended;

/// The PiP window's shape (Android's Rational). Android accepts only
/// 1:2.39 … 2.39:1; anything else throws, so we stay strictly inside.
/// The native side clamps each number to 1..100.
class PipAspect {
  const PipAspect(this.w, this.h);
  final int w;
  final int h;

  /// portrait phone video until the remote size is known
  static const PipAspect fallback = PipAspect(9, 16);

  double get ratio => w / h;

  @override
  bool operator ==(Object o) => o is PipAspect && o.w == w && o.h == h;
  @override
  int get hashCode => Object.hash(w, h);
  @override
  String toString() => '$w:$h';
}

const double _maxRatio = 2.38; // Android limit 2.39 (and 1/2.39)
const double _minRatio = 1 / 2.38;

/// The remote video's pixel size -> the PiP shape (WhatsApp: the window has
/// the other person's video shape). Unknown/zero -> 9:16.
PipAspect pipAspectFor(int? videoW, int? videoH) {
  if (videoW == null || videoH == null || videoW <= 0 || videoH <= 0) {
    return PipAspect.fallback;
  }
  var r = videoW / videoH;
  if (r > _maxRatio) r = _maxRatio;
  if (r < _minRatio) r = _minRatio;
  if (r >= 1) {
    return PipAspect(100, (100 / r).round().clamp(43, 100));
  }
  return PipAspect((100 * r).round().clamp(43, 100), 100);
}

/// The buttons inside the PiP window (Android RemoteAction; at most 3 fit
/// on every phone): mute/unmute, camera off/on (video only), end call.
enum PipActionId { mute, camera, end }

class PipAction {
  const PipAction(this.id, {this.on = false});
  final PipActionId id;

  /// mute: true = muted now (button says "Unmute");
  /// camera: true = camera on now (button says "Turn camera off").
  final bool on;

  @override
  bool operator ==(Object o) => o is PipAction && o.id == id && o.on == on;
  @override
  int get hashCode => Object.hash(id, on);
  @override
  String toString() => '${id.name}:${on ? 1 : 0}';
}

List<PipAction> pipActions(
        {required bool muted, required bool videoOn, required bool cameraOn}) =>
    [
      PipAction(PipActionId.mute, on: muted),
      if (videoOn) PipAction(PipActionId.camera, on: cameraOn),
      const PipAction(PipActionId.end),
    ];

/// What the native side gets for the current call; identical states are
/// sent once (every controller tick would otherwise cross the channel).
class PipState {
  const PipState(
      {required this.auto, required this.aspect, required this.actions});
  final bool auto;
  final PipAspect aspect;
  final List<PipAction> actions;

  static const PipState off =
      PipState(auto: false, aspect: PipAspect.fallback, actions: []);

  String get signature => '${auto ? 1 : 0}|$aspect|${actions.join(',')}';
}

PipState pipStateFor({
  required bool videoOn,
  required bool live,
  required bool ended,
  required bool muted,
  required bool cameraOn,
  int? remoteW,
  int? remoteH,
}) {
  final auto = wantAutoPip(videoOn: videoOn, live: live, ended: ended);
  if (!auto) return PipState.off;
  return PipState(
    auto: true,
    aspect: pipAspectFor(remoteW, remoteH),
    actions: pipActions(muted: muted, videoOn: videoOn, cameraOn: cameraOn),
  );
}

// ------------------------------------------------ camera in the background
/// Android blocks the camera for an app in the background (Assisto has no
/// camera foreground service — Play policy). Leaving WITHOUT PiP (voice
/// switch, PiP off in Settings, PiP closed) releases the camera and the
/// other phone shows our avatar — never a frozen frame. In PiP the activity
/// is still visible ([AppLifecycleState.inactive]): the camera stays live.
bool shouldPauseCameraBg({
  required AppLifecycleState state,
  required bool inPip,
  required bool videoOn,
  required bool cameraOn,
  required bool live,
}) =>
    videoOn &&
    cameraOn &&
    live &&
    !inPip &&
    (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached);

/// ... and it comes back on its own as soon as Assisto is visible again
/// (full screen, or the PiP window after the user re-opened it).
bool shouldResumeCameraBg({
  required AppLifecycleState state,
  required bool inPip,
  required bool pausedBg,
}) =>
    pausedBg && (state == AppLifecycleState.resumed || inPip);

// ------------------------------------------- Back on the app's last screen
enum RootBackAction {
  /// no call: the normal Android Back (Assisto closes)
  none,

  /// live video call: shrink into PiP (like WhatsApp), never close
  pip,

  /// voice call (or PiP unavailable): go to the background, call keeps
  /// running with its notification
  background,
}

RootBackAction rootBackAction(
    {required bool callActive, required bool videoLive}) {
  if (!callActive) return RootBackAction.none;
  return videoLive ? RootBackAction.pip : RootBackAction.background;
}

// --------------------------------------------- in-app bar / tile / PiP view
/// What the app-wide call host draws for a MINIMIZED call.
class MiniCallView {
  const MiniCallView({this.bar = false, this.tile = false, this.pip = false});
  final bool bar;
  final bool tile;
  final bool pip;

  @override
  bool operator ==(Object o) =>
      o is MiniCallView && o.bar == bar && o.tile == tile && o.pip == pip;
  @override
  int get hashCode => Object.hash(bar, tile, pip);
  @override
  String toString() => 'bar=$bar tile=$tile pip=$pip';
}

MiniCallView miniCallView(
    {required bool hasCall,
    required bool ended,
    required bool inPip,
    required bool videoOn}) {
  if (!hasCall || ended) return const MiniCallView();
  // Android PiP: the whole (tiny) window is the call's video
  if (inPip) return const MiniCallView(pip: true);
  // inside Assisto: green bar always (voice + video), floating video tile
  // only for video
  return MiniCallView(bar: true, tile: videoOn);
}

/// The small self view inside the PiP window / floating tile: only while
/// my camera really sends (never a black box for a paused camera).
bool showSelfInset(
        {required bool videoOn,
        required bool cameraOn,
        required bool pausedBg,
        required bool cameraUnavailable}) =>
    videoOn && cameraOn && !pausedBg && !cameraUnavailable;
