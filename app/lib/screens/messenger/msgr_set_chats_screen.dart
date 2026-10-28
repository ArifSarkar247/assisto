import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/circle_extras_backup.dart';
import '../../widgets/circle_extras_wallpaper.dart';
import '../../widgets/msgr_set_tiles.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../feature_gates.dart' show kMsgrChatBackupWired; // f6

/// Chats settings for the hub: THEME (reuses the app's ThemeMode via
/// AppState.setThemeMode, so light/dark/system stays in lock-step with the rest
/// of the app), WALLPAPER (reuses [WallpaperThemePicker] + the built-in set;
/// the chosen default is stored on-device as the hub default for new chats),
/// CHAT BACKUP (reuses [BackupSheet]/[RestoreSheet] — the same encrypted backup
/// widgets used by the per-chat extras hub), and CHAT HISTORY (clear local
/// cache — honest on-device action).
class MsgrSetChatsScreen extends StatefulWidget {
  const MsgrSetChatsScreen({super.key});

  @override
  State<MsgrSetChatsScreen> createState() => _MsgrSetChatsScreenState();
}

class _MsgrSetChatsScreenState extends State<MsgrSetChatsScreen> {
  static const _kWallpaper = 'msgr_default_wallpaper';
  String _wallpaperId = 'cyan_blue';

  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() =>
          _wallpaperId = prefs.getString(_kWallpaper) ?? 'cyan_blue');
    }
  }

  Future<void> _setWallpaper(String id) async {
    setState(() => _wallpaperId = id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kWallpaper, id);
  }

  String _themeId(ThemeMode m) => switch (m) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  void _setTheme(String id) {
    final mode = switch (id) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    context.read<AppState>().setThemeMode(mode);
  }

  void _openBackup() => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => BackupSheet(
          messageCount: 0,
          onConfirm: (code, hint) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(_t.msgrSetBackupStarted)));
          },
        ),
      );

  void _openRestore() => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => RestoreSheet(
          onRestore: (_) {
            Navigator.of(context).maybePop();
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(_t.msgrSetRestoreStarted)));
          },
        ),
      );

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(_t.msgrSetChatHistoryClear),
        content: Text(_t.msgrSetChatHistoryClearBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.msgrSetChatHistoryClearConfirm)),
        ],
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.msgrSetChatHistoryCleared)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetChats)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.only(bottom: Gap.xxl)),
        children: [
          MsgrSetSection(t.msgrSetChatsThemeSection),
          // Theme + wallpaper picker (reused widget). Theme maps to the app's
          // ThemeMode so the whole app follows this choice.
          WallpaperThemePicker(
            wallpaperId: _wallpaperId,
            themeId: _themeId(app.themeMode),
            onWallpaper: _setWallpaper,
            onTheme: _setTheme,
          ),
          // f6 (no showpieces): chat backup / restore / clear-history only
          // showed a "started"/"cleared" snackbar — nothing was sealed,
          // uploaded or deleted. Hidden until really wired (the real
          // encrypted backup lives in Settings -> Encrypted backup).
          if (kMsgrChatBackupWired) ...[
          const Divider(),
          MsgrSetSection(t.msgrSetChatsBackupSection),
          MsgrSetRow(
            icon: Icons.backup_rounded,
            title: t.msgrSetChatBackup,
            subtitle: t.msgrSetChatBackupSub,
            onTap: _openBackup,
          ),
          MsgrSetRow(
            icon: Icons.restore_rounded,
            title: t.msgrSetChatRestore,
            subtitle: t.msgrSetChatRestoreSub,
            onTap: _openRestore,
          ),
          const Divider(),
          MsgrSetSection(t.msgrSetChatsHistorySection),
          MsgrSetRow(
            icon: Icons.delete_sweep_rounded,
            title: t.msgrSetChatHistoryClear,
            subtitle: t.msgrSetChatHistoryClearSub,
            onTap: _clearHistory,
          ),
          ],
        ],
      ),
    );
  }
}
