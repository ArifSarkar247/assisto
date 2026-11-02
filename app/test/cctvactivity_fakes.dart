// cctvactivity (W10): a fake activity server for widget tests + the gallery.
// Shapes and wording mirror backend/core/cctv_activity.py (day_view,
// VisitorLogView, TimelapseView) and logic/cctv_brief.py summary_lines.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:assisto/api.dart';
import 'package:assisto/cctvx/activity_source.dart';

class FakeActivity implements ActivitySource {
  final String mode; // data | empty | fail | viewer
  final String lang;
  final List<Map<String, dynamic>> saved = [];
  final List<Map<String, String?>> confirms = [];
  final List<String> queries = [];
  int loads = 0;
  bool confirmed = false;
  FakeActivity(this.mode, {this.lang = 'en'});

  bool get _bn => lang == 'bn';

  Map<String, dynamic> _settings() => {
        'brief_on': true,
        'brief_hour': 8,
        'shop_cams': <int>[],
        'wm_on': mode == 'data',
        'wm_start': '22:00',
        'wm_end': '06:00',
        'wm_cams': [5],
        'foot_dir': 'both',
        'ai_desc': true,
        'cameras': [
          {'id': 5, 'name': 'Gate'},
          {'id': 6, 'name': 'Counter'},
        ],
        'ai': {'ready': false, 'cap': 100, 'used': 0, 'note': ''},
      };

  @override
  Future<Map<String, dynamic>> day(int siteId, {String? date}) async {
    loads++;
    if (mode == 'fail') throw ApiException('Error 500', 500);
    final empty = mode == 'empty';
    final rows = empty
        ? <Map<String, dynamic>>[]
        : [
            {'hour': 10, 'visitors': 12, 'sales': 4, 'amount': 2350.0, 'conversion': 33.3},
            {'hour': 11, 'visitors': 7, 'sales': 2, 'amount': 900.0, 'conversion': 28.6},
            {'hour': 18, 'visitors': 18, 'sales': 6, 'amount': 4100.0, 'conversion': 33.3},
            {'hour': 19, 'visitors': 9, 'sales': 1, 'amount': 300.0, 'conversion': 11.1},
          ];
    return {
      'site': siteId,
      'date': date,
      'today': true,
      'foot': empty
          ? {'rows': [], 'visitors': 0, 'sales': 0, 'amount': 0, 'conversion': null, 'peak_hours': []}
          : {
              'rows': rows,
              'visitors': 46,
              'sales': 13,
              'amount': 7650.0,
              'conversion': 28.3,
              'peak_hours': [10, 18, 19]
            },
      'foot_src': empty ? 'none' : 'estimate',
      'open_close': empty
          ? {'open': null, 'close': null, 'confirmed': false}
          : {
              'open': confirmed ? '09:00' : '09:12',
              'close': '21:40',
              'camera_open': '09:12',
              'camera_close': '21:40',
              'last_seen': '21:40',
              'confirmed': confirmed
            },
      'watchman': {
        'on': mode == 'data',
        'totals': {'ok': 6, 'miss': 1, 'unknown': 1},
        'hours': [
          {'hour': 22, 'result': 'ok'},
          {'hour': 23, 'result': 'ok'},
          {'hour': 0, 'result': 'miss'},
          {'hour': 1, 'result': 'unknown'},
        ]
      },
      'health': [
        {'camera': 5, 'name': 'Gate', 'offline_min': 12, 'sd': 'ok', 'last_photo': '21:30'},
        {'camera': 6, 'name': 'Counter', 'offline_min': 0, 'sd': 'unknown', 'last_photo': null},
      ],
      'alerts': empty ? 0 : 3,
      'lines': empty
          ? [_bn ? 'আগন্তুক: ক্যামেরা কোনো মানুষ-ঘটনা পাঠায়নি।' : 'Visitors: the cameras sent no person events.']
          : _bn
              ? [
                  'আগন্তুক: ৪৬জন (আনুমানিক); ভিড়ের সময় ১০:০০–১১:০০, ১৮:০০–১৯:০০।',
                  'বিক্রি: ১৩টি (৳৭৬৫০) — কনভার্সন ২৮.৩%।',
                  'দোকান খুলেছে ০৯:১২, বন্ধ ২১:৪০ (ক্যামেরা দেখে — নিশ্চিত করুন)।',
                  'পাহারাদার: ৬ ঘণ্টা দেখা গেছে, ১ ঘণ্টা দেখা যায়নি, ১ ঘণ্টা ক্যামেরা বন্ধ ছিল।',
                  'সতর্কতা: ৩টি।',
                ]
              : [
                  'Visitors: 46 (estimate); busiest 10:00–11:00, 18:00–19:00.',
                  'Sales: 13 (Tk 7650) — conversion 28.3%.',
                  'Opened 09:12, closed 21:40 (from the camera — please confirm).',
                  'Watchman: seen 6 h, not seen 1 h, 1 h cameras offline.',
                  'Alerts: 3.',
                ],
      'role': mode == 'viewer' ? 'viewer' : 'owner',
      if (mode != 'viewer') 'settings': _settings(),
    };
  }

  @override
  Future<Map<String, dynamic>> saveSettings(int siteId, Map<String, dynamic> body) async {
    saved.add(body);
    return {..._settings(), ...body};
  }

  @override
  Future<Map<String, dynamic>> confirm(int siteId, String date, {String? open, String? close}) async {
    confirms.add({'date': date, 'open': open, 'close': close});
    confirmed = true;
    return {'date': date, 'confirmed': {'open': open, 'close': close}};
  }

  static final _rows = [
    {
      'id': 41,
      'type': 'person_detected',
      'time': '19:05',
      'date': '2026-11-02',
      'camera_name': 'Gate',
      'snapshot_url': '',
      'desc_bn': 'একজন মানুষ দেখা গেছে — Gate (গেট), ১৯:০৫',
      'desc_en': 'A person was seen — Gate (gate), 19:05',
      'desc_src': 'template'
    },
    {
      'id': 42,
      'type': 'line_crossing',
      'time': '18:20',
      'date': '2026-11-02',
      'camera_name': 'Counter',
      'snapshot_url': '',
      'desc_bn': 'দুজন মানুষ, একজনের লাল শার্ট, দরজা দিয়ে ঢুকছেন',
      'desc_en': 'Two people, one in a red shirt, coming in through the door',
      'desc_src': 'ai'
    },
  ];

  @override
  Future<Map<String, dynamic>> visitors(int siteId,
      {String? date, int days = 1, String q = '', String? from, String? to}) async {
    queries.add('$q|$from|$to|$days');
    if (mode == 'fail') throw ApiException('Error 500', 500);
    final rows = mode == 'empty'
        ? <Map<String, dynamic>>[]
        : _rows
            .where((r) =>
                q.isEmpty ||
                '${r['desc_bn']} ${r['desc_en']} ${r['camera_name']}'.toLowerCase().contains(q.toLowerCase()))
            .map((r) => {...r, 'desc': _bn ? r['desc_bn'] : r['desc_en']})
            .toList();
    return {
      'rows': rows,
      'more': false,
      'ai_ready': false,
      'label': _bn
          ? 'বর্ণনা: AI (চাবি ও মাসিক সীমা থাকলে) নয়তো ধরন-সময় থেকে স্বয়ংক্রিয় লেখা। মুখ চেনা হয় না।'
          : 'Descriptions: AI (when a key and the monthly limit allow), else automatic text from type and time. No face recognition.',
    };
  }

  @override
  Future<Map<String, dynamic>> timelapse(int siteId, {String? date, int? cameraId}) async {
    if (mode == 'fail') throw ApiException('Error 500', 500);
    final n = mode == 'empty' ? 0 : 24;
    return {
      'frames': [
        for (var i = 0; i < n; i++)
          {'url': 'https://x.test/$i.jpg', 'time': '${(8 + i ~/ 2).toString().padLeft(2, '0')}:${i.isEven ? '00' : '30'}'}
      ],
      'plan': {'frames': n, 'delay_cs': n == 0 ? 0 : 125, 'seconds': n == 0 ? 0 : 30.0},
      'server_video': false,
    };
  }

  @override
  Future<Uint8List> download(String url) async => testJpeg(int.tryParse(url.split('/').last.split('.').first) ?? 0);
}

/// A small real JPEG (a gradient that shifts with [i]).
Uint8List testJpeg(int i, {int w = 160, int h = 90}) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 255 ~/ w + i * 10) % 256, (y * 255 ~/ h) % 256, (i * 40) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}
