import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../shop_api.dart';
import '../shop_motion.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'shop_live_rtc.dart' deferred as rtc;
import '../services/error_report.dart'; // db1

/// SHOP BOX MODE — an old Android phone becomes the shop's camera.
///
/// OPT-IN and LAZY: nothing here runs at app launch. The camera only opens
/// while the owner has switched the mode ON on this screen, and everything is
/// crash-guarded (a camera/plugin failure shows an honest message; it never
/// takes the app down). No WorkManager, no background service: the phone must
/// stay on this screen, plugged in — we say so plainly.
///
/// What leaves the phone: small detection SIGNALS + at most ONE small snapshot
/// per alert (to POST shop/ingest), a heartbeat, and — only while the owner is
/// watching live — a peer-to-peer WebRTC video stream that is never recorded.
class ShopBoxModeScreen extends StatefulWidget {
  /// Tests/gallery: start in this state without touching secure storage.
  final ({String token, int? cameraId, String site, String camera})? preview;
  const ShopBoxModeScreen({super.key, this.preview});

  @override
  State<ShopBoxModeScreen> createState() => _ShopBoxModeScreenState();
}

const _kToken = 'shopbox_device_token';
const _kCamera = 'shopbox_device_camera';
const _kSite = 'shopbox_device_site';
const _kCamName = 'shopbox_device_camname';
const _kZone = 'shopbox_device_zone';
const _channel = MethodChannel('com.assisto/shopbox');

const _cooldown = Duration(minutes: 3); // per event type
const _heartbeatEvery = Duration(seconds: 15);
const _maxSnapshotBytes = 200 * 1024;

class _ShopBoxModeScreenState extends State<ShopBoxModeScreen>
    with WidgetsBindingObserver {
  static const _secure = FlutterSecureStorage();

  // pairing
  bool _loading = true;
  String? _token;
  int? _cameraId;
  String _siteName = '';
  String _cameraName = '';
  final _tokenField = TextEditingController();
  bool _checking = false;
  String _pairError = '';

  // running
  bool _running = false;
  String _status = '';
  bool _statusIsError = false;
  CameraController? _cam;
  final _detector = MotionDetector();
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _processing = false;
  final Map<String, DateTime> _lastSent = {};
  int _sentCount = 0;
  DateTime? _lastEventAt;
  Timer? _hb;
  String _configVersion = '';
  Map? _hours;
  bool _enabledByOwner = true;
  bool? _charging;
  bool _screenOnHelper = false;
  bool _online = false;

  // live
  bool _inLive = false;

  ShopDeviceClient? get _dev =>
      _token == null ? null : ShopDeviceClient(_token!, cameraId: _cameraId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop(silent: true);
    _tokenField.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // The camera belongs to the visible activity: release it when we leave and
    // reopen it when the owner comes back (honest: no hidden background camera).
    if (!_running) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) {
      if (!_inLive) _closeCamera();
    } else if (s == AppLifecycleState.resumed) {
      if (!_inLive && _cam == null) _openCamera();
    }
  }

  Future<void> _restore() async {
    final p = widget.preview;
    if (p != null) {
      _token = p.token;
      _cameraId = p.cameraId;
      _siteName = p.site;
      _cameraName = p.camera;
    } else {
      try {
        _token = await _secure.read(key: _kToken);
        _cameraId = int.tryParse(await _secure.read(key: _kCamera) ?? '');
        _siteName = await _secure.read(key: _kSite) ?? '';
        _cameraName = await _secure.read(key: _kCamName) ?? '';
        final prefs = await SharedPreferences.getInstance();
        final z = prefs.getStringList(_kZone);
        if (z != null && z.length == 4) {
          final v = z.map(double.tryParse).toList();
          if (!v.contains(null)) {
            _detector.zone = ZoneRect(v[0]!, v[1]!, v[2]!, v[3]!);
          }
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  // ------------------------------------------------------------------ pairing
  Future<void> _pair() async {
    final t = AppLocalizations.of(context);
    final tok = _tokenField.text.trim();
    if (tok.length < 10) {
      setState(() => _pairError = t.shopModeTokenShort);
      return;
    }
    setState(() {
      _checking = true;
      _pairError = '';
    });
    final r = await ShopDeviceClient(tok).pairCheck();
    if (!mounted) return;
    setState(() => _checking = false);
    if (r.status == 0) {
      setState(() => _pairError = t.shopModeOffline);
      return;
    }
    if (!r.ok) {
      setState(() => _pairError = t.shopModeBadToken);
      return;
    }
    final site = ((r.body['site'] ?? {}) as Map)['name']?.toString() ?? '';
    int? camId;
    String camName = '';
    final cam = r.body['camera'];
    if (cam is Map) {
      camId = (cam['id'] as num?)?.toInt();
      camName = (cam['name'] ?? '').toString();
    } else {
      final cams = ((r.body['cameras'] ?? const []) as List).whereType<Map>().toList();
      if (cams.isEmpty) {
        setState(() => _pairError = t.shopModeNoCameras);
        return;
      }
      final picked = cams.length == 1
          ? cams.first
          : await showDialog<Map>(
              context: context,
              builder: (ctx) => SimpleDialog(
                    title: Text(t.shopModePickCamera),
                    children: [
                      for (final c in cams)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, c),
                          child: Text((c['name'] ?? '').toString().isEmpty
                              ? '#${c['id']}'
                              : c['name'].toString()),
                        ),
                    ],
                  ));
      if (picked == null) return;
      camId = (picked['id'] as num?)?.toInt();
      camName = (picked['name'] ?? '').toString();
    }
    try {
      await _secure.write(key: _kToken, value: tok);
      await _secure.write(key: _kCamera, value: camId?.toString() ?? '');
      await _secure.write(key: _kSite, value: site);
      await _secure.write(key: _kCamName, value: camName);
    } catch (e) {
      // db1: pairing works for this session; only the saved copy failed.
      reportNonFatal('shopBox.savePairing', e);
    }
    setState(() {
      _token = tok;
      _cameraId = camId;
      _siteName = site;
      _cameraName = camName;
      _tokenField.clear();
    });
  }

  Future<void> _unpair() async {
    await _stop();
    try {
      for (final k in [_kToken, _kCamera, _kSite, _kCamName]) {
        await _secure.delete(key: k);
      }
    } catch (_) {} // best-effort: local key cleanup; the server unpair already happened
    if (mounted) {
      setState(() {
        _token = null;
        _cameraId = null;
        _siteName = '';
        _cameraName = '';
      });
    }
  }

  // ------------------------------------------------------------------ running
  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _running = true;
      _status = t.shopModeStarting;
      _statusIsError = false;
    });
    try {
      _screenOnHelper = await _channel.invokeMethod<bool>('keepScreenOn', {'on': true}) ?? false;
      _charging = await _channel.invokeMethod<bool>('isCharging');
    } catch (_) {
      _screenOnHelper = false; // native helper not in this build — guidance below
    }
    await _heartbeat();
    _hb = Timer.periodic(_heartbeatEvery, (_) => _heartbeat());
    await _openCamera();
  }

  Future<void> _stop({bool silent = false}) async {
    _hb?.cancel();
    _hb = null;
    await _closeCamera();
    try {
      await _channel.invokeMethod('keepScreenOn', {'on': false});
    } catch (_) {} // best-effort: screen-on flag cleanup
    _running = false;
    if (!silent && mounted) setState(() => _status = '');
  }

  Future<void> _openCamera() async {
    final t = AppLocalizations.of(context);
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus(t.shopModeNoCamera, error: true);
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.low,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      _cam = c;
      _detector.reset();
      await c.startImageStream(_onFrame);
      _setStatus(t.shopModeWatching);
    } on CameraException catch (e) {
      _setStatus(
          e.code.contains('Denied') || e.code.contains('denied')
              ? t.shopModeCameraDenied
              : t.shopModeCameraFailed,
          error: true);
    } catch (_) {
      _setStatus(t.shopModeCameraFailed, error: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _closeCamera() async {
    final c = _cam;
    _cam = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  void _setStatus(String s, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _statusIsError = error;
    });
  }

  void _onFrame(CameraImage img) {
    final now = DateTime.now();
    if (_processing || now.difference(_lastFrame).inMilliseconds < 330) return;
    if (!_enabledByOwner || _inLive) return;
    _lastFrame = now;
    _processing = true;
    try {
      final p = img.planes.first;
      final r = _detector.feed(p.bytes, img.width, img.height, p.bytesPerRow);
      final ev = decideEvent(r,
          afterHours: isAfterHours(_hours, now), hasZone: _detector.zone != null);
      if (ev != null) {
        final last = _lastSent[ev.type];
        if (last == null || now.difference(last) >= _cooldown) {
          _lastSent[ev.type] = now;
          unawaited(_send(ev.type, ev.signals));
        }
      }
    } catch (_) {
      // a malformed frame is skipped, never fatal
    } finally {
      _processing = false;
    }
  }

  /// ONE small still for the alert: pause the stream, take a low-res photo,
  /// resume. Skipped (signals only) if anything fails or it is too big.
  Future<Uint8List?> _snapshot() async {
    final c = _cam;
    if (c == null) return null;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      final f = await c.takePicture();
      final b = await f.readAsBytes();
      return b.length <= _maxSnapshotBytes ? b : null;
    } catch (_) {
      return null;
    } finally {
      try {
        if (_cam == c && !c.value.isStreamingImages) {
          _detector.reset();
          await c.startImageStream(_onFrame);
        }
      } catch (_) {}
    }
  }

  Future<void> _send(String type, Map<String, dynamic> signals) async {
    final dev = _dev;
    if (dev == null) return;
    final snap = await _snapshot();
    final r = await dev.ingest(type, signals, snapshot: snap);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _sentCount++;
        _lastEventAt = DateTime.now();
      });
    } else if (r.unauthorized) {
      _setStatus(AppLocalizations.of(context).shopModeBadToken, error: true);
    }
  }

  Future<void> _heartbeat() async {
    final dev = _dev;
    if (dev == null) return;
    final r = await dev.heartbeat(caps: const ['live']);
    if (!mounted) return;
    if (r.unauthorized) {
      _setStatus(AppLocalizations.of(context).shopModeBadToken, error: true);
      setState(() => _online = false);
      return;
    }
    setState(() => _online = r.ok);
    if (!r.ok) return;
    final v = (r.body['config_version'] ?? '').toString();
    if (v.isNotEmpty && v != _configVersion) await _pullConfig(dev, v);
    final pending = ((r.body['live_pending'] ?? const []) as List).whereType<Map>().toList();
    if (pending.isNotEmpty && !_inLive) {
      unawaited(_answerLive(pending.first.cast<String, dynamic>()));
    }
    try {
      _charging = await _channel.invokeMethod<bool>('isCharging');
    } catch (_) {}
  }

  Future<void> _pullConfig(ShopDeviceClient dev, String version) async {
    final r = await dev.config();
    if (!r.ok) return;
    final cams = ((r.body['cameras'] ?? const []) as List).whereType<Map>().toList();
    Map? mine;
    for (final c in cams) {
      if (_cameraId == null || c['id'] == _cameraId) {
        mine = c;
        break;
      }
    }
    if (mine == null) return;
    _configVersion = version;
    final h = mine['hours'];
    _hours = h is Map && h.isNotEmpty ? h : null;
    final wasEnabled = _enabledByOwner;
    _enabledByOwner = mine['enabled'] != false;
    if (mounted && wasEnabled != _enabledByOwner) {
      final t = AppLocalizations.of(context);
      _setStatus(_enabledByOwner ? t.shopModeWatching : t.shopModeOwnerOff,
          error: !_enabledByOwner);
    }
  }

  // ------------------------------------------------------------------ live
  /// Answer an owner's live-view request as the WebRTC SENDER. The detection
  /// camera is released first (one app owns the camera at a time) and reopened
  /// after the session. Media is peer-to-peer (or TURN relay) and never stored.
  Future<void> _answerLive(Map<String, dynamic> s) async {
    final dev = _dev;
    final sid = (s['id'] as num?)?.toInt();
    if (dev == null || sid == null) return;
    final t = AppLocalizations.of(context);
    _inLive = true;
    _setStatus(t.shopModeLive);
    await _closeCamera();
    dynamic peer;
    var after = 0;
    var answered = false;
    var relayed = false;
    DateTime? since;
    final expires = DateTime.tryParse((s['expires_at'] ?? '').toString())?.toLocal() ??
        DateTime.now().add(const Duration(minutes: 10));
    try {
      await rtc.loadLibrary();
      final ice = ((s['ice']?['ice_servers'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      peer = await rtc.LivePeer.create(ice,
          sender: true, onCandidate: (c) => dev.signal(sid, 'candidate', c));
      while (mounted && _running && DateTime.now().isBefore(expires)) {
        final r = await dev.poll(sid, after);
        if (!r.ok) {
          if (r.status == 404 || r.status == 401) break;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        after = (r.body['seq'] as num?)?.toInt() ?? after;
        final st = (r.body['status'] ?? '').toString();
        var bye = st == 'ended' || st == 'expired';
        for (final m in ((r.body['messages'] ?? const []) as List).whereType<Map>()) {
          final p = m['payload'];
          if (m['kind'] == 'offer' && p is Map && !answered) {
            final ans = await peer.answer(p.cast<String, dynamic>());
            await dev.signal(sid, 'answer', ans);
            answered = true;
            since = DateTime.now();
          } else if (m['kind'] == 'candidate' && p is Map) {
            try {
              await peer.addCandidate(p.cast<String, dynamic>());
            } catch (_) {}
          } else if (m['kind'] == 'bye') {
            bye = true;
          }
        }
        if (bye) break;
        if (answered && !relayed) {
          try {
            relayed = await peer.isRelayed() as bool;
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    } catch (_) {
      // honest: the session simply ends; detection resumes below
    } finally {
      try {
        await peer?.dispose();
      } catch (_) {}
      final secs = since == null ? 0 : DateTime.now().difference(since).inSeconds;
      await dev.end(sid, relayed: relayed, seconds: secs);
      _inLive = false;
      if (mounted && _running) {
        await _openCamera();
      }
    }
  }

  // ------------------------------------------------------------------ zone
  Future<void> _editZone() async {
    final z = await showDialog<ZoneRect?>(
      context: context,
      builder: (_) => _ZoneDialog(initial: _detector.zone),
    );
    if (z == null) return;
    final valid = z.isValid ? z : null;
    setState(() => _detector.zone = valid);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (valid == null) {
        await prefs.remove(_kZone);
      } else {
        await prefs.setStringList(
            _kZone, [valid.left, valid.top, valid.right, valid.bottom].map((e) => '$e').toList());
      }
    } catch (_) {} // best-effort: the zone is applied now; only its saved copy can fail
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.shopModeTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
              children: _token == null ? _pairView(t) : _runView(t),
            ),
    );
  }

  Widget _infoCard(IconData icon, String title, String body, {Color? tint}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: tint ?? scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(body,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
            ]),
          ),
        ]),
      ),
    );
  }

  List<Widget> _pairView(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return [
      _infoCard(Icons.phone_android, t.shopModeIntroTitle, t.shopModeIntroBody),
      const SizedBox(height: Gap.md),
      _infoCard(Icons.privacy_tip_outlined, t.shopModePrivacyTitle, t.shopModePrivacyBody),
      const SizedBox(height: Gap.lg),
      Text(t.shopModePairTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      Text(t.shopModePairHelp,
          style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _tokenField,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: t.shopModeTokenLabel,
          errorText: _pairError.isEmpty ? null : _pairError,
          errorMaxLines: 3,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: t.shopModePaste,
            icon: const Icon(Icons.content_paste),
            onPressed: () async {
              final d = await Clipboard.getData('text/plain');
              if (d?.text != null) _tokenField.text = d!.text!.trim();
            },
          ),
        ),
      ),
      const SizedBox(height: Gap.md),
      FilledButton.icon(
        onPressed: _checking ? null : _pair,
        icon: _checking
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.link),
        label: Text(t.shopModePair),
      ),
      const SizedBox(height: Gap.sm),
      Text(t.shopModeNoScan,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
    ];
  }

  List<Widget> _runView(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final z = _detector.zone;
    return [
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.videocam_outlined, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_cameraName.isEmpty ? t.shopBoxUnnamedCamera : _cameraName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(t.shopModePairedTo(_siteName.isEmpty ? '—' : _siteName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: Gap.md),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _running,
              title: Text(t.shopModeSwitch),
              subtitle: Text(_running ? t.shopModeOnHelp : t.shopModeOffHelp),
              onChanged: (v) => v ? _start() : _stop(),
            ),
            if (_status.isNotEmpty)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_statusIsError ? Icons.error_outline : Icons.radio_button_checked,
                    size: 18, color: _statusIsError ? scheme.error : AssistoTokens.of(context).success),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(_status,
                        style: TextStyle(
                            color: _statusIsError ? scheme.error : null, height: 1.35))),
              ]),
            if (_running) ...[
              const SizedBox(height: Gap.sm),
              Text(_online ? t.shopModeServerOk : t.shopModeServerOffline,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              Text(
                  _lastEventAt == null
                      ? t.shopModeNoEvents
                      : t.shopModeEventsSent(
                          fmtInt(context, _sentCount),
                          MaterialLocalizations.of(context)
                              .formatTimeOfDay(TimeOfDay.fromDateTime(_lastEventAt!))),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
      if (_running && _cam != null && _cam!.value.isInitialized) ...[
        const SizedBox(height: Gap.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(fit: StackFit.expand, children: [
              CameraPreview(_cam!),
              if (z != null)
                LayoutBuilder(builder: (ctx, c) {
                  return Stack(children: [
                    Positioned(
                      left: z.left * c.maxWidth,
                      top: z.top * c.maxHeight,
                      width: (z.right - z.left) * c.maxWidth,
                      height: (z.bottom - z.top) * c.maxHeight,
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              border: Border.all(color: AssistoTokens.of(context).warning, width: 2))),
                    ),
                  ]);
                }),
            ]),
          ),
        ),
      ],
      const SizedBox(height: Gap.md),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.crop_free),
        title: Text(t.shopModeZone),
        subtitle: Text(z == null ? t.shopModeZoneNone : t.shopModeZoneSet),
        trailing: const Icon(Icons.chevron_right),
        onTap: _editZone,
      ),
      const SizedBox(height: Gap.sm),
      _infoCard(
          Icons.battery_charging_full,
          t.shopModeGuideTitle,
          [
            if (_charging == false) t.shopModeNotCharging,
            t.shopModeGuideBody,
            if (!_screenOnHelper) t.shopModeScreenTimeout,
          ].join('\n\n'),
          tint: _charging == false ? AssistoTokens.of(context).warning : null),
      const SizedBox(height: Gap.md),
      _infoCard(Icons.privacy_tip_outlined, t.shopModePrivacyTitle, t.shopModePrivacyBody),
      const SizedBox(height: Gap.md),
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: scheme.error),
        onPressed: _unpair,
        icon: const Icon(Icons.logout),
        label: Text(t.shopModeUnpair),
      ),
    ];
  }
}

/// A simple rectangle editor: four sliders (left/top/right/bottom, 0-100%).
class _ZoneDialog extends StatefulWidget {
  final ZoneRect? initial;
  const _ZoneDialog({this.initial});
  @override
  State<_ZoneDialog> createState() => _ZoneDialogState();
}

class _ZoneDialogState extends State<_ZoneDialog> {
  late double l, tp, r, b;
  @override
  void initState() {
    super.initState();
    final z = widget.initial ?? const ZoneRect(0.3, 0.5, 0.7, 0.95);
    l = z.left;
    tp = z.top;
    r = z.right;
    b = z.bottom;
  }

  Widget _s(String label, double v, ValueChanged<double> on) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label  ${(v * 100).round()}%'),
          Slider(value: v, onChanged: on),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.shopModeZone),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(t.shopModeZoneHelp, style: AType.bodySmall.copyWith(height: 1.4)),
          const SizedBox(height: Gap.sm),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: LayoutBuilder(builder: (ctx, c) {
              final ok = r > l && b > tp;
              return DecoratedBox(
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Radii.sm)),
                child: Stack(children: [
                  if (ok)
                    Positioned(
                      left: l * c.maxWidth,
                      top: tp * c.maxHeight,
                      width: (r - l) * c.maxWidth,
                      height: (b - tp) * c.maxHeight,
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: AssistoTokens.of(context).warning.withValues(alpha: 0.25),
                              border: Border.all(color: AssistoTokens.of(context).warning, width: 2))),
                    ),
                ]),
              );
            }),
          ),
          _s(t.shopModeZoneLeft, l, (v) => setState(() => l = v)),
          _s(t.shopModeZoneTop, tp, (v) => setState(() => tp = v)),
          _s(t.shopModeZoneRight, r, (v) => setState(() => r = v)),
          _s(t.shopModeZoneBottom, b, (v) => setState(() => b = v)),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, const ZoneRect(0, 0, 0, 0)),
            child: Text(t.shopModeZoneClear)),
        FilledButton(
            onPressed: () => Navigator.pop(context, ZoneRect(l, tp, r, b)),
            child: Text(t.save)),
      ],
    );
  }
}
