// designv2 — Design System V2 controls: buttons (soft glow), chips, list row,
// avatar, section header, big number. Tokens: lib/theme.dart.
import 'package:flutter/material.dart';

import '../theme.dart';

enum DsButtonKind { primary, secondary, danger, ghost }

/// Button: primary / danger carry a soft coloured glow (none in lite mode);
/// radius 8; ≥ 48 dp tall; the label wraps instead of being cut.
class DsButton extends StatelessWidget {
  const DsButton({
    super.key,
    this.buttonKey,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = DsButtonKind.primary,
    this.expand = false,
    this.busy = false,
  });

  const DsButton.secondary({
    super.key,
    this.buttonKey,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
  }) : kind = DsButtonKind.secondary;

  const DsButton.danger({
    super.key,
    this.buttonKey,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
  }) : kind = DsButtonKind.danger;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final DsButtonKind kind;

  /// Key for the inner Material button (tests that read a ButtonStyleButton).
  final Key? buttonKey;
  final bool expand;

  /// Shows a small spinner instead of the icon and disables the button.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final lite = DsPerf.liteOf(context);
    final enabled = onPressed != null && !busy;
    final tx = Theme.of(context).textTheme.labelLarge;
    final lead = busy
        ? const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : (icon == null ? null : Icon(icon, size: 20));
    final text = Text(label, textAlign: TextAlign.center, softWrap: true);
    final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DsRadius.button));
    const pad = EdgeInsets.symmetric(horizontal: Gap.lg + Gap.xs, vertical: Gap.md);
    const min = Size(kMinTap, kMinTap + 2);
    Widget b;
    switch (kind) {
      case DsButtonKind.primary:
      case DsButtonKind.danger:
        final danger = kind == DsButtonKind.danger;
        final style = FilledButton.styleFrom(
          backgroundColor: danger ? t.dangerFill : null,
          foregroundColor: danger ? t.onDangerFill : null,
          minimumSize: min,
          padding: pad,
          shape: shape,
          textStyle: tx,
        );
        b = lead == null
            ? FilledButton(
                key: buttonKey,
                onPressed: enabled ? onPressed : null, style: style, child: text)
            : FilledButton.icon(
                key: buttonKey,
                onPressed: enabled ? onPressed : null,
                style: style,
                icon: lead,
                label: text);
        if (enabled && !lite) {
          b = DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DsRadius.button),
              boxShadow: danger ? t.dangerGlow : t.primaryGlow,
            ),
            child: b,
          );
        }
      case DsButtonKind.secondary:
        final style = OutlinedButton.styleFrom(
          backgroundColor: t.card,
          foregroundColor: t.primaryInk,
          side: BorderSide(color: t.border, width: 1.2),
          minimumSize: min,
          padding: pad,
          shape: shape,
          textStyle: tx,
        );
        b = lead == null
            ? OutlinedButton(
                key: buttonKey,
                onPressed: enabled ? onPressed : null, style: style, child: text)
            : OutlinedButton.icon(
                key: buttonKey,
                onPressed: enabled ? onPressed : null,
                style: style,
                icon: lead,
                label: text);
      case DsButtonKind.ghost:
        final style = TextButton.styleFrom(
          foregroundColor: t.primaryInk,
          minimumSize: const Size(kMinTap, kMinTap),
          shape: shape,
          textStyle: tx,
        );
        b = lead == null
            ? TextButton(
                key: buttonKey,
                onPressed: enabled ? onPressed : null, style: style, child: text)
            : TextButton.icon(
                key: buttonKey,
                onPressed: enabled ? onPressed : null,
                style: style,
                icon: lead,
                label: text);
    }
    return expand ? SizedBox(width: double.infinity, child: b) : b;
  }
}

/// Round icon action (call / message): 48 dp target, tinted fill.
class DsIconAction extends StatelessWidget {
  const DsIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final c = color ?? t.primaryInk;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
      style: IconButton.styleFrom(
        backgroundColor: c.withValues(alpha: t.isDark ? 0.2 : 0.1),
        foregroundColor: c,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DsRadius.button)),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

/// Filter / choice chip. Use [DsChipRow] for a set (one scrolling row —
/// chips never break into odd rows).
class DsChip extends StatelessWidget {
  const DsChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onSelected,
    this.icon,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    return ChoiceChip(
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 18),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      backgroundColor: t.card,
      selectedColor: t.primarySoft,
      side: BorderSide(color: selected ? t.primaryInk : t.border),
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: selected ? t.primaryInk : t.text),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      shape: const StadiumBorder(),
    );
  }
}

/// One horizontally scrolling row of chips.
class DsChipRow extends StatelessWidget {
  const DsChipRow({super.key, required this.children, this.padding = Gap.screen});
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: Gap.sm),
            children[i],
          ],
        ]),
      );
}

/// Section header: title + optional action (e.g. "See all").
class DsSectionHeader extends StatelessWidget {
  const DsSectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
      child: Row(children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: t.text, fontWeight: FontWeight.w700)),
          ),
        ),
        if (action != null)
          DsButton(label: action!, onPressed: onAction, kind: DsButtonKind.ghost),
      ]),
    );
  }
}

/// List row: leading / title / subtitle / trailing, ≥ 56 dp, wraps text.
class DsListRow extends StatelessWidget {
  const DsListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: Gap.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: tx.bodyLarge
                        ?.copyWith(color: t.text, fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(subtitle!, style: tx.bodyMedium?.copyWith(color: t.muted)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: Gap.sm), trailing!],
        ]),
      ),
    );
    return onTap == null
        ? row
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(DsRadius.card),
            child: row);
  }
}

/// Avatar: initials on a tint (or a [child], e.g. an image / icon).
class DsAvatar extends StatelessWidget {
  const DsAvatar({super.key, this.name = '', this.size = 44, this.color, this.child});
  final String name;
  final double size;
  final Color? color;
  final Widget? child;

  static String initials(String n) {
    final parts = n.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final a = parts.first.characters.first;
    final b = parts.length > 1 ? parts.last.characters.first : '';
    return (a + b).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = DsTokens.of(context);
    final c = color ?? t.primaryInk;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: t.isDark ? 0.24 : 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: child ??
          Text(initials(name),
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: c, fontWeight: FontWeight.w700)),
    );
  }
}

/// Big number (counts, money): bold, tight letter spacing, tabular figures.
class DsNumber extends StatelessWidget {
  const DsNumber(this.text, {super.key, this.color, this.small = false});
  final String text;
  final Color? color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final tx = Theme.of(context).textTheme;
    final base = small ? tx.titleLarge : tx.headlineMedium;
    return Text(text,
        style: base?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
          fontFeatures: AFonts.tabular,
          color: color ?? DsTokens.of(context).text,
        ));
  }
}
