import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// at100 — Play "prominent disclosure" shown IN THE APP, BEFORE Android's
/// own prompt, for the anti-theft engine's sensitive permissions:
///   [AtDisclosureKind.admin]    device admin (lock the screen, notice wrong
///                               unlocks; no erase) — before the system
///                               "Activate device admin app?" screen
///   [AtDisclosureKind.location] location for the always-on protection
///                               (while-in-use only, never background)
/// Returns true only on "Continue". "Not now" changes nothing.
enum AtDisclosureKind { admin, location }

class AtDisclosure {
  AtDisclosure._();

  static Future<bool> show(BuildContext context, AtDisclosureKind kind) async {
    final tr = AppLocalizations.of(context);
    final admin = kind == AtDisclosureKind.admin;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key(admin ? 'at100-disc-admin' : 'at100-disc-location'),
        icon: Icon(admin ? Icons.admin_panel_settings_outlined
            : Icons.location_on_outlined),
        title: Text(admin ? tr.at100DiscAdminTitle : tr.at100DiscLocTitle),
        content: SingleChildScrollView(
          child: Text(admin ? tr.at100DiscAdminBody : tr.at100DiscLocBody,
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(height: 1.4)),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        actions: [
          TextButton(
              key: const Key('at100-disc-no'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.at100IcNo)),
          FilledButton(
              key: const Key('at100-disc-yes'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.at100DiscContinue)),
        ],
      ),
    );
    return r == true;
  }
}
