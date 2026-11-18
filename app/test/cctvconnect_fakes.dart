// cctvconnect: a fake brand-cloud / DVR-health source for widget tests and
// the screenshot gallery (synthetic data only — no real serials or people).
import 'package:assisto/api.dart';
import 'package:assisto/cctvconnect/cctv_connect_source.dart';

class FakeCctvConnect implements CctvConnectSource {
  final String lang;
  bool noProviders;
  bool noLinks;
  String healthStatus;
  // imou-real: the server's "remove it from the vendor app first" ids + an
  // approved no-delete path leading (off by default: older tests unchanged)
  bool guides;
  bool leadImou;
  ApiException? linkError;
  final List<String> calls = [];

  FakeCctvConnect(
      {this.lang = 'en',
      this.noProviders = false,
      this.noLinks = false,
      this.healthStatus = 'green',
      this.guides = false,
      this.leadImou = false});

  bool get _bn => lang == 'bn';

  @override
  Future<Map<String, dynamic>> providers(int siteId) async {
    calls.add('providers:$siteId');
    Map<String, dynamic> p(String id, String name) => {
          'id': id,
          'name': name,
          'modes': id == 'imou' ? ['device_code', 'oauth'] : ['device_code'],
          'code_label_bn': 'লেবেলের ৬ অক্ষরের Verification Code',
          'code_label_en': '6-letter Verification Code on the label',
          'consent_bn': 'আমি এই ক্যামেরার মালিক এবং এটি Assisto-র অ্যাকাউন্টে যুক্ত করতে রাজি; যেকোনো সময় সরাতে পারব।',
          'consent_en': "I own this camera and agree to link it to Assisto's account; I can unlink it any time.",
          if (guides)
            'before': const {'imou': 'imou_life', 'ezviz': 'ezviz_app', 'dolynk': 'dmss'}[id] ?? '',
          if (leadImou && id == 'imou') 'lead': true,
        };
    return {
      'providers': noProviders
          ? []
          : [
              p('hikconnect', 'Hikvision Hik-Connect'),
              p('dolynk', 'Dahua DoLynk'),
              p('ezviz', 'EZVIZ'),
              p('imou', 'Imou'),
            ],
      'links': noLinks
          ? []
          : [
              {'id': 5, 'provider': 'hikconnect', 'name': 'Hikvision Hik-Connect', 'status': 'active',
               'devices': 1, 'serials': ['SIMHKDVR0001']},
              {'id': 6, 'provider': 'imou', 'name': 'Imou', 'status': 'active', 'mode': 'oauth',
               'devices': 2, 'auth_days_left': 89, 'serials': ['SIMIMOUSER1']},
            ],
      'local_ok': true,
    };
  }

  @override
  Future<Map<String, dynamic>> link(String provider, int siteId, String serial, String code,
      {bool consent = false}) async {
    calls.add('link:$provider:$siteId:$serial:$code${consent ? ':consent' : ''}');
    final e = linkError;
    if (e != null) throw e;
    return {
      'link': {'id': 9, 'provider': provider, 'name': 'EZVIZ', 'status': 'active', 'devices': 1},
      'devices': [],
    };
  }

  @override
  Future<Map<String, dynamic>> oauthStart(String provider, int siteId) async {
    calls.add('oauth:$provider:$siteId');
    return {'url': 'https://api.example.test/api/v1/cctv/connect/oauth/go?state=s1'};
  }

  @override
  Future<Map<String, dynamic>> devices(int linkId) async {
    calls.add('devices:$linkId');
    return {
      'link': {'id': linkId},
      'devices': [
        {
          'serial': 'SIMHKDVR0001',
          'name': _bn ? 'দোকানের DVR' : 'Shop DVR',
          'model': 'DS-7604',
          'online': true,
          'kind': 'nvr',
          'channels': [
            {'no': 1, 'name': _bn ? 'গেট' : 'Gate', 'online': true, 'added': true},
            {'no': 2, 'name': _bn ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'online': true, 'added': false},
            {'no': 3, 'name': '', 'online': true, 'added': false},
            {'no': 4, 'name': '', 'online': false, 'added': false},
          ],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> importChannels(int linkId, List<Map<String, dynamic>> items) async {
    calls.add('import:$linkId:${items.length}');
    return {'added': items, 'skipped': [], 'message': ''};
  }

  @override
  Future<void> revoke(int linkId) async {
    calls.add('revoke:$linkId');
  }

  @override
  Future<Map<String, dynamic>> health(int siteId) async {
    calls.add('health:$siteId');
    final red = healthStatus == 'red';
    return {
      'status': healthStatus,
      'title': red
          ? (_bn ? '২ টি সমস্যা — নিচে কী করবেন দেখুন' : '2 problems — see what to do below')
          : (_bn
              ? 'সব ঠিক আছে — রেকর্ডিং চলছে, ডিস্ক ভালো, সব ক্যামেরা অনলাইনে'
              : 'All good — recording, disk healthy, every camera online'),
      'lines': red
          ? [
              {'kind': 'hdd_fail', 'sev': 'red',
               'what': _bn ? 'DVR-এর হার্ডডিস্কে সমস্যা — ভিডিও রেকর্ড হচ্ছে না হতে পারে'
                   : 'The DVR hard disk has a problem — video may not be recording',
               'fix': _bn ? 'টেকনিশিয়ান ডেকে হার্ডডিস্ক পরীক্ষা / বদলান। ততক্ষণ ক্লাউড ক্লিপ চালু রাখুন।'
                   : 'Ask a technician to test / replace the disk. Keep cloud clips on meanwhile.'},
              {'kind': 'cam_offline', 'sev': 'red',
               'what': _bn ? 'ক্যামেরা ৪ — ক্যামেরা বন্ধ / সংযোগ নেই (ভিডিও আসছে না)'
                   : 'Camera 4 — Camera is off / not connected (no video)',
               'fix': _bn ? 'ক্যামেরার তার, অ্যাডাপ্টার ও বিদ্যুৎ দেখুন।'
                   : 'Check the camera cable, adapter and power.'},
            ]
          : [],
      'recorded_days': red ? 4 : 12,
      'target_days': 7,
      'checks': {'disk': red ? 'bad' : 'ok'},
      'devices': [
        {'device': 'SIMHKDVR0001', 'source': 'isapi', 'stale': false, 'problems': red ? 2 : 0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> setTargetDays(int siteId, int days) async {
    calls.add('target:$siteId:$days');
    return health(siteId);
  }
}
