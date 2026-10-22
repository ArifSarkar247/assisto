import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'bn_day_periods.dart' show appDateLocale;

/// Meeting/appointment model helpers + bilingual string table for the ADVANCED
/// MeetingsScreen. Mirrors backend/core/logic/meetings.py so the app and the
/// server agree (normalise/recurrence/partition/agenda/leave-now/share).
///
/// SPEC §21: NO Bangla glyphs live in this .dart file. Every localized string
/// either reuses an existing ARB getter (passed in by the screen) or comes from
/// [mStr], whose [bn, en] pairs are ALSO emitted to .phaseB/up_meet_arb.json
/// for the next ARB sync. Bangla DIGITS use codepoints only (see [mNum]).
///
/// Travel ETA is HONESTLY key-gated: with no Maps key we surface a fixed mock
/// estimate flagged as an estimate (mirrors meetings.travel_eta / MOCK_ETA_MIN)
/// — we never pretend it is live traffic.

bool mIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer: Western digits, or Bangla digits via codepoints when bn.
String mNum(BuildContext c, int n) {
  if (!mIsBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Bilingual table for keys NOT in the ARB yet. Keep in sync with
/// up_meet_arb.json. [bn, en]; picked by active locale. '{m}' = int slot.
const Map<String, List<String>> _strings = {
  'mWith': ['\u0995\u09BE\u09B0 \u09B8\u09BE\u09A5\u09C7', 'With'],
  'mWithHint': ['\u09A8\u09BE\u09AE \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8 (\u0995\u09AE\u09BE \u09A6\u09BF\u09AF\u09BC\u09C7 \u0986\u09B2\u09BE\u09A6\u09BE)', 'Add names (comma separated)'],
  'mReminderLead': ['\u09AE\u09A8\u09C7 \u0995\u09B0\u09BE\u09A8\u09CB\u09B0 \u09B8\u09AE\u09AF\u09BC', 'Remind me'],
  'mRecurrence': ['\u09AA\u09C1\u09A8\u09B0\u09BE\u09AC\u09C3\u09A4\u09CD\u09A4\u09BF', 'Repeat'],
  'mRepeatNone': ['\u098F\u0995\u09AC\u09BE\u09B0', 'Once'],
  'mRepeatDaily': ['\u09AA\u09CD\u09B0\u09A4\u09BF\u09A6\u09BF\u09A8', 'Daily'],
  'mRepeatWeekly': ['\u09AA\u09CD\u09B0\u09A4\u09BF \u09B8\u09AA\u09CD\u09A4\u09BE\u09B9\u09C7', 'Weekly'],
  'mRepeatMonthly': ['\u09AA\u09CD\u09B0\u09A4\u09BF \u09AE\u09BE\u09B8\u09C7', 'Monthly'],
  'mRepeatYearly': ['\u09AA\u09CD\u09B0\u09A4\u09BF \u09AC\u099B\u09B0', 'Yearly'],
  'mLead1Day': ['\u09E7 \u09A6\u09BF\u09A8 \u0986\u0997\u09C7', '1 day before'],
  'mLead1Hour': ['\u09E7 \u0998\u09A3\u09CD\u099F\u09BE \u0986\u0997\u09C7', '1 hour before'],
  'mLead30Min': ['\u09E9\u09E6 \u09AE\u09BF\u09A8\u09BF\u099F \u0986\u0997\u09C7', '30 min before'],
  'mLead10Min': ['\u09E7\u09E6 \u09AE\u09BF\u09A8\u09BF\u099F \u0986\u0997\u09C7', '10 min before'],
  'mLeadAtTime': ['\u09A0\u09BF\u0995 \u09B8\u09AE\u09AF\u09BC\u09C7', 'At start time'],
  'mViewDay': ['\u09A6\u09BF\u09A8', 'Day'],
  'mViewWeek': ['\u09B8\u09AA\u09CD\u09A4\u09BE\u09B9', 'Week'],
  'mViewMonth': ['\u09AE\u09BE\u09B8', 'Month'],
  'mViewAgenda': ['\u09A4\u09BE\u09B2\u09BF\u0995\u09BE', 'List'],
  'mUpcoming': ['\u0986\u09B8\u09A8\u09CD\u09A8', 'Upcoming'],
  'mPast': ['\u0985\u09A4\u09C0\u09A4', 'Past'],
  'mToday': ['\u0986\u099C', 'Today'],
  'mTomorrow': ['\u0986\u0997\u09BE\u09AE\u09C0\u0995\u09BE\u09B2', 'Tomorrow'],
  'mNoneToday': ['\u098F\u0987 \u09A6\u09BF\u09A8\u09C7 \u0995\u09CB\u09A8\u09CB \u09AE\u09BF\u099F\u09BF\u0982 \u09A8\u09C7\u0987', 'No meetings this day'],
  'mStatusDone': ['\u09B8\u09AE\u09CD\u09AA\u09A8\u09CD\u09A8', 'Done'],
  'mStatusCancelled': ['\u09AC\u09BE\u09A4\u09BF\u09B2', 'Cancelled'],
  'mStatusScheduled': ['\u09A8\u09BF\u09B0\u09CD\u09A7\u09BE\u09B0\u09BF\u09A4', 'Scheduled'],
  'mMarkDone': ['\u09B8\u09AE\u09CD\u09AA\u09A8\u09CD\u09A8 \u099A\u09BF\u09B9\u09CD\u09A8\u09BF\u09A4 \u0995\u09B0\u09C1\u09A8', 'Mark done'],
  'mMarkCancelled': ['\u09AC\u09BE\u09A4\u09BF\u09B2 \u0995\u09B0\u09C1\u09A8', 'Cancel meeting'],
  'mReopen': ['\u09AA\u09C1\u09A8\u09B0\u09BE\u09AF\u09BC \u099A\u09BE\u09B2\u09C1 \u0995\u09B0\u09C1\u09A8', 'Reopen'],
  'mShare': ['\u09AC\u09BF\u09AC\u09B0\u09A3 \u09B6\u09C7\u09AF\u09BC\u09BE\u09B0 \u0995\u09B0\u09C1\u09A8', 'Share details'],
  'mInvite': ['\u0986\u09AE\u09A8\u09CD\u09A4\u09CD\u09B0\u09A3 \u09AA\u09BE\u09A0\u09BE\u09A8', 'Send invite'],
  'mShareWhen': ['\u0995\u09AC\u09C7', 'When'],
  'mShareWhere': ['\u0995\u09CB\u09A5\u09BE\u09AF\u09BC', 'Where'],
  'mShareWith': ['\u0995\u09BE\u09B0 \u09B8\u09BE\u09A5\u09C7', 'With'],
  'mLoadError': ['\u09AE\u09BF\u099F\u09BF\u0982 \u0986\u09A8\u09BE \u09AF\u09BE\u09AF\u09BC\u09A8\u09BF', 'Could not load meetings'],
  'mOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u2014\u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A4\u09BE\u09B2\u09BF\u0995\u09BE \u09A6\u09C7\u0996\u09BE\u09A8\u09CB \u09B9\u099A\u09CD\u099B\u09C7', 'Offline — showing your saved list'],
  'mSavedOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4, \u09AA\u09B0\u09C7 \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u09AC\u09C7', 'Saved offline — will sync later'],
  'mDeleteQ': ['\u098F\u0987 \u09AE\u09BF\u099F\u09BF\u0982 \u09AE\u09C1\u099B\u09AC\u09C7\u09A8?', 'Delete this meeting?'],
  'mDeleted': ['\u09AE\u09BF\u099F\u09BF\u0982 \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Meeting deleted'],
  'mEtaEstimate': ['\u0986\u09A8\u09C1\u09AE\u09BE\u09A8\u09BF\u0995 {m} \u09AE\u09BF\u09A8\u09BF\u099F', 'About {m} min'],
  'mEtaMockNote': ['\u0986\u09A8\u09C1\u09AE\u09BE\u09A8\u09BF\u0995\u2014\u09AE\u09CD\u09AF\u09BE\u09AA\u09B8 \u0995\u09BF \u09AF\u09C1\u0995\u09CD\u09A4 \u09B9\u09B2\u09C7 \u09B8\u09A0\u09BF\u0995 \u09B9\u09AC\u09C7', 'Estimate — exact when a Maps key is added'],
  'mEtaGetEstimate': ['\u09AF\u09BE\u09A4\u09CD\u09B0\u09BE\u09B0 \u09B8\u09AE\u09AF\u09BC \u0985\u09A8\u09C1\u09AE\u09BE\u09A8', 'Estimate travel time'],
  'mRecurringBadge': ['\u09AA\u09C1\u09A8\u09B0\u09BE\u09AC\u09C3\u09A4\u09CD\u09A4', 'Repeats'],
  'mAllDay': ['\u09B8\u09BE\u09B0\u09BE\u09A6\u09BF\u09A8', 'All day'],
  'mCount': ['{m}\u099F\u09BF \u09AE\u09BF\u099F\u09BF\u0982', '{m} meetings'],
  'mAddFirst': ['\u09AA\u09CD\u09B0\u09A5\u09AE \u09AE\u09BF\u099F\u09BF\u0982 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add your first meeting'],
};

String mStr(BuildContext c, String key) {
  final pair = _strings[key];
  if (pair == null) return key;
  return mIsBn(c) ? pair[0] : pair[1];
}

String mStrNum(BuildContext c, String key, int n) =>
    mStr(c, key).replaceFirst('{m}', mNum(c, n));

// ---------------------------------------------------------------------------
// status (mirrors meetings.STATUS_*)
// ---------------------------------------------------------------------------
const kStatusScheduled = 'scheduled';
const kStatusDone = 'done';
const kStatusCancelled = 'cancelled';

String statusOf(Map<String, dynamic> a) {
  final s = '${a['status'] ?? kStatusScheduled}';
  if (s == kStatusDone || s == kStatusCancelled) return s;
  return kStatusScheduled;
}

// ---------------------------------------------------------------------------
// reminder lead-time options (minutes before). Mirrors DEFAULT_REMINDER_OFFSETS.
// ---------------------------------------------------------------------------
const List<int> kLeadOptions = [1440, 60, 30, 10, 0];
const List<int> kDefaultLeads = [1440, 60]; // 1 day + 1 hour

String leadLabel(BuildContext c, int minutes) {
  switch (minutes) {
    case 1440:
      return mStr(c, 'mLead1Day');
    case 60:
      return mStr(c, 'mLead1Hour');
    case 30:
      return mStr(c, 'mLead30Min');
    case 10:
      return mStr(c, 'mLead10Min');
    default:
      return mStr(c, 'mLeadAtTime');
  }
}

/// De-dupe + drop negatives, sort descending (mirrors meetings.clean_offsets).
List<int> cleanOffsets(Iterable<int> raw) {
  final seen = <int>{};
  final out = <int>[];
  for (final o in raw) {
    if (o < 0 || seen.contains(o)) continue;
    seen.add(o);
    out.add(o);
  }
  if (out.isEmpty) return List<int>.from(kDefaultLeads);
  out.sort((a, b) => b.compareTo(a));
  return out;
}

// ---------------------------------------------------------------------------
// recurrence (mirrors reminders_engine rule shape via meetings.clean_recurrence)
// ---------------------------------------------------------------------------
const kFreqNone = '';
const kFreqDaily = 'daily';
const kFreqWeekly = 'weekly';
const kFreqMonthly = 'monthly';
const kFreqYearly = 'yearly';
const List<String> kFreqOrder = [
  kFreqNone,
  kFreqDaily,
  kFreqWeekly,
  kFreqMonthly,
  kFreqYearly
];

String freqLabel(BuildContext c, String freq) {
  switch (freq) {
    case kFreqDaily:
      return mStr(c, 'mRepeatDaily');
    case kFreqWeekly:
      return mStr(c, 'mRepeatWeekly');
    case kFreqMonthly:
      return mStr(c, 'mRepeatMonthly');
    case kFreqYearly:
      return mStr(c, 'mRepeatYearly');
    default:
      return mStr(c, 'mRepeatNone');
  }
}

String freqOf(Map<String, dynamic> a) {
  final r = a['recurrence'];
  if (r is Map && r['freq'] is String) {
    final f = r['freq'] as String;
    if (kFreqOrder.contains(f) && f != kFreqNone) return f;
  }
  return kFreqNone;
}

Map<String, dynamic>? recurrenceFor(String freq, DateTime start) {
  switch (freq) {
    case kFreqWeekly:
      return {'freq': kFreqWeekly, 'interval': 1, 'weekday': start.weekday - 1};
    case kFreqMonthly:
      return {'freq': kFreqMonthly, 'interval': 1, 'day_of_month': start.day};
    case kFreqYearly:
      return {
        'freq': kFreqYearly,
        'interval': 1,
        'month': start.month,
        'day_of_month': start.day
      };
    case kFreqDaily:
      return {'freq': kFreqDaily, 'interval': 1};
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// recurrence expansion — mirrors reminders_engine.next_occurrence (the subset
// the UI needs: daily/weekly/monthly/yearly, interval, weekday/dom/month).
// ---------------------------------------------------------------------------
DateTime? nextOccurrence(DateTime anchor, Map? rule, {DateTime? after}) {
  after ??= DateTime.now();
  if (rule == null || rule['freq'] == null) {
    return anchor.isAfter(after) ? anchor : null;
  }
  final freq = '${rule['freq']}';
  final interval =
      (rule['interval'] is num) ? (rule['interval'] as num).toInt() : 1;
  final iv = interval < 1 ? 1 : interval;
  final h = (rule['hour'] is num) ? (rule['hour'] as num).toInt() : anchor.hour;
  final mi =
      (rule['minute'] is num) ? (rule['minute'] as num).toInt() : anchor.minute;

  if (freq == kFreqDaily) {
    var d = anchor.isAfter(after) ? anchor : after;
    var cand = DateTime(d.year, d.month, d.day, h, mi);
    while (!cand.isAfter(after)) {
      cand = cand.add(Duration(days: iv));
    }
    return cand;
  }
  if (freq == kFreqWeekly) {
    final wd = (rule['weekday'] is num)
        ? (rule['weekday'] as num).toInt()
        : anchor.weekday - 1; // 0=Mon
    var cand = DateTime(after.year, after.month, after.day, h, mi);
    for (var i = 0; i < 14 * iv; i++) {
      if ((cand.weekday - 1) == wd && cand.isAfter(after)) return cand;
      cand = cand.add(const Duration(days: 1));
    }
    return null;
  }
  if (freq == kFreqMonthly) {
    final dom =
        (rule['day_of_month'] is num) ? (rule['day_of_month'] as num).toInt() : anchor.day;
    for (var step = 0; step < 48; step++) {
      final m = _addMonths(DateTime(after.year, after.month), step);
      final day = dom.clamp(1, _daysInMonth(m.year, m.month));
      final cand = DateTime(m.year, m.month, day, h, mi);
      if (cand.isAfter(after)) return cand;
    }
    return null;
  }
  if (freq == kFreqYearly) {
    final mo = (rule['month'] is num) ? (rule['month'] as num).toInt() : anchor.month;
    final dom =
        (rule['day_of_month'] is num) ? (rule['day_of_month'] as num).toInt() : anchor.day;
    for (var y = after.year; y < after.year + 20; y++) {
      final day = dom.clamp(1, _daysInMonth(y, mo));
      final cand = DateTime(y, mo, day, h, mi);
      if (cand.isAfter(after)) return cand;
    }
    return null;
  }
  return anchor.isAfter(after) ? anchor : null;
}

DateTime _addMonths(DateTime d, int n) {
  final m = d.month - 1 + n;
  return DateTime(d.year + m ~/ 12, m % 12 + 1, 1);
}

int _daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

/// Next concrete start for a (possibly recurring) appointment. Mirrors
/// meetings.next_start.
DateTime? nextStart(Map<String, dynamic> a, {DateTime? after}) {
  final start = DateTime.tryParse('${a['start']}');
  if (start == null) return null;
  final r = a['recurrence'];
  if (r is! Map || r['freq'] == null) return start;
  after ??= DateTime.now();
  return nextOccurrence(start, r, after: after) ?? start;
}

// ---------------------------------------------------------------------------
// with-whom
// ---------------------------------------------------------------------------
List<String> withList(Map<String, dynamic> a) {
  final w = a['with'];
  if (w is List) return w.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
  return const [];
}

/// Parse a comma-separated names field, de-duped (mirrors clean_contacts).
List<String> parseWith(String raw) {
  final seen = <String>{};
  final out = <String>[];
  for (final part in raw.split(',')) {
    final name = part.trim();
    if (name.isEmpty || seen.contains(name)) continue;
    seen.add(name);
    out.add(name);
  }
  return out;
}

// ---------------------------------------------------------------------------
// conflict detection — mirrors meetings.conflicts (overlap, not touching).
// Cancelled meetings are excluded. Keyed by the appointment's identity index.
// ---------------------------------------------------------------------------
Set<int> conflictIndices(List<Map<String, dynamic>> list) {
  final out = <int>{};
  List<DateTime>? interval(Map<String, dynamic> a) {
    if (statusOf(a) == kStatusCancelled) return null;
    final s = DateTime.tryParse('${a['start']}');
    if (s == null) return null;
    final dur = ((a['duration_min'] ?? 60) as num).toInt();
    return [s, s.add(Duration(minutes: dur))];
  }

  for (var i = 0; i < list.length; i++) {
    final ii = interval(list[i]);
    if (ii == null) continue;
    for (var j = i + 1; j < list.length; j++) {
      final jj = interval(list[j]);
      if (jj == null) continue;
      if (ii[0].isBefore(jj[1]) && jj[0].isBefore(ii[1])) {
        out.add(i);
        out.add(j);
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// share / invite text — mirrors meetings.share_text (localized in-app).
// ---------------------------------------------------------------------------
String shareText(BuildContext c, Map<String, dynamic> a) {
  final df = DateFormat('EEE d MMM, h:mm a', appDateLocale(c));
  final lines = <String>['${a['title']}'];
  final s = DateTime.tryParse('${a['start']}');
  if (s != null) lines.add('${mStr(c, "mShareWhen")}: ${df.format(s)}');
  final place = '${a['place'] ?? ''}'.trim();
  if (place.isNotEmpty) lines.add('${mStr(c, "mShareWhere")}: $place');
  final people = withList(a);
  if (people.isNotEmpty) {
    lines.add('${mStr(c, "mShareWith")}: ${people.join(", ")}');
  }
  final note = '${a['note'] ?? ''}'.trim();
  if (note.isNotEmpty) lines.add(note);
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// HONEST key-gated travel ETA — mirrors meetings.travel_eta / MOCK_ETA_MIN.
// With no Maps key wired we return a fixed mock estimate flagged source='mock'
// so the UI labels it an estimate. We NEVER fake live traffic.
// ---------------------------------------------------------------------------
const int kMockEtaMin = 25;

/// Returns (etaMin, source) where source is 'live' | 'mock' | 'none'.
({int? etaMin, String source}) travelEta({
  String? place,
  double? lat,
  double? lng,
  String? mapsKey,
}) {
  final hasDest = (lat != null && lng != null) ||
      (place != null && place.trim().isNotEmpty);
  if (!hasDest) return (etaMin: null, source: 'none');
  // Integrator: with a real key, swap in a Distance-Matrix call -> source:'live'.
  return (etaMin: kMockEtaMin, source: 'mock');
}
