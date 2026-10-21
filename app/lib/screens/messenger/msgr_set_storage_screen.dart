import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
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

  final Map<String, bool> _autoDl = {
    'photos': true,
    'audio': false,
    'video': false,
    'docs': false,
  };

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.storageUsage();
      _usage = r;
      final ad = (r['auto_download'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final k in _autoDl.keys) {
        if (ad[k] is bool) _autoDl[k] = ad[k] as bool;
      }
      _usageAvailable = true;
    } catch (_) {
      _usageAvailable = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveAutoDl(String key, bool v) async {
    setState(() => _autoDl[key] = v);
    try {
      await _api.setStoragePrefs(
          {'auto_download': Map<String, dynamic>.from(_autoDl)});
    } catch (_) {}
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
                    icon: Icons.sd_storage_outlined,
                    title: t.msgrSetStorageTotal,
                    value: _mb(_usage['total_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.photo_outlined,
                    title: t.msgrSetStorageMedia,
                    value: _mb(_usage['media_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.description_outlined,
                    title: t.msgrSetStorageDocs,
                    value: _mb(_usage['docs_bytes']),
                  ),
                  MsgrSetRow(
                    icon: Icons.cached_outlined,
                    title: t.msgrSetStorageCache,
                    value: _mb(_usage['cache_bytes']),
                  ),
                ] else
                  MsgrSetNote(t.msgrSetStorageUnavailable,
                      icon: Icons.info_outline),
                const Divider(),
                MsgrSetSection(t.msgrSetStorageAutoDlSection),
                for (final e in <(String, IconData, String)>[
                  ('photos', Icons.image_outlined, t.msgrSetStoragePhotos),
                  ('audio', Icons.audiotrack_outlined, t.msgrSetStorageAudio),
                  ('video', Icons.videocam_outlined, t.msgrSetStorageVideo),
                  ('docs', Icons.insert_drive_file_outlined,
                      t.msgrSetStorageDocsDl),
                ])
                  SwitchListTile(
                    secondary: Icon(e.$2),
                    title: Text(e.$3,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    value: _autoDl[e.$1] ?? false,
                    onChanged: (v) => _saveAutoDl(e.$1, v),
                  ),
                MsgrSetNote(t.msgrSetStorageAutoDlHint),
              ],
            ),
    );
  }
}
