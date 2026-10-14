import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Consent + warning block shown before a nominee is saved.
///
/// Two things it makes explicit, respectfully (BD framing — a nominee /
/// waris / trusted person):
///  1. The nominee should KNOW they have been named and should consent out of
///     band (we prompt the owner to tell them — the app never silently enrols a
///     third party).
///  2. Nothing opens now: saving only *arms* a future, verified, cancellable
///     release. No data is shared at this moment.
class NomineeConsentBanner extends StatelessWidget {
  final String relationship;
  const NomineeConsentBanner({super.key, required this.relationship});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.handshake_outlined,
              size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.nomineeConsentTitle,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onTertiaryContainer)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        _Point(text: tr.nomineeConsentInformThem),
        _Point(text: tr.nomineeConsentNothingOpensNow),
        _Point(text: tr.nomineeConsentReversible),
      ]),
    );
  }
}

class _Point extends StatelessWidget {
  final String text;
  const _Point({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: Gap.sm),
          child: Icon(Icons.check, size: 15, color: scheme.onTertiaryContainer),
        ),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: scheme.onTertiaryContainer)),
        ),
      ]),
    );
  }
}
