import 'package:flutter/material.dart';
import '../../theme.dart';

/// Shared helpers for the Business v2 screens.
///
/// The server's pure khata/cashbox logic returns pre-localized `{bn,en}` pairs
/// for every dynamic string (amounts, balance status, tagada messages …). We
/// NEVER re-translate those — we just pick the side that matches the active
/// locale. Static labels come from ARB via AppLocalizations.

/// Read the active-locale side of a `{bn, en}` pair the pure layer returned.
/// Accepts a Map, a plain String (already resolved), or null.
String pair(BuildContext context, dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return _bnMoneyDigits(context, value);
  if (value is Map) {
    final lang = Localizations.localeOf(context).languageCode;
    final v = value[lang] ?? value['bn'] ?? value['en'];
    return _bnMoneyDigits(context, v?.toString() ?? fallback);
  }
  return value.toString();
}

/// qa1: the server's khata/cashbox `bn` amounts come as "৳1,500" (Latin
/// digits) while the rest of the Bangla UI writes Bangla digits. Only strings
/// that carry a taka sign are touched — phone numbers, codes and ids are not.
String _bnMoneyDigits(BuildContext context, String s) {
  if (!s.contains('৳') || Localizations.localeOf(context).languageCode != 'bn') return s;
  return s.replaceAllMapped(
      RegExp('[0-9]'), (m) => String.fromCharCode(0x09E6 + int.parse(m[0]!)));
}

/// Parse a user-typed taka amount (Bangla or Latin digits, optional thousands
/// separators and currency sign) to integer poisha. Returns null if nothing
/// parseable.
int? takaToPoisha(String input) {
  final cleaned = _normalizeDigits(input)
      .replaceAll(',', '')
      .replaceAll('৳', '')
      .replaceAll(RegExp(r'[^0-9.]'), '')
      .trim();
  if (cleaned.isEmpty) return null;
  final taka = double.tryParse(cleaned);
  if (taka == null) return null;
  return (taka * 100).round();
}

/// Plain-taka display for amounts the server did NOT pre-format (e.g. a value
/// the user just typed, before the round-trip). Prefer server `_display` pairs.
String poishaToTaka(int poisha) {
  final taka = poisha / 100;
  final whole = taka == taka.truncateToDouble();
  return '৳${whole ? taka.toStringAsFixed(0) : taka.toStringAsFixed(2)}';
}

String _normalizeDigits(String s) {
  // Bangla-Bengali digits occupy the contiguous block U+09E6 (zero) .. U+09EF
  // (nine); map each to its Latin digit. Built from code points so no Bangla
  // literal lives in source (keeps the language gate strict).
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final ch in s.runes) {
    if (ch >= bnZero && ch <= bnZero + 9) {
      b.write(ch - bnZero);
    } else {
      b.write(String.fromCharCode(ch));
    }
  }
  return b.toString();
}

/// A soft brand-gradient header band used at the top of the hub / section
/// screens (chat-first, matches login/splash hero surfaces).
class BrandBand extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const BrandBand(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(Gap.lg)});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: const BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: child,
        ),
      ),
    );
  }
}
