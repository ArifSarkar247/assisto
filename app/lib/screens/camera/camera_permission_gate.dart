import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';

/// What the camera screen needs before it can show a live preview.
///
/// We request CAMERA always; MIC is needed for video recording; PHOTOS is
/// needed for the recent-gallery strip + the full picker. We ask for all three
/// up front so the shutter (photo + hold-to-record), the strip, and the gallery
/// button all work without a mid-flow permission wall.
enum CameraPermState {
  /// Still deciding / requesting — show a spinner.
  checking,

  /// We have not asked yet (or the user tapped "Not now"): show the friendly
  /// explanation screen with a "Continue" button that triggers the request.
  explain,

  /// Camera granted — the live preview can run. (Mic/photos may still be
  /// limited; the screen degrades those features honestly.)
  granted,

  /// Camera permanently denied (or restricted): the OS will no longer show the
  /// system prompt, so we route the user to app settings.
  denied,
}

/// A small, dependency-light wrapper over permission_handler so the camera
/// screen never has to care about platform quirks. It only decides the CAMERA
/// gate (preview is impossible without it); mic + photos are soft and reported
/// separately so the UI can degrade (e.g. disable hold-to-record) honestly.
class CameraPermissions {
  /// True once the camera permission is granted (live preview allowed).
  bool get cameraGranted => _camera.isGranted;

  /// True when the microphone is available (video records audio).
  bool get micGranted => _mic.isGranted;

  /// True when we may read the photo library (gallery strip + picker).
  bool get photosGranted => _photos.isGranted || _photos == PermissionStatus.limited;

  PermissionStatus _camera = PermissionStatus.denied;
  PermissionStatus _mic = PermissionStatus.denied;
  PermissionStatus _photos = PermissionStatus.denied;

  /// Refresh the current statuses without prompting (used on resume).
  Future<void> refresh() async {
    _camera = await Permission.camera.status;
    _mic = await Permission.microphone.status;
    _photos = await Permission.photos.status;
  }

  /// Returns the gate state for the CAMERA permission after a passive check.
  Future<CameraPermState> evaluate() async {
    await refresh();
    if (_camera.isGranted) return CameraPermState.granted;
    if (_camera.isPermanentlyDenied || _camera.isRestricted) {
      return CameraPermState.denied;
    }
    return CameraPermState.explain;
  }

  /// Ask the OS for camera (+ mic + photos). Returns the resulting gate state
  /// for the camera permission; call sites read [micGranted]/[photosGranted]
  /// afterwards to decide whether to enable video + the gallery strip.
  Future<CameraPermState> request() async {
    final results = await [
      Permission.camera,
      Permission.microphone,
      Permission.photos,
    ].request();
    _camera = results[Permission.camera] ?? _camera;
    _mic = results[Permission.microphone] ?? _mic;
    _photos = results[Permission.photos] ?? _photos;
    if (_camera.isGranted) return CameraPermState.granted;
    if (_camera.isPermanentlyDenied || _camera.isRestricted) {
      return CameraPermState.denied;
    }
    return CameraPermState.explain;
  }
}

/// The honest "we need the camera" explanation shown BEFORE requesting, and the
/// "camera is blocked" screen shown when it's permanently denied. Both are full
/// screens with a single clear action — never a dead tap or a blank preview.
class CameraPermissionScreen extends StatelessWidget {
  /// true  -> permanently denied: button opens system app settings.
  /// false -> first-ask/explain: button triggers the runtime request.
  final bool denied;
  final VoidCallback onPrimary;

  const CameraPermissionScreen({
    super.key,
    required this.denied,
    required this.onPrimary,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Brand.ink,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: t.close,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: Brand.gradient,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    denied ? Icons.no_photography_outlined : Icons.photo_camera_outlined,
                    size: 44,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: Gap.xl),
                Text(
                  denied ? t.camPermBlockedTitle : t.camPermTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: Gap.md),
                Text(
                  denied ? t.camPermBlockedBody : t.camPermBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: Gap.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: Gap.md),
                    ),
                    onPressed: denied ? openAppSettings : onPrimary,
                    icon: Icon(denied ? Icons.settings_outlined : Icons.check),
                    label: Text(
                      denied ? t.camPermOpenSettings : t.continueWord,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (!denied) ...[
                  const SizedBox(height: Gap.sm),
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      t.notNow,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
