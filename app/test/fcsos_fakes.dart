// fcsos: fakes for the SOS sender / receiver tests and gallery shots.
import 'package:assisto/family_sos/sos_api.dart';
import 'package:assisto/family_sos/sos_recorder.dart';
import 'package:assisto/train/dest_alarm_sound.dart';

bool _bn(String l) => l == 'bn';

class FakeFcSosApi implements FcSosApi {
  FakeFcSosApi({this.lang = 'en', this.failSends = 0, this.recipients = 3, Map<String, dynamic>? ev})
      : ev = ev ?? fcsEvent(lang);
  final String lang;
  int failSends;
  final int recipients;
  Map<String, dynamic> ev;
  final List<String> calls = [];
  List<Map<String, dynamic>> goingList = [];

  @override
  Future<Map<String, dynamic>> send(
      {double? lat, double? lng, required String source, required String clientId}) async {
    calls.add('send:$clientId:$lat');
    if (failSends > 0) {
      failSends--;
      throw Exception('offline');
    }
    return {'ok': true, 'recipients': recipients, 'sent': recipients};
  }

  @override
  Future<Map<String, dynamic>> resolve({required bool mistake}) async {
    calls.add(mistake ? 'resolve:mistake' : 'resolve:safe');
    return {'ok': true, 'recipients': recipients};
  }

  @override
  Future<Map<String, dynamic>> status() async =>
      {'state': 'active', 'going': goingList, 'audio': false};

  @override
  Future<Map<String, dynamic>> ladder() async => {
        'stage': 'waiting',
        'recipients': [
          {'name': _bn(lang) ? 'আম্মু' : 'Ammu', 'status': 'sent', 'received': true, 'seen': true},
          {'name': _bn(lang) ? 'ভাইয়া' : 'Bhai', 'status': 'sent', 'received': true, 'seen': false},
          {'name': _bn(lang) ? 'আব্বু' : 'Abbu', 'status': 'sent', 'received': false, 'seen': false},
        ],
        'total': 3,
        'received': 2,
        'seen': 1,
        'age_s': 40,
      };

  @override
  Future<void> location(double lat, double lng) async => calls.add('loc');

  @override
  Future<bool> uploadAudio(List<int> bytes, int sec) async {
    calls.add('audio:$sec');
    return true;
  }

  @override
  Future<Map<String, dynamic>> event(int deliveryId) async {
    calls.add('event:$deliveryId');
    return ev;
  }

  @override
  Future<List<int>> eventAudio(int deliveryId) async => [0, 0, 0, 24];

  @override
  Future<Map<String, dynamic>> going(int deliveryId) async {
    calls.add('going:$deliveryId');
    ev = {...ev, 'me_going': true, 'going': [...(ev['going'] as List), {'name': 'You', 'at': ev['sent_at'], 'me': true}]};
    return {'ok': true};
  }

  @override
  Future<void> seen(int deliveryId) async => calls.add('seen:$deliveryId');

  bool share = false;
  @override
  Future<Map<String, dynamic>> settings() async =>
      {'share_info': share, 'blood_group': 'B+', 'contacts': 2};

  @override
  Future<Map<String, dynamic>> setShareInfo(bool on) async {
    share = on;
    calls.add('share:$on');
    return settings();
  }
}

Map<String, dynamic> fcsEvent(String l, {String state = 'active', bool info = true}) {
  final now = DateTime.utc(2026, 11, 9, 4, 42);
  return {
    'id': 41,
    'kind': 'sos',
    'state': state,
    'sender': {'id': 7, 'name': _bn(l) ? 'রিনা' : 'Rina', 'phone': '01711200001'},
    'sent_at': now.subtract(const Duration(minutes: 2)).toIso8601String(),
    'server_now': now.toIso8601String(),
    'age_s': 120,
    'location': {
      'lat': 23.7461,
      'lng': 90.3742,
      'at': now.subtract(const Duration(seconds: 12)).toIso8601String(),
      'live': true
    },
    'audio_sec': 30,
    'going': [
      {'name': _bn(l) ? 'ভাইয়া' : 'Bhai', 'at': now.subtract(const Duration(minutes: 1)).toIso8601String(), 'me': false}
    ],
    'me_going': false,
    'info': info
        ? {
            'blood_group': 'B+',
            'allergies': '',
            'conditions': _bn(l) ? 'অ্যাজমা' : 'Asthma',
            'contacts': [
              {'name': _bn(l) ? 'ডা. করিম' : 'Dr Karim', 'phone': '01711999999', 'relation': ''}
            ]
          }
        : null,
    'nearby': {
      'police': [
        {'name': 'ধানমন্ডি থানা', 'name_en': 'Dhanmondi Police Station', 'phone': '01320040122', 'lat': 23.7466, 'lng': 90.3726, 'distance_m': 420}
      ],
      'hospital': [
        {'name': 'ল্যাবএইড হাসপাতাল', 'name_en': 'Labaid Hospital', 'phone': '10606', 'lat': 23.7424, 'lng': 90.3826, 'distance_m': 1100}
      ],
      'country': 'BD',
      'attribution': '© OpenStreetMap contributors (ODbL)'
    },
    'country': 'BD',
    'duress': false,
  };
}

Map<String, String> fcsPush(String l) => {
      'kind': 'sos',
      'alert_kind': 'sos',
      'delivery_id': '41',
      'from_name': _bn(l) ? 'রিনা' : 'Rina',
      'lat': '23.7461',
      'lng': '90.3742',
    };

class FakeSosRecorder implements SosRecorder {
  FakeSosRecorder({this.allowed = true});
  bool allowed;
  final List<String> calls = [];
  @override
  Future<bool> granted() async => allowed;
  @override
  Future<bool> request() async {
    calls.add('request');
    return allowed;
  }

  @override
  Future<bool> start() async {
    calls.add('start');
    return allowed;
  }

  @override
  Future<List<int>?> stop() async {
    calls.add('stop');
    return [1, 2, 3];
  }
}

class FakeAlarmSound implements DestAlarmSound {
  final List<String> calls = [];
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    calls.add('start');
    return true;
  }

  @override
  Future<bool> speak(String text, String lang) async => true;
  @override
  Future<bool> playClip(String path) async {
    calls.add('clip');
    return true;
  }

  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async => calls.add('stop');
}
