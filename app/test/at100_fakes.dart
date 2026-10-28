// at100: realistic remote-switch / watched-phone payloads (same shape as
// core/views_at_remote.py) for FakeApi, the gallery and the widget tests.

String _iso(Duration ago) => DateTime.now().toUtc().subtract(ago).toIso8601String();

Map<String, dynamic> at100Cmd(int id, String kind, String state,
        {Duration ago = const Duration(minutes: 3),
        String detail = '',
        bool mine = true,
        bool byOwner = true,
        String by = ''}) =>
    {
      'id': id,
      'kind': kind,
      'state': state,
      'detail': detail,
      'mine': mine,
      'by_owner': byOwner,
      'by': by,
      'created_at': _iso(ago),
      'delivered_at': (state == 'delivered' || state == 'done' || state == 'failed')
          ? _iso(ago - const Duration(seconds: 20))
          : null,
      'done_at': (state == 'done' || state == 'failed')
          ? _iso(ago - const Duration(seconds: 30))
          : null,
    };

Map<String, dynamic> at100FakeCommands({
  required bool bn,
  bool empty = false,
  bool trusted = false,
  bool online = true,
  bool lostMode = false,
  bool protectionOn = true,
  bool active = true,
}) {
  final cmds = empty
      ? <Map<String, dynamic>>[]
      : <Map<String, dynamic>>[
          at100Cmd(13, 'alarm', online ? 'done' : 'queued',
              ago: const Duration(minutes: 1), detail: 'rang_60s'),
          at100Cmd(12, 'lock', 'failed',
              ago: const Duration(minutes: 9), detail: 'no_admin',
              mine: false, byOwner: !trusted, by: bn ? 'মা' : 'Ma'),
          at100Cmd(11, 'lost_mode', 'done', ago: const Duration(minutes: 12)),
        ];
  final can = {
    for (final k in ['lost_mode', 'alarm', 'alarm_stop', 'lock', 'message'])
      k: protectionOn && (!trusted || k == 'lost_mode' || active || lostMode)
  };
  return {
    'role': trusted ? 'trusted' : 'owner',
    'phone_id': 7,
    'owner': bn ? 'আরিফ' : 'Arif',
    'phone': {
      'protection_on': protectionOn,
      'online': online,
      'last_seen': _iso(online ? const Duration(minutes: 2) : const Duration(hours: 3)),
      'interval_min': 5,
      'lost_mode': lostMode,
    },
    'can': can,
    'commands': cmds,
    'in_flight': false,
    'wipe': {'supported': false, 'use': 'https://www.google.com/android/find'},
    'alarm_s': 60,
  };
}

List<Map<String, dynamic>> at100FakeWatching(bool bn) => [
      {
        'phone_id': 7,
        'owner': bn ? 'আরিফ' : 'Arif',
        'model': 'realme 9i',
        'lost_mode': true,
        'went_dark_at': null,
        'online': false,
        'last_seen': _iso(const Duration(minutes: 40)),
        'protection_on': true,
        'last_location': {
          'lat': 23.7330,
          'lng': 90.4172,
          'fix_at': _iso(const Duration(minutes: 41)),
          'acc': 18.0
        },
      },
      {
        'phone_id': 9,
        'owner': bn ? 'সুমি' : 'Sumi',
        'model': 'Galaxy A15',
        'lost_mode': false,
        'went_dark_at': null,
        'online': true,
        'last_seen': _iso(const Duration(minutes: 4)),
        'protection_on': true,
      },
    ];
