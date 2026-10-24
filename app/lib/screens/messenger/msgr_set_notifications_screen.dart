import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../../messaging/msg_settings_section.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2
import '../../feature_gates.dart' show kInAppSoundBuilt; // f6

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
  bool _loadFailed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      _loadFailed = false;
    } catch (e) {
      _loadFailed = true;
      _failCause = e; // honest retry, never fake defaults as saved
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(String key, bool value) async {
    final before = _v[key];
    setState(() => _v[key] = value);
    try {
      await _api.setNotificationPrefs({key: value});
      _synced = true;
    } catch (_) {
      _v[key] = before ?? true; // revert: the server didn't take it
      _synced = false;
    }
    if (mounted) setState(() {});
  }

  /// In-app sound / vibration need on-device playback the app doesn't do
  /// yet — shown disabled with the reason instead of a switch that does
  /// nothing.
  Widget _deviceOnly(IconData icon, String title) => ListTile(
        enabled: false,
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(_t.msgNotifInAppNotYet),
      );

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
          : _loadFailed
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(honestFailText(t, _failCause, otherwise: t.msgLoadFailed), textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    FilledButton(
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                        child: Text(t.retry)),
                  ]),
                )
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
                // f6 (no showpieces): in-app sound/vibration rows stay hidden
                // until the app really plays them.
                if (kInAppSoundBuilt) ...[
                  _deviceOnly(Icons.volume_up_outlined, t.msgrSetNotifSound),
                  _deviceOnly(Icons.vibration, t.msgrSetNotifVibrate),
                ],
                _toggle(Icons.remove_red_eye_outlined, 'show_preview',
                    t.msgrSetNotifPreview, t.msgrSetNotifPreviewSub),
                if (!_synced) MsgrSetNote(t.msgrSetNotSynced),
                const Divider(),
                // c3-msg: hide content, message sound, bubbles (this phone).
                const MsgDeviceNotifSection(),
              ],
            ),
    );
  }
}
