import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
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
        icon: Icons.lock_outline,
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
          Expanded(child: _metric(t.crmPipelineValue, bdt(d['pipeline_value'] as num?), Icons.account_tree_outlined)),
          const SizedBox(width: Gap.sm),
          Expanded(child: _metric(t.crmWonValue, bdt(d['won_value'] as num?), Icons.emoji_events_outlined)),
        ]),
        const SizedBox(height: Gap.md),
        // ---- weighted forecast with method shown ----
        _sectionTitle(t.crmWeightedForecast),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: forecast['has_data'] == true
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bdt(forecast['weighted'] as num?), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                    const SizedBox(height: Gap.xs),
                    _line(t.crmBestCase, bdt(forecast['best_case'] as num?)),
                    _line(t.crmCommit, bdt(forecast['commit'] as num?)),
                    _line(t.crmOpenDeals, '${forecast['open_count'] ?? 0}'),
                    const SizedBox(height: Gap.xs),
                    Text('${t.crmMethod}: ${_safeMethod(forecast['method'])}',
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ])
                : Row(children: [
                    Icon(Icons.info_outline, color: scheme.onSurfaceVariant, size: 18),
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
                    _line(t.crmMarkWon, '${winLoss['won'] ?? 0}'),
                    _line(t.crmMarkLost, '${winLoss['lost'] ?? 0}'),
                    _line(t.crmWinRate, winLoss['win_rate'] == null ? '—' : '${winLoss['win_rate']}%'),
                  ])
                : Text(t.crmNotEnoughData, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ),
        const SizedBox(height: Gap.md),
        // ---- by industry ----
        _sectionTitle(t.crmByIndustry),
        _rows(byInd, (r) => _line(_industryLabel(t, r['industry']?.toString()), '${bdt(r['value'] as num?)} · ${r['count']}'), t),
        const SizedBox(height: Gap.md),
        // ---- by salesperson ----
        _sectionTitle(t.crmBySalesperson),
        _rows(byRep, (r) => _line(r['name']?.toString() ?? '—', '${t.crmMarkWon} ${r['won']} · ${bdt(r['won_value'] as num?)}'), t),
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
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  // The backend's by_industry rows carry the raw industry CODE (rmg/pharma/…).
  // Map known codes to their proper labels (matches crm_firstrun) and title-
  // case anything unexpected, so nothing renders as a bare lowercase token.
  String _industryLabel(AppLocalizations t, String? code) {
    switch (code) {
      case 'rmg':
        return t.crmIndRmg;
      case 'pharma':
        return t.crmIndPharma;
      case 'retail':
        return t.crmIndRetail;
      case 'it':
        return t.crmIndIt;
      case 'manufacturing':
        return t.crmIndManufacturing;
      case 'services':
        return t.crmIndServices;
      case 'other':
        return t.crmIndOther;
      default:
        final c = (code ?? '').trim();
        if (c.isEmpty) return '—';
        return c[0].toUpperCase() + c.substring(1);
    }
  }

  // Swap symbols the app font lacks (render as tofu boxes) for safe ASCII:
  // sigma U+03A3 -> 'Sum ', multiplication sign U+00D7 -> 'x'.
  String _safeMethod(Object? raw) => (raw ?? '')
      .toString()
      .replaceAll('\u03A3', 'Sum ')
      .replaceAll('\u00D7', 'x');
}
