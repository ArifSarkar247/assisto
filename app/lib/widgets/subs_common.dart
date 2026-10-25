import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Shared logic + small UI atoms for the advanced Subscriptions module.
///
/// Mirrors backend/core/logic/subscriptions.py so the client renders the same
/// smart views offline, straight off the list-endpoint shape. ALL money is
/// INTEGER POISHA (1 taka = 100 poisha) — never a float — so summing /
/// annualising / averaging never drifts. Digits render Bangla via code points
/// (no Bangla literal in source, keeping the language gate strict). Every
/// user-facing string comes from AppLocalizations.

// ---------------------------------------------------------------- cycles
// NOTE: backend Subscription.cycle is CharField(max_length=8). "quarterly" is
// 9 chars and will NOT persist — we send "quarter" (7) and treat both as the
// quarterly cycle. See .phaseB/up_subs_integration.md.
const kCycles = ['weekly', 'monthly', 'quarter', 'yearly', 'custom'];

String cycleWire(String c) => c == 'quarterly' ? 'quarter' : c;
String cycleNorm(String? c) => (c == 'quarterly') ? 'quarter' : (c ?? 'monthly');

String cycleLabel(AppLocalizations t, String? c) {
  switch (cycleNorm(c)) {
    case 'weekly':
      return t.subsCycleWeekly;
    case 'quarter':
      return t.subsCycleQuarterly;
    case 'yearly':
      return t.subsCycleYearly;
    case 'custom':
      return t.subsCycleCustom;
    case 'monthly':
    default:
      return t.subsCycleMonthly;
  }
}

// ---------------------------------------------------------------- money (poisha)

/// Parse a user-typed / API taka value to integer poisha (no float drift).
int takaToPoisha(String? input) {
  if (input == null) return 0;
  final cleaned = _ascii(input).replaceAll(RegExp(r'[^0-9.]'), '').trim();
  if (cleaned.isEmpty) return 0;
  final dot = cleaned.indexOf('.');
  if (dot < 0) return (int.tryParse(cleaned) ?? 0) * 100;
  final whole = int.tryParse(cleaned.substring(0, dot)) ?? 0;
  var frac = cleaned.substring(dot + 1).replaceAll('.', '');
  if (frac.length > 2) frac = frac.substring(0, 2);
  frac = frac.padRight(2, '0');
  return whole * 100 + (int.tryParse(frac) ?? 0);
}

int poishaOf(Map s) {
  if (s['amount_poisha'] != null) {
    return int.tryParse('${s['amount_poisha']}') ?? 0;
  }
  return takaToPoisha('${s['amount']}');
}

/// Per-year multiplier for a cycle (as a rational via integers, kept in double
/// only at the final display rounding — poisha math stays integer).
double _perYear(String cycle, int intervalDays) {
  switch (cycle) {
    case 'weekly':
      return 365 / 7;
    case 'quarter':
      return 4;
    case 'yearly':
      return 1;
    case 'custom':
      return intervalDays > 0 ? 365 / intervalDays : 12;
    case 'monthly':
    default:
      return 12;
  }
}

bool _live(Map s) => (s['status'] ?? 'active') == 'active';

int monthlyPoisha(Map s) {
  if (!_live(s)) return 0;
  final amt = poishaOf(s);
  final c = cycleNorm(s['cycle']);
  final iv = int.tryParse('${s['interval_days']}') ?? 30;
  return ((amt * _perYear(c, iv)) / 12).round();
}

int yearlyPoisha(Map s) {
  if (!_live(s)) return 0;
  final amt = poishaOf(s);
  final c = cycleNorm(s['cycle']);
  final iv = int.tryParse('${s['interval_days']}') ?? 30;
  return (amt * _perYear(c, iv)).round();
}

// ---------------------------------------------------------------- next-due roll

DateTime? parseDate(dynamic v) {
  if (v == null || v == '') return null;
  if (v is DateTime) return v;
  return DateTime.tryParse('$v'.length >= 10 ? '$v'.substring(0, 10) : '$v');
}

DateTime _addMonths(DateTime d, int n) {
  var m = d.month - 1 + n;
  final y = d.year + (m ~/ 12);
  m = m % 12 + 1;
  final dim = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day > dim ? dim : d.day);
}

DateTime advanceDue(DateTime d, String cycle, int intervalDays) {
  switch (cycle) {
    case 'weekly':
      return d.add(const Duration(days: 7));
    case 'custom':
      return d.add(Duration(days: intervalDays > 0 ? intervalDays : 30));
    case 'quarter':
      return _addMonths(d, 3);
    case 'yearly':
      return _addMonths(d, 12);
    case 'monthly':
    default:
      return _addMonths(d, 1);
  }
}

/// Roll next_due to the first cycle strictly after `today` (catches up misses).
String? rollNextDue(Map s, DateTime today) {
  var due = parseDate(s['next_due']);
  if (due == null || (s['status'] ?? 'active') == 'cancelled') {
    return s['next_due'] as String?;
  }
  final c = cycleNorm(s['cycle']);
  final iv = int.tryParse('${s['interval_days']}') ?? 30;
  var guard = 0;
  final t0 = DateTime(today.year, today.month, today.day);
  while (!due!.isAfter(t0) && guard < 600) {
    final nxt = advanceDue(due, c, iv);
    if (!nxt.isAfter(due)) break;
    due = nxt;
    guard++;
  }
  return _iso(due!);
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------- bn digits

String _ascii(String s) {
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final ch in s.runes) {
    if (ch >= bnZero && ch <= bnZero + 9) {
      b.write(ch - bnZero);
    } else {
      b.writeCharCode(ch);
    }
  }
  return b.toString();
}

String _toBn(String ascii, bool bn) {
  if (!bn) return ascii;
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final cu in ascii.codeUnits) {
    if (cu >= 0x30 && cu <= 0x39) {
      b.writeCharCode(bnZero + (cu - 0x30));
    } else {
      b.writeCharCode(cu);
    }
  }
  return b.toString();
}

/// Localised integer with thousands separators + locale digits.
String fmtInt(BuildContext context, int n) {
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  final neg = n < 0;
  var s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return (neg ? '-' : '') + _toBn(buf.toString(), bn);
}

/// The Bangladeshi taka sign (U+09F3), via code point so no Bangla-block
/// literal lives in source (keeps the language gate strict).
const _takaSign = '\u09F3';

/// Taka from integer poisha with the taka sign (no decimals for whole amounts).
String taka(BuildContext context, int poisha) {
  final whole = poisha ~/ 100;
  final frac = poisha % 100;
  final base = frac == 0
      ? fmtInt(context, whole)
      : '${fmtInt(context, whole)}.${_toBn(frac.toString().padLeft(2, '0'), Localizations.localeOf(context).languageCode == 'bn')}';
  return '$_takaSign$base';
}

// ---------------------------------------------------------------- catalogs

/// Category → (icon, seed colour). Keys are stable wire values.
const kCategories = [
  'streaming', 'internet', 'mobile', 'utility', 'fitness',
  'shopping', 'productivity', 'other',
];

IconData categoryIcon(String? c) {
  switch (c) {
    case 'streaming':
      return Icons.play_circle_outline_rounded;
    case 'internet':
      return Icons.wifi_rounded;
    case 'mobile':
      return Icons.smartphone_rounded;
    case 'utility':
      return Icons.bolt_rounded;
    case 'fitness':
      return Icons.fitness_center_rounded;
    case 'shopping':
      return Icons.shopping_bag_rounded;
    case 'productivity':
      return Icons.workspaces_outline;
    default:
      return Icons.subscriptions_rounded;
  }
}

String categoryLabel(AppLocalizations t, String? c) {
  switch (c) {
    case 'streaming':
      return t.subsCatStreaming;
    case 'internet':
      return t.subsCatInternet;
    case 'mobile':
      return t.subsCatMobile;
    case 'utility':
      return t.subsCatUtility;
    case 'fitness':
      return t.subsCatFitness;
    case 'shopping':
      return t.subsCatShopping;
    case 'productivity':
      return t.subsCatProductivity;
    default:
      return t.subsCatOther;
  }
}

const kPaymentMethods = ['bkash', 'nagad', 'rocket', 'card', 'bank', 'cash'];

String paymentLabel(AppLocalizations t, String? p) {
  switch (p) {
    case 'bkash':
      return t.subsPayBkash;
    case 'nagad':
      return t.subsPayNagad;
    case 'rocket':
      return t.subsPayRocket;
    case 'card':
      return t.subsPayCard;
    case 'bank':
      return t.subsPayBank;
    default:
      return t.subsPayCash;
  }
}

IconData paymentIcon(String? p) {
  switch (p) {
    case 'card':
      return Icons.credit_card_rounded;
    case 'bank':
      return Icons.account_balance_rounded;
    case 'cash':
      return Icons.payments_rounded;
    default:
      return Icons.account_balance_wallet_rounded;
  }
}

/// Deterministic brand-family colour for an icon chip (stable per name).
Color subColor(BuildContext context, String key) {
  const palette = [Brand.blue, Brand.cyan, Brand.purple, Brand.success, Brand.warning];
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

// ---------------------------------------------------------------- date helpers

int? daysUntil(dynamic due, DateTime today) {
  final d = parseDate(due);
  if (d == null) return null;
  final t0 = DateTime(today.year, today.month, today.day);
  final d0 = DateTime(d.year, d.month, d.day);
  return d0.difference(t0).inDays;
}

/// Human "in N days / today / overdue N days" — localised.
String dueRelative(BuildContext context, AppLocalizations t, dynamic due) {
  final n = daysUntil(due, DateTime.now());
  if (n == null) return t.subsNoDate;
  if (n == 0) return t.subsDueToday;
  if (n == -1) return t.shopQaOverdueOneDay; // not "1 days"
  if (n < 0) return t.subsOverdue(fmtInt(context, -n));
  if (n == 1) return t.subsDueTomorrow;
  return t.shopQaDueInDays(fmtInt(context, n));
}
