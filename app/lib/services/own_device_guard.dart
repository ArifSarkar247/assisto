import 'package:shared_preferences/shared_preferences.dart';

/// grab-guard (owner 25 Oct) — the owner's OWN phone never DISPLAYS an
/// anti-theft / safety alert about itself ("Arif's phone: battery low / went
/// offline / sudden grab" on Arif's own phone). The server already sends
/// these to approved family only; this is the app-side second line of
/// defence for pushes (foreground + background isolate), the foreground
/// /alerts poll and every screen that reads /alerts (home urgent card).
///
/// The owner-only "test" alarm (he pressed it himself) still shows.
/// Ids are kept in SharedPreferences so the FCM background isolate (no
/// AppState) can check too. Every call is crash-guarded.
class OwnDeviceGuard {
  OwnDeviceGuard._();

  static const _kUid = 'own_guard_uid';
  static const _kPhones = 'own_guard_phone_ids';

  static int? _me;
  static Set<int> _phones = <int>{};
  static bool _loaded = false;

  static int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

  /// Is this push data / alert row an anti-theft (lost-phone) item?
  static bool isAntitheft(Map<dynamic, dynamic> d) =>
      '${d['alert_kind'] ?? ''}' == 'antitheft' ||
      '${d['type'] ?? ''}' == 'antitheft' ||
      '${d['antitheft_kind'] ?? ''}'.isNotEmpty;

  /// PURE rule: an anti-theft item about the signed-in user's own phone
  /// (owner_id == me, or phone_id one of his protected phones). The
  /// owner-only `test` kind is allowed through.
  static bool isOwn(Map<dynamic, dynamic> d,
      {required int? me, Set<int> phoneIds = const {}}) {
    if (!isAntitheft(d)) return false;
    final kind = '${d['antitheft_kind'] ?? d['kind'] ?? ''}';
    if (kind == 'test') return false;
    if (d['own_device'] == true || '${d['own_device']}' == 'true') return true;
    final o = _int(d['owner_id']);
    if (me != null && o != null && o == me) return true;
    final p = _int(d['phone_id']);
    return p != null && phoneIds.contains(p);
  }

  /// Signed in / profile loaded: remember who this phone belongs to.
  static Future<void> rememberUser(int? userId) async {
    if (userId == null) return;
    _me = userId;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getInt(_kUid) != userId) {
        // a different account on this phone: its phones are not ours
        _phones = <int>{};
        await p.remove(_kPhones);
      }
      await p.setInt(_kUid, userId);
    } catch (_) {}
  }

  /// The engine state named this user's protected phone.
  static Future<void> rememberPhone(Object? phoneId) async {
    final id = _int(phoneId);
    if (id == null) return;
    _phones = {..._phones, id};
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kPhones, _phones.map((e) => '$e').toList());
    } catch (_) {}
  }

  /// Signed out: forget everything.
  static Future<void> forget() async {
    _me = null;
    _phones = <int>{};
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kUid);
      await p.remove(_kPhones);
    } catch (_) {}
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      _me ??= p.getInt(_kUid);
      _phones = {
        ..._phones,
        ...(p.getStringList(_kPhones) ?? const <String>[])
            .map(int.tryParse)
            .whereType<int>(),
      };
      _loaded = true;
    } catch (_) {}
  }

  /// Push data (any isolate): true = do NOT draw it.
  static Future<bool> isOwnPush(Map<dynamic, dynamic> data) async {
    try {
      if (!isAntitheft(data)) return false;
      await _ensureLoaded();
      return isOwn(data, me: _me, phoneIds: _phones);
    } catch (_) {
      return false;
    }
  }

  /// /alerts rows without the ones about this user's own phone.
  static Future<List<Map<String, dynamic>>> filterAlerts(
      List<Map<String, dynamic>> rows) async {
    try {
      if (!rows.any(isAntitheft)) return rows;
      await _ensureLoaded();
      return rows.where((a) => !isOwn(a, me: _me, phoneIds: _phones)).toList();
    } catch (_) {
      return rows;
    }
  }

  static void resetForTest() {
    _me = null;
    _phones = <int>{};
    _loaded = false;
  }
}
