// train: FakeApi / gallery GET stubs for the Train tracker — the server's
// real response shapes (backend/core/train_views.py). Honest states: an
// unchecked timetable estimate, a live train with 3 sharers, a chat with
// an emergency message and a My Circle request.
Map<String, dynamic> _st(String id, String bn, String en, double lat, double lng) =>
    {'id': id, 'bn': bn, 'en': en, 'lat': lat, 'lng': lng};

final _ctg = _st('n1', 'চট্টগ্রাম', 'Chattogram Railway Station', 22.33402, 91.82956);
final _dhk = _st('n2', 'কমলাপুর', 'Kamalapur Railway Station', 23.73195, 90.42627);
final _bia = _st('n3', 'ঢাকা বিমানবন্দর', 'Dhaka Airport Railway Station', 23.85207, 90.40838);

Map<String, dynamic> trainSummary701() => {
      'no': '701', 'name_bn': 'সুবর্ণ এক্সপ্রেস', 'from': _ctg, 'to': _dhk,
      'dep': '07:00', 'arr': '12:20', 'off_days': [0], 'km': 321.2, 'approved': false,
    };

Map<String, dynamic> trainLive701({bool live = false}) {
  final now = DateTime.now().toUtc();
  return {
    'train': trainSummary701(),
    'date': '2026-11-03',
    'runs': true,
    'mode': live ? 'live' : 'estimate',
    'live': live
        ? {'label': 'live', 'chainage_m': 160000, 'lat': 23.1, 'lng': 91.2, 'sharers': 3,
           'dropped': 1, 'age_s': 25, 'speed_kmh': 62, 'arrived': false, 'delay_min': 18,
           'next_stop': _bia}
        : null,
    'estimate': {'label': 'estimate', 'state': 'running', 'chainage_m': 150000,
        'lat': 23.05, 'lng': 91.25, 'next_stop': _bia, 'approved': false,
        'dep': now.toIso8601String(), 'arr': now.toIso8601String()},
    'stops': [
      {..._ctg, 'km': 0, 'at': now.subtract(const Duration(hours: 2)).toIso8601String(), 'label': 'estimate'},
      {..._bia, 'km': 300.1, 'at': now.add(const Duration(hours: 2)).toIso8601String(), 'label': 'estimate'},
      {..._dhk, 'km': 321.2, 'at': now.add(const Duration(hours: 3)).toIso8601String(), 'label': 'estimate'},
    ],
    'path': [[22.33402, 91.82956], [23.0, 91.3], [23.85207, 90.40838], [23.73195, 90.42627]],
    'sms': {'to': '16318', 'body': 'TR 701', 'cost_bdt': 4},
    'my_share': null,
    'chat_count': 2,
    'source': {'wiki_title': 'সুবর্ণ এক্সপ্রেস', 'wiki_revid': 1},
  };
}

Map<String, dynamic> trainChatRoom({bool joined = true, bool bn = true}) => {
      'me': joined ? {'nickname': bn ? 'নীল' : 'Blue'} : null,
      'messages': joined
          ? [
              {'id': 1, 'nick': bn ? 'সবুজ' : 'Green', 'mine': false,
               'text': bn ? 'ট্রেন ভৈরবে থেমে আছে' : 'Train is stopped at Bhairab',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': false},
              {'id': 2, 'nick': bn ? 'লাল' : 'Red', 'mine': false,
               'text': bn ? 'কোচ চ-তে একজন অসুস্থ, সাহায্য লাগবে' : 'Someone in coach C is sick, need help',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': true},
              {'id': 3, 'nick': bn ? 'নীল' : 'Blue', 'mine': true,
               'text': bn ? 'গার্ডকে জানাচ্ছি' : 'Telling the guard',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': false},
            ]
          : [],
      'circle_requests': joined ? [{'id': 9, 'nick': bn ? 'সবুজ' : 'Green'}] : [],
      'ends_at': DateTime.now().toUtc().add(const Duration(hours: 9)).toIso8601String(),
      'hotlines': {'police': '999', 'rail': '131'},
    };

Map<String, dynamic>? fakeTrainGet(String path, {required bool bn, required bool empty}) {
  if (path.startsWith('/train/config')) {
    return {'enabled': true, 'dest_alarm': true, 'map': {'tile_url': ''},
        'attribution': '© OpenStreetMap contributors (ODbL)',
        'sms': {'to': '16318', 'cost_bdt': 4}, 'hotlines': {'police': '999', 'rail': '131'}};
  }
  if (path.startsWith('/train/search')) {
    return {'trains': empty ? [] : [trainSummary701()]};
  }
  if (path.contains('/live')) return trainLive701(live: !empty);
  if (path.contains('/chat')) return trainChatRoom(joined: !empty, bn: bn);
  return null;
}
