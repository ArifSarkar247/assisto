import '../ads/ad_placements.dart' show AdExit, AdExitPlacement;
import '../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart';
import '../widgets/local_digits.dart'; // lifebar
import '../widgets/confirm_delete.dart'; // lifebar
import '../widgets/app_sheet.dart' show withNavBarInset, showAppSheet; // lifebar
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show serverFailText; // qa2

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

String _takaStrRaw(int poisha) {
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

/// lifebar: quantities may be decimal (2.5 kg, 1.5 days) — never truncated.
double _toQty(String? value) {
  final s = (value ?? '').replaceAll(',', '').trim();
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return 0;
  return v;
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
  final double qty;
  final int unitPoisha;
  final int minutesEach;
  const _Line(this.name, this.qty, this.unitPoisha, this.minutesEach);
  int get costPoisha => (qty * unitPoisha).round();
  int get timeMinutes => (qty * minutesEach).round();
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
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _addRow();
    _load();
  }

  @override
  void dispose() {
    // OWNER ADS FINAL: leaving after a finished task -> exit placement
    AdExit.maybeShow(AdExitPlacement.estimateAfterFinish);
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
      .map((r) => _Line(r.name.text.trim(), _toQty(r.qty.text),
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _failCause = e;
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
              // p2plan: where the rate came from survives a save / reopen
              if (r.src != null) 'rate_src': r.src,
              if (r.ownerUnit != null) 'owner_unit': r.ownerUnit,
              if (r.unitLabel.isNotEmpty) 'unit': r.unitLabel,
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
        // lifebar: keep editing the SAME project (Save twice = one row)
        final created = await api.createItem(_projectsPath, row);
        final nid = created['id'];
        if (nid is int) _editingId = nid;
        if (nid is String) _editingId = int.tryParse(nid);
      }
      AdExit.taskDone(AdExitPlacement.estimateAfterFinish);
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
    if (!await confirmDelete(context, what: '${row['name'] ?? ''}')) return;
    if (!mounted) return;
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
      '${t.ceTotalCost}: ${_taka(e.totalPoisha)}',
      '${t.ceTotalTime}: ${_durationText(e.totalMinutes)}',
      '${t.ceBand}: ${_taka(e.lowPoisha)} – ${_taka(e.highPoisha)}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: txt));
    if (!mounted) return;
    _toast(t.ceCopied);
  }

  void _newEstimate() {
    for (final r in _rows) {
      r.dispose();
    }
    setState(() {
      _rows
        ..clear()
        ..add(_Row());
      _name.clear();
      _contingency = 0;
      _editingId = null;
    });
    _tabs.animateTo(0);
  }

  // ------------------------------------------------- p2plan: templates
  /// Ready templates for common BD jobs. Quantities come from the user's
  /// answers; rates are the OWNER's (with source + date) or empty — never a
  /// made-up market price.
  Future<void> _pickTemplate() async {
    List<Map<String, dynamic>> templates;
    try {
      final r = await context.read<AppState>().api.getJson('/estimate/templates');
      templates = (r['templates'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      if (mounted) _toast(t.p2CeTemplatesFailed);
      return;
    }
    if (!mounted || templates.isEmpty) return;
    final picked = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: withNavBarInset(ctx, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        children: [
          Text(t.p2CeTemplates,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          for (final tpl in templates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_tplIcon('${tpl['id']}')),
              title: Text('${tpl['title'] ?? ''}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(ctx, tpl),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final answers = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TemplateQuestions(template: picked),
    );
    if (answers == null || !mounted) return;
    Map<String, dynamic> res;
    try {
      res = await context
          .read<AppState>()
          .api
          .postJson('/estimate/templates/${picked['id']}', {'inputs': answers});
    } catch (_) {
      if (mounted) _toast(t.p2CeTemplatesFailed);
      return;
    }
    if (!mounted) return;
    if (_hasAnyData && !await _confirmReplace()) return;
    final lines = (res['lines'] as List? ?? const []).whereType<Map>().toList();
    for (final r in _rows) {
      r.dispose();
    }
    setState(() {
      _rows.clear();
      for (final l in lines) {
        final cost = l['unit_cost'];
        _rows.add(_Row({
          'name': l['name'],
          'qty': '${l['qty'] ?? ''}',
          'unit_cost': cost == null ? '' : _num(cost),
          'minutes': l['minutes'] == null ? '' : '${l['minutes']}',
          'rate_src': l['rate_src'],
          'owner_unit': cost == null ? null : _num(cost),
          'unit': l['unit'],
        }));
      }
      if (_rows.isEmpty) _rows.add(_Row());
      _name.text = '${res['title'] ?? ''}';
      _editingId = null;
    });
    final note = '${res['note'] ?? ''}';
    if (note.isNotEmpty) _toast(note);
  }

  String _num(Object v) {
    final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  IconData _tplIcon(String id) => const {
        'home': Icons.home_repair_service_rounded,
        'event': Icons.celebration_rounded,
        'travel': Icons.luggage_rounded,
        'business': Icons.storefront_rounded,
        'tutor': Icons.school_rounded,
      }[id] ??
      Icons.calculate_rounded;

  Future<bool> _confirmReplace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.p2CeReplaceQ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.p2CeReplace)),
        ],
      ),
    );
    return ok == true;
  }

  /// lifebar: money in the app language's digits (was always Latin).
  String _taka(int poisha) => ld(context, _takaStrRaw(poisha));

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
        // lifebar: Save now keeps editing the same project, so starting a
        // fresh estimate is an explicit action
        actions: [
          IconButton(
            tooltip: t.p2CeTemplates,
            icon: const Icon(Icons.dashboard_customize_rounded),
            onPressed: _pickTemplate,
          ),
          IconButton(
            tooltip: t.lifebarCeNew,
            icon: const Icon(Icons.note_add_rounded),
            onPressed: _newEstimate,
          ),
        ],
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
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl)),
      children: [
        const _HonestMarker(),
        const SizedBox(height: Gap.lg),
        if (!_hasAnyData) ...[
          // p2plan: most people don't know the lines a job needs — start
          // from a BD job template (home repair, event, trip, shop, tutor)
          SizedBox(
            height: 52,
            child: FilledButton.tonalIcon(
              onPressed: _pickTemplate,
              icon: const Icon(Icons.dashboard_customize_rounded),
              label: Text(t.p2CeStartFromTemplate, textAlign: TextAlign.center),
            ),
          ),
          const SizedBox(height: Gap.lg),
        ],
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
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
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
          icon: const Icon(Icons.add_rounded, size: 18),
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
          totalCost: _taka(e.totalPoisha),
          subtotal: _taka(e.subtotalPoisha),
          contingency: _taka(e.contingencyPoisha),
          contingencyPct: e.contingencyPct,
          totalTime: _durationText(e.totalMinutes),
          band: '${_taka(e.lowPoisha)} – ${_taka(e.highPoisha)}',
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
        icon: Icons.cloud_off_rounded,
        tint: Brand.danger,
        title: t.ceLoadError,
        message: serverFailText(t, _failCause),
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_saved.isEmpty) {
      return StateMessage(
        icon: Icons.calculate_rounded,
        title: t.ceEmptyTitle,
        message: t.ceEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(t.ceTabEstimate),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        itemCount: _saved.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          final row = _saved[i];
          final comps = (row['components'] as List?) ?? [];
          final lines = comps
              .map((c) => _Line(
                  (c['name'] ?? '').toString(),
                  _toQty(c['qty']?.toString()),
                  _toPoisha(c['unit_cost']?.toString()),
                  _toInt(c['minutes']?.toString())))
              .toList();
          final e =
              _estimate(lines, _toInt(row['contingency_pct']?.toString()));
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              title: Text((row['name'] ?? t.ceUntitled).toString(),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '${_taka(e.totalPoisha)} · ${t.ceComponentsCount(fmtInt(context, lines.length))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              onTap: () => _openSaved(row),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
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
  // p2plan: template rows remember where their rate came from
  final Map<String, dynamic>? src; // {kind: owner|none, source, date}
  final String? ownerUnit; // the owner's rate as first filled in
  final String unitLabel; // 'sq ft', 'plates' …
  _Row([Map<String, dynamic>? seed])
      : src = seed?['rate_src'] is Map
            ? Map<String, dynamic>.from(seed!['rate_src'] as Map)
            : null,
        ownerUnit = seed?['owner_unit']?.toString(),
        unitLabel = (seed?['unit'] ?? '').toString(),
        name = TextEditingController(text: (seed?['name'] ?? '').toString()),
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
                style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          if (canRemove)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18),
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
        if (row.src != null) _rateSource(context, t, scheme),
      ]),
    );
  }

  /// p2plan: every template line says where its rate came from.
  Widget _rateSource(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final src = row.src!;
    final typed = row.unit.text.trim();
    String text;
    Color color = scheme.onSurfaceVariant;
    IconData icon = Icons.person_outline_rounded;
    if (src['kind'] == 'owner' && row.ownerUnit != null && typed == row.ownerUnit) {
      text = t.p2CeRateOwner('${src['source'] ?? ''}', ld(context, '${src['date'] ?? ''}'));
      icon = Icons.verified_outlined;
    } else if (typed.isEmpty) {
      text = t.p2CeRateNone;
      color = Brand.warning;
      icon = Icons.edit_note_rounded;
    } else {
      text = t.p2CeRateUser;
    }
    final unit = row.unitLabel.isEmpty ? '' : ' · ${row.unitLabel}';
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: Gap.xs),
        Expanded(
            child: Text('$text$unit',
                style: AType.bodySmall.copyWith(color: color, height: 1.35))),
      ]),
    );
  }
}

/// p2plan: the template's questions (sq ft, guests, nights …) — numbers only.
class _TemplateQuestions extends StatefulWidget {
  final Map<String, dynamic> template;
  const _TemplateQuestions({required this.template});
  @override
  State<_TemplateQuestions> createState() => _TemplateQuestionsState();
}

class _TemplateQuestionsState extends State<_TemplateQuestions> {
  late final List<Map<String, dynamic>> _qs = (widget.template['questions'] as List? ?? const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
  late final Map<String, TextEditingController> _c = {
    for (final q in _qs)
      '${q['key']}': TextEditingController(
          text: (q['default'] ?? 0) == 0 ? '' : '${q['default']}'),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: withNavBarInset(
          context,
          EdgeInsets.fromLTRB(
              Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('${widget.template['title'] ?? ''}',
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.p2CeTemplateAnswers),
        const SizedBox(height: Gap.md),
        for (final q in _qs) ...[
          TextField(
            controller: _c['${q['key']}'],
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '${q['label'] ?? ''}',
              suffixText: '${q['unit'] ?? ''}',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
        ],
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, {
            for (final e in _c.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0,
          }),
          icon: const Icon(Icons.calculate_rounded),
          label: Text(t.p2CeBuild),
        ),
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
                  style: (strong ? AType.titleMedium : AType.bodyMedium).copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
            ),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: (strong ? AType.titleMedium : AType.bodyMedium).copyWith(
                      fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                      fontFeatures: AFonts.tabular,
                      color: strong ? scheme.primary : null)),
            ),
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
        const SizedBox(height: Gap.xxs),
        line(t.ceTotalTime, totalTime),
        line(t.ceBand, band),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.bookmark_outline_rounded, size: 18),
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
        Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.f6QtRuleMarker, // truth: arithmetic, not AI
                style: AType.bodySmall.copyWith(color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                    height: 1.4)),
            const SizedBox(height: Gap.xxs),
            Text(t.ceMarkerSub,
                style: AType.bodySmall.copyWith(color: scheme.onTertiaryContainer,
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
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.ceAiTitle,
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: Gap.xxs),
            Text(t.ceAiBody,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
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
        Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant,
                    height: 1.4))),
      ]),
    );
  }
}
