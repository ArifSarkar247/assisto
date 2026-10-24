import '../notifications.dart';

/// f6 — Probashi document-expiry reminders (were "not wired yet").
///
/// For every saved document with an expiry date we schedule two LOCAL
/// notifications on this phone (same mechanism as subscriptions / reminders):
///   * 30 days before the expiry, 09:00 — "start renewing"
///   * on the expiry day, 09:00
/// Ids are stable (`probashi-doc-<id>-30` / `-0`), so re-planning after every
/// load/edit simply overwrites; a deleted or undated document is cancelled.
class ProbashiDocReminder {
  final String localId;
  final DateTime when;
  final int docId;
  final bool onExpiryDay; // false = the 30-days-before nudge
  const ProbashiDocReminder(this.localId, this.when, this.docId, this.onExpiryDay);
}

class ProbashiReminders {
  ProbashiReminders._();

  static const int leadDays = 30;
  static const int hour = 9;

  static String idFor(int docId, {required bool onExpiryDay}) =>
      'probashi-doc-$docId-${onExpiryDay ? 0 : leadDays}';

  static DateTime? _asDate(dynamic v) {
    if (v == null || v == '') return null;
    try {
      final p = DateTime.parse(v.toString().substring(0, 10));
      return DateTime(p.year, p.month, p.day);
    } catch (_) {
      return null;
    }
  }

  /// Pure plan: which reminders should exist for [docs] as of [now].
  /// Only future moments are returned.
  static List<ProbashiDocReminder> plan(
      List<Map<String, dynamic>> docs, DateTime now) {
    final out = <ProbashiDocReminder>[];
    for (final d in docs) {
      final id = d['id'];
      if (id is! int) continue;
      final exp = _asDate(d['expiry']);
      if (exp == null) continue;
      final before = DateTime(exp.year, exp.month, exp.day - leadDays, hour);
      final onDay = DateTime(exp.year, exp.month, exp.day, hour);
      if (before.isAfter(now)) {
        out.add(ProbashiDocReminder(
            idFor(id, onExpiryDay: false), before, id, false));
      }
      if (onDay.isAfter(now)) {
        out.add(ProbashiDocReminder(
            idFor(id, onExpiryDay: true), onDay, id, true));
      }
    }
    return out;
  }

  /// Cancels every reminder of [docs] and schedules the current plan.
  /// [title] names the document; [body] gives the line for each moment.
  /// Best-effort: never throws (notifications must not block the screen).
  static Future<void> sync(
    List<Map<String, dynamic>> docs, {
    required String Function(Map<String, dynamic> doc) title,
    required String Function(bool onExpiryDay) body,
    DateTime? now,
    Future<void> Function(String id, String title, String body, DateTime when)?
        schedule,
    Future<void> Function(String id)? cancel,
  }) async {
    final sch = schedule ?? Notifications.schedule;
    final can = cancel ?? Notifications.cancel;
    try {
      for (final d in docs) {
        final id = d['id'];
        if (id is! int) continue;
        await can(idFor(id, onExpiryDay: false));
        await can(idFor(id, onExpiryDay: true));
      }
      final byId = {for (final d in docs) d['id']: d};
      for (final r in plan(docs, now ?? DateTime.now())) {
        final doc = byId[r.docId]!;
        await sch(r.localId, title(doc), body(r.onExpiryDay), r.when);
      }
    } catch (_) {
      // best-effort only
    }
  }

  /// A deleted document: drop both of its reminders.
  static Future<void> cancelFor(int docId,
      {Future<void> Function(String id)? cancel}) async {
    final can = cancel ?? Notifications.cancel;
    try {
      await can(idFor(docId, onExpiryDay: false));
      await can(idFor(docId, onExpiryDay: true));
    } catch (_) {}
  }
}
