import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../../widgets/msgr_avatar.dart';
import '../settings_screen.dart' show SupportScreen;
import 'messenger_profile_screen.dart';
import 'msgr_set_account_screen.dart';
import 'msgr_set_calls_screen.dart';
import 'msgr_set_chats_screen.dart';
import 'msgr_set_notifications_screen.dart';
import 'msgr_set_privacy_screen.dart';
import 'msgr_set_storage_screen.dart';
import '../../widgets/founder_badge.dart';
import 'package:assisto/widgets/app_sheet.dart';

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
    final chosen = await showAppSheet<String>(
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
          scrollable: true, // insets: 200% text / keyboard
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
// ---- profile = the soft DS hero (photo · name · phone · edit) ----
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
            child: DsHeroCard(
              onTap: () => _open(context, const MessengerProfileScreen()),
              child: Row(children: [
                MsgrAvatar(name: name, photoUrl: u?.photoUrl ?? '', radius: 28),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // the name wraps (never "…")
                    Text(name,
                        style: AType.titleLarge.copyWith(
                            color: scheme.ds.text, fontWeight: FontWeight.w800)),
                    Text(phone.isEmpty ? t.msgrSetProfileHint : phone,
                        style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
                    // f1-founders: Founding Member badge on My Circle profile.
                    if (u?.isFounder == true) ...[
                      const SizedBox(height: 6),
                      const FounderBadge(dense: true),
                    ],
                  ]),
                ),
                Icon(Icons.edit_rounded, color: scheme.ds.muted),
              ]),
            ),
          ),
MsgrSetGroup([
          MsgrSetRow(
            icon: Icons.key_rounded,
            title: t.msgrSetAccount,
            subtitle: t.msgrSetAccountSub,
            onTap: () => _open(context, const MsgrSetAccountScreen()),
          ),
MsgrSetRow(
            icon: Icons.lock_outline_rounded,
            title: t.msgrSetPrivacy,
            subtitle: t.msgrSetPrivacySub,
            onTap: () => _open(context, const MsgrSetPrivacyScreen()),
          ),
MsgrSetRow(
            icon: Icons.chat_rounded,
            title: t.msgrSetChats,
            subtitle: t.msgrSetChatsSub,
            onTap: () => _open(context, const MsgrSetChatsScreen()),
          ),
MsgrSetRow(
            icon: Icons.notifications_rounded,
            title: t.msgrSetNotifications,
            subtitle: t.msgrSetNotificationsSub,
            onTap: () => _open(context, const MsgrSetNotificationsScreen()),
          ),
MsgrSetRow(
            icon: Icons.call_rounded,
            title: t.msgrSetCalls,
            subtitle: t.msgrSetCallsSub,
            onTap: () => _open(context, const MsgrSetCallsScreen()),
          ),
MsgrSetRow(
            icon: Icons.data_usage_rounded,
            title: t.msgrSetStorage,
            subtitle: t.msgrSetStorageSub,
            onTap: () => _open(context, const MsgrSetStorageScreen()),
          ),
]),
MsgrSetGroup([
MsgrSetRow(
            icon: Icons.language_rounded,
            title: t.msgrSetLanguage,
            subtitle: lang,
            onTap: () => _pickLanguage(context),
          ),
MsgrSetRow(
            icon: Icons.help_outline_rounded,
            title: t.msgrSetHelp,
            subtitle: t.msgrSetHelpSub,
            onTap: () => _open(context, const SupportScreen()),
          ),
MsgrSetRow(
            icon: Icons.card_giftcard_rounded,
            title: t.msgrSetInvite,
            subtitle: t.msgrSetInviteSub,
            onTap: () => _invite(context),
          ),
]),
],
      ),
    );
  }
}
