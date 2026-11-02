// cctvarm: a fake Auto guard source for widget tests + the screenshot gallery.
import 'package:assisto/cctvx/auto_guard_source.dart';

class FakeAutoGuard implements AutoGuardSource {
  Map<String, dynamic> data;
  Map<String, dynamic> mineData;
  Map<String, dynamic> sos;
  final List<Map<String, dynamic>> saves = [];
  final List<bool> consents = [];
  final List<List<Map<String, dynamic>>> reports = [];
  FakeAutoGuard({Map<String, dynamic>? data, Map<String, dynamic>? mine, Map<String, dynamic>? sos})
      : data = data ?? ownerData(),
        mineData = mine ?? {'sites': []},
        sos = sos ?? {'grants': [], 'minutes': 30};

  static Map<String, dynamic> ownerData(
          {bool familyOn = true,
          bool armed = false,
          String summary = 'unknown',
          bool privacy = false,
          bool cams = true,
          bool people = true,
          bool log = true}) =>
      {
        'site': 1,
        'name': 'Home',
        'kind': 'home',
        'config': {
          'family_on': familyOn,
          'radius_m': 150,
          'exit_m': 300,
          'privacy_on': true,
          'closed_on': false,
          'sos_live': true,
          'home': {'name': 'Our flat', 'place_id': 3},
        },
        'status': {
          'auto_armed': armed,
          'reason': armed ? 'family_away' : '',
          'summary': summary,
          'privacy': privacy,
          'eod_until': null,
          'sos_until': null,
        },
        'members': people
            ? [
                {'uid': 1, 'name': 'Rahim', 'consent': true, 'state': 'away', 'is_me': true},
                {'uid': 2, 'name': 'Karima', 'consent': true, 'state': 'unknown', 'is_me': false},
                {'uid': 3, 'name': 'Sabbir', 'consent': false, 'state': 'no_consent', 'is_me': false},
              ]
            : [],
        'candidates': people ? [
          {'uid': 4, 'name': 'Amma', 'family': true}
        ] : [],
        'cameras': cams
            ? [
                {
                  'id': 11,
                  'name': 'Living room',
                  'online': true,
                  'indoor': true,
                  'nomove': {'on': true, 'from': '06:00', 'by': '10:00', 'people': [2]}
                },
                {
                  'id': 12,
                  'name': 'Gate',
                  'online': false,
                  'indoor': false,
                  'nomove': {'on': false, 'from': '06:00', 'by': '10:00', 'people': []}
                },
              ]
            : [],
        'home_places': [
          {'id': 3, 'name': 'Our flat', 'home': true}
        ],
        'hours_set': false,
        'log': log
            ? [
                {'at': '2026-11-03T08:05:00+06:00', 'what': 'armed_family', 'text': 'Everyone is out — guard on: Home'},
              ]
            : [],
        'rules': {'radius_bounds': [80, 500], 'stale_min': 30, 'dwell_min': 5, 'hold_min': 60, 'sos_live_min': 30},
      };

  @override
  Future<Map<String, dynamic>> load(int siteId) async => data;

  @override
  Future<Map<String, dynamic>> save(int siteId, Map<String, dynamic> body) async {
    saves.add(body);
    return data;
  }

  @override
  Future<Map<String, dynamic>> mine() async => mineData;

  @override
  Future<Map<String, dynamic>> consent(int siteId, bool yes) async {
    consents.add(yes);
    final s = (mineData['sites'] as List).cast<Map<String, dynamic>>();
    for (final r in s) {
      if (r['site'] == siteId) r['consent'] = yes;
    }
    return {'ok': true, 'consent': yes, 'message': 'ok'};
  }

  @override
  Future<Map<String, dynamic>> presence(List<Map<String, dynamic>> r) async {
    reports.add(r);
    return {'sites': []};
  }

  @override
  Future<Map<String, dynamic>> sosLive() async => sos;
}
