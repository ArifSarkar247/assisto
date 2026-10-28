import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CELEBRITY tier — Brand deals & offers pipeline (#121, §14).
///
/// A brand-deal tracker for a public figure's PA: each deal has a brand, a value
/// (৳ — a number the PA typed), a STAGE (negotiating → signed → delivered →
/// paid), DELIVERABLES and a deadline. The board is ordered open-first → deadline
/// → brand and shows honest pipeline totals (sum, stage-weighted "expected",
/// paid) and the overdue count. This HOLDS NO MONEY — it tracks only.
///
/// Mirrors backend/core/logic/pa_deals.py so previews are identical offline.
/// ZERO Bangla literals — every string is an AppLocalizations getter.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('star/deals') / createItem / updateItem / deleteItem
class StarDealsScreen extends StatefulWidget {
  const StarDealsScreen({super.key});
  @override
  State<StarDealsScreen> createState() => _StarDealsScreenState();
}

// ---- constants (mirror pa_deals.py) ---------------------------------------
const String _stNeg = 'negotiating';
const String _stSigned = 'signed';
const String _stDelivered = 'delivered';
const String _stPaid = 'paid';
const List<String> _stages = [_stNeg, _stSigned, _stDelivered, _stPaid];
const Map<String, int> _stageRank = {
  _stNeg: 0,
  _stSigned: 1,
  _stDelivered: 2,
  _stPaid: 3,
};
const Map<String, double> _stageWeight = {
  _stNeg: 0.5,
  _stSigned: 0.9,
  _stDelivered: 1.0,
  _stPaid: 1.0,
};
const List<String> _closed = [_stDelivered, _stPaid];

class _StarDealsScreenState extends State<StarDealsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    try {
      _rows = await context.read<AppState>().api.listItems('star/deals');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- deterministic mirror of pa_deals.py ---------------------------------
  String _stage(Map<String, dynamic> r) {
    final v = (r['stage'] ?? '').toString().toLowerCase();
    return _stages.contains(v) ? v : _stNeg;
  }

  num _value(Map<String, dynamic> r) {
    final v = num.tryParse((r['value'] ?? '').toString()) ?? 0;
    return v < 0 ? 0 : v;
  }

  List<String> _deliverables(Map<String, dynamic> r) {
    final raw = r['deliverables'];
    if (raw is List) {
      return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }
    return raw
            ?.toString()
            .replaceAll(',', '\n')
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        [];
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    return DateTime.tryParse(s.trim().endsWith('Z')
        ? s.trim().substring(0, s.trim().length - 1)
        : s.trim());
  }

  bool _overdue(Map<String, dynamic> r) {
    if (_closed.contains(_stage(r))) return false;
    final d = _parseDate(r['deadline']?.toString());
    if (d == null) return false;
    final now = DateTime.now();
    return DateTime(d.year, d.month, d.day)
        .isBefore(DateTime(now.year, now.month, now.day));
  }

  List<Map<String, dynamic>> get _ordered {
    final list = List<Map<String, dynamic>>.from(_rows);
    list.sort((a, b) {
      final ra = _stageRank[_stage(a)] ?? 0;
      final rb = _stageRank[_stage(b)] ?? 0;
      if (ra != rb) return ra - rb;
      final da = _parseDate(a['deadline']?.toString());
      final db = _parseDate(b['deadline']?.toString());
      final ka = da?.toIso8601String() ?? '9999';
      final kb = db?.toIso8601String() ?? '9999';
      final c = ka.compareTo(kb);
      if (c != 0) return c;
      return (a['brand'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['brand'] ?? '').toString().toLowerCase());
    });
    return list;
  }

  num get _totalValue => _rows.fold<num>(0, (s, r) => s + _value(r));
  num get _expectedValue {
    final e = _rows.fold<double>(
        0, (s, r) => s + _value(r) * (_stageWeight[_stage(r)] ?? 0.5));
    return e == e.roundToDouble() ? e.round() : double.parse(e.toStringAsFixed(2));
  }

  num get _paidValue =>
      _rows.where((r) => _stage(r) == _stPaid).fold<num>(0, (s, r) => s + _value(r));
  int get _overdueCount => _rows.where(_overdue).length;

  String _money(num v) => v == v.roundToDouble()
      ? '৳${v.round()}'
      : '৳${v.toStringAsFixed(2)}';

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addOrEdit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DealForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('star/deals', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('star/deals', result);
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _advance(Map<String, dynamic> r, AppLocalizations tr) async {
    final cur = _stage(r);
    final idx = _stages.indexOf(cur);
    if (idx >= _stages.length - 1) return;
    final to = _stages[idx + 1];
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.updateItem('star/deals', id, {'stage': to});
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(tr.starDealsDeleteTitle),
        content: Text(tr.starDealsDeleteBody((r['brand'] ?? '').toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('star/deals', id);
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.starDealsTitle)),
      // qa1: the empty state already has this action as its CTA — one is enough
      floatingActionButton: (!_loading && !_error && _rows.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _loading ? null : () => _addOrEdit(tr),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr.starDealsAdd),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.starDealsLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr)
                  : _bodyView(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => StateMessage(
        icon: Icons.handshake_rounded,
        title: tr.starDealsWelcomeTitle,
        // The arrow (U+2192) used as a stage separator renders as a tofu box in
        // the app font; swap it for the bullet the app already uses elsewhere.
        message: tr.starDealsWelcomeBody.replaceAll('\u2192', ' \u2022 '),
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.starDealsAdd),
        ),
      );

  Widget _bodyView(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          _pipelineCard(tr, scheme),
          const SizedBox(height: Gap.md),
          Text(tr.starDealsNoHold,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
          const SizedBox(height: Gap.md),
          for (final r in list) ...[
            _card(r, tr, scheme),
            const SizedBox(height: Gap.sm),
          ],
        ],
      ),
    );
  }

  Widget _pipelineCard(AppLocalizations tr, ColorScheme scheme) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr.starDealsPipeline,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            _kv(tr.starDealsTotalValue, _money(_totalValue), scheme),
            _kv(tr.starDealsExpectedValue, _money(_expectedValue), scheme),
            _kv(tr.starDealsPaidValue, _money(_paidValue), scheme),
            if (_overdueCount > 0) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text(tr.starDealsOverdue('$_overdueCount'),
                      style: AType.bodyMedium.copyWith(color: scheme.error, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
            const SizedBox(height: Gap.xs),
            Text(tr.starDealsExpectedNote,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
          ]),
        ),
      );

  Widget _kv(String k, String v, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
        child: Row(children: [
          Expanded(
            child: Text(k,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: Gap.sm),
          Text(v,
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );

  Color _stageColor(String s, ColorScheme scheme) {
    switch (s) {
      case _stPaid:
        return Brand.success;
      case _stDelivered:
        return scheme.primary;
      case _stSigned:
        return Brand.cyan;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  String _stageLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _stSigned:
        return tr.starDealsStageSigned;
      case _stDelivered:
        return tr.starDealsStageDelivered;
      case _stPaid:
        return tr.starDealsStagePaid;
      default:
        return tr.starDealsStageNegotiating;
    }
  }

  Widget _card(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final stage = _stage(r);
    final overdue = _overdue(r);
    final brand = (r['brand'] ?? '').toString();
    final deliverables = _deliverables(r);
    final deadline = (r['deadline'] ?? '').toString().trim();
    final canAdvance = _stages.indexOf(stage) < _stages.length - 1;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(brand,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            _pill(_stageLabel(tr, stage), _stageColor(stage, scheme)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(_money(_value(r)),
              style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurface, fontWeight: FontWeight.w600)),
          if (deliverables.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: deliverables
                  .map((d) => Chip(
                        label: Text(d, style: AType.bodySmall),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ))
                  .toList(),
            ),
          ],
          if (deadline.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.event_rounded,
                  size: 15, color: overdue ? scheme.error : scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(
                    overdue ? tr.starDealsDeadlineOverdue(deadline) : tr.starDealsDeadline(deadline),
                    style: AType.bodySmall.copyWith(color: overdue ? scheme.error : scheme.onSurfaceVariant, fontWeight: overdue ? FontWeight.w700 : FontWeight.w400),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ],
          const Divider(height: Gap.xl),
          Row(children: [
            if (canAdvance)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _advance(r, tr),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(tr.starDealsAdvance(_stageLabel(tr, _stages[_stages.indexOf(stage) + 1])),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              )
            else
              Expanded(
                child: Text(tr.starDealsFullyPaid,
                    style: AType.bodyMedium.copyWith(color: Brand.success, fontWeight: FontWeight.w600)),
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'edit') _addOrEdit(tr, existing: r);
                if (v == 'delete') _delete(r, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
      );
}

/// Add / edit a brand deal.
class _DealForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _DealForm({this.existing});
  @override
  State<_DealForm> createState() => _DealFormState();
}

class _DealFormState extends State<_DealForm> {
  late final TextEditingController _brand =
      TextEditingController(text: widget.existing?['brand']?.toString() ?? '');
  late final TextEditingController _value =
      TextEditingController(text: widget.existing?['value']?.toString() ?? '');
  late final TextEditingController _deliverables = TextEditingController(
      text: _initDeliverables(widget.existing?['deliverables']));
  late final TextEditingController _deadline =
      TextEditingController(text: widget.existing?['deadline']?.toString() ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.existing?['note']?.toString() ?? '');
  late String _stage = _stages.contains((widget.existing?['stage'] ?? '').toString())
      ? widget.existing!['stage'].toString()
      : _stNeg;

  String _initDeliverables(dynamic raw) {
    if (raw is List) return raw.join('\n');
    return raw?.toString() ?? '';
  }

  @override
  void dispose() {
    _brand.dispose();
    _value.dispose();
    _deliverables.dispose();
    _deadline.dispose();
    _note.dispose();
    super.dispose();
  }

  String _stageLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _stSigned:
        return tr.starDealsStageSigned;
      case _stDelivered:
        return tr.starDealsStageDelivered;
      case _stPaid:
        return tr.starDealsStagePaid;
      default:
        return tr.starDealsStageNegotiating;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _brand.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.starDealsAdd : tr.starDealsEdit,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _brand,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.starDealsBrandField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _value,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr.starDealsValueField,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.starDealsStageLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final s in _stages)
              ChoiceChip(
                label: Text(_stageLabel(tr, s)),
                selected: _stage == s,
                onSelected: (_) => setState(() => _stage = s),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _deliverables,
            maxLines: 3,
            decoration: InputDecoration(
                labelText: tr.starDealsDeliverablesField,
                helperText: tr.starDealsDeliverablesHelper,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _deadline,
            decoration: InputDecoration(
                labelText: tr.starDealsDeadlineField,
                hintText: 'YYYY-MM-DD',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: tr.starDealsNoteField,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(context, <String, dynamic>{
                          'brand': _brand.text.trim(),
                          'value': _value.text.trim(),
                          'stage': _stage,
                          'deliverables': _deliverables.text.trim(),
                          'deadline': _deadline.text.trim(),
                          'note': _note.text.trim(),
                        })
                    : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
