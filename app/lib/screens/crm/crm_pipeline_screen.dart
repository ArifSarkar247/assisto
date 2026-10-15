import 'crm_erp_handoff_screen.dart';
import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';

/// Pipeline kanban (CRM_SPEC): columns = stages, drag a deal between stages
/// (updates stage via API), with deal value (৳ BDT), probability, expected close
/// date and a stuck-age warning. A move onto a Lost stage requires a mandatory
/// loss reason (enforced by the backend; collected here first).
class CrmPipelineScreen extends StatefulWidget {
  final int org;
  const CrmPipelineScreen({super.key, required this.org});
  @override
  State<CrmPipelineScreen> createState() => _CrmPipelineScreenState();
}

class _CrmPipelineScreenState extends State<CrmPipelineScreen> {
  List<Map<String, dynamic>> _stages = [];
  List<Map<String, dynamic>> _deals = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmApi.of(context);
      final pipes = await api.pipelines(widget.org);
      if (pipes.isNotEmpty) {
        _stages = ((pipes.first['stages'] as List?) ?? []).cast<Map<String, dynamic>>();
        _deals = await api.deals(widget.org, pipeline: (pipes.first['id'] as num).toInt());
      } else {
        _stages = [];
        _deals = [];
      }
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _move(AppLocalizations t, Map<String, dynamic> deal, Map<String, dynamic> stage) async {
    final isLost = stage['is_lost'] == true;
    String? lossReason;
    if (isLost) {
      lossReason = await _askLoss(t);
      if (lossReason == null) return; // cancelled — mandatory reason not given
    }
    try {
      await CrmApi.of(context).moveDeal(
          (deal['id'] as num).toInt(), (stage['id'] as num).toInt(),
          lossReason: lossReason);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<String?> _askLoss(AppLocalizations t) async {
    final reasons = {
      'price': t.crmLossPrice,
      'competitor': t.crmLossCompetitor,
      'timing': t.crmLossTiming,
      'no_budget': t.crmLossNoBudget,
      'no_need': t.crmLossNoNeed,
      'no_response': t.crmLossNoResponse,
      'other': t.crmIndOther,
    };
    String? pick;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t.crmLossReasonRequired),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final e in reasons.entries)
                RadioListTile<String>(
                  value: e.key,
                  groupValue: pick,
                  title: Text(e.value),
                  onChanged: (v) => set(() => pick = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: pick == null ? null : () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    return ok == true ? pick : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_stages.isEmpty) {
      return CrmStateView.empty(icon: Icons.view_kanban_outlined, title: t.crmNoPipeline, message: t.crmNoPipelineHint);
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(Gap.md),
      children: [
        for (final s in _stages) _column(t, s),
      ],
    );
  }

  Widget _column(AppLocalizations t, Map<String, dynamic> stage) {
    final scheme = Theme.of(context).colorScheme;
    final stageId = (stage['id'] as num).toInt();
    final deals = _deals.where((d) => (d['stage'] as num?)?.toInt() == stageId).toList();
    // Size each column to ~68% of the viewport so ~1.3 columns show on a 360dp
    // screen (the previous fixed 260dp left the first column as dead space and
    // clipped the next column's card). Capped for wider tablets.
    final screenW = MediaQuery.of(context).size.width;
    final colW = (screenW * 0.68).clamp(220.0, 290.0);
    return Container(
      width: colW,
      margin: const EdgeInsets.only(right: Gap.md),
      child: DragTarget<Map<String, dynamic>>(
        onWillAcceptWithDetails: (d) => (d.data['stage'] as num?)?.toInt() != stageId,
        onAcceptWithDetails: (d) => _move(t, d.data, stage),
        builder: (ctx, cand, rej) => Container(
          decoration: BoxDecoration(
            color: cand.isNotEmpty ? scheme.primaryContainer.withValues(alpha: 0.4) : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          padding: const EdgeInsets.all(Gap.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(Gap.xs),
              child: Row(children: [
                Expanded(child: Text(stage['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w800))),
                Text('${stage['probability']}%', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
            Expanded(
              child: ListView(children: [
                for (final d in deals) _dealCard(t, d, stage),
                if (deals.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Text(t.crmNoDealsHere, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _dealCard(AppLocalizations t, Map<String, dynamic> d, Map<String, dynamic> stage) {
    final stuckDays = _stuckAge(d, stage);
    final card = Card(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(bdt((d['value'] as num?)), style: const TextStyle(fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${d['probability']}% · ${d['expected_close'] ?? '—'}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          if (stuckDays != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.warning_amber_outlined, size: 14, color: Brand.warning),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('${t.crmStuck} $stuckDays${t.crmDaysShort}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Brand.warning)),
                ),
              ]),
            ),
        ]),
      ),
    );
    return LongPressDraggable<Map<String, dynamic>>(
      data: d,
      feedback: Material(color: Colors.transparent, child: SizedBox(width: 240, child: card)),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      // Tap a deal → ERP implementation hand-off (Axon); long-press still drags.
      child: GestureDetector(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => CrmErpHandoffScreen(org: widget.org, deal: d))),
        child: card,
      ),
    );
  }

  int? _stuckAge(Map<String, dynamic> d, Map<String, dynamic> stage) {
    final thresh = (stage['stuck_after_days'] as num?)?.toInt() ?? 0;
    final entered = DateTime.tryParse((d['stage_entered_at'] ?? '').toString());
    if (thresh <= 0 || entered == null || d['state'] != 'open') return null;
    final age = DateTime.now().difference(entered).inDays;
    return age > thresh ? age : null;
  }
}
