// fcelder: fakes for the Elder Easy Home / setup / Silent Watch tests + shots.
import 'package:assisto/eldercare/elder_common.dart';
import 'package:assisto/eldercare/silent_watch_api.dart';
import 'package:assisto/eldercare/silent_watch_native.dart';
import 'package:assisto/train/dest_alarm_sound.dart';

class FakeSilentWatchApi implements SilentWatchApi {
  FakeSilentWatchApi({this.statusBody, this.peopleList});

  Map<String, dynamic>? statusBody;
  List<Map<String, dynamic>>? peopleList;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> status() async {
    calls.add('status');
    return statusBody ?? {'mine': null, 'watching': [], 'family': []};
  }

  @override
  Future<Map<String, dynamic>> setConfig(Map<String, dynamic> body) async {
    calls.add('config:${body['enabled']}');
    return {'ok': true, 'config': {'enabled': body['enabled'] ?? true, 'hours': 4,
        'day_start': '07:00', 'day_end': '22:00', 'setter_name': 'Arif'}};
  }

  @override
  Future<String?> newToken() async => 'fake-test-token-bbbbbbbbbbbbbbbb';

  @override
  Future<void> ok() async => calls.add('ok');

  @override
  Future<Map<String, dynamic>> ack(int alertId) async {
    calls.add('ack:$alertId');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> test(int elderId) async {
    calls.add('test:$elderId');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> startSetup(Map<String, dynamic> body) async {
    calls.add('setup:${body['elder_user_id']}:${body['hours']}:${body['nearby_user_id']}');
    return {'ok': true, 'code': 'KQ7M2XPA', 'url': 'https://lifeassisto.com/e/KQ7M2XPA',
        'ttl_s': 900, 'elder_id': body['elder_user_id'], 'elder_name': 'Ammu',
        'plan': {'easy_home': true, 'carecall': true, 'silent_watch': true}};
  }

  @override
  Future<Map<String, dynamic>> previewSetup(String code) async {
    calls.add('preview:$code');
    return {'ok': true, 'child_name': 'Arif', 'hours': 4,
        'plan': {'easy_home': true, 'carecall': true, 'silent_watch': true}};
  }

  @override
  Future<Map<String, dynamic>> acceptSetup(String code) async {
    calls.add('accept:$code');
    return {'ok': true, 'token': 'fake-test-token-aaaaaaaaaaaaaaaa',
        'plan': {'easy_home': false, 'carecall': true, 'silent_watch': true},
        'config': {'enabled': true, 'hours': 4, 'day_start': '07:00', 'day_end': '22:00',
            'setter_name': 'Arif'}};
  }

  @override
  Future<List<Map<String, dynamic>>> people() async =>
      peopleList ??
      [
        {'user_id': 2, 'name': 'Ammu', 'relation': 'mother'},
        {'user_id': 3, 'name': 'Bina', 'relation': 'sister'},
        {'user_id': 4, 'name': 'Nabil', 'relation': 'other'},
      ];
}

class FakeSwNative implements SilentWatchNative {
  final armed = <Map<String, dynamic>>[];
  int okCount = 0, notes = 0, disarms = 0;
  int stage = 0;
  List<int> log = const [];
  List<int> told = const [];
  final away = <int>[];
  int awayUntilMs = 0;

  @override
  Future<bool> arm(Map<String, dynamic> args) async {
    armed.add(args);
    return true;
  }

  @override
  Future<bool> disarm() async {
    disarms++;
    return true;
  }

  @override
  Future<bool> noteActivity() async {
    notes++;
    return true;
  }

  @override
  Future<bool> ok() async {
    okCount++;
    stage = 0;
    return true;
  }

  @override
  Future<bool> goingOut(int minutes) async {
    away.add(minutes);
    awayUntilMs = DateTime.now().add(Duration(minutes: minutes)).millisecondsSinceEpoch;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> state() async => {
        'enabled': armed.isNotEmpty,
        'stage': stage,
        'told': false,
        'log': log,
        'told_log': told,
        'away_until_ms': awayUntilMs,
      };
}

class SpokenRecorder implements DestAlarmSound {
  final said = <String>[];
  @override
  Future<bool> speak(String text, String lang) async {
    said.add(text);
    return true;
  }

  @override
  Future<bool> start({required bool sound, required bool vibrate}) async => true;
  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async {}
}

const fceFamily = [
  ElderContact(1, 'Arif', '01711000001', 'son'),
  ElderContact(3, 'Bina', '01711000003', 'daughter'),
];

Map<String, dynamic> fceWatching({String status = 'open'}) => {
      'mine': null,
      'family': [
        {'user_id': 2, 'name': 'Ammu', 'phone': '01711000002', 'relation': 'mother'}
      ],
      'watching': [
        {
          'elder_id': 2,
          'elder_name': 'Ammu',
          'i_set_it_up': true,
          'hours': 4,
          'alert': status.isEmpty
              ? null
              : {'id': 9, 'status': status, 'kind': 'inactivity', 'step': 1, 'checking_name': 'Bina'},
        }
      ],
    };
