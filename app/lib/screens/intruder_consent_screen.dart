import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// at100 — the intruder-photo CONSENT screen (prominent disclosure). Shown
/// BEFORE the camera permission prompt, every time the owner switches the
/// option on. It says plainly: what, when (only while Assisto is open, after
/// wrong Security PINs — never the lock screen, never the background), that
/// it is not hidden (shutter sound + camera dot + a line on every PIN box),
/// where it is kept, who sees it, how long, how to turn it off / delete, and
/// the "your own phone only" rule. Returns true only on "I agree".
///
/// [consentVersion] is sent to the server with the setting; the server
/// refuses to switch the photo on without it (core/views_at_remote.py).
class IntruderConsentScreen extends StatelessWidget {
  static const consentVersion = 1;

  const IntruderConsentScreen({super.key});

  static Future<bool> ask(BuildContext context) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          fullscreenDialog: true, builder: (_) => const IntruderConsentScreen()),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget item(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Semantics(
            container: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.xxs),
                      Text(body, style: text.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr.at100IcTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  Text(tr.at100IcLead, style: text.bodyLarge),
                  const SizedBox(height: Gap.sm),
                  item(Icons.photo_camera_front_outlined, tr.at100IcWhatT,
                      tr.at100IcWhat),
                  item(Icons.schedule_rounded, tr.at100IcWhenT, tr.at100IcWhen),
                  item(Icons.campaign_outlined, tr.at100IcNoticeT, tr.at100IcNotice),
                  item(Icons.lock_outline_rounded, tr.at100IcWhereT, tr.at100IcWhere),
                  item(Icons.people_outline_rounded, tr.at100IcWhoT, tr.at100IcWho),
                  item(Icons.auto_delete_outlined, tr.at100IcKeepT, tr.at100IcKeep),
                  item(Icons.toggle_off_outlined, tr.at100IcDeleteT, tr.at100IcDelete),
                  const SizedBox(height: Gap.sm),
                  Card(
                    color: Brand.warning.withValues(alpha: 0.14),
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.md),
                      child: Text(tr.at100IcLaw,
                          style: text.bodyMedium
                              ?.copyWith(color: Brand.warnInk(context))),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    key: const Key('at100-ic-agree'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr.at100IcAgree, textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: Gap.sm),
                  OutlinedButton(
                    key: const Key('at100-ic-no'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr.at100IcNo),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
