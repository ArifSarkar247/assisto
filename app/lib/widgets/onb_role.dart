import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'onb_common.dart';

/// "Who are you setting this up for?" — self / elderly parent / family / business.
/// The choice tailors the first win and whether we push the parent-link step
/// (mirrors parent_link.first_win_for_role / should_prompt_parent_link).
/// Mirrors the backend role codes exactly so the two never drift.
enum OnbRole { self, parent, family, business }

extension OnbRoleCode on OnbRole {
  /// Backend code (core/logic/parent_link.ROLE_*).
  String get code => switch (this) {
        OnbRole.self => 'self',
        OnbRole.parent => 'parent',
        OnbRole.family => 'family',
        OnbRole.business => 'business',
      };
}

class OnbRoleStep extends StatelessWidget {
  final OnbRole? selected;
  final ValueChanged<OnbRole> onPick;

  /// famcare (owner decision 6, 28 Oct): "Simple home (for elders)" can be
  /// chosen right here — it turns on the EXISTING elderly simple home.
  final bool simpleHome;
  final ValueChanged<bool>? onSimpleHome;
  const OnbRoleStep({super.key, required this.selected, required this.onPick,
      this.simpleHome = false, this.onSimpleHome});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = <(OnbRole, IconData, String, String)>[
      (OnbRole.self, Icons.person_outline_rounded, t.onbRoleSelf, t.onbRoleSelfSub),
      (
        OnbRole.parent,
        Icons.elderly_rounded,
        t.onbRoleParent,
        t.onbRoleParentSub
      ),
      (
        OnbRole.family,
        Icons.diversity_1_rounded,
        t.onbRoleFamily,
        t.onbRoleFamilySub
      ),
      (
        OnbRole.business,
        Icons.storefront_rounded,
        t.onbRoleBusiness,
        t.onbRoleBusinessSub
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        OnbHeader(
          icon: Icons.waving_hand_rounded,
          title: t.onbWhoTitle,
          subtitle: t.onbWhoSub,
          iconSize: 72,
        ),
        const SizedBox(height: Gap.xl),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: OnbChoiceTile(
              icon: it.$2,
              title: it.$3,
              subtitle: it.$4,
              selected: selected == it.$1,
              onTap: () => onPick(it.$1),
            ),
          ),
        if (onSimpleHome != null)
          Card(
            key: const ValueKey('onb-simple-home'),
            child: SwitchListTile(
              secondary: const Icon(Icons.elderly_woman_rounded, size: 32),
              value: simpleHome,
              onChanged: onSimpleHome,
              title: Text(t.onbSimpleHome,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(t.onbSimpleHomeSub),
            ),
          ),
      ],
    );
  }
}
