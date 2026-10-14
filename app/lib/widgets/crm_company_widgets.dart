import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Shared presentational widgets for the CRM Company/Contact 360 and Reports
/// screens. Pure UI — no network. All copy is passed in from AppLocalizations by
/// the caller so there is zero Bangla literal here.

/// Contact "role" is inferred from the (free-text) job title + the lead
/// `decision_maker` flag, because the backend Contact model has no explicit role
/// field (title + is_primary only). The inference is a convenience, never a
/// fabrication: an unmatched title falls back to "User". Codes are stable.
enum ContactRole { decisionMaker, finance, influencer, champion, user }

ContactRole inferContactRole(String? title, {bool isPrimary = false}) {
  final t = (title ?? '').toLowerCase();
  bool any(List<String> kw) => kw.any(t.contains);
  if (any(['ceo', 'cto', 'coo', 'cfo', 'founder', 'owner', 'managing director',
      'md', 'director', 'chairman', 'proprietor', 'vp', 'head', 'chief'])) {
    // Finance-specific chiefs read as Finance below; otherwise decision maker.
    if (any(['cfo', 'finance', 'accounts', 'accountant', 'treasur'])) {
      return ContactRole.finance;
    }
    return ContactRole.decisionMaker;
  }
  if (any(['finance', 'accounts', 'accountant', 'treasur', 'billing', 'audit'])) {
    return ContactRole.finance;
  }
  if (any(['manager', 'lead', 'senior', 'architect', 'consultant'])) {
    return ContactRole.influencer;
  }
  if (isPrimary) return ContactRole.champion;
  return ContactRole.user;
}

String contactRoleLabel(ContactRole r, AppLocalizations t) {
  switch (r) {
    case ContactRole.decisionMaker:
      return t.crmRoleDecisionMaker;
    case ContactRole.finance:
      return t.crmRoleFinance;
    case ContactRole.influencer:
      return t.crmRoleInfluencer;
    case ContactRole.champion:
      return t.crmRoleChampion;
    case ContactRole.user:
      return t.crmRoleUser;
  }
}

Color contactRoleColor(ContactRole r) {
  switch (r) {
    case ContactRole.decisionMaker:
      return Brand.purple;
    case ContactRole.finance:
      return Brand.success;
    case ContactRole.influencer:
      return Brand.blue;
    case ContactRole.champion:
      return Brand.warning;
    case ContactRole.user:
      return const Color(0xFF6B7280);
  }
}

/// A compact role chip (decision maker / influencer / finance / …). WCAG-safe:
/// solid tinted bg with white text for strong roles, muted for "user".
class ContactRoleChip extends StatelessWidget {
  final ContactRole role;
  const ContactRoleChip(this.role, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final c = contactRoleColor(role);
    final muted = role == ContactRole.user;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: muted ? scheme.surfaceContainerHighest : c,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        contactRoleLabel(role, t),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: muted ? scheme.onSurfaceVariant : Colors.white,
        ),
      ),
    );
  }
}

/// A "primary contact" star marker.
class PrimaryContactBadge extends StatelessWidget {
  const PrimaryContactBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.star, size: 14, color: Brand.warning),
      const SizedBox(width: 3),
      Text(t.crmPrimary,
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Brand.warning)),
    ]);
  }
}

/// A free-form tag chip (name + its stored hex colour). Tapable for filtering.
class CrmTagChip extends StatelessWidget {
  final String name;
  final String? colorHex;
  final bool selected;
  final VoidCallback? onTap;
  const CrmTagChip(this.name,
      {super.key, this.colorHex, this.selected = false, this.onTap});

  Color get _color {
    final h = (colorHex ?? '').replaceAll('#', '');
    if (h.length == 6) {
      final v = int.tryParse(h, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Brand.blue;
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Material(
      color: selected ? c : c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.sell_outlined,
                size: 13, color: selected ? Colors.white : c),
            const SizedBox(width: 4),
            Text(name,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : c)),
          ]),
        ),
      ),
    );
  }
}

/// A labelled key → value row used across the overview / custom-field panels.
class KvRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  const KvRow(this.label, this.value, {super.key, this.icon});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
        ],
        SizedBox(
          width: 110,
          child: Text(label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// A section header used across the 360 and reports screens.
class CrmSectionHeader extends StatelessWidget {
  final String title;
  final String? hint;
  final Widget? trailing;
  const CrmSectionHeader(this.title, {super.key, this.hint, this.trailing});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs, top: Gap.xs),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15)),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(hint!,
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// A timeline activity dot + kind icon, for the aggregated company timeline.
IconData activityKindIcon(String? kind) {
  switch (kind) {
    case 'call':
      return Icons.call_outlined;
    case 'meeting':
      return Icons.groups_outlined;
    case 'task':
      return Icons.check_circle_outline;
    case 'email':
      return Icons.mail_outline;
    case 'whatsapp':
      return Icons.chat_outlined;
    case 'stage':
      return Icons.timeline_outlined;
    case 'system':
      return Icons.settings_suggest_outlined;
    default:
      return Icons.sticky_note_2_outlined;
  }
}

/// A horizontal "funnel bar" — width proportional to reached/max, with the
/// stage name, reached count and conversion % from the previous stage.
class FunnelBar extends StatelessWidget {
  final String stage;
  final int reached;
  final int max;
  final double? conversionFromPrev;
  const FunnelBar({
    super.key,
    required this.stage,
    required this.reached,
    required this.max,
    this.conversionFromPrev,
  });
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final frac = max <= 0 ? 0.0 : (reached / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(stage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          Text('$reached',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          if (conversionFromPrev != null) ...[
            const SizedBox(width: 6),
            Text('· $conversionFromPrev% ${t.crmFromPrevStage}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xs),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 10,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: const AlwaysStoppedAnimation(Brand.blue),
          ),
        ),
      ]),
    );
  }
}

/// A single stat tile for the reports header strip.
class ReportStatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? tint;
  const ReportStatTile(
      {super.key,
      required this.label,
      required this.value,
      required this.icon,
      this.tint});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: tint ?? scheme.primary),
          const SizedBox(height: Gap.xs),
          Text(value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
