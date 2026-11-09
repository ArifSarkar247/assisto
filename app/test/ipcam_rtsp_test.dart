// cctvbox: the Guard Box RTSP path — URL parsing (raw '@' in passwords),
// Digest auth, SDP, H.264 / H.265 depacketizing, access units, and a full
// RTSP session (OPTIONS/DESCRIBE/SETUP/PLAY over TCP-interleaved RTP) against
// an in-process fake camera that demands Digest auth. Plus the pipeline's
// feeding / reconnect rules with a fake decoder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ipcam/ipcam_decoder.dart';
import 'package:assisto/ipcam/ipcam_pipeline.dart';
import 'package:assisto/ipcam/rtsp_client.dart';

final _sps = Uint8List.fromList([0x67, 0x42, 0x00, 0x1e, 0x95, 0xa8, 0x28, 0x0f, 0x64]);
final _pps = Uint8List.fromList([0x68, 0xce, 0x3c, 0x80]);

Uint8List _rtp(int seq, int ts, bool marker, List<int> payload, {int pt = 96}) {
  final b = BytesBuilder()
    ..addByte(0x80)
    ..addByte((marker ? 0x80 : 0) | pt)
    ..add([seq >> 8 & 0xff, seq & 0xff])
    ..add([ts >> 24 & 0xff, ts >> 16 & 0xff, ts >> 8 & 0xff, ts & 0xff])
    ..add([0, 0, 0, 1])
    ..add(payload);
  return b.toBytes();
}

Uint8List _interleave(Uint8List rtp) =>
    Uint8List.fromList([0x24, 0, rtp.length >> 8, rtp.length & 0xff, ...rtp]);

String _md5(String s) => c.md5.convert(utf8.encode(s)).toString();

/// A tiny RTSP camera: Digest auth (realm "cam", nonce "n1"), one H.264
/// track, then a key picture (FU-A in 3 parts) + 2 P pictures, repeating.
class _FakeCam {
  final String user, pass;
  final bool closeAfterPlay;
  late ServerSocket server;
  int plays = 0;
  final authSeen = <String>[];
  _FakeCam({this.user = 'admin', this.pass = 'pa@ss', this.closeAfterPlay = false});

  int get port => server.port;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_conn);
  }

  Future<void> stop() => server.close();

  void _conn(Socket s) {
    var buf = '';
    Timer? pump;
    s.listen((d) {
      buf += latin1.decode(d);
      while (true) {
        final i = buf.indexOf('\r\n\r\n');
        if (i < 0) break;
        final req = buf.substring(0, i);
        buf = buf.substring(i + 4);
        final lines = req.split('\r\n');
        final parts = lines.first.split(' ');
        final method = parts[0], uri = parts[1];
        String h(String n) => lines
            .firstWhere((l) => l.toLowerCase().startsWith('${n.toLowerCase()}:'), orElse: () => ':')
            .split(':')
            .skip(1)
            .join(':')
            .trim();
        final cseq = h('CSeq');
        void reply(String status, [Map<String, String> hs = const {}, String body = '']) {
          final b = StringBuffer('RTSP/1.0 $status\r\nCSeq: $cseq\r\n');
          hs.forEach((k, v) => b.write('$k: $v\r\n'));
          if (body.isNotEmpty) b.write('Content-Length: ${utf8.encode(body).length}\r\n');
          b.write('\r\n$body');
          s.add(utf8.encode(b.toString()));
        }

        if (method == 'OPTIONS') {
          reply('200 OK', {'Public': 'OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER'});
          continue;
        }
        if (method == 'TEARDOWN') {
          reply('200 OK');
          continue;
        }
        final auth = h('Authorization');
        authSeen.add(auth);
        final ha1 = _md5('$user:cam:$pass'), ha2 = _md5('$method:$uri');
        if (!auth.contains('response="${_md5('$ha1:n1:$ha2')}"')) {
          reply('401 Unauthorized', {'WWW-Authenticate': 'Digest realm="cam", nonce="n1"'});
          continue;
        }
        if (method == 'DESCRIBE') {
          final sdp = 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=cam\r\nt=0 0\r\n'
              'm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n'
              'a=fmtp:96 packetization-mode=1;sprop-parameter-sets=${base64Encode(_sps)},${base64Encode(_pps)}\r\n'
              'a=control:trackID=1\r\n';
          reply('200 OK', {'Content-Type': 'application/sdp', 'Content-Base': 'rtsp://127.0.0.1:$port/live/'}, sdp);
        } else if (method == 'SETUP') {
          expect(uri, 'rtsp://127.0.0.1:$port/live/trackID=1');
          reply('200 OK', {'Session': 'S1;timeout=60', 'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'});
        } else if (method == 'PLAY') {
          plays++;
          reply('200 OK', {'Session': 'S1'});
          var seq = 100, ts = 9000, frame = 0;
          pump = Timer.periodic(const Duration(milliseconds: 20), (_) {
            try {
              if (frame % 3 == 0) {
                // IDR (type 5) as FU-A in 3 parts
                final idr = List<int>.generate(30, (i) => i);
                s.add(_interleave(_rtp(seq++, ts, false, [0x7c, 0x85, ...idr.sublist(0, 10)])));
                s.add(_interleave(_rtp(seq++, ts, false, [0x7c, 0x05, ...idr.sublist(10, 20)])));
                s.add(_interleave(_rtp(seq++, ts, true, [0x7c, 0x45, ...idr.sublist(20)])));
              } else {
                s.add(_interleave(_rtp(seq++, ts, true, [0x41, 0x9a, frame & 0xff])));
              }
              // RTCP-ish noise on channel 1 must be ignored
              s.add(Uint8List.fromList([0x24, 1, 0, 4, 1, 2, 3, 4]));
              ts += 3000;
              frame++;
              if (closeAfterPlay && frame > 4) {
                pump?.cancel();
                s.destroy();
              }
            } catch (_) {
              pump?.cancel();
            }
          });
        }
      }
    }, onDone: () => pump?.cancel(), onError: (_) => pump?.cancel());
  }
}

class _FakeDecoder implements IpDecoder {
  int opens = 0, feeds = 0, closes = 0;
  final fed = <Uint8List>[];
  String mime = '';
  List<Uint8List> csd = const [];
  @override
  Future<bool> available() async => true;
  @override
  Future<String?> open(String m, List<Uint8List> c) async {
    opens++;
    mime = m;
    csd = c;
    return null;
  }

  @override
  Future<bool> feed(Uint8List au, int ptsUs) async {
    feeds++;
    fed.add(au);
    return true;
  }

  @override
  Future<IpFrame?> grab({int gw = 160, int maxW = 640, int quality = 70, int timeoutMs = 3000}) async {
    if (feeds == 0) return null;
    return IpFrame(Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]), Uint8List(16 * 9), 16, 9, 640, 360);
  }

  @override
  Future<void> close() async => closes++;
}

void main() {
  group('RtspUrl', () {
    test('raw @ and / in the password; port; query kept', () {
      final u = RtspUrl.parse('rtsp://admin:pa@ss/1@192.168.1.64:8554/cam/realmonitor?channel=1&subtype=1')!;
      expect(u.user, 'admin');
      expect(u.pass, 'pa@ss/1');
      expect(u.host, '192.168.1.64');
      expect(u.port, 8554);
      expect(u.path, '/cam/realmonitor?channel=1&subtype=1');
      expect(u.bare, 'rtsp://192.168.1.64:8554/cam/realmonitor?channel=1&subtype=1');
      expect(u.redacted, isNot(contains('pa@ss')));
    });

    test('encoded credentials, default port, no user', () {
      final u = RtspUrl.parse(RtspUrl.build('10.0.0.5', '/stream2', user: 'tapo user', pass: 'p:w@d'))!;
      expect(u.user, 'tapo user');
      expect(u.pass, 'p:w@d');
      expect(u.port, 554);
      expect(u.bare, 'rtsp://10.0.0.5/stream2');
      final n = RtspUrl.parse('rtsp://10.0.0.5/live')!;
      expect(n.user, '');
      expect(RtspUrl.parse('http://x/y'), isNull);
      expect(RtspUrl.parse('rtsp://:99999/'), isNull);
    });
  });

  test('Digest auth matches RFC 2617 (no qop), Basic fallback', () {
    final a = RtspAuth.fromChallenges(['Basic realm="x"', 'Digest realm="IP Camera(12345)", nonce="abc123"'])!;
    expect(a.scheme, 'digest');
    final h = a.header('DESCRIBE', 'rtsp://192.168.1.64/Streaming/Channels/102', 'admin', 'pa@ss/1');
    expect(h, contains('response="fec83c255ddef35f3594f73634c3fdd4"'));
    final b = RtspAuth.fromChallenges(['Basic realm="x"'])!;
    expect(b.header('DESCRIBE', 'u', 'a', 'b'), 'Basic ${base64Encode(utf8.encode('a:b'))}');
    expect(RtspAuth.fromChallenges(['Bearer x']), isNull);
  });

  group('SDP', () {
    test('H.264 with parameter sets and a relative control', () {
      final v = parseSdpVideo('v=0\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=0\r\n'
          'm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n'
          'a=fmtp:96 profile-level-id=42001e;sprop-parameter-sets=${base64Encode(_sps)},${base64Encode(_pps)};packetization-mode=1\r\n'
          'a=control:trackID=1\r\n')!;
      expect(v.codec, 'H264');
      expect(v.payloadType, 96);
      expect(v.control, 'trackID=1');
      expect(v.paramSets, [_sps, _pps]);
      expect(v.mime, 'video/avc');
      expect(resolveControl('rtsp://h/live/', v.control), 'rtsp://h/live/trackID=1');
      expect(resolveControl('rtsp://h/live', 'rtsp://h/x'), 'rtsp://h/x');
    });

    test('H.265 (Hikvision default) and unsupported MJPEG', () {
      final v = parseSdpVideo('m=video 0 RTP/AVP 98\na=rtpmap:98 H265/90000\n'
          'a=fmtp:98 sprop-vps=QAEMAf//;sprop-sps=QgEBAWAA;sprop-pps=RAHA\na=control:*\n')!;
      expect(v.codec, 'H265');
      expect(v.paramSets.length, 3);
      expect(v.mime, 'video/hevc');
      expect(resolveControl('rtsp://h/a', '*'), 'rtsp://h/a');
      final j = parseSdpVideo('m=video 0 RTP/AVP 26\na=control:t\n')!;
      expect(j.supported, isFalse);
      expect(parseSdpVideo('m=audio 0 RTP/AVP 0\n'), isNull);
    });
  });

  group('depacketizers + access units', () {
    test('H.264 STAP-A and FU-A; key picture carries SPS/PPS', () {
      final d = H264Depacketizer();
      final stap = d.push(Uint8List.fromList([0x18, 0, 2, 0x06, 0x01, 0, 3, 0x41, 0xaa, 0xbb]));
      expect(stap.map((n) => n.length), [2, 3]);
      expect(d.push(Uint8List.fromList([0x7c, 0x85, 1, 2])), isEmpty);
      expect(d.push(Uint8List.fromList([0x7c, 0x05, 3])), isEmpty);
      final fu = d.push(Uint8List.fromList([0x7c, 0x45, 4]));
      expect(fu.single, [0x65, 1, 2, 3, 4]);
      final asm = AuAssembler(hevc: false, sdpParams: [_sps, _pps]);
      expect(asm.hasParams, isTrue);
      final au = asm.push(fu, 1000, true).single;
      expect(au.key, isTrue);
      expect(au.data.sublist(0, 4), [0, 0, 0, 1]);
      expect(au.data.sublist(4, 4 + _sps.length), _sps);
      final p = asm.push([Uint8List.fromList([0x41, 1])], 2000, true).single;
      expect(p.key, isFalse);
      expect(p.data, [0, 0, 0, 1, 0x41, 1]);
    });

    test('a lost packet drops the picture; timestamp change flushes', () {
      final asm = AuAssembler(hevc: false, sdpParams: [_sps, _pps]);
      asm.push([Uint8List.fromList([0x41, 1])], 1, false);
      asm.lost();
      expect(asm.push([Uint8List.fromList([0x41, 2])], 2, false), isEmpty); // broken one dropped
      final out = asm.push([Uint8List.fromList([0x41, 3])], 3, true);
      expect(out.length, 2);
    });

    test('H.265 FU rebuilds the NAL header; IRAP = key', () {
      final d = H265Depacketizer();
      // FU of an IDR_W_RADL (type 19): header type 49 = 0x62 0x01
      expect(d.push(Uint8List.fromList([0x62, 0x01, 0x80 | 19, 9, 9])), isEmpty);
      final n = d.push(Uint8List.fromList([0x62, 0x01, 0x40 | 19, 8])).single;
      expect(h265Type(n), 19);
      expect(n, [19 << 1, 0x01, 9, 9, 8]);
      final asm = AuAssembler(hevc: true, sdpParams: [
        Uint8List.fromList([0x40, 0x01, 1]),
        Uint8List.fromList([0x42, 0x01, 2]),
        Uint8List.fromList([0x44, 0x01, 3]),
      ]);
      expect(asm.hasParams, isTrue);
      final au = asm.push([n], 5, true).single;
      expect(au.key, isTrue);
      expect(au.data.sublist(4, 7), [0x40, 0x01, 1]); // VPS first
    });

    test('RTP header with CSRC, extension and padding', () {
      final raw = Uint8List.fromList([
        0xb1, 0xe0, 0, 7, 0, 0, 0, 9, 0, 0, 0, 1, // V2 P X CC=1, M, PT 96
        1, 2, 3, 4, // CSRC
        0xbe, 0xde, 0, 1, 9, 9, 9, 9, // extension, 1 word
        0x41, 0x55, 0, 2, // payload + 2 padding bytes
      ]);
      final p = RtpPacket.parse(raw)!;
      expect(p.pt, 96);
      expect(p.marker, isTrue);
      expect(p.seq, 7);
      expect(p.payload, [0x41, 0x55]);
      expect(RtpPacket.parse(Uint8List(5)), isNull);
    });
  });

  group('session against a fake camera (Digest + interleaved RTP)', () {
    test('plays: key picture with SPS/PPS first, then P pictures', () async {
      final cam = _FakeCam();
      await cam.start();
      final s = RtspSession(RtspUrl.parse('rtsp://admin:pa@ss@127.0.0.1:${cam.port}/live')!);
      await s.open();
      expect(s.video.codec, 'H264');
      final units = await s.units.take(4).toList().timeout(const Duration(seconds: 5));
      expect(units.first.key, isTrue);
      expect(units.first.data.sublist(4, 4 + _sps.length), _sps);
      expect(units[1].key, isFalse);
      expect(units[3].key, isTrue);
      expect(s.lostPackets, 0);
      expect(cam.authSeen.where((a) => a.startsWith('Digest')), isNotEmpty);
      await s.close();
      await cam.stop();
    });

    test('wrong password = auth; nothing listening = unreachable', () async {
      final cam = _FakeCam();
      await cam.start();
      final s = RtspSession(RtspUrl.parse('rtsp://admin:nope@127.0.0.1:${cam.port}/live')!);
      await expectLater(s.open(), throwsA(isA<RtspException>().having((e) => e.kind, 'kind', RtspFail.auth)));
      await cam.stop();
      final port = cam.port;
      final u = RtspSession(RtspUrl.parse('rtsp://127.0.0.1:$port/x')!,
          ioTimeout: const Duration(seconds: 2));
      await expectLater(
          u.open(), throwsA(isA<RtspException>().having((e) => e.kind, 'kind', RtspFail.unreachable)));
    });
  });

  group('pipeline', () {
    test('opens the decoder on the first key picture with the SDP parameter sets; grabs a frame', () async {
      final cam = _FakeCam();
      await cam.start();
      final dec = _FakeDecoder();
      final p = IpCamPipeline('rtsp://admin:pa@ss@127.0.0.1:${cam.port}/live', dec);
      expect(await p.start(), isNull);
      IpFrame? f;
      for (var i = 0; i < 50 && f == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        f = await p.grab();
      }
      expect(f, isNotNull);
      expect(dec.opens, 1);
      expect(dec.mime, 'video/avc');
      expect(dec.csd, [_sps, _pps]);
      expect(dec.fed.first.sublist(4, 5), [0x67]); // key picture first
      expect(p.codec, 'H264');
      await p.stop();
      expect(dec.closes, 1);
      await cam.stop();
    });

    test('reconnects after the camera drops the connection', () async {
      final cam = _FakeCam(closeAfterPlay: true);
      await cam.start();
      final dec = _FakeDecoder();
      final p = IpCamPipeline('rtsp://admin:pa@ss@127.0.0.1:${cam.port}/live', dec,
          backoff: (_) => const Duration(milliseconds: 50));
      await p.run();
      for (var i = 0; i < 100 && cam.plays < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(cam.plays, greaterThanOrEqualTo(2));
      expect(p.reconnects, greaterThanOrEqualTo(1));
      await p.stop();
      await cam.stop();
    });

    test('a wrong password is reported, not retried by start()', () async {
      final cam = _FakeCam();
      await cam.start();
      final p = IpCamPipeline('rtsp://admin:x@127.0.0.1:${cam.port}/live', _FakeDecoder());
      expect(await p.start(), RtspFail.auth);
      await p.stop();
      await cam.stop();
    });
  });

  group('FeedGate (old phones)', () {
    AccessUnit au(bool key) => AccessUnit(Uint8List(1), key, 0);
    test('waits for a key picture; backlog drops until the next key; 3 overflows = key only', () {
      final g = FeedGate(maxBacklog: 5);
      final t0 = DateTime(2026, 11, 9);
      expect(g.accept(au(false), 0, now: t0), isFalse);
      expect(g.accept(au(true), 0, now: t0), isTrue);
      expect(g.accept(au(false), 0, now: t0), isTrue);
      expect(g.accept(au(false), 5, now: t0), isFalse); // overflow
      expect(g.accept(au(false), 0, now: t0), isFalse); // until a key
      expect(g.accept(au(true), 0, now: t0), isTrue);
      g.accept(au(false), 5, now: t0.add(const Duration(seconds: 1)));
      expect(g.keyOnly, isFalse);
      g.accept(au(false), 5, now: t0.add(const Duration(seconds: 2)));
      expect(g.keyOnly, isTrue);
      expect(g.accept(au(true), 0), isTrue);
      expect(g.accept(au(false), 0), isFalse);
    });
  });
}
