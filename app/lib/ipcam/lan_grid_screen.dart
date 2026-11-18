// cctv-accuracy — WI-FI LIVE GRID: 4 or 9 cameras of the owner's DVR / NVR
// (or separate IP cameras) live on one screen, straight from the cameras on
// the same Wi-Fi. Pure Dart RTSP (rtsp_client.dart) + the phone's own video
// decoder (IpCamDecoder.kt, one slot per tile). No Assisto server in the
// path, nothing recorded, the camera password stays in this phone's
// encrypted storage.
//
// 2 GB phones: a small tile plays the SUB stream at 3-6 pictures a second;
// a tile scrolled away (or the app in the background) is disconnected after
// 2 s; only the ONE camera opened big plays the MAIN stream (HD). Pictures
// are decoded to tile size and released at once (no image cache growth).
// Rules: lan_grid_logic.dart. Measured on a 2 GB API 33 emulator with 9
// test cameras: .github/workflows/cctv-grid.yml.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessInfo;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../l10n/app_localizations.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/cv_empty.dart';
import '../widgets/local_digits.dart' show ld;
import 'ipcam_decoder.dart';
import 'ipcam_pipeline.dart';
import 'lan_grid_logic.dart';

const _kStoreKey = 'lan_grid_v1';
const _kBrands = ['hikvision', 'dahua', 'imou', 'ezviz', 'rtsp'];
const _kChannels = [1, 2, 4, 8, 9, 16];

/// The grid's camera list on this phone only (encrypted storage).
class LanGridStore {
  static const _s = FlutterSecureStorage();
  Future<LanGridConfig?> load() async {
    try {
      return LanGridConfig.fromJson(await _s.read(key: _kStoreKey));
    } catch (_) {
      return null; // a phone whose keystore is broken: just ask again
    }
  }

  Future<bool> save(LanGridConfig c) async {
    try {
      await _s.write(key: _kStoreKey, value: jsonEncode(c.toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }
}

enum TileStatus { off, connecting, live, lost, noDecoder }

/// One tile's camera connection: the right stream, its picture, its meter.
class LanTileFeed extends ChangeNotifier {
  final LanCam cam;
  final String slot;
  final IpDecoder Function(String slot) decoderFor;
  final SessionOpener? opener;
  LanTileFeed(this.cam, this.slot, {required this.decoderFor, this.opener});

  GridQuality quality = GridQuality.off;
  TileStatus status = TileStatus.off;
  ui.Image? image;
  final meter = TileMeter();
  int frames = 0;
  int _fps = 3;
  int _grabW = 320;
  int _bytesBase = 0;
  IpCamPipeline? _pipe;
  int _gen = 0;
  bool _disposed = false;

  /// Every byte this camera sent this phone since the grid opened.
  int get bytesNow => _bytesBase + (_pipe?.bytesIn ?? 0);

  Future<void> set(GridQuality q, {required int fps, required int grabW}) async {
    _fps = fps;
    _grabW = grabW;
    if (q == quality || _disposed) return;
    final gen = ++_gen;
    quality = q;
    final old = _pipe;
    _pipe = null;
    if (old != null) {
      _bytesBase += old.bytesIn;
      await old.stop();
    }
    if (gen != _gen || _disposed) return;
    if (q == GridQuality.off) {
      status = TileStatus.off;
      _notify();
      return;
    }
    final pipe = IpCamPipeline(cam.url(q), decoderFor(slot), opener: opener);
    _pipe = pipe;
    status = TileStatus.connecting;
    _notify();
    unawaited(pipe.run());
    unawaited(_loop(gen, pipe));
  }

  Future<void> _loop(int gen, IpCamPipeline pipe) async {
    while (gen == _gen && !_disposed) {
      final t0 = DateTime.now();
      final f = pipe.decoding ? await pipe.grab(maxW: _grabW, timeoutMs: 2000) : null;
      if (gen != _gen || _disposed) break;
      if (f != null) {
        final img = await _decode(f.jpeg, _grabW);
        if (gen != _gen || _disposed) {
          img?.dispose();
          break;
        }
        if (img != null) {
          final old = image;
          image = img;
          old?.dispose(); // RawImage keeps its own clone until it repaints
          frames++;
          meter.frame(DateTime.now());
          status = TileStatus.live;
        }
      } else if (pipe.state == PipeState.waiting) {
        status = TileStatus.lost;
      } else if (pipe.decodeFails >= 3) {
        status = TileStatus.noDecoder;
      }
      meter.bytes(bytesNow, DateTime.now());
      _notify();
      final every = Duration(milliseconds: _fps <= 0 ? 500 : 1000 ~/ _fps);
      final left = every - DateTime.now().difference(t0);
      await Future<void>.delayed(left > Duration.zero ? left : const Duration(milliseconds: 30));
    }
  }

  static Future<ui.Image?> _decode(Uint8List jpeg, int w) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg, targetWidth: w);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null; // a broken picture is skipped
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() async {
    _gen++;
    final p = _pipe;
    _pipe = null;
    if (p != null) {
      _bytesBase += p.bytesIn;
      await p.stop();
    }
    quality = GridQuality.off;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    image?.dispose();
    image = null;
    super.dispose();
  }
}

class LanGridScreen extends StatefulWidget {
  /// Cameras given directly (tests / the CI measurement); null = the
  /// owner's saved DVR from [store] (or the set-up form).
  final List<LanCam>? cams;
  final int? cols;
  final LanGridStore? store;
  final IpDecoder Function(String slot)? decoderFor;
  final SessionOpener? opener;

  /// Every 10 s: per-tile fps / data / stream + the app's memory (CI).
  final void Function(Map<String, Object?> stats)? onStats;
  const LanGridScreen({super.key, this.cams, this.cols, this.store, this.decoderFor, this.opener, this.onStats});

  @override
  State<LanGridScreen> createState() => LanGridScreenState();
}

class LanGridScreenState extends State<LanGridScreen> with WidgetsBindingObserver {
  static const _gap = 6.0;
  static const _pad = 8.0;
  late final LanGridStore _store = widget.store ?? LanGridStore();
  LanGridConfig? _cfg;
  bool _loading = true;
  bool _editing = false;
  List<LanTileFeed> _feeds = const [];
  final _graces = <OffGrace>[];
  int _cols = 2;
  bool _active = true; // app in front, no camera opened big
  final _scroll = ScrollController();
  double _viewH = 0, _viewW = 0;
  Timer? _tick, _statsTimer;
  DateTime _openedAt = DateTime.now();
  double _mbPerMin = 0;

  // set-up form
  String _brand = 'dahua';
  int _channels = 4;
  final _host = TextEditingController();
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  final _lines = TextEditingController();
  bool _showPass = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_apply);
    _init();
  }

  Future<void> _init() async {
    if (widget.cams != null) {
      _start(widget.cams!);
    } else {
      final c = await _store.load();
      if (!mounted) return;
      _cfg = c;
      if (c != null) {
        _fillForm(c);
        final cams = c.cams(name: _camName);
        if (cams.isNotEmpty) _start(cams);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _camName(int n) => AppLocalizations.of(context).lvgCam(ld(context, n));

  void _fillForm(LanGridConfig c) {
    _brand = _kBrands.contains(c.brand) ? c.brand : 'rtsp';
    _channels = _kChannels.contains(c.channels) ? c.channels : 4;
    _host.text = c.host;
    _user.text = c.user;
    _pass.text = c.pass;
    _lines.text = c.lines.join('\n');
  }

  /// The stream tile [i] plays now (tests / the CI measurement).
  @visibleForTesting
  GridQuality debugQuality(int i) => _feeds[i].quality;

  /// Bytes each camera has sent so far (tests / the CI measurement).
  @visibleForTesting
  List<int> debugBytes() => [for (final f in _feeds) f.bytesNow];

  IpDecoder _dec(String slot) => widget.decoderFor?.call(slot) ?? NativeIpDecoder(id: slot);

  void _start(List<LanCam> cams) {
    _stopAll();
    _feeds = [
      for (var i = 0; i < cams.length; i++)
        LanTileFeed(cams[i], 'grid$i', decoderFor: _dec, opener: widget.opener)
    ];
    _graces
      ..clear()
      ..addAll([for (final _ in cams) OffGrace()]);
    _cols = widget.cols ?? (cams.length <= 4 ? 2 : 3);
    _openedAt = DateTime.now();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _apply());
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _stats());
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  void _stopAll() {
    _tick?.cancel();
    _statsTimer?.cancel();
    for (final f in _feeds) {
      f.dispose();
    }
    _feeds = const [];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final front = state == AppLifecycleState.resumed;
    if (front == _active) return;
    _active = front;
    _apply();
  }

  /// The heart of it: which stream each tile plays right now.
  void _apply() {
    if (!mounted || _feeds.isEmpty || _viewW <= 0) return;
    final tileW = (_viewW - 2 * _pad - (_cols - 1) * _gap) / _cols;
    final tileH = tileW * 9 / 16;
    final off = _scroll.hasClients ? _scroll.offset : 0.0;
    final now = DateTime.now();
    final wants = <GridQuality>[];
    for (var i = 0; i < _feeds.length; i++) {
      final top = _pad + (i ~/ _cols) * (tileH + _gap);
      final vis = visibleFraction(top: top, height: tileH, viewTop: off, viewHeight: _viewH);
      final w = wantQuality(visibleFrac: vis, tileWidth: tileW, appActive: _active);
      // the app left the front / a camera opened big: cut at once (data)
      wants.add(_active ? _graces[i].apply(w, _feeds[i].quality, now) : GridQuality.off);
    }
    final live = wants.where((q) => q != GridQuality.off).length;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    for (var i = 0; i < _feeds.length; i++) {
      unawaited(_feeds[i].set(wants[i], fps: tileFps(wants[i], live), grabW: grabWidth(wants[i], tileW, dpr)));
    }
  }

  void _stats() {
    if (!mounted) return;
    final now = DateTime.now();
    var kb = 0.0;
    final tiles = <Map<String, Object?>>[];
    for (final f in _feeds) {
      final k = f.meter.kbPerMin(now);
      kb += k;
      tiles.add({
        'cam': f.slot,
        'q': f.quality.name,
        'st': f.status.name,
        'fps': double.parse(f.meter.fps(now).toStringAsFixed(1)),
        'kb_min': k.round(),
        'frames': f.frames,
        'bytes': f.bytesNow,
      });
    }
    setState(() => _mbPerMin = kb / 1024);
    int? rss;
    try {
      rss = ProcessInfo.currentRss;
    } catch (_) {}
    widget.onStats?.call({
      't_s': now.difference(_openedAt).inSeconds,
      'cols': _cols,
      'cams': _feeds.length,
      'active': _active,
      'mb_min': double.parse((kb / 1024).toStringAsFixed(2)),
      'rss_mb': rss == null ? null : (rss / 1048576).round(),
      'tiles': tiles,
    });
  }

  Future<void> _openBig(LanTileFeed f) async {
    _active = false;
    _apply();
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LanBigView(
            feed: LanTileFeed(f.cam, 'gridF', decoderFor: _dec, opener: widget.opener))));
    if (!mounted) return;
    _active = true;
    _apply();
  }

  Future<void> _save() async {
    final c = LanGridConfig(
      brand: _brand,
      host: _host.text.trim(),
      user: _user.text.trim(),
      pass: _pass.text,
      channels: _channels,
      lines: _lines.text.split('\n'),
    );
    final cams = c.cams(name: _camName);
    final t = AppLocalizations.of(context);
    if (cams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.lvgNeedAddress)));
      return;
    }
    await _store.save(c);
    if (!mounted) return;
    setState(() {
      _cfg = c;
      _editing = false;
    });
    _start(cams);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAll();
    _scroll.dispose();
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    _lines.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final showForm = !_loading && (_editing || (_feeds.isEmpty && widget.cams == null));
    return Scaffold(
      appBar: AppBar(
        title: Text(t.lvgTitle),
        actions: [
          if (!showForm && _feeds.isNotEmpty) ...[
            IconButton(
              key: const ValueKey('lvg-cols'),
              tooltip: _cols == 2 ? t.lvgLayout3 : t.lvgLayout2,
              icon: Icon(_cols == 2 ? Icons.grid_on_rounded : Icons.grid_view_rounded),
              onPressed: () {
                setState(() => _cols = _cols == 2 ? 3 : 2);
                WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
              },
            ),
            if (widget.cams == null)
              IconButton(
                key: const ValueKey('lvg-edit'),
                tooltip: t.lvgEdit,
                icon: const Icon(Icons.edit_outlined),
                onPressed: () {
                  _stopAll();
                  setState(() => _editing = true);
                },
              ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : showForm
              ? _form(t)
              : _grid(t),
    );
  }

  Widget _grid(AppLocalizations t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Text(t.lvgNote(ld(context, _mbPerMin.toStringAsFixed(1))),
            key: const ValueKey('lvg-note'), style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth != _viewW || c.maxHeight != _viewH) {
            _viewW = c.maxWidth;
            _viewH = c.maxHeight;
            WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
          }
          return GridView.builder(
            controller: _scroll,
            padding: withNavBarInset(context, const EdgeInsets.all(_pad)),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _cols, mainAxisSpacing: _gap, crossAxisSpacing: _gap, childAspectRatio: 16 / 9),
            itemCount: _feeds.length,
            itemBuilder: (_, i) => LanTile(feed: _feeds[i], onTap: () => _openBig(_feeds[i])),
          );
        }),
      ),
    ]);
  }

  Widget _form(AppLocalizations t) {
    final byLines = _brand == 'rtsp';
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 24)),
      children: [
        CvEmptyBlock(
          icon: Icons.grid_view_rounded,
          title: t.lvgSetupTitle,
          benefit: t.lvgSetupBenefit,
          steps: [t.lvgStep1, t.lvgStep2, t.lvgStep3],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('lvg-brand'),
          initialValue: _brand,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.icgBrand),
          items: [
            for (final b in _kBrands) DropdownMenuItem(value: b, child: Text(_brandName(t, b))),
          ],
          onChanged: (v) => setState(() => _brand = v ?? _brand),
        ),
        const SizedBox(height: 12),
        if (byLines)
          TextField(
            key: const ValueKey('lvg-lines'),
            controller: _lines,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: t.lvgLines, helperText: t.lvgLinesHelp, helperMaxLines: 3),
          )
        else ...[
          TextField(
            key: const ValueKey('lvg-host'),
            controller: _host,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: t.lvgHost, helperText: t.lvgHostHelp, helperMaxLines: 3),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('lvg-user'),
            controller: _user,
            decoration: InputDecoration(labelText: t.lvgUser),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('lvg-pass'),
            controller: _pass,
            obscureText: !_showPass,
            decoration: InputDecoration(
              labelText: t.lvgPass,
              suffixIcon: IconButton(
                tooltip: t.icgShowPass,
                icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPass = !_showPass),
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const ValueKey('lvg-channels'),
            initialValue: _channels,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.lvgChannels),
            items: [for (final n in _kChannels) DropdownMenuItem(value: n, child: Text(ld(context, n)))],
            onChanged: (v) => setState(() => _channels = v ?? _channels),
          ),
        ],
        const SizedBox(height: 8),
        Text(t.lvgPrivacy, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('lvg-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _save,
          icon: const Icon(Icons.play_circle_outline_rounded),
          label: Text(t.lvgSave),
        ),
        if (_cfg != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () {
              setState(() => _editing = false);
              final cams = _cfg!.cams(name: _camName);
              if (cams.isNotEmpty) _start(cams);
            },
            child: Text(t.lvgCancelEdit),
          ),
        ],
      ],
    );
  }

  static String _brandName(AppLocalizations t, String b) => switch (b) {
        'hikvision' => 'Hikvision',
        'dahua' => 'Dahua',
        'imou' => 'Imou',
        'ezviz' => 'EZVIZ',
        _ => t.icgBrandRtsp,
      };
}

/// One small camera tile: the live picture (or why there is none), the
/// camera's name and SD / HD.
class LanTile extends StatelessWidget {
  final LanTileFeed feed;
  final VoidCallback onTap;
  const LanTile({super.key, required this.feed, required this.onTap});

  static String statusText(AppLocalizations t, TileStatus s) => switch (s) {
        TileStatus.off => t.lvgPaused,
        TileStatus.connecting => t.lvgConnecting,
        TileStatus.live => t.lvgLive,
        TileStatus.lost => t.lvgLost,
        TileStatus.noDecoder => t.lvgNoDecoder,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        final live = feed.status == TileStatus.live && feed.image != null;
        final q = feed.quality == GridQuality.main ? t.lvgHd : t.lvgSd;
        final state = statusText(t, feed.status);
        return Semantics(
          button: true,
          label: '${feed.cam.name}, $state${live ? ', $q' : ''}',
          excludeSemantics: true,
          onTap: onTap,
          child: Material(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('lvg-tile-${feed.slot}'),
              onTap: onTap,
              child: Stack(fit: StackFit.expand, children: [
                if (feed.image != null)
                  Opacity(
                    opacity: live ? 1 : 0.45,
                    child: RawImage(image: feed.image, fit: BoxFit.cover),
                  ),
                if (!live)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(state,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(live ? '${feed.cam.name} · $q' : feed.cam.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// One camera opened big: the MAIN stream (HD), 10 pictures a second.
class LanBigView extends StatefulWidget {
  final LanTileFeed feed;
  const LanBigView({super.key, required this.feed});

  @override
  State<LanBigView> createState() => _LanBigViewState();
}

class _LanBigViewState extends State<LanBigView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final w = MediaQuery.sizeOf(context).width;
      unawaited(widget.feed.set(GridQuality.main,
          fps: tileFps(GridQuality.main, 1),
          grabW: grabWidth(GridQuality.main, w, MediaQuery.devicePixelRatioOf(context))));
    });
  }

  @override
  void dispose() {
    widget.feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final f = widget.feed;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(f.cam.name)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: f,
          builder: (context, _) => Column(children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: f.image != null
                      ? RawImage(key: const ValueKey('lvg-big'), image: f.image, fit: BoxFit.contain)
                      : Center(
                          child: Text(LanTile.statusText(t, f.status),
                              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(f.cam.singleStream ? t.lvgOneStream : t.lvgBigNote,
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
          ]),
        ),
      ),
    );
  }
}
