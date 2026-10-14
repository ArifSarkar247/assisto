import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../circle_privacy_screen.dart';
import '../circle_screen.dart';
import '../in_progress_screen.dart';
import '../settings_screen.dart';
import 'messenger_home_screen.dart';
import 'messenger_profile_screen.dart';

/// WhatsApp-style hub Settings for the Messenger ("My Circle") hub (OWNER UI
/// FIX v2 §3). A tappable profile card sits at the TOP (avatar · name · phone),
/// followed by a list of rows: Account · Privacy · Chats · Notifications ·
/// Linked devices · Starred messages · New group · New community.
///
/// Every row navigates somewhere REAL or to an honest "coming soon" placeholder
/// ([InProgressScreen]) — no dead rows. Privacy reuses the existing
/// [CirclePrivacyScreen]; nothing here duplicates its logic.
class MessengerSettingsScreen extends StatelessWidget {
  const MessengerSettingsScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final u = context.watch<AppState>().user;
    final name = u?.name.isNotEmpty == true ? u!.name : t.you;
    final phone = (u?.phone?.isNotEmpty == true) ? u!.phone! : '';

    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSettingsTitle)),
      body: ListView(
        children: [
          // ---- profile card (WhatsApp-style) → full profile/account ----
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.sm),
                leading: CircleAvatar(
                  radius: 28,
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    (name.isNotEmpty ? name[0] : 'A').toUpperCase(),
                    style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 22),
                  ),
                ),
                title: Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: phone.isEmpty
                    ? null
                    : Text(phone,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Icon(Icons.qr_code_2_outlined,
                    color: scheme.onSurfaceVariant),
                onTap: () =>
                    _open(context, const MessengerProfileScreen()),
              ),
            ),
          ),
          const Divider(),
          // ---- rows ----
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(t.msgrSetAccount),
            subtitle: Text(t.msgrSetAccountSub),
            onTap: () => _open(context, const SettingsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(t.msgrSetPrivacy),
            subtitle: Text(t.msgrSetPrivacySub),
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: Text(t.msgrSetChats),
            subtitle: Text(t.msgrSetChatsSub),
            onTap: () =>
                _open(context, const MessengerHomeScreen(initialTab: 0)),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Text(t.msgrSetNotifications),
            subtitle: Text(t.msgrSetNotificationsSub),
            onTap: () => _open(context, const InProgressScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: Text(t.msgrSetLinkedDevices),
            subtitle: Text(t.msgrSetLinkedDevicesSub),
            onTap: () => _open(context, const InProgressScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.star_outline),
            title: Text(t.msgrSetStarred),
            subtitle: Text(t.msgrSetStarredSub),
            onTap: () => _open(context, const InProgressScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.group_add_outlined),
            title: Text(t.msgrSetNewGroup),
            subtitle: Text(t.msgrSetNewGroupSub),
            // Groups are circle-only: CircleScreen bootstraps the on-device
            // identity + members, then opens the Groups create flow.
            onTap: () => _open(context, const CircleScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.groups_2_outlined),
            title: Text(t.msgrSetNewCommunity),
            subtitle: Text(t.msgrSetNewCommunitySub),
            // Communities live in the hub's Communities tab (index 2), which
            // owns the identity needed to create one.
            onTap: () =>
                _open(context, const MessengerHomeScreen(initialTab: 2)),
          ),
        ],
      ),
    );
  }
}
