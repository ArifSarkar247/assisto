// cctvact: in-memory CCTV V3 act / report / ask / sales / automation source
// for widget tests + the screenshot gallery. Shapes mirror
// backend/core/cctv_act_views.py. Sample data only (no real people / places).
import 'package:assisto/cctvact/cctvact_source.dart';

import 'cctvx_fakes.dart';

const _bnD = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
String bnd(String s) => s.replaceAllMapped(RegExp(r'\d'), (m) => _bnD[int.parse(m[0]!)]);

Map<String, dynamic> fakeAct({bool locks = true, bool stations = true}) => {
      'site_id': 1,
      'role': 'owner',
      'live': {'path': 'webrtc', 'camera_id': 7, 'name': 'Till'},
      'play': [
        {'target': 'box', 'camera_id': null}
      ],
      'thana': {
        'has_location': stations,
        'emergency': '999',
        'stations': stations
            ? [
                {'name': 'Sample Model Thana', 'phone': '01711000000', 'distance_km': 1.2,
                 'lat': 23.81, 'lng': 90.41},
                {'name': 'Sample Police Station', 'phone': '', 'distance_km': 2.8,
                 'lat': 23.82, 'lng': 90.42},
              ]
            : [],
      },
      'wrong': {
        'wrong': 1, 'correct': 0, 'factor': 1.0, 'quiet': false,
        'note_bn': 'ধন্যবাদ — আরও কয়েকবার বললে Assisto এই ধরনের ভুল কমাবে।',
        'note_en': 'Thanks — after a few more answers like this Assisto will send fewer of these.',
      },
      if (locks) 'lock_pending': [
        {'id': 'p1', 'name': 'Shutter lock'}
      ],
      'auto': [
        {'device': 'Front light', 'kind': 'plug', 'state': 'on'},
        {'device': 'Shutter lock', 'kind': 'lock', 'state': 'asked'},
      ],
    };

Map<String, dynamic> actEventActions({bool locks = true}) {
  final base = Map<String, dynamic>.from(kFakeEventActions);
  base['actions'] = {
    ...Map<String, dynamic>.from(kFakeEventActions['actions'] as Map),
    'act': fakeAct(locks: locks),
  };
  return base;
}

Map<String, dynamic> fakeReport(String lang) {
  final bn = lang != 'en';
  final hourly = List<int>.filled(24, 0);
  hourly[10] = 6;
  hourly[11] = 12;
  hourly[13] = 9;
  hourly[18] = 30;
  hourly[19] = 25;
  return {
    'site': 1,
    'date': '2026-11-09',
    'title': bn ? 'আজকের হিসাব — রহিম স্টোর (${bnd('2026-11-09')})' : "Today's report — Rahim Store (2026-11-09)",
    'lines': bn
        ? [
            'খুলেছে ${bnd('09:40')} — নির্ধারিত সময়ের ${bnd('40')} মিনিট পরে',
            'শেষ নড়াচড়া ${bnd('20:30')} — নির্ধারিত বন্ধের ${bnd('30')} মিনিট আগে',
            'মানুষ এসেছেন প্রায় ${bnd('82')} জন (পরিচয় ছাড়া গোনা); সবচেয়ে ব্যস্ত: সন্ধ্যা ${bnd('6')}টা, রাত ${bnd('7')}টা',
            'খোলা সময়ে কাউন্টার খালি ছিল ${bnd('1')} ঘণ্টা ${bnd('35')} মিনিট',
            'সতর্কতা ${bnd('3')} টি (ভুল বলে চিহ্নিত ${bnd('1')})',
            'দেখার জন্য ${bnd('1')} টি ক্যাশ-ক্লিপ (অভিযোগ নয়)',
            'বিক্রি ${bnd('41')} টি, মোট ৳${bnd('18250')}',
            'টিল: ${bnd('35')} মিনিট বন্ধ ছিল',
          ]
        : [
            'Opened 09:40 — 40 min after the set time',
            'Last movement 20:30 — 30 min before the set closing',
            'About 82 people came in (counted, no identity); busiest: 6 pm, 7 pm',
            'Counter left empty for 1 h 35 min while open',
            '3 alerts (1 marked wrong)',
            '1 cash clips to review (not accusations)',
            '41 sales, total Tk 18250',
            'Till: offline for 35 min',
          ],
    'sections': {
      'people': {'visitors': 82, 'peak_hours': [18, 19], 'hourly': hourly},
      'alerts': {'total': 3, 'wrong': 1},
    },
    'all_ok': false,
    'cfg': {'use': 'cafe', 'push': true,
            'uses': ['shop', 'cafe', 'parking', 'office', 'warehouse', 'home', 'gate']},
    'measured': {'counter': true, 'vehicles': false, 'tables': false},
    'privacy': bn ? 'মানুষ গোনা হয় পরিচয় ছাড়া — মুখ চেনা নেই।'
        : 'People are counted with no identity — no face recognition.',
  };
}

Map<String, dynamic> fakeAsk(String lang) {
  final bn = lang != 'en';
  return {
    'q': bn ? '২টা থেকে ৩টার মধ্যে ক্যাশে কে গিয়েছিল?' : 'Who went to the cash between 2 and 3 pm?',
    'filter': {'date': '2026-11-09', 'from_min': 840, 'to_min': 900, 'zone': 'cash', 'kind': 'person'},
    'answer': bn
        ? ['${bnd('2')} টি ঘটনা পাওয়া গেছে — প্রথম ${bnd('14:05')}, শেষ ${bnd('14:41')}।',
           'কারা ছিলেন তা Assisto বলে না (মুখ চেনা নেই) — ক্লিপ দেখে নিজে দেখুন।']
        : ['Found 2 events — first 14:05, last 14:41.',
           'Assisto does not say who it was (no face recognition) — watch the clips.'],
    'results': [
      {'event_id': 301, 'hhmm': '14:41', 'camera_name': bn ? 'টিল' : 'Till',
       'what': bn ? 'ক্যাশে হাত' : 'Hand in the cash zone', 'has_clip': true},
      {'event_id': 300, 'hhmm': '14:05', 'camera_name': bn ? 'টিল' : 'Till',
       'what': bn ? 'ক্যাশে হাত' : 'Hand in the cash zone', 'has_clip': false},
    ],
    'total': 2,
    'used_ai': false,
    'privacy': bn ? 'মুখ চেনা নেই, পরিচয় নেই — শুধু সময়, জায়গা, রং আর ধরন দিয়ে খোঁজা।'
        : 'No face recognition, no identity — searched by time, place, colour and type only.',
  };
}

Map<String, dynamic> fakeSales(String lang, {bool empty = false}) {
  final bn = lang != 'en';
  return {
    'site': 1,
    'date': '2026-11-09',
    'items': empty
        ? []
        : [
            {'kind': 'drawer_no_sale', 'event_id': 310, 'has_clip': true, 'time': '15:12',
             'text': bn ? '${bnd('15:12')}-এ ক্যাশ ড্রয়ার খোলা — আশেপাশে কোনো বিক্রি/খাতা নেই'
                 : 'Cash drawer opened at 15:12 — no sale or khata entry nearby'},
            {'kind': 'after_sale_check', 'event_id': 311, 'has_clip': true, 'time': '16:40',
             'text': bn ? '${bnd('16:40')}-এ বিক্রির ${bnd('30')} সেকেন্ড পর ক্যাশের কাছে হাতের নড়াচড়া'
                 : 'Hand movement near the cash 30 s after a sale at 16:40'},
          ],
    'feeds': ['asalify', 'assisto'],
    'note': bn
        ? 'শুধু দেখার জন্য — এটা কোনো অভিযোগ নয়; স্বাভাবিক কারণও থাকতে পারে (খুচরা দেওয়া, ড্রয়ার গোছানো)। নিজে ক্লিপ দেখে সিদ্ধান্ত নিন।'
        : 'For review only — this is not an accusation; there may be a normal reason (giving change, tidying the drawer). Watch the clip and decide yourself.',
    'pos_key': !empty,
  };
}

Map<String, dynamic> fakeKey({bool has = true}) => {
      'site': 1, 'has_key': has, 'key_id': has ? 'ak_1_ab12cd34ef' : null,
      'partner': has ? 'asalify' : null, 'events': has ? 128 : 0,
      'url': 'https://lifeassisto.com/api/v1/shop/pos/webhook',
    };

Map<String, dynamic> fakeAuto({bool linked = true, String lang = 'en'}) => {
      'site': 1,
      'linked': linked,
      'mode': linked ? 'own' : null,
      'service_on': false,
      'devices': linked
          ? [
              {'id': 'plug1', 'name': lang == 'en' ? 'Front light' : 'সামনের লাইট', 'kind': 'plug',
               'online': true},
              {'id': 'siren1', 'name': lang == 'en' ? 'Shop siren' : 'দোকানের সাইরেন', 'kind': 'siren',
               'online': true},
              {'id': 'lock1', 'name': lang == 'en' ? 'Shutter lock' : 'শাটারের লক', 'kind': 'lock',
               'online': false},
            ]
          : [],
      'rules': linked
          ? [
              {'id': 'r1', 'trigger': 'night_intrusion', 'on': true,
               'window': {'start': '22:00', 'end': '06:00'},
               'actions': [
                 {'device_id': 'plug1', 'kind': 'plug', 'seconds': 120},
                 {'device_id': 'lock1', 'kind': 'lock', 'seconds': 120},
               ],
               'warn': true, 'siren_box': false},
            ]
          : [],
      'log': [],
      'pending': [],
      'has_warn': true,
      'play_targets': 1,
      'lock_note': '',
    };

class FakeCctvAct implements CctvActSource {
  final List<String> calls = [];
  final String lang;
  FakeCctvAct({this.lang = 'en'});

  @override
  Future<Map<String, dynamic>> setLocation(int siteId, double lat, double lon) async {
    calls.add('loc:$siteId');
    return {'state': 'ok', 'stations': fakeAct()['thana']['stations'], 'emergency': '999'};
  }

  @override
  Future<Map<String, dynamic>> thana(int siteId, {bool refresh = false}) async =>
      {'state': 'ok', 'stations': fakeAct()['thana']['stations'], 'emergency': '999'};

  @override
  Future<Map<String, dynamic>> play(int eventId, String sound, {int? cameraId}) async {
    calls.add('play:$eventId:$sound');
    return {'ok': true, 'queued': 1, 'status': 'queued'};
  }

  @override
  Future<Map<String, dynamic>> markWrong(int eventId, String reason) async {
    calls.add('wrong:$eventId:$reason');
    return {'ok': true, 'status': 'false_alarm'};
  }

  @override
  Future<Map<String, dynamic>> automations(int siteId, {bool refresh = false}) async {
    calls.add('auto:$siteId');
    return fakeAuto();
  }

  @override
  Future<Map<String, dynamic>> saveRules(int siteId, List<Map<String, dynamic>> rules) async {
    calls.add('rules:${rules.length}');
    return {...fakeAuto(), 'rules': rules};
  }

  @override
  Future<Map<String, dynamic>> link(int siteId, Map<String, dynamic> body) async {
    calls.add('link:${body['mode']}:${body['uid']}');
    return fakeAuto();
  }

  @override
  Future<Map<String, dynamic>> unlink(int siteId) async {
    calls.add('unlink');
    return fakeAuto(linked: false);
  }

  @override
  Future<Map<String, dynamic>> testDevice(int siteId, String deviceId) async {
    calls.add('test:$deviceId');
    return {'ok': true, 'seconds': 10};
  }

  @override
  Future<Map<String, dynamic>> lock(int siteId, String pendingId) async {
    calls.add('lock:$pendingId');
    return {'ok': true, 'locked': true};
  }

  @override
  Future<Map<String, dynamic>> closingReport(int siteId, {String? date}) async {
    calls.add('report');
    return fakeReport(lang);
  }

  @override
  Future<Map<String, dynamic>> saveReportCfg(int siteId, Map<String, dynamic> body) async {
    calls.add('cfg:${body.keys.join(',')}');
    return {...fakeReport(lang)['cfg'] as Map<String, dynamic>, ...body};
  }

  @override
  Future<Map<String, dynamic>> posKey(int siteId) async => fakeKey();

  @override
  Future<Map<String, dynamic>> createPosKey(int siteId, String partner) async {
    calls.add('key:$partner');
    return {...fakeKey(), 'secret': 'ask_sample_secret_only_for_tests', 'secret_once': true};
  }

  @override
  Future<Map<String, dynamic>> revokePosKey(int siteId) async {
    calls.add('revoke');
    return fakeKey(has: false);
  }

  @override
  Future<Map<String, dynamic>> importCsv(int siteId, String csv) async {
    calls.add('csv:${csv.length}');
    return {'ok': true, 'accepted': 2, 'duplicates': 0, 'error_count': 0, 'errors': []};
  }

  @override
  Future<Map<String, dynamic>> salesMatch(int siteId, {String? date}) async {
    calls.add('sales');
    return fakeSales(lang);
  }

  @override
  Future<Map<String, dynamic>> ask(int siteId, String q) async {
    calls.add('ask:$q');
    return fakeAsk(lang);
  }
}
