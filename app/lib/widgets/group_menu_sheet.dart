import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Every action the GROUP CHAT ⋮ overflow can trigger. The group-flavoured
/// mirror of the 1:1 chat ⋮ (spec §3 last para): same core behaviours, plus the
/// group-only items (Group info / Group media / Add members / Exit group /
/// Report group).
enum GroupMenuAction {
  groupInfo,
  groupMedia,
  search,
  selectMessages,
  mute,
  disappearing,
  chatTheme,
  addToFavourites,
  exportChat,
  // ── calls ──
  sendCallLink,
  scheduleCall,
  newGroupCall,
  // ── Assisto extras ──
  summarise,
  makeReminder,
  translate,
  // ── group management ──
  addMembers,
  exitGroup,
  reportGroup,
  clearChat,
}

/// Show the GROUP CHAT ⋮ menu and resolve the chosen [GroupMenuAction] (or null
/// if dismissed). Strict spec order; every item routes to a real handler in the
/// group chat screen — there are NO dead taps. A dividers between the core,
/// calls, extras and management clusters mirror the 1:1 layout.
Future<GroupMenuAction?> showGroupMenuSheet(
  BuildContext context, {
  required bool isFavourite,
}) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<GroupMenuAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _item(ctx, Icons.info_outline, t.grpMenuGroupInfo,
                GroupMenuAction.groupInfo),
            _item(ctx, Icons.perm_media_outlined, t.grpMenuGroupMedia,
                GroupMenuAction.groupMedia),
            _item(ctx, Icons.search, t.grpMenuSearch,
                GroupMenuAction.search),
            _item(ctx, Icons.checklist_outlined, t.grpMenuSelectMessages,
                GroupMenuAction.selectMessages),
            _item(ctx, Icons.notifications_off_outlined, t.grpMenuMute,
                GroupMenuAction.mute,
                trailing: const Icon(Icons.chevron_right)),
            _item(ctx, Icons.timer_outlined, t.grpMenuDisappearing,
                GroupMenuAction.disappearing,
                trailing: const Icon(Icons.chevron_right)),
            _item(ctx, Icons.palette_outlined, t.grpMenuChatTheme,
                GroupMenuAction.chatTheme),
            _item(
                ctx,
                isFavourite ? Icons.star : Icons.star_border,
                isFavourite
                    ? t.grpMenuRemoveFavourite
                    : t.grpMenuAddFavourite,
                GroupMenuAction.addToFavourites),
            _item(ctx, Icons.ios_share, t.grpMenuExportChat,
                GroupMenuAction.exportChat),
            const Divider(height: 1),
            _item(ctx, Icons.link_outlined, t.grpMenuSendCallLink,
                GroupMenuAction.sendCallLink),
            _item(ctx, Icons.schedule_outlined, t.grpMenuScheduleCall,
                GroupMenuAction.scheduleCall),
            _item(ctx, Icons.video_call_outlined, t.grpMenuNewGroupCall,
                GroupMenuAction.newGroupCall),
            const Divider(height: 1),
            // Assisto extras — AI runs only on already-decrypted messages.
            _item(ctx, Icons.auto_awesome_outlined, t.grpMenuSummarise,
                GroupMenuAction.summarise),
            _item(ctx, Icons.alarm_add_outlined, t.grpMenuMakeReminder,
                GroupMenuAction.makeReminder),
            _item(ctx, Icons.translate_outlined, t.grpMenuTranslate,
                GroupMenuAction.translate),
            const Divider(height: 1),
            _item(ctx, Icons.person_add_alt_1_outlined, t.grpMenuAddMembers,
                GroupMenuAction.addMembers),
            _item(ctx, Icons.logout, t.grpMenuExitGroup,
                GroupMenuAction.exitGroup,
                danger: true),
            _item(ctx, Icons.flag_outlined, t.grpMenuReportGroup,
                GroupMenuAction.reportGroup,
                danger: true),
            _item(ctx, Icons.delete_sweep_outlined, t.grpMenuClearChat,
                GroupMenuAction.clearChat,
                danger: true),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    ),
  );
}

Widget _item(
  BuildContext ctx,
  IconData icon,
  String label,
  GroupMenuAction action, {
  Widget? trailing,
  bool danger = false,
}) {
  final color = danger ? Brand.danger : null;
  return ListTile(
    leading: Icon(icon, color: color),
    title: Text(label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: danger ? const TextStyle(color: Brand.danger) : null),
    trailing: trailing,
    onTap: () => Navigator.pop(ctx, action),
  );
}

/// A small ▸ sub-chooser used for Mute (8h / 1 week / Always) and Disappearing
/// (Off / 24h / 7d / 90d). Returns the chosen server token or null. Kept here
/// so the group chat screen reuses one picker for both radial sub-menus.
Future<String?> showGroupOptionPicker(
  BuildContext context, {
  required String title,
  required List<(String value, String label)> options,
  String? current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
            child: Text(title,
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final (value, label) in options)
            RadioListTile<String>(
              value: value,
              groupValue: current,
              title: Text(label),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
          const SizedBox(height: Gap.sm),
        ],
      ),
    ),
  );
}
