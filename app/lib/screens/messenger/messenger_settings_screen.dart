import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_avatar.dart';
import '../settings_screen.dart' show SupportScreen;
import 'messenger_profile_screen.dart';
import 'msgr_set_account_screen.dart';
import 'msgr_set_calls_screen.dart';
import 'msgr_set_chats_screen.dart';
import 'msgr_set_notifications_screen.dart';
import 'msgr_set_privacy_screen.dart';
import 'msgr_set_storage_screen.dart';

/// Full-spec hub Settings for "My Circle" (MESSENGER_UI_FULL §2). A tappable
/// profile card sits at the TOP (photo · name · bio · phone · edit →
/// [MessengerProfileScreen]), followed by rows that EACH open a real working
/// screen — NO dead taps:
///   Account · Privacy · Chats · Notifications · Calls · Storage & data ·
///   Language · Help · Invite a friend.
///
/// Reuse is deliberate: Privacy links to the existing CirclePrivacyScreen,
/// Account reuses the existing export + delete, Chats reuses the backup/
/// wallpaper widgets, Help reuses the existing [SupportScreen], Language reuses
/// AppState.setLocale, and Invite reuses the existing ApiClient.invite(). Only
/// the genuinely new surfaces (two-step PIN, change number, calls prefs,
/// storage & data, blocked list, message requests) are new screens.
class MessengerSettingsScreen extends StatelessWidget {
  const MessengerSettingsScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => screen));

  // ---- Language: reuse the app locale switch (AppState.setLocale) ----
  Future<void> _pickLanguage(BuildContext context) async {
    final app = context.read<AppState>();
    final t = AppLocalizations.of(context);
    final current = app.locale?.languageCode ?? 'bn';
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          RadioListTile<String>(
            value: 'bn',
            groupValue: current,
            title: Text(t.languageBangla),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<String>(
            value: 'en',
            groupValue: current,
            title: Text(t.languageEnglish),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
        ]),
      ),
    );
    if (chosen != null) app.setLocale(Locale(chosen));
  }

  // ---- Invite a friend: reuse ApiClient.invite() (same as main Settings) ----
  Future<void> _invite(BuildContext context) async {
    final app = context.read<AppState>();
    final t = AppLocalizations.of(context);
    try {
      final inv = await app.api.invite();
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.msgrSetInviteTitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText('${inv['code'] ?? ''}',
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.sm),
            SelectableText('${inv['share_text'] ?? ''}',
                textAlign: TextAlign.center),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(t.ok)),
          ],
        ),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.msgrSetInviteFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    final u = app.user;
    final name = u?.name.isNotEmpty == true ? u!.name : t.you;
    final phone = (u?.phone?.isNotEmpty == true) ? u!.phone! : '';
    final lang = (app.locale?.languageCode ?? 'bn') == 'en'
        ? t.languageEnglish
        : t.languageBangla;

    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSettingsTitle)),
      body: ListView(
        children: [
          // ---- profile card (photo · name · bio · phone · edit) ----
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.sm),
                leading: MsgrAvatar(name: name, radius: 28),
                title: Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    phone.isEmpty ? t.msgrSetProfileHint : phone,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing:
                    Icon(Icons.edit_outlined, color: scheme.onSurfaceVariant),
                onTap: () => _open(context, const MessengerProfileScreen()),
              ),
            ),
          ),
          const Divider(),
          // ---- rows ----
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(t.msgrSetAccount),
            subtitle: Text(t.msgrSetAccountSub),
            onTap: () => _open(context, const MsgrSetAccountScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(t.msgrSetPrivacy),
            subtitle: Text(t.msgrSetPrivacySub),
            onTap: () => _open(context, const MsgrSetPrivacyScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: Text(t.msgrSetChats),
            subtitle: Text(t.msgrSetChatsSub),
            onTap: () => _open(context, const MsgrSetChatsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Text(t.msgrSetNotifications),
            subtitle: Text(t.msgrSetNotificationsSub),
            onTap: () => _open(context, const MsgrSetNotificationsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.call_outlined),
            title: Text(t.msgrSetCalls),
            subtitle: Text(t.msgrSetCallsSub),
            onTap: () => _open(context, const MsgrSetCallsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.data_usage_outlined),
            title: Text(t.msgrSetStorage),
            subtitle: Text(t.msgrSetStorageSub),
            onTap: () => _open(context, const MsgrSetStorageScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: Text(t.msgrSetLanguage),
            subtitle: Text(lang),
            onTap: () => _pickLanguage(context),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(t.msgrSetHelp),
            subtitle: Text(t.msgrSetHelpSub),
            onTap: () => _open(context, const SupportScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.card_giftcard_outlined),
            title: Text(t.msgrSetInvite),
            subtitle: Text(t.msgrSetInviteSub),
            onTap: () => _invite(context),
          ),
        ],
      ),
    );
  }
}
