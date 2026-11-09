// designv2 — Design System V2 feedback pieces: empty state with drawn
// illustration, skeleton loader, toast, offline strip (look only — the
// offline1st lane owns behaviour), paywall card (look only — the buyinside
// lane owns logic), sheet header (sheets open via showAppSheet).
import 'package:flutter/material.dart';

import '../theme.dart';
import 'ds_controls.dart';
import 'ds_surfaces.dart';

/// Empty state: illustration + benefit line + big button + how-to steps.
class DsEmptyState extends StatelessWidget {
  const DsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.benefit,
    this.actionLabel,
    this.onAction,
    this.howTo = const [],
    this.danger = false,
    this.actionKey,
  });

  final IconData icon;
  final String title;
  final Key? actionKey;
  final String? benefit;
  final String? actionLabel;
  final VoidCallback? onAction;
  final List<String> howTo;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    final accent = danger ? t.danger : t.primary;
    return DsCard(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        DsIllustration(icon: icon, color: accent),
        const SizedBox(height: Gap.lg),
        Text(title,
            textAlign: TextAlign.center,
            style: tx.titleLarge?.copyWith(color: t.text)),
        if (benefit != null) ...[
          const SizedBox(height: Gap.xs),
          Text(benefit!,
              textAlign: TextAlign.center,
              style: tx.bodyMedium?.copyWith(color: t.muted)),
        ],
        if (actionLabel != null) ...[
          const SizedBox(height: Gap.lg),
          DsButton(
            buttonKey: actionKey, // on the Material button itself
            label: actionLabel!,
            onPressed: onAction,
            kind: danger ? DsButtonKind.danger : DsButtonKind.primary,
            expand: true,
          ),
        ],
        if (howTo.isNotEmpty) ...[
          const SizedBox(height: Gap.lg),
          for (var i = 0; i < howTo.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DsStepNumber(i + 1),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(howTo[i],
                        style: tx.bodyMedium?.copyWith(color: t.text))),
              ]),
            ),
        ],
      ]),
    );
  }
}

/// Small numbered bubble (how-to steps). Digits come from the caller's
/// number formatting — pass the number; it is shown with the locale digits.
class DsStepNumber extends StatelessWidget {
  const DsStepNumber(this.n, {super.key});
  final int n;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    // Bangla digits by code point (no Bangla literal in Dart — lang gate).
    final s = bn
        ? String.fromCharCodes('$n'.codeUnits.map((c) => c - 0x30 + 0x09E6))
        : '$n';
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.primarySoft, shape: BoxShape.circle),
      child: Text(s,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: t.primaryInk)),
    );
  }
}

/// Drawn illustration (no image asset → no APK weight): two soft rings, a
/// tinted disc and the icon.
class DsIllustration extends StatelessWidget {
  const DsIllustration({super.key, required this.icon, this.color, this.size = 96});
  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final c = color ?? t.primary;
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          Container(
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: t.isDark ? 0.10 : 0.07))),
          Container(
              width: size * 0.72,
              height: size * 0.72,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: t.isDark ? 0.18 : 0.12))),
          Container(
            width: size * 0.48,
            height: size * 0.48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.withValues(alpha: 0.85), c],
              ),
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.26),
          ),
        ]),
      ),
    );
  }
}

/// Skeleton loader block (gentle opacity pulse; static in lite mode).
class DsSkeleton extends StatefulWidget {
  const DsSkeleton({super.key, this.height = 16, this.width, this.radius = DsRadius.small});
  final double height;
  final double? width;
  final double radius;

  /// A card-shaped placeholder of [lines] text lines.
  static Widget card({int lines = 3}) => DsCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const DsSkeleton(height: 18, width: 160),
          for (var i = 0; i < lines; i++) ...[
            const SizedBox(height: Gap.sm),
            DsSkeleton(height: 12, width: i == lines - 1 ? 120 : null),
          ],
        ]),
      );

  @override
  State<DsSkeleton> createState() => _DsSkeletonState();
}

class _DsSkeletonState extends State<DsSkeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = !DsPerf.liteOf(context);
    if (animate && _c == null) {
      _c = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);
    } else if (!animate && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final box = Container(
      height: widget.height,
      width: widget.width,
      decoration: BoxDecoration(
        color: t.cardHighest,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
    final c = _c;
    return Semantics(
      label: MaterialLocalizations.of(context).refreshIndicatorSemanticLabel,
      child: c == null
          ? box
          : FadeTransition(
              opacity: Tween(begin: 0.55, end: 1.0).animate(c), child: box),
    );
  }
}

enum DsToastTone { info, success, danger }

/// Toast: floating snack bar in the V2 style.
void showDsToast(BuildContext context, String message,
    {DsToastTone tone = DsToastTone.info, String? actionLabel, VoidCallback? onAction}) {
  final t = DsTokens.of(context);
  final (Color bg, Color fg, IconData icon) = switch (tone) {
    DsToastTone.success => (t.successBg, t.successInk, Icons.check_circle_rounded),
    DsToastTone.danger => (t.dangerBg, t.dangerInk, Icons.error_rounded),
    DsToastTone.info => (t.isDark ? t.cardHigh : t.text, t.isDark ? t.text : t.card, Icons.info_rounded),
  };
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DsRadius.card),
        side: BorderSide(color: fg.withValues(alpha: 0.25)),
      ),
      content: Row(children: [
        Icon(icon, color: fg, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg))),
      ]),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, textColor: fg, onPressed: onAction ?? () {}),
    ));
}

/// Offline strip (look only): a slim bar under the app bar.
class DsOfflineStrip extends StatelessWidget {
  const DsOfflineStrip({super.key, required this.label, this.retryLabel, this.onRetry});
  final String label;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final a = AssistoTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: a.warningContainer,
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: a.onWarningContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: a.onWarningContainer))),
          if (retryLabel != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: a.onWarningContainer),
              child: Text(retryLabel!),
            ),
        ]),
      ),
    );
  }
}

/// Paywall card (look only): plan title, price, perks, one CTA.
class DsPaywallCard extends StatelessWidget {
  const DsPaywallCard({
    super.key,
    required this.title,
    required this.price,
    required this.perks,
    required this.ctaLabel,
    required this.onCta,
    this.badge,
    this.note,
  });

  final String title;
  final String price;
  final List<String> perks;
  final String ctaLabel;
  final VoidCallback? onCta;
  final String? badge;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    return DsHeroCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Text(title, style: tx.titleLarge?.copyWith(color: t.text))),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
              decoration: BoxDecoration(
                  color: t.primarySoft,
                  borderRadius: BorderRadius.circular(DsRadius.chip)),
              child: Text(badge!,
                  style: tx.labelMedium?.copyWith(color: t.primaryInk)),
            ),
        ]),
        const SizedBox(height: Gap.xs),
        DsNumber(price),
        const SizedBox(height: Gap.md),
        for (final p in perks)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_circle_rounded, size: 20, color: t.success),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(p, style: tx.bodyMedium?.copyWith(color: t.text))),
            ]),
          ),
        const SizedBox(height: Gap.md),
        DsButton(label: ctaLabel, onPressed: onCta, expand: true),
        if (note != null) ...[
          const SizedBox(height: Gap.sm),
          Text(note!, style: tx.bodySmall?.copyWith(color: t.muted)),
        ],
      ]),
    );
  }
}

/// Header for a bottom sheet opened with showAppSheet (lib/widgets/
/// app_sheet.dart — never showModalBottomSheet; it owns the insets).
class DsSheetHeader extends StatelessWidget {
  const DsSheetHeader(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: Gap.md),
            decoration: BoxDecoration(
                color: t.border, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        Semantics(
            header: true,
            child: Text(title, style: tx.titleLarge?.copyWith(color: t.text))),
        if (subtitle != null)
          Text(subtitle!, style: tx.bodyMedium?.copyWith(color: t.muted)),
      ]),
    );
  }
}
