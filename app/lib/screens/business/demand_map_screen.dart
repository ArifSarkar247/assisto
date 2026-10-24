import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// DEMAND MAP — ADVANCED (#145, SPEC v2.1 §21).
///
/// A MANUAL demand tracker for a business. The user LOGS demand SIGNALS they
/// observe — product, area, period, a demand level (low/medium/high/surge),
/// and an optional note — and the screen computes, on-device, a deterministic
/// HEAT summary over the user's OWN signals: which products and which areas are
/// hot, plus a product×area grid.
///
/// NEVER FABRICATE MARKET DATA — only the user's own logged signals are ever
/// aggregated. LIVE trade/market demand data is a DOCUMENTED, key-gated SEAM
/// only, surfaced as an honest "connect a trade-data source" card. There is no
/// trade-data key in the Integrations registry yet; the heat is a sum of the
/// user's own level scores, not a claim about the real market.
///
/// `_DMath` mirrors backend/core/logic/demand_map.py. ZERO Bangla literals —
/// every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('demand/signals') → [{id, product, area, period, level, note}]
/// create/update/deleteItem on the same path; each row round-trips through one
/// flexible per-user JSON collection. `level` is one of low/medium/high/surge.
class DemandMapScreen extends StatefulWidget {
  const DemandMapScreen({super.key});
  @override
  State<DemandMapScreen> createState() => _DemandMapScreenState();
}

const String _path = 'demand/signals';
const List<String> _levels = ['low', 'medium', 'high', 'surge'];

String _levelLabel(AppLocalizations tr, String l) {
  switch (l) {
    case 'low':
      return tr.demandLevelLow;
    case 'medium':
      return tr.demandLevelMedium;
    case 'high':
      return tr.demandLevelHigh;
    default:
      return tr.demandLevelSurge;
  }
}

Color _bandColor(String band) {
  switch (band) {
    case 'low':
      return Brand.success;
    case 'medium':
      return Brand.warning;
    case 'high':
      return Brand.danger;
    default:
      return Brand.purple;
  }
}

class _DemandMapScreenState extends State<DemandMapScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  int _view = 0; // 0 product, 1 area, 2 grid

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
      _rows = await api.listItems(_path);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add({String? product, String? area}) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _signalSheet(context, null,
        presetProduct: product, presetArea: area);
    if (res == null) return;
    try {
      await api.createItem(_path, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _signalSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_path, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(context, tr.demandDeleteTitle, tr.demandDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_path, row['id'] as int);
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
        appBar: AppBar(title: Text(tr.demandTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.demandTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.demandLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final heat = _DMath.heat(_rows);

    return Scaffold(
      appBar: AppBar(title: Text(tr.demandTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(),
        icon: const Icon(Icons.add),
        label: Text(tr.demandLogSignal),
      ),
      body: _rows.isEmpty
          ? StateMessage(
              icon: Icons.insights_outlined,
              title: tr.demandWelcomeTitle,
              message: tr.demandWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _add(),
                icon: const Icon(Icons.add),
                label: Text(tr.demandLogSignal),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                _manualNote(context, tr),
                const SizedBox(height: Gap.md),
                _hottestCard(context, tr, heat),
                const SizedBox(height: Gap.md),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 0, label: Text(tr.demandViewProduct)),
                    ButtonSegment(value: 1, label: Text(tr.demandViewArea)),
                    ButtonSegment(value: 2, label: Text(tr.demandViewGrid)),
                  ],
                  selected: {_view},
                  onSelectionChanged: (s) => setState(() => _view = s.first),
                  showSelectedIcon: false,
                ),
                const SizedBox(height: Gap.md),
                ..._bucketsFor(heat).map((b) => _bucketCard(context, tr, b)),
                if (_bucketsFor(heat).isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Text(tr.demandGridNeedsBoth,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                const SizedBox(height: Gap.lg),
                _signalsList(context, tr),
                const SizedBox(height: Gap.md),
                _tradeSeamCard(context, tr),
              ],
            ),
    );
  }

  List<_DBucket> _bucketsFor(_DHeat h) {
    switch (_view) {
      case 1:
        return h.byArea;
      case 2:
        return h.grid;
      default:
        return h.byProduct;
    }
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
            child: Text(tr.demandManualNote,
                style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }

  Widget _hottestCard(BuildContext context, AppLocalizations tr, _DHeat h) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.demandHeatTitle,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: _stat(
                context,
                tr.demandHottestProduct,
                h.hottestProduct ?? '—',
                Icons.local_fire_department_outlined,
              ),
            ),
            Expanded(
              child: _stat(
                context,
                tr.demandHottestArea,
                h.hottestArea ?? '—',
                Icons.place_outlined,
              ),
            ),
          ]),
          const Divider(height: Gap.xl),
          Text(
            tr.demandSignalSummary(h.signalCount, h.productCount, h.areaCount),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, IconData ic) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(ic, size: 15, color: scheme.primary),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: Gap.xxs),
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
    ]);
  }

  Widget _bucketCard(BuildContext context, AppLocalizations tr, _DBucket b) {
    final scheme = Theme.of(context).colorScheme;
    final color = _bandColor(b.band);
    // Heat bar: avg score (1..4) mapped to a 0..1 fill.
    final fill = ((b.avg - 1.0) / 3.0).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(b.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AType.titleSmall.copyWith(fontWeight: FontWeight.w800)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(_levelLabel(tr, b.band),
                  style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: fill,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            _mini(context, tr.demandStatSignals, b.count.toString()),
            const SizedBox(width: Gap.md),
            _mini(context, tr.demandStatHeat, b.total.toString()),
            const SizedBox(width: Gap.md),
            _mini(context, tr.demandStatAvg, b.avg.toStringAsFixed(1)),
          ]),
        ]),
      ),
    );
  }

  Widget _mini(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Text('$label ',
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _signalsList(BuildContext context, AppLocalizations tr) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr.demandSignalsHeading,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: Gap.sm),
      ..._rows.map((r) {
        final sig = _DMath.normalize(r);
        final color = _bandColor(sig.level);
        return Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.16),
              child: Icon(Icons.trending_up, color: color, size: 20),
            ),
            title: Text(
                sig.product.isEmpty ? sig.area : sig.product,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(_signalSubtitle(tr, sig)),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'add') {
                  _add(product: sig.product, area: sig.area);
                }
                if (v == 'edit') _edit(r);
                if (v == 'delete') _delete(r);
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'add', child: Text(tr.demandLogSignal)),
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
            onTap: () => _edit(r),
          ),
        );
      }),
    ]);
  }

  String _signalSubtitle(AppLocalizations tr, _DSignal s) {
    final parts = <String>[_levelLabel(tr, s.level)];
    if (s.product.isNotEmpty && s.area.isNotEmpty) parts.add(s.area);
    if (s.period.isNotEmpty) parts.add(s.period);
    return parts.join('  ·  ');
  }

  Widget _tradeSeamCard(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.public_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.demandTradeSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr.demandTradeSeamBody,
              style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ---- add/edit sheet ---------------------------------------------------------

Future<Map<String, dynamic>?> _signalSheet(
    BuildContext context, Map<String, dynamic>? existing,
    {String? presetProduct, String? presetArea}) {
  final tr = AppLocalizations.of(context);
  final productCtl = TextEditingController(
      text: (existing?['product'] ?? presetProduct ?? '').toString());
  final areaCtl = TextEditingController(
      text: (existing?['area'] ?? presetArea ?? '').toString());
  final periodCtl =
      TextEditingController(text: (existing?['period'] ?? '').toString());
  final noteCtl =
      TextEditingController(text: (existing?['note'] ?? '').toString());
  var level = (existing?['level'] ?? 'medium').toString();
  if (!_levels.contains(level)) level = 'medium';

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
              Text(existing == null ? tr.demandLogSignal : tr.demandEditSignal,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.md),
              TextField(
                controller: productCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.demandFieldProduct,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: areaCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.demandFieldArea,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: periodCtl,
                decoration: InputDecoration(
                    labelText: tr.demandFieldPeriod,
                    helperText: tr.demandFieldPeriodHelp,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(tr.demandFieldLevel,
                    style: AType.bodyMedium),
              ),
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.sm,
                children: _levels.map((l) {
                  final sel = level == l;
                  final color = _bandColor(l);
                  return ChoiceChip(
                    label: Text(_levelLabel(tr, l)),
                    selected: sel,
                    selectedColor: color.withValues(alpha: 0.2),
                    onSelected: (_) => setSheet(() => level = l),
                  );
                }).toList(),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: noteCtl,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: tr.demandFieldNote,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final product = productCtl.text.trim();
                    final area = areaCtl.text.trim();
                    if (product.isEmpty && area.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    Navigator.pop(ctx, <String, dynamic>{
                      'product': product,
                      'area': area,
                      'period': periodCtl.text.trim(),
                      'level': level,
                      'note': noteCtl.text.trim(),
                    });
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
// _DMath — VERBATIM mirror of backend/core/logic/demand_map.py.
// Deterministic heat aggregation over the user's OWN signals. No market data.
// =============================================================================

const Map<String, int> _levelScore = {
  'low': 1,
  'medium': 2,
  'high': 3,
  'surge': 4,
};

class _DSignal {
  final Object? id;
  final String product;
  final String area;
  final String period;
  final String level;
  final int score;
  final String note;
  final Map<String, dynamic> raw;
  _DSignal(this.id, this.product, this.area, this.period, this.level,
      this.score, this.note, this.raw);
}

class _DBucket {
  final String key;
  final String label;
  final int count;
  final int total;
  final double avg;
  final String band;
  final String topLevel;
  _DBucket(this.key, this.label, this.count, this.total, this.avg, this.band,
      this.topLevel);
}

class _DHeat {
  final List<_DBucket> byProduct;
  final List<_DBucket> byArea;
  final List<_DBucket> grid;
  final String? hottestProduct;
  final String? hottestArea;
  final int signalCount;
  final int productCount;
  final int areaCount;
  _DHeat(this.byProduct, this.byArea, this.grid, this.hottestProduct,
      this.hottestArea, this.signalCount, this.productCount, this.areaCount);
}

class _DMath {
  static String _clean(dynamic v) => (v ?? '')
      .toString()
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .join(' ')
      .trim();

  static String _level(dynamic v) {
    final s = _clean(v).toLowerCase();
    return _levels.contains(s) ? s : 'medium';
  }

  static int _score(String level) => _levelScore[level] ?? 2;

  static String _band(double avg) {
    if (avg < 1.5) return 'low';
    if (avg < 2.5) return 'medium';
    if (avg < 3.5) return 'high';
    return 'surge';
  }

  static _DSignal normalize(Map<String, dynamic> row) {
    final level = _level(row['level']);
    return _DSignal(
      row['id'],
      _clean(row['product']),
      _clean(row['area']),
      _clean(row['period']),
      level,
      _score(level),
      _clean(row['note']),
      row,
    );
  }

  static List<_DBucket> _bucketize(
      List<_DSignal> items,
      String Function(_DSignal) keyfn,
      String Function(_DSignal) labelfn) {
    final groups = <String, List<_DSignal>>{};
    final labels = <String, String>{};
    for (final s in items) {
      final k = keyfn(s);
      if (k.isEmpty) continue;
      groups.putIfAbsent(k, () => []).add(s);
      labels.putIfAbsent(k, () => labelfn(s));
    }
    final out = <_DBucket>[];
    groups.forEach((k, sigs) {
      var total = 0;
      for (final s in sigs) {
        total += s.score;
      }
      final count = sigs.length;
      final avg = (total * 10.0 / count).round() / 10.0;
      var top = sigs.first;
      for (final s in sigs) {
        if (s.score > top.score) top = s;
      }
      out.add(_DBucket(k, labels[k]!, count, total, avg, _band(avg), top.level));
    });
    out.sort((a, b) {
      final t = b.total.compareTo(a.total);
      if (t != 0) return t;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return out;
  }

  static _DHeat heat(List<Map<String, dynamic>> rows) {
    final items = <_DSignal>[];
    for (final r in rows) {
      if (_clean(r['product']).isEmpty && _clean(r['area']).isEmpty) continue;
      items.add(normalize(r));
    }
    final byProduct = _bucketize(
        items, (s) => s.product.toLowerCase(), (s) => s.product);
    final byArea =
        _bucketize(items, (s) => s.area.toLowerCase(), (s) => s.area);
    final grid = _bucketize(items, (s) {
      final p = s.product.toLowerCase();
      final a = s.area.toLowerCase();
      if (p.isEmpty || a.isEmpty) return '';
      return '$p␟$a';
    }, (s) => '${s.product}  ·  ${s.area}');

    return _DHeat(
      byProduct,
      byArea,
      grid,
      byProduct.isNotEmpty ? byProduct.first.label : null,
      byArea.isNotEmpty ? byArea.first.label : null,
      items.length,
      byProduct.length,
      byArea.length,
    );
  }
}
