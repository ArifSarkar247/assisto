import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

/// Shared helpers for the advanced Finance tools.
///
/// All compute is CLIENT-SIDE and offline — the calculators are pure math over
/// numbers the user types, so there is no network round-trip and no invented
/// data (FX rates, bullion prices, profit rates are all user inputs). The math
/// mirrors `backend/core/finance.py` byte-for-byte so a future AI/voice flow
/// on the server returns identical numbers.
///
/// LANGUAGE GATE: this file contains ZERO Bangla literals. User-visible text
/// comes only from AppLocalizations. Bangla digits are accepted on INPUT by
/// mapping their Unicode code points (U+09E6..U+09EF) — no Bangla glyph in
/// source.

/// Map Bangla-Bengali digits to Latin so the parser accepts either. Built from
/// code points (U+09E6 = zero) so no Bangla literal lives in source.
String normalizeDigits(String s) {
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

/// Bengali taka sign (U+09F3), built from its code point so no Bangla-block
/// glyph literal lives in source.
final String takaSign = String.fromCharCode(0x09F3);

/// Parse a user-typed number (Bangla or Latin digits, optional thousands
/// separators, taka sign, spaces). Returns null if nothing parseable.
double? parseNum(String input) {
  final cleaned = normalizeDigits(input)
      .replaceAll(',', '')
      .replaceAll(takaSign, '')
      .replaceAll(RegExp(r'[^0-9.\-]'), '')
      .trim();
  if (cleaned.isEmpty || cleaned == '-' || cleaned == '.') return null;
  return double.tryParse(cleaned);
}

/// Taka display with thousands grouping. Whole numbers show no decimals.
String fmtTaka(double v) => '$takaSign${_group(v)}';

/// Plain grouped number (no currency sign) — for units, percentages etc.
String fmtNum(double v) => _group(v);

String _group(double v) {
  final neg = v < 0;
  final abs = v.abs();
  final whole = abs == abs.truncateToDouble();
  final s = whole ? abs.toStringAsFixed(0) : abs.toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0];
  // Indian/BD grouping: last 3 digits, then pairs.
  final buf = StringBuffer();
  final digits = intPart.split('');
  final n = digits.length;
  for (var i = 0; i < n; i++) {
    final fromRight = n - i;
    if (i != 0 &&
        ((fromRight == 3) || (fromRight > 3 && (fromRight - 3) % 2 == 0))) {
      buf.write(',');
    }
    buf.write(digits[i]);
  }
  final grouped = buf.toString();
  final dec = parts.length > 1 ? '.${parts[1]}' : '';
  return '${neg ? '-' : ''}$grouped$dec';
}

/// Input formatter that permits Latin + Bangla digits, one dot, optional minus.
class FinanceDigitsFormatter extends TextInputFormatter {
  final bool allowDecimal;
  final bool allowNegative;
  const FinanceDigitsFormatter(
      {this.allowDecimal = true, this.allowNegative = false});
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final norm = normalizeDigits(newValue.text);
    final pattern = StringBuffer('[0-9');
    if (allowDecimal) pattern.write('.');
    if (allowNegative) pattern.write('\\-');
    pattern.write(']');
    final kept = norm.split('').where((c) {
      return RegExp(pattern.toString()).hasMatch(c);
    }).join();
    if (kept == newValue.text) return newValue;
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}

/// A labelled numeric input used across every calculator.
class FinanceField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool allowDecimal;
  final bool allowNegative;
  final IconData? icon;
  final String? suffix;
  const FinanceField({
    super.key,
    required this.controller,
    required this.label,
    this.allowDecimal = true,
    this.allowNegative = false,
    this.icon,
    this.suffix,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(
            decimal: allowDecimal, signed: allowNegative),
        inputFormatters: [
          FinanceDigitsFormatter(
              allowDecimal: allowDecimal, allowNegative: allowNegative),
        ],
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          suffixText: suffix,
        ),
      ),
    );
  }
}

/// A single result row (label left, bold value right).
class FinanceResultRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasise;
  final Color? valueColor;
  const FinanceResultRow(this.label, this.value,
      {super.key, this.emphasise = false, this.valueColor});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: emphasise ? FontWeight.w700 : FontWeight.w500)),
          ),
          const SizedBox(width: Gap.md),
          Text(value,
              style: TextStyle(
                  fontSize: emphasise ? 20 : 16,
                  fontWeight: emphasise ? FontWeight.w800 : FontWeight.w700,
                  color: valueColor ?? scheme.onSurface)),
        ],
      ),
    );
  }
}

/// The result card: breakdown rows + a short bn/en explanation of the math.
class FinanceResultCard extends StatelessWidget {
  final List<Widget> rows;
  final String noteLabel;
  final String explanation;
  final VoidCallback onShare;
  final String shareLabel;
  final Widget? extra; // e.g. amortization table toggle
  const FinanceResultCard({
    super.key,
    required this.rows,
    required this.noteLabel,
    required this.explanation,
    required this.onShare,
    required this.shareLabel,
    this.extra,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...rows,
            if (extra != null) ...[const SizedBox(height: Gap.sm), extra!],
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline_rounded,
                      size: 18, color: scheme.onSecondaryContainer),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style.copyWith(
                            height: 1.4, color: scheme.onSecondaryContainer),
                        children: [
                          TextSpan(
                              text: '$noteLabel: ',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          TextSpan(text: explanation),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.md),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(shareLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline validation / error banner.
class FinanceErrorBanner extends StatelessWidget {
  final String message;
  const FinanceErrorBanner(this.message, {super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(message,
                style: TextStyle(color: scheme.onErrorContainer))),
      ]),
    );
  }
}
