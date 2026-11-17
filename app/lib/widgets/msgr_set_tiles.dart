import 'package:flutter/material.dart';

import '../theme.dart';
import '../ds/ds.dart';

/// Shared building blocks for the expanded hub Settings sub-screens. Keeps the
/// sub-screens tidy and visually consistent (Original Assisto look — our own
/// icons/wording, never Meta assets). No Bangla literals here; every label is
/// passed in from AppLocalizations by the caller.

/// A section header inside a settings list (DS section header look).
class MsgrSetSection extends StatelessWidget {
  final String label;
  const MsgrSetSection(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: AType.titleSmall.copyWith(color: ds.muted, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// designv2: the rows of one settings section inside ONE alive DS card
/// (settings-style group, thin inset dividers).
class MsgrSetGroup extends StatelessWidget {
  final List<Widget> children;
  const MsgrSetGroup(this.children, {super.key});

  @override
  Widget build(BuildContext context) => DsGroup(children: children);
}

/// A navigation row: tinted icon bubble, title (wraps — never "…"),
/// optional subtitle / right-aligned value, chevron.
class MsgrSetRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value; // right-aligned current value (e.g. "English")
  final VoidCallback? onTap;
  final Color? color;
  const MsgrSetRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    final ink = color == null ? ds.primaryInk : Brand.onTint(context, color!);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xxs),
      leading: DsAvatar(size: 40, color: color, child: Icon(icon, size: 20, color: ink)),
      title: Text(title,
          style: AType.bodyLarge.copyWith(
              color: color == null ? ds.text : ink, fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AType.bodyMedium.copyWith(color: ds.muted)),
      trailing: value == null
          ? (onTap == null ? null : Icon(Icons.chevron_right_rounded, color: ds.muted))
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(value!,
                  textAlign: TextAlign.end,
                  style: AType.bodyMedium.copyWith(color: ds.muted)),
            ),
      onTap: onTap,
    );
  }
}

/// An HONEST "coming soon / needs key X" panel (DS card with the drawn
/// illustration) so the row that opens the screen is never a dead tap.
class MsgrSetComingSoon extends StatelessWidget {
  final String title;
  final String requirement;
  final IconData icon;
  const MsgrSetComingSoon({
    super.key,
    required this.title,
    required this.requirement,
    this.icon = Icons.schedule_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: DsCard(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DsIllustration(icon: icon),
            const SizedBox(height: Gap.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: AType.titleMedium.copyWith(color: ds.text, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(requirement,
                textAlign: TextAlign.center,
                style: AType.bodyMedium.copyWith(color: ds.muted, height: 1.4)),
          ]),
        ),
      ),
    );
  }
}

/// A short footer note (e.g. "server-enforced") shown under a settings list.
class MsgrSetNote extends StatelessWidget {
  final String text;
  final IconData icon;
  const MsgrSetNote(this.text, {super.key, this.icon = Icons.info_outline_rounded});

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: ds.primaryInk),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text, style: AType.bodySmall.copyWith(color: ds.muted, height: 1.4)),
        ),
      ]),
    );
  }
}
