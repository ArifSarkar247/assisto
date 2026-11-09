// fcbrain: gallery states for test/screenshots_test.dart — Family privacy &
// alerts (on / paused), the night news card (card / off). No network: the
// screens take a fixed server answer (debugData).
import 'package:flutter/material.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_v3/brain/fc_brain_settings_screen.dart';
import 'package:assisto/family_v3/brain/fc_night_news_card.dart';

Map<String, dynamic> fcbSettingsData(String l, {bool paused = false}) => {
      'prefs': {
        'prefs': {
          'auto_arrive': true,
          'leave_news': false,
          'night': {
            'on': true,
            'time': '21:30',
            'voice': false,
            'items': ['place', 'arrivals', 'battery'],
          },
        },
        'paused_until': paused ? DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String() : null,
        'watch_on': true,
        'budget': {'limit': 3, 'used': 1, 'left': 2, 'skipped': 0},
        'pause_hours': [1, 2, 8],
        'night_items': ['place', 'arrivals', 'battery', 'carecall', 'tasks'],
      },
      'visibility': {
        'people': [
          {'user_id': 2, 'name': 'Rahima', 'families': [l == 'bn' ? 'আমার পরিবার' : 'Our home']},
          {'user_id': 3, 'name': 'Karim', 'families': [l == 'bn' ? 'আমার পরিবার' : 'Our home', l == 'bn' ? 'বাবার বাড়ি' : 'Parents home']},
        ],
        'reminder_due': false,
      },
      'counters': {'gps': 6, 'net': 41, 'passive': 3, 'pings': 52},
      'running': true,
    };

Map<String, dynamic> fcbNightData(String l, {bool on = true}) => {
      'card': {
        'text': l == 'bn'
            ? 'আজ রাতের খবর — Rafi: বাড়িতে আছেন। Karim-এর কাছ থেকে নতুন খবর নেই।'
            : 'Tonight: Rafi: at Home. No fresh news from Karim.',
        'source': 'template',
      },
      'night': {'on': on, 'time': '21:30', 'voice': true, 'items': ['place']},
    };

final Map<String, Widget Function(String)> fcbrainShots = {
  'fcb_settings': (l) => FcBrainSettingsScreen(api: ApiClient(), familyId: 1, debugData: fcbSettingsData(l)),
  'fcb_settings_paused': (l) =>
      FcBrainSettingsScreen(api: ApiClient(), familyId: 1, debugData: fcbSettingsData(l, paused: true)),
  'fcb_night': (l) => Scaffold(
      appBar: AppBar(),
      body: ListView(children: [FcNightNewsCard(api: ApiClient(), familyId: 1, debugData: fcbNightData(l))])),
  'fcb_night_off': (l) => Scaffold(
      appBar: AppBar(),
      body: ListView(
          children: [FcNightNewsCard(api: ApiClient(), familyId: 1, debugData: fcbNightData(l, on: false))])),
};
