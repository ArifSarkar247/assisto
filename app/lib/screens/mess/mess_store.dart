import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../mess_v2_api.dart';
import '../../services/error_kind.dart';

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

  /// Number of writes still waiting for the internet (for [messId] or all).
  static Future<int> pending([int? messId]) async {
    final ops = await _load();
    return messId == null ? ops.length : ops.where((o) => o['mess'] == messId).length;
  }

  /// gap-money: one request may wait at most this long on a weak 2G line
  /// before the write is kept for later (it used to hang with no limit).
  static const requestTimeout = Duration(seconds: 15);

  /// True when [e] means "try again later" — no answer, our server's 5xx,
  /// a timeout or rate limit (408 / 429). A real refusal (closed month,
  /// cut-off, not allowed) is never one. [flush] also keeps a 401 (an
  /// expired session is not the entry's fault) so it is sent after sign-in.
  static bool isTransient(Object e, {bool keepUnauthorized = false}) {
    if (e is ApiException) {
      final s = e.status ?? 0;
      if (s == 408 || s == 429) return true;
      if (keepUnauthorized && s == 401) return true;
    }
    return failKindOf(e) != FailKind.refused;
  }

  /// Send now; on a network / server failure keep it and return 'queued'. A
  /// server refusal is rethrown so the caller shows it. 'sent' | 'queued'.
  static Future<String> write(ApiClient api, int messId, String path,
      Map<String, dynamic> body) async {
    final b = {...body, 'client_id': body['client_id'] ?? newClientId()};
    // gap-money: when the user pressed Save — sent with a QUEUED write so a
    // meal change made offline before the cut-off still counts when it syncs
    // later (the server checks it: before the cut-off, at most 24 h late).
    final savedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await api.messWrite(path, b).timeout(requestTimeout);
      return 'sent';
    } catch (e) {
      if (!isTransient(e)) rethrow;
      await _mutate((ops) => ops.add(
          {'mess': messId, 'path': path, 'body': {...b, 'saved_at': savedAt}}));
      return 'queued';
    }
  }

  // Every read-modify-write of the queue is ATOMIC: after the one await for
  // the prefs instance, read -> change -> write run with no await between
  // (SharedPreferences updates its cache synchronously), so a write queued
  // while a flush is sending is never overwritten by the flush's save.
  // (No static Future chain: it would outlive a widget-test zone.)
  static Future<void> _mutate(void Function(List<Map<String, dynamic>> ops) change) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      final ops = (raw == null || raw.isEmpty)
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List).whereType<Map>()
              .map((m) => m.cast<String, dynamic>()).toList();
      change(ops);
      unawaited(p.setString(_key, jsonEncode(ops)));
    } catch (_) {}
  }

  static Future<({int sent, List<String> refused})>? _flushing;

  /// Re-send everything queued, oldest first. Stops at the first transient
  /// failure (still offline / server busy) and keeps that op and the rest.
  /// A server refusal drops that op and is reported in the returned list so
  /// the screen can tell the user. Single-flight: a second caller (resume +
  /// pull-to-refresh at once) shares the running pass.
  static Future<({int sent, List<String> refused})> flush(ApiClient api) =>
      _flushing ??= _flush(api).whenComplete(() => _flushing = null);

  static Future<({int sent, List<String> refused})> _flush(ApiClient api) async {
    final ops = await _load();
    if (ops.isEmpty) return (sent: 0, refused: const <String>[]);
    var sent = 0;
    final refused = <String>[];
    final done = <String>{};
    for (final o in ops) {
      final body = (o['body'] as Map).cast<String, dynamic>();
      try {
        await api.messWrite('${o['path']}', body).timeout(requestTimeout);
        sent++;
      } catch (e) {
        if (isTransient(e, keepUnauthorized: true)) break;
        refused.add(e is ApiException ? e.message : '$e');
      }
      done.add('${body['client_id']}');
    }
    if (done.isNotEmpty) {
      await _mutate((now) => now.removeWhere(
          (o) => done.contains('${(o['body'] as Map?)?['client_id']}')));
    }
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
/// One mess entry may be at most ৳1,00,00,000 (views_mess._poisha).
const messMaxPoisha = 1000000000;

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
  var s = b.toString().replaceAll(RegExp(r'bdt|tk\.?|taka', caseSensitive: false), '');
  // gap-money: the Bangla word "taka" (U+099F U+09BE U+0995 U+09BE) and the
  // everyday "500/-" / "500/=" endings are part of how people write money.
  s = s.replaceAll('\u099F\u09BE\u0995\u09BE', '');
  s = s.replaceAll(RegExp(r'[৳,\s]'), '');
  s = s.replaceAll(RegExp(r'/[-=]$'), '');
  if (s.isEmpty || !RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  final frac = parts.length > 1 ? '${parts[1]}00'.substring(0, 2) : '00';
  final p = whole * 100 + int.parse(frac);
  // gap-money: the server's limit (৳1 crore per entry) — a bigger number
  // used to pass here and then fail as a confusing server error.
  if (p <= 0 || p > messMaxPoisha) return null;
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

/// gap-money: poisha -> "৳1,23,456.50" (lakh grouping, like the server's
/// fmt_poisha). Latin digits — wrap in [messDigits] for the Bangla UI.
String messPoishaText(int p) {
  final neg = p < 0;
  final a = p.abs();
  final taka = '${a ~/ 100}';
  final paisa = (a % 100).toString().padLeft(2, '0');
  String g;
  if (taka.length <= 3) {
    g = taka;
  } else {
    var head = taka.substring(0, taka.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    g = '${parts.join(',')},${taka.substring(taka.length - 3)}';
  }
  return '${neg ? '-' : ''}৳$g.$paisa';
}

/// gap-money (trust, owner order J): WHAT changed in one edit-history row,
/// from the server's before/after — "৳500.00 → ৳5,000.00 · 5/11" for an
/// edit, "৳700.00 · 3/11" for an add or delete, meals "1/1/1 → 0/1/1".
/// Latin digits; the caller localizes with [messDigits]. '' when nothing to
/// show (member / month rows).
String messHistoryDetail(Object? before, Object? after) {
  final b = before is Map ? before : const {};
  final a = after is Map ? after : const {};
  String day(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '' : '${d.day}/${d.month}';
  }

  String meals(Map m) => (m.containsKey('b') || m.containsKey('l') || m.containsKey('d'))
      ? '${m['b'] ?? 1}/${m['l'] ?? 1}/${m['d'] ?? 1}'
      : '';
  final parts = <String>[];
  final ba = b['amount'], aa = a['amount'];
  if (ba is num && aa is num && ba != aa) {
    parts.add('${messPoishaText(ba.toInt())} → ${messPoishaText(aa.toInt())}');
  } else if ((aa ?? ba) is num && (aa ?? ba) != 0) {
    parts.add(messPoishaText(((aa ?? ba) as num).toInt()));
  }
  final mb = meals(b), ma = meals(a);
  if (mb.isNotEmpty && ma.isNotEmpty && mb != ma) {
    parts.add('$mb → $ma');
  } else if (ma.isNotEmpty && mb.isEmpty) {
    parts.add(ma);
  }
  final db = day(b['date']), da = day(a['date']);
  if (db.isNotEmpty && da.isNotEmpty && db != da) {
    parts.add('$db → $da');
  } else if ((da.isNotEmpty ? da : db).isNotEmpty) {
    parts.add(da.isNotEmpty ? da : db);
  }
  return parts.join(' · ');
}
