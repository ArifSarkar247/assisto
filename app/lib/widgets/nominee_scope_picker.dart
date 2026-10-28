import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Which categories of the owner's information a nominee may access when (and
/// only when) a release trigger fires.
///
/// IMPORTANT: these are *categories / pointers*, never the raw secrets. The
/// `documents` scope grants access to the vault's document list and metadata
/// pointers — the vault itself stays end-to-end encrypted and its contents are
/// never surfaced through the nominee flow (see vault_screen.dart).
class NomineeScope {
  final String key;
  final IconData icon;
  const NomineeScope(this.key, this.icon);

  static const emergency = NomineeScope('emergency', Icons.emergency_rounded);
  static const documents = NomineeScope('documents', Icons.folder_shared_rounded);
  static const accounts = NomineeScope('accounts', Icons.account_balance_rounded);
  static const insurance = NomineeScope('insurance', Icons.health_and_safety_rounded);
  static const wishes = NomineeScope('wishes', Icons.menu_book_rounded);

  static const all = <NomineeScope>[
    emergency,
    documents,
    accounts,
    insurance,
    wishes,
  ];

  String label(AppLocalizations tr) {
    switch (key) {
      case 'documents':
        return tr.nomineeScopeDocuments;
      case 'accounts':
        return tr.nomineeScopeAccounts;
      case 'insurance':
        return tr.nomineeScopeInsurance;
      case 'wishes':
        return tr.nomineeScopeWishes;
      case 'emergency':
      default:
        return tr.nomineeScopeEmergency;
    }
  }

  /// One-line explanation of exactly what this category exposes — shown so the
  /// owner understands the blast radius before granting it.
  String describe(AppLocalizations tr) {
    switch (key) {
      case 'documents':
        return tr.nomineeScopeDocumentsDesc2;
      case 'accounts':
        return tr.nomineeScopeAccountsDesc;
      case 'insurance':
        return tr.nomineeScopeInsuranceDesc;
      case 'wishes':
        return tr.nomineeScopeWishesDesc;
      case 'emergency':
      default:
        return tr.nomineeScopeEmergencyDesc;
    }
  }
}

/// Multi-select category picker. Tapping a tile toggles it; each tile carries a
/// short description so consent is informed. A nominee must have at least one
/// category (enforced by the caller's save gate).
class NomineeScopePicker extends StatelessWidget {
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  const NomineeScopePicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final s in NomineeScope.all)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () {
                // Migrate the legacy 'all' value into explicit categories when
                // the owner starts customising.
                selected.remove('all');
                if (selected.contains(s.key)) {
                  selected.remove(s.key);
                } else {
                  selected.add(s.key);
                }
                onChanged(selected);
              },
              child: Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: selected.contains(s.key)
                      ? scheme.primaryContainer.withValues(alpha: 0.6)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(
                    color: selected.contains(s.key)
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: selected.contains(s.key) ? 1.5 : 1,
                  ),
                ),
                child: Row(children: [
                  Icon(s.icon,
                      color: selected.contains(s.key)
                          ? scheme.primary
                          : scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.label(tr),
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        const SizedBox(height: 2),
                        Text(s.describe(tr),
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Icon(
                    selected.contains(s.key)
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected.contains(s.key)
                        ? scheme.primary
                        : scheme.outline,
                    size: 22,
                  ),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}
