// sjkids — made-up Children Corner data for the gallery and widget tests
// (sample names and coordinates only; never real user data).

String _ago(int min) => DateTime.now().subtract(Duration(minutes: min)).toUtc().toIso8601String();

List<Map<String, dynamic>> kcFakePlaces(String lang) {
  final bn = lang == 'bn';
  return [
    {'id': 1, 'kind': 'school', 'role': 'safe', 'name': bn ? 'আইডিয়াল স্কুল' : 'Ideal School',
     'lat': 23.7801, 'lng': 90.4251, 'radius_m': 150,
     'windows': [{'days': [6, 0, 1, 2, 3], 'start': '08:00', 'end': '13:00'}]},
    {'id': 2, 'kind': 'coaching', 'role': 'safe', 'name': '',
     'lat': 23.7741, 'lng': 90.4182, 'radius_m': 150,
     'windows': [{'days': [0, 2], 'start': '16:00', 'end': '18:00'}]},
    {'id': 3, 'kind': 'relative', 'role': 'safe', 'name': bn ? 'খালার বাসা' : "Aunt's house",
     'lat': 23.7702, 'lng': 90.4301, 'radius_m': 150, 'windows': const []},
    {'id': 4, 'kind': 'river', 'role': 'watch', 'name': '',
     'lat': 23.7650, 'lng': 90.4400, 'radius_m': 200, 'windows': const []},
    {'id': 5, 'kind': 'market', 'role': 'watch', 'name': bn ? 'নতুন বাজার' : 'Notun Bazar',
     'lat': 23.7905, 'lng': 90.4210, 'radius_m': 150, 'windows': const []},
  ];
}

/// One child's plan: an open "Do you know where Rina is?" question
/// (unknown place in school hours) + an answered one.
Map<String, dynamic> kcFakePlan(String lang, {bool empty = false, bool ask = true}) {
  final bn = lang == 'bn';
  return {
    'id': 5, 'child_name': bn ? 'রিনা' : 'Rina', 'enabled': true, 'accepted': true,
    'mode': 'phone', 'mine': true, 'i_am_child': false,
    'config': {
      'start': '08:00', 'end': '13:00', 'days': [6, 0, 1, 2, 3], 'holidays': const [],
      'kc_places': empty ? const [] : kcFakePlaces(lang),
    },
    'watchers': [{'id': 1, 'name': bn ? 'আব্বু' : 'Abbu', 'owner': true}],
    'today': {'state': 'at_school', 'school_day': true},
    'kids_corner': {
      'where': empty ? 'unknown' : 'outside', 'place_kind': '', 'place_name': '',
      'since': _ago(14),
      'asks': empty || !ask
          ? const []
          : [
              {'id': '2026-11-09-0@0800', 'key': '0@08:00', 'state': 'open',
               'place_kind': 'school', 'place_name': bn ? 'আইডিয়াল স্কুল' : 'Ideal School',
               'at': _ago(4), 'out_since': _ago(14), 'lat': 23.7712, 'lng': 90.4333},
            ],
      'windows': const [], 'watch_today': const [],
    },
  };
}
