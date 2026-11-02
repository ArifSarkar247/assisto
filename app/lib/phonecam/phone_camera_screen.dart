import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cashguard/guard_box_engine.dart' show PersonDetect;
import '../cashguard/guard_box_model.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../services/error_report.dart';
import '../shop_api.dart';
import '../shop_motion.dart';
import '../theme.dart' show Brand;
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/permission_reason.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../screens/shop_live_rtc.dart' deferred as rtc;
import 'phonecam_api.dart';
import 'phonecam_logic.dart';

/// cctvphone — THIS phone becomes an Assisto camera (owner CCTV order 3 Nov,
/// part A). Built on the Shop Box pieces (device client, motion detector,
/// live-view signaling, the on-phone YOLOX person model) — nothing rewritten.
///
/// Honest by design:
///   * the camera runs only while this screen is open (screen dimmed to the
///     minimum, kept awake, plugged in). No WorkManager, no background camera
///     service — Play's camera FGS rules (see CCTV_PHONE_CAMERA_BN.md);
///   * a clear "this phone is a camera — recording" banner on the screen and
///     an ongoing notification while it runs;
///   * sound is OFF unless the consent switch on THIS phone is on;
///   * clips stay on this phone (rolling, size-capped); only an alert photo
///     and a live view the owner opens leave the phone.
class PhoneCameraScreen extends StatefulWidget {
  /// From the QR App Link (https://lifeassisto.com/pc/<code>): pre-filled.
  final String? initialCode;

  /// Tests / gallery: a canned state, no storage, no camera.
  final PhoneCamPreview? preview;
  const PhoneCameraScreen({super.key, this.initialCode, this.preview});

  @override
  State<PhoneCameraScreen> createState() => _PhoneCameraScreenState();
}

class PhoneCamPreview {
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
  });
}

const _kTok = 'phonecam_token', _kCam = 'phonecam_camera', _kSite = 'phonecam_site';
const _kCamName = 'phonecam_camname';
const _kAudio = 'phonecam_audio', _kCap = 'phonecam_cap_mb';
const _channel = MethodChannel('com.assisto/shopbox');
const _notifId = 7310;
const _heartbeatEvery = Duration(seconds: 20);
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

  // clips on this phone
  int _clipCount = 0;
  int _clipBytes = 0;

  ShopDeviceClient? get _dev =>
      _token == null ? null : ShopDeviceClient(_token!, cameraId: _cameraId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final c = widget.initialCode;
    if (c != null && c.isNotEmpty) _code.text = normalizePairCode(c) ?? c;
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      if (!_inLive) _closeCamera();
    } else if (s == AppLifecycleState.resumed) {
      if (!_inLive && _cam == null) _openCamera();
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

  /// ~10 s clip of what happened, kept ONLY on this phone.
  Future<void> _recordClip(CameraController c) async {
    try {
      await c.startVideoRecording();
      await Future.delayed(_clipLength);
      final f = await c.stopVideoRecording();
      final src = File(f.path);
      final size = await src.length();
      await _enforceCap(incoming: size);
      final d = await _clipDir();
      if (d == null) return;
      final name = 'clip_${DateTime.now().millisecondsSinceEpoch}.mp4';
      try {
        await src.rename('${d.path}/$name');
      } catch (_) {
        await src.copy('${d.path}/$name');
        await src.delete();
      }
      await _refreshClips();
    } catch (e) {
      reportNonFatal('phonecam.clip', e);
      try {
        if (c.value.isRecordingVideo) await c.stopVideoRecording();
      } catch (_) {}
    }
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
    unawaited(_notif(true));
    await _heartbeat();
    _hb = Timer.periodic(_heartbeatEvery, (_) => _heartbeat());
    await _openCamera();
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
    // Play: explain the camera ask before the plugin's own system prompt.
    if (!await showPermissionReason(context, PermKind.camera)) return;
    if (!mounted) return;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus(t.shopModeNoCamera);
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.medium,
          enableAudio: _audio, imageFormatGroup: ImageFormatGroup.yuv420);
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

  Future<void> _closeCamera() async {
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
    final now = DateTime.now();
    if (_busy || _inLive || now.difference(_lastFrame).inMilliseconds < 330) return;
    _lastFrame = now;
    try {
      final p = img.planes.first;
      final grid = _motion.downsample(p.bytes, img.width, img.height, p.bytesPerRow);
      final wasDark = _dark.dark;
      _dark.feed(DarkMonitor.meanOf(grid), now);
      if (wasDark != _dark.dark) unawaited(_heartbeat());
      final r = _motion.feedGrid(grid);
      if (!r.motion) return;
      final last = _lastAlert;
      final cool = _detect != null ? _personCooldown : _motionOnlyCooldown;
      if (last != null && now.difference(last) < cool) return;
      if (_lastCheck != null && now.difference(_lastCheck!).inSeconds < 5) return;
      _lastCheck = now;
      _busy = true;
      unawaited(_onMotion().whenComplete(() => _busy = false));
    } catch (_) {} // a malformed frame is skipped, never fatal
  }

  /// Motion -> one photo -> person check on THIS phone -> alert (+ clip).
  Future<void> _onMotion() async {
    final c = _cam;
    final dev = _dev;
    if (c == null || dev == null) return;
    Uint8List? jpeg;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      final f = await c.takePicture();
      jpeg = await f.readAsBytes();
      try {
        await File(f.path).delete();
      } catch (_) {}
    } catch (_) {
      jpeg = null;
    }
    try {
      final detect = _detect;
      List<List<double>>? boxes;
      if (detect != null && jpeg != null) boxes = await detect(jpeg);
      final alert = phoneAlert(modelAvailable: detect != null, boxes: boxes);
      if (alert != null) {
        _lastAlert = DateTime.now();
        final snap = (jpeg != null && jpeg.length <= _maxSnapshotBytes) ? jpeg : null;
        final r = await dev.ingest(alert.type, alert.signals, snapshot: snap);
        if (mounted && r.ok) setState(() => _alerts++);
        if (_cam == c && _running && !_inLive) await _recordClip(c);
      }
    } finally {
      try {
        if (_cam == c && _running && !_inLive && !c.value.isStreamingImages) {
          _motion.reset();
          await c.startImageStream(_onFrame);
        }
      } catch (_) {}
    }
  }

  Future<void> _heartbeat() async {
    final dev = _dev;
    if (dev == null || widget.preview != null) return;
    Map? batt;
    try {
      batt = await _channel.invokeMapMethod<String, dynamic>('battery');
    } catch (_) {}
    final health = healthReport(batt, dark: _dark.dark);
    final r = await dev.heartbeat(caps: const ['live', 'phone'], health: health);
    if (!mounted) return;
    if (r.unauthorized || r.status == 404) {
      // the owner removed this camera: honest message, back to pairing
      await _stop();
      await _forget();
      if (mounted) _snack(AppLocalizations.of(context).pcRemovedByOwner);
      return;
    }
    setState(() {
      _online = r.ok;
      _warnings = localWarnings(health);
    });
    if (!r.ok) return;
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
      if (mounted && _running) await _openCamera();
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

  String _mb(int bytes) => fmtInt(context, (bytes / (1024 * 1024)).round());

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_running) return _runningView(t);
    return Scaffold(
      appBar: AppBar(title: Text(t.pcTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
              children: _token == null ? _pairView(t) : _readyView(t),
            ),
    );
  }

  Widget _card(IconData icon, String title, String body) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(height: 1.4)),
              ]),
            ),
          ]),
        ),
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
            hintText: '12-ABC234',
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
        const SizedBox(height: 16),
        _card(Icons.privacy_tip_rounded, t.pcTrustTitle, t.pcTrustBody),
      ];

  List<Widget> _readyView(AppLocalizations t) {
    final caps = [...kClipCapChoicesMb];
    if (!caps.contains(_capMb)) caps.add(_capMb);
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.videocam_rounded),
          title: Text(_cameraName.isEmpty ? t.pcUnnamed : _cameraName,
              style: const TextStyle(fontWeight: FontWeight.w700)),
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
      Text(t.pcStartHelp, style: Theme.of(context).textTheme.bodySmall),
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
      Text(t.pcClipsHelp, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      _card(Icons.tips_and_updates_rounded, t.pcGuideTitle, t.pcGuideBody),
      const SizedBox(height: 8),
      _card(Icons.privacy_tip_rounded, t.pcTrustTitle, t.pcTrustBody),
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
                          style: const TextStyle(color: fg, fontWeight: FontWeight.w700)),
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
                      style: const TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: dim)),
                  const SizedBox(height: 4),
                  Text(_online ? t.pcServerOk : t.pcServerOffline,
                      textAlign: TextAlign.center, style: const TextStyle(color: dim)),
                  Text(_detect != null ? t.pcModelOn : t.pcModelOff,
                      textAlign: TextAlign.center, style: const TextStyle(color: dim)),
                  Text(t.pcAlertsSent(fmtInt(context, _alerts)),
                      textAlign: TextAlign.center, style: const TextStyle(color: dim)),
                  Text(t.pcClipsLine(fmtInt(context, _clipCount), _mb(_clipBytes), fmtInt(context, _capMb)),
                      textAlign: TextAlign.center, style: const TextStyle(color: dim)),
                  for (final w in _warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_warnText(t, w),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Brand.warning, fontWeight: FontWeight.w600)),
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
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
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
