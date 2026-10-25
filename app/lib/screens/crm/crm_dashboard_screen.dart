import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/ladder_common.dart';
import 'crm_common.dart';

/// Dashboard (CRM_SPEC): pipeline value, weighted forecast WITH its method
/// shown, win/loss, by industry, by salesperson. Thin data shows a clear
/// "Not enough data" state instead of a misleading number.
class CrmDashboardScreen extends StatefulWidget {
  final int org;
  const CrmDashboardScreen({super.key, required this.org});
  @override
  State<CrmDashboardScreen> createState() => _CrmDashboardScreenState();
}

class _CrmDashboardScreenState extends State<CrmDashboardScreen> {
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
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final d = _d ?? {};
    // Salesperson: the backend returns a clean restricted payload (no profit/
    // forecast). Show a friendly panel, not an empty/broken dashboard.
    if (d['restricted'] == true) {
      final lang = Localizations.localeOf(context).languageCode;
      return CrmStateView.empty(
        icon: Icons.lock_outline_rounded,
        title: t.crmDashboardRestricted,
        message: lang == 'bn'
            ? (d['message_bn'] ?? t.crmDashboardRestrictedHint).toString()
            : (d['message_en'] ?? t.crmDashboardRestrictedHint).toString(),
      );
    }
    final forecast = (d['forecast'] as Map?)?.cast<String, dynamic>() ?? {};
    final winLoss = (d['win_loss'] as Map?)?.cast<String, dynamic>() ?? {};
    final byInd = (d['by_industry'] as Map?)?.cast<String, dynamic>() ?? {};
    final byRep = (d['by_salesperson'] as Map?)?.cast<String, dynamic>() ?? {};
    final lang = Localizations.localeOf(context).languageCode;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        Row(children: [
          Expanded(child: _metric(t.crmPipelineValue, bdt(context, d['pipeline_value'] as num?), Icons.account_tree_rounded)),
          const SizedBox(width: Gap.sm),
          Expanded(child: _metric(t.crmWonValue, bdt(context, d['won_value'] as num?), Icons.emoji_events_rounded)),
        ]),
        const SizedBox(height: Gap.md),
        // ---- weighted forecast with method shown ----
        _sectionTitle(t.crmWeightedForecast),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: forecast['has_data'] == true
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bdt(context, forecast['weighted'] as num?), style: AType.headlineMedium.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: Gap.xs),
                    _line(t.crmBestCase, bdt(context, forecast['best_case'] as num?)),
                    _line(t.crmCommit, bdt(context, forecast['commit'] as num?)),
                    _line(t.crmOpenDeals, fmtInt(context, (forecast['open_count'] as num?)?.toInt() ?? 0)),
                    const SizedBox(height: Gap.xs),
                    // the formula is fixed server-side; show it in the user's
                    // language (the server's text is English-only)
                    Text('${t.crmMethod}: ${t.shopQaForecastMethod}',
                        style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
                  ])
                : Row(children: [
                    Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant, size: 18),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text(lang == 'bn'
                        ? (forecast['message_bn'] ?? t.crmNotEnoughData).toString()
                        : (forecast['message_en'] ?? t.crmNotEnoughData).toString())),
                  ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        // ---- win / loss ----
        _sectionTitle(t.crmWinLoss),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: winLoss['has_data'] == true
                ? Column(children: [
                    _line(t.shopQaWon, fmtInt(context, (winLoss['won'] as num?)?.toInt() ?? 0)),
                    _line(t.crmMarkLost, fmtInt(context, (winLoss['lost'] as num?)?.toInt() ?? 0)),
                    _line(t.crmWinRate, winLoss['win_rate'] == null ? '—' : '${fmtInt(context, (winLoss['win_rate'] as num).toInt())}%'),
                  ])
                : Text(t.crmNotEnoughData, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ),
        const SizedBox(height: Gap.md),
        // ---- by industry ----
        _sectionTitle(t.crmByIndustry),
        _rows(byInd, (r) => _line(_industryLabel(t, r['industry']?.toString()), '${bdt(context, r['value'] as num?)} · ${fmtInt(context, (r['count'] as num?)?.toInt() ?? 0)}'), t),
        const SizedBox(height: Gap.md),
        // ---- by salesperson ----
        _sectionTitle(t.crmBySalesperson),
        _rows(byRep, (r) => _line(r['name']?.toString() ?? '—', '${t.shopQaWon} ${fmtInt(context, (r['won'] as num?)?.toInt() ?? 0)} · ${bdt(context, r['won_value'] as num?)}'), t),
      ]),
    );
  }

  Widget _rows(Map<String, dynamic> block, Widget Function(Map<String, dynamic>) row, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final rows = ((block['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: block['has_data'] == true && rows.isNotEmpty
            ? Column(children: [for (final r in rows) row(r)])
            : Text(t.crmNotEnoughData, style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
    );
  }

  Widget _metric(String label, String value, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(height: Gap.xs),
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800), maxLines: 1)),
          Text(label, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  String _industryLabel(AppLocalizations t, String? code) =>
      crmIndustryLabel(t, code);

  // Swap symbols the app font lacks (render as tofu boxes) for safe ASCII:
  // sigma U+03A3 -> 'Sum ', multiplication sign U+00D7 -> 'x'.
}
