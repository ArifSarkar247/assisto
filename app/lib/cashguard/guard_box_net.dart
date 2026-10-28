// cashguard — Guard Box LAN helpers (pure Dart: dart:io + package:http +
// package:crypto). Everything here talks ONLY to the shop's own network:
//   * WS-Discovery probe (ONVIF cameras on the same Wi-Fi) — the probe goes
//     to the multicast group, answers come back UNICAST to our socket, so no
//     Android MulticastLock is needed to receive them;
//   * ONVIF GetCapabilities -> GetProfiles -> GetSnapshotUri, with a WS-Security
//     UsernameToken (PasswordDigest);
//   * vendor snapshot URL templates when ONVIF is off (Hikvision ISAPI,
//     Dahua / Imou CGI);
//   * HTTP Basic / Digest (MD5, qop=auth) snapshot GETs.
// The camera password stays on this phone (secure storage) — never sent to
// our server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------- discovery
String wsProbe(String id) => '<?xml version="1.0" encoding="UTF-8"?>'
    '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
    '<e:Header><w:MessageID>uuid:$id</w:MessageID>'
    '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
    '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
    '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>';

/// XAddrs (ONVIF device service URLs) in a ProbeMatches answer.
List<String> parseXAddrs(String xml) {
  final m = RegExp(r'<[^>]*XAddrs[^>]*>([^<]+)<').allMatches(xml);
  final out = <String>[];
  for (final x in m) {
    for (final u in x.group(1)!.trim().split(RegExp(r'\s+'))) {
      if (u.startsWith('http://') && !u.contains('[') && !out.contains(u)) out.add(u);
    }
  }
  return out;
}

class DiscoveredCamera {
  final String host;
  final String xaddr;
  final String name;
  const DiscoveredCamera(this.host, this.xaddr, this.name);
}

String _scopeName(String xml) {
  final m = RegExp(r'onvif://www\.onvif\.org/(?:name|hardware)/([^\s<]+)').firstMatch(xml);
  return m == null ? '' : Uri.decodeComponent(m.group(1)!).replaceAll('_', ' ');
}

/// Probe the LAN for [wait]; never throws (no Wi-Fi -> empty list).
Future<List<DiscoveredCamera>> discoverOnvif({Duration wait = const Duration(seconds: 3)}) async {
  final found = <String, DiscoveredCamera>{};
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final id = List<String>.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
    final probe = utf8.encode(wsProbe('$id-0000-4000-8000-000000000000'));
    s.send(probe, InternetAddress('239.255.255.250'), 3702);
    final done = Completer<void>();
    final timer = Timer(wait, () {
      if (!done.isCompleted) done.complete();
    });
    s.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = s!.receive();
      if (d == null) return;
      final xml = utf8.decode(d.data, allowMalformed: true);
      for (final x in parseXAddrs(xml)) {
        final host = Uri.tryParse(x)?.host ?? d.address.address;
        found.putIfAbsent(host, () => DiscoveredCamera(host, x, _scopeName(xml)));
      }
    });
    await done.future;
    timer.cancel();
  } catch (_) {
    // no network / multicast blocked: honest empty result
  } finally {
    s?.close();
  }
  return found.values.toList();
}

// ---------------------------------------------------------------- onvif
String _wsse(String user, String pass, {DateTime? now, Uint8List? nonce}) {
  final n = nonce ?? Uint8List.fromList(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
  final created = (now ?? DateTime.now().toUtc()).toIso8601String().split('.').first + 'Z';
  final digest = base64Encode(c.sha1.convert([...n, ...utf8.encode(created), ...utf8.encode(pass)]).bytes);
  return '<s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
      '<UsernameToken><Username>${_esc(user)}</Username>'
      '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</Password>'
      '<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${base64Encode(n)}</Nonce>'
      '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</Created>'
      '</UsernameToken></Security></s:Header>';
}

String _esc(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _soap(String body, String user, String pass) =>
    '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
    '${_wsse(user, pass)}<s:Body>$body</s:Body></s:Envelope>';

String? xmlFirst(String xml, String tag) {
  final m = RegExp('<(?:[A-Za-z0-9]+:)?$tag(?:\\s[^>]*)?>\\s*([^<]*?)\\s*</(?:[A-Za-z0-9]+:)?$tag>')
      .firstMatch(xml);
  return m?.group(1);
}

String? mediaXAddr(String capsXml) {
  final i = capsXml.indexOf('Media');
  if (i < 0) return null;
  return xmlFirst(capsXml.substring(i), 'XAddr');
}

String? firstProfileToken(String profilesXml) =>
    RegExp(r'<(?:[A-Za-z0-9]+:)?Profiles[^>]*\btoken="([^"]+)"').firstMatch(profilesXml)?.group(1);

/// ONVIF snapshot URL of a camera, or null (ONVIF off / no snapshot support).
Future<String?> onvifSnapshotUri(String xaddr, String user, String pass, {http.Client? client}) async {
  final cl = client ?? http.Client();
  Future<String?> call(String url, String body) async {
    try {
      final r = await cl
          .post(Uri.parse(url),
              headers: {'Content-Type': 'application/soap+xml; charset=utf-8'},
              body: _soap(body, user, pass))
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200 ? r.body : null;
    } catch (_) {
      return null;
    }
  }

  final caps = await call(xaddr,
      '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>Media</Category></GetCapabilities>');
  final media = caps == null ? null : mediaXAddr(caps);
  if (media == null) return null;
  final prof = await call(media, '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>');
  final token = prof == null ? null : firstProfileToken(prof);
  if (token == null) return null;
  final snap = await call(media,
      '<GetSnapshotUri xmlns="http://www.onvif.org/ver10/media/wsdl"><ProfileToken>${_esc(token)}</ProfileToken></GetSnapshotUri>');
  final uri = snap == null ? null : xmlFirst(snap, 'Uri');
  return (uri == null || uri.isEmpty) ? null : uri.replaceAll('&amp;', '&');
}

/// Well-known LAN snapshot URLs when ONVIF is off.
List<String> vendorSnapshotUrls(String vendor, String host, {int channel = 1}) => switch (vendor) {
      'hikvision' => ['http://$host/ISAPI/Streaming/channels/${channel}01/picture'],
      'dahua' || 'imou' => ['http://$host/cgi-bin/snapshot.cgi?channel=$channel'],
      _ => [
          'http://$host/ISAPI/Streaming/channels/${channel}01/picture',
          'http://$host/cgi-bin/snapshot.cgi?channel=$channel',
        ],
    };

// ---------------------------------------------------------------- http auth
/// Digest Authorization header for [challenge] (RFC 7616, MD5, qop=auth).
String digestHeader(String challenge, String method, Uri uri, String user, String pass,
    {String? cnonce, int nc = 1}) {
  final p = <String, String>{};
  for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(challenge)) {
    p[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  String md5(String s) => c.md5.convert(utf8.encode(s)).toString();
  final realm = p['realm'] ?? '', nonce = p['nonce'] ?? '';
  final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  final ha1 = md5('$user:$realm:$pass');
  final ha2 = md5('$method:$path');
  final qop = (p['qop'] ?? '').split(',').map((e) => e.trim()).contains('auth') ? 'auth' : '';
  final cn = cnonce ?? List<String>.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  final ncs = nc.toRadixString(16).padLeft(8, '0');
  final resp = qop.isEmpty ? md5('$ha1:$nonce:$ha2') : md5('$ha1:$nonce:$ncs:$cn:$qop:$ha2');
  return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$path", '
      'response="$resp"${qop.isEmpty ? '' : ', qop=$qop, nc=$ncs, cnonce="$cn"'}'
      '${p.containsKey('opaque') ? ', opaque="${p['opaque']}"' : ''}, algorithm=MD5';
}

/// GETs JPEG stills from one camera URL, answering Basic or Digest
/// challenges (the challenge is remembered between frames).
class SnapshotFetcher {
  final String url;
  final String user, pass;
  final http.Client _c;
  String? _challenge;
  int _nc = 0;
  static const maxBytes = 2 * 1024 * 1024;
  SnapshotFetcher(this.url, this.user, this.pass, {http.Client? client}) : _c = client ?? http.Client();

  Map<String, String> _auth(Uri u) {
    final ch = _challenge;
    if (ch == null) return const {};
    if (ch.toLowerCase().startsWith('digest')) {
      _nc++;
      return {'Authorization': digestHeader(ch, 'GET', u, user, pass, nc: _nc)};
    }
    return {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$pass'))}'};
  }

  /// One still, or null. Throws nothing; [lastStatus] says why.
  int lastStatus = 0;
  Future<Uint8List?> fetch() async {
    final u = Uri.parse(url);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await _c.get(u, headers: _auth(u)).timeout(const Duration(seconds: 5));
        lastStatus = r.statusCode;
        if (r.statusCode == 401 && attempt == 0) {
          _challenge = r.headers['www-authenticate'] ?? 'Basic';
          _nc = 0;
          continue;
        }
        if (r.statusCode != 200 || r.bodyBytes.length > maxBytes) return null;
        final b = r.bodyBytes;
        if (b.length < 3 || b[0] != 0xff || b[1] != 0xd8) return null; // JPEG only
        return b;
      } catch (_) {
        lastStatus = 0;
        return null;
      }
    }
    return null;
  }

  void close() => _c.close();
}
