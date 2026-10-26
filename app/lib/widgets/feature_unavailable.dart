import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// feature-flags: what a user sees when an old link, notification, chat reply
/// or saved shortcut points at a feature that is switched off for them — a
/// short, friendly notice and one tap back. Never a crash, never a blank page.
class FeatureUnavailableScreen extends StatelessWidget {
  const FeatureUnavailableScreen({super.key});

  /// In-place notice (SnackBar) when a ScaffoldMessenger is around, else the
  /// full page.
  static void notify(BuildContext context) {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    if (m != null) {
      m
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            key: const ValueKey('feature_unavailable_snack'),
            content: Text(t.ffUnavailableBody)));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const FeatureUnavailableScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      key: const ValueKey('feature_unavailable'),
      appBar: AppBar(title: Text(t.ffUnavailableTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.hourglass_empty_rounded,
                  size: 56, color: scheme.onSurfaceVariant),
              const SizedBox(height: Gap.md),
              Text(t.ffUnavailableBody,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: Gap.lg),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.ffUnavailableBack),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
