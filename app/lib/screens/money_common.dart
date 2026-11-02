import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Shared formatting + small UI helpers for the My Account (money) module.
/// Kept in one place so every money_*.dart screen renders Taka identically.

final _tk = NumberFormat('#,##,###.##', 'en');

/// Format a numeric value as Bangladeshi Taka, e.g. ৳1,23,456.78.
String tkFmt(dynamic v) {
  final d = dbl(v);
  return '৳${_tk.format(d)}';
}

/// Signed Taka, e.g. +৳500 / -৳500 (used in ledgers / deltas).
String tkSigned(dynamic v) {
  final d = dbl(v);
  final s = '৳${_tk.format(d.abs())}';
  if (d > 0) return '+$s';
  if (d < 0) return '-$s';
  return s;
}

const _bnZero = 0x09E6;

/// remhbud: digits in the UI language (Bangla digits in bn). No Bangla
/// literal here — the language gate keeps Bangla text in the ARB files.
String moneyLangDigits(String lang, Object v) {
  final s = v.toString();
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}

/// remhbud: [v] with the UI language's digits.
String moneyDigitsOf(BuildContext context, Object v) =>
    moneyLangDigits(Localizations.localeOf(context).languageCode, v);

/// remhbud: Taka in the UI digits — ৳1,23,456 in en, Bangla digits in bn.
/// Same grouping/decimals as [tkFmt]; use this for anything on screen.
String tkOf(BuildContext context, dynamic v) => moneyDigitsOf(context, tkFmt(v));

/// remhbud: "85%" in the UI digits.
String pctOf(BuildContext context, Object? p) =>
    moneyDigitsOf(context, '${(p is num ? p : num.tryParse('${p ?? 0}') ?? 0).round()}%');

/// remhbud: a typed amount -> plain ASCII ("৫,০০০" -> "5000"), so a Bangla
/// keyboard's digits are understood and the server always gets ASCII.
String moneyAscii(String? s) {
  final b = StringBuffer();
  for (final c in (s ?? '').trim().codeUnits) {
    if (c >= _bnZero && c <= _bnZero + 9) {
      b.writeCharCode(0x30 + c - _bnZero);
    } else if (c != 0x2C) {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

/// remhbud: lenient amount parse that also accepts Bangla digits/commas.
double moneyParse(String? s) => double.tryParse(moneyAscii(s)) ?? 0;

/// remhbud: "now" on the Asia/Dhaka wall clock (UTC+6, no DST), so month
/// boundaries match the server's (settings.TIME_ZONE) even when the phone's
/// own time zone is set elsewhere.
DateTime dhakaNow([DateTime? at]) {
  final u = (at ?? DateTime.now()).toUtc().add(const Duration(hours: 6));
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// remhbud: 'YYYY-MM' for a date.
String moneyMonthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// qa1: localized month for a server 'YYYY-MM' ("October 2026" / Bangla);
/// anything else is returned unchanged.
String moneyMonth(BuildContext context, dynamic ym) {
  final s = '${ym ?? ''}';
  final d = DateTime.tryParse(s.length == 7 ? '$s-01' : '');
  if (d == null) return s;
  return DateFormat.yMMMM(Localizations.localeOf(context).toLanguageTag()).format(d);
}

/// qa1: short localized month ("Oct" / Bangla) for chart axes.
String moneyMonthShort(BuildContext context, dynamic ym) {
  final s = '${ym ?? ''}';
  final d = DateTime.tryParse(s.length == 7 ? '$s-01' : '');
  if (d == null) return s;
  return DateFormat.MMM(Localizations.localeOf(context).toLanguageTag()).format(d);
}

/// qa1: localized day for a server 'YYYY-MM-DD' ("5 Oct 2026" / Bangla).
String moneyDay(BuildContext context, dynamic ymd) {
  final s = '${ymd ?? ''}';
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  return DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(d);
}

/// budget-remittance: the family-budget category KEYS (food, rent, …) that
/// Budget and Remittance writes into the shared Budget / expense rows show in
/// the UI language; anything the user typed is shown as typed.
String moneyCatLabel(AppLocalizations t, Object? raw) {
  final s = '${raw ?? ''}';
  // remhbud: a key typed in another case ("Food") or the server's bucket for
  // expenses with no category also shows in the UI language.
  return switch (s.trim().toLowerCase()) {
    'food' => t.rmtCatFood,
    'rent' => t.rmtCatRent,
    'education' => t.rmtCatEducation,
    'health' => t.rmtCatMedicine,
    'savings' => t.rmtCatSavings,
    'loan' => t.rmtCatLoan,
    'other' || 'uncategorized' => t.rmtCatOther,
    _ => s,
  };
}

/// Lenient double parse (handles strings, nulls, ints).
double dbl(dynamic v) => double.tryParse('${v ?? 0}') ?? 0;

/// Account-type -> localised label.
Map<String, String> accTypes(AppLocalizations t) => {
      'cash': t.moneyAccTypeCash,
      'bkash': t.moneyAccTypeBkash,
      'nagad': t.moneyAccTypeNagad,
      'rocket': t.moneyAccTypeRocket,
      'bank': t.moneyAccTypeBank,
      'card': t.moneyAccTypeCard,
      'mobile': t.moneyAccTypeBkash,
    };

/// Account-type -> icon.
IconData accIcon(String? type) {
  switch (type) {
    case 'bank':
      return Icons.account_balance_rounded;
    case 'card':
      return Icons.credit_card_rounded;
    case 'bkash':
    case 'nagad':
    case 'rocket':
    case 'mobile':
      return Icons.smartphone_rounded;
    default:
      return Icons.payments_rounded;
  }
}

/// A compact stat card used on the overview + report screens.
Widget statCard(BuildContext context, String label, String value, Color color,
    IconData icon) {
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Gap.xs),
          Expanded(
            // 2 lines: "Income This Month" must not become "Income This Mo…"
            child: Text(label,
                maxLines: 2,
                style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        // big amounts shrink to fit a half-width card instead of clipping
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              maxLines: 1,
              style: AType.titleLarge.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontFeatures: AFonts.tabular)),
        ),
      ]),
    ),
  );
}

/// A confirm-then-delete bottom sheet with an inline Undo snackbar.
/// Used for long-press delete across money lists so a mis-tap is recoverable.
Future<void> confirmDelete(BuildContext context, VoidCallback onConfirm) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showAppSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: Gap.md),
        ListTile(
          leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
          title: Text(t.moneyDeleteConfirm),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.cancel)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                  style: Brand.dangerButton(),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.delete)),
            ),
          ]),
        ),
      ]),
    ),
  );
  if (ok == true) {
    onConfirm();
    messenger.showSnackBar(SnackBar(content: Text(t.moneyDeleted)));
  }
}

/// A small coloured delta chip (up = red for expense, green otherwise).
Widget deltaChip(BuildContext context, double delta, {bool upIsBad = true}) {
  final up = delta > 0;
  final color = delta == 0
      ? Theme.of(context).colorScheme.onSurfaceVariant
      : (up == upIsBad ? Theme.of(context).colorScheme.error : AssistoTokens.of(context).success);
  return Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(
        delta == 0
            ? Icons.remove_rounded
            : up
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
        size: 13,
        color: color),
    Text(tkFmt(delta.abs()),
        style: AType.labelMedium.copyWith(
            color: color, fontFeatures: AFonts.tabular)),
  ]);
}
