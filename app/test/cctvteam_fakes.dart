// cctvteam (W11): a fake grid / roles / share-link / neighbourhood-watch
// server for widget tests + the gallery. Shapes mirror
// backend/core/cctv_team_views.py. Two tiny schematic stills (a gate, a till)
// stand in for camera photos — clearly drawings, never a real person.
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'package:assisto/api.dart';
import 'package:assisto/screens/watchman/cctv_team_source.dart';

const _gate = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAkCAIAAAC2bqvFAAAAWElEQVR42u3PoQ2AMBRAwY6DRlcTBKIbdI1O0jW6BmMhSKrryA+XPPXcpT7u0CUAAACA0ICat7dW9tmcix8AAAAAAAAAAAAAAOCfgOO8QgcAAAAAAADwZQ/GJ0JA4iCW0gAAAABJRU5ErkJggg==';
const _till = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAkCAIAAAC2bqvFAAAATElEQVR42u3WMQ0AIAwAQeR0wQE2sIE6HLAgCw1sNFzyBm77stdMXQEAAAAAAAB4FBBRbwMAAAAAAAAAyPVCo7fUAQAAAAAAAAD8DDiUd98dla4s+gAAAABJRU5ErkJggg==';

class FakeCctvTeam extends CctvTeamSource {
  /// data | empty | fail | guard
  final String mode;
  final String lang;
  final List<Map<String, dynamic>> roleSaves = [];
  final List<Map<String, dynamic>> shares = [];
  final List<Map<String, dynamic>> linksMade = [];
  final List<int> revoked = [];
  final List<String> reports = [];
  int freshCalls = 0;
  FakeCctvTeam(this.mode, {this.lang = 'en'});

  bool get _bn => lang == 'bn';
  String get _ago => DateTime.now().toUtc().subtract(const Duration(minutes: 4)).toIso8601String();
  String get _later => DateTime.now().toUtc().add(const Duration(hours: 20)).toIso8601String();

  void _maybeFail() {
    if (mode == 'fail') throw ApiException(_bn ? 'সার্ভারে পৌঁছানো গেল না।' : 'Could not reach the server.', 503);
  }

  Map<String, dynamic> _cam(int id, String name, String status, {String? url, int open = 0,
          bool fresh = false, bool live = false, String? src = 'alert'}) =>
      {
        'id': id, 'name': name, 'vendor': fresh ? 'imou' : 'onvif', 'status': status,
        'last_seen': _ago, 'still_url': url, 'still_at': url == null ? null : _ago,
        'still_source': url == null ? null : src, 'fresh_supported': fresh,
        'live_capable': live, 'live_ok': live, 'open_alerts': open,
      };

  @override
  ImageProvider image(String url, {int width = 360}) =>
      MemoryImage(base64Decode(url.contains('till') ? _till : _gate));

  @override
  Future<Map<String, dynamic>> grid() async {
    _maybeFail();
    if (mode == 'empty') return {'sites': [], 'live_max': 2, 'live_now': 0, 'refresh_s': 60};
    final gate = _cam(5, _bn ? 'গেট' : 'Gate', 'online', url: 'mem://gate', open: 1, fresh: true, live: true);
    if (mode == 'guard') {
      return {
        'sites': [
          {'id': 1, 'name': _bn ? 'রহিম স্টোর' : 'Rahim Store', 'kind': 'shop', 'role': 'guard',
           'owner_name': 'Rahim', 'gateway_online': true, 'open_alerts': 1, 'cameras': [gate]}
        ],
        'live_max': 2, 'live_now': 0, 'refresh_s': 60,
      };
    }
    return {
      'sites': [
        {'id': 1, 'name': _bn ? 'রহিম স্টোর' : 'Rahim Store', 'kind': 'shop', 'role': 'owner',
         'owner_name': '', 'gateway_online': true, 'open_alerts': 3, 'cameras': [
           gate,
           _cam(6, _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'online', url: 'mem://till', open: 2, live: true),
           _cam(7, _bn ? 'গুদাম' : 'Store room', 'offline', url: 'mem://gate'),
           _cam(8, _bn ? 'পেছনের দরজা' : 'Back door', 'never'),
         ]},
        {'id': 2, 'name': _bn ? 'বাসা' : 'Home', 'kind': 'home', 'role': 'family',
         'owner_name': _bn ? 'আব্বু' : 'Abbu', 'gateway_online': true, 'open_alerts': 0, 'cameras': [
           _cam(9, _bn ? 'বসার ঘর' : 'Living room', 'online', url: 'mem://till'),
         ]},
      ],
      'live_max': 2, 'live_now': 0, 'refresh_s': 60,
    };
  }

  @override
  Future<Map<String, dynamic>> still(int cameraId, {bool fresh = false}) async {
    _maybeFail();
    if (fresh) freshCalls++;
    return {'camera': cameraId, 'still_url': 'mem://gate', 'still_at': DateTime.now().toUtc().toIso8601String(),
            'source': 'camera', 'fresh_supported': true, 'fresh': true};
  }

  @override
  Future<Map<String, dynamic>> roles(int siteId) async {
    _maybeFail();
    return {
      'viewers': [],
      'cameras': [
        {'id': 5, 'name': _bn ? 'গেট' : 'Gate'},
        {'id': 6, 'name': _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter'},
      ],
      'roles': ['family', 'manager', 'guard', 'staff'],
    };
  }

  @override
  Future<Map<String, dynamic>> setRole(int siteId, int userId, Map<String, dynamic> body) async {
    roleSaves.add(body);
    return {'user_id': userId, ...body};
  }

  @override
  Future<Map<String, dynamic>> accessLog(int siteId) async {
    _maybeFail();
    final note = _bn
        ? 'শুধু আপনি এই তালিকা দেখেন। Assisto-র কোনো কর্মী বা মালিক আপনার ক্যামেরা দেখতে পারেন না।'
        : 'Only you see this list. No Assisto staff member or owner can see your cameras.';
    if (mode == 'empty') return {'rows': [], 'keep_days': 30, 'note': note};
    // cctvroles: the audit list (exports / shares / changes, the owner's own too)
    if (mode == 'audit') {
      Map<String, dynamic> a(int id, String action, String who, bool owner, String detail,
              {String cam = ''}) =>
          {'id': id, 'at': _ago, 'action': action, 'user_id': owner ? 1 : 14, 'name': who,
           'is_owner': owner, 'detail': detail, 'kind': 'change', 'link_id': null,
           'link_label': '', 'camera': null, 'camera_name': cam};
      return {
        'rows': [
          a(9, 'export', 'Rahim', true, _bn ? 'সতর্কতা #২১২-এর প্রমাণ' : 'evidence of alert #212'),
          a(8, 'change', _bn ? 'সুমন (ম্যানেজার)' : 'Sumon (manager)', false,
              _bn ? 'সতর্কতা #২১১: ঠিক আছে' : 'alert #211: checked',
              cam: _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter'),
          a(7, 'role', 'Rahim', true, _bn ? 'জামাল → কর্মী' : 'Jamal → staff'),
          a(6, 'installer', _bn ? 'রানা সিসিটিভি' : 'Rana CCTV', false,
              _bn ? 'যুক্ত হয়েছেন: রানা সিসিটিভি' : 'joined: Rana CCTV'),
          a(5, 'delete', 'Rahim', true, _bn ? 'ক্যামেরা: পুরনো গেট' : 'camera: Old gate'),
          {'id': 3, 'at': _ago, 'action': 'still', 'user_id': 12, 'name': _bn ? 'জামাল (গার্ড)' : 'Jamal (guard)',
           'is_owner': false, 'detail': '', 'kind': 'view',
           'link_id': null, 'link_label': '', 'camera': 5, 'camera_name': _bn ? 'গেট' : 'Gate'},
        ],
        'keep_days': 30, 'audit_keep_days': 180, 'note': note,
      };
    }
    return {
      'rows': [
        {'id': 3, 'at': _ago, 'action': 'still', 'user_id': 12, 'name': _bn ? 'জামাল (গার্ড)' : 'Jamal (guard)',
         'link_id': null, 'link_label': '', 'camera': 5, 'camera_name': _bn ? 'গেট' : 'Gate'},
        {'id': 2, 'at': _ago, 'action': 'link', 'user_id': null, 'name': null,
         'link_id': 4, 'link_label': _bn ? 'রফিক ভাই' : 'Cousin Rafiq', 'camera': null, 'camera_name': ''},
        {'id': 1, 'at': _ago, 'action': 'live', 'user_id': 13, 'name': _bn ? 'করিমা' : 'Karima',
         'link_id': null, 'link_label': '', 'camera': 6, 'camera_name': _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter'},
      ],
      'keep_days': 30, 'note': note,
    };
  }

  @override
  Future<Map<String, dynamic>> shareLinks(int siteId) async {
    _maybeFail();
    if (mode == 'empty') return {'links': [], 'presets': [1, 24], 'max_hours': 72, 'max_active': 5};
    return {
      'links': [
        {'id': 4, 'label': _bn ? 'রফিক ভাই' : 'Cousin Rafiq', 'cameras': [5], 'state': 'active',
         'expires_at': _later, 'views': 2, 'audio': false},
        {'id': 3, 'label': '', 'cameras': [5, 6], 'state': 'revoked', 'expires_at': _ago, 'views': 0, 'audio': false},
      ],
      'presets': [1, 24], 'max_hours': 72, 'max_active': 5,
    };
  }

  @override
  Future<Map<String, dynamic>> createShareLink(int siteId, Map<String, dynamic> body) async {
    linksMade.add(body);
    return {'id': 9, 'label': body['label'], 'cameras': body['cameras'], 'state': 'active',
            'expires_at': _later, 'views': 0, 'audio': false,
            'url': 'https://lifeassisto.com/c/AbCdEfGh12345678'};
  }

  @override
  Future<Map<String, dynamic>> revokeShareLink(int linkId) async {
    revoked.add(linkId);
    return {'id': linkId, 'state': 'revoked'};
  }

  String get _note => _bn
      ? 'শুধু এই প্রাইভেট গ্রুপের সদস্যরা দেখেন; সময় শেষে ছবিটি মুছে যায়। মুখ ঝাপসা করা হয় না।'
      : 'Only members of this private group see it; the photo is deleted when time is up. Faces are NOT blurred.';

  @override
  Future<Map<String, dynamic>> watchGroups() async {
    _maybeFail();
    if (mode == 'empty') return {'groups': [], 'hours': [6, 24, 72], 'default_hours': 24, 'note': _note};
    return {
      'groups': [
        {'id': 21, 'name': _bn ? 'রোড ৩ পাহারা' : 'Road 3 watch', 'community': _bn ? 'রোড ৩ প্রতিবেশী' : 'Road 3 neighbours', 'members': 14},
      ],
      'hours': [6, 24, 72], 'default_hours': 24, 'note': _note,
    };
  }

  @override
  Future<Map<String, dynamic>> watchPosts(int groupId) async {
    _maybeFail();
    if (mode == 'empty') return {'group': groupId, 'posts': [], 'note': _note};
    return {
      'group': groupId,
      'posts': [
        {'id': 31, 'group': groupId, 'caption': _bn ? 'সন্দেহজনক মোটরসাইকেল — একটু খেয়াল রাখুন' : 'Suspicious motorbike — please keep an eye out',
         'author_id': 2, 'author_name': _bn ? 'সেলিম' : 'Selim', 'mine': false, 'image_url': 'mem://gate',
         'created': _ago, 'expires_at': _later},
        {'id': 32, 'group': groupId, 'caption': '', 'author_id': 1, 'author_name': 'Rahim', 'mine': true,
         'image_url': 'mem://till', 'created': _ago, 'expires_at': _later},
      ],
      'note': _note,
    };
  }

  @override
  Future<Map<String, dynamic>> watchShare(Map<String, dynamic> body) async {
    shares.add(body);
    return {'id': 40, ...body};
  }

  @override
  Future<void> watchDelete(int postId) async {}

  @override
  Future<Map<String, dynamic>> watchReport(int postId, String reason, {bool block = false}) async {
    reports.add('$postId:$reason:$block');
    return {'ok': true, 'hidden_for_all': false};
  }

  @override
  Future<void> watchBlock(int userId) async {}

  // ---- cctvroles: installer partners (modes: data | empty | pending | fail)
  final List<int> ended = [];
  final List<String> joined = [];

  @override
  Future<Map<String, dynamic>> installers(int siteId) async {
    _maybeFail();
    final note = _bn
        ? 'ইনস্টলার শুধু সেটআপের অবস্থা দেখেন (ক্যামেরা অনলাইন কিনা) — কখনো ভিডিও, ছবি বা সতর্কতা নয়। যেকোনো সময় বন্ধ করতে পারেন।'
        : 'An installer sees only the setup status (are the cameras online) — never video, photos or alerts. You can end it any time.';
    if (mode == 'empty') return {'site': siteId, 'links': [], 'invite_hours': 48, 'note': note};
    return {
      'site': siteId,
      'links': [
        {'id': 21, 'status': 'active', 'partner': {'name': _bn ? 'রানা সিসিটিভি' : 'Rana CCTV', 'area': _bn ? 'মিরপুর ১০' : 'Mirpur 10'},
         'created': _ago, 'expires_at': null, 'accepted_at': _ago},
        {'id': 22, 'status': 'invited', 'partner': null, 'created': _ago, 'expires_at': _later, 'accepted_at': null},
      ],
      'invite_hours': 48, 'note': note,
    };
  }

  @override
  Future<Map<String, dynamic>> makeInstallerCode(int siteId) async {
    _maybeFail();
    return {'id': 23, 'status': 'invited', 'partner': null, 'created': _ago, 'expires_at': _later,
            'accepted_at': null, 'code': 'K7MPQ2XR', 'qr': 'https://lifeassisto.com/install/K7MPQ2XR'};
  }

  @override
  Future<Map<String, dynamic>> endInstaller(int linkId) async {
    ended.add(linkId);
    return {'id': linkId, 'status': 'ended'};
  }

  @override
  Future<Map<String, dynamic>> partnerMe() async {
    _maybeFail();
    final note = _bn ? 'আপনি শুধু সেটআপের অবস্থা দেখেন — কোনো ভিডিও, ছবি বা সতর্কতা কখনো নয়।'
        : 'You see only the setup status — never any video, photo or alert.';
    if (mode == 'empty') return {'partner': null, 'sites': [], 'note': note};
    final p = {'status': mode == 'pending' ? 'pending' : 'approved',
               'name': _bn ? 'রানা সিসিটিভি' : 'Rana CCTV', 'area': _bn ? 'মিরপুর ১০' : 'Mirpur 10', 'since': _ago};
    if (mode == 'pending') return {'partner': p, 'sites': [], 'note': note};
    Map<String, dynamic> step(String k, bool ok) => {'key': k, 'ok': ok};
    return {
      'partner': p,
      'sites': [
        {'link_id': 21, 'site': 1, 'name': _bn ? 'রহিম স্টোর' : 'Rahim Store', 'kind': 'shop', 'since': _ago,
         'paying': true, 'cameras': 4, 'online': 3, 'gateway_age_min': 2, 'done': false,
         'camera_rows': [
           {'name': _bn ? 'গেট' : 'Gate', 'online': true, 'zone': true},
           {'name': _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'online': true, 'zone': true},
           {'name': _bn ? 'গুদাম' : 'Store room', 'online': true, 'zone': false},
           {'name': _bn ? 'পেছনের দরজা' : 'Back door', 'online': false, 'zone': false},
         ],
         'steps': [step('cameras_added', true), step('cameras_online', false), step('gateway_connected', true),
                   step('hours_set', true), step('zones_set', false)]},
        {'link_id': 24, 'site': 3, 'name': _bn ? 'করিম ফার্মেসি' : 'Karim Pharmacy', 'kind': 'shop', 'since': _ago,
         'paying': false, 'cameras': 2, 'online': 2, 'gateway_age_min': 1, 'done': true,
         'camera_rows': [
           {'name': _bn ? 'কাউন্টার' : 'Counter', 'online': true, 'zone': true},
           {'name': _bn ? 'দরজা' : 'Door', 'online': true, 'zone': true},
         ],
         'steps': [step('cameras_added', true), step('cameras_online', true), step('gateway_connected', true),
                   step('hours_set', true), step('zones_set', true)]},
      ],
      'commission': {'status': 'proposal', 'approved': false},
      'note': note,
    };
  }

  @override
  Future<Map<String, dynamic>> partnerApply(String name, String area) async =>
      {'status': 'pending', 'name': name, 'area': area, 'since': _ago};

  @override
  Future<Map<String, dynamic>> partnerJoin(String code) async {
    joined.add(code);
    return {'ok': true, 'site': 1};
  }
}
