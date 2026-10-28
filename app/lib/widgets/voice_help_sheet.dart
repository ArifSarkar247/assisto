import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../voice/va_native.dart';

/// aivoice: the honest "Turn on Bangla voice" steps. Shown from the
/// "no Bangla" / "needs speech services" messages and from Settings -> Voice.
///
/// Why: on Realme/OPPO (ColorOS) and Xiaomi (MIUI/HyperOS) the default speech
/// engine is often NOT Google, so Bangla dictation fails with a bare error in
/// every app. Nobody explains it; we do, phone by phone, with buttons that
/// open the right settings page. Assisto never records or keeps the voice.
class VoiceHelpSheet extends StatelessWidget {
  const VoiceHelpSheet({super.key});

  static const googleAppPlay =
      'https://play.google.com/store/apps/details?id=com.google.android.googlequicksearchbox';

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const VoiceHelpSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.4);

    Widget step(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ExcludeSemantics(child: Icon(icon, size: 22, color: scheme.primary)),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
          ]),
        );

    void failed() {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.vaSettingsOpenFailed)));
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: SingleChildScrollView(
          key: const ValueKey('voice_help_sheet'),
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(t.aivHelpTitle,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.aivHelpIntro, style: muted),
            const SizedBox(height: Gap.lg),
            step(Icons.download_rounded, t.aivHelpStep1),
            step(Icons.offline_bolt_rounded, t.aivHelpStep2),
            step(Icons.phone_android_rounded, t.aivHelpColorOs),
            step(Icons.phone_android_rounded, t.aivHelpMiui),
            step(Icons.phone_android_rounded, t.aivHelpSamsung),
            step(Icons.record_voice_over_rounded, t.aivHelpTts),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              key: const ValueKey('voice_help_open_input'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                if (!await VaNative.openVoiceInputSettings()) failed();
              },
              icon: const Icon(Icons.settings_voice_rounded),
              label: Text(t.aivHelpOpenVoiceInput),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              key: const ValueKey('voice_help_get_google'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                var ok = false;
                try {
                  ok = await launchUrl(Uri.parse(googleAppPlay),
                      mode: LaunchMode.externalApplication);
                } catch (_) {
                  // best-effort: no browser / Play Store on this phone —
                  // failed() below tells the user plainly.
                }
                if (!ok) failed();
              },
              icon: const Icon(Icons.shop_rounded),
              label: Text(t.aivHelpGetGoogle),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              key: const ValueKey('voice_help_open_tts'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                if (!await VaNative.openTtsSettings()) failed();
              },
              icon: const Icon(Icons.record_voice_over_rounded),
              label: Text(t.vaTtsInstallBn),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
