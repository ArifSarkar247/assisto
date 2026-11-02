// cctvescalate: in-memory escalate source + alert actions with the 999 card
// and the camera table, for widget tests + the screenshot gallery. Shapes
// mirror backend/core/cctv_escalate_views.py.
import 'dart:typed_data';

import 'package:assisto/cctvx/escalate_source.dart';

import 'cctvx_fakes.dart';

class FakeEscalate implements EscalateSource {
  final List<String> calls = [];
  bool hasClip;
  FakeEscalate({this.hasClip = false});

  @override
  Future<Map<String, dynamic>> deter(int eventId, String feature,
      {int? cameraId, int? seconds}) async {
    calls.add('deter:$eventId:$feature:$cameraId');
    return {'ok': true, 'feature': feature, 'status': feature == 'light' ? 'on' : 'playing'};
  }

  Map<String, dynamic> _clip() => {
        'site': 1, 'has_clip': hasClip, 'seconds': hasClip ? 6.2 : null, 'max_seconds': 20,
        'lines': const [
          'সতর্কতা! এই জায়গা ক্যামেরায় রেকর্ড হচ্ছে। মালিককে জানানো হয়েছে। এখনই চলে যান।',
          'আপনাকে ক্যামেরায় দেখা যাচ্ছে। বাড়ির লোক ও প্রতিবেশীদের জানানো হয়েছে।',
          'দোকান বন্ধ। ভেতরে ঢোকা নিষেধ। ক্যামেরা চালু আছে।',
        ],
      };

  @override
  Future<Map<String, dynamic>> warnClip(int siteId) async {
    calls.add('clip:$siteId');
    return _clip();
  }

  @override
  Future<Map<String, dynamic>> saveWarnClip(int siteId, Uint8List wav) async {
    calls.add('save_clip:$siteId:${wav.length}');
    hasClip = true;
    return _clip();
  }

  @override
  Future<Map<String, dynamic>> deleteWarnClip(int siteId) async {
    calls.add('delete_clip:$siteId');
    hasClip = false;
    return _clip();
  }

  @override
  Future<Map<String, dynamic>> cameraTable(int cameraId, {bool refresh = false}) async {
    calls.add('table:$cameraId');
    return {'camera': cameraId, 'table': kFakeDeter['table_en']};
  }
}

const _tableBn = [
  {'feature': 'siren', 'supported': true, 'route': 'imou_cloud', 'reason': null, 'text': null},
  {'feature': 'light', 'supported': true, 'route': 'imou_cloud', 'reason': null, 'text': null},
  {'feature': 'voice', 'supported': false, 'route': null, 'reason': 'voice_no_api',
   'text': 'এই ব্র্যান্ডের খোলা প্ল্যাটফর্মে ক্যামেরার স্পিকারে বার্তা বাজানোর অফিসিয়াল উপায় নেই — এই ক্যামেরায় নেই।'},
  {'feature': 'talk', 'supported': false, 'route': null, 'reason': 'talk_sdk',
   'text': 'দুই দিকে কথা Imou / EZVIZ শুধু তাদের নিজস্ব অ্যাপের ভেতরের SDK-তে দেয় — Assisto-তে এখনো নেই। এখন ক্যামেরার নিজের অ্যাপ থেকে কথা বলুন।'},
];
const _tableEn = [
  {'feature': 'siren', 'supported': true, 'route': 'imou_cloud', 'reason': null, 'text': null},
  {'feature': 'light', 'supported': true, 'route': 'imou_cloud', 'reason': null, 'text': null},
  {'feature': 'voice', 'supported': false, 'route': null, 'reason': 'voice_no_api',
   'text': "This brand's open platform has no official way to play a message on the camera's speaker — not on this camera."},
  {'feature': 'talk', 'supported': false, 'route': null, 'reason': 'talk_sdk',
   'text': 'Imou / EZVIZ give two-way talk only inside their own app SDK — not in Assisto yet. Use the camera\'s own app to talk for now.'},
];

const Map<String, dynamic> kFakeDeter = {
  'camera_id': 11, 'site_id': 1, 'allowed': true, 'warn_clip': false, 'light_seconds': 30,
  'table_bn': _tableBn, 'table_en': _tableEn,
};

/// An EZVIZ camera with a speaker: the recorded warning is available.
const Map<String, dynamic> kFakeDeterEzviz = {
  'camera_id': 12, 'site_id': 1, 'allowed': true, 'warn_clip': true, 'light_seconds': 30,
  'table_bn': [
    {'feature': 'siren', 'supported': false, 'reason': 'ezviz_no_api',
     'text': 'EZVIZ-এর খোলা প্ল্যাটফর্মে সাইরেন বাজানোর কোনো অফিসিয়াল উপায় নেই — EZVIZ অ্যাপ থেকে বাজান।'},
    {'feature': 'light', 'supported': false, 'reason': 'light_no_api',
     'text': 'এই ব্র্যান্ডে দূর থেকে আলো জ্বালানোর অফিসিয়াল উপায় নেই — এই ক্যামেরায় নেই।'},
    {'feature': 'voice', 'supported': true, 'route': 'ezviz_cloud'},
    {'feature': 'talk', 'supported': false, 'reason': 'talk_sdk', 'text': 'এখনো নেই'},
  ],
  'table_en': [
    {'feature': 'siren', 'supported': false, 'reason': 'ezviz_no_api',
     'text': "EZVIZ's open platform has no official way to sound the siren — use the EZVIZ app."},
    {'feature': 'light', 'supported': false, 'reason': 'light_no_api',
     'text': 'This brand has no official way to switch the light on remotely — not on this camera.'},
    {'feature': 'voice', 'supported': true, 'route': 'ezviz_cloud'},
    {'feature': 'talk', 'supported': false, 'reason': 'talk_sdk', 'text': 'Not yet'},
  ],
};

const Map<String, dynamic> kFakePolice = {
  'number': '999', 'auto': false, 'address': 'House 12, Road 3, Mirpur 10, Dhaka',
  'address_missing': false,
  'card_bn': 'সিসিটিভি সতর্কতা — সাহায্য দরকার\nজায়গা: রহিম স্টোর\nঠিকানা: বাড়ি ১২, রোড ৩, মিরপুর ১০, ঢাকা\nসময়: ০৩/১১/২০২৬ ০২:১০\nক্যামেরা: দরজা\nসতর্কতা নং: ২০১ (Assisto)\nAssisto অ্যাপ থেকে মালিক / পরিবার পাঠিয়েছেন।',
  'card_en': 'CCTV alert — please help\nPlace: Rahim Store\nAddress: House 12, Road 3, Mirpur 10, Dhaka\nTime: 03/11/2026 02:10\nCamera: Door\nAlert no.: 201 (Assisto)\nSent by the owner / family from the Assisto app.',
  'note_bn': '', 'note_en': '', 'snapshot_url': '',
};

Map<String, dynamic> escalateActions(
    {Map<String, dynamic> deter = kFakeDeter, Map<String, dynamic> police = kFakePolice}) {
  final base = Map<String, dynamic>.from(kFakeEventActions);
  base['actions'] = {
    ...Map<String, dynamic>.from(kFakeEventActions['actions'] as Map),
    'police': police,
    'deter': deter,
  };
  return base;
}
