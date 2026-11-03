// p3faith (owner PART 3, 3 Nov 2026): today's worship tracker — the five
// prayers + Quran pages read. User-entered only (never auto-marked), kept on
// the phone (SharedPreferences). Fasting stays in RamadanFastingTracker (one
// source of truth for fasts).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'local_digits.dart';

/// One day: prayers done (5 flags, Fajr..Isha) + Quran pages.
class FaithDay {
  final List<bool> prayers;
  final int pages;
  const FaithDay(this.prayers, this.pages);
  static const empty = FaithDay([false, false, false, false, false], 0);

  int get prayed => prayers.where((p) => p).length;

  Map<String, dynamic> toJson() =>
      {'p': [for (final b in prayers) b ? 1 : 0], 'q': pages};

  static FaithDay fromJson(Object? v) {
    if (v is! Map) return empty;
    final p = (v['p'] is List) ? (v['p'] as List) : const [];
    return FaithDay(
      [for (var i = 0; i < 5; i++) i < p.length && (p[i] == 1 || p[i] == true)],
      ((v['q'] is int) ? v['q'] as int : 0).clamp(0, FaithLog.maxPages),
    );
  }

  FaithDay withPrayer(int i, bool on) =>
      FaithDay([for (var k = 0; k < 5; k++) k == i ? on : prayers[k]], pages);
  FaithDay withPages(int n) =>
      FaithDay(prayers, n.clamp(0, FaithLog.maxPages));
}

/// Local log keyed by yyyy-MM-dd; keeps the last [keepDays] days.
class FaithLog {
  static const prefsKey = 'faith_log_v1';
  static const keepDays = 60;
  static const maxPages = 604; // pages of a standard Madani mushaf

  static String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  static Future<Map<String, FaithDay>> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final v = jsonDecode(p.getString(prefsKey) ?? '{}');
      if (v is! Map) return {};
      return {
        for (final e in v.entries) '${e.key}': FaithDay.fromJson(e.value)
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<String, FaithDay> log, DateTime today) async {
    final cutoff = dayKey(today.subtract(const Duration(days: keepDays)));
    final p = await SharedPreferences.getInstance();
    await p.setString(
        prefsKey,
        jsonEncode({
          for (final e in log.entries)
            if (e.key.compareTo(cutoff) >= 0) e.key: e.value.toJson()
        }));
  }

  /// Prayers done / possible and pages over the 7 days ending [today].
  static ({int prayed, int possible, int pages}) week(
      Map<String, FaithDay> log, DateTime today) {
    var prayed = 0, pages = 0;
    for (var i = 0; i < 7; i++) {
      final d = log[dayKey(today.subtract(Duration(days: i)))];
      if (d == null) continue;
      prayed += d.prayed;
      pages += d.pages;
    }
    return (prayed: prayed, possible: 35, pages: pages);
  }
}

class RamadanDailyTracker extends StatefulWidget {
  /// Opens the Quran reader (null when the Quran feature is off).
  final VoidCallback? onOpenQuran;
  final DateTime? today; // tests
  const RamadanDailyTracker({super.key, this.onOpenQuran, this.today});
  @override
  State<RamadanDailyTracker> createState() => _RamadanDailyTrackerState();
}

class _RamadanDailyTrackerState extends State<RamadanDailyTracker> {
  Map<String, FaithDay> _log = {};
  bool _loaded = false;

  DateTime get _today => widget.today ?? DateTime.now();
  String get _key => FaithLog.dayKey(_today);
  FaithDay get _day => _log[_key] ?? FaithDay.empty;

  @override
  void initState() {
    super.initState();
    FaithLog.load().then((v) {
      if (mounted) {
        setState(() {
          _log = v;
          _loaded = true;
        });
      }
    });
  }

  void _set(FaithDay d) {
    setState(() => _log = {..._log, _key: d});
    FaithLog.save(_log, _today);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!_loaded) return const SizedBox.shrink();
    final names = [
      t.ramadanFajr, t.ramadanDhuhr, t.ramadanAsr, t.ramadanMaghrib,
      t.ramadanIsha,
    ];
    final d = _day;
    final w = FaithLog.week(_log, _today);
    return Container(
      key: const Key('ramadan-daily-tracker'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.rmd2TrackerTitle,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.xxs),
        Text(t.rmd2TrackerHint,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (var i = 0; i < 5; i++)
            FilterChip(
              key: Key('faith-prayer-$i'),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(names[i]),
              selected: d.prayers[i],
              onSelected: (on) => _set(d.withPrayer(i, on)),
            ),
        ]),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: Text(t.rmd2QuranPages(ld(context, d.pages)),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            key: const Key('faith-pages-minus'),
            tooltip: t.rmd2PagesMinus,
            icon: const Icon(Icons.remove_circle_outline_rounded),
            onPressed: d.pages > 0 ? () => _set(d.withPages(d.pages - 1)) : null,
          ),
          IconButton(
            key: const Key('faith-pages-plus'),
            tooltip: t.rmd2PagesPlus,
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: () => _set(d.withPages(d.pages + 1)),
          ),
        ]),
        Text(
            t.rmd2Week(ld(context, w.prayed), ld(context, w.possible),
                ld(context, w.pages)),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        if (widget.onOpenQuran != null) ...[
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('faith-open-quran'),
              icon: const Icon(Icons.menu_book_rounded),
              label: Text(t.rmd2OpenQuran),
              onPressed: widget.onOpenQuran,
            ),
          ),
        ],
      ]),
    );
  }
}
