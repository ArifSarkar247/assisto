import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../mess_v2_api.dart';

/// messv2 — offline entry with sync (owner order K).
///
/// A write that fails because the phone is OFFLINE (any error that is not an
/// [ApiException] from our server) is kept here with its `client_id` and
/// re-sent on the next screen open / resume / pull-to-refresh. The server
/// de-duplicates by `client_id`, so a write that actually reached it before the
/// connection dropped is never counted twice. A real server refusal (closed
/// month, cut-off, not allowed) is NEVER queued — it is shown at once.
class MessOutbox {
  MessOutbox._();
  static const _key = 'mess_v2_outbox';
  static const _cacheKey = 'mess_v2_cache_';

  static String newClientId() {
    final r = Random();
    return 'm${DateTime.now().microsecondsSinceEpoch}${r.nextInt(1 << 30)}';
  }

  static Future<List<Map<String, dynamic>>> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).whereType<Map>()
          .map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> ops) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(ops));
    } catch (_) {}
  }

  /// Number of writes still waiting for the internet (for [messId] or all).
  static Future<int> pending([int? messId]) async {
    final ops = await _load();
    return messId == null ? ops.length : ops.where((o) => o['mess'] == messId).length;
  }

  /// Send now; on a network failure keep it and return 'queued'. A server
  /// error is rethrown so the caller shows it. Returns 'sent' | 'queued'.
  static Future<String> write(ApiClient api, int messId, String path,
      Map<String, dynamic> body) async {
    final b = {...body, 'client_id': body['client_id'] ?? newClientId()};
    try {
      await api.messWrite(path, b);
      return 'sent';
    } on ApiException {
      rethrow;
    } catch (_) {
      final ops = await _load();
      ops.add({'mess': messId, 'path': path, 'body': b});
      await _save(ops);
      return 'queued';
    }
  }

  /// Re-send everything queued, oldest first. Stops at the first network
  /// failure (still offline). A server refusal drops that op and is
  /// reported in the returned list so the screen can tell the user.
  static Future<({int sent, List<String> refused})> flush(ApiClient api) async {
    final ops = await _load();
    if (ops.isEmpty) return (sent: 0, refused: const <String>[]);
    var sent = 0;
    final refused = <String>[];
    final left = <Map<String, dynamic>>[];
    var offline = false;
    for (final o in ops) {
      if (offline) {
        left.add(o);
        continue;
      }
      try {
        await api.messWrite('${o['path']}',
            (o['body'] as Map).cast<String, dynamic>());
        sent++;
      } on ApiException catch (e) {
        refused.add(e.message);
      } catch (_) {
        offline = true;
        left.add(o);
      }
    }
    await _save(left);
    return (sent: sent, refused: refused);
  }

  /// Last good detail JSON per mess, so the screen opens offline.
  static Future<void> cache(int messId, Map<String, dynamic> detail) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_cacheKey$messId', jsonEncode(detail));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> cached(int messId) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_cacheKey$messId');
      if (raw == null) return null;
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

/// Taka typed in Bangla, Arabic-Indic or Latin digits, with commas, ৳ / Tk /
/// BDT and spaces -> INTEGER poisha; null when there is no valid number.
/// Same contract as savesweep's takaToPoishaInput (lib/widgets/num_input.dart);
/// the integrator may point this at that shared parser.
int? messTakaToPoisha(String? raw) {
  if (raw == null) return null;
  final b = StringBuffer();
  for (final cu in raw.trim().codeUnits) {
    if (cu >= 0x09E6 && cu <= 0x09EF) {
      b.writeCharCode(0x30 + cu - 0x09E6);
    } else if (cu >= 0x0660 && cu <= 0x0669) {
      b.writeCharCode(0x30 + cu - 0x0660);
    } else if (cu >= 0x06F0 && cu <= 0x06F9) {
      b.writeCharCode(0x30 + cu - 0x06F0);
    } else {
      b.writeCharCode(cu);
    }
  }
  var s = b.toString().replaceAll(RegExp(r'(?i)bdt|tk|taka'), '');
  s = s.replaceAll(RegExp(r'[৳,\s]'), '');
  if (s.isEmpty || !RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  final frac = parts.length > 1 ? '${parts[1]}00'.substring(0, 2) : '00';
  final p = whole * 100 + int.parse(frac);
  if (p <= 0 || p > 100000000000) return null;
  return p;
}

/// Bangla digits while the UI is Bangla.
String messDigits(BuildContext context, Object? v) {
  final s = '${v ?? ''}';
  if (Localizations.maybeLocaleOf(context)?.languageCode != 'bn') return s;
  final b = StringBuffer();
  for (final cu in s.codeUnits) {
    b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? 0x09E6 + (cu - 0x30) : cu);
  }
  return b.toString();
}

/// "2026-11-03" -> "3/11" (localized digits).
String messShortDate(BuildContext context, String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return messDigits(context, iso);
  return messDigits(context, '${d.day}/${d.month}');
}

String messIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
