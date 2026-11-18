import 'package:flutter/material.dart';

import '../../ds/ds.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../phonecam/phone_camera_screen.dart';
import '../../phonecam/phonecam_pair_sheet.dart';
import '../../widgets/app_sheet.dart';
import 'guard_box_screen.dart';

/// gap-cctv D3 (owner rule "one job = one tile"): ONE entry for every way an
/// old phone or a small box becomes part of a place's CCTV, with sections
/// inside — before there were three separate buttons/screens (pair an old
/// phone, this phone as a camera, the Guard Box reading an IP camera) plus
/// the Linux box only in a README.
///
/// [siteId] null = opened from the CCTV home on the old phone itself (no
/// place to pair to yet), so "pair to this place" is not offered.
Future<void> showOldPhoneHub(BuildContext context,
    {int? siteId, Future<void> Function()? onChanged}) async {
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => OldPhoneHubSheet(siteId: siteId, onChanged: onChanged, host: context),
  );
}

class OldPhoneHubSheet extends StatelessWidget {
  final int? siteId;
  final Future<void> Function()? onChanged;

  /// Tests: whether the Guard Box (IP camera) section is on.
  final bool? guardBoxOn;

  /// The screen that opened the sheet: the next step opens from there (the
  /// sheet's own context is gone once it closes).
  final BuildContext? host;
  const OldPhoneHubSheet({super.key, this.siteId, this.onChanged, this.guardBoxOn, this.host});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final gb = guardBoxOn ?? FeatureFlags.instance.isOn('guard_box_mode');
    final sheetNav = Navigator.of(context);
    final hostCtx = host ?? context;
    final nav = Navigator.of(hostCtx);
    Widget option(Key key, IconData icon, String title, String sub, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DsCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              key: key,
              minTileHeight: 64,
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(sub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onTap,
            ),
          ),
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.gcvHubTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(t.gcvHubIntro),
          const SizedBox(height: 12),
          if (siteId != null)
            option(const Key('gcv-hub-pair'), Icons.qr_code_2_rounded, t.pcOwnerButton,
                t.gcvHubPairSub, () async {
              sheetNav.pop();
              if (hostCtx.mounted) {
                await showPhoneCamPairSheet(hostCtx, siteId!, onPaired: onChanged);
              }
            }),
          option(const Key('gcv-hub-this'), Icons.videocam_outlined, t.pcThisPhoneButton,
              t.gcvHubThisSub, () {
            sheetNav.pop();
            nav.push(MaterialPageRoute(builder: (_) => const PhoneCameraScreen()));
          }),
          if (gb)
            option(const Key('gcv-hub-guardbox'), Icons.router_outlined, t.gbTitle, t.gcvHubGuardBoxSub,
                () {
              sheetNav.pop();
              nav.push(MaterialPageRoute(builder: (_) => const GuardBoxScreen()));
            }),
          const SizedBox(height: 4),
          const GuardBoxLinuxSteps(codeAbove: false),
        ]),
      ),
    );
  }
}
