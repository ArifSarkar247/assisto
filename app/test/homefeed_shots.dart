// homefeed (row 38): Today facts gallery states for test/screenshots_test.dart
// — a source outage (last real value + "not responding, X ago", old gold
// price warning) and the offline saved copy ("copy saved X ago").
import 'package:flutter/material.dart';

import 'package:assisto/screens/world/world_today_screen.dart';

import 'world_fake.dart';

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

class _StaleApi extends FakeWorldApi {
  _StaleApi({super.lang, this.offline = false});
  final bool offline;

  @override
  Future<Map<String, dynamic>> today() async {
    if (offline) throw StateError('offline');
    final j = await super.today();
    final cards = Map<String, dynamic>.from(j['cards'] as Map);
    if (cards['weather'] is Map) {
      cards['weather'] = {
        ...(cards['weather'] as Map).cast<String, dynamic>(),
        'fetched_at': _ago(const Duration(hours: 5)),
        'age_min': 300,
        'stale': true,
      };
    }
    if (cards['gold'] is Map) {
      cards['gold'] = {...(cards['gold'] as Map).cast<String, dynamic>(), 'stale': true};
    }
    return {...j, 'cards': cards, 'generated_at': _ago(Duration.zero)};
  }

  @override
  Future<Map<String, dynamic>> config() async {
    if (offline) throw StateError('offline');
    return super.config();
  }
}

Map<String, dynamic> _savedCopy(String l) {
  final bn = l == 'bn';
  final now = DateTime.now().toUtc().add(const Duration(hours: 6));
  final day =
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return {
    'city': {'id': 'dhaka', 'name': bn ? 'ঢাকা' : 'Dhaka'},
    'generated_at': _ago(const Duration(minutes: 35)),
    'cards': {
      'prayer': {
        'times': {
          'fajr': '04:52',
          'sunrise': '06:09',
          'dhuhr': '11:44',
          'asr': '15:35',
          'maghrib': '17:13',
          'isha': '18:31'
        },
        'next': 'asr',
        'date': day,
        'note': bn
            ? 'স্থানীয় হিসাব — আপনার মসজিদের সময়ের সাথে কয়েক মিনিট পার্থক্য হতে পারে।'
            : 'Local calculation — may differ by a few minutes from your mosque.',
        'days': <Map<String, dynamic>>[],
      },
      'weather': {
        'temp': 27.6,
        'humidity': 68,
        'wind': 2.4,
        'label': bn ? 'আংশিক মেঘলা' : 'Partly cloudy',
        'icon': 'cloud',
        'next': <Map<String, dynamic>>[],
        'updated': _ago(const Duration(minutes: 50)),
        'fetched_at': _ago(const Duration(minutes: 50)),
        'age_min': 15,
        'stale': false,
        'source': 'MET Norway (CC BY 4.0)',
        'source_url': 'https://api.met.no/',
      },
    },
    'hidden': <String, String>{},
    'hidden_since': <String, String>{},
  };
}

final Map<String, Widget Function(String)> homefeedShots = {
  'homefeed_today_outage': (l) => WorldTodayScreen(api: _StaleApi(lang: l)),
  'homefeed_today_offline': (l) => WorldTodayScreen(
      api: _StaleApi(lang: l, offline: true), debugSavedCopy: _savedCopy(l)),
};
