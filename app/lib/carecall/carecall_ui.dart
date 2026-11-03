import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show localDigits;
import '../messaging/presence_label.dart' show clockLabel;
import 'carecall_plan.dart';

/// carecall — small shared pieces of the three Care Call screens.

String ccLang(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';

/// 'HH:MM' -> '9:00 am' (Bangla: day-period word + Bangla digits).
String ccTimeText(BuildContext context, String hhmm) {
  final m = ccMinutes(hhmm) ?? 540;
  return clockLabel(AppLocalizations.of(context), DateTime(2000, 1, 1, m ~/ 60, m % 60),
      lang: ccLang(context));
}

/// A server ISO time -> its Bangladesh clock ('9:02 am').
String ccIsoTimeText(BuildContext context, String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return '';
  final w = ccBdWall(d);
  return clockLabel(AppLocalizations.of(context), DateTime(2000, 1, 1, w.hour, w.minute),
      lang: ccLang(context));
}

String ccNum(BuildContext context, Object v) => localDigits('$v', ccLang(context));

/// Saturday-first week (Bangladesh) as server day numbers (0 = Monday).
const List<int> kCcWeek = [5, 6, 0, 1, 2, 3, 4];

String ccDayShort(AppLocalizations t, int d) => switch (d) {
      0 => t.ccDayMon,
      1 => t.ccDayTue,
      2 => t.ccDayWed,
      3 => t.ccDayThu,
      4 => t.ccDayFri,
      5 => t.ccDaySat,
      _ => t.ccDaySun,
    };

String ccRepeatText(BuildContext context, String repeat, List<int> days, String date) {
  final t = AppLocalizations.of(context);
  switch (repeat) {
    case 'once':
      final d = DateTime.tryParse(date);
      if (d == null) return t.ccRepeatOnce;
      final today = ccBdWall(DateTime.now());
      final t0 = DateTime(today.year, today.month, today.day);
      final diff = DateTime(d.year, d.month, d.day).difference(t0).inDays;
      if (diff == 0) return '${t.ccRepeatOnce} · ${t.ccOnceToday}';
      if (diff == 1) return '${t.ccRepeatOnce} · ${t.ccOnceTomorrow}';
      return '${t.ccRepeatOnce} · ${ccNum(context, '${d.day}/${d.month}')}';
    case 'days':
      final sel = [for (final d in kCcWeek) if (days.contains(d)) ccDayShort(t, d)];
      return sel.isEmpty ? t.ccRepeatDays : sel.join(', ');
    default:
      return t.ccRepeatDaily;
  }
}

/// The round first-letter avatar used on every Care Call screen.
class CcAvatar extends StatelessWidget {
  const CcAvatar({super.key, required this.initial, this.size = 44, this.icon});
  final String initial;
  final double size;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: s.primaryContainer),
        child: icon != null
            ? Icon(icon, color: s.onPrimaryContainer, size: size * 0.5)
            : Text(initial.isEmpty ? '?' : initial,
                style: TextStyle(
                    color: s.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.42)),
      ),
    );
  }
}

/// A labelled tappable "field" box (Who / Time / Repeat).
class CcField extends StatelessWidget {
  const CcField({super.key, required this.label, required this.child, this.onTap, this.semantics});
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Text(label, style: tt.labelLarge?.copyWith(color: s.onSurfaceVariant)),
      ),
      Semantics(
        button: onTap != null,
        label: semantics == null ? label : '$label: $semantics',
        excludeSemantics: semantics != null,
        child: Material(
          color: s.surfaceContainerHighest.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: s.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Align(alignment: AlignmentDirectional.centerStart, child: child),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
