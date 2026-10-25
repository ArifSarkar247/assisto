import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/media/media_store.dart'; // md1
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';

/// Storage & data for the hub: a usage breakdown (total / media / docs / cache)
/// and the media auto-download policy (photos / audio / video / docs). Usage
/// comes from [MessengerSettingsApi.storageUsage]; the auto-download toggles
/// persist via setStoragePrefs. If the server route isn't live, the screen
/// shows an honest "usage unavailable yet" state and still lets the user set
/// (on-device) auto-download preferences — no dead tap.
class MsgrSetStorageScreen extends StatefulWidget {
  const MsgrSetStorageScreen({super.key});

  @override
  State<MsgrSetStorageScreen> createState() => _MsgrSetStorageScreenState();
}

class _MsgrSetStorageScreenState extends State<MsgrSetStorageScreen> {
  bool _loading = true;
  bool _usageAvailable = false;
  Map<String, dynamic> _usage = {};
  // md1: device-level media auto-download (WhatsApp-like defaults).
  bool _wifi = true;
  final Map<String, bool> _mobile = {'photo': false, 'voice': false, 'document': false, 'video': false};

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _wifi = await MediaPrefs.wifiAuto();
    for (final k in _mobile.keys.toList()) {
      _mobile[k] = await MediaPrefs.mobileAuto(k);
    }
    try {
      final r = await _api.storageUsage();
      _usage = r;
      _usageAvailable = true;
    } catch (_) {
      _usageAvailable = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  // QA a6: sizes in the app's digits (was "0 MB" in Latin in Bangla).
  String _mb(dynamic bytes) {
    final b = (bytes is num) ? bytes.toDouble() : 0.0;
    final mb = b / (1024 * 1024);
    final s = b <= 0
        ? '0 MB'
        : mb >= 1024
            ? '${(mb / 1024).toStringAsFixed(1)} GB'
            : '${mb.toStringAsFixed(1)} MB';
    return notifLocalizeDigits(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetStorage)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                MsgrSetSection(t.msgrSetStorageUsageSection),
                if (_usageAvailable) ...[
                  MsgrSetRow(
                    icon: Icons.sd_storage_rounded,
                    title: t.msgrSetStorageTotal,
                    value: _mb(_usage['total_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.photo_rounded,
                    title: t.msgrSetStorageMedia,
                    value: _mb(_usage['media_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.description_rounded,
                    title: t.msgrSetStorageDocs,
                    value: _mb(_usage['docs_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.backup_rounded,
                    title: t.msgStorageBackups,
                    value: _mb(_usage['backup_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.data_usage_rounded,
                    title: t.msgStorageQuota,
                    value: _mb(_usage['quota_bytes']),
                  ),
                ] else
                  MsgrSetNote(t.msgrSetStorageUnavailable,
                      icon: Icons.info_outline_rounded),
                // md1: My Circle chats carry E2E photos / voice / documents.
                MsgrSetSection(t.md1SetAutoTitle),
                SwitchListTile(
                  key: const Key('md1-auto-wifi'),
                  secondary: const Icon(Icons.wifi_rounded),
                  title: Text(t.md1SetWifi),
                  subtitle: Text(t.md1SetWifiSub),
                  value: _wifi,
                  onChanged: (v) async {
                    setState(() => _wifi = v);
                    await MediaPrefs.setWifiAuto(v);
                  },
                ),
                MsgrSetSection(t.md1SetMobileTitle),
                for (final (k, icon, label) in [
                  ('photo', Icons.photo_rounded, t.md1SetMobilePhotos),
                  ('voice', Icons.mic_none_rounded, t.md1SetMobileVoice),
                  ('document', Icons.description_rounded, t.md1SetMobileDocs),
                  ('video', Icons.videocam_rounded, t.mc2SetMobileVideo), // mc-media2
                ])
                  SwitchListTile(
                    key: Key('md1-auto-mobile-$k'),
                    secondary: Icon(icon),
                    title: Text(label),
                    value: _mobile[k] ?? false,
                    onChanged: (v) async {
                      setState(() => _mobile[k] = v);
                      await MediaPrefs.setMobileAuto(k, v);
                    },
                  ),
                MsgrSetNote(t.md1SetKeepNote, icon: Icons.lock_outline_rounded),
              ],
            ),
    );
  }
}
