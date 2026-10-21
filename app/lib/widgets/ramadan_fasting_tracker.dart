import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Locale-aware integer (Bangla via codepoints when bn — no Bangla glyphs here).
String _localeNum(BuildContext context, int n) {
  if (Localizations.localeOf(context).languageCode != 'bn') return '$n';
  const zeroBn = 0x09E6;
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Fasting tracker — the user taps the days they fasted; the count is kept
/// locally (SharedPreferences). Purely user-entered: we never auto-mark a fast.
/// Mirrors `core.logic.ramadan.fasting_stats` (dedup + count out of 30).
class RamadanFastingTracker extends StatefulWidget {
  const RamadanFastingTracker({super.key});
  @override
  State<RamadanFastingTracker> createState() => _RamadanFastingTrackerState();
}

class _RamadanFastingTrackerState extends State<RamadanFastingTracker> {
  static const _prefsKey = 'ramadan_fasts_kept';
  static const int _total = 30;
  final Set<int> _kept = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_prefsKey) ?? const [];
    if (mounted) {
      setState(() {
        _kept
          ..clear()
          ..addAll(list
              .map(int.tryParse)
              .whereType<int>()
              .where((n) => n >= 1 && n <= _total));
        _loaded = true;
      });
    }
  }

  Future<void> _toggle(int day) async {
    setState(() {
      if (!_kept.remove(day)) _kept.add(day);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, _kept.map((e) => e.toString()).toList());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.check_circle_outline, color: Brand.purple),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanFastingTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            Text(
              t.ramadanFastingCount(
                  // signature is (total, kept) — metadata order, not text order
                  _localeNum(context, _total), _localeNum(context, _kept.length)),
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Brand.purple),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.ramadanFastingHint,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List.generate(_total, (i) {
              final n = i + 1;
              final on = _kept.contains(n);
              return GestureDetector(
                onTap: () => _toggle(n),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on
                        ? Brand.purple
                        : Colors.grey.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: on
                        ? null
                        : Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                  child: on
                      ? const Icon(Icons.check, size: 18, color: Colors.white)
                      : Text(_localeNum(context, n),
                          style: TextStyle(color: Colors.grey.shade700)),
                ),
              );
            }),
          ),
        ]),
      ),
    );
  }
}
