import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CORPORATE · Departmental update — ADVANCED (#117, §14).
///
/// Collect one status UPDATE per department (department, lead, HIGHLIGHTS,
/// BLOCKERS, METRICS), then get a deterministic rolled-up SUMMARY across
/// departments: departments reporting, how many are blocked, total highlights
/// / blockers, plus a per-department structured block. Metrics are REPORTED
/// verbatim, never computed. Editable, copy/share-able, savable ('pa/deptupdates').
/// Works fully offline with NO key.
///
/// Honest "AI-generated — review" marker (the STRUCTURE / counting is generated,
/// nothing is fabricated); a documented "connect an AI key for an AI-written
/// synthesis" seam (Anthropic) that never fakes a narrative. Fixed scaffolding
/// (Highlights / Blockers / Metrics headings + roll-up labels) is localised
/// bn/en from the .arb — this file has ZERO Bangla literals. Structure mirrors
/// backend/core/logic/pa_dept.py exactly so the preview is identical offline.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/deptupdates')            → saved updates (one row per dept)
///   createItem('pa/deptupdates', body)     → save
///   updateItem('pa/deptupdates', id, body) → re-save edits
///   deleteItem('pa/deptupdates', id)       → remove
class DeptUpdateScreen extends StatefulWidget {
  const DeptUpdateScreen({super.key});
  @override
  State<DeptUpdateScreen> createState() => _DeptUpdateScreenState();
}

String _clean(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

List<String> _bullets(String raw) => raw
    .replaceAll('\r\n', '\n')
    .split('\n')
    .map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
    .where((s) => s.isNotEmpty)
    .toList();

class _DeptUpdateScreenState extends State<DeptUpdateScreen> {
  List<Map<String, dynamic>> _saved = [];
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
      _saved = await context.read<AppState>().api.listItems('pa/deptupdates');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open({Map<String, dynamic>? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _DeptEditor(existing: existing)),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paDeptDeleteTitle),
        content: Text(tr.paDeptDeleteBody(_clean(r['department']?.toString()))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
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
      if (id is int) {
        await context.read<AppState>().api.deleteItem('pa/deptupdates', id);
      }
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.deleteFailed)));
      }
    }
  }

  // ---- cross-department roll-up (mirror pa_dept.rollup counts) -------------
  ({int depts, int blocked, int hl, int bl}) _counts() {
    var depts = 0, blocked = 0, hl = 0, bl = 0;
    for (final r in _saved) {
      if (_clean(r['department']?.toString()).isEmpty) continue;
      depts++;
      final h = _bullets(r['highlights']?.toString() ?? '');
      final b = _bullets(r['blockers']?.toString() ?? '');
      hl += h.length;
      bl += b.length;
      if (b.isNotEmpty) blocked++;
    }
    return (depts: depts, blocked: blocked, hl: hl, bl: bl);
  }

  String _rollupText(AppLocalizations tr) {
    final c = _counts();
    final out = <String>[tr.paDeptRollReporting(c.depts)];
    out.add(
        c.blocked > 0 ? tr.paDeptRollBlocked(c.blocked) : tr.paDeptRollClear);
    out.add(tr.paDeptRollHighlights(c.hl));
    out.add(tr.paDeptRollBlockers(c.bl));
    for (final r in _saved) {
      final dept = _clean(r['department']?.toString());
      if (dept.isEmpty) continue;
      final lead = _clean(r['lead']?.toString());
      out.add('');
      out.add(lead.isNotEmpty ? '$dept — $lead' : dept);
      final h = _bullets(r['highlights']?.toString() ?? '');
      out.add('${tr.paDeptSecHighlights}:');
      if (h.isEmpty) {
        out.add('  (${tr.paDeptNone})');
      } else {
        for (final x in h) {
          out.add('  • $x');
        }
      }
      final b = _bullets(r['blockers']?.toString() ?? '');
      out.add('${tr.paDeptSecBlockers}:');
      if (b.isEmpty) {
        out.add('  (${tr.paDeptNone})');
      } else {
        for (final x in b) {
          out.add('  • $x');
        }
      }
      final metrics = (r['metrics'] as List?) ?? const [];
      final validMetrics = metrics
          .whereType<Map>()
          .where((m) => _clean(m['label']?.toString()).isNotEmpty)
          .toList();
      if (validMetrics.isNotEmpty) {
        out.add('${tr.paDeptSecMetrics}:');
        for (final m in validMetrics) {
          final label = _clean(m['label']?.toString());
          final value = _clean(m['value']?.toString());
          out.add(value.isNotEmpty ? '  • $label: $value' : '  • $label');
        }
      }
    }
    return out.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paDeptTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.paDeptNew),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paDeptLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _saved.isEmpty
                  ? StateMessage(
                      icon: Icons.insights_rounded,
                      title: tr.paDeptWelcomeTitle,
                      message: tr.paDeptWelcomeBody,
                      action: FilledButton.icon(
                        onPressed: () => _open(),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(tr.paDeptNew),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.md, Gap.md, Gap.md, 96),
                        children: [
                          _rollupCard(tr, scheme),
                          const SizedBox(height: Gap.md),
                          for (final r in _saved) ...[
                            _deptCard(tr, scheme, r),
                            const SizedBox(height: Gap.sm),
                          ],
                        ],
                      ),
                    ),
    );
  }

  Widget _rollupCard(AppLocalizations tr, ColorScheme scheme) {
    final c = _counts();
    final rendered = _rollupText(tr);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.summarize_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.paDeptRollupTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          _chip(
              scheme, Icons.business_rounded, tr.paDeptRollReporting(c.depts)),
          _chip(
              scheme,
              c.blocked > 0 ? Icons.block_rounded : Icons.check_circle_outline_rounded,
              c.blocked > 0
                  ? tr.paDeptRollBlocked(c.blocked)
                  : tr.paDeptRollClear,
              danger: c.blocked > 0),
          _chip(scheme, Icons.star_outline_rounded, tr.paDeptRollHighlights(c.hl)),
          _chip(scheme, Icons.report_rounded, tr.paDeptRollBlockers(c.bl)),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Icon(Icons.info_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: Text(tr.f6BwTemplateMarker, // truth: template, not AI
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: rendered));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(content: Text(tr.copied)));
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(tr.copy),
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => Share.share(rendered),
              icon: const Icon(Icons.share_rounded, size: 18),
              label: Text(tr.share),
            ),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        _aiSeamCard(tr, scheme),
      ]),
    );
  }

  Widget _chip(ColorScheme scheme, IconData icon, String label,
      {bool danger = false}) {
    final c = danger ? scheme.error : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: c, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _deptCard(
      AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> r) {
    final dept = _clean(r['department']?.toString());
    final lead = _clean(r['lead']?.toString());
    final h = _bullets(r['highlights']?.toString() ?? '');
    final b = _bullets(r['blockers']?.toString() ?? '');
    final metrics = ((r['metrics'] as List?) ?? const [])
        .whereType<Map>()
        .where((m) => _clean(m['label']?.toString()).isNotEmpty)
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dept.isEmpty ? tr.paDeptUnnamed : dept,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    if (lead.isNotEmpty)
                      Text(lead,
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 12.5)),
                  ]),
            ),
            if (b.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(tr.paDeptBlockedBadge,
                    style: TextStyle(
                        color: scheme.error,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700)),
              ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'open') _open(existing: r);
                if (v == 'delete') _delete(r, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'open', child: Text(tr.paDeptOpen)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          if (h.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            _bulletBlock(scheme, tr.paDeptSecHighlights, h, scheme.primary),
          ],
          if (b.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            _bulletBlock(scheme, tr.paDeptSecBlockers, b, scheme.error),
          ],
          if (metrics.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(tr.paDeptSecMetrics,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final m in metrics)
                _metricChip(scheme, _clean(m['label']?.toString()),
                    _clean(m['value']?.toString())),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _bulletBlock(
      ColorScheme scheme, String label, List<String> items, Color accent) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700)),
      for (final x in items)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Container(
                  width: 5,
                  height: 5,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle)),
            ),
            Expanded(child: Text(x, style: const TextStyle(fontSize: 13.5))),
          ]),
        ),
    ]);
  }

  Widget _metricChip(ColorScheme scheme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(value.isNotEmpty ? '$label: $value' : label,
          style: const TextStyle(fontSize: 12.5)),
    );
  }

  Widget _aiSeamCard(AppLocalizations tr, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.paDeptAiSeamTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, height: 1.4)),
              const SizedBox(height: 2),
              Text(tr.paDeptAiSeamBody,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.4)),
            ]),
          ),
        ]),
      );
}

/// Editor for one department's update: dept, lead, highlights, blockers,
/// metrics (label + value). Save writes a 'pa/deptupdates' row.
class _DeptEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _DeptEditor({this.existing});
  @override
  State<_DeptEditor> createState() => _DeptEditorState();
}

class _DeptEditorState extends State<_DeptEditor> {
  late final TextEditingController _dept = TextEditingController(
      text: widget.existing?['department']?.toString() ?? '');
  late final TextEditingController _lead =
      TextEditingController(text: widget.existing?['lead']?.toString() ?? '');
  late final TextEditingController _highlights = TextEditingController(
      text: widget.existing?['highlights']?.toString() ?? '');
  late final TextEditingController _blockers = TextEditingController(
      text: widget.existing?['blockers']?.toString() ?? '');
  late List<Map<String, dynamic>> _metrics = () {
    final v = widget.existing?['metrics'];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }();
  bool _saving = false;

  @override
  void dispose() {
    _dept.dispose();
    _lead.dispose();
    _highlights.dispose();
    _blockers.dispose();
    super.dispose();
  }

  List<String> _validate() {
    final problems = <String>[];
    if (_clean(_dept.text).isEmpty) problems.add('empty_department');
    return problems;
  }

  Future<void> _save(AppLocalizations tr) async {
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'department': _clean(_dept.text),
      'lead': _clean(_lead.text),
      'highlights': _highlights.text.trim(),
      'blockers': _blockers.text.trim(),
      'metrics': _metrics
          .where((m) => _clean(m['label']?.toString()).isNotEmpty)
          .toList(),
    };
    try {
      final api = context.read<AppState>().api;
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem('pa/deptupdates', id, body);
      } else {
        await api.createItem('pa/deptupdates', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.saveFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final problems = _validate();
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null ? tr.paDeptNew : tr.paDeptEdit)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
        children: [
          TextField(
            controller: _dept,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paDeptNameField,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _lead,
            decoration: InputDecoration(
                labelText: tr.paDeptLeadField,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _highlights,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: tr.paDeptHighlightsField,
              helperText: tr.paDeptLinesHelp,
              helperMaxLines: 2,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _blockers,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr.paDeptBlockersField,
              helperText: tr.paDeptLinesHelp,
              helperMaxLines: 2,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.lg),
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.query_stats_rounded,
                    size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.paDeptSecMetrics,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(tr.paDeptMetricHelp,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              for (var i = 0; i < _metrics.length; i++) ...[
                const SizedBox(height: Gap.sm),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      initialValue: _metrics[i]['label']?.toString() ?? '',
                      onChanged: (v) => _metrics[i]['label'] = v,
                      decoration: InputDecoration(
                          isDense: true,
                          labelText: tr.paDeptMetricLabelField,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      initialValue: _metrics[i]['value']?.toString() ?? '',
                      onChanged: (v) => _metrics[i]['value'] = v,
                      decoration: InputDecoration(
                          isDense: true,
                          labelText: tr.paDeptMetricValueField,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  IconButton(
                    icon:
                        Icon(Icons.remove_circle_outline_rounded, color: scheme.error),
                    onPressed: () => setState(() => _metrics.removeAt(i)),
                  ),
                ]),
              ],
              const SizedBox(height: Gap.xs),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _metrics.add({'label': '', 'value': ''})),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(tr.paDeptAddMetric),
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(tr.paDeptMetricReportedNote,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  (problems.isEmpty && !_saving) ? () => _save(tr) : null,
              icon: const Icon(Icons.save_rounded, size: 18),
              label: Text(tr.save),
            ),
          ),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(tr.paDeptNeedName,
                style: TextStyle(color: scheme.error, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
