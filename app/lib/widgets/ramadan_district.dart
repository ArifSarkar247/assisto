// p3faith (owner PART 3, 3 Nov 2026): Ramadan by DISTRICT (no GPS needed),
// offline cache, month timetable, approximate (lunar) Ramadan dates.
//
// Times come from the backend (core.logic.ramadan.ifb_times): Islamic
// Foundation Bangladesh convention — 18 deg dawn, sehri 3 min before
// Subh-e-Sadiq, iftar 3 min after sunset. The last answer + the month table
// are kept on the phone so sehri/iftar still show without internet.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'local_digits.dart';

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

class RamadanDistrict {
  final String code, bn, en;
  const RamadanDistrict(this.code, this.bn, this.en);
  String name(BuildContext c) => _bn(c) ? bn : en;
}

/// Phone-side cache. Everything is the server's own answer, saved as-is.
class RamadanCache {
  static const _kDistrict = 'ramadan_district_v1';
  static const _kTimes = 'ramadan_times_v1';
  static const _kMonth = 'ramadan_month_v1';
  static const _kDistricts = 'ramadan_districts_v1';
  static const _kSavedAt = 'ramadan_saved_at_v1';

  static Future<String?> district() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kDistrict);
    return (v == null || v.isEmpty) ? null : v;
  }

  static Future<void> setDistrict(String? code) async {
    final p = await SharedPreferences.getInstance();
    if (code == null || code.isEmpty) {
      await p.remove(_kDistrict);
    } else {
      await p.setString(_kDistrict, code);
    }
  }

  static Future<Map<String, dynamic>?> _json(String k) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(k);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _put(String k, Map<String, dynamic> v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(k, jsonEncode(v));
  }

  static Future<void> saveTimes(Map<String, dynamic> t) async {
    await _put(_kTimes, t);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSavedAt, DateTime.now().toIso8601String());
  }

  static Future<Map<String, dynamic>?> times() => _json(_kTimes);
  static Future<void> saveMonth(Map<String, dynamic> m) => _put(_kMonth, m);
  static Future<Map<String, dynamic>?> month() => _json(_kMonth);

  static Future<DateTime?> savedAt() async {
    final p = await SharedPreferences.getInstance();
    return DateTime.tryParse(p.getString(_kSavedAt) ?? '');
  }

  static Future<void> saveDistricts(List<RamadanDistrict> d) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kDistricts,
        jsonEncode([
          for (final x in d) {'code': x.code, 'bn': x.bn, 'en': x.en}
        ]));
  }

  static Future<List<RamadanDistrict>> districts() async {
    final p = await SharedPreferences.getInstance();
    try {
      final v = jsonDecode(p.getString(_kDistricts) ?? '[]') as List;
      return parseDistricts(v);
    } catch (_) {
      return const [];
    }
  }

  /// Offline fallback: today's row of the saved month table (same district),
  /// else the last saved answer. Null when nothing was ever saved.
  static Future<Map<String, dynamic>?> offlineTimes(DateTime today) async {
    final iso = DateFormat('yyyy-MM-dd').format(today);
    final m = await month();
    final last = await times();
    for (final d in (m?['days'] as List?) ?? const []) {
      if (d is Map && d['date'] == iso) {
        return {
          ...?last,
          'date': iso,
          'method': 'ifb',
          'sehri_end': d['sehri_end'],
          'iftar': d['iftar'],
          'fajr': d['fajr'],
          'maghrib': d['maghrib'],
          // other prayers are not in the month table: hide, never guess
          'dhuhr': null, 'asr': null, 'isha': null, 'sunrise': null,
          'district': m?['district'],
          'name_bn': m?['name_bn'],
          'name_en': m?['name_en'],
        };
      }
    }
    if (last != null && last['date'] == iso) return last;
    return null;
  }
}

List<RamadanDistrict> parseDistricts(List raw) => [
      for (final e in raw)
        if (e is Map && e['code'] != null)
          RamadanDistrict('${e['code']}', '${e['bn'] ?? e['name'] ?? ''}',
              '${e['en'] ?? e['name'] ?? ''}'),
    ];

/// Bottom sheet: search + the 64 districts. Returns the picked code.
Future<String?> pickRamadanDistrict(
    BuildContext context, List<RamadanDistrict> all) {
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _DistrictSheet(all: all),
  );
}

class _DistrictSheet extends StatefulWidget {
  final List<RamadanDistrict> all;
  const _DistrictSheet({required this.all});
  @override
  State<_DistrictSheet> createState() => _DistrictSheetState();
}

class _DistrictSheetState extends State<_DistrictSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final q = _q.trim().toLowerCase();
    final list = widget.all
        .where((d) =>
            q.isEmpty || d.bn.contains(q) || d.en.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name(context).compareTo(b.name(context)));
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.rmd2ChooseDistrict,
                  style:
                      AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: Gap.sm),
              TextField(
                key: const Key('ramadan-district-search'),
                autofocus: false,
                decoration: InputDecoration(
                  hintText: t.rmd2SearchDistrict,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: withNavBarInset(context, EdgeInsets.zero),
            itemCount: list.length,
            itemBuilder: (c, i) => ListTile(
              key: Key('ramadan-district-${list[i].code}'),
              minTileHeight: 52,
              leading: const Icon(Icons.place_outlined),
              title: Text(list[i].name(context)),
              onTap: () => Navigator.of(context).pop(list[i].code),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Empty state when there is no location and no district yet: benefit line,
/// big button, how-to.
class RamadanDistrictPrompt extends StatelessWidget {
  final VoidCallback onPick;
  final VoidCallback onGps;
  const RamadanDistrictPrompt(
      {super.key, required this.onPick, required this.onGps});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('ramadan-district-prompt'),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: Brand.purple.withOpacity(0.08),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.nightlight_round_rounded,
            size: 40, color: Brand.purple),
        const SizedBox(height: Gap.sm),
        Text(t.ramadanLocationNeeded,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurface)),
        const SizedBox(height: Gap.xs),
        Text(t.rmd2DistrictWhy,
            textAlign: TextAlign.center,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const Key('ramadan-pick-district'),
          icon: const Icon(Icons.place_rounded),
          label: Text(t.rmd2ChooseDistrict),
          onPressed: onPick,
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.my_location_rounded),
          label: Text(t.rmd2UseGps),
          onPressed: onGps,
        ),
      ]),
    );
  }
}

String _fmtDate(BuildContext c, String iso, {bool withYear = true}) {
  final d = DateTime.tryParse(iso);
  if (d == null) return ld(c, iso);
  final loc = Localizations.localeOf(c).toLanguageTag();
  try {
    final f = withYear ? DateFormat.yMMMd(loc) : DateFormat.MMMd(loc);
    return ld(c, f.format(d));
  } catch (_) {
    return ld(c, (withYear ? DateFormat.yMMMd() : DateFormat.MMMd()).format(d));
  }
}

/// "Next Ramadan (approximate) ... confirm with the moon-sighting committee".
class RamadanApproxCard extends StatelessWidget {
  final Map<String, dynamic> approx;
  const RamadanApproxCard({super.key, required this.approx});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final start = _fmtDate(context, '${approx['start'] ?? ''}');
    final end = _fmtDate(context, '${approx['end'] ?? ''}');
    final during = approx['in_ramadan'] == true;
    return Container(
      key: const Key('ramadan-approx'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.brightness_3_rounded, color: scheme.primary),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                during
                    ? t.rmd2InRamadan(start, end)
                    : t.rmd2NextRamadan(start, end),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xxs),
            Text(t.rmd2MoonNote,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

/// Full month sehri/iftar table (the saved IFB-method month for a district).
Future<void> showRamadanMonth(
    BuildContext context, Map<String, dynamic> month) {
  final t = AppLocalizations.of(context);
  final days = ((month['days'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  final name = _bn(context) ? '${month['name_bn'] ?? ''}' : '${month['name_en'] ?? ''}';
  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.85,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(t.rmd2MonthTitle(name),
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              key: const Key('ramadan-month-list'),
              padding: withNavBarInset(
                  ctx, const EdgeInsets.symmetric(horizontal: Gap.lg)),
              itemCount: days.length,
              itemBuilder: (c, i) {
                final d = days[i];
                final isToday = d['date'] == today;
                return Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: Gap.sm, horizontal: Gap.sm),
                  decoration: BoxDecoration(
                    color: isToday ? scheme.primary.withOpacity(0.10) : null,
                    border: Border(
                        bottom: BorderSide(color: scheme.outlineVariant)),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: Gap.md,
                    runSpacing: Gap.xs,
                    children: [
                      Text(
                          '${t.rmd2DayN(ld(c, i + 1))} · '
                          '${_fmtDate(c, '${d['date']}', withYear: false)}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${t.ramadanSehri} ${ld(c, d['sehri_end'] ?? '--:--')}'
                          ' · ${t.ramadanIftar} ${ld(c, d['iftar'] ?? '--:--')}'),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: withNavBarInset(ctx, const EdgeInsets.all(Gap.md)),
            child: Text(t.rmd2MethodIfb,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      );
    },
  );
}
