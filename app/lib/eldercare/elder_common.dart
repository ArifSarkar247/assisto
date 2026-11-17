import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../family_v3/fc_slots_register.dart'; // fcrest
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

  /// gap-familycare: tests / gallery replace the mic sheet and the server
  /// agent of "Talk to Assisto" (null = the real voice sheet + POST /agent).
  static Future<String?> Function(BuildContext context)? listenOverride;
  static Future<Map<String, dynamic>> Function(BuildContext context, String text)?
      agentOverride;

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
    if (openSos == null) fcRegisterSlots(); // fcrest: the 5-second SOS sender
    final f = openSos;
    if (f != null) return f(context);
    ChatNav.push(context, 'emergency');
  }

  static String lang(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';

  static Future<void> say(BuildContext context, String text) async {
    try {
      await voice.speak(text, lang(context));
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
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
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
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
    // designv2: card radius, a soft glow in the button's own colour (none in
    // lite mode), white ink on the fill; big type from the theme scale.
    final lite = DsPerf.liteOf(context);
    final tx = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(DsRadius.card + 4);
    return Semantics(
      button: true,
      label: sublabel == null ? label : '$label. $sublabel',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: lite
              ? null
              : [BoxShadow(color: color.withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Material(
          color: color,
          borderRadius: radius,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Container(
              constraints: BoxConstraints(minHeight: minHeight),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                            style: tx.headlineMedium?.copyWith(
                                color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.2)),
                        if (sublabel != null && sublabel!.isNotEmpty)
                          Text(sublabel!,
                              style: tx.titleMedium?.copyWith(color: Colors.white, fontSize: 19, height: 1.3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ElderColors {
  ElderColors._();
  static const ok = Brand.successFill; // 5.3:1
  static const callA = Brand.blueDeep; // deep blue, white 6.6:1
  // darkened brand tokens (no new colour literals): white >= 7:1 on each
  static final callB = Color.lerp(Brand.purple, Brand.ink, 0.4)!; // deep purple
  static final talk = Color.lerp(Brand.cyan, Brand.ink, 0.6)!; // deep teal
  static const danger = Brand.dangerFill; // 5.6:1
}

/// gap-familycare: an AI answer made readable for an elder — markdown marks
/// removed (headings, bold, bullets, code ticks), blank lines collapsed.
String elderPlainReply(String raw) {
  final lines = <String>[];
  for (var l in raw.replaceAll('\r', '').split('\n')) {
    l = l
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*'), '')
        .replaceAll(RegExp(r'^\s*[-*•]\s+'), '• ')
        .replaceAll(RegExp(r'\*\*|__|`|\*'), '')
        .trimRight();
    if (l.trim().isEmpty) {
      if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
      continue;
    }
    lines.add(l);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n').trim();
}

/// gap-familycare: the part of an answer read OUT LOUD — the first sentences
/// up to about [max] characters, always ending at a full sentence (never
/// mid-word); the whole answer stays on screen.
String elderSpokenPart(String plain, {int max = 320}) {
  final flat = plain.replaceAll('•', '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  final ends = RegExp('[.!?\u0964](\\s|\$)');
  var cut = -1;
  for (final m in ends.allMatches(flat)) {
    if (m.start + 1 > max) break;
    cut = m.start + 1;
  }
  if (cut > 0) return flat.substring(0, cut).trim();
  final sp = flat.lastIndexOf(' ', max);
  return sp > 0 ? flat.substring(0, sp).trim() : flat.substring(0, max);
}
