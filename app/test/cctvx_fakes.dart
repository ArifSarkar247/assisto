// cctvx: an in-memory CCTV-extras source for widget tests + the screenshot
// gallery. Shapes mirror backend/core/cctvx_views.py.
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/cctvx/cctvx_source.dart';

import 'cashguard_fakes.dart';

class FakeCctvx implements CctvxSource {
  /// 'data' | 'fail' | 'empty'
  final String mode;
  FakeCctvx([this.mode = 'data']);

  final List<String> calls = [];
  final List<Map<String, dynamic>> saved = [];
  Map<String, dynamic> settings = {
    'nosale_on': true, 'nosale_min': 2, 'escalate_min': 2, 'offline_on': true,
    'offline_min': 10, 'late_on': true, 'late_min': 30, 'opened_on': true,
    'escalation': [21], 'closed_days': [4], 'shop_phone': '01712345678',
  };

  void _fail() {
    if (mode == 'fail') throw ApiException('Error 500', 500);
  }

  Map<String, dynamic> _guard() => {
        'site': 1,
        'settings': Map<String, dynamic>.from(settings),
        'circle': [
          {'uid': 21, 'name': 'Karim (manager)', 'has_key': true},
          {'uid': 22, 'name': 'Rina', 'has_key': false},
        ],
        'bounds': {'nosale_min': [1, 10], 'escalate_min': [1, 10], 'offline_min': [5, 60],
                   'late_min': [10, 180]},
        'max_chain': 3,
        'caps': {'escalations_day': 4, 'offline_day': 4, 'sirens_day': 5, 'notices_day': 2,
                 'clips_day': 2, 'alerts_day': 12, 'tier': 'premium'},
        'usage': {'escalations_day': 1, 'offline_day': 0, 'sirens_day': 0, 'notices_day': 1},
        'uses_records': true,
        'tip': null,
        'ads': false,
      };

  @override
  Future<Map<String, dynamic>> guard(int siteId) async {
    calls.add('guard:$siteId');
    _fail();
    return _guard();
  }

  @override
  Future<Map<String, dynamic>> saveGuard(int siteId, Map<String, dynamic> body) async {
    calls.add('save:$siteId');
    saved.add(body);
    settings = {...settings, ...body};
    return _guard();
  }

  @override
  Future<Map<String, dynamic>> report(int siteId) async {
    calls.add('report:$siteId');
    _fail();
    if (mode == 'empty') return {'lines': [], 'counts': {}};
    return {
      'lines': [
        'Cash drawer: 14 time(s) with a sale, 1 without.',
        'Camera/internet silent: 12 min.',
        'The shop opened at 09:07.',
      ],
      'credits': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> privacyKit(int siteId) async {
    calls.add('kit:$siteId');
    _fail();
    return kFakeKit;
  }

  @override
  Future<Map<String, dynamic>> placement(int cameraId) async {
    calls.add('placement:$cameraId');
    _fail();
    return kFakePlacementDark;
  }

  @override
  Future<Map<String, dynamic>> event(int eventId) async {
    calls.add('event:$eventId');
    _fail();
    return kFakeEventActions;
  }

  @override
  Future<Map<String, dynamic>> opened(int eventId) async {
    calls.add('opened:$eventId');
    return {'ok': true, 'opened_at': '2026-10-28T10:00:00+06:00'};
  }

  @override
  Future<Map<String, dynamic>> siren(int eventId, {int? cameraId, int? seconds}) async {
    calls.add('siren:$eventId');
    return {'ok': true, 'route': 'imou_cloud', 'status': 'sounding', 'seconds': 15};
  }

  @override
  Future<Map<String, dynamic>> shareTargets(int eventId) async {
    calls.add('targets:$eventId');
    return {
      'people': [
        {'uid': 21, 'name': 'Karim (manager)', 'has_key': true, 'key_id': 'abcdef012345',
         'pub': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='},
      ],
      'shares_left': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> share(int eventId, int uid, Map<String, String> wrap,
      {Uint8List? ciphertext}) async {
    calls.add('share:$eventId:$uid');
    return {'ok': true, 'uid': uid};
  }

  @override
  Future<Map<String, dynamic>> evidence(int eventId) async {
    calls.add('evidence:$eventId');
    return {
      'facts': {'shop': 'Mirpur shop', 'camera': 'Till', 'when': '2026-10-28 10:00:00',
                'event_id': eventId},
      'created': '2026-10-28T04:00:00+00:00', 'last_at': '2026-10-28T04:00:00+00:00',
      'confidence': 0.7, 'type': 'hand_in_cash_zone', 'tz': 'Asia/Dhaka', 'hash': 'sha256',
      'gd_draft': 'To\nThe Officer-in-Charge',
    };
  }

  @override
  Future<Map<String, dynamic>> evidenceRecord(int eventId, String manifestSha256, int files) async {
    calls.add('evidence_record:$eventId');
    return {'gd_draft': 'To\nThe Officer-in-Charge\n$manifestSha256', 'recorded': true};
  }

  @override
  Future<Map<String, dynamic>> inbox() async {
    calls.add('inbox');
    _fail();
    if (mode == 'empty') return {'events': [], 'hours': 48};
    return {
      'events': [
        {'id': 301, 'type': 'hand_in_cash_zone', 'nosale': true, 'role': 'escalated',
         'owner_name': 'Rahim', 'site_name': 'Mirpur shop', 'camera_name': 'Till',
         'last_at': '2026-10-28T10:02:00+06:00', 'snapshot_url': '', 'clip': null,
         'opened_at': null},
        {'id': 302, 'type': 'zone_intrusion', 'nosale': false, 'role': 'shared',
         'owner_name': 'Rahim', 'site_name': 'Mirpur shop', 'camera_name': 'Door',
         'last_at': '2026-10-28T09:40:00+06:00', 'snapshot_url': '',
         'clip': {'status': 'ready'}, 'opened_at': '2026-10-28T09:41:00+06:00'},
      ],
      'hours': 48,
    };
  }

  @override
  Future<Uint8List> download(String url) async {
    calls.add('download');
    return kTinyPng;
  }
}

const Map<String, dynamic> kFakeKit = {
  'sticker': {
    'bn': ['সিসিটিভি চালু আছে', 'নিরাপত্তা ও ক্যাশ হিসাবের জন্য এই মিরপুর শপ ক্যামেরায় দেখা হয়।',
           'শব্দ রেকর্ড হয় না · মুখ চেনার ব্যবস্থা নেই', 'প্রশ্ন থাকলে মালিকের সাথে কথা বলুন'],
    'en': ['CCTV in operation', 'This Mirpur shop is watched by cameras for safety and cash checks.',
           'No sound recording · No face recognition', 'Questions? Please ask the owner'],
  },
  'staff_notice': {
    'bn': 'কর্মীদের জন্য বিজ্ঞপ্তি\n\nএই দোকানে সিসিটিভি ক্যামেরা চালু আছে।',
    'en': 'Notice for staff\n\nCCTV cameras are in operation in this shop.',
  },
  'sizes': ['A4', 'A5'],
  'legal_note': false,
};

const Map<String, dynamic> kFakePlacementDark = {
  'ok': false,
  'score': 67,
  'checks': [
    {'key': 'light', 'ok': false, 'tip': 'The cash area is dark — add a light over the drawer.'},
    {'key': 'glare', 'ok': true, 'tip': null},
    {'key': 'clear', 'ok': true, 'tip': null},
    {'key': 'size_small', 'ok': true, 'tip': null},
    {'key': 'size_large', 'ok': true, 'tip': null},
    {'key': 'edge', 'ok': false, 'tip': 'The cash area touches the edge of the picture.'},
  ],
  'tips': ['The cash area is dark — add a light over the drawer.'],
  'honest': 'This checks light, clarity and framing — it cannot tell what is in front of the lens.',
};

const Map<String, dynamic> kFakeEventActions = {
  'role': 'owner',
  'event': {'id': 201, 'type': 'hand_in_cash_zone', 'nosale': true, 'snapshot_url': '',
            'camera_name': 'Till'},
  'actions': {
    'siren': {'supported': false, 'allowed': true, 'reason': 'ezviz_no_api',
              'detail_bn': 'EZVIZ-এর খোলা প্ল্যাটফর্মে সাইরেন বাজানোর কোনো অফিসিয়াল উপায় নেই।',
              'detail_en': "EZVIZ's open platform has no official way to sound the siren."},
    'call_shop': '01712345678',
    'emergency': '999',
    'share_clip': true,
    'evidence': true,
  },
};
