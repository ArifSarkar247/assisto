import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// invite-join — where an invite code comes from, and the one place that
/// remembers it until the person has joined.
///
/// Sources (all end in [PendingInvite.set]):
///  * App Link https://lifeassisto.com/i/<CODE> — cold start
///    (PlatformDispatcher.defaultRouteName = the full URL) or warm
///    (MaterialApp.onGenerateRoute gets "/i/<CODE>");
///  * Play Install Referrer `ci=<CODE>` — read ONCE per install, seconds after
///    the first frame, over the lazy, crash-guarded native channel;
///  * typed / pasted code on the join screen.
///
/// A circle code is exactly 10 chars of [kInviteAlphabet]. Anything else on
/// /i/ is a p5 referral code (4–12 chars) and is kept separately so the
/// existing referral claim can use it after sign-up.
const kInviteAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const kInviteCodeLen = 10;

class InviteLink {
  InviteLink._();

  /// "CODE" from CODE / code / https://lifeassisto.com/i/CODE / /i/CODE?x,
  /// else null.
  static String? codeFrom(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    final i = s.indexOf('/i/');
    if (i != -1) {
      // only our host when it is a full URL
      if (s.contains('://')) {
        final Uri u;
        try {
          u = Uri.parse(s);
        } catch (_) {
          return null;
        }
        if (!u.host.endsWith('lifeassisto.com')) return null;
      }
      s = s.substring(i + 3);
    }
    s = s.split('?').first.split('#').first.replaceAll('/', '').trim().toUpperCase();
    if (s.length != kInviteCodeLen) return null;
    for (final c in s.split('')) {
      if (!kInviteAlphabet.contains(c)) return null;
    }
    return s;
  }

  /// A p5 referral code on /i/ (not a circle code), else null.
  static String? referralFrom(String? raw) {
    if (raw == null || !raw.contains('/i/')) return null;
    if (codeFrom(raw) != null) return null;
    final s = raw.substring(raw.indexOf('/i/') + 3).split('?').first.split('#').first
        .replaceAll('/', '').trim().toUpperCase();
    return RegExp(r'^[A-Z0-9]{4,12}$').hasMatch(s) ? s : null;
  }

  /// Play referrer string ("ci=CODE&utm_source=…" or "ref=CODE") -> parts.
  static ({String? circle, String? referral}) fromReferrer(String? raw) {
    if (raw == null || raw.isEmpty) return (circle: null, referral: null);
    Map<String, String> q;
    try {
      q = Uri.splitQueryString(raw);
    } catch (_) {
      return (circle: null, referral: null);
    }
    final ci = codeFrom(q['ci']);
    final ref = q['ref'];
    final okRef = ref != null && RegExp(r'^[A-Za-z0-9]{4,12}$').hasMatch(ref)
        ? ref.toUpperCase()
        : null;
    return (circle: ci, referral: okRef);
  }

  static bool isInvitePath(String? name) =>
      name != null && name.contains('/i/') && codeFrom(name) != null;
}

/// The invite waiting to be joined. In memory for the router + persisted so a
/// kill between "install" and "join" doesn't lose it (7 days, then dropped).
class PendingInvite {
  PendingInvite._();

  static const _kCode = 'ij_pending_code';
  static const _kAt = 'ij_pending_at';
  static const _kVia = 'ij_pending_via';
  static const _kRef = 'ij_pending_referral';
  static const _kReferrerAsked = 'ij_referrer_asked';
  static const ttl = Duration(days: 7);

  /// Router listens: a new code while signed out swaps Login for Join.
  static final ValueNotifier<String?> code = ValueNotifier<String?>(null);
  static String via = 'link';
  static String? referral;

  static Future<void> set(String c, {String via = 'link'}) async {
    PendingInvite.via = via;
    code.value = c;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCode, c);
      await p.setString(_kVia, via);
      await p.setInt(_kAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> setReferral(String r) async {
    referral = r;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kRef, r);
    } catch (_) {}
  }

  static Future<void> clear() async {
    code.value = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kCode);
      await p.remove(_kAt);
      await p.remove(_kVia);
    } catch (_) {}
  }

  static Future<void> clearReferral() async {
    referral = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kRef);
    } catch (_) {}
  }

  /// Startup: restore a code saved by an earlier launch (fast prefs read).
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getString(_kCode);
      final at = p.getInt(_kAt) ?? 0;
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
      if (c != null && InviteLink.codeFrom(c) != null && age < ttl) {
        via = p.getString(_kVia) ?? 'link';
        code.value ??= c;
      } else if (c != null) {
        await p.remove(_kCode);
      }
      referral ??= p.getString(_kRef);
    } catch (_) {}
  }

  /// A route name / URL that carries an invite -> remembered. True if taken.
  static bool takeLink(String? name) {
    final c = InviteLink.codeFrom(name);
    if (c != null && name != null && name.contains('/i/')) {
      set(c, via: 'link');
      return true;
    }
    final r = InviteLink.referralFrom(name);
    if (r != null) {
      setReferral(r);
      return true;
    }
    return false;
  }

  /// Play Install Referrer, asked ONCE per install. [channel] is injectable
  /// for tests. Never throws, never blocks the caller for more than ~6 s.
  static Future<String?> readReferrerOnce({MethodChannel? channel}) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kReferrerAsked) ?? false) return null;
      await p.setBool(_kReferrerAsked, true);
      final ch = channel ?? const MethodChannel('com.assisto/install_referrer');
      final raw = await ch
          .invokeMethod<String>('get')
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
      final parts = InviteLink.fromReferrer(raw);
      if (parts.circle != null && code.value == null) {
        await set(parts.circle!, via: 'referrer');
      }
      if (parts.referral != null && referral == null) {
        await setReferral(parts.referral!);
      }
      return parts.circle;
    } catch (_) {
      return null; // no channel (tests / iOS / sideload): nothing to do
    }
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    code.value = null;
    via = 'link';
    referral = null;
  }
}
