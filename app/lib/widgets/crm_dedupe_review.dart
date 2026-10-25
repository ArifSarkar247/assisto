import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// DEDUPE + MERGE review (CRM spec #1). Lists duplicate lead groups (server
/// mirrors logic_capture.find_duplicates: phone/email/company+name). For each
/// group the user picks a SURVIVOR, previews the merge PLAN — which shows the
/// no-data-loss guarantee (activities before == after) — then applies it. The
/// merge folds the whole timeline/activities onto the survivor; nothing is lost.
class CrmDedupeReview extends StatefulWidget {
  final int org;
  const CrmDedupeReview({super.key, required this.org});
  @override
  State<CrmDedupeReview> createState() => _CrmDedupeReviewState();
}

class _CrmDedupeReviewState extends State<CrmDedupeReview> {
  List<Map<String, dynamic>> _groups = [];
  Map<int, Map<String, dynamic>> _leads = {}; // id -> lead summary
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
      final api = CrmAdvApi.of(context);
      final r = await api.duplicates(widget.org);
      _groups = ((r['groups'] as List?) ?? []).cast<Map<String, dynamic>>();
      final leads = (r['leads'] as List?)?.cast<Map<String, dynamic>>() ??
          await api.leads(widget.org);
      _leads = {for (final l in leads) (l['id'] as num).toInt(): l};
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_groups.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.verified_rounded,
          title: t.crmNoDuplicates,
          message: t.crmNoDuplicatesHint);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [for (final g in _groups) _groupCard(t, g)],
      ),
    );
  }

  Widget _groupCard(AppLocalizations t, Map<String, dynamic> g) {
    final ids = ((g['lead_ids'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.content_copy_rounded, size: 18),
            const SizedBox(width: Gap.xs),
            Text('${t.crmMatchedOn}: ${g['match_on']}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: Gap.xs),
          for (final id in ids) _leadLine(t, id),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: () => _startMerge(t, ids),
              icon: const Icon(Icons.merge_type_rounded),
              label: Text(t.crmMerge),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _leadLine(AppLocalizations t, int id) {
    final l = _leads[id] ?? {'id': id};
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(Icons.person_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            [l['name'], l['company'], l['phone'], l['email']]
                .where((x) => (x ?? '').toString().isNotEmpty)
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text('#$id', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Future<void> _startMerge(AppLocalizations t, List<int> ids) async {
    int survivor = ids.first;
    // Step 1 — pick the survivor.
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t.crmPickSurvivor),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.crmPickSurvivorHint,
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            for (final id in ids)
              RadioListTile<int>(
                value: id,
                groupValue: survivor,
                title: Text(_leads[id]?['name']?.toString().isNotEmpty == true
                    ? _leads[id]!['name'].toString()
                    : '#$id'),
                subtitle: Text(_leads[id]?['company']?.toString() ?? ''),
                onChanged: (v) => set(() => survivor = v ?? survivor),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, survivor), child: Text(t.crmNext)),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final dupIds = ids.where((x) => x != chosen).toList();

    // Step 2 — preview the plan (shows the no-loss guarantee), then apply.
    try {
      final plan = await CrmAdvApi.of(context).mergePreview(widget.org, chosen, dupIds);
      if (!mounted) return;
      final before = (plan['activity_count_before'] as num?)?.toInt() ?? 0;
      final after = (plan['activity_count_after'] as num?)?.toInt() ?? 0;
      final safe = before == after;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.crmConfirmMerge),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.crmSurvivor}: #$chosen'),
            Text('${t.crmWillDelete}: ${dupIds.map((e) => '#$e').join(', ')}'),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(safe ? Icons.verified_rounded : Icons.error_outline_rounded,
                  color: safe ? Brand.success : Brand.danger, size: 18),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  safe
                      ? '${t.crmNoDataLoss} ($before → $after ${t.crmActivitiesWord})'
                      : t.crmMergeUnsafe,
                  style: TextStyle(color: safe ? Brand.success : Brand.danger),
                ),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: safe ? () => Navigator.pop(ctx, true) : null,
                child: Text(t.crmMerge)),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await CrmAdvApi.of(context).mergeApply(widget.org, chosen, dupIds);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.crmMerged)));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(CrmError.from(e).textFor(context))));
      }
    }
  }
}
