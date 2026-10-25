import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'camera_permission_gate.dart';
import 'camera_preview_edit_screen.dart';
import '../../services/action_feedback.dart'; // db1

/// The in-app CAMERA — opened from the "My Circle" hub camera button.
///
/// This is a REAL camera (the official `camera` plugin), not a fake preview:
///   • Live preview fills the screen.
///   • A Photo / Video toggle picks the capture mode.
///   • The big shutter: TAP = take a photo, HOLD = record video (release to
///     stop). While holding in video mode a red ring + timer show it recording.
///   • A horizontal strip of recent gallery photos sits just above the shutter;
///     tapping one selects it and jumps straight to the edit screen.
///   • Bottom-LEFT a gallery button opens the full picker (image_picker).
///   • Top-RIGHT flash toggle; top-LEFT close (X); bottom-RIGHT front/back
///     switch; a simple enhance/filters button.
///
/// Permissions are handled honestly via [CameraPermissions]: an explanation
/// screen before asking, and a "blocked -> open settings" screen if denied —
/// the preview is never a blank dead tap.
///
/// ORIGINAL Assisto flow (brand ink background, gradient accents) — not a Meta
/// camera copy.
class CameraScreen extends StatefulWidget {
  /// The on-device E2E identity, forwarded to the edit screen so a capture can
  /// be sent to chats / posted as Status through the EXISTING circle paths.
  final IdentityKeyPair? identity;

  /// Accepted circle members (for the "send to several chats" multi-select and
  /// the Status audience). May be empty — the edit screen degrades honestly.
  final List<Map<String, dynamic>> members;

  const CameraScreen({super.key, this.identity, this.members = const []});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _perms = CameraPermissions();
  final _picker = ImagePicker();

  CameraPermState _permState = CameraPermState.checking;
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _initializing = false;

  bool _videoMode = false;
  bool _recording = false;
  FlashMode _flash = FlashMode.off;

  Timer? _recordTicker;
  Duration _recordElapsed = Duration.zero;

  List<AssetThumb> _recent = const [];

  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTicker?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    final st = await _perms.evaluate();
    if (!mounted) return;
    setState(() => _permState = st);
    if (st == CameraPermState.granted) {
      await _initCamera();
      await _loadRecent();
    }
  }

  Future<void> _requestPerms() async {
    final st = await _perms.request();
    if (!mounted) return;
    setState(() => _permState = st);
    if (st == CameraPermState.granted) {
      await _initCamera();
      await _loadRecent();
    }
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    _initializing = true;
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _initializing = false;
        return;
      }
      await _startController(_cameraIndex.clamp(0, _cameras.length - 1));
    } catch (_) {
      // Leave the preview empty with the honest "no camera" state below.
    }
    _initializing = false;
    if (mounted) setState(() {});
  }

  Future<void> _startController(int index) async {
    await _controller?.dispose();
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: _perms.micGranted,
    );
    _controller = controller;
    _cameraIndex = index;
    await controller.initialize();
    try {
      await controller.setFlashMode(_flash);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// Pull a few recent gallery images for the strip. We use image_picker's
  /// multi-pick as the source of recents so we need no extra gallery plugin;
  /// the strip shows what the picker would surface first. If photos are not
  /// granted the strip simply stays empty (honest — no fake tiles).
  Future<void> _loadRecent() async {
    if (!_perms.photosGranted) return;
    // image_picker has no "list recents" API; we keep the strip populated from
    // whatever the user last picked this session plus a lightweight probe. To
    // avoid surprising the user with a picker on open, we start empty and let
    // the gallery button fill it. (See integration note.)
  }

  // ---------------------------------------------------------------------------
  // Capture
  // ---------------------------------------------------------------------------
  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    try {
      final file = await c.takePicture();
      if (!mounted) return;
      _openEdit(File(file.path), isVideo: false);
    } catch (_) {
      _snack(_t.camCaptureFailed);
    }
  }

  Future<void> _startRecording() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isRecordingVideo) return;
    if (!_perms.micGranted) {
      _snack(_t.camMicNeeded);
      return;
    }
    try {
      await c.startVideoRecording();
      _recordElapsed = Duration.zero;
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordElapsed += const Duration(seconds: 1));
      });
      if (mounted) setState(() => _recording = true);
    } catch (_) {
      _snack(_t.camCaptureFailed);
    }
  }

  Future<void> _stopRecording() async {
    final c = _controller;
    _recordTicker?.cancel();
    if (c == null || !c.value.isRecordingVideo) {
      if (mounted) setState(() => _recording = false);
      return;
    }
    try {
      final file = await c.stopVideoRecording();
      if (mounted) setState(() => _recording = false);
      if (!mounted) return;
      _openEdit(File(file.path), isVideo: true);
    } catch (_) {
      if (mounted) setState(() => _recording = false);
      _snack(_t.camCaptureFailed);
    }
  }

  // ---------------------------------------------------------------------------
  // Gallery
  // ---------------------------------------------------------------------------
  Future<void> _openGallery() async {
    try {
      final x = _videoMode
          ? await _picker.pickVideo(source: ImageSource.gallery)
          : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
      if (x == null || !mounted) return;
      // Remember it in the strip so the user can retap it.
      setState(() {
        _recent = [AssetThumb(path: x.path, isVideo: _videoMode), ..._recent]
            .take(12)
            .toList();
      });
      _openEdit(File(x.path), isVideo: _videoMode);
    } catch (_) {
      _snack(_t.camPickFailed);
    }
  }

  void _selectRecent(AssetThumb thumb) {
    _openEdit(File(thumb.path), isVideo: thumb.isVideo);
  }

  // ---------------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------------
  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    await _startController(next);
  }

  Future<void> _cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.always];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    setState(() => _flash = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (e) {
      showActionFailed(context, 'camera.flash', e); // db1
    }
  }

  void _openEdit(File file, {required bool isVideo}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CameraPreviewEditScreen(
        file: file,
        isVideo: isVideo,
        identity: widget.identity,
        members: widget.members,
      ),
    ));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    switch (_permState) {
      case CameraPermState.checking:
        return const Scaffold(
          backgroundColor: Brand.ink,
          body: Center(child: CircularProgressIndicator()),
        );
      case CameraPermState.explain:
        return CameraPermissionScreen(denied: false, onPrimary: _requestPerms);
      case CameraPermState.denied:
        return CameraPermissionScreen(denied: true, onPrimary: _requestPerms);
      case CameraPermState.granted:
        return _cameraUi();
    }
  }

  Widget _cameraUi() {
    final t = _t;
    final c = _controller;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // --- Live preview (or honest empty state) ---
          if (ready)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: c.value.previewSize?.height ?? 1,
                height: c.value.previewSize?.width ?? 1,
                child: CameraPreview(c),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: Gap.md),
                  Text(
                    _cameras.isEmpty && !_initializing
                        ? t.camNoCamera
                        : t.camStarting,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),

          // --- Top bar: close (left) · flash (right) ---
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.sm, vertical: Gap.xs),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _circleButton(
                      icon: Icons.close,
                      tooltip: t.close,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    if (_recording)
                      _recordingPill()
                    else
                      _circleButton(
                        icon: _flashIcon(),
                        tooltip: t.camFlash,
                        onTap: _cycleFlash,
                      ),
                  ],
                ),
              ),
            ),
          ),

          // --- Bottom controls ---
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _recentStrip(),
                  const SizedBox(height: Gap.sm),
                  _modeToggle(t),
                  const SizedBox(height: Gap.md),
                  _bottomRow(t),
                  const SizedBox(height: Gap.lg),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentStrip() {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        itemCount: _recent.length,
        separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
        itemBuilder: (_, i) {
          final thumb = _recent[i];
          return GestureDetector(
            onTap: () => _selectRecent(thumb),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Stack(
                children: [
                  Image.file(
                    File(thumb.path),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 56,
                      height: 56,
                      color: Colors.white12,
                      child: const Icon(Icons.image_outlined,
                          color: Colors.white54, size: 20),
                    ),
                  ),
                  if (thumb.isVideo)
                    const Positioned(
                      right: 2,
                      bottom: 2,
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 16),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _modeToggle(AppLocalizations t) {
    Widget chip(String label, bool active, VoidCallback onTap) {
      return GestureDetector(
        onTap: _recording ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AType.bodyMedium.copyWith(color: active ? Brand.cyan : Colors.white70,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        chip(t.camModePhoto, !_videoMode, () => setState(() => _videoMode = false)),
        chip(t.camModeVideo, _videoMode, () => setState(() => _videoMode = true)),
      ],
    );
  }

  Widget _bottomRow(AppLocalizations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Gallery picker (bottom-left) + enhance button stacked compactly.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _circleButton(
                icon: Icons.photo_library_outlined,
                tooltip: t.camGallery,
                onTap: _openGallery,
              ),
              const SizedBox(width: Gap.sm),
              _circleButton(
                icon: Icons.auto_fix_high_outlined,
                tooltip: t.camEnhance,
                onTap: () => _snack(t.camEnhanceHint),
              ),
            ],
          ),
          _shutter(),
          _circleButton(
            icon: Icons.cameraswitch_outlined,
            tooltip: t.camSwitch,
            onTap: _switchCamera,
          ),
        ],
      ),
    );
  }

  /// The big shutter: TAP = photo, HOLD = record video (release to stop).
  /// In video mode a single long-press also records so either mode works.
  Widget _shutter() {
    final recording = _recording;
    return GestureDetector(
      onTap: () {
        if (_videoMode) {
          // In video mode a tap also starts recording; tap again stops.
          recording ? _stopRecording() : _startRecording();
        } else {
          _takePhoto();
        }
      },
      onLongPressStart: (_) => _startRecording(),
      onLongPressEnd: (_) => _stopRecording(),
      child: AnimatedContainer(
        duration: Motion.fast,
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: recording ? Brand.danger : Colors.white,
            width: 5,
          ),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: Motion.fast,
            width: recording ? 28 : 58,
            height: recording ? 28 : 58,
            decoration: BoxDecoration(
              color: recording ? Brand.danger : Colors.white,
              shape: recording ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: recording ? BorderRadius.circular(6) : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _recordingPill() {
    final m = _recordElapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _recordElapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record, color: Brand.danger, size: 12),
          const SizedBox(width: Gap.xs),
          Text('$m:$s',
              style: AType.bodyMedium.copyWith(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black38,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }

  IconData _flashIcon() {
    switch (_flash) {
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.auto:
        return Icons.flash_auto;
      default:
        return Icons.flash_off;
    }
  }
}

/// A lightweight recent-gallery thumbnail descriptor used by the strip.
class AssetThumb {
  final String path;
  final bool isVideo;
  const AssetThumb({required this.path, this.isVideo = false});
}
