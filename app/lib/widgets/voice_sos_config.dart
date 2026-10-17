import '../state.dart';

/// Pure-Dart configuration + wake-phrase matching for Hands-free Voice SOS
/// (feature #79). No Flutter/plugin imports here so the matcher is unit-testable
/// and can be shared by both the UI isolate and the foreground-service isolate.
///
/// Hands-free SOS is OPT-IN and OFF by default. When armed, a foreground service
/// listens on-device (via `speech_to_text`) for a chosen wake phrase; on a match
/// it fires the SAME SOS action as the manual button (api.journeySos) — it never
/// duplicates or fakes the alert.
///
/// Privacy: audio is transcribed ON-DEVICE by the platform speech engine and is
/// never uploaded by Assisto. Only the final SOS alert (with GPS) leaves the
/// device, exactly like the manual SOS. This is stated to the user in the UI.
class VoiceSosConfig {
  // SharedPreferences keys (read by both isolates through the Settings helper).
  static const kEnabled = 'voice_sos_on'; // bool, default false (OPT-IN)
  static const kPhrase = 'voice_sos_phrase'; // String, chosen wake phrase
  static const kCountdown = 'voice_sos_cd'; // String int, cancel-window seconds

  /// Safe default wake phrases. Deliberately uncommon word runs so normal
  /// conversation does not fire SOS. Index 0 is the default. These are NOT
  /// user-facing display copy (they are literal spoken keywords matched against
  /// the recogniser, ASCII-only so the language gate is satisfied); the UI
  /// labels them with localized descriptions.
  static const List<String> defaultPhrases = <String>[
    'assisto help help',
    'assisto emergency now',
  ];

  static const int defaultCountdown = 5;

  static Future<bool> isEnabled() => Settings.getBool(kEnabled, false);

  static Future<void> setEnabled(bool v) => Settings.setBool(kEnabled, v);

  static Future<String> phrase() async {
    final p = (await Settings.getString(kPhrase) ?? '').trim();
    return p.isEmpty ? defaultPhrases.first : p;
  }

  static Future<void> setPhrase(String v) =>
      Settings.setString(kPhrase, v.trim());

  static Future<int> countdown() async {
    final s = await Settings.getString(kCountdown);
    return int.tryParse(s ?? '') ?? defaultCountdown;
  }

  static Future<void> setCountdown(int v) =>
      Settings.setString(kCountdown, '$v');

  /// BCP-47-ish speech recogniser locale for the app's ACTIVE language, read
  /// from the SAME persisted 'locale' preference the main app writes
  /// (AppState.setLocale). The foreground-service isolate has no BuildContext,
  /// so it derives the locale here instead. Returns 'bn_BD' for Bengali, else
  /// 'en_US'. If the device lacks that pack the speech plugin falls back safely.
  static Future<String> speechLocaleId() async {
    final lc = (await Settings.getString('locale') ?? '').trim();
    return lc.startsWith('bn') ? 'bn_BD' : 'en_US';
  }

  /// Normalise a phrase for matching: lowercase, strip punctuation, collapse
  /// whitespace. Keeps Unicode letters/digits so Bangla speech also matches if
  /// a user ever sets a Bangla phrase (the matching is script-agnostic).
  static String normalize(String s) {
    final lowered = s.toLowerCase();
    final buf = StringBuffer();
    var lastSpace = false;
    for (final rune in lowered.runes) {
      final ch = String.fromCharCode(rune);
      final isSpace = ch.trim().isEmpty;
      final isPunct = RegExp(r'''[\.,!\?;:"'\-_/\\()\[\]{}]''').hasMatch(ch);
      if (isSpace || isPunct) {
        if (!lastSpace && buf.isNotEmpty) buf.write(' ');
        lastSpace = true;
      } else {
        buf.write(ch);
        lastSpace = false;
      }
    }
    return buf.toString().trim();
  }

  /// True when [heard] (a running speech transcript) contains the wake
  /// [phrase]. Matches on normalized-substring so trailing/leading words in a
  /// continuous transcript still trigger. An empty phrase never matches.
  static bool matches(String heard, String phrase) {
    final p = normalize(phrase);
    if (p.isEmpty) return false;
    final h = normalize(heard);
    if (h.isEmpty) return false;
    // Word-boundary-aware contains: surround with spaces so "help" inside
    // "helpful" does not match, but a phrase at either end still does.
    return ' $h '.contains(' $p ');
  }
}
