import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// k1-wake — Google Play "prominent disclosure" for the background
/// microphone, shown BEFORE the first "Hey Assisto" enable and before the
/// Android permission prompt. Full screen, plain words, an explicit
/// "I agree" button and an equally visible "Not now". Pops `true` only when
/// the user agrees.
class WakeDisclosureScreen extends StatelessWidget {
  const WakeDisclosureScreen({super.key});

  static Future<bool> show(BuildContext context) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => const WakeDisclosureScreen()));
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    final points = <(IconData, String)>[
      (Icons.phonelink_lock_outlined, t.vaWkDisc1),
      (Icons.record_voice_over_outlined, t.vaWkDisc2),
      (Icons.notifications_active_outlined, t.vaWkDisc3),
      (Icons.pause_circle_outline, t.vaWkDisc4),
      (Icons.toggle_off_outlined, t.vaWkDisc5),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: t.vaWkDiscNo,
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.lg),
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                      color: scheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.mic_none_rounded,
                      size: 34, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: Gap.lg),
                Text(t.vaWkDiscTitle,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.md),
                Container(
                  padding: const EdgeInsets.all(Gap.lg),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(t.vaWkDiscLead,
                      style: TextStyle(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                          height: 1.35)),
                ),
                const SizedBox(height: Gap.lg),
                for (final p in points)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.md),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(p.$1, size: 22, color: scheme.primary),
                          const SizedBox(width: Gap.md),
                          Expanded(
                              child: Text(p.$2,
                                  style: const TextStyle(height: 1.35))),
                        ]),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => launchUrl(
                        Uri.parse(lang == 'bn'
                            ? 'https://lifeassisto.com/privacy'
                            : 'https://lifeassisto.com/privacy?lang=en'),
                        mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(t.vaWkDiscPolicy),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, Gap.lg),
            child: Column(children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                    child: Text(t.vaWkDiscAgree, textAlign: TextAlign.center),
                  ),
                ),
              ),
              const SizedBox(height: Gap.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                    child: Text(t.vaWkDiscNo, textAlign: TextAlign.center),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
