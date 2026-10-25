import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/error_report.dart';

/// wa-polish2 — which RECEIVED voice notes this phone has played, for
/// WhatsApp's "unplayed" dot. Only the media ref (a random id, never content
/// or a key) is kept, on this phone only, newest [kVoicePlayedCap] refs.
/// Loaded lazily on the first voice bubble — nothing at launch.
const int kVoicePlayedCap = 600;
const String _kPrefKey = 'wa2_voice_played';

class VoicePlayedStore {
  VoicePlayedStore._();
  static final VoicePlayedStore instance = VoicePlayedStore._();

  /// The played refs; listeners rebuild the dots. `null` until loaded (no dot
  /// is drawn before then, so nothing flickers on).
  final ValueNotifier<Set<String>?> played = ValueNotifier(null);
  List<String> _order = [];
  Future<void>? _loading;

  /// Load once (idempotent).
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _order = p.getStringList(_kPrefKey) ?? [];
    } catch (e) {
      reportNonFatal('wa2_voice_played_load', e);
      _order = [];
    }
    played.value = {..._order, ...?played.value};
  }

  bool isPlayed(String ref) => played.value?.contains(ref) ?? true;

  /// Mark [ref] played (once); persisted quietly.
  Future<void> mark(String ref) async {
    if (ref.isEmpty) return;
    await ensureLoaded();
    final cur = played.value ?? <String>{};
    if (cur.contains(ref)) return;
    _order = [..._order.where((r) => r != ref), ref];
    if (_order.length > kVoicePlayedCap) {
      _order = _order.sublist(_order.length - kVoicePlayedCap);
    }
    played.value = {..._order};
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kPrefKey, _order);
    } catch (e) {
      reportNonFatal('wa2_voice_played_save', e);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _order = [];
    _loading = null;
    played.value = null;
  }
}

/// wa-polish2: a stable "looks like speech" waveform for a note that carries
/// no amplitude samples (older senders): seeded by [seed], so the same note
/// always draws the same bars. Levels 0..31 like the recorder's.
List<int> seededWave(int seed, {int n = 32}) {
  var x = (seed & 0x7fffffff) ^ 0x5bd1e995;
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    // a tiny deterministic LCG (no dart:math Random state)
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    final base = 6 + ((x >> 16) % 18); // 6..23
    // a soft envelope: quieter at both ends, like a spoken phrase
    final edge = (i < 3 || i >= n - 3) ? 0.55 : 1.0;
    out.add((base * edge).round().clamp(2, 31));
  }
  return out;
}
