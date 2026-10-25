import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The 1:1 CHAT overflow (⋮) menu actions — exact order and dividers per
/// .phaseB/MESSENGER_UI_FULL.md §3. Original Assisto identity (own icons, own
/// wording); never a copy of any other app's menu.
enum ChatMenuAction {
  contactInfo,
  search,
  selectMessages,
  mute,
  disappearing,
  chatTheme,
  nicknames, // cde-chat
  addFavourite,
  addToList,
  bubble, // c3-msg: per-chat "Show as bubble" (Android 11+)
  exportChat,
  closeChat,
  lockChat, // e-gaps: chat lock (fingerprint / face / code)
  // --- divider ---
  sendCallLink,
  scheduleCall,
  newGroupCall,
  // --- divider ---
  summarise, // Assisto extras
  makeReminder,
  translate,
  // --- divider ---
  report,
  block,
  clearChat,
}

/// A single menu row descriptor (null == divider).
class _Row {
  final ChatMenuAction? action;
  final IconData? icon;
  final String Function(AppLocalizations) label;
  final bool submenu; // shows a ▸ trailing chevron
  const _Row.divider()
      : action = null,
        icon = null,
        label = _noLabel,
        submenu = false;
  const _Row(this.action, this.icon, this.label, {this.submenu = false});
  static String _noLabel(AppLocalizations _) => '';
}

String _favLabel(AppLocalizations t, bool isFav) =>
    isFav ? t.msgrChatRemoveFavourite : t.msgrChatAddFavourite;

/// Open the chat ⋮ menu. Returns the chosen [ChatMenuAction], or null if
/// dismissed. [isFavourite] flips the favourites row label (no dead state).
Future<ChatMenuAction?> showChatMenu(
  BuildContext context, {
  required bool isFavourite,
  bool? bubbleOn, // c3-msg: null = hide the row (no bubbles on this phone)
  bool locked = false, // e-gaps: flips Lock chat / Unlock chat
}) {
  final t = AppLocalizations.of(context);
  final rows = <_Row>[
    _Row(ChatMenuAction.contactInfo, Icons.person_outline_rounded, (t) => t.msgrChatContactInfo),
    _Row(ChatMenuAction.search, Icons.search_rounded, (t) => t.msgrChatSearch),
    _Row(ChatMenuAction.selectMessages, Icons.checklist_rtl_rounded, (t) => t.msgrChatSelectMessages),
    _Row(ChatMenuAction.mute, Icons.notifications_off_rounded, (t) => t.msgrChatMute, submenu: true),
    _Row(ChatMenuAction.disappearing, Icons.timer_rounded, (t) => t.msgrChatDisappearing, submenu: true),
    _Row(ChatMenuAction.chatTheme, Icons.palette_rounded, (t) => t.msgrChatTheme),
    _Row(ChatMenuAction.nicknames, Icons.badge_rounded, (t) => t.cdeNickTitle),
    _Row(ChatMenuAction.addFavourite, Icons.star_outline_rounded, (t) => _favLabel(t, isFavourite)),
    _Row(ChatMenuAction.addToList, Icons.playlist_add_rounded, (t) => t.msgrChatAddToList, submenu: true),
    if (bubbleOn != null)
      _Row(ChatMenuAction.bubble, Icons.bubble_chart_rounded,
          (t) => bubbleOn ? t.c3BubbleOff : t.c3BubbleOn),
    _Row(ChatMenuAction.exportChat, Icons.ios_share_rounded, (t) => t.msgrChatExport),
    _Row(ChatMenuAction.closeChat, Icons.archive_rounded, (t) => t.msgrChatClose),
    _Row(ChatMenuAction.lockChat, locked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
        (t) => locked ? t.eLockUnlockChat : t.eLockLockChat),
    const _Row.divider(),
    _Row(ChatMenuAction.sendCallLink, Icons.link_rounded, (t) => t.msgrChatSendCallLink),
    _Row(ChatMenuAction.scheduleCall, Icons.schedule_rounded, (t) => t.msgrChatScheduleCall),
    _Row(ChatMenuAction.newGroupCall, Icons.groups_rounded, (t) => t.msgrChatNewGroupCall),
    const _Row.divider(),
    _Row(ChatMenuAction.summarise, Icons.auto_awesome_rounded, (t) => t.msgrChatSummarise),
    _Row(ChatMenuAction.makeReminder, Icons.alarm_add_rounded, (t) => t.msgrChatMakeReminder),
    _Row(ChatMenuAction.translate, Icons.translate_rounded, (t) => t.msgrChatTranslate),
    const _Row.divider(),
    _Row(ChatMenuAction.report, Icons.flag_rounded, (t) => t.circleReport),
    _Row(ChatMenuAction.block, Icons.block_rounded, (t) => t.circleBlock),
    _Row(ChatMenuAction.clearChat, Icons.delete_sweep_rounded, (t) => t.msgrChatClear),
  ];

  return showModalBottomSheet<ChatMenuAction>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: Gap.sm),
            children: [
              for (final r in rows)
                if (r.action == null)
                  const Divider(height: Gap.sm)
                else
                  ListTile(
                    leading: Icon(r.icon,
                        color: r.action == ChatMenuAction.report ||
                                r.action == ChatMenuAction.block ||
                                r.action == ChatMenuAction.clearChat
                            ? scheme.error
                            : scheme.onSurfaceVariant),
                    title: Text(
                      r.label(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: r.action == ChatMenuAction.report ||
                                r.action == ChatMenuAction.block ||
                                r.action == ChatMenuAction.clearChat
                            ? scheme.error
                            : null,
                      ),
                    ),
                    trailing: r.submenu
                        ? Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant)
                        : null,
                    onTap: () => Navigator.pop(ctx, r.action),
                  ),
            ],
          ),
        ),
      );
    },
  );
}
