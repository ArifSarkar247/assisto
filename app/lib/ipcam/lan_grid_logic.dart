// cctv-accuracy — PURE rules of the Wi-Fi live grid (4 / 9 cameras of a
// DVR / NVR or IP cameras on the same Wi-Fi, watched directly from this
// phone; no Assisto server, no relay, the password never leaves the phone).
// No Flutter widgets: unit-tested in test/lan_grid_logic_test.dart and
// measured on a 2 GB emulator (.github/workflows/cctv-grid.yml).
//
// The rule that keeps a 2 GB phone and its data pack alive:
//   * a SMALL tile plays the camera's SUB stream (a small picture),
//   * only ONE camera opened big plays the MAIN stream,
//   * a tile scrolled off the screen (or the app in the background) is
//     DISCONNECTED after a short grace — zero data, zero decoding.
import 'dart:convert';

import 'ipcam_presets.dart';
import 'rtsp_client.dart' show RtspUrl;

enum GridQuality { off, sub, main }

/// One camera of the grid: its small (sub) and big (main) stream URLs.
/// Credentials are inside the URLs and stay on this phone.
class LanCam {
  final String name;
  final String sub;
  final String main;
  const LanCam(this.name, this.sub, this.main);

  /// The camera has no separate small stream (one URL typed by hand).
  bool get singleStream => sub == main;

  String url(GridQuality q) => q == GridQuality.main ? main : sub;
}

/// What the owner typed once. [brand] from [kIpCamBrands]; for 'rtsp' /
/// 'onvif' the cameras are the [lines] ("url" or "main-url | sub-url").
class LanGridConfig {
  final String brand;
  final String host;
  final String user;
  final String pass;
  final int channels;
  final List<String> lines;
  const LanGridConfig({
    required this.brand,
    this.host = '',
    this.user = '',
    this.pass = '',
    this.channels = 4,
    this.lines = const [],
  });

  static const maxCams = 16;

  bool get byLines => brandPaths(brand).isEmpty;

  /// The cameras, in channel order. Empty = nothing usable typed yet.
  List<LanCam> cams({String Function(int n)? name}) {
    String nm(int n) => name?.call(n) ?? '$n';
    if (byLines) {
      final out = <LanCam>[];
      for (final raw in lines) {
        final l = raw.trim();
        if (l.isEmpty) continue;
        final parts = l.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        if (parts.isEmpty || RtspUrl.parse(parts.first) == null) continue;
        final main = parts.first;
        final sub = parts.length > 1 && RtspUrl.parse(parts[1]) != null ? parts[1] : main;
        out.add(LanCam(nm(out.length + 1), sub, main));
        if (out.length >= maxCams) break;
      }
      return out;
    }
    if (host.trim().isEmpty) return const [];
    final n = channels.clamp(1, maxCams);
    return [
      for (var ch = 1; ch <= n; ch++)
        () {
          final urls = brandUrls(brand, host, user, pass, channel: ch);
          return LanCam(nm(ch), urls.first, urls.last); // presets: sub first, main last
        }()
    ];
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'brand': brand,
        'host': host,
        'user': user,
        'pass': pass,
        'channels': channels,
        'lines': lines,
      };

  static LanGridConfig? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map || d['v'] != 1) return null;
      return LanGridConfig(
        brand: (d['brand'] ?? 'rtsp').toString(),
        host: (d['host'] ?? '').toString(),
        user: (d['user'] ?? '').toString(),
        pass: (d['pass'] ?? '').toString(),
        channels: (d['channels'] as num?)?.toInt() ?? 4,
        lines: [for (final l in (d['lines'] as List? ?? const [])) l.toString()],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Share (0..1) of a tile [top, top+height) inside the visible window
/// [viewTop, viewTop+viewHeight).
double visibleFraction(
    {required double top, required double height, required double viewTop, required double viewHeight}) {
  if (height <= 0) return 0;
  final a = top > viewTop ? top : viewTop;
  final b = (top + height) < (viewTop + viewHeight) ? top + height : viewTop + viewHeight;
  final v = (b - a) / height;
  return v <= 0 ? 0 : (v >= 1 ? 1 : v);
}

/// A tile at least this wide (logical px) is "big" — a tablet with one
/// column — and may use the main stream without being opened.
const double kMainTileMinWidth = 600;

/// The stream a tile should play now.
GridQuality wantQuality({
  required double visibleFrac,
  required double tileWidth,
  bool focused = false,
  bool appActive = true,
}) {
  if (!appActive) return GridQuality.off;
  if (focused) return GridQuality.main;
  if (visibleFrac < 0.1) return GridQuality.off;
  return tileWidth >= kMainTileMinWidth ? GridQuality.main : GridQuality.sub;
}

/// A tile that left the screen is cut only after [grace] (a quick scroll
/// past it must not reconnect the camera 3 times); one that comes back is
/// started at once.
class OffGrace {
  final Duration grace;
  DateTime? _offSince;
  OffGrace({this.grace = const Duration(seconds: 2)});

  GridQuality apply(GridQuality want, GridQuality current, DateTime now) {
    if (want != GridQuality.off) {
      _offSince = null;
      return want;
    }
    if (current == GridQuality.off) return GridQuality.off;
    _offSince ??= now;
    return now.difference(_offSince!) >= grace ? GridQuality.off : current;
  }
}

/// Pictures a second per tile: one big camera 10; a 2x2 grid 6 each; a 3x3
/// grid 3 each (about 27 small pictures a second in all = what a 2 GB phone
/// decodes and shows without dropping frames).
int tileFps(GridQuality q, int liveTiles) {
  switch (q) {
    case GridQuality.off:
      return 0;
    case GridQuality.main:
      return 10;
    case GridQuality.sub:
      return liveTiles <= 4 ? 6 : 3;
  }
}

/// The picture width asked from the decoder: the tile's real pixels (never
/// more than the stream gives), even, at most 640 for a small tile and 1280
/// for a big one.
int grabWidth(GridQuality q, double tileWidth, double devicePixelRatio) {
  final cap = q == GridQuality.main ? 1280 : 640;
  var w = (tileWidth * devicePixelRatio).round();
  if (w > cap) w = cap;
  if (w < 160) w = 160;
  return w & ~1;
}

/// Frame rate + data of one tile over a sliding window (for the on-screen
/// "data per minute" and the CI measurement).
class TileMeter {
  final Duration window;
  final _frames = <DateTime>[];
  final _bytes = <(DateTime, int)>[];
  TileMeter({this.window = const Duration(seconds: 10)});

  void frame(DateTime now) {
    _frames.add(now);
    _trim(now);
  }

  /// [total] = all bytes the camera sent so far (monotonic).
  void bytes(int total, DateTime now) {
    _bytes.add((now, total));
    _trim(now);
  }

  void _trim(DateTime now) {
    _frames.removeWhere((t) => now.difference(t) > window);
    while (_bytes.length > 2 && now.difference(_bytes[1].$1) > window) {
      _bytes.removeAt(0);
    }
  }

  double fps(DateTime now) {
    _trim(now);
    return _frames.length / (window.inMilliseconds / 1000);
  }

  /// Kilobytes a minute over the window (0 with fewer than two samples).
  double kbPerMin(DateTime now) {
    _trim(now);
    if (_bytes.length < 2) return 0;
    final a = _bytes.first, b = _bytes.last;
    final ms = b.$1.difference(a.$1).inMilliseconds;
    if (ms <= 0) return 0;
    return (b.$2 - a.$2) / 1024 * 60000 / ms;
  }
}
