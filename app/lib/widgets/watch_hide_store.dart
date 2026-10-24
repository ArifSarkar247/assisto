import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// f6 — Watch feed dismiss / snooze that really sticks.
///
/// Before f6 both only went into an in-memory set: "Snoozed to tomorrow" and
/// the item was back the next time the screen opened. Now each hidden item id
/// is saved on this phone with an "until" moment:
///   * snooze  -> until the start of tomorrow (it comes back tomorrow)
///   * dismiss -> for 30 days (long after any one-off item has passed)
/// Expired entries are dropped on load.
class WatchHideStore {
  WatchHideStore._();

  static const _key = 'watch_feed_hidden_v1';
  static const dismissDays = 30;

  static DateTime snoozeUntil(DateTime now) =>
      DateTime(now.year, now.month, now.day + 1);
  static DateTime dismissUntil(DateTime now) =>
      now.add(const Duration(days: dismissDays));

  /// Pure: ids still hidden at [now] from a stored map.
  static Set<String> activeIds(Map<String, String> raw, DateTime now) => {
        for (final e in raw.entries)
          if ((DateTime.tryParse(e.value) ?? DateTime(0)).isAfter(now)) e.key,
      };

  static Future<Map<String, String>> _read() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_key);
      if (s == null || s.isEmpty) return {};
      return (jsonDecode(s) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  static Future<Set<String>> load({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final raw = await _read();
    final keep = activeIds(raw, n);
    if (keep.length != raw.length) {
      await _write({for (final k in keep) k: raw[k]!});
    }
    return keep;
  }

  static Future<void> _write(Map<String, String> m) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(m));
    } catch (_) {}
  }

  static Future<void> hide(String id, DateTime until) async {
    final m = await _read();
    m[id] = until.toIso8601String();
    await _write(m);
  }

  static Future<void> unhide(String id) async {
    final m = await _read();
    if (m.remove(id) != null) await _write(m);
  }
}
