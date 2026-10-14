import 'package:shared_preferences/shared_preferences.dart';

/// Local store for SAVED health tips (bookmark). Persists just the stable tip
/// `id`s in SharedPreferences so a user's saved list survives restarts without
/// any server call. No PII, no health data — only opaque content ids (e.g.
/// "handwash"). Kept self-contained so the Health-Tips module ships without
/// editing shared state.dart.
class HtipsStore {
  static const _key = 'htips_saved_ids';

  /// The set of saved tip ids (order not significant).
  static Future<Set<String>> savedIds() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_key) ?? const <String>[]).toSet();
  }

  /// Toggle a tip's saved state; returns the new saved state (true=now saved).
  static Future<bool> toggle(String id) async {
    final p = await SharedPreferences.getInstance();
    final ids = (p.getStringList(_key) ?? const <String>[]).toSet();
    final bool nowSaved;
    if (ids.contains(id)) {
      ids.remove(id);
      nowSaved = false;
    } else {
      ids.add(id);
      nowSaved = true;
    }
    await p.setStringList(_key, ids.toList());
    return nowSaved;
  }

  static Future<bool> isSaved(String id) async => (await savedIds()).contains(id);
}
