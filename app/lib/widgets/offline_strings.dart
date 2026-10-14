import 'package:flutter/material.dart';

/// Bilingual string table for the OFFLINE-FIRST feature (#12, SPEC v2.1 §21).
///
/// These keys are NOT in the ARB yet (the task forbids editing app_*.arb). They
/// are mirrored verbatim into .phaseB/up_offline_arb.json for the next ARB sync,
/// exactly like contacts_model's cStr pattern. NO Bangla glyphs are written as
/// literals in any .dart file — Bangla is stored as \u escapes only (SPEC §21).
/// [bn, en]; picked by the active locale.
const Map<String, List<String>> _oStrings = {
  'offTitle': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0993 \u09A1\u09BE\u099F\u09BE', 'Offline & data'],
  'offStatusOnline': ['\u0985\u09A8\u09B2\u09BE\u0987\u09A8', 'Online'],
  'offStatusOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8', 'Offline'],
  'offStatusOnlineSub': ['\u0987\u09A8\u09CD\u099F\u09BE\u09B0\u09A8\u09C7\u099F \u09AF\u09C1\u0995\u09CD\u09A4 \u2014 \u09AA\u09B0\u09BF\u09AC\u09B0\u09CD\u09A4\u09A8 \u098F\u0996\u09A8 \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u099A\u09CD\u099B\u09C7\u0964', 'Connected \u2014 your changes are syncing now.'],
  'offStatusOfflineSub': ['\u0987\u09A8\u09CD\u099F\u09BE\u09B0\u09A8\u09C7\u099F \u09A8\u09C7\u0987 \u2014 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u0995\u09AA\u09BF \u09A6\u09C7\u0996\u09BE\u09A8\u09CB \u09B9\u099A\u09CD\u099B\u09C7, \u09AA\u09B0\u09C7 \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u09AC\u09C7\u0964', 'No internet \u2014 showing saved copies; will sync when back online.'],
  'offAvailableOffline': ['\u098F\u0987 \u09AE\u09A1\u09BF\u0989\u09B2\u0997\u09C1\u09B2\u09CB \u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7\u0993 \u0995\u09BE\u099C \u0995\u09B0\u09C7', 'These modules work offline'],
  'offWorksOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7 \u099A\u09B2\u09C7', 'Works offline'],
  'offCached': ['\u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4', 'Cached'],
  'offNotCached': ['\u098F\u0996\u09A8\u09CB \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A8\u09AF\u09BC', 'Not cached yet'],
  'offPureLocal': ['\u09B8\u09AC\u09B8\u09AE\u09AF\u09BC \u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u2014 \u0995\u09CB\u09A8\u09CB \u09A1\u09BE\u099F\u09BE \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09A3 \u09B2\u09BE\u0997\u09C7 \u09A8\u09BE', 'Always offline \u2014 no data to store'],
  'offStale': ['\u09AA\u09C1\u09B0\u09A8\u09CB \u09B9\u09A4\u09C7 \u09AA\u09BE\u09B0\u09C7', 'May be out of date'],
  'offNeverSynced': ['\u098F\u0996\u09A8\u09CB \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u09AF\u09BC\u09A8\u09BF', 'Never synced'],
  'offSyncedJustNow': ['\u098F\u0987\u09AE\u09BE\u09A4\u09CD\u09B0 \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Synced just now'],
  'offSyncedMinutes': ['%d \u09AE\u09BF\u09A8\u09BF\u099F \u0986\u0997\u09C7 \u09B8\u09BF\u0999\u09CD\u0995', 'Synced %d min ago'],
  'offSyncedHours': ['%d \u0998\u09A3\u09CD\u099F\u09BE \u0986\u0997\u09C7 \u09B8\u09BF\u0999\u09CD\u0995', 'Synced %d h ago'],
  'offSyncedDays': ['%d \u09A6\u09BF\u09A8 \u0986\u0997\u09C7 \u09B8\u09BF\u0999\u09CD\u0995', 'Synced %d d ago'],
  'offDataUsage': ['\u09A1\u09BE\u099F\u09BE \u09AC\u09CD\u09AF\u09AC\u09B9\u09BE\u09B0', 'Data usage'],
  'offDataUsageNote': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0995\u09AA\u09BF \u0986\u09AA\u09A8\u09BE\u09B0 \u09AB\u09CB\u09A8\u09C7 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A5\u09BE\u0995\u09C7, \u09A1\u09BE\u099F\u09BE \u0996\u09B0\u099A \u09B9\u09AF\u09BC \u0995\u09C7\u09AC\u09B2 \u09B8\u09BF\u0999\u09CD\u0995\u09C7\u09B0 \u09B8\u09AE\u09AF\u09BC\u0964', 'Offline copies live on your phone; mobile data is used only when syncing.'],
  'offTotalCached': ['\u09AE\u09CB\u099F \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4: %s', 'Total cached: %s'],
  'offClear': ['\u09AE\u09C1\u099B\u09C1\u09A8', 'Clear'],
  'offClearAll': ['\u09B8\u09AC \u0995\u09CD\u09AF\u09BE\u09B6 \u09AE\u09C1\u099B\u09C1\u09A8', 'Clear all caches'],
  'offCleared': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0995\u09AA\u09BF \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Offline copy cleared'],
  'offClearedAll': ['\u09B8\u09AC \u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0995\u09AA\u09BF \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'All offline copies cleared'],
  'offClearQ': ['\u098F\u0987 \u09AE\u09A1\u09BF\u0989\u09B2\u09C7\u09B0 \u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0995\u09AA\u09BF \u09AE\u09C1\u099B\u09AC\u09C7\u09A8? \u0985\u09A8\u09B2\u09BE\u0987\u09A8 \u09B9\u09B2\u09C7 \u0986\u09AC\u09BE\u09B0 \u09A1\u09BE\u0989\u09A8\u09B2\u09CB\u09A1 \u09B9\u09AC\u09C7\u0964', 'Clear this module\u2019s offline copy? It will re-download when you are online.'],
  'offClearAllQ': ['\u09B8\u09AC \u09AE\u09A1\u09BF\u0989\u09B2\u09C7\u09B0 \u0985\u09AB\u09B2\u09BE\u0987\u09A8 \u0995\u09AA\u09BF \u09AE\u09C1\u099B\u09AC\u09C7\u09A8? \u09B8\u09BE\u09B0\u09CD\u09AD\u09BE\u09B0\u09C7\u09B0 \u09A1\u09BE\u099F\u09BE \u09AE\u09CB\u099B\u09BE \u09B9\u09AC\u09C7 \u09A8\u09BE\u0964', 'Clear every module\u2019s offline copy? Nothing on the server is deleted.'],
  'offNothingToClear': ['\u09AE\u09C1\u099B\u09AC\u09BE\u09B0 \u09AE\u09A4\u09CB \u0995\u09BF\u099B\u09C1 \u09A8\u09C7\u0987', 'Nothing to clear'],
  'offServerSafeNote': ['\u0995\u09CD\u09AF\u09BE\u09B6 \u09AE\u09C1\u099B\u09B2\u09C7 \u0995\u09C7\u09AC\u09B2 \u09AB\u09CB\u09A8\u09C7\u09B0 \u0995\u09AA\u09BF \u09AF\u09BE\u09AF\u09BC \u2014 \u09B8\u09BE\u09B0\u09CD\u09AD\u09BE\u09B0\u09C7\u09B0 \u0995\u09BF\u099B\u09C1 \u09AE\u09CB\u099B\u09BE \u09B9\u09AF\u09BC \u09A8\u09BE\u0964', 'Clearing a cache removes only the on-phone copy; nothing on the server is touched.'],
  'offModNotes': ['\u09A8\u09CB\u099F', 'Notes'],
  'offModContacts': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F', 'Contacts'],
  'offModReminders': ['\u09B0\u09BF\u09AE\u09BE\u0987\u09A8\u09CD\u09A1\u09BE\u09B0', 'Reminders'],
  'offModSupplyList': ['\u09AC\u09BE\u099C\u09BE\u09B0 \u09A4\u09BE\u09B2\u09BF\u0995\u09BE', 'Supply list'],
  'offModTodo': ['\u099F\u09C1-\u09A1\u09C1', 'To-do'],
  'offModDictionary': ['\u0985\u09AD\u09BF\u09A7\u09BE\u09A8', 'Dictionary'],
  'offModMedicineDb': ['\u0993\u09B7\u09C1\u09A7 \u09A4\u09A5\u09CD\u09AF', 'Medicine info'],
  'offModHealthTips': ['\u09B8\u09CD\u09AC\u09BE\u09B8\u09CD\u09A5\u09CD\u09AF \u099F\u09BF\u09AA\u09B8', 'Health tips'],
  'offModFinanceCalc': ['\u0986\u09B0\u09CD\u09A5\u09BF\u0995 \u0995\u09CD\u09AF\u09BE\u09B2\u0995\u09C1\u09B2\u09C7\u099F\u09B0', 'Finance calculators'],
};

bool _isBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Pick a bilingual string by key for the active locale. Falls back to English,
/// then the key itself. Never throws, never blank.
String oStr(BuildContext c, String key) {
  final pair = _oStrings[key];
  if (pair == null) return key;
  return _isBn(c) ? pair[0] : pair[1];
}

/// Western or Bangla digits (codepoints only — no Bangla glyph literal).
String _num(BuildContext c, int n) {
  if (!_isBn(c)) return '$n';
  const zeroBn = 0x09E6;
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Fill a single %d placeholder with a locale-formatted integer.
String oStrNum(BuildContext c, String key, int n) =>
    oStr(c, key).replaceFirst('%d', _num(c, n));

/// Fill a single %s placeholder with an already-formatted string.
String oStrS(BuildContext c, String key, String s) =>
    oStr(c, key).replaceFirst('%s', s);

/// Human, locale-aware "last synced" line from a timestamp (or null => never).
String offlineSyncedLabel(BuildContext c, DateTime? ts) {
  if (ts == null) return oStr(c, 'offNeverSynced');
  final d = DateTime.now().difference(ts);
  if (d.inMinutes < 1) return oStr(c, 'offSyncedJustNow');
  if (d.inMinutes < 60) return oStrNum(c, 'offSyncedMinutes', d.inMinutes);
  if (d.inHours < 24) return oStrNum(c, 'offSyncedHours', d.inHours);
  return oStrNum(c, 'offSyncedDays', d.inDays);
}

/// Locale-aware byte-size label (B / KB / MB), digits localised.
String offlineSizeLabel(BuildContext c, int bytes) {
  if (bytes < 1024) return '${_num(c, bytes)} B';
  if (bytes < 1024 * 1024) return '${_num(c, (bytes / 1024).round())} KB';
  return '${_num(c, (bytes / (1024 * 1024)).round())} MB';
}
