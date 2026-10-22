import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../realtime/realtime_channel.dart';

/// c3-msg — the chat-header subtitle (replaces the relation label):
/// "typing…" > "recording audio…" > "online" > "last seen today at 10:14" >
/// "last seen yesterday at 21:03" > "last seen 12 Oct at 09:00" > nothing
/// (hidden by the other person's privacy). Pure apart from the strings.
String? presenceLabel(AppLocalizations t, RtChatState s,
    {required String lang, DateTime? now, bool isGroup = false}) {
  if (s.recording) {
    return isGroup && s.who.isNotEmpty
        ? t.c3GroupRecording(s.who)
        : t.c3Recording;
  }
  if (s.typing) {
    return isGroup && s.who.isNotEmpty ? t.c3GroupTyping(s.who) : t.c3Typing;
  }
  if (isGroup) return null;
  if (s.online == true) return t.c3Online;
  final ls = s.lastSeen;
  if (ls == null) return null;
  final n = now ?? DateTime.now();
  final loc = lang == 'bn' ? 'bn' : 'en';
  final time = DateFormat.Hm(loc).format(ls);
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(ls.year, ls.month, ls.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return t.c3LastSeenToday(time);
  if (diff == 1) return t.c3LastSeenYesterday(time);
  return t.c3LastSeenOn(DateFormat.MMMd(loc).format(ls), time);
}

/// The chat-list replacement for the preview while someone types to me
/// (shown in green). null = show the normal preview.
String? activityLabel(AppLocalizations t, RtChatState s,
    {bool isGroup = false}) {
  if (!s.active) return null;
  return presenceLabel(t, s, lang: 'en', isGroup: isGroup);
}
