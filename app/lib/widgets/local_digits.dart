import 'package:flutter/widgets.dart';

/// lifebar: strict-language digits. In a Bangla UI every ASCII digit 0-9 is
/// shown as its Bangla digit (U+09E6..U+09EF, built from code points so no
/// Bangla literal lives in Dart source); English stays as-is.
String toLocalDigits(String s, bool bn) {
  if (!bn) return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c);
  }
  return b.toString();
}

/// [v] rendered in the app language's digits.
String ld(BuildContext context, Object? v) =>
    toLocalDigits('${v ?? ''}', Localizations.localeOf(context).languageCode == 'bn');
