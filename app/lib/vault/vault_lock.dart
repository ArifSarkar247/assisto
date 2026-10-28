// vault100 — the vault's DEVICE lock: PIN (salted PBKDF2 hash, never the
// PIN itself), wrong-PIN back-off, optional fingerprint, and the offline
// RECOVERY CODE. Everything here stays on this phone; nothing is ever sent to
// the server (core/vault_recovery refuses any request carrying a PIN/code).
//
// Honest model (shown in the app, see VaultSecurityScreen):
//   * documents live with the user's ACCOUNT on the server (auth-checked
//     links) — they are NOT encrypted with the PIN, so a forgotten PIN never
//     loses a document; proving it is you (SMS/email code, password or the
//     recovery code) lets you set a new PIN;
//   * "available offline" copies are sealed with a separate random key
//     (VaultOffline), not with the PIN — a PIN reset keeps them.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hc;

import '../security/secret_store.dart';

/// The secure key-value slots this file uses (SecretStore names).
class VaultSlots {
  static const legacyPin = 'vault_pin'; // plaintext PIN of builds <= 262
  static const pinHash = 'vault_pin_h1';
  static const fails = 'vault_pin_fails';
  static const codeFails = 'vault_rc_fails'; // own back-off: a PIN lock-out never blocks recovery
  static const recovery = 'vault_rc_h1';
  static const bio = 'vault_bio';
}

/// Minimal store interface so tests can inject a map.
abstract class VaultKv {
  Future<String?> read(String name);
  Future<bool> write(String name, String value);
  Future<void> delete(String name);
}

class SecretKv implements VaultKv {
  final SecretStore? _s;
  const SecretKv([this._s]);
  SecretStore get _store => _s ?? SecretStore.instance;
  @override
  Future<String?> read(String name) => _store.read(name);
  @override
  Future<bool> write(String name, String value) => _store.write(name, value);
  @override
  Future<void> delete(String name) => _store.delete(name);
}

class MemoryKv implements VaultKv {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<bool> write(String name, String value) async {
    values[name] = value;
    return true;
  }

  @override
  Future<void> delete(String name) async => values.remove(name);
}

enum PinCheck { ok, wrong, lockedOut, noPin }

class VaultLock {
  VaultLock({VaultKv? kv, this.iterations = 30000, DateTime Function()? clock, Random? rng})
      : kv = kv ?? const SecretKv(),
        _now = clock ?? DateTime.now,
        _rng = rng ?? Random.secure();

  final VaultKv kv;
  final int iterations;
  final DateTime Function() _now;
  final Random _rng;

  static const int minPin = 4;
  static const int maxPin = 6;
  static const int freeTries = 5;
  static const Duration firstLockout = Duration(seconds: 30);
  static const Duration maxLockout = Duration(minutes: 15);
  static const String _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  // ------------------------------------------------------------ hashing
  static Uint8List pbkdf2(List<int> secret, List<int> salt, int iters, [int len = 32]) {
    final hmac = hc.Hmac(hc.sha256, secret);
    final out = <int>[];
    var block = 1;
    while (out.length < len) {
      var u = hmac.convert([...salt, (block >> 24) & 255, (block >> 16) & 255,
        (block >> 8) & 255, block & 255]).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iters; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.addAll(t);
      block++;
    }
    return Uint8List.fromList(out.sublist(0, len));
  }

  Uint8List _random(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// Off the UI thread for real iteration counts (tests use tiny ones).
  static Future<Uint8List> derive(List<int> secret, List<int> salt, int iters,
      [int len = 32]) {
    if (iters <= 2000) return Future.value(pbkdf2(secret, salt, iters, len));
    final s = List<int>.from(secret), sa = List<int>.from(salt);
    return Isolate.run(() => pbkdf2(s, sa, iters, len));
  }

  Future<String> _seal(String secret) async {
    final salt = _random(16);
    final h = await derive(utf8.encode(secret), salt, iterations);
    return 'v1\$$iterations\$${base64Encode(salt)}\$${base64Encode(h)}';
  }

  static Future<bool> _matches(String stored, String secret) async {
    final p = stored.split('\$');
    if (p.length != 4 || p[0] != 'v1') return false;
    final iters = int.tryParse(p[1]) ?? 0;
    if (iters < 1) return false;
    final salt = base64Decode(p[2]);
    final want = base64Decode(p[3]);
    final got = await derive(utf8.encode(secret), salt, iters, want.length);
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= want[i] ^ got[i];
    }
    return diff == 0;
  }

  static bool validPin(String pin) =>
      pin.length >= minPin && pin.length <= maxPin && RegExp(r'^\d+$').hasMatch(pin);

  // ------------------------------------------------------------ PIN
  /// True when this phone has a vault PIN (hashed, or a legacy plaintext one
  /// an older build left — migrated to a hash on the next correct unlock).
  Future<bool> hasPin() async =>
      (await kv.read(VaultSlots.pinHash)) != null ||
      (await kv.read(VaultSlots.legacyPin)) != null;

  Future<bool> setPin(String pin) async {
    if (!validPin(pin)) return false;
    final ok = await kv.write(VaultSlots.pinHash, await _seal(pin));
    if (ok) {
      await kv.delete(VaultSlots.legacyPin);
      await kv.delete(VaultSlots.fails);
    }
    return ok;
  }

  /// Remaining lock-out, or null when a try is allowed now.
  Future<Duration?> lockedFor([String slot = VaultSlots.fails]) async {
    final f = await _fails(slot);
    final until = f.until;
    if (until == null) return null;
    final left = until.difference(_now());
    return left > Duration.zero ? left : null;
  }

  Future<PinCheck> check(String pin) async {
    if (await lockedFor() != null) return PinCheck.lockedOut;
    final h = await kv.read(VaultSlots.pinHash);
    bool ok;
    if (h != null) {
      ok = await _matches(h, pin);
    } else {
      final legacy = await kv.read(VaultSlots.legacyPin);
      if (legacy == null) return PinCheck.noPin;
      ok = legacy == pin;
      if (ok) await setPin(pin); // migrate: hash it, drop the plaintext
    }
    if (ok) {
      await kv.delete(VaultSlots.fails);
      return PinCheck.ok;
    }
    final f = await _fails();
    final n = f.count + 1;
    DateTime? until;
    if (n >= freeTries) {
      final steps = n - freeTries; // 30 s, 60 s, 120 s ... max 15 min
      final secs = min(maxLockout.inSeconds, firstLockout.inSeconds * (1 << min(steps, 10)));
      until = _now().add(Duration(seconds: secs));
    }
    await kv.write(VaultSlots.fails, jsonEncode({
      'n': n,
      if (until != null) 'until': until.toIso8601String(),
    }));
    return until != null ? PinCheck.lockedOut : PinCheck.wrong;
  }

  Future<int> triesLeftBeforeLockout() async {
    final f = await _fails();
    return max(0, freeTries - f.count);
  }

  Future<({int count, DateTime? until})> _fails([String slot = VaultSlots.fails]) async {
    try {
      final raw = await kv.read(slot);
      if (raw == null) return (count: 0, until: null);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        count: (j['n'] as num?)?.toInt() ?? 0,
        until: j['until'] == null ? null : DateTime.tryParse('${j['until']}'),
      );
    } catch (_) {
      return (count: 0, until: null);
    }
  }

  /// After the server verified it is the account owner (or a recovery code
  /// matched): forget the PIN so the user sets a new one. Offline copies and
  /// documents are untouched.
  Future<void> clearPin() async {
    await kv.delete(VaultSlots.pinHash);
    await kv.delete(VaultSlots.legacyPin);
    await kv.delete(VaultSlots.fails);
  }

  // ------------------------------------------------------------ fingerprint
  Future<bool> biometricEnabled() async => (await kv.read(VaultSlots.bio)) == '1';
  Future<void> setBiometric(bool on) async =>
      on ? await kv.write(VaultSlots.bio, '1') : await kv.delete(VaultSlots.bio);

  // ------------------------------------------------------------ recovery code
  Future<bool> hasRecoveryCode() async => (await kv.read(VaultSlots.recovery)) != null;

  /// A fresh 16-character code (shown ONCE, grouped XXXX-XXXX-XXXX-XXXX).
  /// Only its salted hash is kept, on this phone. Replaces any older code.
  Future<String?> newRecoveryCode() async {
    final chars = List.generate(16, (_) => _codeAlphabet[_rng.nextInt(_codeAlphabet.length)]);
    final code = chars.join();
    final ok = await kv.write(VaultSlots.recovery, await _seal(code));
    return ok ? formatCode(code) : null;
  }

  static String normalizeCode(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String formatCode(String code) {
    final c = normalizeCode(code);
    final parts = <String>[];
    for (var i = 0; i < c.length; i += 4) {
      parts.add(c.substring(i, min(i + 4, c.length)));
    }
    return parts.join('-');
  }

  /// Single use: a match clears the PIN AND burns the code (make a new one
  /// after setting the new PIN). Wrong codes count toward the same back-off.
  Future<PinCheck> useRecoveryCode(String raw) async {
    const slot = VaultSlots.codeFails;
    if (await lockedFor(slot) != null) return PinCheck.lockedOut;
    final h = await kv.read(VaultSlots.recovery);
    if (h == null) return PinCheck.noPin;
    if (await _matches(h, normalizeCode(raw))) {
      await kv.delete(VaultSlots.recovery);
      await kv.delete(slot);
      await clearPin();
      return PinCheck.ok;
    }
    final f = await _fails(slot);
    final n = f.count + 1;
    DateTime? until;
    if (n >= freeTries) {
      until = _now().add(firstLockout * (1 << min(n - freeTries, 5)));
    }
    await kv.write(slot, jsonEncode({
      'n': n,
      if (until != null) 'until': until.toIso8601String(),
    }));
    return until != null ? PinCheck.lockedOut : PinCheck.wrong;
  }

  /// Remaining recovery-code lock-out (separate from the PIN's).
  Future<Duration?> codeLockedFor() => lockedFor(VaultSlots.codeFails);

  Future<void> deleteRecoveryCode() => kv.delete(VaultSlots.recovery);
}
