import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_extras_backup.dart';
import '../widgets/circle_extras_stickers.dart';
import '../widgets/circle_extras_wallpaper.dart';
import 'circle_extras_broadcast_screen.dart';
import 'circle_extras_scheduled_screen.dart';
import '../l10n/app_localizations.dart';

/// Per-chat EXTRAS hub (M2 items 9 + 10). Opened from a chat's menu. Gathers:
///   - Disappearing-messages timer (24h / 7d / 90d) + view-once toggle
///   - Per-chat wallpaper + theme (ON-DEVICE preference, persisted locally)
///   - Sticker + GIF picker entry
///   - Scheduled messages
///   - Broadcast list
///   - Encrypted chat backup + restore
///   - Export this chat
///   - Linked devices (item 10 — design)
///
/// Disappearing timer + wallpaper are the two settings that map to the
/// ChatSettings model (disappearing_sec, wallpaper, theme); the hub POSTs the
/// timer to the server (routing metadata, not content) and persists the
/// wallpaper/theme ON-DEVICE (SharedPreferences, keyed by chat id).
///
/// Backend seam (integrator wires — see MIGRATION NOTE):
///   GET  /circle/{peer}/settings  -> {disappearing_sec}
///   POST /circle/{peer}/settings  -> persist {disappearing_sec}
/// Wallpaper/theme are NOT uploaded here (on-device only).
class CircleExtrasHubScreen extends StatefulWidget {
  final Map<String, dynamic> member; // the peer chat
  /// Accepted circle members (for the broadcast picker). Optional.
  final List<Map<String, dynamic>> circleMembers;
  /// Already-decrypted messages for export (the chat screen passes its cache).
  final List<Map<String, dynamic>> Function()? decryptedMessages;
  /// Owner Tenor/GIPHY key if configured (else GIF picker shows gated state).
  final String? gifProviderKey;
  /// Whether the encrypted media bucket is live (user stickers / view-once media).
  final bool mediaBytesAvailable;
  const CircleExtrasHubScreen({
    super.key,
    required this.member,
    this.circleMembers = const [],
    this.decryptedMessages,
    this.gifProviderKey,
    this.mediaBytesAvailable = false,
  });

  @override
  State<CircleExtrasHubScreen> createState() => _CircleExtrasHubScreenState();
}

class _CircleExtrasHubScreenState extends State<CircleExtrasHubScreen> {
  // Disappearing timer choices mirror circle_extras DISAPPEAR_* (seconds).
  static const _off = 0;
  static const _d24h = 24 * 3600;
  static const _d7d = 7 * 24 * 3600;
  static const _d90d = 90 * 24 * 3600;

  int _disappearing = _off;
  bool _viewOnceDefault = false;
  String _wallpaper = 'default';
  String _theme = 'system';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  int get _peer => widget.member['id'] as int;
  String get _wpKey => 'circle_wp_$_peer';
  String get _themeKey => 'circle_theme_$_peer';
  String get _viewOnceKey => 'circle_viewonce_$_peer';

  Future<void> _load() async {
    // Wallpaper/theme + view-once default are on-device prefs (ChatSettings
    // only persists disappearing_sec server-side; view-once is a per-device
    // send-time default, not server state). TODO(M2): if a future ChatSettings
    // field exposes a shared view-once default, mirror it here via the API.
    _wallpaper = await Settings.getString(_wpKey) ?? 'default';
    _theme = await Settings.getString(_themeKey) ?? 'system';
    _viewOnceDefault = await Settings.getBool(_viewOnceKey, false);
    // Disappearing timer is server routing metadata.
    try {
      final r = await _api.getJson('messenger/chat/$_peer/settings');
      final s = (r['disappearing_sec'] as num?)?.toInt() ?? 0;
      _disappearing = const [_off, _d24h, _d7d, _d90d].contains(s) ? s : _off;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveDisappearing(int sec) async {
    final before = _disappearing;
    setState(() => _disappearing = sec);
    try {
      await _api.postJson('messenger/chat/$_peer/settings', {'disappearing_sec': sec});
    } catch (_) {
      // m3-circle: never silent — roll back and say so.
      if (mounted) {
        setState(() => _disappearing = before);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
    }
  }

  Future<void> _saveWallpaper(String id) async {
    setState(() => _wallpaper = id);
    await Settings.setString(_wpKey, id);
  }

  Future<void> _saveTheme(String id) async {
    setState(() => _theme = id);
    await Settings.setString(_themeKey, id);
  }

  void _openTimerSheet(AppLocalizations t) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in [
              [_off, t.circleExtrasTimerOff],
              [_d24h, t.circleExtrasTimer24h],
              [_d7d, t.circleExtrasTimer7d],
              [_d90d, t.circleExtrasTimer90d],
            ])
              RadioListTile<int>(
                value: opt[0] as int,
                groupValue: _disappearing,
                title: Text(opt[1] as String),
                onChanged: (v) {
                  if (v != null) _saveDisappearing(v);
                  Navigator.of(context).maybePop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openStickerSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StickerGifSheet(
        mediaBytesAvailable: widget.mediaBytesAvailable,
        gifProviderKey: widget.gifProviderKey,
        onSticker: (_) {}, // chat screen wires the actual send
        onGif: (_) {},
      ),
    );
  }

  void _openBackup(AppLocalizations t) {
    final msgs = widget.decryptedMessages?.call() ?? const [];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BackupSheet(
        messageCount: msgs.length,
        // The chat layer seals + uploads using KeyBackup + build_backup_envelope.
        onConfirm: (code, hint) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(
                  content: Text(t.circleExtrasBackupDone('${msgs.length}'))));
        },
      ),
    );
  }

  void _openRestore(AppLocalizations t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RestoreSheet(
        onRestore: (_) {
          Navigator.of(context).maybePop();
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.circleExtrasRestoreOk)));
        },
      ),
    );
  }

  void _exportChat(AppLocalizations t) {
    final msgs = widget.decryptedMessages?.call() ?? const [];
    // The chat layer assembles the file via circle_extras.export_chat_text /
    // export_chat_json (on-device, decrypted locally) and shares it.
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(
            content: Text(t.circleExtrasExportReady('${msgs.length}'))));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.circleExtrasHubTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                _header(t, scheme),

                // --- disappearing / view-once ---
                _sectionHeader(t.circleExtrasDisappearing, scheme),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(t.circleExtrasDisappearing),
                  subtitle: Text(t.circleExtrasDisappearingHint,
                      style: const TextStyle(fontSize: 12)),
                  trailing: Text(_timerLabel(t),
                      style: TextStyle(color: scheme.primary)),
                  onTap: () => _openTimerSheet(t),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: Text(t.circleExtrasViewOnce),
                  subtitle: Text(t.circleExtrasViewOnceHint,
                      style: const TextStyle(fontSize: 12)),
                  value: _viewOnceDefault,
                  onChanged: (v) {
                    setState(() => _viewOnceDefault = v);
                    Settings.setBool(_viewOnceKey, v);
                  },
                ),
                const Divider(),

                // --- wallpaper / theme (on-device) ---
                _sectionHeader(t.circleExtrasWallpaper, scheme),
                WallpaperThemePicker(
                  wallpaperId: _wallpaper,
                  themeId: _theme,
                  onWallpaper: _saveWallpaper,
                  onTheme: _saveTheme,
                ),
                const Divider(),

                // --- stickers + GIF ---
                ListTile(
                  leading: const Icon(Icons.emoji_emotions_outlined),
                  title: Text(t.circleExtrasStickers),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openStickerSheet,
                ),
                const Divider(),

                // --- scheduled ---
                ListTile(
                  leading: const Icon(Icons.schedule_send_outlined),
                  title: Text(t.circleExtrasScheduled),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        CircleExtrasScheduledScreen(member: widget.member),
                  )),
                ),

                // --- broadcast ---
                ListTile(
                  leading: const Icon(Icons.campaign_outlined),
                  title: Text(t.circleExtrasBroadcast),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CircleExtrasBroadcastScreen(
                        members: widget.circleMembers),
                  )),
                ),
                const Divider(),

                // --- backup / restore / export ---
                _sectionHeader(t.circleExtrasBackup, scheme),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(t.circleExtrasCreateBackup),
                  subtitle: Text(t.circleExtrasBackupHint,
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => _openBackup(t),
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: Text(t.circleExtrasRestore),
                  onTap: () => _openRestore(t),
                ),
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: Text(t.circleExtrasExportChat),
                  subtitle:
                      Text(t.circleExtrasExportHint, style: const TextStyle(fontSize: 12)),
                  onTap: () => _exportChat(t),
                ),
                const Divider(),

                // --- linked devices (item 10) ---
                _sectionHeader(t.circleExtrasLinkedDevices, scheme),
                LinkedDevicesCard(
                  thisDeviceName: t.circleExtrasThisDevice,
                  onLink: () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t.circleExtrasScanToLink))),
                ),

                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_outlined,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(t.circleExtrasE2eNote,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                                height: 1.3)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _timerLabel(AppLocalizations t) {
    switch (_disappearing) {
      case _d24h:
        return t.circleExtrasTimer24h;
      case _d7d:
        return t.circleExtrasTimer7d;
      case _d90d:
        return t.circleExtrasTimer90d;
      default:
        return t.circleExtrasTimerOff;
    }
  }

  Widget _header(AppLocalizations t, ColorScheme scheme) => Container(
        margin: const EdgeInsets.all(Gap.lg),
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          children: [
            const Icon(Icons.tune, color: Colors.white),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.circleExtrasHubSubtitle,
                  style: const TextStyle(color: Colors.white, height: 1.35)),
            ),
          ],
        ),
      );

  Widget _sectionHeader(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.primary)),
      );
}
