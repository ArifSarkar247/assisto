import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;

/// Relationship-scoped sharing editor ("who sees what"). Mirrors
/// core/logic/circle.py SCOPES + default_sharing(). A member toggles which
/// scopes a given relation may see. Safe defaults are set server-side on
/// accept; this edits the live policy.
class CircleSharingEditor extends StatelessWidget {
  final Map<String, bool> policy;
  final ValueChanged<Map<String, bool>> onChanged;
  const CircleSharingEditor(
      {super.key, required this.policy, required this.onChanged});

  static const scopes = ['medicines', 'location', 'documents', 'money', 'profile'];

  String _label(AppLocalizations t, String scope) {
    switch (scope) {
      case 'medicines':
        return t.circleScopeMedicines;
      case 'location':
        return t.circleScopeLocation;
      case 'documents':
        return t.circleScopeDocuments;
      case 'money':
        return t.circleScopeMoney;
      case 'profile':
        return t.circleScopeProfile;
      default:
        return scope;
    }
  }

  IconData _icon(String scope) {
    switch (scope) {
      case 'medicines':
        return Icons.medication_rounded;
      case 'location':
        return Icons.place_rounded;
      case 'documents':
        return Icons.lock_outline_rounded;
      case 'money':
        return Icons.account_balance_wallet_rounded;
      case 'profile':
        return Icons.person_outline_rounded;
      default:
        return Icons.tune_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Text(t.circleSharingTitle,
              style: Theme.of(context).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: Text(t.circleSharingHint,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant, height: 1.35)),
        ),
        // play-nomed: no "medicines" sharing scope in the Play flavour.
        for (final s in scopes)
          if (s != 'medicines' || kMedicalFeaturesAllowed)
          SwitchListTile(
            secondary: Icon(_icon(s), color: scheme.onSurfaceVariant),
            title: Text(_label(t, s)),
            value: policy[s] ?? false,
            onChanged: (v) {
              final next = Map<String, bool>.from(policy);
              next[s] = v;
              onChanged(next);
            },
          ),
      ],
    );
  }
}
