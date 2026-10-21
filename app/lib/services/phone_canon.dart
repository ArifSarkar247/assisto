import 'dart:convert';

import '../crypto/e2e.dart';

/// c1-contacts — THE on-device phone canonicaliser + contact-match hash.
///
/// Byte-for-byte mirror of the server helper `backend/core/phone.py`
/// (`canonical_phone` / `hash_canonical`). Both sides pin the same examples in
/// their tests (backend/core/tests_c1_contacts.py, test/c1_phone_canon_test.dart).
///
/// * Bangladesh mobiles -> E.164 `+8801XXXXXXXXX`. Accepts 01…, 1…, 8801…,
///   +880…, 00880…, "+880 01…", spaces, dashes, dots, brackets and Bangla
///   digits (U+09E6..U+09EF).
/// * Other countries only when written with an explicit `+` or `00`.
/// * Anything else -> `null` (rejected honestly, never guessed).
///
/// Hash (contract v1, GET /messenger/contacts/contract):
///   hex(HMAC-SHA256(key = salt, msg = canonical))[:hashLen]
class PhoneCanon {
  PhoneCanon._();

  static final RegExp _separators = RegExp(r'[\s\-(). ​/]');
  static final RegExp _bdSubscriber = RegExp(r'^1[3-9]\d{8}$');
  static final RegExp _digits = RegExp(r'^\d+$');

  /// Bangla digits -> ASCII digits.
  static String toAsciiDigits(String raw) {
    final b = StringBuffer();
    for (final r in raw.runes) {
      if (r >= 0x09E6 && r <= 0x09EF) {
        b.writeCharCode(0x30 + (r - 0x09E6));
      } else {
        b.writeCharCode(r);
      }
    }
    return b.toString();
  }

  /// Canonical E.164 string or null.
  static String? canonical(String? raw) {
    var s = toAsciiDigits((raw ?? '').trim()).replaceAll(_separators, '');
    if (s.isEmpty) return null;
    var intl = false;
    if (s.startsWith('+')) {
      s = s.substring(1);
      intl = true;
    } else if (s.startsWith('00')) {
      s = s.substring(2);
      intl = true;
    }
    if (s.isEmpty || !_digits.hasMatch(s)) return null;
    String? bd;
    if (s.startsWith('880')) {
      bd = s.substring(3);
      if (bd.startsWith('0')) bd = bd.substring(1);
    } else if (!intl) {
      bd = s.startsWith('0') ? s.substring(1) : s;
    }
    if (bd != null) {
      if (_bdSubscriber.hasMatch(bd)) return '+880$bd';
      if (s.startsWith('880') || !intl) return null;
    }
    if (intl && s.length >= 8 && s.length <= 15 && !s.startsWith('0')) {
      return '+$s';
    }
    return null;
  }

  /// Local display form: +8801XXXXXXXXX -> 01XXXXXXXXX (others unchanged).
  static String localForm(String canon) =>
      (canon.startsWith('+8801') && canon.length == 14)
          ? '0${canon.substring(4)}'
          : canon;

  /// hex(HMAC-SHA256(salt, canonical)) truncated to [hashLen] hex chars.
  static String hashCanonical(String canon, String salt, {int hashLen = 32}) {
    if (canon.isEmpty) return '';
    final mac = HmacSha256.mac(utf8.encode(salt), utf8.encode(canon));
    final hex = mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex.substring(0, hashLen.clamp(1, hex.length));
  }
}
