import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_company_widgets.dart';
import 'crm_common.dart';

/// Sales Reports / management dashboard (CRM_SPEC §9). Surfaces the reports the
/// server already computes and returns on `GET /crm/dashboard`:
///   - weighted forecast (labelled an ESTIMATE, with its method shown)
///   - win rate + win/loss
///   - pipeline by industry
///   - performance by rep (open/won/lost, won value, target attainment)
/// Reports the server CALCULATES but does not yet RETURN on any endpoint
/// (funnel drop-off, sales-cycle length, source win-rate, activity leaderboard)
/// are shown as honest "not surfaced yet" panels — never invented numbers — and
/// recorded as gaps in crm_report_arb / the integration md. Booked-vs-collected
/// and renewal pipeline are not modelled on the backend at all and are likewise
/// shown as unavailable.
///
/// Benchmarked against best-in-class B2B sales dashboards: a headline KPI strip,
/// a forecast card that is transparent about its method, a visual funnel, and
/// per-rep attainment bars — with rigorous honest-empty states.
class CrmReportsScreen extends StatefulWidget {
  final int org;
  const CrmReportsScreen({super.key, required this.org});
  @override
  State<CrmReportsScreen> createState() => _CrmReportsScreenState();
}

class _CrmReportsScreenState extends State<CrmReportsScreen> {
  Map<String, dynamic>? _d;
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
      _d = await CrmApi.of(context).dashboard(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(
          error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final d = _d ?? {};
    if (d['restricted'] == true) {
      final lang = Localizations.localeOf(context).languageCode;
      return CrmStateView.empty(
        icon: Icons.lock_outline_rounded,
        title: t.crmReports,
        message: lang == 'bn'
            ? (d['message_bn'] ?? t.crmOnlyManagers).toString()
            : (d['message_en'] ?? t.crmOnlyManagers).toString(),
      );
    }
    final forecast = (d['forecast'] as Map?)?.cast<String, dynamic>() ?? {};
    final winLoss = (d['win_loss'] as Map?)?.cast<String, dynamic>() ?? {};
    final byInd = (d['by_industry'] as Map?)?.cast<String, dynamic>() ?? {};
    final byRep = (d['by_salesperson'] as Map?)?.cast<String, dynamic>() ?? {};
    // Forward-compatible: these are COMPUTED server-side but not yet returned by
    // DashboardView (gap #8). We read them if present so the moment the backend
    // adds them to the response, these panels light up with no further change.
    final funnel = (d['funnel'] as Map?)?.cast<String, dynamic>();
    final cycle = (d['sales_cycle'] as Map?)?.cast<String, dynamic>();
    final bySource = (d['source_attribution'] as Map?)?.cast<String, dynamic>();
    final leaderboard =
        (d['activity_leaderboard'] as Map?)?.cast<String, dynamic>();
    final lang = Localizations.localeOf(context).languageCode;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        Text(t.crmReportsSubtitle,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),

        // ---- KPI strip ----
        Row(children: [
          Expanded(
            child: ReportStatTile(
                label: t.crmPipelineValue,
                value: bdt(context, d['pipeline_value'] as num?),
                icon: Icons.account_tree_rounded),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: ReportStatTile(
                label: t.crmWonValue,
                value: bdt(context, d['won_value'] as num?),
                icon: Icons.emoji_events_rounded,
                tint: AssistoTokens.of(context).success),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: ReportStatTile(
                label: t.crmReportWinRate,
                value: winLoss['win_rate'] == null
                    ? '—'
                    : '${winLoss['win_rate']}%',
                icon: Icons.percent_rounded,
                tint: Brand.blue),
          ),
        ]),
        const SizedBox(height: Gap.md),

        // ---- weighted forecast (ESTIMATE) ----
        CrmSectionHeader(t.crmReportForecast,
            trailing: _estimateBadge(t)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: forecast['has_data'] == true
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bdt(context, forecast['weighted'] as num?),
                          style: AType.headlineMedium.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: Gap.xs),
                      _line(t.crmBestCase, bdt(context, forecast['best_case'] as num?)),
                      _line(t.crmCommitForecast, bdt(context, forecast['commit'] as num?)),
                      _line(t.crmOpenDealsCount, '${forecast['open_count'] ?? 0}'),
                      const SizedBox(height: Gap.xs),
                      // fixed server formula, shown in the user's language
                      // (the server text is English and uses a Σ glyph the
                      // Bengali font lacks)
                      Text('${t.crmMethodLabel}: ${t.shopQaForecastMethod}',
                          style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.xs),
                      Text(t.crmForecastEstimateNote,
                          style: AType.labelSmall.copyWith(fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant)),
                    ],
                  )
                : _notEnough(lang, forecast),
          ),
        ),
        const SizedBox(height: Gap.md),

        // ---- win / loss ----
        CrmSectionHeader(t.crmReportWinRate),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: winLoss['has_data'] == true
                ? Column(children: [
                    _line(t.crmWon, '${winLoss['won'] ?? 0}'),
                    _line(t.crmLost, '${winLoss['lost'] ?? 0}'),
                    _line(t.crmReportWinRate,
                        winLoss['win_rate'] == null
                            ? '—'
                            : '${winLoss['win_rate']}%'),
                    ...(() {
                      final reasons = ((winLoss['loss_reasons'] as List?) ?? [])
                          .cast<Map<String, dynamic>>()
                          .where((r) => (r['count'] as num?) != null &&
                              (r['count'] as num) > 0)
                          .toList();
                      if (reasons.isEmpty) return <Widget>[];
                      return [
                        for (final r in reasons)
                          _line(_lossLabel(r['label']?.toString(), lang),
                              '${r['count']}'),
                      ];
                    })(),
                  ])
                : Text(t.crmNotEnoughData,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ),
        const SizedBox(height: Gap.md),

        // ---- pipeline by industry ----
        CrmSectionHeader(t.crmReportByIndustry),
        _rowsCard(byInd,
            (r) => _line(crmIndustryLabel(t, r['industry']?.toString()),
                '${bdt(context, r['value'] as num?)} · ${r['count']}')),
        const SizedBox(height: Gap.md),

        // ---- performance by rep (with attainment bars) ----
        CrmSectionHeader(t.crmReportByRep),
        _repCard(byRep, t),
        const SizedBox(height: Gap.md),

        // ---- reports DashboardView returns (gap #8) ----
        // f6: a panel whose block the server did not send is HIDDEN, never an
        // "unavailable" placeholder.
        if (funnel != null) ...[
          CrmSectionHeader(t.crmReportFunnel, hint: t.crmReportFunnelHint),
          _funnelCard(funnel),
          const SizedBox(height: Gap.md),
        ],
        if (cycle != null) ...[
          CrmSectionHeader(t.crmReportSalesCycle,
              hint: t.crmReportSalesCycleHint),
          _cycleCard(cycle, t),
          const SizedBox(height: Gap.md),
        ],
        if (bySource != null) ...[
          CrmSectionHeader(t.crmReportWinBySource,
              hint: t.crmReportWinBySourceHint),
          _rowsCard(bySource,
              (r) => _line(r['source']?.toString() ?? '—',
                  '${bdt(context, r['value'] as num?)} · ${r['count']}')),
          const SizedBox(height: Gap.md),
        ],
        if (leaderboard != null) ...[
          CrmSectionHeader(t.crmReportLeaderboard,
              hint: t.crmReportLeaderboardHint),
          _rowsCard(leaderboard,
              (r) => _line(r['name']?.toString() ?? '—',
                  '${r['activities']} ${t.crmActivitiesCount}')),
          const SizedBox(height: Gap.md),
        ],
        // f6: "booked vs collected" and "renewals" are not modelled on the
        // backend at all, so their placeholder panels are hidden (no
        // showpieces) until a real report exists.
      ]),
    );
  }

  Widget _estimateBadge(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: AssistoTokens.of(context).warning.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.info_outline_rounded, size: 13, color: AssistoTokens.of(context).warning),
        const SizedBox(width: Gap.xs),
        Text(t.crmReportForecastEstimate,
            style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
      ]),
    );
  }

  Widget _notEnough(String lang, Map<String, dynamic> block) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant, size: 18),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Text(lang == 'bn'
            ? (block['message_bn'] ?? t.crmNotEnoughData).toString()
            : (block['message_en'] ?? t.crmNotEnoughData).toString()),
      ),
    ]);
  }

  Widget _unavailable(String message) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.cloud_queue_rounded,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(message,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
        ]),
      ),
    );
  }

  Widget _funnelCard(Map<String, dynamic>? funnel) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (funnel == null) return _unavailable(t.crmReportUnavailable);
    final rows = ((funnel['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (funnel['has_data'] != true || rows.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.crmNotEnoughData,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final maxReached = rows.fold<int>(
        0, (m, r) => ((r['reached'] as num?)?.toInt() ?? 0) > m
            ? ((r['reached'] as num?)?.toInt() ?? 0)
            : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          for (final r in rows)
            FunnelBar(
              stage: r['stage']?.toString() ?? '—',
              reached: (r['reached'] as num?)?.toInt() ?? 0,
              max: maxReached,
              conversionFromPrev:
                  (r['conversion_from_prev'] as num?)?.toDouble(),
            ),
        ]),
      ),
    );
  }

  Widget _cycleCard(Map<String, dynamic>? cycle, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (cycle == null) return _unavailable(t.crmReportUnavailable);
    if (cycle['has_data'] != true) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.crmNotEnoughData,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          _line(t.crmAvgDays, '${cycle['avg_days']} ${t.crmDays}'),
          _line(t.crmSampleSize, '${cycle['sample'] ?? 0}'),
        ]),
      ),
    );
  }

  Widget _rowsCard(
      Map<String, dynamic> block, Widget Function(Map<String, dynamic>) row) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = ((block['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: block['has_data'] == true && rows.isNotEmpty
            ? Column(children: [for (final r in rows) row(r)])
            : Text(t.crmNotEnoughData,
                style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
    );
  }

  Widget _repCard(Map<String, dynamic> block, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final rows = ((block['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (block['has_data'] != true || rows.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.crmNotEnoughData,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          for (final r in rows) _repRow(r, t),
        ]),
      ),
    );
  }

  Widget _repRow(Map<String, dynamic> r, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final attain = (r['attainment_pct'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r['name']?.toString() ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(bdt(context, r['won_value'] as num?),
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: Gap.xxs),
        Text(
          '${t.crmOpen} ${r['open'] ?? 0} · ${t.crmWon} ${r['won'] ?? 0} · ${t.crmLost} ${r['lost'] ?? 0}',
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (attain != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.xs),
                child: LinearProgressIndicator(
                  value: (attain / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                      attain >= 100 ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Text('${t.crmAttainment} $attain%',
                style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxs),
            child: Text(t.crmNoTarget,
                style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }

  // Loss-reason labels come from the server as "bn / en" bilingual strings; pick
  // the right half for the current locale so we never show both languages.
  String _lossLabel(String? raw, String lang) {
    if (raw == null || raw.isEmpty) return '—';
    final parts = raw.split('/');
    if (parts.length == 2) {
      return (lang == 'bn' ? parts[0] : parts[1]).trim();
    }
    return raw.trim();
  }

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}
