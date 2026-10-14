import 'api.dart';

/// Assisto — NOTIFICATION CENTRE (the bell screen) client surface.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public helpers
/// (`getJson` / `postJson`) so this module ships WITHOUT editing the shared
/// api.dart. The integrator SHOULD later fold these into ApiClient proper — the
/// paths below are authoritative and follow the backend route style (NO
/// trailing slash, matching `backend/core/urls.py`).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`, so dynamic
/// titles / bodies arrive as `{"bn": ..., "en": ...}` pairs AND/OR a pre-picked
/// string. The UI renders the active-language side of each pair.
///
/// The backend ALREADY applies each module's notification settings (a muted
/// module simply does not appear in the feed) — the client just renders what
/// it is given; it must NOT re-filter by settings.
extension NotifApi on ApiClient {
  // --------------------------------------------------------------- Reminders

  /// GET /notif/reminders
  /// ->
  /// {
  ///   "today":    [ <reminder>, ... ],
  ///   "upcoming": [ <reminder>, ... ],
  ///   "missed":   [ <reminder>, ... ]
  /// }
  ///
  /// where each <reminder> is:
  /// {
  ///   "id": String|int,
  ///   "title": {"bn": String, "en": String} | String,
  ///   "when": ISO-8601 String (local when rendered),
  ///   "route": String|null,     // ChatNav route to open the source item
  ///   "module": String|null,    // owning module (used by [reminderDone])
  ///   "done": bool
  /// }
  Future<Map<String, dynamic>> notifReminders() => getJson('/notif/reminders');

  /// POST /notif/reminders/<id>/done  — mark a reminder complete.
  ///
  /// The reminder's own `module`/`route` is forwarded so the backend can
  /// dispatch completion to the real owning handler (medicine dose taken,
  /// task done, subscription acknowledged, …). Backend ignores unknown hints.
  Future<Map<String, dynamic>> reminderDone(String id,
          {String? module, String? route}) =>
      postJson('/notif/reminders/$id/done', {
        if (module != null) 'module': module,
        if (route != null) 'route': route,
      });

  /// POST /notif/reminders/<id>/snooze {preset?, until?}
  ///
  /// [preset] is one of `15m` | `1h` | `tomorrow` (server computes the new
  /// time). For a custom pick send [until] as an ISO-8601 instant instead.
  Future<Map<String, dynamic>> reminderSnooze(String id,
          {String? preset, DateTime? until}) =>
      postJson('/notif/reminders/$id/snooze', {
        if (preset != null) 'preset': preset,
        if (until != null) 'until': until.toUtc().toIso8601String(),
      });

  // ----------------------------------------------------------------- Feed

  /// GET /notif/feed
  /// ->
  /// {
  ///   "items": [
  ///     {
  ///       "id": String|int,
  ///       "type": String,         // see NotifType (circle/community/channel/
  ///                               //  family/scam/watch/business/crm/security/
  ///                               //  plan/points/update/...)
  ///       "title": {"bn","en"} | String,
  ///       "body":  {"bn","en"} | String,
  ///       "time": ISO-8601 String,
  ///       "route": String|null,   // ChatNav route to the source
  ///       "seen": bool
  ///     }, ...
  ///   ],
  ///   "unseen": int               // badge count (optional)
  /// }
  ///
  /// Chat messages are NOT included here — they live in My Circle.
  Future<Map<String, dynamic>> notifFeed() => getJson('/notif/feed');

  /// POST /notif/<id>/seen — mark a single feed event as seen.
  Future<Map<String, dynamic>> notifSeen(String id) =>
      postJson('/notif/$id/seen', const {});

  /// POST /notif/read-all — mark every feed event as seen.
  Future<Map<String, dynamic>> notifReadAll() =>
      postJson('/notif/read-all', const {});
}
