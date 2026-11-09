import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state.dart';
import '../theme.dart';
import '../train/dest_alarm_sound.dart';
import '../widgets/chatnav.dart';
import 'silent_watch_api.dart';

/// fcelder — shared bits of the elder screens: the injectable server / voice,
/// the SOS hook, Bangla digits, the family call targets and the big button.
class ElderHooks {
  ElderHooks._();

  /// Tests / gallery inject a fake server.
  static SilentWatchApi? apiOverride;

  /// "Every button speaks its name" — the phone's own TTS on the alarm
  /// stream (heard even on silent). Tests inject a recorder.
  static DestAlarmSound voice = NativeDestAlarmSound();

  /// Red Danger -> the SOS sender. fcsos assigns its 5-second sender here
  /// (SosSenderScreen.open(context, source: 'elder')); until then the
  /// existing emergency screen (SOS one tap) opens.
  static Future<void> Function(BuildContext context)? openSos;

  static SilentWatchApi? api(BuildContext context) {
    if (apiOverride != null) return apiOverride;
    try {
      final app = context.read<AppState>();
      return app.loggedIn ? HttpSilentWatchApi(app.api) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> sos(BuildContext context) async {
    final f = openSos;
    if (f != null) return f(context);
    ChatNav.push(context, 'emergency');
  }

  static String lang(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';

  static Future<void> say(BuildContext context, String text) async {
    try {
      await voice.speak(text, lang(context));
    } catch (_) {}
  }
}

/// ASCII digits -> Bangla digits when [bn].
String elderDigits(Object? v, bool bn) {
  final s = '${v ?? ''}';
  if (!bn) return s;
  return String.fromCharCodes(
      s.codeUnits.map((c) => (c >= 0x30 && c <= 0x39) ? 0x09E6 + (c - 0x30) : c));
}

/// "10:05" (Bangla digits on a Bangla screen); the part-of-day word is in the ARB greeting.
String elderClock(DateTime t, bool bn) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return elderDigits('$h:$m', bn);
}

String elderHhmm(int minutes, bool bn) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return elderDigits('$h:$m', bn);
}

/// One family member the elder can call with one tap.
class ElderContact {
  final int? userId;
  final String name;
  final String phone;
  final String relation;
  const ElderContact(this.userId, this.name, this.phone, this.relation);

  Map<String, dynamic> toJson() =>
      {'user_id': userId, 'name': name, 'phone': phone, 'relation': relation};

  static ElderContact? fromJson(Object? o) {
    if (o is! Map) return null;
    final phone = '${o['phone'] ?? ''}'.trim();
    if (phone.isEmpty) return null;
    return ElderContact((o['user_id'] as num?)?.toInt(), '${o['name'] ?? ''}'.trim(), phone,
        '${o['relation'] ?? ''}'.trim().toLowerCase());
  }

  // son / daughter in the circle's codes, or typed in Bangla (escaped: the
  // language gate keeps Bangla literals out of code).
  static final _son = RegExp('^(son|\u099b\u09c7\u09b2\u09c7)');
  static final _daughter = RegExp('^(daughter|\u09ae\u09c7\u09df\u09c7|\u09ae\u09c7\u09af\u09bc\u09c7)');
  bool get isSon => _son.hasMatch(relation);
  bool get isDaughter => _daughter.hasMatch(relation);
}

/// Picks the two call buttons: a son and a daughter when known, else the
/// first family members with a phone.
({ElderContact? first, ElderContact? second}) pickCallTargets(List<ElderContact> all) {
  ElderContact? son, daughter;
  for (final c in all) {
    if (son == null && c.isSon) son = c;
    if (daughter == null && c.isDaughter) daughter = c;
  }
  final rest = all.where((c) => c != son && c != daughter).toList();
  final first = son ?? (rest.isNotEmpty ? rest.removeAt(0) : null);
  final second = daughter ?? (rest.isNotEmpty ? rest.removeAt(0) : null);
  return (first: first, second: second);
}

class ElderFamilyCache {
  static const key = 'fce_family_cache';

  static Future<List<ElderContact>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = jsonDecode(p.getString(key) ?? '[]');
      return (raw as List).map(ElderContact.fromJson).whereType<ElderContact>().toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<ElderContact> all) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode([for (final c in all) c.toJson()]));
    } catch (_) {}
  }
}

/// A very large, high-contrast action button (white text on a solid fill,
/// >= 5:1; >= 96 dp tall; text wraps instead of clipping at 200 % font).
class ElderBigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final Color color;
  final VoidCallback onTap;
  final double minHeight;

  const ElderBigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.sublabel,
    this.minHeight = 96,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: sublabel == null ? label : '$label. $sublabel',
      excludeSemantics: true,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            constraints: BoxConstraints(minHeight: minHeight),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2),
            ),
            child: Row(
              children: [
                Icon(icon, size: 48, color: Colors.white),
                const SizedBox(width: Gap.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.2)),
                      if (sublabel != null && sublabel!.isNotEmpty)
                        Text(sublabel!,
                            style: const TextStyle(color: Colors.white, fontSize: 19, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Solid fills used by the elder screens (white text on each >= 5:1).
class ElderColors {
  ElderColors._();
  static const ok = Brand.successFill; // 5.3:1
  static const callA = Color(0xFF1F4FD1); // deep blue, 6.6:1
  static const callB = Color(0xFF6A2FB0); // deep purple, 7.6:1
  static const talk = Color(0xFF0E5E77); // deep teal, 7.2:1
  static const danger = Brand.dangerFill; // 5.6:1
}
