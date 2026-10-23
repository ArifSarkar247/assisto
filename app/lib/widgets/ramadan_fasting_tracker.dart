import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import 'ramadan_day_grid.dart';
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
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          RamadanDayGrid(
            count: _total,
            cell: (context, n, _) {
              final on = _kept.contains(n);
              final scheme = Theme.of(context).colorScheme;
              return Semantics(
                button: true,
                selected: on,
                label: _localeNum(context, n),
                excludeSemantics: true,
                child: Material(
                  color: on ? Brand.purple : scheme.onSurface.withValues(alpha: 0.06),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: on
                        ? BorderSide.none
                        : BorderSide(color: scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _toggle(n),
                    child: Center(
                      child: on
                          ? const Icon(Icons.check,
                              size: 20, color: Colors.white)
                          : Text(_localeNum(context, n),
                              style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: scheme.onSurface)),
                    ),
                  ),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }
}
