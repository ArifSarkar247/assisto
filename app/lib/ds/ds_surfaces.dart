// designv2 — Design System V2 surfaces: card, hero card, tile, status dot.
// Tokens: lib/theme.dart (DsTokens / DsRadius / DsMotion / DsPerf).
// Cheap by construction: plain BoxShadows (no BackdropFilter / blur layers),
// one CustomPaint stroke for the top highlight, a RepaintBoundary around the
// only looping animation (the status dot), and everything static in lite mode
// (low-RAM phone, reduce motion, battery saver).
import 'package:flutter/material.dart';

import '../theme.dart';

/// Tone of a surface: normal (white card), danger (soft red), success.
enum DsTone { normal, danger, success }

/// The pressable "alive" surface every card / tile builds on: radius 12,
/// owner shadow, 1 px top highlight, lifts 2 px on press.
class DsSurface extends StatefulWidget {
  const DsSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.tone = DsTone.normal,
    this.gradient,
    this.color,
    this.borderColor,
    this.radius = DsRadius.card,
    this.semanticLabel,
    this.flat = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final DsTone tone;
  final Gradient? gradient;
  final Color? color;
  final Color? borderColor;
  final double radius;
  final String? semanticLabel;

  /// No shadow (a surface nested inside another card).
  final bool flat;

  @override
  State<DsSurface> createState() => _DsSurfaceState();
}

class _DsSurfaceState extends State<DsSurface> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final lite = DsPerf.liteOf(context);
    final interactive = widget.onTap != null || widget.onLongPress != null;
    final pressed = _down && interactive && !lite;
    final (Color fill, Color border) = switch (widget.tone) {
      DsTone.danger => (t.dangerBg, t.dangerBorder),
      DsTone.success => (t.successBg, t.success.withValues(alpha: 0.35)),
      DsTone.normal => (t.card, t.isDark ? t.border : t.border.withValues(alpha: 0.7)),
    };
    final shadows = widget.flat
        ? const <BoxShadow>[]
        : lite
            ? t.liteShadows
            : (pressed ? t.pressedShadows : t.shadows);
    final r = BorderRadius.circular(widget.radius);
    Widget body = Padding(padding: widget.padding, child: widget.child);
    // lite: no highlight shader, no animated container, no clip layer
    if (!widget.flat && !lite) {
      body = CustomPaint(
        foregroundPainter: _TopHighlight(t.highlight, widget.radius),
        child: body,
      );
    }
    final deco = BoxDecoration(
      color: widget.gradient == null ? (widget.color ?? fill) : null,
      gradient: widget.gradient,
      borderRadius: r,
      border: Border.all(color: widget.borderColor ?? border),
      boxShadow: shadows,
    );
    final material = Material(
        type: MaterialType.transparency,
        borderRadius: r,
        // a clip only where ink must stay inside the corners
        clipBehavior: interactive && !lite ? Clip.antiAlias : Clip.none,
        child: interactive
            ? InkWell(
                borderRadius: r,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                onHighlightChanged: _set,
                child: body,
              )
            : body,
      );
    Widget card = lite
        ? DecoratedBox(decoration: deco, child: material)
        : AnimatedContainer(
            duration: DsMotion.press,
            curve: DsMotion.curve,
            transform: Matrix4.translationValues(0, pressed ? -DsMotion.lift : 0, 0),
            decoration: deco,
            child: material,
          );
    if (widget.semanticLabel != null) {
      card = Semantics(
          label: widget.semanticLabel, button: interactive, child: card);
    }
    return card;
  }
}

/// 1 px highlight along the top edge, fading out over the corner radius.
class _TopHighlight extends CustomPainter {
  const _TopHighlight(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0 || size.isEmpty) return;
    final rr = RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5), Radius.circular(radius));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, radius));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, radius)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TopHighlight old) =>
      old.color != color || old.radius != radius;
}

/// Standard content card.
class DsCard extends StatelessWidget {
  const DsCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.tone = DsTone.normal,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final DsTone tone;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => DsSurface(
        onTap: onTap,
        padding: padding,
        tone: tone,
        semanticLabel: semanticLabel,
        child: child,
      );
}

/// Hero card: the soft light gradient (light: white → #F2F7FF; dark: card →
/// background), or the red urgent hero ([danger]) with white ink.
class DsHeroCard extends StatelessWidget {
  const DsHeroCard({
    super.key,
    required this.child,
    this.onTap,
    this.danger = false,
    this.padding = const EdgeInsets.all(Gap.lg + Gap.xs),
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool danger;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final lite = DsPerf.liteOf(context);
    final g = danger
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: t.dangerHero)
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [t.heroTop, t.heroBottom]);
    Widget surface = DsSurface(
      onTap: onTap,
      padding: padding,
      gradient: g,
      borderColor: danger ? t.dangerHero.last : null,
      child: danger
          ? DefaultTextStyle.merge(
              style: TextStyle(color: t.onDangerHero),
              child: IconTheme.merge(
                  data: IconThemeData(color: t.onDangerHero), child: child),
            )
          : child,
    );
    if (danger && !lite) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DsRadius.card),
          boxShadow: t.dangerGlow,
        ),
        child: surface,
      );
    }
    return surface;
  }
}

/// Grid tile: icon bubble + label (max two lines, never cut with "…" — it
/// wraps, and the tile grows).
class DsTile extends StatelessWidget {
  const DsTile({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.accent,
    this.selected = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? accent;
  final bool selected;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    final a = accent ?? t.primaryInk;
    return DsSurface(
      onTap: onTap,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.md),
      borderColor: selected ? a : null,
      color: selected ? t.primarySoft : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTap + Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: a.withValues(alpha: t.isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(DsRadius.card),
                ),
                child: Icon(icon, color: a, size: 24),
              ),
              if (badge != null) Positioned(top: -4, right: -6, child: badge!),
            ]),
            const SizedBox(height: Gap.sm),
            ExcludeSemantics(
              child: Text(
                label,
                textAlign: TextAlign.center,
                softWrap: true, // grows at 200% font — never cut
                style: tx.labelLarge?.copyWith(color: t.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status dot that gently pulses every 2 s (static in lite mode).
class DsStatusDot extends StatefulWidget {
  const DsStatusDot({super.key, this.color, this.size = 10, this.pulse = true});
  final Color? color;
  final double size;
  final bool pulse;

  @override
  State<DsStatusDot> createState() => _DsStatusDotState();
}

class _DsStatusDotState extends State<DsStatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = widget.pulse && !DsPerf.liteOf(context);
    if (animate && _c == null) {
      _c = AnimationController(vsync: this, duration: DsMotion.pulse)..repeat();
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
    final c = widget.color ?? DsTokens.of(context).success;
    final s = widget.size;
    final dot = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
    final ctl = _c;
    return SizedBox(
      width: s * 2,
      height: s * 2,
      child: RepaintBoundary(
        child: Stack(alignment: Alignment.center, children: [
          if (ctl != null)
            AnimatedBuilder(
              animation: ctl,
              builder: (_, __) {
                final v = Curves.easeOut.transform(ctl.value);
                return Container(
                  width: s + s * v,
                  height: s + s * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.withValues(alpha: 0.35 * (1 - v)),
                  ),
                );
              },
            ),
          dot,
        ]),
      ),
    );
  }
}

/// Grouped list card (settings-style): rows inside one V2 card, thin inset
/// dividers between them; empty children (SizedBox.shrink tiles that render
/// nothing) still just take no room.
class DsGroup extends StatelessWidget {
  const DsGroup({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
    this.flat = false,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  /// design3: a flat bordered group (no shadow) for rows INSIDE another card.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    return Padding(
      padding: margin,
      child: DsSurface(
        flat: flat,
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                  height: 1,
                  indent: Gap.lg,
                  endIndent: Gap.lg,
                  color: t.border.withValues(alpha: 0.6)),
            children[i],
          ],
        ]),
      ),
    );
  }
}
