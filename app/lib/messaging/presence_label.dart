import '../l10n/app_localizations.dart';
import '../realtime/realtime_channel.dart';
import 'date_separators.dart' show fmtDate, fmtTime, localDigits;

/// c3-msg — the chat-header subtitle (replaces the relation label):
/// "typing…" > "recording audio…" > "online" > the FULL last-seen line
/// ([lastSeenLabel]) > nothing (hidden by the other person's privacy).
/// [use24h] = the phone's 24-hour setting (MediaQuery.alwaysUse24HourFormat).
/// Pure apart from the strings.
String? presenceLabel(AppLocalizations t, RtChatState s,
    {required String lang,
    DateTime? now,
    bool isGroup = false,
    bool use24h = false,
    DateTime Function(DateTime)? toLocal}) {
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
  return lastSeenLabel(t, ls,
      lang: lang, now: now, use24h: use24h, toLocal: toLocal);
}

/// mr1 — WhatsApp-format last seen, ALWAYS with the time:
///   today        "last seen today at 9:40 pm"     (bn: today + night 9:40)
///   yesterday    "last seen yesterday at 8:15 am" (bn: yesterday + morning)
///   2–6 days     "last seen Monday at 9:40 pm"    (bn: weekday + time)
///   older        "last seen 18 Oct at 9:40 pm"    (bn: day + month + time)
///   other year   "last seen 18 Oct 2025 at 9:40 pm"
/// Days are calendar days on the phone's wall clock ([toLocal], default the
/// phone's zone — tests pass e.g. dhakaWallClock); [use24h] follows the
/// phone's 24-hour setting ("21:40", Bangla digits for bn).
String lastSeenLabel(AppLocalizations t, DateTime lastSeen,
    {required String lang,
    DateTime? now,
    bool use24h = false,
    DateTime Function(DateTime)? toLocal}) {
  final conv = toLocal ?? (DateTime d) => d.toLocal();
  final loc = lang == 'bn' ? 'bn' : 'en';
  final ls = conv(lastSeen);
  final n = conv(now ?? DateTime.now());
  final time = clockLabel(t, ls, lang: loc, use24h: use24h);
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(ls.year, ls.month, ls.day);
  // rounded hours/24 (not inDays) stays right across a DST change.
  final diff = (today.difference(day).inHours / 24).round();
  if (diff <= 0) return t.c3LastSeenToday(time);
  if (diff == 1) return t.c3LastSeenYesterday(time);
  final String date;
  if (diff < 7) {
    date = fmtDate('EEEE', ls, loc);
  } else if (ls.year == n.year) {
    date = fmtDate(loc == 'bn' ? 'd MMMM' : 'd MMM', ls, loc);
  } else {
    date = fmtDate(loc == 'bn' ? 'd MMMM y' : 'd MMM y', ls, loc);
  }
  return t.mr1LastSeenOn(date, time);
}

/// mr1 — the clock part of a last-seen line. 12-hour: en "9:40 pm", bn with
/// the natural day-period word first ([dayPeriod]); 24-hour: "21:40".
/// Bangla digits always for bn.
String clockLabel(AppLocalizations t, DateTime d,
    {required String lang, bool use24h = false}) {
  final loc = lang == 'bn' ? 'bn' : 'en';
  if (use24h) return fmtTime(d, loc);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final hm = '$h12:${d.minute.toString().padLeft(2, '0')}';
  if (loc == 'bn') return '${dayPeriod(t, d.hour)} ${localDigits(hm, 'bn')}';
  return '$hm ${d.hour < 12 ? t.mr1Am : t.mr1Pm}';
}

/// The Bangla day period for an hour (0–23): morning 5–11, noon 12–14,
/// afternoon 15–17, evening 18–19, night 20–4.
String dayPeriod(AppLocalizations t, int hour) {
  if (hour >= 5 && hour < 12) return t.mr1PeriodMorning;
  if (hour >= 12 && hour < 15) return t.mr1PeriodNoon;
  if (hour >= 15 && hour < 18) return t.mr1PeriodAfternoon;
  if (hour >= 18 && hour < 20) return t.mr1PeriodEvening;
  return t.mr1PeriodNight;
}

/// The chat-list replacement for the preview while someone types to me
/// (shown in green). null = show the normal preview.
String? activityLabel(AppLocalizations t, RtChatState s,
    {bool isGroup = false}) {
  if (!s.active) return null;
  return presenceLabel(t, s, lang: 'en', isGroup: isGroup);
}
