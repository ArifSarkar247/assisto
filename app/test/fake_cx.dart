// circle-extras: gallery stubs for "Linked devices" + "Link a phone"
// (shapes mirror backend core/device_link.py). Made-up sample data only.
import 'dart:convert';
import 'dart:typed_data';

String _norm(String path) =>
    (path.startsWith('/') ? path.substring(1) : path).split('?').first;

final _samplePub = base64Encode(Uint8List.fromList(List.generate(32, (i) => i * 7 % 256)));

Map<String, dynamic>? fakeCxGet(String path, {bool bn = true, bool empty = false}) {
  final p = _norm(path);
  if (p == 'messenger/linked-devices') {
    if (empty) return {'devices': <Map<String, dynamic>>[], 'count': 0};
    final now = DateTime.now();
    return {
      'count': 1,
      'devices': [
        {
          'device_id': 'sample-tab-1',
          'name': 'Samsung Galaxy Tab A8',
          'platform': 'android',
          'platform_label': bn ? 'অ্যান্ড্রয়েড' : 'Android',
          'role': 'linked',
          'linked_at': now.subtract(const Duration(days: 3)).toIso8601String(),
          'last_active': now.subtract(const Duration(minutes: 5)).toIso8601String(),
          'current': false,
          'revoked': false,
        },
      ],
    };
  }
  if (p == 'e2/link/status') {
    return {'state': 'waiting', 'pair': 1, 'eph_pub': _samplePub};
  }
  return null;
}

Map<String, dynamic>? fakeCxPost(String path, Map<String, dynamic> body) {
  final p = _norm(path);
  if (p == 'e2/link/start') {
    return {
      'token': 'sample-token',
      'code': 'KTQM-WHXP',
      'qr': 'assisto-link:1:sample-token',
      'ttl_sec': 120,
    };
  }
  if (p == 'e2/link/approve') return {'ok': true, 'state': 'approved'};
  if (p.startsWith('messenger/linked-devices/')) return {'ok': true, 'revoked': true};
  return null;
}
