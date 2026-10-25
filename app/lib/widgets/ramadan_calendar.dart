import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import 'ramadan_day_grid.dart';
import '../l10n/app_localizations.dart';

/// Locale-aware integer (Western digits, or Bangla via codepoints when bn).
/// Codepoints only — no Bangla glyphs in source. (Bengali zero == U+09E6.)
String _localeNum(BuildContext context, int n) {
  if (Localizations.localeOf(context).languageCode != 'bn') return '$n';
  const zeroBn = 0x09E6;
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Ramadan calendar — a 30-day grid built from a USER-supplied start date
/// (moon-sighting varies by country, so we never hard-code it). Highlights the
/// current day ("day N of 30"). Mirrors `core.logic.ramadan.ramadan_calendar`.
/// The start date is kept locally (SharedPreferences); nothing is invented.
class RamadanCalendar extends StatefulWidget {
  const RamadanCalendar({super.key});
  @override
  State<RamadanCalendar> createState() => _RamadanCalendarState();
}

class _RamadanCalendarState extends State<RamadanCalendar> {
  static const _prefsKey = 'ramadan_start_date';
  static const int _length = 30;
  DateTime? _start;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsKey);
    if (mounted) {
      setState(() {
        _start = s == null ? null : DateTime.tryParse(s);
        _loaded = true;
      });
    }
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _start ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, iso);
    if (mounted) setState(() => _start = picked);
  }

  int? _currentDay() {
    if (_start == null) return null;
    final today = DateUtils.dateOnly(DateTime.now());
    final start = DateUtils.dateOnly(_start!);
    final diff = today.difference(start).inDays;
    if (diff < 0 || diff >= _length) return null;
    return diff + 1;
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
    final day = _currentDay();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.calendar_month_rounded, color: Brand.blue),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanCalendarTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            TextButton(
              onPressed: _pickStart,
              child:
                  Text(_start == null ? t.ramadanSetStart : t.ramadanChangeStart),
            ),
          ]),
          if (_start == null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.ramadanSetStartHint,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            )
          else ...[
            Text(
              day == null
                  ? t.ramadanNotRunning
                  : t.ramadanDayOf(
                      _localeNum(context, day), _localeNum(context, _length)),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Gap.sm),
            _grid(context, day),
          ],
        ]),
      ),
    );
  }

  Widget _grid(BuildContext context, int? today) {
    // qa2: shared 6/5-column grid, 48dp rows (was 7 x 36dp).
    return RamadanDayGrid(
      count: _length,
      cell: (context, n, _) {
        final scheme = Theme.of(context).colorScheme;
        final isToday = today == n;
        final isPast = today != null && n < today;
        final Color bg;
        final Color fg;
        if (isToday) {
          bg = Brand.purple;
          fg = Colors.white;
        } else if (isPast) {
          bg = Brand.blue.withValues(alpha: 0.14);
          fg = Brand.onTint(context, Brand.blue);
        } else {
          bg = scheme.onSurface.withValues(alpha: 0.06);
          fg = scheme.onSurfaceVariant; // qa1: was 2.8:1 in dark mode
        }
        return Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(_localeNum(context, n),
              style: TextStyle(
                  color: fg,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.w500)),
        );
      },
    );
  }
}
