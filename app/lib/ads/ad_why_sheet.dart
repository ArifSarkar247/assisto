import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'ad_privacy_tile.dart' show AdPrivacyTile;
import 'admob_sdk.dart';
import 'consent.dart';

/// ads-nine (row 54): the localized "Ad" label on every ad Assisto draws
/// (banner, native card, home card). Tapping it opens [AdWhySheet] — an
/// honest "Why am I seeing this ad?" (AdMob's own AdChoices icon stays on
/// the ad itself). 48 dp tap target; TalkBack reads "Ad. Why this ad?".
///
/// [whyIcon] adds a small (i) inside the chip. Home keeps its frozen look
/// (owner rule: Home layout never changes), so Home passes false — the chip
/// is still tappable there.
class AdLabelChip extends StatelessWidget {
  const AdLabelChip({
    super.key,
    this.onRemoveAds,
    this.whyIcon = true,
    this.labelKey = const ValueKey('ad-label-chip'),
  });

  final VoidCallback? onRemoveAds;
  final bool whyIcon;
  final Key labelKey;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final chip = Container(
      key: labelKey,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(t.h1AdLabel,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.onTertiaryContainer)),
        if (whyIcon) ...[
          const SizedBox(width: 3),
          Icon(Icons.info_outline_rounded,
              size: 14, color: scheme.onTertiaryContainer),
        ],
      ]),
    );
    return Semantics(
      button: true,
      label: '${t.h1AdLabel}. ${t.adWhyTapLabel}',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('ad-why-open'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => AdWhySheet.show(context, onRemoveAds: onRemoveAds),
        // 48 dp target where the chip has the (i); on the frozen Home the
        // row keeps its old height (the Remove-ads link beside it is 48 dp)
        child: whyIcon
            ? ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1,
                    child: chip),
              )
            : chip,
      ),
    );
  }
}

/// The "Why am I seeing this ad?" sheet. Every line is TRUE for this build:
///  * Assisto sends Google no name, phone, contacts, messages or location
///    (AdmobSdk.request() builds a bare AdRequest — no keywords, no
///    content URL, no custom targeting; test/ads_why_test.dart guards it);
///  * personalised only where UMP says no consent is needed AND the owner
///    allows it ([AdmobSdk.personalisedNow]); otherwise non-personalised;
///  * never on SOS / calls / safety / child / Quran / blood / payment /
///    login / permission screens (AdBlockContext + AdRules);
///  * Premium removes every ad.
class AdWhySheet extends StatelessWidget {
  const AdWhySheet({super.key, this.onRemoveAds, this.personalised});

  final VoidCallback? onRemoveAds;

  /// Test seam; null = ask [AdmobSdk.personalisedNow].
  final bool? personalised;

  static Future<void> show(BuildContext context, {VoidCallback? onRemoveAds}) =>
      showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => AdWhySheet(onRemoveAds: onRemoveAds),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = personalised ?? AdmobSdk.personalisedNow;
    Widget line(IconData icon, String text, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(text,
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(height: 1.4, color: scheme.onSurface))),
          ]),
        );
    return SingleChildScrollView(
      key: const ValueKey('ad-why-sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(t.adWhyTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: Gap.md),
          line(Icons.volunteer_activism_outlined, t.adWhyFree),
          line(Icons.storefront_outlined, t.adWhyGoogle),
          line(Icons.lock_outline_rounded, t.adWhyNoShare),
          line(Icons.tune_rounded, p ? t.adWhyPersonal : t.adWhyNonPersonal,
              key: ValueKey(p ? 'ad-why-personal' : 'ad-why-nonpersonal')),
          line(Icons.shield_outlined, t.adWhyNever),
          if (onRemoveAds != null) ...[
            const SizedBox(height: Gap.sm),
            FilledButton(
              key: const ValueKey('ad-why-remove'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () {
                Navigator.of(context).pop();
                onRemoveAds!();
              },
              child: Text(t.adWhyRemove, textAlign: TextAlign.center),
            ),
          ],
          // the UMP privacy-options entry, only where Google says required
          ValueListenableBuilder<bool>(
            valueListenable: AdConsent.instance.privacyOptionsRequired,
            builder: (_, req, __) => req
                ? const Padding(
                    padding: EdgeInsets.only(top: Gap.sm),
                    child: AdPrivacyTile())
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const ValueKey('ad-why-close'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.close),
          ),
        ],
      ),
    );
  }
}
