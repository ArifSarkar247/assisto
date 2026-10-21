import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart';
import '../widgets/skeleton.dart';

/// COST / TIME ESTIMATOR (#36, SPEC v2.1 §8, ADVANCED).
///
/// Estimate the cost + time for a task or project: add COMPONENTS (items/steps),
/// each with a quantity, a unit cost (৳) and a duration (minutes); the tool
/// computes per-line subtotals, a project TOTAL cost + TOTAL time, an optional
/// CONTINGENCY buffer, and a rough ±15% planning band. Projects save + reopen.
///
/// The on-screen math MIRRORS backend/core/logic/cost_estimator.py VERBATIM —
/// all MONEY is INTEGER POISHA (no float drift) and the ৳ glyph (U+09F3, a
/// currency sign, gate-exempt) formats taka. The app HOLDS NO MONEY; it plans.
///
/// NEVER FINANCIAL ADVICE — it arithmetic-adds exactly what you enter; it
/// invents no prices. The optional "AI estimate" for an UNKNOWN component is
/// the key-gated seam: a deterministic rough band (from your known lines) with
/// an honest "owner can connect an AI key for a smarter estimate" state. See
/// up_contractcost_integration.md.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('estimate/projects') → [{id, name, components, contingency_pct,
///                                        saved_at}]
///     components is a JSON list of {name, qty, unit_cost, minutes}.
/// create/update/deleteItem on the same path; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
///
/// ZERO Bangla literals — every string is an AppLocalizations getter; ৳ is a
/// currency glyph (not a Bangla letter). No U+0980–U+09FF appears in this file.
class CostEstimatorScreen extends StatefulWidget {
  const CostEstimatorScreen({super.key});
  @override
  State<CostEstimatorScreen> createState() => _CostEstimatorScreenState();
}

const String _projectsPath = 'estimate/projects';
const int _maxComponents = 200;

// ------------------------------------------------------- engine mirror
// Integer-poisha math mirroring cost_estimator.py. Blanks → 0, deterministic.

int _toPoisha(String? taka) {
  final s = (taka ?? '').replaceAll(',', '').trim();
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return 0;
  return (v * 100).round();
}

String _takaStr(int poisha) {
  if (poisha < 0) poisha = 0;
  final whole = poisha ~/ 100;
  final frac = poisha % 100;
  final digits = whole.toString();
  final buf = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '৳$buf.${frac.toString().padLeft(2, '0')}';
}

int _toInt(String? value) {
  final s = (value ?? '').replaceAll(',', '').trim();
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return 0;
  return v.toInt();
}

class _Line {
  final String name;
  final int qty;
  final int unitPoisha;
  final int minutesEach;
  const _Line(this.name, this.qty, this.unitPoisha, this.minutesEach);
  int get costPoisha => qty * unitPoisha;
  int get timeMinutes => qty * minutesEach;
}

class _Estimate {
  final List<_Line> lines;
  final int subtotalPoisha;
  final int contingencyPct;
  final int contingencyPoisha;
  final int totalPoisha;
  final int totalMinutes;
  final int lowPoisha;
  final int highPoisha;
  const _Estimate(
      this.lines,
      this.subtotalPoisha,
      this.contingencyPct,
      this.contingencyPoisha,
      this.totalPoisha,
      this.totalMinutes,
      this.lowPoisha,
      this.highPoisha);
}

_Estimate _estimate(List<_Line> lines, int contingencyPct) {
  final capped = lines.take(_maxComponents).toList();
  final subtotal = capped.fold<int>(0, (s, l) => s + l.costPoisha);
  final totalMinutes = capped.fold<int>(0, (s, l) => s + l.timeMinutes);
  final cp = contingencyPct.clamp(0, 100);
  final contingency = (subtotal * cp) ~/ 100;
  final total = subtotal + contingency;
  final low = (total * 85) ~/ 100;
  final high = (total * 115 + 99) ~/ 100;
  return _Estimate(
      capped, subtotal, cp, contingency, total, totalMinutes, low, high);
}

class _CostEstimatorScreenState extends State<CostEstimatorScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _name = TextEditingController();

  final List<_Row> _rows = [];
  int _contingency = 0;
  int? _editingId;

  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _addRow();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRow([Map<String, dynamic>? seed]) {
    setState(() => _rows.add(_Row(seed)));
  }

  void _removeRow(_Row r) {
    setState(() {
      _rows.remove(r);
      r.dispose();
    });
  }

  List<_Line> get _lines => _rows
      .map((r) => _Line(r.name.text.trim(), _toInt(r.qty.text),
          _toPoisha(r.unit.text), _toInt(r.minutes.text)))
      .toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final list = await context.read<AppState>().api.listItems(_projectsPath);
      if (!mounted) return;
      setState(() {
        _saved = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  bool get _hasAnyData =>
      _rows.any((r) => r.name.text.trim().isNotEmpty || r.qty.text.trim().isNotEmpty);

  Future<void> _saveProject() async {
    if (!_hasAnyData) {
      _toast(t.ceErrEmpty);
      return;
    }
    final comps = _rows
        .map((r) => {
              'name': r.name.text.trim(),
              'qty': r.qty.text.trim(),
              'unit_cost': r.unit.text.trim(),
              'minutes': r.minutes.text.trim(),
            })
        .toList();
    final row = {
      'name': _name.text.trim().isEmpty ? t.ceUntitled : _name.text.trim(),
      'components': comps,
      'contingency_pct': _contingency,
      'saved_at': DateTime.now().toIso8601String(),
    };
    try {
      final api = context.read<AppState>().api;
      if (_editingId != null) {
        await api.updateItem(_projectsPath, _editingId!, row);
      } else {
        await api.createItem(_projectsPath, row);
      }
      await _load();
      if (!mounted) return;
      _toast(t.ceSaved);
    } catch (_) {
      _toast(t.ceErrSave);
    }
  }

  void _openSaved(Map<String, dynamic> row) {
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();
    final comps = (row['components'] as List?) ?? [];
    for (final c in comps) {
      _rows.add(_Row(c as Map<String, dynamic>));
    }
    if (_rows.isEmpty) _rows.add(_Row());
    setState(() {
      _editingId = row['id'] as int?;
      _name.text = (row['name'] ?? '').toString();
      _contingency = _toInt(row['contingency_pct']?.toString());
    });
    _tabs.animateTo(0);
  }

  Future<void> _deleteSaved(Map<String, dynamic> row) async {
    final id = row['id'] as int?;
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem(_projectsPath, id);
      if (_editingId == id) _editingId = null;
      await _load();
      if (!mounted) return;
      _toast(t.ceDeleted);
    } catch (_) {
      _toast(t.ceErrSave);
    }
  }

  Future<void> _copyTotals(_Estimate e) async {
    final txt = [
      '${t.ceTotalCost}: ${_takaStr(e.totalPoisha)}',
      '${t.ceTotalTime}: ${_durationText(e.totalMinutes)}',
      '${t.ceBand}: ${_takaStr(e.lowPoisha)} – ${_takaStr(e.highPoisha)}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: txt));
    if (!mounted) return;
    _toast(t.ceCopied);
  }

  String _durationText(int minutes) {
    final days = minutes ~/ (24 * 60);
    final rem = minutes % (24 * 60);
    final hours = rem ~/ 60;
    final mins = rem % 60;
    final parts = <String>[];
    if (days > 0) parts.add(t.ceDays(fmtInt(context, days)));
    if (hours > 0) parts.add(t.ceHours(fmtInt(context, hours)));
    if (mins > 0 || parts.isEmpty) parts.add(t.ceMinutes(fmtInt(context, mins)));
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.ceTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
                child: Text(t.ceTabEstimate,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.ceTabSaved,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_estimateTab(), _savedTab()],
      ),
    );
  }

  // ------------------------------------------------------- estimate tab

  Widget _estimateTab() {
    final e = _estimate(_lines, _contingency);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        const _HonestMarker(),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _name,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: t.ceNameLabel,
            hintText: t.ceNameHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.ceComponents,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: Gap.sm),
        ..._rows.asMap().entries.map((entry) => _ComponentCard(
              key: ValueKey(entry.value),
              row: entry.value,
              index: entry.key + 1,
              canRemove: _rows.length > 1,
              onChanged: () => setState(() {}),
              onRemove: () => _removeRow(entry.value),
            )),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          onPressed: _rows.length >= _maxComponents ? null : () => _addRow(),
          icon: const Icon(Icons.add, size: 18),
          label: Text(t.ceAddComponent),
        ),
        const SizedBox(height: Gap.lg),

        // contingency slider
        Text(t.ceContingency(fmtInt(context, _contingency)),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        Slider(
          value: _contingency.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          label: '${fmtInt(context, _contingency)}%',
          onChanged: (v) => setState(() => _contingency = v.round()),
        ),
        const SizedBox(height: Gap.sm),

        // totals
        _TotalsCard(
          totalCost: _takaStr(e.totalPoisha),
          subtotal: _takaStr(e.subtotalPoisha),
          contingency: _takaStr(e.contingencyPoisha),
          contingencyPct: e.contingencyPct,
          totalTime: _durationText(e.totalMinutes),
          band: '${_takaStr(e.lowPoisha)} – ${_takaStr(e.highPoisha)}',
          onCopy: () => _copyTotals(e),
          onSave: _saveProject,
        ),
        const SizedBox(height: Gap.lg),
        const _AiEstimateCard(),
        const SizedBox(height: Gap.lg),
        _DisclaimerCard(text: t.ceDisclaimer),
      ],
    );
  }

  // ------------------------------------------------------- saved tab

  Widget _savedTab() {
    if (_loading) return const SkeletonList(count: 4);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: Brand.danger,
        title: t.ceLoadError,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_saved.isEmpty) {
      return StateMessage(
        icon: Icons.calculate_outlined,
        title: t.ceEmptyTitle,
        message: t.ceEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.add, size: 18),
          label: Text(t.ceTabEstimate),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _saved.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          final row = _saved[i];
          final comps = (row['components'] as List?) ?? [];
          final lines = comps
              .map((c) => _Line(
                  (c['name'] ?? '').toString(),
                  _toInt(c['qty']?.toString()),
                  _toPoisha(c['unit_cost']?.toString()),
                  _toInt(c['minutes']?.toString())))
              .toList();
          final e =
              _estimate(lines, _toInt(row['contingency_pct']?.toString()));
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              title: Text((row['name'] ?? t.ceUntitled).toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '${_takaStr(e.totalPoisha)} · ${t.ceComponentsCount(fmtInt(context, lines.length))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              onTap: () => _openSaved(row),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: t.delete,
                onPressed: () => _deleteSaved(row),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------- row model

class _Row {
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController unit;
  final TextEditingController minutes;
  _Row([Map<String, dynamic>? seed])
      : name = TextEditingController(text: (seed?['name'] ?? '').toString()),
        qty = TextEditingController(text: (seed?['qty'] ?? '').toString()),
        unit = TextEditingController(
            text: (seed?['unit_cost'] ?? '').toString()),
        minutes =
            TextEditingController(text: (seed?['minutes'] ?? '').toString());
  void dispose() {
    name.dispose();
    qty.dispose();
    unit.dispose();
    minutes.dispose();
  }
}

// ------------------------------------------------------- widgets

class _ComponentCard extends StatelessWidget {
  final _Row row;
  final int index;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _ComponentCard({
    super.key,
    required this.row,
    required this.index,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(t.ceComponentN(fmtInt(context, index)),
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant)),
          ),
          if (canRemove)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              tooltip: t.delete,
              onPressed: onRemove,
            ),
        ]),
        TextField(
          controller: row.name,
          onChanged: (_) => onChanged(),
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            isDense: true,
            labelText: t.ceItemName,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.sm),
        // Labels like "Unit cost" (and the bn label) were cut to 1 letter in three
        // ~95px columns: lay out by the space each label really needs.
        LayoutBuilder(builder: (context, c) {
          final need = 120 * MediaQuery.textScalerOf(context).scale(1);
          final qtyF = TextField(
            controller: row.qty,
            keyboardType: TextInputType.number,
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              isDense: true,
              labelText: t.ceQty,
              border: const OutlineInputBorder(),
            ),
          );
          final unitF = TextField(
            controller: row.unit,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              isDense: true,
              labelText: t.ceUnitCost,
              prefixText: '৳ ',
              border: const OutlineInputBorder(),
            ),
          );
          final minF = TextField(
            controller: row.minutes,
            keyboardType: TextInputType.number,
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              isDense: true,
              labelText: t.ceMinEach,
              border: const OutlineInputBorder(),
            ),
          );
          if (c.maxWidth >= need * 3 + 2 * Gap.sm) {
            return Row(children: [
              Expanded(child: qtyF),
              const SizedBox(width: Gap.sm),
              Expanded(child: unitF),
              const SizedBox(width: Gap.sm),
              Expanded(child: minF),
            ]);
          }
          if (c.maxWidth >= need * 2 + Gap.sm) {
            return Column(children: [
              Row(children: [
                Expanded(child: qtyF),
                const SizedBox(width: Gap.sm),
                Expanded(child: minF),
              ]),
              const SizedBox(height: Gap.sm),
              unitF,
            ]);
          }
          return Column(children: [
            qtyF,
            const SizedBox(height: Gap.sm),
            unitF,
            const SizedBox(height: Gap.sm),
            minF,
          ]);
        }),
      ]),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final String totalCost, subtotal, contingency, totalTime, band;
  final int contingencyPct;
  final VoidCallback onCopy, onSave;
  const _TotalsCard({
    required this.totalCost,
    required this.subtotal,
    required this.contingency,
    required this.contingencyPct,
    required this.totalTime,
    required this.band,
    required this.onCopy,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget line(String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
                      fontSize: strong ? 15 : 13)),
            ),
            Text(value,
                style: TextStyle(
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                    fontSize: strong ? 16 : 13.5,
                    color: strong ? scheme.primary : null)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          Brand.blue.withValues(alpha: 0.08),
          Brand.purple.withValues(alpha: 0.08),
        ]),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        line(t.ceSubtotal, subtotal),
        if (contingencyPct > 0) line(t.ceContingencyLine(fmtInt(context, contingencyPct)), contingency),
        const Divider(height: Gap.lg),
        line(t.ceTotalCost, totalCost, strong: true),
        const SizedBox(height: 2),
        line(t.ceTotalTime, totalTime),
        line(t.ceBand, band),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.bookmark_outline, size: 18),
              label: Text(t.save),
            ),
          ),
          const SizedBox(width: Gap.sm),
          OutlinedButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(t.copy),
          ),
        ]),
      ]),
    );
  }
}

class _HonestMarker extends StatelessWidget {
  const _HonestMarker();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.ceMarker,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    height: 1.4)),
            const SizedBox(height: 2),
            Text(t.ceMarkerSub,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontSize: 12,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _AiEstimateCard extends StatelessWidget {
  const _AiEstimateCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.ceAiTitle,
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 2),
            Text(t.ceAiBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _DisclaimerCard extends StatelessWidget {
  final String text;
  const _DisclaimerCard({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.4))),
      ]),
    );
  }
}
