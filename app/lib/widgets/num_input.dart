// savesweep: THE shared number parser for every number field in Assisto.
//
// Owner bug 10 Nov: Save did nothing on Family accounting (fund goal 15000,
// expense 10000) because the phone keyboard typed Bangla digits and the old
// parser (int.tryParse / double.tryParse) returned null -> 0 -> the Save
// handler returned silently. Every number field must parse through here:
// test/save_sweep_static_test.dart fails on a raw tryParse of a controller's
// text in a form.
//
// Accepts: Latin 0-9, Bangla U+09E6..U+09EF, Arabic-Indic U+0660..U+0669 and
// Extended (Persian) U+06F0..U+06F9 digits; thousands commas (Latin ',',
// Arabic U+066C, full-width U+FF0C); Arabic decimal U+066B; taka signs
// (U+09F3 taka sign, Tk, BDT); spaces / NBSP; a leading +/-.
// No Bangla glyph literal lives in source (code points only).

import 'package:flutter/services.dart';

String _digitOf(int r) {
  if (r >= 0x09E6 && r <= 0x09EF) return '${r - 0x09E6}';
  if (r >= 0x0660 && r <= 0x0669) return '${r - 0x0660}';
  if (r >= 0x06F0 && r <= 0x06F9) return '${r - 0x06F0}';
  if (r >= 0xFF10 && r <= 0xFF19) return '${r - 0xFF10}';
  return String.fromCharCode(r);
}

/// Any-script digits -> Latin, grouping/currency removed, decimal -> '.'.
/// STRICT: returns '' when anything else is left (so "12abc" stays invalid
/// and the form shows its error, exactly like int.tryParse did for Latin).
String normalizeNumInput(String? input) {
  if (input == null) return '';
  final b = StringBuffer();
  for (final r in input.runes) {
    if (r == 0x066B) {
      b.write('.');
    } else if (r == 0x2212) {
      b.write('-'); // unicode minus
    } else {
      b.write(_digitOf(r));
    }
  }
  var s = b.toString().trim();
  // currency words / taka sign, grouping commas (Latin, Arabic, full-width),
  // spaces incl. NBSP / narrow NBSP, underscores
  // gap-money: no word boundary, so "Tk500" / "500tk" are read too (the
  // strict check below still refuses any other letters).
  s = s.replaceAll(RegExp(r'(bdt|taka|tk)\.?', caseSensitive: false), '');
  // gap-money: the Bangla word "taka" (code points, no glyph literal) and
  // the everyday Bangladeshi endings "500/-" and "500/=".
  s = s.replaceAll('\u099F\u09BE\u0995\u09BE', '');
  s = s.replaceAll(RegExp('[,\\u066C\\uFF0C\\u09F3\\s\\u00A0\\u202F_]'), '');
  s = s.replaceAll(RegExp(r'/[-=]$'), '');
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(s)) return '';
  if (s.startsWith('+')) s = s.substring(1);
  return s;
}

/// User-typed number -> double, or null when the field holds no number.
double? parseNumInput(String? input) {
  final s = normalizeNumInput(input);
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// User-typed whole number -> int, or null (also null for "1.5", as
/// int.tryParse was; "1,200" and Bangla digits are fine).
int? parseIntInput(String? input) {
  final s = normalizeNumInput(input);
  if (s.isEmpty) return null;
  final whole = s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  return int.tryParse(whole);
}

/// User-typed taka -> INTEGER poisha (half-up on the paisa, no binary float),
/// or null when the field holds no number.
int? takaToPoishaInput(String? input) {
  var s = normalizeNumInput(input);
  if (s.isEmpty) return null;
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final dot = s.indexOf('.');
  var whole = dot >= 0 ? s.substring(0, dot) : s;
  var frac = dot >= 0 ? s.substring(dot + 1) : '';
  if (whole.isEmpty) whole = '0';
  frac = '${frac}000'.substring(0, 3);
  final taka = int.tryParse(whole);
  final milli = int.tryParse(frac);
  if (taka == null || milli == null) return null;
  var p = taka * 100 + milli ~/ 10;
  if (milli % 10 >= 5) p += 1;
  return neg ? -p : p;
}

/// Input formatter: converts Bangla / Arabic-Indic / full-width digits to
/// Latin AS THE USER TYPES. Put it FIRST, before any digits-only filter:
/// `FilteringTextInputFormatter.digitsOnly` alone silently drops every Bangla
/// digit (the field stays empty and Save looks dead).
class LatinDigitsFormatter extends TextInputFormatter {
  const LatinDigitsFormatter();
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final t = newValue.text;
    var changed = false;
    final b = StringBuffer();
    for (final r in t.runes) {
      final d = _digitOf(r);
      if (d.length == 1 && d.codeUnitAt(0) != r) changed = true;
      b.write(d);
    }
    if (!changed) return newValue;
    final out = b.toString();
    // every mapped digit is one UTF-16 unit before and after: offsets hold
    return newValue.copyWith(text: out);
  }
}
