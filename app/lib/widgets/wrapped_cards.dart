import 'package:flutter/material.dart';
import '../theme.dart';
import '../screens/money_common.dart';

/// Story-card primitives for Monthly Money Wrapped (feature #63, §21).
///
/// Each card is a full-bleed gradient "slide" (festival-card look) built from
/// REAL recap numbers passed in by money_wrapped_screen.dart. No data is
/// fabricated here — the screen only builds cards for stats the backend
/// actually returned; a null/absent stat means that card is skipped upstream.
///
/// Every card is a plain widget so the whole deck (or a single card) can be
/// wrapped in a RepaintBoundary and captured to a PNG for sharing.
///
/// No literal Bangla text lives in this file: all copy comes from ARB via the
/// caller; only the Taka symbol (through [tkFmt]) and numbers render here.

/// Palette rotated per card so the swipe deck feels like Wrapped.
const List<List<Color>> kWrappedGradients = [
  [Brand.cyan, Brand.blue],
  [Brand.blue, Brand.purple],
  [Brand.purple, Brand.blueDeep],
  [Brand.blueDeep, Brand.cyan],
  [Brand.blue, Brand.cyan],
  [Brand.purple, Brand.blue],
];

/// The outer frame every Wrapped card shares: full-bleed gradient, rounded,
/// generous padding, a small eyebrow label at top and free content below.
class WrappedCardFrame extends StatelessWidget {
  final int index; // picks the gradient
  final String eyebrow; // small top label (from ARB)
  final Widget child;
  final String? footer; // optional bottom caption (from ARB / month name)
  const WrappedCardFrame({
    super.key,
    required this.index,
    required this.eyebrow,
    required this.child,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final colors = kWrappedGradients[index % kWrappedGradients.length];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(Radii.lg),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow.toUpperCase(),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const Spacer(),
          child,
          const Spacer(),
          if (footer != null)
            Text(
              footer!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// A big hero number with a caption underneath (total spent / earned / saved).
class WrappedBigStat extends StatelessWidget {
  final String value; // already-formatted (e.g. tkFmt(...))
  final String caption; // from ARB
  final IconData? icon;
  const WrappedBigStat({
    super.key,
    required this.value,
    required this.caption,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: Colors.white, size: 40),
          const SizedBox(height: Gap.md),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 44,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(
          caption,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Two-line stat: a title line (from ARB) + a formatted value + optional note.
class WrappedLineStat extends StatelessWidget {
  final String title;
  final String value;
  final String? note;
  final IconData? icon;
  const WrappedLineStat({
    super.key,
    required this.title,
    required this.value,
    this.note,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: Colors.white, size: 36),
          const SizedBox(height: Gap.md),
        ],
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Gap.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: Gap.sm),
          Text(
            note!,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ],
    );
  }
}

/// The savings-rate card: a ring that fills to the real rate, no fabrication.
class WrappedSavingsRing extends StatelessWidget {
  final int ratePct; // 0..(can exceed if net>income? clamped for the ring)
  final String title; // from ARB
  final String caption; // from ARB
  const WrappedSavingsRing({
    super.key,
    required this.ratePct,
    required this.title,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = ratePct.clamp(0, 100) / 100.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Gap.lg),
        Center(
          child: SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 140,
                  height: 140,
                  child: CircularProgressIndicator(
                    value: clamped,
                    strokeWidth: 12,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                Text(
                  '$ratePct%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(
          caption,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }
}

/// The trend card: an up/down arrow + signed percentage vs last month. Only
/// rendered by the screen when the recap says a real previous month exists.
class WrappedTrend extends StatelessWidget {
  final bool up;
  final int pct; // signed
  final String deltaValue; // formatted taka
  final String title; // from ARB
  final String caption; // from ARB (already includes direction phrasing)
  const WrappedTrend({
    super.key,
    required this.up,
    required this.pct,
    required this.deltaValue,
    required this.title,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Gap.md),
        Row(
          children: [
            Icon(up ? Icons.trending_up : Icons.trending_down,
                color: Colors.white, size: 44),
            const SizedBox(width: Gap.sm),
            Text(
              '${up ? '+' : ''}$pct%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Text(
          deltaValue,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(
          caption,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }
}

/// The finale persona card: a big emoji + persona title + one-line blurb, all
/// from ARB (the backend only sends a slug).
class WrappedPersona extends StatelessWidget {
  final String emoji;
  final String title; // from ARB
  final String blurb; // from ARB
  final String eyebrow; // from ARB
  const WrappedPersona({
    super.key,
    required this.emoji,
    required this.title,
    required this.blurb,
    required this.eyebrow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 72)),
        const SizedBox(height: Gap.md),
        Text(
          eyebrow,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: Gap.xs),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(
          blurb,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// Small helper so the screen can show a chip-style "N categories · M txns"
/// stat row inside a card without pulling in extra widgets.
class WrappedFactChips extends StatelessWidget {
  final List<String> facts; // each already localised + formatted
  const WrappedFactChips({super.key, required this.facts});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        for (final f in facts)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              f,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
      ],
    );
  }
}
