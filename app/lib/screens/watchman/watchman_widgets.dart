import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../shop_box_mode_screen.dart';
import 'watchman_source.dart';

/// cctv1 shared pieces: the 30-second guide, the honest gateway status line,
/// the pairing sheet, the staff/visitor notice sheet and alert wording.

String wmLang(BuildContext context) => Localizations.localeOf(context).languageCode;

/// "Online" / "Offline since …" / "Never connected" for a gateway state map
/// ({online, last_seen, never_seen}) from the server.
String wmGatewayLine(AppLocalizations t, BuildContext context, Map<String, dynamic> g) {
  if (g['online'] == true) return t.wmGatewayOnline;
  final dt = DateTime.tryParse((g['last_seen'] ?? '').toString())?.toLocal();
  if (dt == null) return t.wmGatewayNever;
  final loc = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
  final time = loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt));
  return t.wmGatewayOfflineSince(sameDay ? time : '${loc.formatShortDate(dt)} $time');
}

String wmGatewayName(AppLocalizations t, String g) => switch (g) {
      'phone' => t.wmGwPhone,
      'shopbox' => t.wmGwShopbox,
      'pc' => t.wmGwPc,
      _ => t.wmGwNone,
    };

String wmVendorName(AppLocalizations t, String v) => switch (v) {
      'imou' => 'Imou',
      'hikvision' => 'Hikvision',
      'dahua' => 'Dahua',
      'tapo' => 'TP-Link Tapo',
      'ezviz' => 'EZVIZ',
      'onvif' => t.wmVendorOnvif,
      'rtsp' => t.wmVendorRtsp,
      'phone' => t.wmVendorPhone,
      _ => t.wmVendorOther,
    };

/// What an alert is about, in plain words — never accusatory.
String wmEventWhat(AppLocalizations t, String type) => switch (type) {
      'person_detected' => t.wmEvPerson,
      'zone_intrusion' => t.wmEvZone,
      'line_crossing' => t.wmEvLine,
      'camera_alarm' => t.wmEvCameraAlarm,
      'after_hours' => t.wmEvAfterHours,
      'hand_in_cash_zone' => t.wmEvCash,
      'drawer_open' => t.wmEvDrawer,
      'pose_possible' => t.wmEvMaybe,
      'eod_mismatch' => t.wmEvEod,
      'void_spike' || 'refund_spike' || 'discount_spike' => t.wmEvPos,
      _ => t.wmEvMotion,
    };

/// The 3-step "how it works" explainer (first run + the help button).
class WatchmanGuideCard extends StatelessWidget {
  final VoidCallback? onClose;
  const WatchmanGuideCard({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, size: 20, color: scheme.onPrimaryContainer)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(body),
            ])),
          ]),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.wmGuideTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          step(Icons.router_outlined, t.wmGuide1Title, t.wmGuide1Body),
          step(Icons.videocam_outlined, t.wmGuide2Title, t.wmGuide2Body),
          step(Icons.notifications_active_outlined, t.wmGuide3Title, t.wmGuide3Body),
          const SizedBox(height: 4),
          Text(t.wmGuidePrivacy, style: Theme.of(context).textTheme.bodySmall),
          if (onClose != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: onClose,
                  child: Text(t.wmGuideGotIt)),
            ),
        ]),
      ),
    );
  }
}

/// Pairing: the site code (+ QR) and what to do on the chosen gateway.
Future<void> showWatchmanPairSheet(BuildContext context, Map<String, dynamic> site) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => WatchmanPairSheet(site: site),
  );
}

class WatchmanPairSheet extends StatelessWidget {
  final Map<String, dynamic> site;
  const WatchmanPairSheet({super.key, required this.site});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final token = (site['enrollment_token'] ?? '').toString();
    final gw = (site['gateway'] ?? '').toString();
    final steps = gw == 'phone'
        ? [t.wmPairPhone1, t.wmPairPhone2, t.wmPairPhone3]
        : [t.wmPairPc1, t.wmPairPc2, t.wmPairPc3];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(t.wmPairTitle(wmGatewayName(t, gw)),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${wmDigits(wmLang(context), i + 1)}. ${steps[i]}'),
            ),
          const SizedBox(height: 8),
          if (token.isNotEmpty) ...[
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: SizedBox.square(
                    dimension: 168, child: QrImageView(data: token, size: 168)),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(token, textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.copy_rounded),
                label: Text(t.wmPairCopy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(t.wmPairCopied)));
                  }
                },
              ),
              if (gw == 'phone')
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.phone_android_rounded),
                  label: Text(t.wmPairThisPhone),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ShopBoxModeScreen(initialToken: token))),
                ),
            ]),
          ],
          const SizedBox(height: 12),
          Text(t.wmPairSecretNote, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The staff / household-helper / visitor notice (server text, bn or en).
Future<void> showWatchmanNoticeSheet(BuildContext context, Map<String, dynamic> notice) {
  final t = AppLocalizations.of(context);
  final lang = wmLang(context);
  final text = (notice[lang] ?? notice['en'] ?? '').toString();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(t.wmNoticeTitle, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(t.wmNoticeWhy),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12)),
            child: SelectableText(text.isEmpty ? t.wmNoticeUnavailable : text),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.share_rounded),
              label: Text(t.wmNoticeShare),
              onPressed: text.isEmpty ? null : () => Share.share(text),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.copy_rounded),
              label: Text(t.wmPairCopy),
              onPressed: text.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: text)),
            ),
          ]),
        ],
      ),
    ),
  );
}

/// A small coloured status pill (always text + icon, never colour alone).
class WmPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const WmPill({super.key, required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? Color.lerp(color, Colors.white, 0.45)! : Color.lerp(color, Colors.black, 0.35)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.22 : 0.14),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

Color wmOk() => Brand.success;
Color wmWarn() => Brand.warning;
Color wmBad() => Brand.danger;
