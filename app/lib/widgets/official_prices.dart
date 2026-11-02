import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'bn_day_periods.dart' show appDateLocale;
import 'money_digits.dart';
import 'tax_widgets.dart' show openExternal;

/// moneybar: TCB (Trading Corporation of Bangladesh, government) official
/// daily retail prices for Dhaka — served by GET /prices/official
/// (backend core/tcb_prices.py, fetched once a day from tcb.gov.bd).
///
/// HONESTY: we show exactly what TCB published (min–max range, its date, the
/// markets it surveyed). connected=false -> "not fetched yet" + a button to
/// TCB's own page; stale=true -> "TCB has not published since <date>". A
/// price TCB did not publish is never shown (the server drops it).
const String tcbPricesUrl = 'https://tcb.gov.bd/pages/daily-rmps';

extension OfficialPricesApi on ApiClient {
  Future<Map<String, dynamic>> officialPrices() => getJson('/prices/official');
}

class OfficialItem {
  final String name, unit, group;
  final num min, max;
  final num? weekMin, weekMax, monthMin, monthMax;
  const OfficialItem(this.name, this.unit, this.group, this.min, this.max,
      this.weekMin, this.weekMax, this.monthMin, this.monthMax);

  static num? _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

  static OfficialItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lo = _n(raw['min']), hi = _n(raw['max']);
    final name = '${raw['name'] ?? ''}'.trim();
    if (lo == null || hi == null || name.isEmpty) return null;
    return OfficialItem(name, '${raw['unit'] ?? ''}'.trim(),
        '${raw['group'] ?? ''}'.trim(), lo, hi, _n(raw['week_min']),
        _n(raw['week_max']), _n(raw['month_min']), _n(raw['month_max']));
  }

  /// Mid-point change vs one week ago in % (null when TCB gave no week price).
  double? get weekChangePct {
    if (weekMin == null || weekMax == null) return null;
    final before = (weekMin! + weekMax!) / 2;
    if (before <= 0) return null;
    return ((min + max) / 2 - before) / before * 100;
  }
}

class OfficialPrices {
  final bool connected, stale;
  final String? date;
  final String markets;
  final List<OfficialItem> items;
  const OfficialPrices(
      this.connected, this.stale, this.date, this.markets, this.items);

  static OfficialPrices fromJson(Map<String, dynamic> j) => OfficialPrices(
        j['connected'] == true,
        j['stale'] == true,
        j['date'] as String?,
        '${j['markets'] ?? ''}',
        [
          for (final r in (j['items'] as List? ?? const []))
            if (OfficialItem.fromJson(r) != null) OfficialItem.fromJson(r)!
        ],
      );

  /// Best official match for an item the user typed ("rice", "onion"): an
  /// official name that contains the user's word (case-insensitive) — first
  /// in TCB's order. Null when nothing matches; we never guess further.
  OfficialItem? match(String userItem) {
    final q = userItem.trim().toLowerCase();
    if (q.length < 2) return null;
    for (final it in items) {
      if (it.name.toLowerCase().contains(q)) return it;
    }
    return null;
  }
}

String _taka(num v) => moneyDigits(
    '৳${NumberFormat('#,##,###.##', 'en').format(v)}');

String officialRange(OfficialItem it) =>
    it.min == it.max ? _taka(it.min) : '${_taka(it.min)}–${_taka(it.max)}';

String officialDate(BuildContext context, String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return iso ?? '';
  return moneyDigits(DateFormat.yMMMd(appDateLocale(context)).format(d));
}

/// "TCB (Dhaka, 1 Nov): ৳70–90 / kg" under the user's own item card.
String mbOfficialLine(BuildContext context, OfficialItem o) =>
    AppLocalizations.of(context)
        .mbTcbMatchLine(officialRange(o), o.unit, o.name);

/// The card on the price radar. [data] null = could not load (offline / old
/// server) — the card then only offers TCB's page, honestly.
class OfficialPricesCard extends StatelessWidget {
  const OfficialPricesCard({super.key, required this.data});
  final OfficialPrices? data;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = data;
    final connected = d != null && d.connected && d.items.isNotEmpty;
    return Card(
      key: const ValueKey('mb-official-card'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.verified_rounded, size: 20, color: scheme.onSecondaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.mbTcbTitle,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSecondaryContainer)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            connected
                ? (d.stale
                    ? t.mbTcbStale(officialDate(context, d.date))
                    : t.mbTcbFresh(officialDate(context, d.date),
                        moneyDigits('${d.items.length}')))
                : t.mbTcbNotConnected,
            style: AType.bodySmall.copyWith(
                height: 1.4, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (connected)
              FilledButton.icon(
                key: const ValueKey('mb-official-open-list'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => OfficialPricesScreen(data: d))),
                icon: const Icon(Icons.list_alt_rounded),
                label: Text(t.mbTcbSeeAll),
              ),
            OutlinedButton.icon(
              key: const ValueKey('mb-official-open-site'),
              // contrast: on secondaryContainer use its own "on" colour
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: scheme.onSecondaryContainer,
                  side: BorderSide(color: scheme.onSecondaryContainer)),
              onPressed: () => openExternal(context, tcbPricesUrl, t.taxLinkCopied),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(t.mbTcbOpenSite),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Full official list: search + groups, each row min–max and week change.
class OfficialPricesScreen extends StatefulWidget {
  const OfficialPricesScreen({super.key, required this.data});
  final OfficialPrices data;
  @override
  State<OfficialPricesScreen> createState() => _OfficialPricesScreenState();
}

class _OfficialPricesScreenState extends State<OfficialPricesScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    syncMoneyDigits(context);
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = widget.data;
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final it in d.items)
        if (q.isEmpty ||
            it.name.toLowerCase().contains(q) ||
            it.group.toLowerCase().contains(q))
          it
    ];
    final rows = <Widget>[];
    String? lastGroup;
    for (final it in shown) {
      if (it.group.isNotEmpty && it.group != lastGroup) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(0, Gap.md, 0, Gap.xs),
          child: Text(it.group,
              style: AType.labelSmall.copyWith(
                  fontWeight: FontWeight.w800, color: scheme.primary)),
        ));
      }
      lastGroup = it.group;
      final ch = it.weekChangePct;
      // 200% text: a Wrap, not a ListTile trailing (that overflowed)
      rows.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xxs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xxs,
                crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(officialRange(it),
                  style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
              Text(it.unit, style: TextStyle(color: scheme.onSurfaceVariant)),
              if (ch != null && ch.abs() >= 0.05)
                Text(
                    ch > 0
                        ? t.mbTcbWeekUp(moneyDigits(ch.abs().toStringAsFixed(1)))
                        : t.mbTcbWeekDown(moneyDigits(ch.abs().toStringAsFixed(1))),
                    style: TextStyle(
                        color: ch > 0 ? scheme.error : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700)),
            ]),
          ]),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.mbTcbTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
          children: [
            Text(t.mbTcbSourceLine(officialDate(context, d.date)),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            if (d.markets.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(t.mbTcbMarkets(d.markets),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('mb-official-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                labelText: t.mbTcbSearch,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: Gap.sm),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Text(t.mbTcbNoMatch,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ...rows,
          ],
        ),
      ),
    );
  }
}
