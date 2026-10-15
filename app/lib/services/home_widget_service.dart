import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../state.dart';

/// #196 HOME-SCREEN WIDGET — Dart side.
///
/// Pushes a tiny, honest snapshot to the native Android home-screen widget
/// (see `android_overlay/.../AssistoWidgetProvider.kt`): the NEXT upcoming
/// reminder's title + time, and TODAY'S reminder count. Tapping the widget
/// opens the app.
///
/// Design rules honoured:
///  - Real package (`home_widget`) — no fake data.
///  - Everything is self-guarded; a failure here NEVER crashes the app or the
///    widget. If the widget isn't added, pushes are harmless no-ops.
///  - ZERO Bangla literals: all human-readable strings are passed IN by the
///    caller (already localised via AppLocalizations) so the native widget only
///    ever renders text the app chose. The service itself writes no copy.
///  - Reuses the existing reminders repo (`AppState.reminders`) — no new store.
///
/// The native side reads these SharedPreferences keys (home_widget namespaces
/// them under `HomeWidgetPreferences`):
///   widget_title       → next reminder title       (String, may be empty)
///   widget_subtitle    → next reminder "when" label (String, may be empty)
///   widget_count       → today's reminder count     (String, e.g. "3")
///   widget_empty_title → localised "no reminders"   (String)
///   widget_empty_body  → localised hint             (String)
///   widget_count_label → localised "today" label    (String)
///   widget_updated     → ISO timestamp of last push (String, for debugging)
class HomeWidgetService {
  HomeWidgetService._();

  /// Must match `AssistoWidgetProvider` (native) and the app id `com.assisto`.
  static const String _androidProvider = 'AssistoWidgetProvider';

  /// SharedPreferences key the toggle in Settings persists.
  static const String enabledPref = 'home_widget_enabled';

  static bool _initialised = false;

  /// Whether the home-screen widget is supported on this platform. Android only:
  /// no iOS WidgetKit extension is shipped yet, so on iOS every call here is a
  /// no-op and the Settings tile shows an honest "coming soon".
  static bool get isSupported => Platform.isAndroid;

  /// One-time init. Safe to call more than once. No-op on iOS (no widget
  /// extension). The app-group id only matters on iOS (not built here) so we
  /// pass the Android package id.
  static Future<void> init() async {
    if (!isSupported) return;
    if (_initialised) return;
    try {
      await HomeWidget.setAppGroupId('com.assisto');
      _initialised = true;
    } catch (e) {
      if (kDebugMode) debugPrint('home_widget init failed: $e');
    }
  }

  /// Whether the user has turned the widget on in Settings. This does NOT mean
  /// a widget is actually placed on the home screen (the OS controls that) —
  /// it only gates whether we bother pushing updates.
  static Future<bool> isEnabled() =>
      Settings.getBool(enabledPref, false);

  static Future<void> setEnabled(bool on) =>
      Settings.setBool(enabledPref, on);

  /// Push the current snapshot to the widget. [labels] carries the already
  /// localised static strings so the service holds no copy of its own.
  ///
  /// Returns true if the push was attempted (enabled + init ok). A false return
  /// is not an error — it just means the widget is off or unavailable.
  static Future<bool> refresh(
    AppState app, {
    required HomeWidgetLabels labels,
  }) async {
    if (!isSupported) return false; // iOS: no widget extension, no-op
    if (!await isEnabled()) return false;
    await init();
    if (!_initialised) return false;

    final snap = snapshot(app.reminders.items, DateTime.now());
    try {
      await HomeWidget.saveWidgetData<String>('widget_title', snap.title);
      await HomeWidget.saveWidgetData<String>('widget_subtitle', snap.subtitle);
      await HomeWidget.saveWidgetData<String>(
          'widget_count', snap.todayCount.toString());
      await HomeWidget.saveWidgetData<String>(
          'widget_empty_title', labels.emptyTitle);
      await HomeWidget.saveWidgetData<String>(
          'widget_empty_body', labels.emptyBody);
      await HomeWidget.saveWidgetData<String>(
          'widget_count_label', labels.todayLabel);
      await HomeWidget.saveWidgetData<String>(
          'widget_updated', DateTime.now().toIso8601String());
      await HomeWidget.updateWidget(
        name: _androidProvider,
        androidName: _androidProvider,
      );
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('home_widget refresh failed: $e');
      return false;
    }
  }

  /// Clear the widget back to its empty state (used when the user disables it).
  static Future<void> clear(HomeWidgetLabels labels) async {
    if (!isSupported) return; // iOS: no widget extension, no-op
    await init();
    if (!_initialised) return;
    try {
      await HomeWidget.saveWidgetData<String>('widget_title', '');
      await HomeWidget.saveWidgetData<String>('widget_subtitle', '');
      await HomeWidget.saveWidgetData<String>('widget_count', '0');
      await HomeWidget.saveWidgetData<String>(
          'widget_empty_title', labels.emptyTitle);
      await HomeWidget.saveWidgetData<String>(
          'widget_empty_body', labels.emptyBody);
      await HomeWidget.saveWidgetData<String>(
          'widget_count_label', labels.todayLabel);
      await HomeWidget.updateWidget(
        name: _androidProvider,
        androidName: _androidProvider,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('home_widget clear failed: $e');
    }
  }

  /// PURE, testable projection of the reminder list → a widget snapshot.
  /// No I/O, no clock (now passed in). Mirrors the reminders screen's notion of
  /// "today" (same calendar day) and "next" (soonest not-done due time at or
  /// after now; falls back to the soonest future reminder).
  static HomeWidgetSnapshot snapshot(
      List<Map<String, dynamic>> items, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    DateTime? _due(Map<String, dynamic> it) {
      final d = (it['data'] as Map?)?.cast<String, dynamic>();
      final raw = d?['due_at'];
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString())?.toLocal();
    }

    bool _done(Map<String, dynamic> it) =>
        ((it['data'] as Map?)?['done'] == true);

    String _title(Map<String, dynamic> it) =>
        ((it['data'] as Map?)?['title'] ?? '').toString().trim();

    // Today's count: not-done reminders whose due date is today.
    var todayCount = 0;
    for (final it in items) {
      if (_done(it)) continue;
      final due = _due(it);
      if (due == null) continue;
      final dd = DateTime(due.year, due.month, due.day);
      if (dd == today) todayCount++;
    }

    // Next: soonest not-done reminder due at/after `now`. If none is in the
    // future, there is no "next" (we don't resurface overdue items as "next").
    Map<String, dynamic>? next;
    DateTime? nextDue;
    for (final it in items) {
      if (_done(it)) continue;
      final due = _due(it);
      if (due == null || due.isBefore(now)) continue;
      if (nextDue == null || due.isBefore(nextDue)) {
        nextDue = due;
        next = it;
      }
    }

    if (next == null || nextDue == null) {
      return HomeWidgetSnapshot(
          title: '', subtitle: '', todayCount: todayCount);
    }

    final dueDay = DateTime(nextDue.year, nextDue.month, nextDue.day);
    final hh = nextDue.hour.toString().padLeft(2, '0');
    final mm = nextDue.minute.toString().padLeft(2, '0');
    // Date part only for non-today/tomorrow; the native widget shows this raw.
    // Kept numeric + locale-neutral (HH:mm / yyyy-MM-dd) so NO Bangla literal is
    // needed and nothing is fabricated. The "today/tomorrow" wording is applied
    // by the caller-provided labels when it maps the snapshot to display text.
    String subtitle;
    if (dueDay == today) {
      subtitle = '$hh:$mm';
    } else if (dueDay == tomorrow) {
      subtitle = '+1 · $hh:$mm';
    } else {
      final y = nextDue.year.toString().padLeft(4, '0');
      final mo = nextDue.month.toString().padLeft(2, '0');
      final da = nextDue.day.toString().padLeft(2, '0');
      subtitle = '$y-$mo-$da $hh:$mm';
    }

    return HomeWidgetSnapshot(
      title: _title(next),
      subtitle: subtitle,
      todayCount: todayCount,
    );
  }
}

/// A rendered snapshot pushed to the native widget.
@immutable
class HomeWidgetSnapshot {
  final String title; // next reminder title ('' = none)
  final String subtitle; // next reminder "when" (HH:mm / +1 · HH:mm / date)
  final int todayCount; // today's open reminder count
  const HomeWidgetSnapshot({
    required this.title,
    required this.subtitle,
    required this.todayCount,
  });
}

/// Static, already-localised strings the service writes to the widget so the
/// native layout never contains a hard-coded Bangla/English literal.
@immutable
class HomeWidgetLabels {
  final String emptyTitle; // e.g. "No upcoming reminders"
  final String emptyBody; // e.g. "You're all caught up"
  final String todayLabel; // e.g. "today"
  const HomeWidgetLabels({
    required this.emptyTitle,
    required this.emptyBody,
    required this.todayLabel,
  });
}
