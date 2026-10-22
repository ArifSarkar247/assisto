import 'dart:convert';

import '../crypto/e2e.dart' show Sha256;

/// sc1 — privacy scrubbing for crash / error reports (Crashlytics AND our own
/// /client/crash-report). Pure Dart, no plugins, unit-tested.
///
/// Rules (owner privacy rule: no message content or personal data in any
/// report):
///   * anything in quotes ("…", '…', «…») is dropped — exception messages
///     quote the offending input (FormatException, JSON errors, ...);
///   * e-mail addresses, URLs (whole URL incl. query), phone-number-like digit
///     runs (7+ digits, with or without +, spaces or dashes) and any other
///     number of 5+ digits (ids, amounts, OTPs) are replaced by placeholders;
///   * file paths are cut to their folder shape: a path under the app's data
///     dir or external storage becomes `<path>` (file names can be names of
///     people / photos);
///   * long opaque tokens (hex/base64 ≥ 20 chars: auth tokens, keys) become
///     `<token>`;
///   * the result is capped at [maxMessage] characters.
/// Stack frames keep only code locations (package/dart URIs + line), which
/// carry no user data.
class CrashScrub {
  CrashScrub._();

  static const int maxMessage = 300;
  static const int maxFrames = 8;

  static final _quoted = RegExp(r'''"[^"\n]*"|'[^'\n]*'|«[^»\n]*»|“[^”\n]*”''');
  static final _email = RegExp(r'[\w.+\-]+@[\w\-]+(\.[\w\-]+)+');
  static final _url = RegExp(r'\b(?:https?|wss?|ftp|content|file)://\S+',
      caseSensitive: false);
  static final _phone = RegExp(r'(?:\+?\d[\d \-]{5,}\d)');
  static final _bigNum = RegExp(r'\d{5,}');
  static final _path = RegExp(
      r'(?:/(?:data|storage|sdcard|mnt|private|var|Users|home)(?:/[^\s:,;)\]]+)+)');
  static final _token = RegExp(r'\b[A-Za-z0-9_\-+/=]{20,}\b');
  static final _ws = RegExp(r'\s+');

  /// Scrub one exception message.
  static String message(String raw) {
    var s = raw;
    s = s.replaceAll(_quoted, '"…"');
    s = s.replaceAll(_url, '<url>');
    s = s.replaceAll(_email, '<email>');
    s = s.replaceAll(_path, '<path>');
    s = s.replaceAll(_token, '<token>');
    s = s.replaceAll(_phone, '<num>');
    s = s.replaceAll(_bigNum, '<num>');
    s = s.replaceAll(_ws, ' ').trim();
    if (s.length > maxMessage) s = '${s.substring(0, maxMessage)}…';
    return s;
  }

  static final _frame = RegExp(
      r'#\d+\s+(\S.*?)\s+\(((?:package|dart|org-dartlang-sdk):[^)]*)\)');

  /// Top code frames of a Dart stack trace: "Class.method (package:x/y.dart:12)".
  /// Frames without a code URI (native, unparsed) are dropped.
  static List<String> frames(StackTrace? st, {int max = maxFrames}) {
    if (st == null) return const [];
    final out = <String>[];
    for (final line in st.toString().split('\n')) {
      final m = _frame.firstMatch(line);
      if (m == null) continue;
      // the reporting helpers themselves are never the interesting frame
      final uri = m.group(2)!;
      if (uri.contains('/diag/non_fatal.dart') ||
          uri.contains('/services/error_report.dart')) {
        continue;
      }
      final fn = m.group(1)!.replaceAll(_quoted, '"…"');
      // drop the column, keep file:line
      final loc = m.group(2)!.replaceFirstMapped(
          RegExp(r':(\d+):\d+$'), (mm) => ':${mm.group(1)}');
      out.add('${fn.length > 80 ? fn.substring(0, 80) : fn} ($loc)');
      if (out.length >= max) break;
    }
    return out;
  }

  /// Error type without generics/values, e.g. "PlatformException".
  static String errorType(Object error) {
    final t = '${error.runtimeType}';
    final i = t.indexOf('<');
    return (i > 0 ? t.substring(0, i) : t).replaceAll(RegExp(r'[^\w.$]'), '');
  }

  /// Stable grouping key: error type + the first 3 frames WITHOUT line
  /// numbers (a rebuild that shifts lines keeps the same group).
  static String fingerprint(String type, List<String> frames) {
    final top = frames
        .take(3)
        .map((f) => f.replaceAll(RegExp(r':\d+\)$'), ')'))
        .join('|');
    final h = Sha256.hash(utf8.encode('$type|$top'));
    return h.take(10).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Opaque, non-reversible user tag (Crashlytics user identifier). The
  /// server never needs it to match — it hashes the real id itself.
  static String userHash(Object userId) {
    final h = Sha256.hash(utf8.encode('assisto-crash-v1:$userId'));
    return h.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// The error object handed to Crashlytics: its toString() is the SCRUBBED
/// message, so Crashlytics never receives the raw text.
class ScrubbedError implements Exception {
  ScrubbedError(this.type, this.message);
  final String type;
  final String message;
  @override
  String toString() => message.isEmpty ? type : '$type: $message';
}
