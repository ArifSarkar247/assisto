/// remmeter — PURE prepaid-meter helpers (no Flutter). Mirrors
/// backend/core/logic/prepaid_meter.py (UTILITIES, validate_meter_number,
/// extract_tokens, alert_days). Tested in test/remmeter_meter_test.dart.
///
/// Honesty rules:
///  * We do NOT know each company's official meter-number format, so a
///    number is only checked for "digits, 6–20 long" and the form says so.
///  * Wallet (bKash / Nagad) Pay Bill steps are shown only where we verified
///    the wallet lists that company's PREPAID biller; otherwise the sheet
///    says "check the wallet's Pay Bill list". No undocumented deep links:
///    we open the wallet app itself and copy the meter number first.
///  * Prepaid GAS meters use a smart card: bKash says a prepaid gas card
///    payment through Pay Bill does NOT reach the meter, so gas shows no
///    wallet path at all — vending point only.
library;

class Utility {
  const Utility(this.id, this.kind,
      {this.bkash = false, this.nagad = false, this.hotline = ''});
  final String id;

  /// electricity | gas | '' (other)
  final String kind;

  /// Verified: the wallet's Pay Bill lists this company's prepaid biller.
  final bool bkash;
  final bool nagad;
  final String hotline;
}

const List<Utility> kUtilities = [
  Utility('desco', 'electricity', bkash: true, nagad: true, hotline: '16120'),
  Utility('dpdc', 'electricity', bkash: true, hotline: '16116'),
  Utility('nesco', 'electricity', bkash: true, hotline: '16603'),
  Utility('wzpdcl', 'electricity', bkash: true, hotline: '16117'),
  Utility('breb', 'electricity', bkash: true, nagad: true),
  Utility('bpdb', 'electricity', bkash: true),
  Utility('titas', 'gas'),
  Utility('karnaphuli', 'gas'),
  Utility('other', ''),
];

Utility? utilityById(String? id) {
  for (final u in kUtilities) {
    if (u.id == id) return u;
  }
  return null;
}

List<Utility> utilitiesFor(String kind) =>
    [for (final u in kUtilities) if (u.kind == kind || u.kind.isEmpty) u];

const String kBkashPackage = 'com.bKash.customerapp';
const String kNagadPackage = 'com.konasl.nagad';
const String kBkashUssd = '*247#';
const String kNagadUssd = '*167#';

/// Bangla digits -> ASCII; spaces / dashes / dots dropped.
String normalizeNumber(String? v) {
  final b = StringBuffer();
  for (final r in (v ?? '').runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + r - 0x09E6);
    } else if (r == 0x20 || r == 0x2D || r == 0x5F || r == 0x2E || r == 0x09) {
      continue;
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// null = OK (or empty — the field is optional); otherwise a problem code:
/// `meter_digits_only` | `meter_length`.
String? meterNumberProblem(String? number) {
  final n = normalizeNumber(number);
  if (n.isEmpty) return null;
  if (!RegExp(r'^[0-9]+$').hasMatch(n)) return 'meter_digits_only';
  if (n.length < 6 || n.length > 20) return 'meter_length';
  return null;
}

/// Every 20-digit STS token in a pasted SMS (groups split by spaces or
/// dashes are joined; Bangla digits allowed). Tariff changes can add
/// key-change tokens, so all are returned in order.
List<String> extractTokens(String? text) {
  // Split into chunks on spaces / dashes / newlines; a chunk that is all
  // digits joins its neighbours (a token printed as 4-4-4-4-4); a chunk with
  // letters ("KCT1", "Tk500") breaks the run. Inside each run, consecutive
  // chunks adding up to EXACTLY 20 digits form a token.
  final s = normalizeDigitsOnly(text ?? '');
  final out = <String>[];
  final runs = <List<String>>[[]];
  for (final chunk in s.split(RegExp(r'[\s\-]+'))) {
    final c = chunk.replaceAll(RegExp(r'^[^0-9A-Za-z]+|[^0-9A-Za-z]+$'), '');
    if (c.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(c)) {
      runs.last.add(c);
      // trailing punctuation ("7890.") ends the run after this chunk
      if (chunk.endsWith('.') || chunk.endsWith(',')) runs.add([]);
    } else {
      runs.add([]);
    }
  }
  for (final run in runs) {
    var i = 0;
    while (i < run.length) {
      var acc = '';
      var j = i;
      while (j < run.length && acc.length < 20) {
        acc += run[j];
        j++;
      }
      if (acc.length >= 20 && acc.length % 20 == 0 &&
          (j - i == 1 || acc.length == 20)) {
        for (var k = 0; k < acc.length; k += 20) {
          out.add(acc.substring(k, k + 20));
        }
        i = j;
      } else {
        i++;
      }
    }
  }
  return out;
}

/// Bangla digits -> ASCII, everything else kept.
String normalizeDigitsOnly(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x09E6 && r <= 0x09EF ? 0x30 + r - 0x09E6 : r);
  }
  return b.toString();
}

bool validToken(String? t) {
  final n = normalizeNumber(t);
  return n.length == 20 && RegExp(r'^[0-9]+$').hasMatch(n);
}

/// "1234 5678 9012 3456 7890" for display / reading out.
String groupToken(String t) {
  final n = normalizeNumber(t);
  final parts = <String>[];
  for (var i = 0; i < n.length; i += 4) {
    parts.add(n.substring(i, i + 4 > n.length ? n.length : i + 4));
  }
  return parts.join(' ');
}

const int kAlertDaysDefault = 3;

int alertDaysOf(Map<String, dynamic> meter) {
  final v = meter['alert_days'];
  final d = v is int ? v : int.tryParse('${v ?? ''}') ?? kAlertDaysDefault;
  return d < 1 ? 1 : (d > 7 ? 7 : d);
}

bool alertsOn(Map<String, dynamic> meter) => meter['alerts'] != false;
