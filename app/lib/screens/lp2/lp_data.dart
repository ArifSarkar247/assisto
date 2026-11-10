/// lpapp — Language Partner V2 data: bundled Life English + vocabulary
/// (app/assets/lp, works offline from the first open), newer approved content
/// from the server (GET /lp/content/*, cached), progress in the generic
/// per-user collections lp/days · lp/vocab · lp/results, and offline
/// download of mock tests (JSON + listening audio in the app's own folder).
///
/// Contract: owner_actions/LANGUAGE_PARTNER_API.md (lpcore).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../ielts_engine.dart' show ieltsToday, ieltsStreak, Streak;
import 'lp_engine.dart';

const String kLpDays = 'lp/days';
const String kLpVocab = 'lp/vocab';
const String kLpResults = 'lp/results';

/// Daily goal: minutes of practice (a vocab session ≈ 5, a scenario ≈ 10,
/// a section ≈ its timer).
const int kLpDailyGoalMin = 15;

List<Map<String, dynamic>> lpList(Object? v) =>
    v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];
List<String> lpStrs(Object? v) => v is List ? [for (final e in v) '$e'] : const [];

/// Tests: replace the bundled asset reader.
@visibleForTesting
Future<String> Function(String asset)? debugLpAsset;

class LpContent {
  LpContent._();
  static Map<String, dynamic>? _life, _vocab;

  @visibleForTesting
  static void debugReset() {
    _life = null;
    _vocab = null;
  }

  static Future<Map<String, dynamic>> _bundled(String name) async {
    final s = await (debugLpAsset ?? rootBundle.loadString)('assets/lp/$name');
    return Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  /// Server copy (newer, approved) when cached, else the bundled file.
  static Future<Map<String, dynamic>> _load(String kind, String asset) async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString('lp2_content_$kind');
      if (s != null) {
        final m = Map<String, dynamic>.from(jsonDecode(s) as Map);
        if (lpList(m['items']).isNotEmpty) return m;
      }
    } catch (_) {}
    return _bundled(asset);
  }

  static Future<List<Map<String, dynamic>>> scenarios() async {
    _life ??= await _load('life', 'life_en_v1.json');
    final items = lpList(_life!['items']);
    return items.isNotEmpty ? items : lpList(_life!['scenarios']);
  }

  static Future<List<Map<String, dynamic>>> topics() async {
    _vocab ??= await _load('vocab', 'vocab_v1.json');
    final items = lpList(_vocab!['items']);
    return items.isNotEmpty ? items : lpList(_vocab!['topics']);
  }

  /// Background refresh: fetch newer approved content once the server says
  /// its version is above the bundled one. Never blocks a screen.
  static Future<void> refresh(ApiClient api) async {
    try {
      final v = await api.getJson('/lp/content/version');
      final p = await SharedPreferences.getInstance();
      for (final kind in ['life', 'vocab']) {
        final sv = v[kind];
        if (sv is! int || sv <= (p.getInt('lp2_ver_$kind') ?? 1)) continue;
        final c = await api.getJson('/lp/content/$kind');
        if (lpList(c['items']).isEmpty) continue;
        await p.setString('lp2_content_$kind', jsonEncode(c));
        await p.setInt('lp2_ver_$kind', sv);
        if (kind == 'life') _life = null;
        if (kind == 'vocab') _vocab = null;
      }
    } catch (_) {
      // offline / not deployed yet: the bundled content stays.
    }
  }
}

// ------------------------------------------------------------- progress

class LpProgress {
  final List<Map<String, dynamic>> days;
  final List<Map<String, dynamic>> vocab;
  final List<Map<String, dynamic>> results;
  const LpProgress(this.days, this.vocab, this.results);

  static const empty = LpProgress([], [], []);

  int get today => ieltsToday();
  Streak get streak => ieltsStreak(days.map((d) => (d['day'] as num?)?.toInt() ?? -1).where((d) => d >= 0), today);
  int get minutesToday => days
      .where((d) => (d['day'] as num?)?.toInt() == today)
      .fold<int>(0, (a, d) => a + ((d['minutes'] as num?)?.toInt() ?? 0));

  Map<String, VocabState> get vocabState => {
        for (final r in vocab)
          '${r['card_id']}': VocabState((r['box'] as num?)?.toInt() ?? 1, (r['due'] as num?)?.toInt() ?? 0),
      };

  Map<String, dynamic>? get lastMock {
    final m = results.where((r) => r['kind'] == 'mock').toList();
    if (m.isEmpty) return null;
    m.sort((a, b) => ((b['at'] as num?) ?? 0).compareTo((a['at'] as num?) ?? 0));
    return m.first;
  }

  static Future<LpProgress> load(ApiClient api) async {
    Future<List<Map<String, dynamic>>> safe(String p) async {
      try {
        return await api.listItems(p);
      } on ApiException catch (e) {
        if (e.status == 404) return const [];
        rethrow;
      }
    }

    final r = await Future.wait([safe(kLpDays), safe(kLpVocab), safe(kLpResults)]);
    return LpProgress(r[0], r[1], r[2]);
  }
}

/// Logs practice minutes for today (streak + daily goal). Best-effort.
Future<void> lpLogPractice(ApiClient api, String kind, int minutes) async {
  try {
    await api.createItem(kLpDays, {'day': ieltsToday(), 'kind': kind, 'minutes': minutes});
  } catch (_) {} // best-effort: streak minutes only; the practice itself is done and shown
}

Future<void> lpSaveResult(ApiClient api, Map<String, dynamic> row) async {
  try {
    await api.createItem(kLpResults, {...row, 'at': DateTime.now().millisecondsSinceEpoch, 'day': ieltsToday()});
  } catch (_) {} // best-effort: history copy; the result is already on screen
}

// -------------------------------------------------------- offline mocks

/// Tests: replaces the app folder.
@visibleForTesting
Future<Directory> Function()? debugLpDir;

class LpOffline {
  LpOffline._();

  /// Tests: no app folder (widget tests run without the platform plugin).
  @visibleForTesting
  static bool debugDisabled = false;

  static Future<Directory> _dir() async {
    final base = await (debugLpDir ?? getApplicationDocumentsDirectory)();
    final d = Directory('${base.path}/lp_offline');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<bool> has(String id) async {
    if (debugDisabled) return false;
    try {
      return File('${(await _dir()).path}/${_safe(id)}.json').existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> read(String id) async {
    if (debugDisabled) return null;
    try {
      final f = File('${(await _dir()).path}/${_safe(id)}.json');
      if (!f.existsSync()) return null;
      return Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return null;
    }
  }

  /// Saves the mock and its listening audio (signed links expire, so the
  /// files are kept locally and the JSON points to them).
  static Future<void> save(String id, Map<String, dynamic> mock) async {
    final d = await _dir();
    final copy = jsonDecode(jsonEncode(mock)) as Map<String, dynamic>;
    final parts = lpList((copy['listening'] as Map?)?['parts']);
    for (final p in parts) {
      final url = '${p['audio_url'] ?? ''}';
      if (!url.startsWith('http')) continue;
      final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
      if (r.statusCode != 200) throw const HttpException('audio');
      final f = File('${d.path}/${_safe(id)}_l${p['n']}.audio');
      await f.writeAsBytes(r.bodyBytes);
      p['audio_url'] = f.path;
    }
    if (copy['listening'] is Map) (copy['listening'] as Map)['parts'] = parts;
    await File('${d.path}/${_safe(id)}.json').writeAsString(jsonEncode(copy));
  }

  static Future<void> remove(String id) async {
    try {
      final d = await _dir();
      for (final f in d.listSync()) {
        final n = f.uri.pathSegments.last;
        if (f is File && (n == '${_safe(id)}.json' || n.startsWith('${_safe(id)}_l'))) f.deleteSync();
      }
    } catch (_) {}
  }
}
