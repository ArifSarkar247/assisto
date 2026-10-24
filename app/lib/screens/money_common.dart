import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

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
      return Icons.account_balance_outlined;
    case 'card':
      return Icons.credit_card_outlined;
    case 'bkash':
    case 'nagad':
    case 'rocket':
    case 'mobile':
      return Icons.smartphone_outlined;
    default:
      return Icons.payments_outlined;
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
  final ok = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: Gap.md),
        ListTile(
          leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
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
            ? Icons.remove
            : up
                ? Icons.arrow_upward
                : Icons.arrow_downward,
        size: 13,
        color: color),
    Text(tkFmt(delta.abs()),
        style: AType.labelMedium.copyWith(
            color: color, fontFeatures: AFonts.tabular)),
  ]);
}
