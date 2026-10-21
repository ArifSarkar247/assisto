import 'dart:math' as math;

import 'package:assisto/api.dart';

/// v1-vehicle fake data for the screenshot gallery (wired from FakeApi).
/// Returns null for any non-vehicle path so FakeApi keeps handling it.
/// [mode]: 'data' | 'empty' | 'fail' | 'slow'. [plan] = FakeApi.planSlug.
Map<String, dynamic>? fakeVehicleGet(String path, bool bn, String mode, String plan) {
  if (!path.startsWith('/vehicle/')) return null;
  if (mode == 'fail') {
    throw ApiException(bn ? 'সংযোগ করা গেল না' : 'Could not connect', 503);
  }
  final now = DateTime.now().toUtc();
  String iso(Duration ago) => now.subtract(ago).toIso8601String();
  if (path == '/vehicle/trackers') {
    if (mode == 'empty') return {'trackers': [], 'month_credits': 50};
    return {
      'month_credits': 50,
      'trackers': [
        _tracker(1, bn ? 'পরিবারের গাড়ি' : 'Family car', iso, moving: true),
        _tracker(2, bn ? 'অফিসের মাইক্রো' : 'Office microbus', iso, shared: true),
        {
          'id': 3,
          'name': bn ? 'বাইক' : 'Bike',
          'state': 'pending',
          'online': false,
          'pair_expires_at': iso(const Duration(minutes: -8)),
          'is_owner': true,
          'access': {'view': true, 'command': true, 'manage': true},
        },
      ],
    };
  }
  if (path == '/vehicle/fleet') {
    if (plan != 'business') throw ApiException('business_only', 403);
    return {
      'ok': true,
      'month_credits': 50,
      'totals': {'vehicles': 4, 'online': 3, 'moving': 2, 'km_today': 186.4, 'alerts_today': 2},
      'vehicles': [
        {..._tracker(1, bn ? 'ডেলিভারি ভ্যান ১' : 'Delivery van 1', iso, moving: true), 'km_today': 72.3, 'alerts_today': 1},
        {..._tracker(2, bn ? 'ডেলিভারি ভ্যান ২' : 'Delivery van 2', iso, moving: true), 'km_today': 64.0, 'alerts_today': 0},
        {..._tracker(4, bn ? 'পিকআপ' : 'Pickup', iso), 'km_today': 50.1, 'alerts_today': 1},
        {..._tracker(5, bn ? 'মালিকের গাড়ি' : "Owner's car", iso, offline: true), 'km_today': 0.0, 'alerts_today': 0},
      ],
    };
  }
  final m = RegExp(r'^/vehicle/trackers/(\d+)(/[a-z-]+)?').firstMatch(path);
  if (m == null) return const {};
  final id = int.parse(m.group(1)!);
  final sub = m.group(2) ?? '';
  switch (sub) {
    case '':
      return _tracker(id, bn ? 'পরিবারের গাড়ি' : 'Family car', iso, settings: true);
    case '/route':
      return _route(now);
    case '/commands':
      return {
        'commands': [
          {'id': 12, 'kind': 'engine_restore', 'state': 'acked', 'fail_reason': '', 'created_at': iso(const Duration(hours: 20)), 'response': 'Restore fuel supply: Success!'},
          {'id': 11, 'kind': 'engine_cut', 'state': 'failed', 'fail_reason': 'no_reply', 'created_at': iso(const Duration(hours: 21))},
        ]
      };
    case '/obd':
      return {
        'available': true,
        'battery_v': 12.6,
        'obd': {'coolant_temp_c': 91, 'fuel_level_pct': 58, 'rpm': 820, 'dtc': ['P0420']},
        'dtc': [
          {'code': 'P0420', 'known': true, 'severity': 'med',
           'bn': 'ক্যাটালিটিক কনভার্টার ঠিকমতো কাজ করছে না (ব্যাংক ১)',
           'en': 'Catalytic converter efficiency below threshold (bank 1)',
           'advice_bn': 'সুবিধামতো সময়ে মেকানিক দিয়ে পরীক্ষা করান।',
           'advice_en': 'Have a mechanic check it when convenient.'},
        ],
      };
    case '/grants':
      return {
        'grants': [
          {'id': 1, 'kind': 'family', 'can_command': false, 'name': bn ? 'আম্মু' : 'Mom', 'valid': true},
          {'id': 2, 'kind': 'family', 'can_command': true, 'name': bn ? 'রাফি' : 'Rafi', 'valid': true},
        ]
      };
  }
  return const {};
}

Map<String, dynamic>? fakeVehiclePost(String path, Map<String, dynamic> body, bool bn) {
  if (!path.startsWith('/vehicle/')) return null;
  if (path == '/vehicle/obd/decode') {
    return {
      'dtc': [
        {'code': 'P0301', 'known': true, 'severity': 'high',
         'bn': 'সিলিন্ডার ১-এ মিসফায়ার', 'en': 'Cylinder 1 misfire',
         'advice_bn': 'শিগগিরই মেকানিক দেখান; ইঞ্জিনের আলো জ্বলে-নিভে করলে গাড়ি চালানো বন্ধ রাখুন।',
         'advice_en': 'See a mechanic soon; if the engine light is flashing, stop driving.'},
      ]
    };
  }
  if (path.endsWith('/ai-summary')) {
    return {
      'ai': false,
      'reason': 'no_key',
      'text': bn
          ? 'গত ২৪ ঘণ্টায় ৩ টি যাত্রা, মোট ৪২.৬ কিমি। দয়া করে দেখে নিন: রাতে একটি যাত্রা হয়েছে (১২.১ কিমি)।'
          : '3 trip(s) in the last 24 hours, 42.6 km in total. Please check: a trip at night (12.1 km).',
    };
  }
  return {'ok': true};
}

Map<String, dynamic> _tracker(int id, String name, String Function(Duration) iso,
    {bool moving = false, bool shared = false, bool offline = false, bool settings = false}) {
  return {
    'id': id,
    'name': name,
    'imei_tail': '3915',
    'protocol': id.isEven ? 'teltonika' : 'gt06',
    'state': 'paired',
    'online': !offline,
    'last_seen_at': iso(offline ? const Duration(hours: 5) : const Duration(seconds: 20)),
    'live': {
      'lat': 23.7925, 'lng': 90.4078,
      'speed_kmh': moving ? 38.0 : 0.0,
      'course': 90,
      'at': iso(const Duration(seconds: 25)),
      'fix_age_s': 25,
      'moving': moving,
    },
    'ignition': moving,
    'relay_cut': false,
    'ext_voltage_v': 12.6,
    'is_owner': !shared,
    'access': {'view': true, 'command': !shared, 'manage': !shared},
    if (settings)
      'settings': {
        'moving_interval_s': 5,
        'parked_interval_s': 180,
        'speed_limit_kmh': 80,
        'night_ignition_alert': true,
        'night_start': '23:00',
        'night_end': '05:00',
        'geofences': [
          {'id': 'h', 'name': 'Home', 'lat': 23.7808, 'lng': 90.4130, 'radius_m': 400},
        ],
        'cutoff_requires_approval': false,
        'approver_member_id': null,
      },
  };
}

Map<String, dynamic> _route(DateTime now) {
  // Home (Banani) -> office (Gulshan) -> back, as a deterministic wiggly path.
  final pts = <Map<String, dynamic>>[];
  var lat = 23.7808, lng = 90.4130;
  for (var i = 0; i < 120; i++) {
    final t = now.subtract(Duration(minutes: 600 - i * 5));
    lat += 0.0006 * math.sin(i / 9) + (i < 60 ? 0.0004 : -0.0004);
    lng += 0.0005 * math.cos(i / 7);
    pts.add({'at': t.toIso8601String(), 'lat': lat, 'lng': lng, 'speed_kmh': (i % 20 < 3) ? 0 : 30 + (i % 7) * 4});
  }
  String iso(int minAgo) => now.subtract(Duration(minutes: minAgo)).toIso8601String();
  return {
    'points': pts,
    'trips': [
      {'start': iso(600), 'end': iso(560), 'km': 14.2, 'duration_s': 2400, 'night': false, 'max_kmh': 58},
      {'start': iso(420), 'end': iso(380), 'km': 16.3, 'duration_s': 2350, 'night': false, 'max_kmh': 62},
      {'start': iso(120), 'end': iso(95), 'km': 12.1, 'duration_s': 1500, 'night': true, 'max_kmh': 71},
    ],
    'stops': [],
    'total_km': 42.6,
    'moving_s': 6250,
    'max_speed_kmh': 71,
    'point_count': 120,
  };
}
