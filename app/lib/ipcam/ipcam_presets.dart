// cctvbox — RTSP addresses of the IP cameras common in Bangladesh, so the
// owner only types the camera's IP + password (or nothing: ONVIF finds it).
// SUB stream first (small picture = cheap to decode on a 2 GB phone, enough
// for person checks and SD live), main stream as the fallback.
import 'package:http/http.dart' as http;

import '../cashguard/guard_box_net.dart' show onvifCall, mediaXAddr, xmlFirst;
import 'rtsp_client.dart';

const kIpCamBrands = ['hikvision', 'dahua', 'imou', 'ezviz', 'tapo', 'onvif', 'rtsp'];

/// Default user name per brand ('' = the user must type it).
String defaultUser(String brand) => switch (brand) {
      'tapo' => '',
      'rtsp' => '',
      _ => 'admin',
    };

/// Candidate RTSP paths for [brand], sub stream first. [channel] = NVR/DVR
/// channel (1 for a single camera).
List<String> brandPaths(String brand, {int channel = 1}) => switch (brand) {
      'hikvision' => ['/Streaming/Channels/${channel}02', '/Streaming/Channels/${channel}01'],
      'dahua' || 'imou' => [
          '/cam/realmonitor?channel=$channel&subtype=1',
          '/cam/realmonitor?channel=$channel&subtype=0',
        ],
      'ezviz' => [
          '/h264/ch$channel/sub/av_stream',
          '/Streaming/Channels/${channel}02',
          '/h264/ch$channel/main/av_stream',
        ],
      'tapo' => ['/stream2', '/stream1'],
      _ => const [],
    };

/// Full candidate URLs (credentials inside; they stay on this phone).
List<String> brandUrls(String brand, String host, String user, String pass, {int channel = 1}) {
  final h = host.trim();
  if (h.isEmpty) return const [];
  var port = 554;
  var hostOnly = h;
  final i = h.lastIndexOf(':');
  if (i > 0) {
    final p = int.tryParse(h.substring(i + 1));
    if (p != null) {
      port = p;
      hostOnly = h.substring(0, i);
    }
  }
  return [
    for (final p in brandPaths(brand, channel: channel))
      RtspUrl.build(hostOnly, p, user: user.trim(), pass: pass, port: port)
  ];
}

/// A brand guessed from an ONVIF scope name ("HIKVISION DS-2CD..." ...).
String guessBrand(String name) {
  final n = name.toLowerCase();
  if (n.contains('hikvision') || n.contains('ds-2c')) return 'hikvision';
  if (n.contains('imou')) return 'imou';
  if (n.contains('dahua') || n.contains('ipc-h')) return 'dahua';
  if (n.contains('ezviz')) return 'ezviz';
  if (n.contains('tapo') || n.contains('tp-link')) return 'tapo';
  return 'onvif';
}

/// Put [user]/[pass] into an RTSP URL the camera reported (ONVIF answers
/// without credentials).
String withCreds(String rtsp, String user, String pass) {
  final u = RtspUrl.parse(rtsp);
  if (u == null) return rtsp;
  return RtspUrl.build(u.host, u.path,
      user: u.user.isNotEmpty ? u.user : user.trim(),
      pass: u.pass.isNotEmpty ? u.pass : pass,
      port: u.port);
}

/// ONVIF GetProfiles -> GetStreamUri (RTP-Unicast over RTSP). Profiles in the
/// camera's order are main, sub, ...: the SUB stream is returned first.
/// Empty when ONVIF is off or the login is refused.
Future<List<String>> onvifStreamUris(String xaddr, String user, String pass, {http.Client? client}) async {
  final caps = await onvifCall(xaddr,
      '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>Media</Category></GetCapabilities>',
      user, pass, client: client);
  final media = caps == null ? null : mediaXAddr(caps);
  if (media == null) return const [];
  final prof = await onvifCall(media, '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>', user, pass,
      client: client);
  if (prof == null) return const [];
  final tokens = [
    for (final m in RegExp(r'<(?:[A-Za-z0-9]+:)?Profiles[^>]*\btoken="([^"]+)"').allMatches(prof)) m.group(1)!
  ];
  if (tokens.length > 1) tokens.insert(0, tokens.removeAt(1)); // sub stream first
  final out = <String>[];
  for (final t in tokens.take(3)) {
    final r = await onvifCall(
        media,
        '<GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup>'
        '<Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>'
        '<Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>'
        '</StreamSetup><ProfileToken>${t.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</ProfileToken></GetStreamUri>',
        user,
        pass,
        client: client);
    final u = r == null ? null : xmlFirst(r, 'Uri');
    if (u != null && u.toLowerCase().startsWith('rtsp://')) {
      final full = withCreds(u.replaceAll('&amp;', '&'), user, pass);
      if (!out.contains(full)) out.add(full);
    }
  }
  return out;
}
