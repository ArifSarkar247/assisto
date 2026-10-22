import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../theme.dart';
import 'call_log.dart';

/// x1-calls A3: the other person's PROFILE PHOTO on the call screen, the
/// full-screen incoming call, the call log and the call notifications.
///
/// Photos are signed, expiring links (/api/v1/m/<file>?e=&s=) whose QUERY
/// changes every hour while the PATH changes only when the person uploads a
/// new photo — so the cache key is the path (+ the server's photo version
/// when given). Bytes are kept in memory and on disk (cache dir), so a ring
/// shows the face instantly and works offline; a new photo = a new key =
/// refreshed everywhere. Every step is guarded: a failure shows the initial.
class CallPhotoCache {
  CallPhotoCache._();
  static final CallPhotoCache instance = CallPhotoCache._();

  final Map<String, Uint8List> _mem = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// Test / gallery hook: no network in tests.
  @visibleForTesting
  static Future<Uint8List?> Function(Uri url)? debugFetch;

  /// Absolute URL for a server path ('/api/v1/m/…' -> api host).
  static String resolve(String url) {
    final u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('/')) return '${AppConfig.apiBase}$u';
    return '';
  }

  static String keyFor(String url, {String version = ''}) {
    final abs = resolve(url);
    if (abs.isEmpty) return '';
    final uri = Uri.tryParse(abs);
    final base = uri == null ? abs : '${uri.host}${uri.path}';
    return version.isEmpty ? base : '$base#$version';
  }

  Uint8List? peek(String url, {String version = ''}) =>
      _mem[keyFor(url, version: version)];

  @visibleForTesting
  void seed(String url, Uint8List bytes, {String version = ''}) =>
      _mem[keyFor(url, version: version)] = bytes;

  @visibleForTesting
  void clear() {
    _mem.clear();
    _inflight.clear();
  }

  Future<Uint8List?> load(String url,
      {String version = '', Duration timeout = const Duration(seconds: 4)}) {
    final key = keyFor(url, version: version);
    if (key.isEmpty) return Future.value(null);
    final hit = _mem[key];
    if (hit != null) return Future.value(hit);
    return _inflight[key] ??= _load(resolve(url), key, timeout)
        .whenComplete(() => _inflight.remove(key));
  }

  Future<Uint8List?> _load(String abs, String key, Duration timeout) async {
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
      final d = Directory('${dir.path}/call_avatars');
      if (!d.existsSync()) d.createSync(recursive: true);
      file = File('${d.path}/${name.length > 120 ? name.substring(name.length - 120) : name}');
      if (file.existsSync()) {
        final b = await file.readAsBytes();
        if (b.isNotEmpty) return _mem[key] = b;
      }
    } catch (e) {
      file = null; // no disk cache (tests, odd storage) -> memory only
    }
    try {
      final uri = Uri.parse(abs);
      final fetch = debugFetch;
      Uint8List? bytes;
      if (fetch != null) {
        bytes = await fetch(uri);
      } else {
        final r = await http
            .get(uri, headers: AppConfig.authHeadersFor(abs))
            .timeout(timeout);
        if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) bytes = r.bodyBytes;
      }
      if (bytes == null || bytes.isEmpty) return null;
      _mem[key] = bytes;
      try {
        await file?.writeAsBytes(bytes, flush: false);
      } catch (_) {}
      return bytes;
    } catch (e) {
      callLog('call_avatar#1', e);
      return null;
    }
  }
}

/// Round avatar: the photo when we have one, else a brand initial.
class CallAvatar extends StatefulWidget {
  const CallAvatar({
    super.key,
    required this.name,
    this.photoUrl = '',
    this.version = '',
    this.radius = 56,
    this.onDark = true,
  });

  final String name;
  final String photoUrl;
  final String version;
  final double radius;

  /// true on the dark call screens (translucent white disc behind the
  /// initial); false on light lists (brand gradient).
  final bool onDark;

  @override
  State<CallAvatar> createState() => _CallAvatarState();
}

class _CallAvatarState extends State<CallAvatar> {
  Uint8List? _bytes;
  String _key = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(CallAvatar old) {
    super.didUpdateWidget(old);
    if (old.photoUrl != widget.photoUrl || old.version != widget.version) {
      _fetch();
    }
  }

  void _fetch() {
    final key = CallPhotoCache.keyFor(widget.photoUrl, version: widget.version);
    _key = key;
    _bytes = CallPhotoCache.instance
        .peek(widget.photoUrl, version: widget.version);
    if (key.isEmpty || _bytes != null) return;
    unawaited(CallPhotoCache.instance
        .load(widget.photoUrl, version: widget.version)
        .then((b) {
      if (mounted && b != null && _key == key) setState(() => _bytes = b);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.radius;
    final b = _bytes;
    if (b != null) {
      return CircleAvatar(
        key: const Key('call-avatar-photo'),
        radius: r,
        backgroundColor: Colors.white.withValues(alpha: 0.14),
        backgroundImage: MemoryImage(b),
        onBackgroundImageError: (_, __) {},
      );
    }
    final n = widget.name.trim();
    final initial = n.isEmpty ? '?' : n.characters.first.toUpperCase();
    return Container(
      key: const Key('call-avatar-initial'),
      width: r * 2,
      height: r * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.onDark ? Colors.white.withValues(alpha: 0.14) : null,
        gradient: widget.onDark ? null : Brand.gradient,
      ),
      child: Text(initial,
          style: TextStyle(
              fontSize: r * 0.8,
              color: Colors.white,
              fontWeight: FontWeight.w700)),
    );
  }
}
