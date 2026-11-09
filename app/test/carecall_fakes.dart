// carecall: a fake Care Call server for widget tests + the gallery.
import 'package:assisto/carecall/carecall_api.dart';
import 'package:assisto/train/dest_alarm_sound.dart';

class FakeCareCallApi implements CareCallApi {
  FakeCareCallApi({Map<String, dynamic>? mine, this.peopleRows = const [], this.offline = false})
      : _mine = mine ?? ccMine('en');

  final Map<String, dynamic> _mine;
  final List<Map<String, dynamic>> peopleRows;
  bool offline;
  final List<Map<String, dynamic>> created = [];
  final List<List<Map<String, dynamic>>> ackBatches = [];
  final List<(int, bool)> consents = [];

  void _net() {
    if (offline) throw Exception('offline');
  }

  @override
  Future<Map<String, dynamic>> mine() async {
    _net();
    return _mine;
  }

  @override
  Future<List<Map<String, dynamic>>> people() async => peopleRows;

  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    _net();
    created.add(body);
    return {'ok': true, 'link': 'accepted', 'care_call': {...body, 'id': created.length, 'link': 'accepted'}};
  }

  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body) async {
    _net();
    return {'ok': true, 'care_call': {...body, 'id': id}};
  }

  @override
  Future<void> delete(int id) async => _net();

  @override
  Future<Map<String, dynamic>> consent(int setterId, bool accept) async {
    _net();
    consents.add((setterId, accept));
    return {'ok': true, 'status': accept ? 'accepted' : 'stopped'};
  }

  @override
  Future<void> quiet(String start, String end) async => _net();

  @override
  Future<Map<String, dynamic>> acks(List<Map<String, dynamic>> acks) async {
    _net();
    ackBatches.add(acks);
    return {'ok': true};
  }

  @override
  Future<List<int>> voice(int id) async => const [];
}

class FakeSound implements DestAlarmSound {
  final List<String> calls = [];
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async => true;
  @override
  Future<bool> speak(String text, String lang) async {
    calls.add('speak:$text');
    return true;
  }

  @override
  Future<bool> playClip(String path) async {
    calls.add('clip:$path');
    return true;
  }

  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async => calls.add('stop');
}

bool _bn(String l) => l == 'bn';

/// The setter's screen-3 data, newest first: today's confirmed card at 9:02
/// and yesterday's amber "did not answer twice" card at 9:20 (BD time).
Map<String, dynamic> ccMine(String l, {bool location = true, bool invite = false, bool empty = false}) {
  if (empty) {
    return {'sent': [], 'received': [], 'links': [], 'invites': [], 'feed': [],
            'quiet_start': '22:00', 'quiet_end': '07:00', 'limits': {}};
  }
  final ammu = _bn(l) ? 'আম্মু' : 'Ammu';
  final text = _bn(l) ? 'গ্যাসের ট্যাবলেটটা খাও' : 'Take your gas tablet';
  return {
    'feed': [
      {'ring_id': 2, 'care_call_id': 1, 'kind': 'confirmed', 'at': '2026-11-04T03:02:00Z',
       'scheduled_at': '2026-11-04T03:00:00Z', 'receiver_id': 7, 'receiver_name': ammu,
       'receiver_initial': _bn(l) ? 'আ' : 'A', 'text': text, 'misses': 0, 'edge_id': 11,
       'can_see_location': location},
      {'ring_id': 1, 'care_call_id': 1, 'kind': 'missed', 'at': '2026-11-03T03:20:00Z',
       'scheduled_at': '2026-11-03T03:00:00Z', 'receiver_id': 7, 'receiver_name': ammu,
       'receiver_initial': _bn(l) ? 'আ' : 'A', 'text': text, 'misses': 2, 'edge_id': 11,
       'can_see_location': location},
    ],
    'sent': [
      {'id': 1, 'text': text, 'time': '09:00', 'repeat': 'daily', 'days': [], 'date': '',
       'active': true, 'has_voice': true, 'voice_rev': 1, 'voice_sec': 7, 'setter_id': 3,
       'receiver_id': 7, 'other_name': ammu, 'other_initial': _bn(l) ? 'আ' : 'A',
       'link': 'accepted', 'quiet_start': '22:00', 'quiet_end': '07:00'},
    ],
    'received': [],
    'links': [
      if (invite) {'setter_id': 9, 'name': _bn(l) ? 'রিনা' : 'Rina', 'initial': _bn(l) ? 'রি' : 'R', 'status': 'pending'},
    ],
    'invites': [
      if (invite) {'setter_id': 9, 'name': _bn(l) ? 'রিনা' : 'Rina', 'initial': _bn(l) ? 'রি' : 'R', 'status': 'pending'},
    ],
    'quiet_start': '22:00',
    'quiet_end': '07:00',
    'limits': {'active_per_setter': 10, 'active_used': 1, 'voice_max_seconds': 30,
               'text_max_chars': 300, 'retry_min': 10, 'snooze_min': 10},
  };
}

/// The receiver's ring payload (SCREEN 2).
Map<String, String> ccRing(String l) => {
      'kind': 'carecall', 'route': 'carecall', 'care_call_id': '1', 'slot': '202611040900',
      'slot_key': '1-202611040900', 'attempt': '1', 'setter_id': '3',
      'setter_name': _bn(l) ? 'আরিফ' : 'Arif', 'setter_initial': _bn(l) ? 'আ' : 'A',
      'text': _bn(l) ? 'গ্যাসের ট্যাবলেটটা খাও' : 'Take your gas tablet', 'voice_rev': '1', 'lang': l,
    };

/// SCREEN 1's picked person.
Map<String, dynamic> ccPerson(String l) => {
      'user_id': 7, 'name': _bn(l) ? 'আম্মু' : 'Ammu', 'initial': _bn(l) ? 'আ' : 'A',
      'link': 'accepted', 'quiet_start': '22:00', 'quiet_end': '07:00',
    };
