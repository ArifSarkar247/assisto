// cashguard: in-memory sources for the Smart Cash Guard widget tests + the
// screenshot gallery. Shapes mirror backend/core/cashguard_views.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/cashguard/cashguard_source.dart';
import 'package:assisto/crypto/e2e.dart';

import 'cctv1_fakes.dart';

/// A 1x1 PNG — a real, decodable frame for the clip player.
final Uint8List kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

class FakeCashGuard implements CashGuardSource {
  /// 'free' | 'business' | 'away' | 'fail'
  final String mode;
  FakeCashGuard([this.mode = 'free']);

  final List<String> calls = [];
  Map<String, dynamic>? lastAway;
  String clipStatus = 'ready';
  Map<String, dynamic> clipMeta = const {};
  Uint8List clipBytes = Uint8List(0);
  List<IdentityKeyPair> keys = const [];

  @override
  Future<Map<String, dynamic>> overview() async {
    calls.add('overview');
    if (mode == 'fail') throw ApiException('Error 500', 500);
    final biz = mode == 'business';
    return {
      'caps': {'tier': biz ? 'business' : 'free', 'cameras': biz ? 4 : 1,
               'alerts_day': biz ? 30 : 5, 'clips_day': biz ? 10 : 1, 'clip_kb': 900},
      'usage': {'cameras': 1, 'clips_today': 0},
      'sites': [
        {'site': 1, 'name': 'Mirpur shop', 'kind': 'shop', 'active': mode == 'away',
         'until': mode == 'away' ? '2026-10-28T18:00:00+06:00' : null,
         'schedule': null, 'alerts_today': 2, 'held_today': 0, 'clip_recipients': 1},
      ],
      'clip': {'seconds': [3, 5], 'ttl_hours': 24, 'end_to_end': true},
      'hand_to_pocket': {'enabled': false, 'precision': null, 'measured': false},
      'ads': false,
    };
  }

  @override
  Future<Map<String, dynamic>> setAway(int siteId, Map<String, dynamic> body) async {
    calls.add('away:$siteId');
    lastAway = body;
    final on = body['on'] == true;
    return {'site': siteId, 'active': on, 'until': on ? '2026-10-28T20:00:00+06:00' : null,
            'schedule': body['schedule']};
  }

  @override
  Future<Map<String, dynamic>> clip(int eventId) async {
    calls.add('clip:$eventId');
    if (clipStatus == 'viewed') throw ApiException('The owner watched this clip, so it was deleted. The photo stays.', 410);
    if (clipStatus == 'pending') return {'status': 'pending', 'event_id': eventId};
    return {'status': 'ready', 'event_id': eventId, 'url': 'https://example.invalid/c.bin',
            'meta': clipMeta, 'delete_on_view': true};
  }

  @override
  Future<Map<String, dynamic>> clipViewed(int eventId) async {
    calls.add('viewed:$eventId');
    return {'ok': true, 'deleted': true, 'status': 'viewed'};
  }

  @override
  Future<Uint8List> download(String url) async {
    calls.add('download');
    return clipBytes;
  }

  @override
  Future<List<IdentityKeyPair>> myKeys() async => keys;

  @override
  Future<Map<String, dynamic>> linkEzviz(int cameraId, String serial, String code) async {
    calls.add('ezviz:$cameraId:$serial');
    return {'ok': true};
  }
}

/// The watchman fake with one CASH alert (clip ready) + one away alert.
class FakeWatchmanCash extends FakeWatchman {
  FakeWatchmanCash() : super('data');

  @override
  Future<Map<String, dynamic>> events(int siteId) async => {
        'role': 'owner',
        'held_today': 0,
        'events': [
          {'id': 201, 'type': 'hand_in_cash_zone', 'confidence': 0.7, 'count': 1, 'status': 'open',
           'verdict': null, 'camera': 12, 'camera_name': 'Cash counter', 'snapshot_url': '',
           'label': 'suspicious_please_check', 'cash': true, 'away': true,
           'clip': {'status': 'ready', 'expires_at': '2026-10-29T10:00:00+06:00', 'size': 420000},
           'last_at': '2026-10-28T13:10:00+06:00', 'created': '2026-10-28T13:10:00+06:00'},
          {'id': 202, 'type': 'hand_in_cash_zone', 'confidence': 0.6, 'count': 1, 'status': 'checked',
           'verdict': 'correct', 'camera': 12, 'camera_name': 'Cash counter', 'snapshot_url': '',
           'label': 'suspicious_please_check', 'cash': true, 'away': false,
           'clip': {'status': 'viewed'},
           'last_at': '2026-10-27T13:10:00+06:00', 'created': '2026-10-27T13:10:00+06:00'},
        ],
      };
}
