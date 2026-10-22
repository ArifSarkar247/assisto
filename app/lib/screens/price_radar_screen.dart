import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// MARKET PRICE RADAR — ADVANCED (#34, SPEC v2.1 §21).
///
/// A MANUAL price tracker for items the user cares about (bazar goods, building
/// materials, …). The user LOGS prices themselves — item, ৳ price, date, market
/// — and the screen computes, on-device, a TREND per item (grouped by name +
/// unit): latest price, high / low / average, and the %-change between the two
/// most recent logs.
///
/// NO FABRICATION — ONLY the user's own logged prices are ever shown. A
/// real-time market-price feed is a DOCUMENTED, key-gated SEAM only, surfaced
/// as an honest "connect a market-data key for live prices" card. We NEVER
/// invent, scrape, or guess a live quote; there is no price-feed key in the
/// Integrations registry yet.
///
/// `_RMath` mirrors backend/core/logic/price_radar.py VERBATIM (integer poisha,
/// signed %-change to 1dp). ZERO Bangla literals — every string is an
/// AppLocalizations getter; the ৳ glyph is a currency sign (gate-exempt).
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('price/logs') → [{id, item, price, date, unit?, market?, note?}]
/// create/update/deleteItem on the same path; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection. `price` is the
/// ৳ price the user saw; `unit` a stable slug (kg/litre/piece/dozen/…) so a
/// trend is only compared within one unit. No live feed, no key needed.
class PriceRadarScreen extends StatefulWidget {
  const PriceRadarScreen({super.key});
  @override
  State<PriceRadarScreen> createState() => _PriceRadarScreenState();
}

const String _logsPath = 'price/logs';
const List<String> _units = [
  'kg',
  'g',
  'litre',
  'ml',
  'piece',
  'dozen',
  'bag',
  'other',
];

String _unitLabel(AppLocalizations tr, String unit) {
  switch (unit) {
    case 'kg':
      return tr.priceUnitKg;
    case 'g':
      return tr.priceUnitG;
    case 'litre':
      return tr.priceUnitLitre;
    case 'ml':
      return tr.priceUnitMl;
    case 'piece':
      return tr.priceUnitPiece;
    case 'dozen':
      return tr.priceUnitDozen;
    case 'bag':
      return tr.priceUnitBag;
    default:
      return tr.priceUnitOther;
  }
}

class _PriceRadarScreenState extends State<PriceRadarScreen> {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _logs = await api.listItems(_logsPath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add({String? item, String? unit}) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _logSheet(context, null, presetItem: item, presetUnit: unit);
    if (res == null) return;
    try {
      await api.createItem(_logsPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _logSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_logsPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok =
        await _confirm(context, tr.priceDeleteTitle, tr.priceDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_logsPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.priceTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.priceTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.priceLoadError,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final radar = _RMath.radar(_logs);

    return Scaffold(
      appBar: AppBar(title: Text(tr.priceTitle)),
      // qa1: the empty state already has this action as its CTA
      floatingActionButton: _logs.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _add(),
              icon: const Icon(Icons.add),
              label: Text(tr.priceLogPrice),
            ),
      body: _logs.isEmpty
          ? StateMessage(
              icon: Icons.storefront_outlined,
              title: tr.priceWelcomeTitle,
              message: tr.priceWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _add(),
                icon: const Icon(Icons.add),
                label: Text(tr.priceLogPrice),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                _manualNote(context, tr),
                const SizedBox(height: Gap.md),
                ...radar.items
                    .map((i) => _itemCard(context, tr, i, _add, _edit, _delete)),
                const SizedBox(height: Gap.md),
                _feedSeamCard(context, tr),
              ],
            ),
    );
  }

  Widget _manualNote(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.priceManualNote,
                style: TextStyle(
                    fontSize: 12, height: 1.4, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }

  Widget _itemCard(BuildContext context, AppLocalizations tr, _RItem item,
      Future<void> Function({String? item, String? unit}) onAddHere,
      Future<void> Function(Map<String, dynamic>) onEdit,
      Future<void> Function(Map<String, dynamic>) onDelete) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                  '${item.item}  ·  ${_unitLabel(tr, item.unit)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            IconButton(
              tooltip: tr.priceLogPrice,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => onAddHere(item: item.item, unit: item.unit),
            ),
          ]),
          const SizedBox(height: 2),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(item.latestDisplay,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800, color: scheme.primary)),
            const SizedBox(width: Gap.sm),
            if (item.hasTrend)
              _trendPill(context, item)
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(tr.priceOneLogOnly,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: 4, children: [
            _stat(context, tr.priceStatHigh, item.highDisplay),
            _stat(context, tr.priceStatLow, item.lowDisplay),
            _stat(context, tr.priceStatAvg, item.avgDisplay),
            _stat(context, tr.priceStatLogs, item.count.toString()),
          ]),
          if (item.mixedUnits) ...[
            const SizedBox(height: Gap.sm),
            Text(tr.priceMixedUnitsWarn,
                style: TextStyle(
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                    color: scheme.error)),
          ],
          const Divider(height: Gap.lg),
          ...item.logs.map((l) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.schedule,
                    size: 18, color: scheme.onSurfaceVariant),
                title: Text(l.priceDisplay,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(_logSubtitle(tr, l)),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'edit') onEdit(l.raw);
                    if (v == 'delete') onDelete(l.raw);
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                    PopupMenuItem(value: 'delete', child: Text(tr.delete)),
                  ],
                ),
              )),
        ]),
      ),
    );
  }

  Widget _trendPill(BuildContext context, _RItem item) {
    final scheme = Theme.of(context).colorScheme;
    final up = item.up == true;
    final color = up ? scheme.error : scheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13, color: color),
          const SizedBox(width: 3),
          Text('${item.changePct.abs().toStringAsFixed(1)}%',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _feedSeamCard(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.sensors_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.priceFeedSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr.priceFeedSeamBody,
              style: TextStyle(
                  fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

String _logSubtitle(AppLocalizations tr, _RLog l) {
  final date = l.date.isEmpty ? tr.priceNoDate : l.date;
  if (l.market.isNotEmpty) {
    return tr.priceLogAtMarket(date, l.market);
  }
  return date;
}

// ---- log sheet --------------------------------------------------------------

Future<Map<String, dynamic>?> _logSheet(
    BuildContext context, Map<String, dynamic>? existing,
    {String? presetItem, String? presetUnit}) {
  final tr = AppLocalizations.of(context);
  final itemCtl = TextEditingController(
      text: (existing?['item'] ?? presetItem ?? '').toString());
  final priceCtl = TextEditingController(
      text: existing?['price'] == null ? '' : existing!['price'].toString());
  final dateCtl =
      TextEditingController(text: (existing?['date'] ?? '').toString());
  final marketCtl =
      TextEditingController(text: (existing?['market'] ?? '').toString());
  var unit = (existing?['unit'] ?? presetUnit ?? 'kg').toString();
  if (!_units.contains(unit)) unit = 'other';

  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: EdgeInsets.only(
              left: Gap.lg,
              right: Gap.lg,
              top: Gap.lg,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.priceLogPrice : tr.priceEditLog,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.md),
              TextField(
                controller: itemCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.priceFieldItem,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: priceCtl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                        labelText: tr.priceFieldPrice,
                        prefixText: '৳ ',
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: unit,
                    decoration: InputDecoration(
                        labelText: tr.priceFieldUnit,
                        border: const OutlineInputBorder()),
                    items: _units
                        .map((u) => DropdownMenuItem(
                            value: u, child: Text(_unitLabel(tr, u))))
                        .toList(),
                    onChanged: (v) => setSheet(() => unit = v ?? 'kg'),
                  ),
                ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                controller: dateCtl,
                decoration: InputDecoration(
                    labelText: tr.priceFieldDate,
                    hintText: 'YYYY-MM-DD',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.calendar_today, size: 18),
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: now,
                          firstDate: DateTime(now.year - 5),
                          lastDate: DateTime(now.year + 1),
                        );
                        if (picked != null) {
                          dateCtl.text =
                              picked.toIso8601String().substring(0, 10);
                        }
                      },
                    ),
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: marketCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.priceFieldMarket,
                    helperText: tr.priceFieldMarketHelp,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final item = itemCtl.text.trim();
                    final price = priceCtl.text.trim();
                    if (item.isEmpty || price.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    final out = <String, dynamic>{
                      'item': item,
                      'price': price,
                      'unit': unit,
                    };
                    if (dateCtl.text.trim().isNotEmpty) {
                      out['date'] = dateCtl.text.trim();
                    }
                    if (marketCtl.text.trim().isNotEmpty) {
                      out['market'] = marketCtl.text.trim();
                    }
                    Navigator.pop(ctx, out);
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}

// =============================================================================
// _RMath — VERBATIM mirror of backend/core/logic/price_radar.py.
// Integer poisha, signed %-change to 1dp. Same inputs → same output.
// =============================================================================

class _RLog {
  final Map<String, dynamic> raw;
  final int price;
  final String priceDisplay;
  final String date;
  final String market;
  _RLog(this.raw, this.price, this.priceDisplay, this.date, this.market);
}

class _RItem {
  final String item;
  final String unit;
  final int count;
  final bool hasTrend;
  final String latestDisplay;
  final double changePct;
  final bool? up;
  final String highDisplay;
  final String lowDisplay;
  final String avgDisplay;
  final bool mixedUnits;
  final List<_RLog> logs;
  _RItem(this.item, this.unit, this.count, this.hasTrend, this.latestDisplay,
      this.changePct, this.up, this.highDisplay, this.lowDisplay,
      this.avgDisplay, this.mixedUnits, this.logs);
}

class _RRadar {
  final List<_RItem> items;
  final int itemCount;
  final int logCount;
  _RRadar(this.items, this.itemCount, this.logCount);
}

class _RMath {
  static const List<String> units = _units;

  static int toMinor(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) return (v * 100).round();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.length > 1 ? parts[1] : '';
    } else {
      whole = s;
      frac = '';
    }
    whole = whole.isEmpty ? '0' : whole;
    frac = (frac + '00').substring(0, 3);
    final major = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (major == null || milli == null) return 0;
    var minor = major * 100 + milli ~/ 10;
    if (milli % 10 >= 5) minor += 1;
    return neg ? -minor : minor;
  }

  static String _group(int n) {
    var s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtBdt(int poisha) {
    final neg = poisha < 0;
    poisha = poisha.abs();
    final taka = poisha ~/ 100;
    final paisa = poisha % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  static double _pctChange(int? old, int newv) {
    if (old == null || old <= 0) return 0.0;
    return ((newv - old) * 1000.0 / old).round() / 10.0;
  }

  static String _unit(dynamic v) {
    var u = (v ?? 'other').toString().trim().toLowerCase();
    if (u.isEmpty) u = 'other';
    return units.contains(u) ? u : 'other';
  }

  static _RRadar radar(List<Map<String, dynamic>> logs) {
    // group by (name_lc, unit); track display name + units per name
    final groups = <String, List<Map<String, dynamic>>>{};
    final displayName = <String, String>{};
    final namesUnits = <String, Set<String>>{};
    for (final r in logs) {
      final nm = (r['item'] ?? '').toString().trim();
      final nmLc = nm.toLowerCase();
      if (nmLc.isEmpty) continue;
      final unit = _unit(r['unit']);
      final key = '$nmLc $unit';
      groups.putIfAbsent(key, () => []).add(r);
      displayName.putIfAbsent(key, () => nm);
      namesUnits.putIfAbsent(nmLc, () => <String>{}).add(unit);
    }

    final keys = groups.keys.toList()..sort();
    final items = <_RItem>[];
    var totalLogs = 0;
    for (final key in keys) {
      final parts = key.split(' ');
      final nmLc = parts[0];
      final unit = parts[1];
      final t = _itemTrend(groups[key]!);
      if (t == null) continue;
      totalLogs += t.count;
      items.add(_RItem(
        displayName[key]!,
        unit,
        t.count,
        t.hasTrend,
        t.latestDisplay,
        t.changePct,
        t.up,
        t.highDisplay,
        t.lowDisplay,
        t.avgDisplay,
        (namesUnits[nmLc]?.length ?? 0) > 1,
        t.logs,
      ));
    }
    return _RRadar(items, items.length, totalLogs);
  }

  static _RTrend? _itemTrend(List<Map<String, dynamic>> logs) {
    final clean = <_RLog>[];
    for (final r in logs) {
      final price = toMinor(r['price']);
      if (price <= 0) continue;
      clean.add(_RLog(r, price, fmtBdt(price),
          (r['date'] ?? '').toString(), (r['market'] ?? '').toString()));
    }
    // stable sort by date ascending (empty dates sort first)
    clean.sort((a, b) => a.date.compareTo(b.date));
    final count = clean.length;
    if (count == 0) return null;

    final prices = clean.map((c) => c.price).toList();
    final latest = clean.last;
    var high = prices.first, low = prices.first, sum = 0;
    for (final p in prices) {
      if (p > high) high = p;
      if (p < low) low = p;
      sum += p;
    }
    final avg = sum ~/ count;
    final hasTrend = count >= 2;
    final prev = hasTrend ? clean[count - 2].price : null;
    final changePct = hasTrend ? _pctChange(prev, latest.price) : 0.0;
    final change = hasTrend ? latest.price - prev! : null;

    return _RTrend(
      count,
      hasTrend,
      latest.priceDisplay,
      changePct,
      change == null ? null : change > 0,
      fmtBdt(high),
      fmtBdt(low),
      fmtBdt(avg),
      clean,
    );
  }
}

class _RTrend {
  final int count;
  final bool hasTrend;
  final String latestDisplay;
  final double changePct;
  final bool? up;
  final String highDisplay;
  final String lowDisplay;
  final String avgDisplay;
  final List<_RLog> logs;
  _RTrend(this.count, this.hasTrend, this.latestDisplay, this.changePct,
      this.up, this.highDisplay, this.lowDisplay, this.avgDisplay, this.logs);
}
