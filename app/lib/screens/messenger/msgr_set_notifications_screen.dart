import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';

/// Notification preferences for the hub. Toggles are mirrored to the server via
/// [MessengerSettingsApi.notificationPrefs] / setNotificationPrefs so they
/// follow the account across devices; if the server route isn't live the UI
/// keeps the chosen values on-device and shows an honest "not yet synced" note
/// (no dead tap, no silent loss).
class MsgrSetNotificationsScreen extends StatefulWidget {
  const MsgrSetNotificationsScreen({super.key});

  @override
  State<MsgrSetNotificationsScreen> createState() =>
      _MsgrSetNotificationsScreenState();
}

class _MsgrSetNotificationsScreenState
    extends State<MsgrSetNotificationsScreen> {
  bool _loading = true;
  bool _synced = true;

  // Safe defaults — everything on, no preview suppression.
  final Map<String, bool> _v = {
    'messages': true,
    'groups': true,
    'calls': true,
    'in_app_sound': true,
    'in_app_vibrate': true,
    'show_preview': true,
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
      final r = await _api.notificationPrefs();
      for (final k in _v.keys) {
        if (r[k] is bool) _v[k] = r[k] as bool;
      }
      _synced = true;
    } catch (_) {
      _synced = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(String key, bool value) async {
    setState(() => _v[key] = value);
    try {
      await _api.setNotificationPrefs(Map<String, dynamic>.from(_v));
      _synced = true;
    } catch (_) {
      _synced = false;
    }
    if (mounted) setState(() {});
  }

  SwitchListTile _toggle(
          IconData icon, String key, String title, String sub) =>
      SwitchListTile(
        secondary: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(sub),
        value: _v[key] ?? true,
        onChanged: (x) => _save(key, x),
      );

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetNotifications)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                MsgrSetSection(t.msgrSetNotifMessagesSection),
                _toggle(Icons.chat_bubble_outline, 'messages',
                    t.msgrSetNotifMessages, t.msgrSetNotifMessagesSub),
                _toggle(Icons.groups_outlined, 'groups',
                    t.msgrSetNotifGroups, t.msgrSetNotifGroupsSub),
                _toggle(Icons.call_outlined, 'calls', t.msgrSetNotifCalls,
                    t.msgrSetNotifCallsSub),
                const Divider(),
                MsgrSetSection(t.msgrSetNotifInAppSection),
                _toggle(Icons.volume_up_outlined, 'in_app_sound',
                    t.msgrSetNotifSound, t.msgrSetNotifSoundSub),
                _toggle(Icons.vibration, 'in_app_vibrate',
                    t.msgrSetNotifVibrate, t.msgrSetNotifVibrateSub),
                _toggle(Icons.remove_red_eye_outlined, 'show_preview',
                    t.msgrSetNotifPreview, t.msgrSetNotifPreviewSub),
                if (!_synced) MsgrSetNote(t.msgrSetNotSynced),
              ],
            ),
    );
  }
}
