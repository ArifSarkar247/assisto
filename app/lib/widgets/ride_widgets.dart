import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ride_deeplink.dart';
import 'ride_store.dart';

/// Ride & food ADVANCED — reusable presentation widgets (SPEC v2.1 §21).
/// All copy comes from [AppLocalizations] (bilingual, zero Bangla in .dart).

/// Honest banner: we only open the provider's app; no booking, no payment.
class RideHonestNote extends StatelessWidget {
  const RideHonestNote({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.blue.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.open_in_new_rounded, size: 18, color: Brand.blue),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            t.rideFoodDeepLinkNote,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
          ),
        ),
      ]),
    );
  }
}

/// Approximate-fare note. We NEVER compute or invent a number — this only tells
/// the user the real estimate appears inside the provider's own app.
class RideFareNote extends StatelessWidget {
  const RideFareNote({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            t.rideFoodFareApprox,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}

/// In-app booking deferred chip (🤝 — not now; opens provider app instead).
class RideInAppComingNote extends StatelessWidget {
  const RideInAppComingNote({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.handshake_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            t.rideFoodInAppComing,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}

/// A section header row.
class RideSectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  const RideSectionHeader(
      {super.key, required this.icon, required this.label, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// A provider row that knows (best-effort) whether its app is installed, and
/// deep-links out with the trip/search prefilled. Shows an honest install chip.
class RideProviderTile extends StatelessWidget {
  final RideProvider provider;
  final InstallState install;
  final VoidCallback onOpen;
  const RideProviderTile({
    super.key,
    required this.provider,
    required this.install,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    String sub;
    switch (install) {
      case InstallState.installed:
        sub = t.rideFoodInstalled;
        break;
      case InstallState.notInstalled:
        sub = t.rideFoodNotInstalled;
        break;
      case InstallState.unknown:
        sub = t.rideFoodOpenInApp;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Brand.blue.withValues(alpha: 0.12),
          child: Icon(provider.icon, color: Brand.blue),
        ),
        title: Text(provider.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Row(children: [
          if (install == InstallState.installed)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: Icon(Icons.check_circle_rounded,
                  size: 14, color: Brand.success),
            ),
          Expanded(
            child: Text(sub,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
          ),
        ]),
        trailing: FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text(t.rideFoodOpen),
          onPressed: onOpen,
        ),
        onTap: onOpen,
      ),
    );
  }
}

/// A saved-place chip (home/work/other) that prefills the destination field.
class RidePlaceChip extends StatelessWidget {
  final SavedPlace place;
  final VoidCallback onUse;
  final VoidCallback? onRemove;
  const RidePlaceChip(
      {super.key, required this.place, required this.onUse, this.onRemove});

  IconData get _icon {
    switch (place.kind) {
      case SavedPlace.home:
        return Icons.home_rounded;
      case SavedPlace.work:
        return Icons.work_outline_rounded;
      default:
        return Icons.place_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InputChip(
      avatar: Icon(_icon, size: 18),
      label: Text(place.label),
      onPressed: onUse,
      onDeleted: onRemove,
      tooltip: place.address,
    );
  }
}

/// A recent-trip / saved-craving quick chip (string reuse).
class RideQuickChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onUse;
  final VoidCallback? onRemove;
  const RideQuickChip({
    super.key,
    required this.label,
    required this.icon,
    required this.onUse,
    this.onRemove,
  });
  @override
  Widget build(BuildContext context) {
    return InputChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onUse,
      onDeleted: onRemove,
    );
  }
}

/// Loading skeleton for the provider list (state #2 of §21).
class RideLoading extends StatelessWidget {
  const RideLoading({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double w) => Container(
          height: 56,
          margin: const EdgeInsets.only(bottom: Gap.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
        );
    return Column(children: [bar(1), bar(1)]);
  }
}

/// Empty-state (no saved places / trips / cravings yet).
class RideEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  const RideEmpty({super.key, required this.icon, required this.message});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(message,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// Error-state (e.g. the open could not be handed off to any app/browser).
class RideError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const RideError({super.key, required this.message, this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, size: 18, color: Brand.danger),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(message,
              style: const TextStyle(fontSize: 12.5, color: Brand.danger)),
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: Text(t.rideFoodRetry)),
      ]),
    );
  }
}
