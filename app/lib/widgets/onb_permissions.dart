import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The HONEST permissions step. We do NOT request anything here — we simply
/// explain, up front, every permission Assisto might later ask for and exactly
/// WHY, so the real OS prompt (shown lazily by the feature that needs it, via
/// permission_reason.dart) is never a surprise. Play-policy friendly and builds
/// trust. All strings localized; zero Bangla in this file.
class OnbPermissions extends StatelessWidget {
  const OnbPermissions({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // (icon, title, why).
    // playall: mic + location rows have their own honest summary (voice
    // notes and calls ARE sent; Safe Journey / Voice SOS / anti-theft keep
    // location with the app closed); each feature still shows its own
    // disclosure right before the Android prompt.
    final rows = <(IconData, String, String)>[
      (Icons.notifications_active_rounded, t.onbPermNotifTitle,
          t.onbPermNotifWhy),
      (Icons.mic_none_rounded, t.onbPermMicTitle, t.onbPermMicWhy2),
      (Icons.photo_camera_rounded, t.onbPermCameraTitle, t.permCamera),
      (Icons.location_on_rounded, t.onbPermLocationTitle, t.onbPermLocWhy2),
      (Icons.contacts_rounded, t.onbPermContactsTitle, t.onbPermContactsWhy),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Icon(Icons.verified_user_rounded, size: 40, color: scheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.onbPermTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.onbPermSub,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: _permRow(scheme, r.$1, r.$2, r.$3),
          ),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.onbPermFootnote,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurfaceVariant)),
          ),
        ]),
      ],
    );
  }

  Widget _permRow(
      ColorScheme scheme, IconData icon, String title, String why) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 22, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.md),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(why,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}
