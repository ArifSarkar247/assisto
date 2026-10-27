// cctv1: an in-memory WatchmanSource for the gallery + widget tests. Shapes
// mirror backend/core/watchman_views.py (overview, setup, cameras, gateway
// tasks, zones, events, viewers).
import 'package:assisto/api.dart';
import 'package:assisto/screens/watchman/watchman_source.dart';

class FakeWatchman implements WatchmanSource {
  /// 'empty' (first run), 'data' (a home + a shop), 'offline' (gateway down),
  /// 'off' (feature flag hidden), 'fail' (network error).
  final String mode;
  FakeWatchman([this.mode = 'data']);

  final List<String> calls = [];
  Map<String, dynamic>? lastCheckBody;
  Map<String, dynamic>? savedZones;
  String? markedVerdict;
  int taskPolls = 0;

  /// What the gateway answers for a check: 'ok', 'auth', 'unreachable'.
  String checkOutcome = 'ok';

  static Map<String, dynamic> camera({int id = 11, String name = 'Front door', String vendor = 'imou',
          bool online = true, Map<String, dynamic>? compat}) =>
      {
        'id': id, 'name': name, 'kind': 'shopbox', 'enabled': true, 'vendor': vendor,
        'online': online, 'last_seen': '2026-10-26T10:00:00+06:00',
        'source': {'host': '192.168.1.20', 'port': 554, 'channel': 1, 'stream': 'sub'},
        'compat': compat ?? {'ok': true, 'steps': []}, 'has_preview': false,
        'zones_v2': true, 'cloud_alarms': false,
      };

  Map<String, dynamic> _site(int id, String kind, String gateway, {bool online = true, String role = 'owner'}) => {
        'id': id, 'name': kind == 'home' ? 'Dhanmondi flat' : 'Mirpur shop', 'kind': kind,
        'gateway': gateway, 'role': role, 'snapshot_retention_days': 3,
        'enrollment_token': role == 'owner' ? 'PAIR-CODE-FAKE-1' : null,
        'owner_name': role == 'owner' ? '' : 'Rahim',
        'gateway_state': {
          'online': online,
          'last_seen': online ? '2026-10-26T10:00:00+06:00' : '2026-10-25T21:15:00+06:00',
          'never_seen': false,
        },
        'cameras_list': [
          camera(),
          if (kind == 'shop')
            camera(id: 12, name: 'Cash counter', vendor: 'hikvision', online: online,
                compat: {'ok': false, 'steps': [{'key': 'auth', 'ok': false, 'code': 'auth_failed'}]}),
        ],
        'open_alerts': kind == 'home' ? 2 : 0,
        'today_alerts': 2,
        'held_today': kind == 'shop' ? 3 : 0,
      };

  void _fail() {
    if (mode == 'fail') throw ApiException('Error 500', 500);
    if (mode == 'off') throw ApiException('This feature is not available yet.', 403);
  }

  @override
  Future<Map<String, dynamic>> overview() async {
    calls.add('overview');
    _fail();
    final sites = switch (mode) {
      'empty' => <Map<String, dynamic>>[],
      'offline' => [_site(1, 'home', 'pc', online: false)],
      'viewer' => [_site(1, 'home', 'pc', role: 'viewer')],
      _ => [_site(1, 'home', 'pc'), _site(2, 'shop', 'shopbox')],
    };
    return {
      'feature_on': true, 'sites': sites, 'setup_needed': sites.isEmpty,
      'plan': 'premium', 'can_shop': mode != 'empty', 'credits': 120,
      'limits': {'included_cameras': 0, 'credits_per_extra_camera': 30, 'period_days': 30,
                 'daily_alert_cap': 30, 'group_min': 10},
      'imou_cloud': false,
      'notice': {
        'en': 'Notice: this place is watched by CCTV cameras. They are used only for safety.',
        'bn': 'বিজ্ঞপ্তি: এই জায়গাটি সিসিটিভি ক্যামেরা দিয়ে নজরে রাখা হয়। ক্যামেরা শুধু নিরাপত্তার জন্য।',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> setup(String kind, String gateway, String name) async {
    calls.add('setup:$kind:$gateway');
    return _site(3, kind, gateway);
  }

  @override
  Future<Map<String, dynamic>> addCamera(int siteId, Map<String, dynamic> body) async {
    calls.add('addCamera:${body['vendor']}');
    if ((body['source'] as Map?)?['password'] != null) throw StateError('password sent');
    return camera(id: 21, name: body['name'].toString(), vendor: body['vendor'].toString())
      ..['compat'] = {};
  }

  @override
  Future<Map<String, dynamic>> queueCheck(int cameraId, Map<String, dynamic> body) async {
    calls.add('check:$cameraId');
    lastCheckBody = body;
    return {'id': 5, 'action': 'check', 'status': 'pending', 'camera': cameraId,
            'request': {'vendor': 'imou'}, 'result': {},
            'gateway': {'online': true, 'last_seen': '2026-10-26T10:00:00+06:00'}};
  }

  @override
  Future<Map<String, dynamic>> discover(int siteId) async {
    calls.add('discover');
    return {'id': 6, 'status': 'done', 'result': {'ok': true, 'discovered': [
      {'host': '192.168.1.20', 'manufacturer': 'Imou', 'model': 'Ranger 2'}]}};
  }

  static Map<String, dynamic> result(String outcome) => switch (outcome) {
        'auth' => {'ok': false, 'steps': [
            {'key': 'reachable', 'ok': true, 'code': ''},
            {'key': 'auth', 'ok': false, 'code': 'auth_failed'},
            {'key': 'stream', 'ok': null, 'code': 'skipped'},
          ]},
        'unreachable' => {'ok': false, 'steps': [
            {'key': 'reachable', 'ok': false, 'code': 'unreachable'},
          ]},
        _ => {'ok': true, 'steps': [
            {'key': 'reachable', 'ok': true, 'code': ''},
            {'key': 'auth', 'ok': true, 'code': ''},
            {'key': 'stream', 'ok': true, 'code': ''},
            {'key': 'snapshot', 'ok': true, 'code': ''},
            {'key': 'events', 'ok': null, 'code': 'not_checked'},
          ], 'info': {'width': 1920, 'height': 1080, 'fps': 15.0}},
      };

  @override
  Future<Map<String, dynamic>> task(int taskId) async {
    taskPolls++;
    return {'id': taskId, 'action': 'check', 'status': 'done', 'request': {'vendor': 'imou'},
            'result': result(checkOutcome),
            'gateway': {'online': true, 'last_seen': '2026-10-26T10:00:00+06:00'}};
  }

  @override
  Future<Map<String, dynamic>> zones(int cameraId) async => {
        'camera': cameraId,
        'zone_config': {
          'v': 2,
          'zones': [
            {'id': 'z1', 'type': 'restricted', 'points': [[0.1, 0.2], [0.45, 0.2], [0.45, 0.8], [0.1, 0.8]]},
            {'id': 'z2', 'type': 'entry_line', 'points': [[0.55, 0.9], [0.95, 0.9]]},
          ],
          'schedule': {'days': [0, 1, 2, 3, 4], 'start': '22:00', 'end': '06:00'},
          'sensitivity': 'medium',
          'quiet_hours': {'start': '23:00', 'end': '07:00'},
        },
        'tuning': {'person_conf': 0.5, 'motion_mult': 1.15, 'cooldown_s': 240, 'correct': 3, 'wrong': 1},
      };

  @override
  Future<Map<String, dynamic>> saveZones(int cameraId, Map<String, dynamic> cfg) async {
    calls.add('saveZones');
    savedZones = cfg;
    return {'camera': cameraId, 'zone_config': cfg};
  }

  @override
  Future<Map<String, dynamic>> preview(int cameraId) async =>
      throw ApiException('No picture yet — run the camera check first.', 404);

  @override
  Future<Map<String, dynamic>> linkImou(int cameraId, String serial, String code) async {
    calls.add('imou:$serial');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> events(int siteId) async {
    _fail();
    if (mode == 'empty') return {'events': [], 'held_today': 0, 'role': 'owner'};
    return {
      'role': mode == 'viewer' ? 'viewer' : 'owner',
      'held_today': 1,
      'events': [
        {'id': 101, 'type': 'person_detected', 'confidence': 0.72, 'count': 3, 'status': 'open',
         'verdict': null, 'camera': 11, 'camera_name': 'Front door', 'snapshot_url': '',
         'label': 'suspicious_please_check', 'last_at': '2026-10-26T02:14:00+06:00',
         'created': '2026-10-26T02:05:00+06:00'},
        {'id': 102, 'type': 'zone_intrusion', 'confidence': 0.75, 'count': 1, 'status': 'false_alarm',
         'verdict': 'wrong', 'camera': 11, 'camera_name': 'Front door', 'snapshot_url': '',
         'label': 'suspicious_please_check', 'last_at': '2026-10-25T23:40:00+06:00',
         'created': '2026-10-25T23:40:00+06:00'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> mark(int eventId, String verdict) async {
    markedVerdict = verdict;
    return {'ok': true, 'event_id': eventId, 'status': verdict == 'wrong' ? 'false_alarm' : 'checked',
            'verdict': verdict};
  }

  @override
  Future<Map<String, dynamic>> viewers(int siteId) async => {
        'viewers': mode == 'empty'
            ? []
            : [{'user_id': 7, 'name': 'Karima', 'phone': '017•••••002', 'since': '2026-10-26T09:00:00+06:00'}],
        'max': 5,
      };

  @override
  Future<Map<String, dynamic>> addViewer(int siteId, String phone) async {
    calls.add('addViewer:$phone');
    if (phone == '01799999999') {
      throw ApiException('No Assisto account with this number — ask them to open Assisto first.', 404);
    }
    return {'user_id': 8, 'name': 'New', 'phone': '017•••••999'};
  }

  @override
  Future<void> removeViewer(int siteId, int userId) async => calls.add('removeViewer:$userId');

  @override
  Future<Map<String, dynamic>> patchSite(int siteId, Map<String, dynamic> body) async => {};

  @override
  Future<void> deleteCamera(int cameraId) async => calls.add('deleteCamera:$cameraId');
  @override
  Future<Map<String, dynamic>> camera(int cameraId) async {
    calls.add('camera:$cameraId');
    return {'id': cameraId, 'camera_token': 'tok$cameraId'};
  }
}
