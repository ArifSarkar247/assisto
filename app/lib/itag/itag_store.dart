// flag-itag: the paired tags, kept ONLY on this phone (SharedPreferences).
// Nothing here is sent to the server — not the tag, not the last-seen place.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ItagPlace {
  final double lat;
  final double lng;
  final int atMs;
  const ItagPlace(this.lat, this.lng, this.atMs);

  Map<String, Object> toJson() => {'lat': lat, 'lng': lng, 'at': atMs};
  static ItagPlace? fromJson(Object? m) {
    if (m is! Map) return null;
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    final at = (m['at'] as num?)?.toInt();
    if (lat == null || lng == null || at == null) return null;
    return ItagPlace(lat, lng, at);
  }
}

class ItagTag {
  final String address;
  final String name;
  final int addedMs;
  final ItagPlace? lastSeen;
  final int? battery;
  final int? batteryMs;
  const ItagTag(this.address, this.name, this.addedMs,
      {this.lastSeen, this.battery, this.batteryMs});

  ItagTag copyWith({String? name, ItagPlace? lastSeen, int? battery, int? batteryMs}) =>
      ItagTag(address, name ?? this.name, addedMs,
          lastSeen: lastSeen ?? this.lastSeen,
          battery: battery ?? this.battery,
          batteryMs: batteryMs ?? this.batteryMs);

  Map<String, Object?> toJson() => {
        'address': address,
        'name': name,
        'added': addedMs,
        if (lastSeen != null) 'seen': lastSeen!.toJson(),
        if (battery != null) 'battery': battery,
        if (batteryMs != null) 'battery_at': batteryMs,
      };

  static ItagTag? fromJson(Object? m) {
    if (m is! Map) return null;
    final a = (m['address'] ?? '').toString();
    if (a.isEmpty) return null;
    return ItagTag(a, (m['name'] ?? '').toString(), (m['added'] as num?)?.toInt() ?? 0,
        lastSeen: ItagPlace.fromJson(m['seen']),
        battery: (m['battery'] as num?)?.toInt(),
        batteryMs: (m['battery_at'] as num?)?.toInt());
  }
}

class ItagStore {
  static const tagsKey = 'itag_tags_v1';
  static const buttonKey = 'itag_button_rings_phone';
  // "watch my bag" is never restored after a restart: it runs only while
  // the user keeps the app open and sees the banner.

  Future<List<ItagTag>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(tagsKey);
      if (raw == null) return [];
      final l = jsonDecode(raw);
      if (l is! List) return [];
      return l.map(ItagTag.fromJson).whereType<ItagTag>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<ItagTag> tags) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(tagsKey, jsonEncode([for (final t in tags) t.toJson()]));
    } catch (_) {}
  }

  Future<bool> buttonRingsPhone() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(buttonKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setButtonRingsPhone(bool v) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(buttonKey, v);
    } catch (_) {}
  }
}
