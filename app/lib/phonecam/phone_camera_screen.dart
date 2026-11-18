import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/material.dart';
import '../widgets/skeleton.dart';
import '../ds/ds.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cashguard/guard_box_engine.dart' show PersonDetect;
import '../cctv/phone_zone_watch.dart';
import '../cashguard/guard_box_model.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../services/error_report.dart';
import '../shop_api.dart';
import '../shop_motion.dart';
import '../theme.dart' show AType, Brand;
import '../widgets/local_digits.dart' show ld;
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/permission_reason.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../screens/shop_live_rtc.dart' deferred as rtc;
import 'phonecam_api.dart';
import 'phonecam_clips.dart';
import 'phonecam_rec_logic.dart';
import 'phonecam_logic.dart';
import '../config.dart'; // guardbox-play
import '../feature_flags.dart'; // cctvbox
import '../ipcam/ipcam_guard_screen.dart'; // cctvbox
import '../ipcam/box_siren.dart'; // cctvbox

/// cctvphone — THIS phone becomes an Assisto camera (owner CCTV order 3 Nov,
/// part A). Built on the Shop Box pieces (device client, motion detector,
/// live-view signaling, the on-phone YOLOX person model) — nothing rewritten.
///
/// Honest by design:
///   * the camera runs only while this screen's run is on (screen dimmed to
///     the minimum, kept awake, plugged in). guardbox-play: the user may turn
///     the screen off — a camera foreground service (PhoneCamService.kt, type
///     camera, started only by Start, a notification with a Stop button, never
///     at boot; Play declaration PLAY_DECL_GUARDBOX_BN.md) takes over the
///     camera while the app is in the background: still frames for the same
///     motion + person check and the alert photo; clips need the screen on.
///     No WorkManager;
///   * a clear "this phone is a camera — recording" banner on the screen and
///     an ongoing notification while it runs;
///   * sound is OFF unless the consent switch on THIS phone is on;
///   * clips stay on this phone (rolling, size-capped); an alert photo, a
///     small SEALED preview of the clip (cctvplay), the full clip only when a
///     viewer asks for it, and a live view the owner opens leave the phone.
/// guardbox-play: the camera foreground service (screen-off watch) is in
/// this build — the website APK always; the Play build only once the owner
/// filed the camera-FGS form (play-decl key `guardbox_camera` in
/// PLAY_DECLARED -> --dart-define=PLAY_CAMERA_FGS=true). Without it the run
/// keeps the screen on, and the screen says so honestly.
const bool kCameraFgsInBuild =
    !AppConfig.playStore || bool.fromEnvironment('PLAY_CAMERA_FGS');

class PhoneCameraScreen extends StatefulWidget {
  /// From the QR App Link (https://lifeassisto.com/pc/<code>): pre-filled.
  final String? initialCode;

  /// Tests / gallery: a canned state, no storage, no camera.
  final PhoneCamPreview? preview;
  const PhoneCameraScreen({super.key, this.initialCode, this.preview});

  /// Tests: fake native channel replies (null = the real channel).
  @visibleForTesting
  static Future<Object?> Function(String method, [Object? args])? debugChannel;

  /// E2E: skip the person model (motion-only alerts — the emulator's fake
  /// camera shows no person). Never set in the app.
  @visibleForTesting
  static bool debugNoPersonModel = false;

  @override
  State<PhoneCameraScreen> createState() => _PhoneCameraScreenState();
}

class PhoneCamPreview {
  /// cctvplay item 4: '' (off) | 'recording' | a pause reason
  final String rec;
  final bool paired;
  final bool running;
  final String camera;
  final String site;
  final int alerts;
  final int clips;
  final int clipMb;
  final bool audio;
  final bool model;
  final List<String> warnings;
  const PhoneCamPreview({
    this.paired = true,
    this.running = false,
    this.camera = '',
    this.site = '',
    this.alerts = 0,
    this.clips = 0,
    this.clipMb = 0,
    this.audio = false,
    this.model = true,
    this.warnings = const [],
    this.rec = '',
  });
}

const _kTok = 'phonecam_token', _kCam = 'phonecam_camera', _kSite = 'phonecam_site';
const _kCamName = 'phonecam_camname';
const _kAudio = 'phonecam_audio', _kCap = 'phonecam_cap_mb';
const _channel = MethodChannel('com.assisto/shopbox');
const _notifId = 7310;
// cctvtoday: 10 s (was 20 s) — a live view the owner opens is picked up on
// the next heartbeat, so the viewer sees video well inside its 35 s wait.
const _heartbeatEvery = Duration(seconds: 10);
const _personCooldown = Duration(seconds: 60);
const _motionOnlyCooldown = Duration(minutes: 3);
const _clipLength = Duration(seconds: 10);
const _maxSnapshotBytes = 200 * 1024;

class _PhoneCameraScreenState extends State<PhoneCameraScreen> with WidgetsBindingObserver {
  static const _secure = FlutterSecureStorage();

  bool _loading = true;
  String? _token;
  int? _cameraId;
  String _siteName = '';
  String _cameraName = '';
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _claiming = false;
  String _pairError = '';

  // settings
  bool _audio = false;
  int _capMb = kClipCapDefaultMb;

  // running
  bool _running = false;
  bool _showControls = true;
  String _status = '';
  CameraController? _cam;
  final _motion = MotionDetector();
  final _dark = DarkMonitor();
  final _zones = PhoneZoneWatch(); // cctvdet: gate / post / dwell zones + tamper
  String? _zonesVer;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false; // snapshot / person check / clip in progress
  DateTime? _lastAlert;
  DateTime? _lastCheck; // a person check at most every 5 s (old phones)
  int _alerts = 0;
  PersonDetect? _detect;
  bool _modelTried = false;
  Timer? _hb;
  Timer? _hideTimer;
  bool _online = false;
  List<String> _warnings = const [];
  bool _inLive = false;
  BoxSiren? _siren; // cctvbox

  // guardbox-play: the camera foreground service + its screen-off watch
  bool _svcOn = false; // PhoneCamService runs (its notification is shown)
  bool _bgOn = false; // the app is in the background: the service has the camera
  Timer? _bgTimer;
  int _bgLastN = -1;
  int _bgRot = 0;
  bool _bgBusy = false;

  // clips on this phone
  int _clipCount = 0;
  int _clipBytes = 0;

  // cctvplay: who previews / full videos are sealed for + pending requests
  PhoneClipCfg _clipCfg = const PhoneClipCfg();
  bool _videoBusy = false;
  int _previewsSent = 0;

  // cctvplay item 4: optional continuous recording (OFF by default)
  bool _recOn = false;
  int _recCapMb = kRecCapDefaultMb;
  String _recReason = '';
  bool _recUnsupported = false;
  bool _segRec = false;
  int _segStartS = 0;
  Timer? _segTimer;
  int _recBytes = 0;
  bool _recBusy = false;
  final Map<String, int> _refTimes = {}; // alert clip ref -> second (continuous mode)
  final List<(int, String)> _pendingPreviews = [];

  ShopDeviceClient? get _dev =>
      _token == null ? null : ShopDeviceClient(_token!, cameraId: _cameraId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.preview == null) {
      // guardbox-play: Stop in the camera notification ends this run too
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'camSvcStopTapped') {
          _svcOn = false;
          if (_running) await _stop();
        }
        return null;
      });
    }
    final c = widget.initialCode;
    if (c != null && c.isNotEmpty) _code.text = normalizePairCode(c) ?? c;
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.preview == null) _channel.setMethodCallHandler(null);
    _stop(silent: true);
    _hideTimer?.cancel();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // the camera belongs to the visible screen: released when we leave,
    // reopened when we come back (no hidden background camera)
    if (!_running) return;
    if (s == AppLifecycleState.paused) {
      if (!_inLive) unawaited(_toBackground());
    } else if (s == AppLifecycleState.resumed) {
      if (!_inLive) unawaited(_toForeground());
    }
  }

  // ------------------------------------------------- guardbox-play (FGS)
  Future<Object?> _native(String method, [Object? args]) {
    final d = PhoneCameraScreen.debugChannel;
    if (d != null) return d(method, args);
    return _channel.invokeMethod<Object?>(method, args);
  }

  /// After Start (the camera is open = permission granted): the camera
  /// foreground service with its notification + Stop button. false = older
  /// build / Android refused: the run still works with the screen on.
  Future<bool> _startCamService() async {
    if (widget.preview != null || !mounted || !kCameraFgsInBuild) return false;
    final t = AppLocalizations.of(context);
    try {
      final ok = await _native('camSvcStart',
              {'title': t.pcSvcNotifTitle, 'body': t.pcSvcNotifBody, 'stop': t.pcSvcStop}) ==
          true;
      _svcOn = ok;
    } catch (_) {
      _svcOn = false;
    }
    return _svcOn;
  }

  Future<void> _stopCamService() async {
    _bgTimer?.cancel();
    _bgTimer = null;
    _bgOn = false;
    if (widget.preview != null) return;
    try {
      await _native('camSvcStop');
    } catch (_) {} // the service also stops itself without pings
    _svcOn = false;
  }

  /// The app left the screen (screen off / Home): hand the camera to the
  /// service. Without the service the camera is released (old behaviour).
  Future<void> _toBackground() async {
    await _closeCamera();
    if (!_running || !_svcOn || _bgOn) return;
    var ok = false;
    try {
      ok = await _native('bgCamOpen') == true;
    } catch (_) {}
    if (!ok || !_running) {
      if (ok) unawaited(_native('bgCamClose').catchError((_) => null));
      return;
    }
    _bgOn = true;
    _bgLastN = -1;
    _motion.reset();
    if (mounted) _setStatus(AppLocalizations.of(context).pcBgWatching);
    _bgTimer?.cancel();
    _bgTimer = Timer.periodic(const Duration(milliseconds: 350), (_) => _bgTick());
  }

  /// Back on the screen: the screen's own camera again (clips, preview).
  Future<void> _toForeground() async {
    if (_bgOn) {
      _bgTimer?.cancel();
      _bgTimer = null;
      _bgOn = false;
      try {
        await _native('bgCamClose');
      } catch (_) {}
    }
    if (_running && !_inLive && _cam == null) await _openCamera();
  }

  Future<void> _bgTick() async {
    if (!_bgOn || _bgBusy || _busy || _inLive) return;
    _bgBusy = true;
    try {
      final r = await _native('bgFrame');
      if (r is! Map) return;
      final n = (r['n'] as num?)?.toInt() ?? 0;
      if (n == _bgLastN) return;
      _bgLastN = n;
      final y = r['y'];
      if (y is! Uint8List) return;
      _bgRot = (r['rot'] as num?)?.toInt() ?? 0;
      _analyze(y, (r['w'] as num).toInt(), (r['h'] as num).toInt(),
          (r['stride'] as num).toInt(), rot: _bgRot);
    } catch (_) {
      // a skipped frame is never fatal
    } finally {
      _bgBusy = false;
    }
  }

  Future<Uint8List?> _bgJpeg() async {
    try {
      final b = await _native('bgJpeg', {'quality': 80});
      return b is Uint8List ? b : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restore() async {
    final p = widget.preview;
    if (p != null) {
      if (p.paired) {
        _token = 'preview';
        _cameraId = 1;
      }
      _cameraName = p.camera;
      _siteName = p.site;
      _running = p.running;
      _alerts = p.alerts;
      _clipCount = p.clips;
      _clipBytes = p.clipMb * 1024 * 1024;
      _audio = p.audio;
      _detect = p.model ? (_) async => null : null;
      _modelTried = true;
      _warnings = p.warnings;
      _online = true;
      _recOn = p.rec.isNotEmpty;
      _segRec = p.rec == 'recording';
      _recReason = p.rec == 'recording' ? '' : p.rec;
      _recBytes = p.rec.isEmpty ? 0 : 412 * 1024 * 1024;
    } else {
      try {
        _token = await _secure.read(key: _kTok);
        _cameraId = int.tryParse(await _secure.read(key: _kCam) ?? '');
        _siteName = await _secure.read(key: _kSite) ?? '';
        _cameraName = await _secure.read(key: _kCamName) ?? '';
        final prefs = await SharedPreferences.getInstance();
        _audio = prefs.getBool(_kAudio) ?? false;
        _capMb = prefs.getInt(_kCap) ?? kClipCapDefaultMb;
      } catch (e) {
        reportNonFatal('phonecam.restore', e);
      }
      await _refreshClips();
      await _refreshRec();
    }
    if (mounted) setState(() => _loading = false);
  }

  // ------------------------------------------------------------------ pairing
  Future<void> _claim() async {
    final t = AppLocalizations.of(context);
    final code = normalizePairCode(_code.text);
    if (code == null) {
      setState(() => _pairError = t.pcCodeInvalid);
      return;
    }
    setState(() {
      _claiming = true;
      _pairError = '';
    });
    var model = '';
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      model = '${a.manufacturer} ${a.model}'.trim();
    } catch (_) {} // best-effort: the phone model is only a label for the owner
    final r = await PhoneCamClaim.claim(code, name: _name.text.trim(), model: model);
    if (!mounted) return;
    setState(() => _claiming = false);
    if (r.status == 0) {
      setState(() => _pairError = t.pcOffline);
      return;
    }
    if (!r.ok) {
      setState(() => _pairError = (r.body['detail'] ?? t.pcCodeInvalid).toString());
      return;
    }
    final tok = (r.body['camera_token'] ?? '').toString();
    final cam = (r.body['camera'] ?? const {}) as Map;
    final site = (r.body['site'] ?? const {}) as Map;
    try {
      await _secure.write(key: _kTok, value: tok);
      await _secure.write(key: _kCam, value: '${cam['id'] ?? ''}');
      await _secure.write(key: _kSite, value: (site['name'] ?? '').toString());
      await _secure.write(key: _kCamName, value: (cam['name'] ?? '').toString());
    } catch (e) {
      reportNonFatal('phonecam.savePairing', e);
    }
    setState(() {
      _token = tok;
      _cameraId = (cam['id'] as num?)?.toInt();
      _siteName = (site['name'] ?? '').toString();
      _cameraName = (cam['name'] ?? '').toString();
      _code.clear();
    });
  }

  Future<void> _forget() async {
    try {
      for (final k in [_kTok, _kCam, _kSite, _kCamName]) {
        await _secure.delete(key: k);
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _token = null;
        _cameraId = null;
        _siteName = '';
        _cameraName = '';
      });
    }
  }

  Future<void> _unbind() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.pcUnbindTitle),
        content: Text(t.pcUnbindBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.pcUnbind)),
        ],
      ),
    );
    if (ok != true) return;
    await _stop();
    final dev = _dev;
    if (dev != null && widget.preview == null) {
      final r = await dev.phoneCamUnbind();
      if (r.status == 0) {
        if (mounted) _snack(t.pcOffline);
        return;
      }
    }
    await _forget();
  }

  // ------------------------------------------------------------------ settings
  Future<void> _setAudio(bool on) async {
    if (on) {
      // Play prominent disclosure first, then Android's prompt
      if (!await showPermissionReason(context, PermKind.mic)) return;
      try {
        final st = await Permission.microphone.request();
        if (!st.isGranted) {
          if (mounted) _snack(AppLocalizations.of(context).pcMicDenied);
          return;
        }
      } catch (_) {
        return;
      }
    }
    setState(() => _audio = on);
    try {
      (await SharedPreferences.getInstance()).setBool(_kAudio, on);
    } catch (_) {} // best-effort: applies now; only the saved copy can fail
  }

  Future<void> _setCap(int mb) async {
    setState(() => _capMb = mb);
    try {
      (await SharedPreferences.getInstance()).setInt(_kCap, mb);
    } catch (_) {} // best-effort: applies now; only the saved copy can fail
    await _enforceCap();
  }

  void _snack(String s) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(s)));

  // ------------------------------------------------------------------ clips
  Future<Directory?> _clipDir() async {
    try {
      final d = Directory('${(await getApplicationDocumentsDirectory()).path}/phonecam_clips');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<List<ClipFile>> _listClips() async {
    final d = await _clipDir();
    if (d == null) return const [];
    final out = <ClipFile>[];
    try {
      await for (final e in d.list()) {
        if (e is File) {
          final st = await e.stat();
          out.add(ClipFile(e.path, st.size, st.modified));
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> _refreshClips() async {
    final l = await _listClips();
    if (!mounted) return;
    setState(() {
      _clipCount = l.length;
      _clipBytes = clipsTotalBytes(l);
    });
  }

  Future<void> _enforceCap({int incoming = 0}) async {
    final l = await _listClips();
    for (final c in clipsToDelete(l, _capMb * 1024 * 1024, incomingBytes: incoming)) {
      try {
        await File(c.path).delete();
      } catch (_) {}
    }
    await _refreshClips();
  }

  Future<void> _deleteAllClips() async {
    for (final c in await _listClips()) {
      try {
        await File(c.path).delete();
      } catch (_) {} // best-effort: the count below shows what is left
    }
    await _refreshClips();
  }

  /// ~10 s clip of what happened, kept on this phone as clip_<ref>.mp4 —
  /// cctvplay: a small sealed preview of it goes to the owner + family.
  Future<void> _recordClip(CameraController c, String ref) async {
    try {
      await c.startVideoRecording();
      await Future.delayed(_clipLength);
      final f = await c.stopVideoRecording();
      final src = File(f.path);
      final size = await src.length();
      await _enforceCap(incoming: size);
      final d = await _clipDir();
      if (d == null) return;
      final name = clipFileName(ref);
      try {
        await src.rename('${d.path}/$name');
      } catch (_) {
        await src.copy('${d.path}/$name');
        await src.delete();
      }
      await _refreshClips();
      if (_clipCfg.enabled) unawaited(_sendPreview('${d.path}/$name', ref));
    } catch (e) {
      reportNonFatal('phonecam.clip', e);
      try {
        if (c.value.isRecordingVideo) await c.stopVideoRecording();
      } catch (_) {}
    }
  }

  /// cctvplay: a few small frames of the clip (native, background thread) ->
  /// ACG1 -> sealed off the UI thread -> shop/clips. Never blocks guarding;
  /// any failure just means "photo only" for this alert.
  Future<void> _sendPreview(String path, String ref, {int? fromMs, int? toMs}) async {
    final dev = _dev;
    final cfg = _clipCfg;
    if (dev == null || !cfg.enabled) return;
    try {
      final raw = await _channel.invokeListMethod<Object?>('clipFrames', {
        'path': path,
        'count': (cfg.fps * kPhoneClipSeconds).round().clamp(4, 30),
        'width': cfg.width,
        'quality': 55,
        if (fromMs != null) 'fromMs': fromMs < 0 ? 0 : fromMs,
        if (toMs != null) 'toMs': toMs,
      });
      final frames = [for (final f in raw ?? const []) if (f is Uint8List) f];
      if (frames.length < 2) return;
      final sealed = await compute(_previewJob, <String, Object>{
        'frames': frames,
        'recipients': cfg.recipients,
        'max_kb': cfg.maxKb,
      });
      if (sealed == null) return;
      for (var attempt = 0; attempt < 3; attempt++) {
        final r = await dev.uploadClip(ref, sealed.meta, sealed.ct);
        if (r.status == 201 || r.status == 200) {
          if (mounted) setState(() => _previewsSent++);
          return;
        }
        if (r.status != 0 && r.status < 500) return; // cap / window / refused: photo only
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    } catch (e) {
      reportNonFatal('phonecam.preview', e); // older build without clipFrames: photo only
    }
  }

  /// cctvplay: a viewer asked for a FULL video (heartbeat) — seal the clip
  /// that is still on this phone and upload it, or say honestly it is gone.
  Future<void> _answerVideos(List<VideoRequest> reqs) async {
    final dev = _dev;
    if (dev == null || _videoBusy || _inLive || reqs.isEmpty) return;
    _videoBusy = true;
    try {
      for (final q in reqs) {
        if (!mounted || _inLive) break;
        if (q.kind != 'event' || q.ref.isEmpty) {
          if (!await _answerSegment(dev, q)) {
            await PhoneCamClipDevice.videoMissing(dev, q.key, reason: 'no_recording');
          }
          continue;
        }
        final d = await _clipDir();
        final f = d == null ? null : File('${d.path}/${clipFileName(q.ref)}');
        if (f == null || !await f.exists()) {
          // item 4: in continuous mode the alert lives inside a segment
          final ts = _refTimes[q.ref];
          if (ts != null) {
            if (_segRec && ts >= _segStartS) continue; // still recording
            final p = segFor([for (final x in await _listRec()) x.path], ts);
            if (p != null && await _uploadSegment(dev, q.key, p)) continue;
          }
          await PhoneCamClipDevice.videoMissing(dev, q.key);
          continue;
        }
        final len = await f.length();
        if (len > kVideoMaxBytes) {
          await PhoneCamClipDevice.videoMissing(dev, q.key, reason: 'too_large');
          continue;
        }
        if (!_clipCfg.canSeal) break; // nobody has a key yet: retry next heartbeat
        final bytes = await f.readAsBytes();
        final sealed = await compute(_videoJob, <String, Object>{
          'mp4': bytes,
          'recipients': _clipCfg.recipients,
          'seconds': kPhoneClipSeconds.toDouble(),
        });
        await PhoneCamClipDevice.uploadVideo(dev, q.key, sealed.meta, sealed.ct);
      }
    } catch (e) {
      reportNonFatal('phonecam.video', e);
    } finally {
      _videoBusy = false;
    }
  }

  /// item 4: a viewer picked a second on the timeline — send the segment
  /// holding it. true = sent or deferred (still being recorded), false =
  /// not on this phone (the caller says so honestly).
  Future<bool> _answerSegment(ShopDeviceClient dev, VideoRequest q) async {
    final t = q.start;
    if (_segRec && t >= _segStartS) return true; // still recording: next heartbeat
    final p = segFor([for (final f in await _listRec()) f.path], t);
    if (p == null) return false;
    return _uploadSegment(dev, q.key, p);
  }

  Future<bool> _uploadSegment(ShopDeviceClient dev, String key, String path) async {
    final seg = parseSeg(path);
    final f = File(path);
    if (seg == null || !await f.exists()) return false;
    if (await f.length() > kVideoMaxBytes) {
      await PhoneCamClipDevice.videoMissing(dev, key, reason: 'too_large');
      return true;
    }
    if (!_clipCfg.canSeal) return true; // nobody has a key yet: retry later
    final bytes = await f.readAsBytes();
    final sealed = await compute(_videoJob, <String, Object>{
      'mp4': bytes,
      'recipients': _clipCfg.recipients,
      'seconds': seg.$2.toDouble(),
    });
    sealed.meta['start_ts'] = seg.$1;
    await PhoneCamClipDevice.uploadVideo(dev, key, sealed.meta, sealed.ct);
    return true;
  }

  // ------------------------------------------------------------------ continuous recording
  Future<Directory?> _recDir() async {
    try {
      final d = Directory('${(await getApplicationDocumentsDirectory()).path}/phonecam_rec');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<List<ClipFile>> _listRec() async {
    final d = await _recDir();
    if (d == null) return const [];
    final out = <ClipFile>[];
    try {
      await for (final e in d.list()) {
        if (e is File && parseSeg(e.path) != null) {
          final st = await e.stat();
          out.add(ClipFile(e.path, st.size, st.modified));
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> _refreshRec() async {
    final l = await _listRec();
    if (mounted) setState(() => _recBytes = clipsTotalBytes(l));
  }

  Future<void> _deleteAllRec() async {
    for (final c in await _listRec()) {
      try {
        await File(c.path).delete();
      } catch (_) {} // best-effort: the size line below shows what is left
    }
    await _refreshRec();
    unawaited(_publishTimeline());
  }

  /// Start or stop recording so it matches the switch and the guards.
  Future<void> _syncRecording() async {
    if (_recBusy || widget.preview != null) return;
    final want = _recOn && _running && _cam != null && !_inLive && !_busy &&
        !_recUnsupported && _recReason.isEmpty;
    if (want == _segRec) return;
    _recBusy = true;
    try {
      if (want) {
        await _startSegment();
      } else {
        await _stopSegment(restartStream: true);
      }
    } finally {
      _recBusy = false;
    }
    unawaited(_publishTimeline());
  }

  Future<void> _startSegment() async {
    final c = _cam;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      // the frames keep feeding motion + person checks while it records
      await c.startVideoRecording(onAvailable: _onFrame);
      _segRec = true;
      _segStartS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _segTimer?.cancel();
      _segTimer = Timer(const Duration(seconds: kRecSegmentS), _rollSegment);
    } catch (e) {
      // honest: this phone cannot record and watch at the same time
      reportNonFatal('phonecam.rec', e);
      _recUnsupported = true;
      _segRec = false;
      try {
        if (!c.value.isStreamingImages && _cam == c) await c.startImageStream(_onFrame);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _rollSegment() async {
    if (_recBusy || !_segRec) return;
    _recBusy = true;
    try {
      await _stopSegment(restartStream: false);
      final keep = _recOn && _running && _cam != null && !_inLive && _recReason.isEmpty;
      if (keep) {
        await _startSegment();
      } else {
        final c = _cam;
        if (c != null && !_inLive && !c.value.isStreamingImages) await c.startImageStream(_onFrame);
      }
    } catch (_) {
    } finally {
      _recBusy = false;
    }
    unawaited(_publishTimeline());
  }

  /// Close the open segment and keep it as seg_<start>_<len>.mp4 (oldest
  /// segments deleted first at the cap); previews of alerts inside it go now.
  Future<void> _stopSegment({required bool restartStream}) async {
    _segTimer?.cancel();
    _segTimer = null;
    final c = _cam;
    if (!_segRec) return;
    _segRec = false;
    if (c == null) return;
    try {
      if (!c.value.isRecordingVideo) return;
      final f = await c.stopVideoRecording();
      final start = _segStartS;
      final dur = (DateTime.now().millisecondsSinceEpoch ~/ 1000 - start).clamp(1, 600);
      final src = File(f.path);
      final size = await src.length();
      final d = await _recDir();
      if (d != null) {
        for (final old in clipsToDelete(await _listRec(), _recCapMb * 1024 * 1024, incomingBytes: size)) {
          try {
            await File(old.path).delete();
          } catch (_) {}
        }
        final path = '${d.path}/${segName(start, dur)}';
        try {
          await src.rename(path);
        } catch (_) {
          await src.copy(path);
          await src.delete();
        }
        await _refreshRec();
        // alert previews that fall inside this segment
        final mine = _pendingPreviews.where((x) => x.$1 >= start && x.$1 < start + dur).toList();
        _pendingPreviews.removeWhere((x) => x.$1 < start + dur);
        for (final (ts, ref) in mine) {
          unawaited(_sendPreview(path, ref, fromMs: (ts - start - 1) * 1000, toMs: (ts - start + 9) * 1000));
        }
      }
    } catch (e) {
      reportNonFatal('phonecam.rec.stop', e);
    } finally {
      if (restartStream) {
        try {
          if (_cam == c && !_inLive && !c.value.isStreamingImages) await c.startImageStream(_onFrame);
        } catch (_) {}
      }
    }
  }

  /// What this phone has recorded -> the owner's timeline (spans + state).
  Future<void> _publishTimeline({bool? setOn}) async {
    final dev = _dev;
    if (dev == null || widget.preview != null) return;
    final segs = <(int, int)>[
      for (final f in await _listRec())
        if (parseSeg(f.path) case final s?) s
    ];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_segRec) segs.add((_segStartS, now - _segStartS));
    final r = await PhoneCamClipDevice.timeline(dev, {
      'spans': spansOf(segs),
      'used_mb': _recBytes ~/ (1024 * 1024),
      'cap_mb': _recCapMb,
      'state': _segRec ? 'recording' : (_recOn ? 'paused' : 'off'),
      'reason': _recUnsupported ? 'unsupported' : _recReason,
      if (setOn != null) 'set_on': setOn,
    });
    final rec = r.body['recording'];
    if (r.ok && rec is Map && mounted) {
      setState(() {
        _recOn = rec['on'] == true;
        _recCapMb = ((rec['cap_mb'] as num?) ?? _recCapMb).toInt();
      });
    }
  }

  Future<void> _setRecLocal(bool on) async {
    setState(() => _recOn = on);
    await _publishTimeline(setOn: on);
    unawaited(_syncRecording());
  }

  // ------------------------------------------------------------------ running
  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _running = true;
      _showControls = true;
      _status = t.pcStarting;
    });
    _scheduleHide();
    if (widget.preview != null) return;
    try {
      await _channel.invokeMethod<bool>('keepScreenOn', {'on': true});
      await _channel.invokeMethod<bool>('dim', {'on': true});
    } catch (_) {} // best-effort: older build — the guide says keep it plugged in and on
    await _heartbeat();
    _hb = Timer.periodic(_heartbeatEvery, (_) => _heartbeat());
    await _openCamera();
    // guardbox-play: the service notification (with Stop) replaces ours
    if (!await _startCamService()) unawaited(_notif(true));
    if (PhoneCameraScreen.debugNoPersonModel) _modelTried = true;
    if (!_modelTried) {
      _modelTried = true;
      unawaited(guardPersonDetector().then((d) {
        if (mounted) setState(() => _detect = d);
      }));
    }
  }

  Future<void> _stop({bool silent = false}) async {
    _hb?.cancel();
    _hb = null;
    _segTimer?.cancel();
    await _stopCamService();
    await _closeCamera();
    if (widget.preview == null) {
      try {
        await _channel.invokeMethod('dim', {'on': false});
        await _channel.invokeMethod('keepScreenOn', {'on': false});
      } catch (_) {} // best-effort: screen flags reset when the screen closes anyway
      unawaited(_notif(false));
    }
    _running = false;
    if (!silent && mounted) setState(() => _status = '');
  }

  Future<void> _notif(bool on) async {
    try {
      final p = FlutterLocalNotificationsPlugin();
      if (!on) {
        await p.cancel(_notifId);
        return;
      }
      if (!Notifications.ready) await Notifications.init();
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      await p.show(
          _notifId,
          t.pcNotifTitle,
          t.pcNotifBody,
          NotificationDetails(
              android: AndroidNotificationDetails('phonecam', t.pcNotifChannel,
                  channelDescription: t.pcNotifChannel,
                  importance: Importance.low,
                  priority: Priority.low,
                  ongoing: true,
                  autoCancel: false,
                  onlyAlertOnce: true,
                  playSound: false,
                  enableVibration: false)));
    } catch (_) {} // the on-screen banner stays the main notice
  }

  Future<void> _openCamera() async {
    final t = AppLocalizations.of(context);
    // Play: explain the camera ask before the plugin's own system prompt —
    // only when Android would really ask (guardbox-play bug fix: the reason
    // dialog came back on EVERY reopen — after each live view, on every
    // return to the app — so an unattended camera phone stopped watching
    // until someone tapped "Continue").
    if (!await _cameraGranted()) {
      if (!mounted || !await showPermissionReason(context, PermKind.camera)) return;
    }
    if (!mounted) return;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus(t.shopModeNoCamera);
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      // cctvplay: ~0.8 Mbps keeps a 10 s clip near 1 MB (more clips in the
      // cap, a cheap full video for the family)
      final c = CameraController(back, ResolutionPreset.medium,
          enableAudio: _audio, videoBitrate: 800000, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      _cam = c;
      _motion.reset();
      await c.startImageStream(_onFrame);
      _setStatus(t.pcWatching);
    } on CameraException catch (e) {
      _setStatus(e.code.toLowerCase().contains('denied') ? t.shopModeCameraDenied : t.shopModeCameraFailed);
    } catch (_) {
      _setStatus(t.shopModeCameraFailed);
    }
  }

  Future<bool> _cameraGranted() async {
    final d = PhoneCameraScreen.debugChannel;
    if (d != null) return await d('cameraGranted') == true;
    try {
      return await Permission.camera.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _closeCamera() async {
    if (_segRec) await _stopSegment(restartStream: false); // item 4: keep it
    final c = _cam;
    _cam = null;
    if (c == null) return;
    try {
      if (c.value.isRecordingVideo) await c.stopVideoRecording();
    } catch (_) {}
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _onFrame(CameraImage img) {
    final p = img.planes.first;
    _analyze(p.bytes, img.width, img.height, p.bytesPerRow,
        rot: _cam?.description.sensorOrientation ?? 0, img: img);
  }

  /// One luma frame (the screen's camera stream, or guardbox-play: the
  /// camera service's frame while the screen is off) -> motion / zones.
  void _analyze(Uint8List luma, int width, int height, int bytesPerRow,
      {required int rot, CameraImage? img}) {
    final now = DateTime.now();
    if (_busy || _inLive || now.difference(_lastFrame).inMilliseconds < 330) return;
    _lastFrame = now;
    try {
      final grid = _motion.downsample(luma, width, height, bytesPerRow);
      final wasDark = _dark.dark;
      _dark.feed(DarkMonitor.meanOf(grid), now);
      if (wasDark != _dark.dark) unawaited(_heartbeat());
      // cctvacc2: + the pixel-level check (same place, 3 frames in a row)
      final plane = _motion.pixelPlane(luma, width, height, bytesPerRow);
      final r = _motion.feedGrid(grid, plane: plane);
      // cctvdet: tamper + "gate left open" from the same grid (cheap)
      final zd = _zones.onGrid(grid, _motion.gridW, _motion.gridH, rot: rot);
      if (zd.isNotEmpty) {
        if (!_busy && !_segRec) {
          // take a photo (+ 10 s clip) for it, like any other alert
          _busy = true;
          unawaited(_onMotion(zoneOnly: true, carry: zd).whenComplete(() => _busy = false));
          return;
        }
        unawaited(_sendZoneDets(zd, null));
      }
      if (!r.motion) {
        // a post zone is armed / someone stands in a zone: check anyway
        // (a photo at most every 5 s on the phone, like the motion path)
        if (!_segRec &&
            (_lastCheck == null || now.difference(_lastCheck!).inSeconds >= 5) &&
            _zones.needsCheck()) {
          _lastCheck = now;
          _busy = true;
          unawaited(_onMotion(zoneOnly: true).whenComplete(() => _busy = false));
        }
        return;
      }
      final last = _lastAlert;
      final cool = _detect != null ? _personCooldown : _motionOnlyCooldown;
      if (last != null && now.difference(last) < cool) return;
      // a night person seen once is checked again on the next frame (2-frame rule)
      if (_lastCheck != null && now.difference(_lastCheck!).inSeconds < 5 &&
          !guardNightPending) {
        return;
      }
      _lastCheck = now;
      _busy = true;
      if (_segRec && img != null) {
        // item 4: the camera is recording — check THIS frame (no still)
        unawaited(_onMotionRec(img).whenComplete(() => _busy = false));
      } else {
        unawaited(_onMotion().whenComplete(() => _busy = false));
      }
    } catch (_) {} // a malformed frame is skipped, never fatal
  }

  Future<Uint8List?> _still(CameraController c) async {
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      final f = await c.takePicture();
      final b = await f.readAsBytes();
      try {
        await File(f.path).delete();
      } catch (_) {}
      return b;
    } catch (_) {
      return null;
    }
  }

  /// Motion -> one photo -> person check on THIS phone -> alert (+ clip).
  /// cctvacc2: at night a person must be seen on TWO photos in a row.
  Future<void> _onMotion(
      {bool zoneOnly = false, List<Map<String, Object?>> carry = const []}) async {
    final c = _cam;
    final dev = _dev;
    if (dev == null || (c == null && !_bgOn)) return;
    // guardbox-play: screen off = the camera service's newest frame
    Future<Uint8List?> grab() => c != null ? _still(c) : _bgJpeg();
    var jpeg = await grab();
    try {
      final detect = _detect;
      List<List<double>>? boxes;
      if (detect != null && jpeg != null) {
        boxes = await detect(jpeg);
        if (boxes != null && boxes.isEmpty && guardNightPending) {
          final j2 = await grab();
          if (j2 != null) {
            final b2 = await detect(j2);
            if (b2 != null && b2.isNotEmpty) {
              boxes = b2;
              jpeg = j2;
            }
          }
        }
      }
      // cctvdet: the same boxes feed the zone rules (person at the gate,
      // dwell, counter empty) — each detection is its own alert + 10 s clip
      final zd = [...carry];
      if (_zones.active && detect != null) zd.addAll(_zones.onBoxes(boxes, night: _dark.dark));
      if (zd.isNotEmpty) await _sendZoneDets(zd, jpeg);
      // a zone alert already covers this check (one photo, one clip)
      final alert = (zoneOnly || zd.isNotEmpty)
          ? null
          : phoneAlert(modelAvailable: detect != null, boxes: boxes);
      if (alert != null) {
        _lastAlert = DateTime.now();
        // cctvplay: the clip starts at once (not after the upload) and the
        // alert names it, so a viewer can later ask for exactly this video
        final ref = c == null ? null : newClipRef(); // no clip with the screen off
        final recording = (c != null && ref != null && _cam == c && _running && !_inLive)
            ? _recordClip(c, ref)
            : Future<void>.value();
        // cctvtoday: a big still is shrunk (off the UI thread), never dropped
        final raw = jpeg;
        final snap = raw == null
            ? null
            : raw.length <= _maxSnapshotBytes
                ? raw
                : await compute(shrinkAlertJpeg, raw);
        final r = await dev.ingest(alert.type, alert.signals, snapshot: snap, clipRef: ref);
        if (mounted && r.ok) setState(() => _alerts++);
        await recording;
      }
    } finally {
      try {
        if (c != null && _cam == c && _running && !_inLive && !c.value.isStreamingImages) {
          _motion.reset();
          await c.startImageStream(_onFrame);
        }
      } catch (_) {}
    }
  }

  /// item 4: motion while continuously recording -> this frame as the
  /// photo -> person check -> alert. The video is already being recorded.
  Future<void> _onMotionRec(CameraImage frame) async {
    final dev = _dev;
    final c = _cam;
    if (dev == null || c == null || frame.planes.length < 3) return;
    final y = frame.planes[0], u = frame.planes[1], v = frame.planes[2];
    final jpeg = await compute(_yuvJob, <String, Object>{
      'w': frame.width,
      'h': frame.height,
      'y': Uint8List.fromList(y.bytes),
      'u': Uint8List.fromList(u.bytes),
      'v': Uint8List.fromList(v.bytes),
      'yRow': y.bytesPerRow,
      'uvRow': u.bytesPerRow,
      'uvPix': u.bytesPerPixel ?? 1,
      'rot': c.description.sensorOrientation,
    });
    final detect = _detect;
    List<List<double>>? boxes;
    if (detect != null && jpeg != null) boxes = await detect(jpeg);
    final alert = phoneAlert(modelAvailable: detect != null, boxes: boxes);
    if (alert == null) return;
    _lastAlert = DateTime.now();
    final ref = newClipRef();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _refTimes[ref] = ts;
    if (_refTimes.length > 500) _refTimes.remove(_refTimes.keys.first);
    if (_clipCfg.enabled) _pendingPreviews.add((ts, ref));
    final r = await dev.ingest(alert.type, alert.signals, snapshot: jpeg, clipRef: ref);
    if (mounted && r.ok) setState(() => _alerts++);
  }

  /// cctvdet: one alert per zone detection, with the phone's 10 s clip.
  Future<void> _sendZoneDets(List<Map<String, Object?>> dets, Uint8List? jpeg) async {
    final dev = _dev;
    final c = _cam;
    if (dev == null) return;
    for (final d in dets) {
      final ref = newClipRef();
      final recording = (c != null && _cam == c && _running && !_inLive && jpeg != null)
          ? _recordClip(c, ref)
          : Future<void>.value();
      final snap = jpeg == null
          ? null
          : jpeg.length <= _maxSnapshotBytes
              ? jpeg
              : await compute(shrinkAlertJpeg, jpeg);
      final r = await dev.ingest('${d['type']}', _zones.signals(d, model: _detect != null),
          snapshot: snap, clipRef: (jpeg == null || c == null) ? null : ref);
      if (mounted && r.ok) setState(() => _alerts++);
      await recording;
    }
  }

  /// cctvdet: the owner's zones (drawn on this camera's picture) — fetched
  /// again only when the server's config version changes.
  Future<void> _refreshZones(ShopDeviceClient dev, Object? version) async {
    if (version == null || version == _zonesVer) return;
    try {
      final c = await dev.config();
      if (c.ok) {
        _zones.applyConfig(c.body);
        _zonesVer = '$version';
      }
    } catch (_) {} // zones stay as they were; alerts keep working
  }

  Future<void> _heartbeat() async {
    final dev = _dev;
    if (dev == null || widget.preview != null) return;
    Map? batt;
    try {
      batt = await _channel.invokeMapMethod<String, dynamic>('battery');
    } catch (_) {}
    final health = healthReport(batt, dark: _dark.dark);
    int? free;
    try {
      free = await _channel.invokeMethod<int>('freeBytes');
    } catch (_) {} // older build: no storage guard (the size cap still holds)
    if (_svcOn) unawaited(_native('camSvcPing').catchError((_) => null)); // guardbox-play watchdog
    final r = await dev.heartbeat(caps: const ['live', 'phone'], health: health);
    if (!mounted) return;
    if (r.unauthorized || r.status == 404) {
      // the owner removed this camera: honest message, back to pairing
      await _stop();
      await _forget();
      if (mounted) _snack(AppLocalizations.of(context).pcRemovedByOwner);
      return;
    }
    final pc = r.body['phonecam'];
    if (r.ok) unawaited(_refreshZones(dev, r.body['config_version']));
    setState(() {
      _online = r.ok;
      _warnings = localWarnings(health);
      if (pc is Map) _clipCfg = PhoneClipCfg.fromJson(pc['clip']);
    });
    if (!r.ok) return;
    if (pc is Map) {
      final reqs = VideoRequest.listFrom(pc['video_requests']);
      if (reqs.isNotEmpty) unawaited(_answerVideos(reqs));
      final rec = pc['recording'];
      if (rec is Map) {
        final on = rec['on'] == true;
        final reason = recGuard(
            charging: health['charging'] as bool?,
            level: health['level'] as int?,
            tempC: (health['temp_c'] as num?)?.toDouble(),
            freeBytes: free,
            inLive: _inLive);
        final changed = on != _recOn || reason != _recReason;
        setState(() {
          _recOn = on;
          _recCapMb = ((rec['cap_mb'] as num?) ?? _recCapMb).toInt();
          _recReason = reason;
        });
        await _syncRecording();
        if (changed && !_segRec) unawaited(_publishTimeline());
      }
    }
    // cctvbox (cctvact contract): the owner's Siren / Warning plays here
    final play = PlayTask.fromHeartbeat(r.body['play']);
    if (play.isNotEmpty && _token != null) {
      _siren ??= BoxSiren.forDevice(_token!, cameraId: _cameraId);
      unawaited(_siren!.handle(play));
    }
    final pending = ((r.body['live_pending'] ?? const []) as List).whereType<Map>().toList();
    if (pending.isNotEmpty && !_inLive && _running) {
      unawaited(_answerLive(pending.first.cast<String, dynamic>()));
    }
  }

  // ------------------------------------------------------------------ live
  /// The owner (or an allowed family member) opened live view: hand the
  /// camera to WebRTC (P2P, our TURN as fallback), SD first, HD on their
  /// tap, sound only with this phone's consent switch. Never recorded.
  Future<void> _answerLive(Map<String, dynamic> s) async {
    final dev = _dev;
    final sid = (s['id'] as num?)?.toInt();
    if (dev == null || sid == null) return;
    final t = AppLocalizations.of(context);
    _inLive = true;
    _setStatus(t.pcLiveNow);
    await _closeCamera();
    // guardbox-play: screen off — WebRTC takes the camera from the service
    final wasBg = _bgOn;
    if (wasBg) {
      _bgTimer?.cancel();
      _bgTimer = null;
      _bgOn = false;
      try {
        await _native('bgCamClose');
      } catch (_) {}
    }
    dynamic peer;
    var after = 0;
    var answered = false;
    var relayed = false;
    DateTime? since;
    final expires = DateTime.tryParse((s['expires_at'] ?? '').toString())?.toLocal() ??
        DateTime.now().add(const Duration(minutes: 10));
    var hardEnd = DateTime.now().add(const Duration(minutes: 30));
    try {
      await rtc.loadLibrary();
      final ice = ((s['ice']?['ice_servers'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      peer = await rtc.LivePeer.create(ice,
          sender: true, onCandidate: (c) => dev.signal(sid, 'candidate', c));
      var deadline = expires;
      while (mounted && _running && DateTime.now().isBefore(hardEnd)) {
        final r = await dev.poll(sid, after);
        if (!r.ok) {
          if (r.status == 404 || r.status == 401) break;
          if (DateTime.now().isAfter(deadline)) break;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        after = (r.body['seq'] as num?)?.toInt() ?? after;
        final st = (r.body['status'] ?? '').toString();
        // the viewer's touches move the server's expiry (5-min idle stop)
        deadline = DateTime.tryParse((r.body['expires_at'] ?? '').toString())?.toLocal() ??
            deadline;
        var bye = st == 'ended' || st == 'expired';
        for (final m in ((r.body['messages'] ?? const []) as List).whereType<Map>()) {
          final p = m['payload'];
          if (m['kind'] == 'offer' && p is Map && !answered) {
            final ans = await peer.answer(p.cast<String, dynamic>(),
                audio: _audio, hdCapable: true);
            await dev.signal(sid, 'answer', ans);
            answered = true;
            since = DateTime.now();
          } else if (m['kind'] == 'candidate' && p is Map) {
            try {
              await peer.addCandidate(p.cast<String, dynamic>());
            } catch (_) {}
          } else if (m['kind'] == 'quality' && p is Map) {
            try {
              await peer.setHd(p['hd'] == true);
            } catch (_) {}
          } else if (m['kind'] == 'bye') {
            bye = true;
          }
        }
        if (bye || DateTime.now().isAfter(deadline)) break;
        if (answered && !relayed) {
          try {
            relayed = await peer.isRelayed() as bool;
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    } catch (e) {
      reportNonFatal('phonecam.live', e);
    } finally {
      try {
        await peer?.dispose();
      } catch (_) {}
      final secs = since == null ? 0 : DateTime.now().difference(since).inSeconds;
      await dev.end(sid, relayed: relayed, seconds: secs);
      _inLive = false;
      if (mounted && _running) {
        final paused = WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
        if (paused && _svcOn) {
          await _toBackground();
        } else {
          await _openCamera();
        }
      }
    }
  }

  // ------------------------------------------------------------------ UI
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && _running) setState(() => _showControls = false);
    });
  }

  String _warnText(AppLocalizations t, String k) => switch (k) {
        'unplugged' => t.pcWarnUnplugged,
        'low_battery' => t.pcWarnLow,
        'hot' => t.pcWarnHot,
        _ => t.pcWarnDark,
      };

  String _recLine(AppLocalizations t) {
    if (_segRec) return t.pcrOnLine(_mb(_recBytes), fmtInt(context, _recCapMb));
    final r = _recUnsupported ? 'unsupported' : _recReason;
    return switch (r) {
      'hot' => t.pcrPausedHot,
      'battery' => t.pcrPausedBattery,
      'storage' => t.pcrPausedStorage,
      'live' => t.pcrPausedLive,
      'unsupported' => t.pcrUnsupported,
      _ => t.pcrStarting,
    };
  }

  String _mb(int bytes) => fmtInt(context, (bytes / (1024 * 1024)).round());

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_running) return _runningView(t);
    return Scaffold(
      appBar: AppBar(title: Text(t.pcTitle)),
      body: _loading
          ? const SkeletonList()
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
              children: _token == null ? _pairView(t) : _readyView(t),
            ),
    );
  }

  Widget _card(IconData icon, String title, String body) => DsCard(
    padding: const EdgeInsets.all(14),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(body, style: AType.bodyMedium.copyWith(height: 1.4)),
              ]),
            ),
          ]),
  );

  List<Widget> _pairView(AppLocalizations t) => [
        _card(Icons.phone_android_rounded, t.pcIntroTitle, t.pcIntroBody),
        const SizedBox(height: 12),
        Text(t.pcPairHereTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(t.pcPairHereHelp),
        const SizedBox(height: 12),
        TextField(
          key: const Key('pcCodeField'),
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: t.pcCodeLabel,
            hintText: ld(context, '12-ABC234'),
            errorText: _pairError.isEmpty ? null : _pairError,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: t.shopModePaste,
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: () async {
                final d = await Clipboard.getData(Clipboard.kTextPlain);
                if (d?.text != null) _code.text = normalizePairCode(d!.text) ?? d.text!;
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _name,
          decoration: InputDecoration(
              labelText: t.pcNameLabel, hintText: t.pcNameHint, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('pcClaim'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _claiming ? null : _claim,
          icon: _claiming
              ? const SizedBox.square(
                  dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link_rounded),
          label: Text(t.pcClaim),
        ),
        ..._ipcamEntry(t), // cctvbox
        const SizedBox(height: 16),
        _card(Icons.privacy_tip_rounded, t.pcTrustTitle, t.pcpTrustBody),
      ];

  // cctvbox: the same old phone can watch a Wi-Fi IP camera instead of using
  // its own camera (Guard Box, no PC). Hidden while the flag is off.
  List<Widget> _ipcamEntry(AppLocalizations t) => [
        if (FeatureFlags.instance.isOn('guard_box_mode')) ...[
          const SizedBox(height: 12),
          DsCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              key: const Key('pcIpcamEntry'),
              minVerticalPadding: 12,
              leading: const Icon(Icons.router_rounded),
              title: Text(t.icgOpen, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text(t.icgOpenBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => IpCamGuardScreen(
                        initialCode: _code.text.trim().isEmpty ? null : _code.text.trim())));
                if (mounted) await _restore();
              },
            ),
          ),
        ],
      ];

  List<Widget> _readyView(AppLocalizations t) {
    final caps = [...kClipCapChoicesMb];
    if (!caps.contains(_capMb)) caps.add(_capMb);
    return [
      DsCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.videocam_rounded),
          title: Text(_cameraName.isEmpty ? t.pcUnnamed : _cameraName,
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text(t.pcPairedTo(_siteName.isEmpty ? '—' : _siteName)),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const Key('pcStart'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: _start,
        icon: const Icon(Icons.play_circle_fill_rounded),
        label: Text(t.pcStart),
      ),
      const SizedBox(height: 8),
      Text(kCameraFgsInBuild ? t.pcStartHelp2 : t.pcStartHelp,
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      SwitchListTile(
        key: const Key('pcAudio'),
        contentPadding: EdgeInsets.zero,
        value: _audio,
        onChanged: _setAudio,
        title: Text(t.pcAudioTitle),
        subtitle: Text(t.pcAudioBody),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.pcClipsTitle),
        subtitle: Text(t.pcClipsLine(fmtInt(context, _clipCount), _mb(_clipBytes), fmtInt(context, _capMb))),
        trailing: DropdownButton<int>(
          value: _capMb,
          onChanged: (v) => v == null ? null : _setCap(v),
          items: [
            for (final c in caps)
              DropdownMenuItem(value: c, child: Text(t.pcCapMb(fmtInt(context, c)))),
          ],
        ),
      ),
      if (_clipCount > 0)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _deleteAllClips,
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(t.pcClipsDelete),
          ),
        ),
      Text(t.pcpClipsHelp, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      // cctvplay item 4: optional continuous recording, OFF by default
      SwitchListTile(
        key: const Key('pcRec'),
        contentPadding: EdgeInsets.zero,
        value: _recOn,
        onChanged: _setRecLocal,
        title: Text(t.pcrTitle),
        subtitle: Text(t.pcrBody(fmtInt(context, _recCapMb), fmtInt(context, _recBytes ~/ (1024 * 1024)))),
      ),
      if (_recBytes > 0)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _deleteAllRec,
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(t.pcrDelete),
          ),
        ),
      ..._ipcamEntry(t), // cctvbox
      const SizedBox(height: 12),
      _card(Icons.tips_and_updates_rounded, t.pcGuideTitle, t.pcGuideBody),
      const SizedBox(height: 8),
      _card(Icons.privacy_tip_rounded, t.pcTrustTitle, t.pcpTrustBody),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('pcUnbind'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _unbind,
        icon: const Icon(Icons.link_off_rounded),
        label: Text(t.pcUnbind),
      ),
    ];
  }

  Widget _runningView(AppLocalizations t) {
    const fg = Colors.white;
    const dim = Colors.white70;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _showControls = true);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _showControls = true);
            _scheduleHide();
          },
          child: SafeArea(
            child: Padding(
              padding: withNavBarInset(context, const EdgeInsets.all(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // the "this phone is recording" notice is ALWAYS visible
                Container(
                  key: const Key('pcRecordingBanner'),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                      color: Brand.dangerFill, borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    const Icon(Icons.fiber_manual_record_rounded, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_audio ? t.pcRecordingBannerAudio : t.pcRecordingBanner,
                          style: AType.bodyMedium.copyWith(color: fg, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                if (_showControls) ...[
                  Text(_cameraName.isEmpty ? t.pcUnnamed : _cameraName,
                      textAlign: TextAlign.center,
                      style: AType.bodyMedium.copyWith(color: fg, fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(_status, textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  const SizedBox(height: 4),
                  Text(_online ? t.pcServerOk : t.pcServerOffline,
                      textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  Text(_detect != null ? t.pcModelOn : t.pcModelOff,
                      textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  if (_svcOn) // guardbox-play: honest — what happens with the screen off
                    Text(t.pcSvcOnLine,
                        key: const Key('pcSvcOn'),
                        textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  Text(t.pcAlertsSent(fmtInt(context, _alerts)),
                      textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  Text(t.pcClipsLine(fmtInt(context, _clipCount), _mb(_clipBytes), fmtInt(context, _capMb)),
                      textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  if (_recOn)
                    Text(_recLine(t), textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: dim)),
                  // cctvplay: honest — does the family get a preview?
                  Text(
                      _clipCfg.enabled
                          ? t.pcpPreviewsSent(fmtInt(context, _previewsSent), fmtInt(context, _clipCfg.leftToday))
                          : _clipCfg.canSeal
                              ? t.pcpPreviewsCapped
                              : t.pcpPreviewsNoKey,
                      textAlign: TextAlign.center,
                      style: AType.bodyMedium.copyWith(color: dim)),
                  for (final w in _warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_warnText(t, w),
                          textAlign: TextAlign.center,
                          style: AType.bodyMedium.copyWith(color: Brand.warning, fontWeight: FontWeight.w600)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('pcStop'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 52),
                        backgroundColor: Brand.dangerFill,
                        foregroundColor: fg),
                    onPressed: () => _stop(),
                    icon: const Icon(Icons.stop_circle_rounded),
                    label: Text(t.pcStop),
                  ),
                ] else
                  Text(t.pcTapToShow,
                      textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: Colors.white60)),
                          ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// cctvplay: off the UI thread (compute) — pure Dart sealing.
({Uint8List ct, Map<String, dynamic> meta})? _previewJob(Map<String, Object> a) => buildPreview(
    (a['frames'] as List).cast<Uint8List>(),
    (a['recipients'] as List).cast<Map<String, dynamic>>(),
    clipSeconds: kPhoneClipSeconds.toDouble(),
    maxKb: a['max_kb'] as int);

({Uint8List ct, Map<String, dynamic> meta}) _videoJob(Map<String, Object> a) => sealVideo(
    a['mp4'] as Uint8List, (a['recipients'] as List).cast<Map<String, dynamic>>(), a['seconds'] as double);

Uint8List? _yuvJob(Map<String, Object> f) {
  final j = yuvToJpeg(f);
  return j;
}
