import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import 'ads_service.dart';
import 'consent.dart';

/// Settings -> "Ad privacy choices" (L3, Google UMP).
///
/// Rendered ONLY while UMP reports the privacy-options entry point as
/// REQUIRED (Google's rule) — otherwise nothing at all (no dead entry). Without
/// a real AdMob app id in this APK it never asks anything and stays hidden.
/// Tapping re-opens Google's privacy options form.
class AdPrivacyTile extends StatefulWidget {
  const AdPrivacyTile({super.key});

  @override
  State<AdPrivacyTile> createState() => _AdPrivacyTileState();
}

class _AdPrivacyTileState extends State<AdPrivacyTile> {
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
    final ok = await AdConsent.instance.showPrivacyOptions();
    if (!mounted || ok) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).l3AdPrivacyFailed)));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AdConsent.instance.privacyOptionsRequired,
      builder: (context, required, _) {
        if (!required) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        return ListTile(
          key: const Key('settings-ad-privacy'),
          leading: const Icon(Icons.privacy_tip_rounded),
          title: Text(t.l3AdPrivacyTitle),
          subtitle: Text(t.l3AdPrivacySub),
          onTap: _open,
        );
      },
    );
  }
}
