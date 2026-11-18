import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../widgets/skeleton.dart';
import '../ds/ds.dart';
import '../theme.dart' show AType;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../cashguard/guard_box_engine.dart' show PersonDetect;
import '../cashguard/guard_box_model.dart';
import '../cashguard/guard_box_net.dart' show DiscoveredCamera, discoverOnvif;
import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../phonecam/phonecam_api.dart';
import '../phonecam/phonecam_logic.dart' show DarkMonitor, normalizePairCode;
import '../services/error_report.dart';
import '../shop_api.dart';
import '../shop_motion.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_digits.dart' show ld;
import '../screens/shop_live_rtc.dart' deferred as rtc;
import 'box_siren.dart';
import 'ipcam_decoder.dart';
import 'ipcam_logic.dart';
import 'ipcam_pipeline.dart';
import 'ipcam_presets.dart';
import 'rtsp_client.dart';

/// cctvbox — GUARD BOX for IP cameras WITHOUT a PC (owner CCTV gaps 9 Nov,
/// item 5): an old Android phone on the same Wi-Fi pulls the camera's RTSP
/// stream, decodes it on the phone, runs the SAME motion + on-phone person
/// check as the phone camera, sends photo alerts and answers the owner's
/// live view (WebRTC; pictures over a data channel; our relay only when P2P
/// is impossible).
///
/// Pairing = the phone-camera code (the owner's "Use an old phone as a
/// camera" QR), so the camera shows up in the owner's list like any phone
/// camera. The camera's address and password stay ONLY on this phone
/// (encrypted secure storage) — they are never sent to Assisto.
/// No new permission, no WorkManager, no background service: it runs while
/// this screen is open (screen kept on, plugged in). Behind the server flag
/// `guard_box_mode` (OFF until the CI emulator E2E proof).
class IpCamGuardScreen extends StatefulWidget {
  /// Tests / gallery: skip the flag check.
  final bool force;
  final String? initialCode;

  /// Tests / gallery: a canned state, no storage, no network.
  final IpCamPreview? preview;
  const IpCamGuardScreen({super.key, this.force = false, this.initialCode, this.preview});

  @override
  State<IpCamGuardScreen> createState() => _IpCamGuardScreenState();
}

class IpCamPreview {
  final bool paired;
  final bool tested;
  final bool running;
  final String site;
  final String camera;
  final String brand;
  final int alerts;
  final bool model;
  final bool camLost;
  final bool lowPower;
  const IpCamPreview({
    this.paired = true,
    this.tested = false,
    this.running = false,
    this.site = '',
    this.camera = '',
    this.brand = 'hikvision',
    this.alerts = 0,
    this.model = true,
    this.camLost = false,
    this.lowPower = false,
  });
}

// the phone-camera pairing (shared: one camera slot per phone)
const _kTok = 'phonecam_token', _kCam = 'phonecam_camera', _kSite = 'phonecam_site';
const _kCamName = 'phonecam_camname';
// the IP camera — never leaves this phone
const _kUrl = 'ipcam_url', _kBrand = 'ipcam_brand', _kHost = 'ipcam_host';
const _kUser = 'ipcam_user', _kPass = 'ipcam_pass';
const _shopbox = MethodChannel('com.assisto/shopbox');
const _maxSnapshotBytes = 200 * 1024;

class _IpCamGuardScreenState extends State<IpCamGuardScreen> {
  static const _secure = FlutterSecureStorage();

  bool _loading = true;
  String? _token;
  int? _cameraId;
  String _site = '', _camName = '';
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _claiming = false;
  String _pairError = '';

  // camera setup
  String _brand = 'hikvision';
  final _host = TextEditingController();
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  final _rtsp = TextEditingController();
  bool _showPass = false;
  List<DiscoveredCamera> _found = const [];
  bool _scanning = false;
  bool _testing = false;
  String _testMsg = '';
  String? _url; // tested, with credentials (secure storage only)
  Uint8List? _preview;
  String _works = '';

  // running
  bool _running = false;
  IpCamPipeline? _pipe;
  PersonDetect? _detect;
  final _motion = MotionDetector();
  final _dark = DarkMonitor();
  final _clock = AlertClock();
  final _pace = LivePace();
  final _offline = OfflineQueue<({String type, Map<String, dynamic> signals, Uint8List? snap})>();
  Timer? _loop, _hb;
  // speedproof: live view used to wait for the 20 s heartbeat (CI: 17.4 s to
  // the first picture). While guarding, a light shop/live/pending poll every
  // [_livePollS] s (server-tunable via the heartbeat's live_poll_s; 0 = off).
  Timer? _lp;
  int _livePollS = 4;
  bool _lpBusy = false;
  bool _tickBusy = false;
  bool _modelLoading = false;
  bool _starting = false;
  BoxSiren? _siren;
  String _played = ''; // 'siren' | 'warn' — last one the owner asked for
  DateTime _lastGrab = DateTime.fromMillisecondsSinceEpoch(0);
  int _alerts = 0, _frames = 0;
  DateTime _fpsAt = DateTime.now();
  int _fpsFrames = 0;
  double _fps = 0;
  bool _online = false;
  bool _camLost = false;
  bool _lowPower = false;
  bool? _charging;
  dynamic _peer; // rtc.LivePeer while someone watches
  bool _inLive = false;
  String _msg = '';

  bool get _flagOn => widget.force || FeatureFlags.instance.isOn('guard_box_mode');

  ShopDeviceClient? get _dev =>
      _token == null ? null : ShopDeviceClient(_token!, cameraId: _cameraId);

  @override
  void initState() {
    super.initState();
    void redraw() {
      if (mounted) setState(() {});
    }

    for (final c in [_code, _host, _rtsp, _pass, _user]) {
      c.addListener(redraw);
    }
    final c = widget.initialCode;
    if (c != null && c.isNotEmpty) _code.text = normalizePairCode(c) ?? c;
    final p = widget.preview;
    if (p != null) {
      if (p.paired) {
        _token = 'preview';
        _cameraId = 1;
      }
      _site = p.site;
      _camName = p.camera;
      _brand = p.brand;
      _host.text = '192.168.1.64';
      if (p.tested) {
        _url = 'rtsp://preview';
        _works = 'H264 · 640×360';
      }
      _running = p.running;
      _alerts = p.alerts;
      _detect = p.model ? (_) async => null : null;
      _online = p.running;
      _camLost = p.camLost;
      _lowPower = p.lowPower;
      _fps = p.running ? 3 : 0;
      _loading = false;
      return;
    }
    _restore();
  }

  @override
  void dispose() {
    _stop(silent: true);
    for (final c in [_code, _name, _host, _user, _pass, _rtsp]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      _token = await _secure.read(key: _kTok);
      _cameraId = int.tryParse(await _secure.read(key: _kCam) ?? '');
      _site = await _secure.read(key: _kSite) ?? '';
      _camName = await _secure.read(key: _kCamName) ?? '';
      _url = await _secure.read(key: _kUrl);
      _brand = await _secure.read(key: _kBrand) ?? _brand;
      _host.text = await _secure.read(key: _kHost) ?? '';
      _user.text = await _secure.read(key: _kUser) ?? defaultUser(_brand);
      _pass.text = await _secure.read(key: _kPass) ?? '';
      if (_brand == 'rtsp' && _url != null) _rtsp.text = _url!;
    } catch (e) {
      reportNonFatal('ipcam.restore', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  // ------------------------------------------------------------------ pair
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
    final name = _name.text.trim().isEmpty ? t.icgDefaultName : _name.text.trim();
    final r = await PhoneCamClaim.claim(code, name: name, model: 'guardbox-ipcam');
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
      reportNonFatal('ipcam.savePairing', e);
    }
    setState(() {
      _token = tok;
      _cameraId = (cam['id'] as num?)?.toInt();
      _site = (site['name'] ?? '').toString();
      _camName = (cam['name'] ?? '').toString();
      _code.clear();
    });
  }

  // ------------------------------------------------------------------ camera
  void _pickBrand(String b) {
    setState(() {
      _brand = b;
      _user.text = defaultUser(b);
      _testMsg = '';
    });
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final f = await discoverOnvif();
    if (!mounted) return;
    setState(() {
      _found = f;
      _scanning = false;
      if (f.length == 1) _useFound(f.first);
    });
  }

  void _useFound(DiscoveredCamera d) {
    _host.text = d.host;
    final b = guessBrand(d.name);
    if (b != _brand) {
      _brand = b;
      _user.text = defaultUser(b);
    }
  }

  Future<List<String>> _candidates() async {
    if (_brand == 'rtsp') return [_rtsp.text.trim()];
    final host = _host.text.trim();
    final out = <String>[...brandUrls(_brand, host, _user.text, _pass.text)];
    // ONVIF: the camera says its own stream address (also the fallback
    // when a brand's usual address is not this model's)
    final x = _found.where((d) => d.host == host).map((d) => d.xaddr).toList();
    final xaddr = x.isNotEmpty ? x.first : 'http://$host/onvif/device_service';
    if (host.isNotEmpty) {
      for (final u in await onvifStreamUris(xaddr, _user.text.trim(), _pass.text)) {
        if (!out.contains(u)) out.add(u);
      }
    }
    return out;
  }

  static const _failRank = ['unreachable', 'notFound', 'noVideo', 'decoder', 'codec', 'auth'];

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMsg = '';
      _preview = null;
      _works = '';
    });
    var fail = '';
    String? ok;
    IpFrame? frame;
    String codec = '';
    try {
      final dec = NativeIpDecoder();
      if (!await dec.available()) {
        fail = 'decoder';
      } else {
        for (final u in await _candidates()) {
          final r = await _probe(u, dec);
          if (r.$1 != null) {
            ok = u;
            frame = r.$1;
            codec = r.$3;
            break;
          }
          if (_failRank.indexOf(r.$2) > _failRank.indexOf(fail)) fail = r.$2;
          if (r.$2 == 'unreachable') break; // wrong address: other paths won't help
        }
      }
    } catch (e) {
      reportNonFatal('ipcam.test', e);
      fail = fail.isEmpty ? 'noVideo' : fail;
    }
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    if (ok != null && frame != null) {
      _url = ok;
      _preview = frame.jpeg;
      _works = '$codec · ${frame.w}×${frame.h}';
      try {
        await _secure.write(key: _kUrl, value: ok);
        await _secure.write(key: _kBrand, value: _brand);
        await _secure.write(key: _kHost, value: _host.text.trim());
        await _secure.write(key: _kUser, value: _user.text.trim());
        await _secure.write(key: _kPass, value: _pass.text);
      } catch (e) {
        reportNonFatal('ipcam.saveCamera', e); // works now; re-typed after a restart
      }
    } else {
      _testMsg = _failText(t, fail.isEmpty ? 'noVideo' : fail);
    }
    setState(() => _testing = false);
  }

  /// (picture, failure kind, codec) for one candidate URL.
  Future<(IpFrame?, String, String)> _probe(String url, IpDecoder dec) async {
    final p = IpCamPipeline(url, dec);
    try {
      final f = await p.start();
      if (f != null) return (null, failKey(f.name), '');
      final until = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(until)) {
        if (p.lastFail != null && p.state != PipeState.playing) {
          return (null, failKey(p.lastFail!.name), p.codec);
        }
        final fr = await p.grab(maxW: 640, timeoutMs: 3000);
        if (fr != null) return (fr, '', p.codec);
        if (!p.decoding) await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      return (null, p.decodeFails > 0 ? 'decoder' : 'noVideo', p.codec);
    } finally {
      await p.stop();
    }
  }

  String _failText(AppLocalizations t, String k) => switch (k) {
        'auth' => t.gbCamAuth,
        'unreachable' => t.gbCamUnreachable,
        'notFound' => t.icgFailNotFound,
        'codec' => t.icgFailCodec,
        'decoder' => t.icgFailDecoder,
        _ => t.icgFailNoVideo,
      };

  String _hint(AppLocalizations t) => switch (_brand) {
        'hikvision' || 'dahua' => t.icgHintHikDahua,
        'imou' => t.icgHintImou,
        'ezviz' => t.icgHintEzviz,
        'tapo' => t.icgHintTapo,
        'onvif' => t.icgHintOnvif,
        _ => t.icgHintRtsp,
      };

  String _brandName(AppLocalizations t, String b) => switch (b) {
        'hikvision' => 'Hikvision',
        'dahua' => 'Dahua',
        'imou' => 'Imou',
        'ezviz' => 'EZVIZ',
        'tapo' => 'TP-Link Tapo',
        'onvif' => t.icgBrandOnvif,
        _ => t.icgBrandRtsp,
      };

  // ------------------------------------------------------------------ run
  Future<void> _start() async {
    final url = _url, dev = _dev;
    if (url == null || dev == null || _starting || _running) return; // a double tap starts once
    _starting = true;
    try {
      await _startInner(url);
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _startInner(String url) async {
    final t = AppLocalizations.of(context);
    final dec = NativeIpDecoder();
    if (!await dec.available()) {
      setState(() => _msg = t.icgFailDecoder);
      return;
    }
    final p = IpCamPipeline(url, dec);
    _pipe = p;
    await p.run();
    _motion.reset();
    try {
      await _shopbox.invokeMethod('keepScreenOn', {'on': true});
      _charging = await _shopbox.invokeMethod<bool>('isCharging');
    } catch (_) {} // best-effort helpers
    _loop = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    _hb = Timer.periodic(const Duration(seconds: 20), (_) => _heartbeat());
    _armLivePoll();
    if (!mounted) return;
    setState(() {
      _running = true;
      _msg = '';
    });
    unawaited(_heartbeat());
    // the on-phone person model (downloaded once, SHA-256 checked); motion
    // only until it is ready, or for good when it can't run on this phone
    _modelLoading = true;
    unawaited(guardPersonDetector()
        .timeout(const Duration(seconds: 90), onTimeout: () => null)
        .then((d) {
      _modelLoading = false;
      if (mounted && _running) setState(() => _detect = d);
    }));
  }

  Future<void> _tick() async {
    final p = _pipe;
    if (p == null || _tickBusy) return;
    final now = DateTime.now();
    final live = _peer != null && _inLive;
    // ~3 pictures a second for checks; up to [LivePace.fps] while watched
    if (now.difference(_lastGrab) < (live ? _pace.every : const Duration(milliseconds: 330))) return;
    _lastGrab = now;
    _tickBusy = true;
    try {
      final f = await p.grab(maxW: live ? _pace.maxW : 640);
      if (f == null) return;
      _frames++;
      _fpsFrames++;
      final el = DateTime.now().difference(_fpsAt).inMilliseconds;
      if (el >= 3000) {
        _fps = _fpsFrames * 1000 / el;
        _fpsFrames = 0;
        _fpsAt = DateTime.now();
      }
      if (live) {
        try {
          await _peer.sendFrame(f.jpeg);
        } catch (_) {}
      }
      final grid = _motion.downsample(f.gray, f.gw, f.gh, f.gw);
      final wasDark = _dark.dark;
      _dark.feed(DarkMonitor.meanOf(grid), now);
      if (wasDark != _dark.dark) unawaited(_heartbeat());
      final r = _motion.feedGrid(grid);
      // while the person model is still loading, no movement-only alerts
      if (r.motion && !_modelLoading && _clock.mayCheck(now, model: _detect != null)) {
        _clock.lastCheck = now;
        await _onMotion(f);
      }
    } catch (e) {
      reportNonFatal('ipcam.tick', e);
    } finally {
      _tickBusy = false;
      final lost = p.lostSince != null;
      if (mounted && (lost != _camLost || p.gate.keyOnly != _lowPower || _frames % 4 == 0)) {
        setState(() {
          _camLost = lost;
          _lowPower = p.gate.keyOnly;
        });
      }
    }
  }

  /// Motion -> person check on THIS phone -> alert with the picture.
  Future<void> _onMotion(IpFrame f) async {
    final dev = _dev;
    if (dev == null) return;
    final detect = _detect;
    List<List<double>>? boxes;
    var pic = f;
    if (detect != null) {
      try {
        // cctv-accuracy: a night person seen once -> the next picture at once
        (boxes, pic) = await checkPersonOnce<IpFrame>((x) => detect(x.jpeg), f,
            next: () async {
              final p = _pipe;
              return p == null ? null : await p.grab(maxW: 640);
            }, nightPending: () => guardNightPending);
      } catch (_) {
        boxes = null;
      }
    }
    final alert = ipcamAlert(modelAvailable: detect != null, boxes: boxes, brand: _brand);
    if (alert == null) return;
    _clock.lastAlert = DateTime.now();
    final snap = pic.jpeg.length <= _maxSnapshotBytes ? pic.jpeg : null;
    final signals = {...alert.signals, 'seen_at': DateTime.now().toUtc().toIso8601String()};
    final r = await dev.ingest(alert.type, signals, snapshot: snap);
    if (r.status == 0 || r.status >= 500) {
      // internet down: keep it, send when the server answers again
      _offline.add((type: alert.type, signals: {...signals, 'sent_late': true}, snap: snap));
    }
    // the server may log a weak signal without alerting ({raised: false}):
    // only a real alert is counted on this screen
    if (mounted && r.ok && r.body['raised'] != false) setState(() => _alerts++);
  }

  Future<void> _flushOffline(ShopDeviceClient dev) async {
    final n = await _offline.flush((a) async => (await dev.ingest(a.type, a.signals, snapshot: a.snap)).ok);
    if (mounted && n > 0) setState(() => _alerts += n);
  }

  Future<void> _heartbeat() async {
    final dev = _dev;
    if (dev == null || widget.preview != null || !_running) return;
    Map? batt;
    try {
      batt = await _shopbox.invokeMapMethod<String, dynamic>('battery');
    } catch (_) {}
    final health = ipcamHealth(batt, dark: _dark.dark, lostSince: _pipe?.lostSince);
    final r = await dev.heartbeat(caps: const ['live', 'phone', 'ipcam'], health: health);
    if (!mounted) return;
    if (r.unauthorized || r.status == 404) {
      final t = AppLocalizations.of(context);
      _stop();
      await _forgetPairing();
      if (mounted) setState(() => _msg = t.pcRemovedByOwner);
      return;
    }
    setState(() {
      _online = r.ok;
      if (batt?['charging'] is bool) _charging = batt!['charging'] as bool;
    });
    if (!r.ok) return;
    if (!_offline.isEmpty) unawaited(_flushOffline(dev));
    // cctvact: the owner pressed Siren / Warning on an alert
    final play = PlayTask.fromHeartbeat(r.body['play']);
    if (play.isNotEmpty) {
      _siren ??= BoxSiren.forDevice(_token!, cameraId: _cameraId);
      unawaited(_siren!.handle(play).then((p) {
        if (mounted && p.isNotEmpty) setState(() => _played = p.last);
      }));
    }
    final ps = (r.body['live_poll_s'] as num?)?.toInt();
    if (ps != null && ps != _livePollS) {
      _livePollS = ps;
      _armLivePoll();
    }
    final pending = ((r.body['live_pending'] ?? const []) as List).whereType<Map>().toList();
    if (pending.isNotEmpty && !_inLive && _running) {
      unawaited(_answerLive(pending.first.cast<String, dynamic>()));
    }
  }

  /// speedproof: (re)start the fast live-request poll.
  void _armLivePoll() {
    _lp?.cancel();
    _lp = null;
    final every = livePollEvery(_livePollS);
    if (every == null || (!_running && _loop == null)) return;
    _lp = Timer.periodic(every, (_) => _pollLive());
  }

  Future<void> _pollLive() async {
    final dev = _dev;
    if (dev == null || widget.preview != null || _inLive || _lpBusy) return;
    if (!_running && _loop == null) return;
    _lpBusy = true;
    try {
      final r = await dev.pending();
      if (!mounted || !r.ok || _inLive) return;
      final s = ((r.body['sessions'] ?? const []) as List).whereType<Map>().toList();
      if (s.isNotEmpty) unawaited(_answerLive(s.first.cast<String, dynamic>()));
    } catch (_) {
      // offline: the heartbeat path still answers
    } finally {
      _lpBusy = false;
    }
  }

  /// The owner (or allowed family) opened live view: answer WITHOUT this
  /// phone's camera/mic; the IP camera's pictures go over the data channel
  /// from [_tick]. Never recorded.
  Future<void> _answerLive(Map<String, dynamic> s) async {
    final dev = _dev;
    final sid = (s['id'] as num?)?.toInt();
    if (dev == null || sid == null) return;
    _inLive = true;
    if (mounted) setState(() {});
    var after = 0;
    var answered = false;
    var relayed = false;
    DateTime? since;
    final expires = DateTime.tryParse((s['expires_at'] ?? '').toString())?.toLocal() ??
        DateTime.now().add(const Duration(minutes: 10));
    final hardEnd = DateTime.now().add(const Duration(minutes: 30));
    try {
      await rtc.loadLibrary();
      final ice = ((s['ice']?['ice_servers'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      _peer = await rtc.LivePeer.create(ice,
          sender: true, onCandidate: (c) => dev.signal(sid, 'candidate', c));
      var deadline = expires;
      while (mounted && _running && DateTime.now().isBefore(hardEnd)) {
        final r = await dev.poll(sid, after);
        if (!r.ok) {
          if (r.status == 404 || r.status == 401) break;
          if (DateTime.now().isAfter(deadline)) break;
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        after = (r.body['seq'] as num?)?.toInt() ?? after;
        final st = (r.body['status'] ?? '').toString();
        deadline = DateTime.tryParse((r.body['expires_at'] ?? '').toString())?.toLocal() ?? deadline;
        var bye = st == 'ended' || st == 'expired';
        for (final m in ((r.body['messages'] ?? const []) as List).whereType<Map>()) {
          final p = m['payload'];
          if (m['kind'] == 'offer' && p is Map && !answered) {
            final ans = await _peer.answerFrames(p.cast<String, dynamic>());
            await dev.signal(sid, 'answer', ans);
            answered = true;
            since = DateTime.now();
          } else if (m['kind'] == 'candidate' && p is Map) {
            try {
              await _peer.addCandidate(p.cast<String, dynamic>());
            } catch (_) {}
          } else if (m['kind'] == 'quality' && p is Map) {
            _pace.hd = p['hd'] == true;
          } else if (m['kind'] == 'bye') {
            bye = true;
          }
        }
        if (bye || DateTime.now().isAfter(deadline)) break;
        if (answered && !relayed) {
          try {
            relayed = await _peer.isRelayed() as bool;
          } catch (_) {}
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    } catch (e) {
      reportNonFatal('ipcam.live', e);
    } finally {
      final peer = _peer;
      _peer = null;
      try {
        await peer?.dispose();
      } catch (_) {}
      final secs = since == null ? 0 : DateTime.now().difference(since).inSeconds;
      await dev.end(sid, relayed: relayed, seconds: secs);
      _inLive = false;
      _pace.hd = false;
      if (mounted) setState(() {});
    }
  }

  void _stop({bool silent = false}) {
    _loop?.cancel();
    _hb?.cancel();
    _lp?.cancel();
    _loop = null;
    _hb = null;
    _lp = null;
    final p = _pipe;
    _pipe = null;
    if (p != null) unawaited(p.stop());
    if (_running) {
      _shopbox.invokeMethod('keepScreenOn', {'on': false}).catchError((_) => null);
      unawaited(closeGuardDetector());
    }
    _running = false;
    if (!silent && mounted) setState(() {});
  }

  Future<void> _forgetPairing() async {
    try {
      for (final k in [_kTok, _kCam, _kSite, _kCamName]) {
        await _secure.delete(key: k);
      }
    } catch (_) {
      // best-effort: the server already removed this camera; the token is dead anyway
    }
    if (mounted) {
      setState(() {
        _token = null;
        _cameraId = null;
        _site = '';
        _camName = '';
      });
    }
  }

  Future<void> _forgetCamera() async {
    try {
      for (final k in [_kUrl, _kBrand, _kHost, _kUser, _kPass]) {
        await _secure.delete(key: k);
      }
    } catch (_) {
      // best-effort: the screen forgets it now; a stale copy is overwritten by the next test
    }
    if (mounted) {
      setState(() {
        _url = null;
        _preview = null;
        _works = '';
        _pass.clear();
        _rtsp.clear();
      });
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget body;
    if (!_flagOn) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(t.gbNotYet, textAlign: TextAlign.center)),
      );
    } else if (_loading) {
      body = const SkeletonList();
    } else {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
        children: [
          if (!_running) _introCard(t),
          if (_msg.isNotEmpty) ...[
            const SizedBox(height: 8),
            _banner(_msg, Icons.info_outline_rounded),
          ],
          const SizedBox(height: 8),
          if (_token == null) _pairCard(t) else _pairedTile(t),
          if (_token != null && !_running) ...[
            const SizedBox(height: 12),
            _cameraCard(t),
          ],
          if (_token != null && _url != null) ...[
            const SizedBox(height: 12),
            _runCard(t),
          ],
          const SizedBox(height: 12),
          _honestCard(t),
        ],
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.icgTitle)), body: body);
  }

  Widget _banner(String text, IconData icon) => DsSurface(color: Theme.of(context).colorScheme.ds.primarySoft,
    padding: const EdgeInsets.all(12),
    child: Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.ds.primaryInk),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.ds.primaryInk)),
            ),
          ]),
  );

  Widget _section(String title, List<Widget> children) => DsCard(
    padding: const EdgeInsets.all(14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
  );

  Widget _introCard(AppLocalizations t) => DsCard(
    padding: const EdgeInsets.all(14),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.router_rounded),
            const SizedBox(width: 12),
            Expanded(child: Text(t.icgIntro, style: AType.bodyMedium.copyWith(height: 1.4))),
          ]),
  );

  Widget _pairCard(AppLocalizations t) => _section(t.icgStepPair, [
        Text(t.pcPairHereHelp),
        const SizedBox(height: 12),
        TextField(
          key: const Key('icgCode'),
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
              labelText: t.pcNameLabel, hintText: t.icgDefaultName, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('icgClaim'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _claiming || _code.text.trim().isEmpty ? null : _claim,
          icon: _claiming
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link_rounded),
          label: Text(t.pcClaim),
        ),
      ]);

  Widget _pairedTile(AppLocalizations t) => DsCard(
    padding: EdgeInsets.zero,
    child: ListTile(
          leading: const Icon(Icons.videocam_rounded),
          title: Text(_camName.isEmpty ? t.icgDefaultName : _camName,
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text(t.pcPairedTo(_site.isEmpty ? '—' : _site)),
        ),
  );

  Widget _cameraCard(AppLocalizations t) {
    final canTest = !_testing &&
        (_brand == 'rtsp' ? RtspUrl.parse(_rtsp.text) != null : _host.text.trim().isNotEmpty);
    return _section(t.icgStepCamera, [
      if (_brand != 'rtsp') ...[
        OutlinedButton.icon(
          key: const Key('icgScan'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _scanning ? null : _scan,
          icon: _scanning
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_find_rounded),
          label: Text(t.gbFind),
        ),
        for (final d in _found)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.videocam_outlined),
            title: Text(d.name.isEmpty ? d.host : d.name),
            subtitle: Text(ld(context, d.host)),
            trailing: _host.text.trim() == d.host ? const Icon(Icons.check_circle_rounded) : null,
            onTap: () => setState(() => _useFound(d)),
          ),
        if (!_scanning && _found.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t.gbFindHelp, style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
      ],
      Text(t.icgBrand, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final b in kIpCamBrands)
          ChoiceChip(
            key: Key('icgBrand_$b'),
            label: Text(_brandName(t, b)),
            selected: _brand == b,
            onSelected: (_) => _pickBrand(b),
          ),
      ]),
      const SizedBox(height: 8),
      Text(_hint(t), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      if (_brand == 'rtsp')
        TextField(
          key: const Key('icgRtsp'),
          controller: _rtsp,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: t.icgRtspUrl,
            hintText: 'rtsp://user:pass@192.168.1.20:554/stream',
            border: const OutlineInputBorder(),
          ),
        )
      else ...[
        TextField(
          key: const Key('icgHost'),
          controller: _host,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
              labelText: t.gbCamIp, hintText: ld(context, '192.168.1.64'), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('icgUser'),
          controller: _user,
          autocorrect: false,
          decoration: InputDecoration(labelText: t.gbCamUser, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('icgPass'),
          controller: _pass,
          obscureText: !_showPass,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: t.gbCamPass,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: t.icgShowPass,
              icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              onPressed: () => setState(() => _showPass = !_showPass),
            ),
          ),
        ),
      ],
      const SizedBox(height: 6),
      Row(children: [
        const Icon(Icons.lock_rounded, size: 16),
        const SizedBox(width: 6),
        Expanded(child: Text(t.gbCamPassNote, style: Theme.of(context).textTheme.bodySmall)),
      ]),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('icgTest'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: canTest ? _test : null,
        icon: _testing
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.play_circle_outline_rounded),
        label: Text(_testing ? t.icgTesting : t.gbTest),
      ),
      if (_testMsg.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(_testMsg,
            key: const Key('icgTestFail'),
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
      ],
      if (_url != null && _works.isNotEmpty) ...[
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.icgWorks(ld(context, _works)),
                key: const Key('icgWorks'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
          ),
        ]),
        if (_preview != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(_preview!, key: const Key('icgPreview'), gaplessPlayback: true),
          ),
        ],
      ],
      if (_url != null) ...[
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _forgetCamera,
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(t.icgForget),
          ),
        ),
      ],
    ]);
  }

  Widget _runCard(AppLocalizations t) {
    final small = Theme.of(context).textTheme.bodySmall;
    if (!_running) {
      return _section(t.icgStepRun, [
        if (_charging == false) ...[
          _banner(t.gbPlugIn, Icons.battery_alert_rounded),
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          key: const Key('icgStart'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
          onPressed: _starting ? null : _start,
          icon: _starting
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.shield_rounded),
          label: Text(t.gbStart),
        ),
        const SizedBox(height: 8),
        Text(t.gbRunHelp, style: small),
      ]);
    }
    final lines = <(IconData, String, Key?)>[
      (Icons.cloud_done_rounded, _online ? t.pcServerOk : t.pcServerOffline, null),
      if (_camLost)
        (Icons.videocam_off_rounded, t.icgCamLost, const Key('icgCamLost'))
      else
        (Icons.videocam_rounded, t.icgWatching(_camName.isEmpty ? t.icgDefaultName : _camName), null),
      (Icons.person_search_rounded, _detect != null ? t.pcModelOn : t.pcModelOff, null),
      (Icons.notifications_active_rounded, t.pcAlertsSent(ld(context, _alerts)), const Key('icgAlerts')),
      (Icons.speed_rounded, t.icgStats(ld(context, _fps.toStringAsFixed(1)),
          ld(context, (_pipe?.kbps ?? 0).round())), null),
      if (_lowPower) (Icons.battery_saver_rounded, t.icgLowPower, null),
      if (_inLive) (Icons.live_tv_rounded, t.pcLiveNow, const Key('icgLive')),
      if (_played.isNotEmpty)
        (Icons.campaign_rounded, _played == 'warn' ? t.icgPlayedWarn : t.icgPlayedSiren, null),
      if (_charging == false) (Icons.battery_alert_rounded, t.gbPlugIn, null),
    ];
    return _section(t.icgStepRun, [
      for (final l in lines)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(l.$1, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(l.$2, key: l.$3)),
          ]),
        ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        key: const Key('icgStop'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: () => _stop(),
        icon: const Icon(Icons.stop_circle_rounded),
        label: Text(t.gbStop),
      ),
    ]);
  }

  Widget _honestCard(AppLocalizations t) => DsCard(
    padding: const EdgeInsets.all(14),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.privacy_tip_rounded),
            const SizedBox(width: 12),
            Expanded(child: Text(t.icgHonest, style: AType.bodyMedium.copyWith(height: 1.4))),
          ]),
  );
}
