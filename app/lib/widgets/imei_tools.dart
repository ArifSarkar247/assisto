/// Pure-Dart IMEI validation + comparison helpers for the anti-theft
/// "tamper awareness" flow. No Flutter, no I/O — deterministic and safe to run
/// entirely on-device.
///
/// HONESTY: these checks catch an IMEI that is *structurally* wrong (bad
/// check-digit) or *inconsistent* across sources (dialer vs box vs tray). They
/// CANNOT prove an IMEI is genuine — a re-flashed IMEI that was copied to every
/// label will still pass. Treat a pass as "no red flag found here", never as
/// "verified". The brand/model (TAC) cross-check is the only thing that can
/// hint at a re-flash, and that depends on a real data source (see
/// ApiClient.tacLookup), which is honestly gated.
library;

/// Keep only the ASCII digits of [s]. Spaces, dashes and the IMEI's optional
/// check-digit separator are all dropped.
String imeiDigits(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    if (c >= 0x30 && c <= 0x39) b.writeCharCode(c);
  }
  return b.toString();
}

/// Standard Luhn (mod-10) check-digit validation for a 15-digit IMEI.
///
/// Non-digits are stripped first; the result must be EXACTLY 15 digits. Returns
/// false for any other length so a 14-digit IMEISV or a typo is rejected.
bool luhnValid(String imei) {
  final d = imeiDigits(imei);
  if (d.length != 15) return false;
  var sum = 0;
  // Double every second digit counting from the right (i.e. the even-indexed
  // digits from the left for a 15-digit string).
  for (var i = 0; i < d.length; i++) {
    var n = d.codeUnitAt(i) - 0x30;
    final fromRight = d.length - 1 - i;
    if (fromRight % 2 == 1) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  return sum % 10 == 0;
}

/// The 8-digit Type Allocation Code (brand/model prefix) of a 15-digit IMEI,
/// or null when the input is not a 15-digit IMEI.
String? tac(String imei) {
  final d = imeiDigits(imei);
  if (d.length != 15) return null;
  return d.substring(0, 8);
}

/// True only when every NON-EMPTY entry in [imeis] normalises to the same digit
/// string. Empty / whitespace-only entries are ignored (fields are optional).
///
/// With fewer than two non-empty values there is nothing to contradict, so this
/// returns true (no mismatch) — the caller decides whether that's "enough"
/// sources to be meaningful.
bool imeisMatch(List<String> imeis) {
  String? first;
  for (final raw in imeis) {
    final d = imeiDigits(raw);
    if (d.isEmpty) continue;
    if (first == null) {
      first = d;
    } else if (d != first) {
      return false;
    }
  }
  return true;
}
