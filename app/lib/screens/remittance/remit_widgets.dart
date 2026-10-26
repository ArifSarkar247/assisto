import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/bn_day_periods.dart' show appDateLocale;
import 'remit_source.dart';

/// budget-remittance shared pieces: money / date formatting in the UI
/// language (Bangla digits in bn), the labels of channels, categories,
/// relations and currencies, the 30-second guide and honest state views.

const _bnZero = 0x09E6;

String rmLang(BuildContext context) => Localizations.localeOf(context).languageCode;

/// Digits in the UI language (Bangla digits in bn). No Bangla literal here:
/// the language gate keeps Bangla text in the ARB files only.
String rmDigits(String lang, Object v) {
  final s = v.toString();
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}

final _grp = NumberFormat('#,##,##0.##', 'en');

/// ৳1,23,456 (Indian grouping) in the UI digits.
String rmTaka(BuildContext context, Object? v) {
  final n = rmNum(v);
  final s = '\u09F3${rmDigits(rmLang(context), _grp.format(n.abs()))}';
  return n < 0 ? '-$s' : s;
}

/// A plain number (rate, foreign amount) in the UI digits.
String rmNumText(BuildContext context, Object? v) => rmDigits(rmLang(context), _grp.format(rmNum(v)));

String rmDay(BuildContext context, String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return DateFormat('d MMM yyyy', appDateLocale(context)).format(d);
}

String rmMonthLabel(BuildContext context, String month) {
  final d = DateTime.tryParse('$month-01');
  if (d == null) return month;
  return DateFormat.yMMMM(appDateLocale(context)).format(d);
}

String rmShortMonth(BuildContext context, int m) => DateFormat.MMM(appDateLocale(context)).format(DateTime(2026, m));

String rmChannel(AppLocalizations t, String c) => switch (c) {
  'bank' => t.rmtChBank,
  'bkash' => t.rmtChBkash,
  'nagad' => t.rmtChNagad,
  'rocket' => t.rmtChRocket,
  'western_union' => t.rmtChWesternUnion,
  'moneygram' => t.rmtChMoneygram,
  _ => t.rmtChOther,
};

IconData rmChannelIcon(String c) => switch (c) {
  'bank' => Icons.account_balance_rounded,
  'bkash' || 'nagad' || 'rocket' => Icons.smartphone_rounded,
  'western_union' || 'moneygram' => Icons.public_rounded,
  _ => Icons.payments_rounded,
};

const kRmCategories = ['food', 'rent', 'education', 'health', 'savings', 'loan', 'other'];

String rmCategory(AppLocalizations t, String c) => switch (c) {
  'food' => t.rmtCatFood,
  'rent' => t.rmtCatRent,
  'education' => t.rmtCatEducation,
  'health' => t.rmtCatMedicine,
  'savings' => t.rmtCatSavings,
  'loan' => t.rmtCatLoan,
  _ => t.rmtCatOther,
};

IconData rmCategoryIcon(String c) => switch (c) {
  'food' => Icons.rice_bowl_outlined,
  'rent' => Icons.house_outlined,
  'education' => Icons.school_outlined,
  'health' => Icons.medication_outlined,
  'savings' => Icons.savings_outlined,
  'loan' => Icons.request_quote_outlined,
  _ => Icons.category_outlined,
};

String rmRelation(AppLocalizations t, String r) => switch (r) {
  'brother' => t.rmtRelBrother,
  'father' => t.rmtRelFather,
  'mother' => t.rmtRelMother,
  'husband' => t.rmtRelHusband,
  'wife' => t.rmtRelWife,
  'son' => t.rmtRelSon,
  'daughter' => t.rmtRelDaughter,
  'sister' => t.rmtRelSister,
  'uncle' => t.rmtRelUncle,
  'aunt' => t.rmtRelAunt,
  _ => r,
};

const kRmCurrencies = [
  'BDT', 'SAR', 'AED', 'QAR', 'KWD', 'OMR', 'BHD', 'MYR', 'SGD', 'USD', //
  'GBP', 'EUR', 'JPY', 'KRW', 'AUD', 'CAD',
];

String rmCurrency(AppLocalizations t, String c) => switch (c) {
  'BDT' => t.rmtCurBDT,
  'SAR' => t.rmtCurSAR,
  'AED' => t.rmtCurAED,
  'QAR' => t.rmtCurQAR,
  'KWD' => t.rmtCurKWD,
  'OMR' => t.rmtCurOMR,
  'BHD' => t.rmtCurBHD,
  'MYR' => t.rmtCurMYR,
  'SGD' => t.rmtCurSGD,
  'USD' => t.rmtCurUSD,
  'GBP' => t.rmtCurGBP,
  'EUR' => t.rmtCurEUR,
  'JPY' => t.rmtCurJPY,
  'KRW' => t.rmtCurKRW,
  'AUD' => t.rmtCurAUD,
  'CAD' => t.rmtCurCAD,
  _ => c,
};

/// The 30-second guide: three steps, then "Got it".
class RemitGuideCard extends StatelessWidget {
  final VoidCallback? onClose;
  const RemitGuideCard({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: scheme.primaryContainer,
            child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xxs),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    );
    return Card(
      key: const ValueKey('rmt_guide'),
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 14, Gap.lg, Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text(t.rmtGuideTitle, style: Theme.of(context).textTheme.titleMedium)),
            const SizedBox(height: Gap.xs + 2),
            step(Icons.record_voice_over_outlined, t.rmtGuide1Title, t.rmtGuide1Body),
            step(Icons.pie_chart_outline_rounded, t.rmtGuide2Title, t.rmtGuide2Body),
            step(Icons.ios_share_rounded, t.rmtGuide3Title, t.rmtGuide3Body),
            const SizedBox(height: Gap.xs),
            Text(t.rmtGuidePrivacy, style: Theme.of(context).textTheme.bodySmall),
            if (onClose != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: onClose,
                  child: Text(t.rmtGotIt),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Honest full-screen state: hidden / offline / error.
class RmMessage extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const RmMessage({super.key, required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Gap.xxl),
      children: [
        const SizedBox(height: Gap.xl),
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: Gap.lg),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(body, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 20), Center(child: action!)],
      ],
    );
  }
}

Widget rmErrorView(BuildContext context, Object e, VoidCallback retry) {
  final t = AppLocalizations.of(context);
  final btn = FilledButton(
    style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
    onPressed: retry,
    child: Text(t.rmtRetry),
  );
  if (rmStatus(e) == 403) {
    return RmMessage(icon: Icons.lock_clock_outlined, title: t.rmtOffTitle, body: t.rmtOffBody);
  }
  if (rmOffline(e)) {
    return RmMessage(icon: Icons.wifi_off_rounded, title: t.rmtOfflineTitle, body: t.rmtOfflineBody, action: btn);
  }
  return RmMessage(
    icon: Icons.cloud_off_rounded,
    title: t.rmtErrorTitle,
    body: rmError(e) ?? t.rmtErrorBody,
    action: btn,
  );
}

/// A titled card section.
class RmSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  const RmSection({super.key, required this.title, required this.children, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Gap.sm,
              children: [
                Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: Gap.sm),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// One label + value pair that wraps at large text instead of clipping.
class RmStat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const RmStat(this.label, this.value, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final muted = AssistoTokens.of(context).textMuted;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700, color: color, fontFeatures: AFonts.tabular),
          ),
        ],
      ),
    );
  }
}

/// A small coloured pill.
class RmChip extends StatelessWidget {
  final String text;
  final Color bg, fg;
  const RmChip(this.text, {super.key, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm + 2, vertical: Gap.xs),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
    child: Text(
      text,
      style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13),
    ),
  );
}
