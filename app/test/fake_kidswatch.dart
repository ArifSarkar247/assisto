// kidswatch: gallery / FakeApi GET stubs for Kids watch + School Mode — the
// server's real response shapes (backend/core/kidswatch_views.py), so the
// screenshots show honest states (one full watch, one safety-only watch, a
// phone plan waiting for the child, the child's own screen).

Map<String, dynamic> _cfg() => {
      'enabled': true,
      'server': {'host': 'track.lifeassisto.com', 'port': 5023},
      'sms': [
        {'step': 'check', 'sms': 'pw,123456,ts#'},
        {'step': 'server', 'sms': 'pw,123456,ip,track.lifeassisto.com,5023#'},
        {'step': 'timezone', 'sms': 'pw,123456,lz,1,6#'},
        {'step': 'interval', 'sms': 'pw,123456,upload,600#'},
        {'step': 'new_password', 'sms': 'pw,123456,pw,<NEW 6 DIGITS>#'},
      ],
      'month_credits': 30,
      'pair_window_min': 30,
      'voice_days': 14,
      'retention_days': 30,
      'transcript_credits': 1,
      'free_always': ['sos', 'school_alerts', 'last_location', 'phone_checkin', 'find_watch'],
      'no_remote_listening': true,
    };

String _ago(int minutes) =>
    DateTime.now().toUtc().subtract(Duration(minutes: minutes)).toIso8601String();

Map<String, dynamic> _today(String state, {Map<String, dynamic> ask = const {}}) => {
      'state': state,
      'window': 'school',
      'paused': false,
      'ask': ask,
      'alerts': const {},
      'school_day': true,
      'arrive_due': DateTime.now().toUtc().toIso8601String(),
      'home_due': DateTime.now().toUtc().add(const Duration(hours: 6)).toIso8601String(),
    };

Map<String, dynamic>? fakeKidsWatchGet(String path, {required bool bn, required bool empty}) {
  final rina = bn ? 'রিনা' : 'Rina';
  final rafi = bn ? 'রাফি' : 'Rafi';
  final abba = bn ? 'আব্বু' : 'Dad';
  final ammu = bn ? 'আম্মু' : 'Mum';
  if (path == '/kids-watch/config') return _cfg();
  if (path == '/kids-watch/watches') {
    return {
      'month_credits': 30,
      'watches': empty
          ? const []
          : [
              {
                'id': 1, 'child_name': rina, 'code_tail': '0015', 'state': 'paired',
                'mine': true, 'maker': 'SG', 'mode': 'full', 'online': true,
                'battery': 76, 'steps': 3120, 'interval_s': 600, 'phase': 'at_school',
                'last_seen_at': _ago(2),
                'live': {'lat': 23.7808, 'lng': 90.4130, 'at': _ago(4), 'acc_m': 12,
                         'source': 'gps'},
                'school_plan_id': 5, 'code': '8800000015', 'sos_numbers': ['01711000001'],
                'guardians': [{'id': 2, 'name': ammu}], 'commands': const [],
              },
              {
                'id': 2, 'child_name': rafi, 'code_tail': '0099', 'state': 'paired',
                'mine': true, 'maker': '3G', 'mode': 'safety_only', 'online': false,
                'battery': 18, 'last_seen_at': _ago(95), 'live': null,
                'school_plan_id': null, 'code': '8800000099', 'sos_numbers': const [],
                'guardians': const [], 'commands': const [],
              },
            ],
    };
  }
  if (path == '/school-mode/plans') {
    return {
      'plans': empty
          ? const []
          : [
              {
                'id': 5, 'child_name': rina, 'enabled': true, 'accepted': true,
                'mode': 'watch', 'watch_id': 1, 'i_am_child': false, 'mine': true,
                'config': null, 'watchers': [
                  {'id': 1, 'name': abba, 'owner': true},
                  {'id': 2, 'name': ammu, 'owner': false},
                ],
                'today': _today('at_school'), 'last_known': null,
              },
              {
                'id': 6, 'child_name': rafi, 'enabled': true, 'accepted': false,
                'mode': 'phone', 'watch_id': null, 'i_am_child': false, 'mine': true,
                'config': null, 'watchers': [{'id': 1, 'name': abba, 'owner': true}],
                'today': _today('idle'), 'last_known': null,
              },
            ],
    };
  }
  if (path == '/school-mode/mine') {
    return {
      'plans': empty
          ? const []
          : [
              {
                'id': 6, 'child_name': rafi, 'enabled': true, 'accepted': true,
                'mode': 'phone', 'watch_id': null, 'i_am_child': true, 'mine': false,
                'config': null, 'watchers': [
                  {'id': 1, 'name': abba, 'owner': true},
                  {'id': 2, 'name': ammu, 'owner': false},
                ],
                'today': _today('to_school', ask: {'school': _ago(1)}), 'last_known': null,
              },
            ],
    };
  }
  if (path == '/school-mode/people') {
    return {
      'people': empty ? const [] : [
        {'id': 2, 'name': ammu, 'relation': 'mother'},
        {'id': 3, 'name': rafi, 'relation': 'son'},
      ],
    };
  }
  if (path == '/school-mode/places') {
    return {
      'places': empty ? const [] : [
        {'id': 1, 'label': bn ? 'বাসা' : 'Home', 'name': '', 'lat': 23.7808, 'lng': 90.4130},
      ],
    };
  }
  if (path.startsWith('/school-mode/plans/') && path.endsWith('/events')) {
    return {
      'events': empty ? const [] : [
        {'id': 1, 'kind': 'arrived_school', 'at': _ago(120), 'source': 'gps'},
        {'id': 2, 'kind': 'left_home', 'at': _ago(150), 'source': 'gps'},
      ],
    };
  }
  if (path.startsWith('/kids-watch/watches/') && path.endsWith('/voice')) {
    return {
      'voice_days': 14,
      'notes': empty ? const [] : [
        {'id': 9, 'direction': 'up', 'at': _ago(30), 'duration_s': 6.2, 'state': 'stored',
         'heard': false, 'mime': 'audio/amr', 'transcript': '', 'from_me': false},
        {'id': 10, 'direction': 'down', 'at': _ago(25), 'duration_s': 4.0, 'state': 'acked',
         'heard': true, 'mime': 'audio/amr', 'transcript': '', 'from_me': true},
      ],
    };
  }
  return null;
}
