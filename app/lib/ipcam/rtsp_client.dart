// cctvbox — a small RTSP client for the GUARD BOX (an old Android phone on
// the same Wi-Fi watches an IP camera, no PC). Pure Dart (dart:io sockets +
// package:crypto) so the whole protocol path is unit-tested on CI against an
// in-process fake camera, and on the emulator E2E against a real mediamtx.
//
//   OPTIONS -> DESCRIBE (Basic / Digest auth) -> SETUP (RTP over the same
//   TCP connection, "interleaved" — no UDP ports, works through any Wi-Fi)
//   -> PLAY -> RTP -> H.264 / H.265 NAL units -> access units (Annex-B)
//   -> the native decoder (ipcam_decoder.dart).
//
// The camera password lives ONLY in the RTSP URL kept in this phone's
// encrypted secure storage; it is sent to the camera (on the LAN) and never
// to Assisto. Keep-alive every <= 25 s; no RTP for 10 s = the stream ended
// (the caller reconnects with backoff).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

// ------------------------------------------------------------------ URL
class RtspUrl {
  final String host;
  final int port;
  final String user;
  final String pass;

  /// path + query, starting with '/'.
  final String path;
  const RtspUrl(this.host, this.port, this.user, this.pass, this.path);

  /// The URL WITHOUT credentials (what goes on the request line).
  String get bare => 'rtsp://$host${port == 554 ? '' : ':$port'}$path';

  /// Parses `rtsp://user:pass@host:port/path?q`. A password may contain a
  /// raw '@' or ':' (people type the sticker code as-is): the LAST '@' before
  /// the path ends the user info. Null when it is not an rtsp URL.
  static RtspUrl? parse(String raw) {
    final s = raw.trim();
    if (!s.toLowerCase().startsWith('rtsp://')) return null;
    final rest = s.substring(7);
    // the user info ends at the last '@' that is followed by a plausible
    // host[:port] (a typed password may hold raw '@', ':' or '/'); an '@'
    // inside the path or query never counts
    var at = -1;
    for (var i = rest.lastIndexOf('@'); i >= 0; i = i == 0 ? -1 : rest.lastIndexOf('@', i - 1)) {
      if (rest.substring(0, i).contains('?')) continue;
      final after = rest.substring(i + 1);
      final sl = after.indexOf('/');
      final hp = sl < 0 ? after : after.substring(0, sl);
      if (RegExp(r'^[A-Za-z0-9.\-]+(:\d{1,5})?$').hasMatch(hp)) {
        at = i;
        break;
      }
    }
    var user = '', pass = '';
    var auth = rest;
    if (at >= 0) {
      final ui = rest.substring(0, at);
      auth = rest.substring(at + 1);
      final colon = ui.indexOf(':');
      user = _dec(colon < 0 ? ui : ui.substring(0, colon));
      pass = colon < 0 ? '' : _dec(ui.substring(colon + 1));
    }
    final slash = auth.indexOf('/');
    final hostPort = slash < 0 ? auth : auth.substring(0, slash);
    final path = slash < 0 ? '/' : auth.substring(slash);
    var host = hostPort;
    var port = 554;
    final pc = hostPort.lastIndexOf(':');
    if (pc > 0 && !hostPort.endsWith(']')) {
      final p = int.tryParse(hostPort.substring(pc + 1));
      if (p == null || p <= 0 || p > 65535) return null;
      port = p;
      host = hostPort.substring(0, pc);
    }
    if (!RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(host)) return null;
    return RtspUrl(host, port, user, pass, path);
  }

  static String _dec(String v) {
    try {
      return Uri.decodeComponent(v);
    } catch (_) {
      return v;
    }
  }

  /// Build a URL with credentials, percent-encoding them.
  static String build(String host, String path, {String user = '', String pass = '', int port = 554}) {
    final ui = user.isEmpty
        ? ''
        : '${Uri.encodeComponent(user)}${pass.isEmpty ? '' : ':${Uri.encodeComponent(pass)}'}@';
    return 'rtsp://$ui$host${port == 554 ? '' : ':$port'}$path';
  }

  /// For logs / screens: never the password.
  String get redacted => 'rtsp://${user.isEmpty ? '' : '$user:***@'}$host${port == 554 ? '' : ':$port'}$path';
}

// ------------------------------------------------------------------ auth
/// RTSP auth answer for a WWW-Authenticate challenge. Digest is preferred
/// (RFC 2617, MD5; most cameras send no qop); Basic only when it is all the
/// camera offers.
class RtspAuth {
  final String scheme; // 'digest' | 'basic'
  final Map<String, String> p;
  int _nc = 0;
  RtspAuth._(this.scheme, this.p);

  static RtspAuth? fromChallenges(List<String> challenges) {
    RtspAuth? basic;
    for (final ch in challenges) {
      final t = ch.trim();
      final lower = t.toLowerCase();
      if (lower.startsWith('digest')) {
        final m = <String, String>{};
        for (final x in RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))').allMatches(t.substring(6))) {
          m[x.group(1)!.toLowerCase()] = x.group(2) ?? x.group(3) ?? '';
        }
        return RtspAuth._('digest', m);
      }
      if (lower.startsWith('basic')) basic = RtspAuth._('basic', const {});
    }
    return basic;
  }

  String header(String method, String uri, String user, String pass, {String? cnonce}) {
    if (scheme == 'basic') return 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
    String md5(String s) => c.md5.convert(utf8.encode(s)).toString();
    final realm = p['realm'] ?? '', nonce = p['nonce'] ?? '';
    final ha1 = md5('$user:$realm:$pass');
    final ha2 = md5('$method:$uri');
    final qop = (p['qop'] ?? '').split(',').map((e) => e.trim()).contains('auth') ? 'auth' : '';
    String resp;
    var extra = '';
    if (qop.isEmpty) {
      resp = md5('$ha1:$nonce:$ha2');
    } else {
      _nc++;
      final nc = _nc.toRadixString(16).padLeft(8, '0');
      final cn = cnonce ?? List<String>.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
      resp = md5('$ha1:$nonce:$nc:$cn:$qop:$ha2');
      extra = ', qop=$qop, nc=$nc, cnonce="$cn"';
    }
    return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", '
        'response="$resp"$extra${p.containsKey('opaque') ? ', opaque="${p['opaque']}"' : ''}';
  }
}

// ------------------------------------------------------------------ SDP
class SdpVideo {
  final String codec; // 'H264' | 'H265' | anything else (unsupported)
  final int payloadType;
  final String control;
  final List<Uint8List> paramSets; // Annex-B-less NAL units (VPS/SPS/PPS)
  const SdpVideo(this.codec, this.payloadType, this.control, this.paramSets);
  bool get supported => codec == 'H264' || codec == 'H265';
  String get mime => codec == 'H265' ? 'video/hevc' : 'video/avc';
}

/// The first video track of an SDP, or null (no video).
SdpVideo? parseSdpVideo(String sdp) {
  var inVideo = false;
  int? pt;
  String codec = '';
  String control = '';
  final sets = <Uint8List>[];
  String? fmtp;
  for (final raw in const LineSplitter().convert(sdp)) {
    final line = raw.trim();
    if (line.startsWith('m=')) {
      if (inVideo) break; // the first video section is done
      inVideo = line.startsWith('m=video');
      if (inVideo) {
        final parts = line.split(RegExp(r'\s+'));
        pt = parts.length > 3 ? int.tryParse(parts[3]) : null;
      }
      continue;
    }
    if (!inVideo) continue;
    if (line.startsWith('a=rtpmap:')) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)').firstMatch(line);
      if (m != null && (pt == null || int.parse(m.group(1)!) == pt)) {
        pt = int.parse(m.group(1)!);
        codec = m.group(2)!.toUpperCase();
        if (codec == 'HEVC') codec = 'H265';
      }
    } else if (line.startsWith('a=fmtp:')) {
      fmtp = line;
    } else if (line.startsWith('a=control:')) {
      control = line.substring(10).trim();
    }
  }
  if (!inVideo && pt == null) return null;
  if (pt == null) return null;
  if (codec.isEmpty) codec = pt == 26 ? 'JPEG' : 'UNKNOWN';
  if (fmtp != null) {
    Iterable<String> b64(String key) {
      final m = RegExp('$key=([^;\\s]+)').firstMatch(fmtp!);
      return m == null ? const [] : m.group(1)!.split(',');
    }

    final keys = codec == 'H265' ? ['sprop-vps', 'sprop-sps', 'sprop-pps'] : ['sprop-parameter-sets'];
    for (final k in keys) {
      for (final s in b64(k)) {
        try {
          final b = base64Decode(_padB64(s));
          if (b.isNotEmpty) sets.add(Uint8List.fromList(b));
        } catch (_) {}
      }
    }
  }
  return SdpVideo(codec, pt, control, sets);
}

String _padB64(String s) {
  final t = s.trim();
  final r = t.length % 4;
  return r == 0 ? t : t + '=' * (4 - r);
}

/// Absolute control URL for SETUP. [base] = Content-Base / the DESCRIBE URL.
String resolveControl(String base, String control) {
  if (control.isEmpty || control == '*') return base;
  if (control.toLowerCase().startsWith('rtsp://')) return control;
  return base.endsWith('/') ? '$base$control' : '$base/$control';
}

// ------------------------------------------------------------------ NALs
int h264Type(Uint8List nal) => nal.isEmpty ? -1 : nal[0] & 0x1f;
int h265Type(Uint8List nal) => nal.isEmpty ? -1 : (nal[0] >> 1) & 0x3f;

abstract class Depacketizer {
  List<Uint8List> push(Uint8List p);
  void reset();
}

/// RTP payload -> complete NAL units (RFC 6184 single / STAP-A / FU-A).
class H264Depacketizer implements Depacketizer {
  BytesBuilder? _fu;
  @override
  void reset() => _fu = null;

  @override
  List<Uint8List> push(Uint8List p) {
    if (p.isEmpty) return const [];
    final t = p[0] & 0x1f;
    if (t >= 1 && t <= 23) return [p];
    final out = <Uint8List>[];
    if (t == 24) {
      var i = 1;
      while (i + 2 <= p.length) {
        final n = (p[i] << 8) | p[i + 1];
        i += 2;
        if (n == 0 || i + n > p.length) break;
        out.add(Uint8List.sublistView(p, i, i + n));
        i += n;
      }
    } else if (t == 28 && p.length > 2) {
      final s = p[1] & 0x80 != 0, e = p[1] & 0x40 != 0;
      if (s) {
        _fu = BytesBuilder(copy: false)
          ..addByte((p[0] & 0xe0) | (p[1] & 0x1f))
          ..add(Uint8List.sublistView(p, 2));
      } else {
        _fu?.add(Uint8List.sublistView(p, 2));
      }
      if (e && _fu != null) {
        out.add(_fu!.takeBytes());
        _fu = null;
      }
    }
    return out;
  }
}

/// RTP payload -> complete NAL units (RFC 7798 single / AP / FU; no DONL).
class H265Depacketizer implements Depacketizer {
  BytesBuilder? _fu;
  @override
  void reset() => _fu = null;

  @override
  List<Uint8List> push(Uint8List p) {
    if (p.length < 3) return const [];
    final t = (p[0] >> 1) & 0x3f;
    if (t < 48) return [p];
    final out = <Uint8List>[];
    if (t == 48) {
      var i = 2;
      while (i + 2 <= p.length) {
        final n = (p[i] << 8) | p[i + 1];
        i += 2;
        if (n == 0 || i + n > p.length) break;
        out.add(Uint8List.sublistView(p, i, i + n));
        i += n;
      }
    } else if (t == 49) {
      final fu = p[2];
      final s = fu & 0x80 != 0, e = fu & 0x40 != 0;
      if (s) {
        _fu = BytesBuilder(copy: false)
          ..addByte((p[0] & 0x81) | ((fu & 0x3f) << 1))
          ..addByte(p[1])
          ..add(Uint8List.sublistView(p, 3));
      } else {
        _fu?.add(Uint8List.sublistView(p, 3));
      }
      if (e && _fu != null) {
        out.add(_fu!.takeBytes());
        _fu = null;
      }
    }
    return out;
  }
}

/// One decodable picture: Annex-B bytes (00 00 00 01 before every NAL).
class AccessUnit {
  final Uint8List data;
  final bool key;
  final int rtpTs;
  const AccessUnit(this.data, this.key, this.rtpTs);
}

/// NAL units -> access units. A key picture always carries the parameter
/// sets (from the SDP or seen in-band), so the decoder can (re)start on it.
class AuAssembler {
  final bool hevc;
  final _nals = <Uint8List>[];
  int? _ts;
  bool _broken = false;
  final Map<int, Uint8List> params = {}; // NAL type -> latest VPS/SPS/PPS
  AuAssembler({required this.hevc, List<Uint8List> sdpParams = const []}) {
    for (final p in sdpParams) {
      _noteParam(p);
    }
  }

  int _type(Uint8List n) => hevc ? h265Type(n) : h264Type(n);
  bool _isParam(int t) => hevc ? (t >= 32 && t <= 34) : (t == 7 || t == 8);
  bool _isKey(int t) => hevc ? (t >= 16 && t <= 21) : t == 5;
  bool _isSlice(int t) => hevc ? t <= 21 : (t >= 1 && t <= 5);

  void _noteParam(Uint8List n) {
    final t = _type(n);
    if (_isParam(t)) params[t] = Uint8List.fromList(n);
  }

  bool get hasParams => hevc ? params.length >= 3 : (params.containsKey(7) && params.containsKey(8));

  /// Parameter sets in decoder order (VPS, SPS, PPS), Annex-B framed.
  List<Uint8List> get paramList {
    final ks = params.keys.toList()..sort();
    return [for (final k in ks) params[k]!];
  }

  /// A lost RTP packet: the current picture is dropped.
  void lost() {
    _broken = true;
  }

  /// Feed the NALs of one RTP packet; returns finished access units.
  List<AccessUnit> push(List<Uint8List> nals, int ts, bool marker) {
    final out = <AccessUnit>[];
    if (_ts != null && ts != _ts && _nals.isNotEmpty) {
      final a = _flush();
      if (a != null) out.add(a);
    }
    _ts = ts;
    for (final n in nals) {
      if (n.isEmpty) continue;
      _noteParam(n);
      _nals.add(n);
    }
    if (marker) {
      final a = _flush();
      if (a != null) out.add(a);
    }
    return out;
  }

  AccessUnit? _flush() {
    final nals = List<Uint8List>.of(_nals);
    _nals.clear();
    final broken = _broken;
    _broken = false;
    if (broken || nals.isEmpty) return null;
    var key = false, slice = false;
    final have = <int>{};
    for (final n in nals) {
      final t = _type(n);
      have.add(t);
      if (_isKey(t)) key = true;
      if (_isSlice(t)) slice = true;
    }
    if (!slice) return null; // params / SEI only: kept for the next picture
    final b = BytesBuilder(copy: false);
    const sc = [0, 0, 0, 1];
    if (key) {
      for (final e in params.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
        if (!have.contains(e.key)) {
          b.add(sc);
          b.add(e.value);
        }
      }
    }
    for (final n in nals) {
      b.add(sc);
      b.add(n);
    }
    return AccessUnit(b.takeBytes(), key, _ts ?? 0);
  }
}

// ------------------------------------------------------------------ RTP
class RtpPacket {
  final int pt, seq, ts;
  final bool marker;
  final Uint8List payload;
  const RtpPacket(this.pt, this.seq, this.ts, this.marker, this.payload);

  static RtpPacket? parse(Uint8List b) {
    if (b.length < 12 || (b[0] >> 6) != 2) return null;
    final cc = b[0] & 0x0f;
    final ext = b[0] & 0x10 != 0;
    final pad = b[0] & 0x20 != 0;
    var off = 12 + cc * 4;
    if (off > b.length) return null;
    if (ext) {
      if (off + 4 > b.length) return null;
      final words = (b[off + 2] << 8) | b[off + 3];
      off += 4 + words * 4;
      if (off > b.length) return null;
    }
    var end = b.length;
    if (pad && end > off) end -= b[end - 1];
    if (end < off) return null;
    return RtpPacket(
      b[1] & 0x7f,
      (b[2] << 8) | b[3],
      (b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7],
      b[1] & 0x80 != 0,
      Uint8List.sublistView(b, off, end),
    );
  }
}

// ------------------------------------------------------------------ session
/// Why a stream could not open / stopped. The screen maps these to plain
/// words ("password wrong", "can't reach the camera", ...).
enum RtspFail { unreachable, auth, notFound, codec, timeout, protocol, closed }

class RtspException implements Exception {
  final RtspFail kind;
  final String detail;
  const RtspException(this.kind, [this.detail = '']);
  @override
  String toString() => 'RtspException(${kind.name}${detail.isEmpty ? '' : ': $detail'})';
}

class RtspResponse {
  final int status;
  final Map<String, List<String>> headers; // lower-case names
  final String body;
  const RtspResponse(this.status, this.headers, this.body);
  String? h(String name) {
    final v = headers[name.toLowerCase()];
    return v == null || v.isEmpty ? null : v.first;
  }
}

/// One RTSP playback. [open] returns once PLAY was accepted; access units
/// then arrive on [units] until the camera stops (the stream closes with an
/// [RtspException] error, or done after [close]).
class RtspSession {
  final RtspUrl url;
  final Duration ioTimeout;
  final Duration rtpSilence;
  Socket? _sock;
  final _buf = _ByteQueue();
  int _cseq = 0;
  final _pending = <int, Completer<RtspResponse>>{};
  RtspAuth? _auth;
  String? _session;
  Timer? _keep, _watch;
  DateTime _lastRtp = DateTime.now();
  bool _closed = false;
  bool _getParam = false;
  late SdpVideo video;
  late AuAssembler _asm;
  late Depacketizer _depack;
  int? _lastSeq;
  final _units = StreamController<AccessUnit>(sync: true);

  /// Bytes received from the camera (for the screen's "KB/s" line).
  int bytesIn = 0;
  int packets = 0;
  int lostPackets = 0;

  RtspSession(this.url,
      {this.ioTimeout = const Duration(seconds: 8), this.rtpSilence = const Duration(seconds: 10)});

  Stream<AccessUnit> get units => _units.stream;
  AuAssembler get assembler => _asm;

  Future<void> open() async {
    try {
      _sock = await Socket.connect(url.host, url.port, timeout: ioTimeout);
    } on SocketException catch (e) {
      throw RtspException(RtspFail.unreachable, e.osError?.message ?? '');
    } on TimeoutException {
      throw const RtspException(RtspFail.unreachable, 'timeout');
    }
    try {
      _sock!.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sock!.listen(_onData, onError: (Object e) => _fail(RtspException(RtspFail.closed, '$e')),
        onDone: () => _fail(const RtspException(RtspFail.closed, 'camera closed the connection')),
        cancelOnError: true);
    try {
      final opt = await _request('OPTIONS', url.bare);
      _getParam = (opt.h('public') ?? '').toUpperCase().contains('GET_PARAMETER');
      final d = await _request('DESCRIBE', url.bare, {'Accept': 'application/sdp'});
      if (d.status != 200) throw _statusFail(d.status);
      final v = parseSdpVideo(d.body);
      if (v == null) throw const RtspException(RtspFail.codec, 'no video track');
      if (!v.supported) throw RtspException(RtspFail.codec, v.codec);
      video = v;
      final hevc = v.codec == 'H265';
      _asm = AuAssembler(hevc: hevc, sdpParams: v.paramSets);
      _depack = hevc ? H265Depacketizer() : H264Depacketizer();
      final base = d.h('content-base') ?? d.h('content-location') ?? url.bare;
      final ctl = resolveControl(base, v.control);
      final s = await _request('SETUP', ctl, {'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'});
      if (s.status != 200) throw _statusFail(s.status);
      final sess = s.h('session') ?? '';
      final parts = sess.split(';');
      _session = parts.first.trim();
      var timeout = 60;
      for (final p in parts.skip(1)) {
        final kv = p.trim().split('=');
        if (kv.length == 2 && kv[0].toLowerCase() == 'timeout') timeout = int.tryParse(kv[1]) ?? 60;
      }
      final p = await _request('PLAY', base, {'Range': 'npt=0.000-'});
      if (p.status != 200) throw _statusFail(p.status);
      final every = Duration(seconds: max(5, min(25, timeout ~/ 2)));
      _keep = Timer.periodic(every, (_) => _keepAlive());
      _lastRtp = DateTime.now();
      _watch = Timer.periodic(const Duration(seconds: 2), (_) {
        if (DateTime.now().difference(_lastRtp) > rtpSilence) {
          _fail(const RtspException(RtspFail.timeout, 'no video from the camera'));
        }
      });
    } catch (e) {
      await close();
      if (e is RtspException) rethrow;
      throw RtspException(RtspFail.protocol, '$e');
    }
  }

  RtspException _statusFail(int st) => switch (st) {
        401 || 403 => const RtspException(RtspFail.auth),
        404 => const RtspException(RtspFail.notFound),
        _ => RtspException(RtspFail.protocol, 'status $st'),
      };

  Future<RtspResponse> _request(String method, String uri, [Map<String, String> extra = const {}]) async {
    var r = await _send(method, uri, extra);
    if (r.status == 401 && url.user.isNotEmpty) {
      final a = RtspAuth.fromChallenges(r.headers['www-authenticate'] ?? const []);
      if (a == null) throw const RtspException(RtspFail.auth);
      _auth = a;
      r = await _send(method, uri, extra);
      if (r.status == 401) throw const RtspException(RtspFail.auth);
    } else if (r.status == 401) {
      throw const RtspException(RtspFail.auth, 'no user');
    }
    return r;
  }

  Future<RtspResponse> _send(String method, String uri, Map<String, String> extra) {
    final s = _sock;
    if (s == null || _closed) return Future.error(const RtspException(RtspFail.closed));
    final n = ++_cseq;
    final b = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: $n\r\nUser-Agent: Assisto-GuardBox/1\r\n');
    final a = _auth;
    if (a != null) b.write('Authorization: ${a.header(method, uri, url.user, url.pass)}\r\n');
    if (_session != null) b.write('Session: $_session\r\n');
    extra.forEach((k, v) => b.write('$k: $v\r\n'));
    b.write('\r\n');
    final done = Completer<RtspResponse>();
    _pending[n] = done;
    try {
      s.add(utf8.encode(b.toString()));
    } catch (e) {
      _pending.remove(n);
      return Future.error(RtspException(RtspFail.closed, '$e'));
    }
    return done.future.timeout(ioTimeout, onTimeout: () {
      _pending.remove(n);
      throw const RtspException(RtspFail.timeout, 'the camera did not answer');
    });
  }

  void _keepAlive() {
    if (_closed) return;
    _send(_getParam ? 'GET_PARAMETER' : 'OPTIONS', url.bare, const {}).then((_) {}, onError: (_) {});
  }

  void _onData(Uint8List data) {
    bytesIn += data.length;
    _buf.add(data);
    while (!_closed) {
      if (_buf.length == 0) return;
      if (_buf.byteAt(0) == 0x24) {
        if (_buf.length < 4) return;
        final ch = _buf.byteAt(1);
        final len = (_buf.byteAt(2) << 8) | _buf.byteAt(3);
        if (_buf.length < 4 + len) return;
        _buf.skip(4);
        final payload = _buf.take(len);
        if (ch == 0) _onRtp(payload);
        continue;
      }
      if (_buf.startsWithAscii('RTSP/')) {
        final end = _buf.indexOfCrlfCrlf();
        if (end < 0) {
          if (_buf.length > 64 * 1024) _fail(const RtspException(RtspFail.protocol, 'header too big'));
          return;
        }
        final head = latin1.decode(_buf.peek(end));
        final lines = head.split('\r\n');
        final st = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
        final hs = <String, List<String>>{};
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i <= 0) continue;
          hs.putIfAbsent(l.substring(0, i).trim().toLowerCase(), () => []).add(l.substring(i + 1).trim());
        }
        final clen = int.tryParse(hs['content-length']?.first ?? '0') ?? 0;
        if (_buf.length < end + 4 + clen) return;
        _buf.skip(end + 4);
        final body = clen > 0 ? utf8.decode(_buf.take(clen), allowMalformed: true) : '';
        final seq = int.tryParse(hs['cseq']?.first ?? '');
        final c = seq == null ? null : _pending.remove(seq);
        if (c != null && !c.isCompleted) c.complete(RtspResponse(st, hs, body));
        continue;
      }
      // garbage (a camera sending RTP bytes we lost sync with): resync on '$' / 'R'
      _buf.skip(1);
    }
  }

  void _onRtp(Uint8List b) {
    final p = RtpPacket.parse(b);
    if (p == null || p.pt != video.payloadType) return;
    _lastRtp = DateTime.now();
    packets++;
    final last = _lastSeq;
    if (last != null && ((p.seq - last) & 0xffff) != 1) {
      lostPackets++;
      _depack.reset();
      _asm.lost();
    }
    _lastSeq = p.seq;
    final nals = _depack.push(p.payload);
    for (final au in _asm.push(nals, p.ts, p.marker)) {
      if (!_units.isClosed) _units.add(au);
    }
  }

  void _fail(RtspException e) {
    if (_closed) return;
    if (!_units.isClosed) _units.addError(e);
    close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keep?.cancel();
    _watch?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const RtspException(RtspFail.closed));
    }
    _pending.clear();
    final s = _sock;
    _sock = null;
    if (s != null) {
      try {
        if (_session != null) {
          s.add(utf8.encode('TEARDOWN ${url.bare} RTSP/1.0\r\nCSeq: ${++_cseq}\r\nSession: $_session\r\n\r\n'));
        }
      } catch (_) {}
      try {
        await s.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
      s.destroy();
    }
    // not awaited: with no listener yet, close() would never complete
    if (!_units.isClosed) unawaited(_units.close());
  }
}

/// A simple growable byte queue (append at the end, consume at the front).
class _ByteQueue {
  Uint8List _b = Uint8List(64 * 1024);
  int _start = 0, _end = 0;
  int get length => _end - _start;

  void add(Uint8List d) {
    if (_end + d.length > _b.length) {
      final live = length;
      if (live + d.length > _b.length ~/ 2) {
        final nb = Uint8List(max(_b.length * 2, live + d.length + 1024));
        nb.setRange(0, live, _b, _start);
        _b = nb;
      } else {
        _b.setRange(0, live, _b, _start);
      }
      _start = 0;
      _end = live;
    }
    _b.setRange(_end, _end + d.length, d);
    _end += d.length;
  }

  int byteAt(int i) => _b[_start + i];
  void skip(int n) => _start += n;
  Uint8List take(int n) {
    final out = Uint8List.fromList(Uint8List.sublistView(_b, _start, _start + n));
    _start += n;
    return out;
  }

  Uint8List peek(int n) => Uint8List.sublistView(_b, _start, _start + n);

  bool startsWithAscii(String s) {
    if (length < s.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (_b[_start + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  int indexOfCrlfCrlf() {
    for (var i = _start; i + 3 < _end; i++) {
      if (_b[i] == 13 && _b[i + 1] == 10 && _b[i + 2] == 13 && _b[i + 3] == 10) return i - _start;
    }
    return -1;
  }
}
