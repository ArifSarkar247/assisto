// cde-chat — the centred system line a control message is drawn as, and the
// PURE text builders (also used for notifications, previews and the readable
// fallback line older app versions show).
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'chat_control.dart';
import 'chat_themes.dart';

/// The line THIS viewer reads for [c].
///
/// * [mine]: I sent the control.
/// * [actor]: the sender's real name (unused when [mine]).
/// * 1:1: [peerName] = the other person's real name.
/// * group: [myUid], [senderUid] and [nameOf] (a member's real name).
String describeControl(
  AppLocalizations t,
  ChatControl c, {
  required bool mine,
  required String actor,
  String peerName = '',
  int? myUid,
  int? senderUid,
  String Function(int uid)? nameOf,
}) {
  if (c.isTheme) {
    final label = chatThemeLabel(t, c.themeId);
    return mine ? t.cdeThemeYou(label) : t.cdeThemeOther(actor, label);
  }
  if (c.isTimer) return describeTimer(t, c.sec, mine: mine, actor: actor);
  final n = c.name;
  final rm = c.removed;
  final uid = c.uid;
  if (uid == null) {
    // 1:1 — who: 'sender' (the sender named themself) | 'recipient'
    final self = c.who == 'sender';
    if (mine) {
      if (self) return rm ? t.cdeNickRmYouSelf : t.cdeNickYouSelf(n);
      return rm ? t.cdeNickRmYouOther(peerName) : t.cdeNickYouOther(peerName, n);
    }
    if (self) return rm ? t.cdeNickRmOtherSelf(actor) : t.cdeNickOtherSelf(actor, n);
    return rm ? t.cdeNickRmOtherYou(actor) : t.cdeNickOtherYou(actor, n);
  }
  // group
  final targetIsSender = senderUid != null && uid == senderUid;
  final targetIsMe = myUid != null && uid == myUid;
  final target = nameOf?.call(uid) ?? '';
  if (mine) {
    if (targetIsMe || targetIsSender) {
      return rm ? t.cdeNickRmYouSelf : t.cdeNickYouSelf(n);
    }
    return rm ? t.cdeNickRmYouOther(target) : t.cdeNickYouOther(target, n);
  }
  if (targetIsSender) return rm ? t.cdeNickRmOtherSelf(actor) : t.cdeNickOtherSelf(actor, n);
  if (targetIsMe) return rm ? t.cdeNickRmOtherYou(actor) : t.cdeNickOtherYou(actor, n);
  return rm ? t.cdeNickRmOtherOther(actor, target) : t.cdeNickOtherOther(actor, target, n);
}

/// The readable line the SENDER puts in front of the payload (what older
/// versions / notifications show): the receiver's point of view.
String controlFallbackLine(AppLocalizations t, ChatControl c,
    {required String myName, String targetName = ''}) {
  if (c.isTheme) return t.cdeThemeOther(myName, chatThemeLabel(t, c.themeId));
  if (c.isTimer) return describeTimer(t, c.sec, mine: false, actor: myName);
  final rm = c.removed;
  if (c.uid == null) {
    if (c.who == 'sender') {
      return rm ? t.cdeNickRmOtherSelf(myName) : t.cdeNickOtherSelf(myName, c.name);
    }
    return rm ? t.cdeNickRmOtherYou(myName) : t.cdeNickOtherYou(myName, c.name);
  }
  if (targetName.isEmpty) {
    return rm ? t.cdeNickRmOtherSelf(myName) : t.cdeNickOtherSelf(myName, c.name);
  }
  return rm
      ? t.cdeNickRmOtherOther(myName, targetName)
      : t.cdeNickOtherOther(myName, targetName, c.name);
}

/// e-gaps: "24 hours" / "7 days" / "90 days" for a disappearing timer.
String timerLabel(AppLocalizations t, int sec) {
  if (sec <= 0) return t.msgrChatDisapOff;
  if (sec <= 86400) return t.msgrChatDisap24h;
  if (sec <= 604800) return t.msgrChatDisap7d;
  return t.msgrChatDisap90d;
}

/// e-gaps: the system line for a disappearing-timer change.
String describeTimer(AppLocalizations t, int sec,
    {required bool mine, required String actor}) {
  if (sec <= 0) return mine ? t.eTimerOffYou : t.eTimerOffOther(actor);
  final label = timerLabel(t, sec);
  return mine ? t.eTimerOnYou(label) : t.eTimerOnOther(actor, label);
}

/// A centred chip: "Rahim changed the theme to Love".
class ChatSystemLine extends StatelessWidget {
  final String text;
  final IconData icon;
  const ChatSystemLine({super.key, required this.text, this.icon = Icons.info_outline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    key: const Key('cde-system-line'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.3, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
