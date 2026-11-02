import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import 'ads_service.dart';
import 'consent.dart';

/// Settings -> "বিজ্ঞাপনের গোপনীয়তা / Ads privacy" (L3 + admobump, Google UMP).
///
///  * UMP says the privacy-options entry point is REQUIRED (EEA/UK/CH, US
///    states once the owner publishes that message): a tappable row that
///    re-opens Google's privacy options form — the user can change or
///    withdraw consent at any time (Google requirement).
///  * UMP says NOT required: one honest, non-tappable line (no consent form
///    in this region; what the ads use) — never a dead button.
///  * Unknown / no real AdMob app id / paid plan (no ads): nothing at all.
class AdPrivacyTile extends StatefulWidget {
  const AdPrivacyTile({super.key});

  @override
  State<AdPrivacyTile> createState() => _AdPrivacyTileState();
}

class _AdPrivacyTileState extends State<AdPrivacyTile> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = AdConsent.instance;
    if (c.active && c.bridge.linked) {
      // Free users only; no-op without a real app id (see AdsService).
      unawaited(AdsService.instance.refreshConsentStatus(context.read<AppState>()));
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AdConsent.instance.showPrivacyOptions();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).l3AdPrivacyFailed)));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PrivacyOptionsStatus>(
      valueListenable: AdConsent.instance.privacyStatus,
      builder: (context, status, _) {
        final t = AppLocalizations.of(context);
        final c = AdConsent.instance;
        // no AdMob consent flow in this APK, or a paid plan (zero ads)
        if (!c.active || !c.bridge.linked || AdsService.instance.config.paid) {
          return const SizedBox.shrink();
        }
        switch (status) {
          case PrivacyOptionsStatus.required:
            return ListTile(
              key: const Key('settings-ad-privacy'),
              minTileHeight: 56,
              leading: const Icon(Icons.privacy_tip_rounded),
              title: Text(t.adsPrivacyTitle),
              subtitle: Text(t.adsPrivacySub),
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : _open,
            );
          case PrivacyOptionsStatus.notRequired:
            // honest line, not a button: nothing to change in this region
            return MergeSemantics(
              child: ListTile(
                key: const Key('settings-ad-privacy-info'),
                minTileHeight: 56,
                leading: const Icon(Icons.privacy_tip_outlined),
                title: Text(t.adsPrivacyTitle),
                subtitle: Text(t.adsPrivacyNotRequired),
              ),
            );
          case PrivacyOptionsStatus.unknown:
            return const SizedBox.shrink();
        }
      },
    );
  }
}
