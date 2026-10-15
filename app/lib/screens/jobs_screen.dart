import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/jobs_store.dart';
import '../widgets/jobs_card.dart';
import '../widgets/jobs_filters.dart';
import '../widgets/jobs_detail.dart';

/// Job Hunter — ADVANCED (feature 37, SPEC v2.1 §21). Three tabs:
///   • Discover — curated sample feed + search/filters + salary insight, with an
///     honest "connect a source" banner (we NEVER scrape; live jobs arrive only
///     via an official API / owner-provided feed, key-gated server-side).
///   • Saved — bookmarked jobs, offline-capable (local store).
///   • Tracker — the applied pipeline (matched→saved→applied→interview→offer/
///     rejected) with dates, notes, reminders and interview prep.
///
/// All AI (CV tailoring, cover-letter draft) is MOCK + key-gated via the
/// existing api.jobTailor. NEVER auto-applies. Zero Bangla literals (ARB only).
class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});
  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  List<Map<String, dynamic>> _jobs = [];
  Set<String> _saved = {};
  bool _loading = true, _error = false;
  JobFilter _filter = JobFilter();
  final _search = TextEditingController();

  /// Discovery feed is NOT connected to a live source yet → curated sample +
  /// honest banner. A real feed is key-gated server-side (official API / owner
  /// feed); flip this when that endpoint is wired. We never scrape.
  static const bool _feedConnected = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = false; });
    try {
      _jobs = await context.read<AppState>().api.listItems('jobs');
      _saved = await JobsLocal.savedIds();
    } catch (_) {
      // offline / token issue — keep any saved bookmarks working
      _saved = await JobsLocal.savedIds();
      if (_jobs.isEmpty) _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleSave(String id) async {
    await JobsLocal.toggleSaved(id);
    final s = await JobsLocal.savedIds();
    if (mounted) setState(() => _saved = s);
  }

  Future<void> _add(AppLocalizations tr) async {
    final title = TextEditingController();
    final company = TextEditingController();
    final jd = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.addJob),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: InputDecoration(labelText: tr.title)),
            TextField(controller: company, decoration: InputDecoration(labelText: tr.company)),
            TextField(controller: jd, maxLines: 4, decoration: InputDecoration(labelText: tr.jobDescription)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.add)),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('jobs', {
        'title': title.text.trim(),
        'company': company.text.trim(),
        'jd': jd.text.trim(),
      });
      await _load();
    }
  }

  void _openFilters(AppLocalizations tr) async {
    final r = await JobsFilterSheet.show(context, _filter);
    if (r != null) setState(() => _filter = r);
  }

  /// Discovery = curated sample ∪ user-added server jobs (both searchable).
  List<Map<String, dynamic>> get _discover {
    final f = JobFilter(
      query: _search.text, category: _filter.category, location: _filter.location,
      jobType: _filter.jobType, experience: _filter.experience,
      minSalary: _filter.minSalary, maxSalary: _filter.maxSalary,
    );
    final all = [
      ...kSampleJobs.map((j) => {...j, 'source': kSampleSource}),
      ..._jobs,
    ];
    return all.where(f.matches).toList();
  }

  List<Map<String, dynamic>> get _savedList {
    final all = [...kSampleJobs, ..._jobs];
    return all.where((j) => _saved.contains('${j['id']}')).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.jobHunter),
          actions: [
            IconButton(
              icon: Badge(
                isLabelVisible: _filter.isActive,
                label: Text('${_filter.activeCount}'),
                child: const Icon(Icons.tune),
              ),
              tooltip: tr.jobsFiltersTitle,
              onPressed: () => _openFilters(tr),
            ),
          ],
          bottom: TabBar(tabs: [
            Tab(child: Text(tr.jobsTabDiscover, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(tr.jobsTabSaved, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(tr.jobsTabTracker, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(tr), icon: const Icon(Icons.add), label: Text(tr.job)),
        body: _loading
            ? const SkeletonList()
            : _error
                ? StateMessage(
                    icon: Icons.cloud_off,
                    tint: scheme.error,
                    title: tr.loadFailed,
                    message: tr.jobsOfflineSavedHint,
                    action: FilledButton.tonalIcon(
                        onPressed: _load, icon: const Icon(Icons.refresh), label: Text(tr.retry)))
                : TabBarView(children: [
                    _discoverTab(tr, scheme),
                    _savedTab(tr, scheme),
                    _trackerTab(tr, scheme),
                  ]),
      ),
    );
  }

  // ----- Discover ---------------------------------------------------------
  Widget _discoverTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _discover;
    final insight = salaryInsight(list, category: _filter.category);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: tr.jobsSearchHint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _search.clear())),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
      if (!_feedConnected) _sourceBanner(tr, scheme),
      if (insight != null) _salaryInsight(tr, scheme, insight),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.search_off,
                title: tr.jobsNoResultsTitle,
                message: _filter.isActive || _search.text.isNotEmpty
                    ? tr.jobsNoResultsFilterHint
                    : tr.jobsNoResultsBody)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 88),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final j = list[i];
                    final id = '${j['id']}';
                    return JobsCard(
                      job: j,
                      saved: _saved.contains(id),
                      onToggleSave: () => _toggleSave(id),
                      onTap: () => JobsDetailSheet.show(context, j,
                          isServerJob: (j['id'] ?? 0) as int > 0, onChanged: _load),
                    );
                  },
                ),
              ),
      ),
    ]);
  }

  Widget _sourceBanner(AppLocalizations tr, ColorScheme scheme) => Container(
        margin: const EdgeInsets.symmetric(horizontal: Gap.md),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.rss_feed, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(tr.jobsConnectSourceBanner,
              style: TextStyle(fontSize: 12.5, color: scheme.onTertiaryContainer, height: 1.3))),
        ]),
      );

  Widget _salaryInsight(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> ins) => Container(
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.payments_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Text(tr.jobsSalaryInsight,
                style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface)),
          ]),
          const SizedBox(height: 4),
          // NB: generated signature order is (median, min, max, count) even
          // though the rendered string reads "min – median – max". Pass values
          // in the SIGNATURE order so each placeholder gets its intended value
          // and the range reads ascending (min ≤ median ≤ max).
          Text(tr.jobsSalaryRange('${ins['median']}', '${ins['min']}', '${ins['max']}', '${ins['count']}'),
              style: TextStyle(color: scheme.onSurface)),
          Text(tr.jobsSalarySourceNote,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ]),
      );

  // ----- Saved ------------------------------------------------------------
  Widget _savedTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _savedList;
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.bookmark_border,
        title: tr.jobsNoSavedTitle,
        message: tr.jobsNoSavedBody,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final j = list[i];
        final id = '${j['id']}';
        return JobsCard(
          job: j,
          saved: true,
          onToggleSave: () => _toggleSave(id),
          onTap: () => JobsDetailSheet.show(context, j,
              isServerJob: (j['id'] ?? 0) as int > 0, onChanged: _load),
        );
      },
    );
  }

  // ----- Tracker ----------------------------------------------------------
  Widget _trackerTab(AppLocalizations tr, ColorScheme scheme) {
    if (_jobs.isEmpty) {
      return StateMessage(
        icon: Icons.work_outline,
        title: tr.noJobsYet,
        message: tr.addAJobDescriptionI,
        action: FilledButton.icon(
            onPressed: () => _add(tr), icon: const Icon(Icons.add), label: Text(tr.addJob)),
      );
    }
    // group by pipeline stage for a kanban-ish read
    final byStage = <String, List<Map<String, dynamic>>>{};
    for (final j in _jobs) {
      byStage.putIfAbsent((j['status'] ?? kStageMatched).toString(), () => []).add(j);
    }
    final order = [...kPipeline, kStageRejected, kStageWithdrawn];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm, left: 4),
          child: Text(tr.iNeverAutoApplyYou,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        for (final stage in order)
          if ((byStage[stage] ?? []).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, Gap.sm, 4, Gap.sm),
              child: Row(children: [
                StageBadge(status: stage),
                const SizedBox(width: Gap.sm),
                Text('${byStage[stage]!.length}',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
              ]),
            ),
            for (final j in byStage[stage]!)
              JobsCard(
                job: j,
                saved: _saved.contains('${j['id']}'),
                onToggleSave: () => _toggleSave('${j['id']}'),
                onTap: () => JobsDetailSheet.show(context, j, isServerJob: true, onChanged: _load),
              ),
          ],
      ],
    );
  }
}
