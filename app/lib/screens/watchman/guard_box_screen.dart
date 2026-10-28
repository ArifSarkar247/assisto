import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../cashguard/guard_box_engine.dart';
import '../../cashguard/guard_box_model.dart';
import '../../cashguard/guard_box_net.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../shop_api.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cashguard — ASSISTO GUARD BOX: an old Android phone on the shop's Wi-Fi
/// reads a shop IP camera over the LAN, runs the cash-zone check ON THE
/// PHONE and sends only event snapshots + end-to-end-sealed clips.
///
/// Behind the server flag `guard_box_mode` (OFF until a real-phone proof).
/// No background service, no WorkManager: like Shop Box mode the phone stays
/// on this screen, plugged in, screen on (FLAG_KEEP_SCREEN_ON through the
/// existing "com.assisto/shopbox" channel). Every step is crash-guarded and
/// says honestly what works (motion only vs person model).
class GuardBoxScreen extends StatefulWidget {
  /// Tests / gallery: skip the flag check + secure storage.
  final bool force;
  final GuardBoxPreview? preview;
  const GuardBoxScreen({super.key, this.force = false, this.preview});

  @override
  State<GuardBoxScreen> createState() => _GuardBoxScreenState();
}

/// A canned state for the screenshot gallery / widget tests.
class GuardBoxPreview {
  final bool paired, running;
  final String site, camera;
  final Map<String, Object> stats;
  const GuardBoxPreview({this.paired = true, this.running = true, this.site = '', this.camera = '',
      this.stats = const {}});
}

const _kTok = 'gb_token', _kCam = 'gb_camera', _kSite = 'gb_site';
const _kUrl = 'gb_snap_url', _kUser = 'gb_cam_user', _kPass = 'gb_cam_pass', _kCamName = 'gb_cam_name';
const _shopbox = MethodChannel('com.assisto/shopbox');

class _Device implements GuardDevice {
  final ShopDeviceClient c;
  _Device(this.c);
  @override
  Future<(int, Map<String, dynamic>)> ingest(String type, Map<String, dynamic> signals,
      {Uint8List? snapshot, String? clipRef}) async {
    final r = await c.ingest(type, signals, snapshot: snapshot, clipRef: clipRef);
    return (r.status, r.body);
  }

  @override
  Future<(int, Map<String, dynamic>)> uploadClip(String ref, Map<String, dynamic> meta, Uint8List blob) async {
    final r = await c.uploadClip(ref, meta, blob);
    return (r.status, r.body);
  }
}

/// JPEG -> small greyscale frame via the engine's own image decoder.
Future<GrayFrame?> decodeGray(Uint8List jpeg, {int width = 160}) async {
  try {
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: width);
    final fr = await codec.getNextFrame();
    final img = fr.image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = img.width, h = img.height;
    img.dispose();
    codec.dispose();
    if (bd == null) return null;
    final rgba = bd.buffer.asUint8List();
    final y = Uint8List(w * h);
    for (var i = 0, j = 0; i < y.length; i++, j += 4) {
      y[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
    }
    return GrayFrame(w, h, y);
  } catch (_) {
    return null;
  }
}

class _GuardBoxScreenState extends State<GuardBoxScreen> {
  static const _secure = FlutterSecureStorage();
  final _code = TextEditingController();
  final _host = TextEditingController();
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  String _vendor = 'onvif';

  bool _loading = true;
  String? _token;
  int? _cameraId;
  String _site = '', _camName = '';
  List<Map<String, dynamic>> _pairCams = const [];
  String _msg = '';
  bool _busy = false;

  List<DiscoveredCamera> _found = const [];
  bool _scanning = false;
  String? _snapUrl;
  Uint8List? _testFrame;

  GuardBoxEngine? _engine;
  Timer? _loop, _hb, _cfg;
  bool _tickBusy = false;
  bool _running = false;
  bool? _charging;
  final Stopwatch _setupClock = Stopwatch();
  Duration? _setupTook;

  bool get _flagOn => widget.force || FeatureFlags.instance.isOn('guard_box_mode');

  @override
  void initState() {
    super.initState();
    // buttons enable as soon as their field has text (no dead taps)
    void redraw() {
      if (mounted) setState(() {});
    }
    _code.addListener(redraw);
    _host.addListener(redraw);
    final p = widget.preview;
    if (p != null) {
      _token = p.paired ? 'preview' : null;
      _site = p.site;
      _camName = p.camera;
      _running = p.running;
      _loading = false;
      return;
    }
    _setupClock.start();
    _restore();
  }

  @override
  void dispose() {
    _stop(silent: true);
    _code.dispose();
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      _token = await _secure.read(key: _kTok);
      _cameraId = int.tryParse(await _secure.read(key: _kCam) ?? '');
      _site = await _secure.read(key: _kSite) ?? '';
      _camName = await _secure.read(key: _kCamName) ?? '';
      _snapUrl = await _secure.read(key: _kUrl);
      _user.text = await _secure.read(key: _kUser) ?? _user.text;
      _pass.text = await _secure.read(key: _kPass) ?? '';
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pair() async {
    final t = AppLocalizations.of(context);
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    final r = await ShopDeviceClient(code).pairCheck();
    if (!mounted) return;
    if (r.ok) {
      _token = code;
      _site = ((r.body['site'] as Map?)?['name'] ?? '').toString();
      final cam = r.body['camera'];
      if (cam is Map) {
        _cameraId = (cam['id'] as num?)?.toInt();
        _camName = (cam['name'] ?? '').toString();
      } else {
        _pairCams = wmList(r.body['cameras']);
        if (_pairCams.length == 1) {
          _cameraId = (_pairCams.first['id'] as num).toInt();
          _camName = (_pairCams.first['name'] ?? '').toString();
        }
      }
      await _save();
    } else {
      _msg = r.unauthorized ? t.gbPairWrong : t.gbOffline;
    }
    setState(() => _busy = false);
  }

  Future<void> _save() async {
    try {
      await _secure.write(key: _kTok, value: _token);
      await _secure.write(key: _kSite, value: _site);
      await _secure.write(key: _kCamName, value: _camName);
      if (_cameraId != null) await _secure.write(key: _kCam, value: '$_cameraId');
    } catch (_) {
      // best-effort: pairing works this session; only the restore after a restart is lost
    }
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final f = await discoverOnvif();
    if (mounted) {
      setState(() {
        _found = f;
        _scanning = false;
      });
    }
  }

  Future<void> _test() async {
    final t = AppLocalizations.of(context);
    final host = _host.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busy = true;
      _msg = '';
      _testFrame = null;
    });
    final candidates = <String>[];
    final x = _found.where((d) => d.host == host).map((d) => d.xaddr).toList();
    final xaddr = x.isNotEmpty ? x.first : 'http://$host/onvif/device_service';
    if (_vendor == 'onvif') {
      final u = await onvifSnapshotUri(xaddr, _user.text, _pass.text);
      if (u != null) candidates.add(u);
    }
    candidates.addAll(vendorSnapshotUrls(_vendor, host));
    String? ok;
    Uint8List? frame;
    var status = 0;
    for (final u in candidates) {
      final f = SnapshotFetcher(u, _user.text, _pass.text);
      frame = await f.fetch();
      status = f.lastStatus;
      f.close();
      if (frame != null) {
        ok = u;
        break;
      }
    }
    if (!mounted) return;
    if (ok != null) {
      _snapUrl = ok;
      _testFrame = frame;
      _setupTook ??= _setupClock.elapsed;
      try {
        await _secure.write(key: _kUrl, value: ok);
        await _secure.write(key: _kUser, value: _user.text);
        await _secure.write(key: _kPass, value: _pass.text);
      } catch (_) {
        // best-effort: the tested camera works now; it is just re-typed after a restart
      }
    } else {
      _msg = status == 401 ? t.gbCamAuth : (status == 0 ? t.gbCamUnreachable : t.gbCamNoSnapshot);
    }
    setState(() => _busy = false);
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    final url = _snapUrl, tok = _token;
    if (url == null || tok == null) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final dev = ShopDeviceClient(tok, cameraId: _cameraId);
      final fetcher = SnapshotFetcher(url, _user.text, _pass.text);
      final detect = await guardPersonDetector();
      final eng = GuardBoxEngine(
          device: _Device(dev), fetch: fetcher.fetch, decode: decodeGray, detect: detect);
      final cfg = await dev.config();
      if (cfg.ok) eng.applyConfig(cfg.body);
      _engine = eng;
      if (!eng.hasZone) _msg = t.gbNoZone;
      try {
        await _shopbox.invokeMethod('keepScreenOn', {'on': true});
        _charging = await _shopbox.invokeMethod<bool>('isCharging');
      } catch (_) {
        // best-effort: keep-screen-on / charging hint are optional helpers
      }
      _loop = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
      _hb = Timer.periodic(const Duration(seconds: 20), (_) {
        dev.heartbeat(caps: const ['gateway', 'guardbox', 'clip']);
      });
      _cfg = Timer.periodic(const Duration(seconds: 60), (_) async {
        final c = await dev.config();
        if (c.ok) eng.applyConfig(c.body);
      });
      dev.heartbeat(caps: const ['gateway', 'guardbox', 'clip']);
      _running = true;
    } catch (_) {
      _msg = t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _tick() async {
    final e = _engine;
    if (e == null || _tickBusy) return;
    _tickBusy = true;
    try {
      await e.tick();
    } catch (_) {
      // never let one bad frame stop the guard
    }
    _tickBusy = false;
    if (mounted) setState(() {});
  }

  void _stop({bool silent = false}) {
    _loop?.cancel();
    _hb?.cancel();
    _cfg?.cancel();
    _engine = null;
    if (_running) {
      _shopbox.invokeMethod('keepScreenOn', {'on': false}).catchError((_) {
        // best-effort: the window flag goes away with the screen anyway
        return null;
      });
      closeGuardDetector();
    }
    _running = false;
    if (!silent && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget body;
    if (!_flagOn) {
      body = ListView(padding: const EdgeInsets.all(32), children: [
        const Icon(Icons.lock_clock_outlined, size: 56),
        const SizedBox(height: 12),
        Text(t.gbNotYet, textAlign: TextAlign.center),
      ]);
    } else if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(t.gbIntro),
        const SizedBox(height: 4),
        Text(t.gbHonest, style: Theme.of(context).textTheme.bodySmall),
        _pairCard(t),
        if (_token != null) _cameraCard(t),
        if (_token != null && (_snapUrl != null || widget.preview != null)) _runCard(t),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_msg, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ]);
    }
    return Scaffold(appBar: AppBar(title: Text(t.gbTitle)), body: body);
  }

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _pairCard(AppLocalizations t) {
    if (_token != null) {
      return _card(t.gbStepPair, [
        WmPill(label: t.gbPairedTo(_site.isEmpty ? '-' : _site), icon: Icons.check_circle_rounded, color: wmOk()),
        if (_pairCams.length > 1 && _cameraId == null) ...[
          const SizedBox(height: 8),
          Text(t.gbPickCamera),
          for (final c in _pairCams)
            ListTile(
              minTileHeight: 48,
              leading: const Icon(Icons.videocam_rounded),
              title: Text((c['name'] ?? '').toString()),
              onTap: () async {
                setState(() {
                  _cameraId = (c['id'] as num).toInt();
                  _camName = (c['name'] ?? '').toString();
                });
                await _save();
              },
            ),
        ],
      ]);
    }
    return _card(t.gbStepPair, [
      Text(t.gbPairHelp),
      const SizedBox(height: 8),
      TextField(
        controller: _code,
        decoration: InputDecoration(labelText: t.gbPairCode, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy || _code.text.trim().isEmpty ? null : _pair,
        child: Text(t.gbPair),
      ),
    ]);
  }

  Widget _cameraCard(AppLocalizations t) {
    return _card(t.gbStepCamera, [
      if (_snapUrl != null && _testFrame == null && !_running)
        WmPill(label: t.gbCamReady(_camName.isEmpty ? '-' : _camName), icon: Icons.check_circle_rounded, color: wmOk()),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: _scanning
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.wifi_find_rounded),
        label: Text(t.gbFind),
        onPressed: _scanning || _running ? null : _scan,
      ),
      for (final d in _found)
        ListTile(
          minTileHeight: 48,
          leading: const Icon(Icons.videocam_outlined),
          title: Text(d.name.isEmpty ? d.host : d.name),
          subtitle: Text(d.host),
          onTap: () => setState(() {
            _host.text = d.host;
            _vendor = 'onvif';
          }),
        ),
      if (!_scanning && _found.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.gbFindHelp, style: Theme.of(context).textTheme.bodySmall),
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _vendor,
        decoration: InputDecoration(labelText: t.gbVendor, border: const OutlineInputBorder()),
        items: [
          DropdownMenuItem(value: 'onvif', child: Text(t.wmVendorOnvif)),
          const DropdownMenuItem(value: 'hikvision', child: Text('Hikvision')),
          const DropdownMenuItem(value: 'dahua', child: Text('Dahua / Imou')),
        ],
        onChanged: _running ? null : (v) => setState(() => _vendor = v ?? 'onvif'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _host,
        enabled: !_running,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(labelText: t.gbCamIp, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _user,
        enabled: !_running,
        decoration: InputDecoration(labelText: t.gbCamUser, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _pass,
        enabled: !_running,
        obscureText: true,
        decoration: InputDecoration(
            labelText: t.gbCamPass, helperText: t.gbCamPassNote, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      FilledButton.tonal(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy || _running || _host.text.trim().isEmpty ? null : _test,
        child: Text(t.gbTest),
      ),
      if (_testFrame != null) ...[
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Semantics(
            label: t.wmSnapshotLabel,
            image: true,
            child: Image.memory(_testFrame!, fit: BoxFit.cover),
          ),
        ),
        if (_setupTook != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(t.gbSetupTook(wmDigits(wmLang(context), _setupTook!.inSeconds)),
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    ]);
  }

  Widget _runCard(AppLocalizations t) {
    final lang = wmLang(context);
    final s = _engine?.stats.toJson() ?? widget.preview?.stats ?? const {};
    String d(Object? v) => wmDigits(lang, v ?? 0);
    final ms = (s['avg_frame_ms'] as num?) ?? 0;
    return _card(t.gbStepRun, [
      if (_running)
        WmPill(label: t.gbRunning, icon: Icons.shield_rounded, color: wmOk())
      else
        Text(t.gbRunHelp),
      if (_running && _charging == false)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(t.gbPlugIn, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      const SizedBox(height: 8),
      if (_running || widget.preview != null) ...[
        Text(t.gbStats(d(s['frames']), d(ms.round()), d(s['events']), d(s['clips_sent']))),
        const SizedBox(height: 2),
        Text(s['detector'] == 'yolox_nano' ? t.gbDetectorPerson : t.gbDetectorMotion,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
      ],
      _running
          ? OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.stop_rounded),
              label: Text(t.gbStop),
              onPressed: () => _stop(),
            )
          : FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(t.gbStart),
              onPressed: _busy ? null : _start,
            ),
    ]);
  }
}
