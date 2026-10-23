import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/ladder_common.dart' show fmtInt, taka;

/// OWNER P&L DASHBOARD (Business Model Build 3, item 5) — owner-only.
///
/// Renders `GET /admin/pnl?days=N`:
///   {series:[{day, revenue, cost, ...}], totals:{revenue, cost, profit, ...},
///    segments:[{plan/feature, revenue, cost, margin}],
///    margin_per_feature:[...], break_even:{users_needed, ad_rev_per_day, ...},
///    guard:{state, ...}, alerts:[{level, message}]}.
///
/// Money is integer POISHA (same convention as the rest of the app) rendered
/// via [taka]. The entry point is pre-gated behind the same owner probe the
/// admin console uses; the backend also returns 403, surfaced as the owner-only
/// state. HONEST empty state when there's no data yet. All copy via ARB.
class OwnerPnlScreen extends StatefulWidget {
  const OwnerPnlScreen({super.key});
  @override
  State<OwnerPnlScreen> createState() => _OwnerPnlScreenState();
}

enum _Status { loading, ok, error, ownerOnly }

class _OwnerPnlScreenState extends State<OwnerPnlScreen> {
  _Status _status = _Status.loading;
  Map<String, dynamic> _data = const {};
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final r = await context.read<AppState>().api.adminPnl(days: _days);
      if (!mounted) return;
      setState(() {
        _data = r;
        _status = _Status.ok;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() =>
          _status = e.status == 403 ? _Status.ownerOnly : _Status.error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _Status.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.pnlTitle),
        actions: [
          if (_status == _Status.ok)
            IconButton(
                tooltip: t.refresh,
                icon: const Icon(Icons.refresh),
                onPressed: _load),
        ],
      ),
      body: switch (_status) {
        _Status.loading => const SkeletonList(),
        _Status.ownerOnly => StateMessage(
            icon: Icons.admin_panel_settings_outlined,
            title: t.pnlOwnerOnlyTitle,
            message: t.pnlOwnerOnlyBody,
            tint: Brand.warning,
          ),
        _Status.error => StateMessage(
            icon: Icons.cloud_off_outlined,
            title: t.loadFailed,
            message: t.loadFailedBody,
            tint: Brand.danger,
            action: FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(t.retry)),
          ),
        _Status.ok => _body(t),
      },
    );
  }

  Widget _body(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final series = (_data['series'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final totals = (_data['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final segments = (_data['segments'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final margins = (_data['margin_per_feature'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final breakEven =
        (_data['break_even'] as Map?)?.cast<String, dynamic>() ?? const {};
    final guard = (_data['guard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alerts = (_data['alerts'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

    final hasData = series.isNotEmpty || totals.isNotEmpty;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          _rangeToggle(t, scheme),
          const SizedBox(height: Gap.md),
          if (!hasData)
            StateMessage(
              icon: Icons.insights_outlined,
              title: t.pnlEmptyTitle,
              message: t.pnlEmptyBody,
            )
          else ...[
            _guardBanner(t, scheme, guard),
            for (final a in alerts) _alertRow(t, scheme, a),
            const SizedBox(height: Gap.md),
            _totalsCard(t, totals),
            const SizedBox(height: Gap.lg),
            if (series.isNotEmpty) ...[
              _sectionTitle(t.pnlDailyTitle, Icons.show_chart, scheme),
              const SizedBox(height: Gap.sm),
              _chart(scheme, series),
              const SizedBox(height: Gap.lg),
            ],
            _breakEvenCard(t, scheme, breakEven),
            if (segments.isNotEmpty) ...[
              const SizedBox(height: Gap.lg),
              _sectionTitle(t.pnlSegmentsTitle, Icons.pie_chart_outline, scheme),
              const SizedBox(height: Gap.sm),
              for (final s in segments) _marginRow(t, scheme, s, isSegment: true),
            ],
            if (margins.isNotEmpty) ...[
              const SizedBox(height: Gap.lg),
              _sectionTitle(t.pnlMarginTitle, Icons.bar_chart, scheme),
              const SizedBox(height: Gap.sm),
              for (final m in margins) _marginRow(t, scheme, m),
            ],
            // ps1-photo: Photo Studio ad revenue vs cost, per feature
            const SizedBox(height: Gap.lg),
            _sectionTitle(t.psOwnerPnlTitle, Icons.auto_awesome_outlined, scheme),
            const SizedBox(height: Gap.sm),
            ..._photoStudioRows(t, scheme),
          ],
        ],
      ),
    );
  }

  Widget _rangeToggle(AppLocalizations t, ColorScheme scheme) {
    const seg = TextStyle(fontSize: 12);
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: 7, label: Text(t.pnlRange7(fmtInt(context, 7)), style: seg)),
        ButtonSegment(value: 30, label: Text(t.pnlRange30(fmtInt(context, 30)), style: seg)),
        ButtonSegment(value: 90, label: Text(t.pnlRange90(fmtInt(context, 90)), style: seg)),
      ],
      selected: {_days},
      onSelectionChanged: (s) {
        setState(() => _days = s.first);
        _load();
      },
    );
  }

  Widget _guardBanner(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> guard) {
    if (guard.isEmpty) return const SizedBox.shrink();
    final state = (guard['state'] ?? 'ok').toString();
    final (tint, icon, title) = switch (state) {
      'alarm' || 'loss' || 'critical' => (
          Brand.danger,
          Icons.error_outline,
          t.pnlGuardLoss
        ),
      'warn' || 'thin' => (
          Brand.warning,
          Icons.warning_amber_outlined,
          t.pnlGuardThin
        ),
      _ => (Brand.success, Icons.verified_outlined, t.pnlGuardHealthy),
    };
    final msg = (guard['message'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (msg.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(msg,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _alertRow(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> a) {
    final level = (a['level'] ?? 'info').toString();
    final tint = level == 'critical' || level == 'error'
        ? Brand.danger
        : (level == 'warn' || level == 'warning'
            ? Brand.warning
            : scheme.primary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.circle, size: 9, color: tint),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text((a['message'] ?? '').toString(),
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface))),
      ]),
    );
  }

  Widget _totalsCard(AppLocalizations t, Map<String, dynamic> totals) {
    final rev = _int(totals['revenue']);
    final cost = _int(totals['cost']);
    final profit = totals['profit'] is num
        ? _int(totals['profit'])
        : (rev - cost);
    final profitPositive = profit >= 0;
    return Container(
      decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg)),
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.pnlRangeTotals(fmtInt(context, _days)),
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: Gap.sm),
        Row(children: [
          _totalCell(t.pnlRevenue, taka(context, rev), Colors.white),
          _totalCell(t.pnlCost, taka(context, cost), Colors.white),
          _totalCell(
              t.pnlProfit,
              '${profitPositive ? '' : '-'}${taka(context, profit.abs())}',
              profitPositive ? Colors.white : const Color(0xFFFFD2D7)),
        ]),
      ]),
    );
  }

  Widget _totalCell(String label, String value, Color valueColor) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
        ]),
      );

  /// A lightweight dual bar chart (revenue vs cost per day) — no chart package.
  Widget _chart(ColorScheme scheme, List<Map<String, dynamic>> series) {
    // Keep it readable: show the most recent ~14 points.
    final pts = series.length > 14
        ? series.sublist(series.length - 14)
        : series;
    int maxV = 1;
    for (final p in pts) {
      maxV = [maxV, _int(p['revenue']), _int(p['cost'])]
          .reduce((a, b) => a > b ? a : b);
    }
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(children: [
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final p in pts)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                  child: _bar(_int(p['revenue']) / maxV,
                                      scheme.primary)),
                              const SizedBox(width: 2),
                              Expanded(
                                  child: _bar(
                                      _int(p['cost']) / maxV, Brand.warning)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Gap.sm),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _legend(scheme.primary, AppLocalizations.of(context).pnlRevenue),
          const SizedBox(width: Gap.lg),
          _legend(Brand.warning, AppLocalizations.of(context).pnlCost),
        ]),
      ]),
    );
  }

  Widget _bar(double frac, Color color) => FractionallySizedBox(
        heightFactor: frac.clamp(0.02, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ),
      );

  Widget _legend(Color color, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, color: color),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      );

  Widget _breakEvenCard(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> be) {
    if (be.isEmpty) return const SizedBox.shrink();
    final users = _int(be['users_needed'] ?? be['more_paid_users']);
    final adRev = _int(be['ad_rev_per_day'] ?? be['ad_revenue_per_day_needed']);
    final atBreakEven = be['at_break_even'] == true ||
        (users <= 0 && adRev <= 0);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.flag_outlined, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.pnlBreakEvenTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              atBreakEven
                  ? t.pnlBreakEvenReached
                  : t.pnlBreakEvenBody( // (adrev, users) per signature
                      taka(context, adRev), fmtInt(context, users)),
              style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                  height: 1.35),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _marginRow(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> m,
      {bool isSegment = false}) {
    final name = (m['feature'] ?? m['plan'] ?? m['name'] ?? '').toString();
    final rev = _int(m['revenue']);
    final cost = _int(m['cost']);
    final margin = m['margin'] is num
        ? _int(m['margin'])
        : (rev - cost);
    final positive = margin >= 0;
    final pct = rev > 0 ? (margin / rev) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text(
              '${positive ? '' : '-'}${taka(context, margin.abs())}'
              '${pct != null ? ' (${fmtInt(context, (pct * 100).round())}%)' : ''}',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: positive ? Brand.success : Brand.danger),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            t.pnlRevCost(taka(context, cost), taka(context, rev)), // (cost, rev)
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  // ps1-photo
  String _psFeature(AppLocalizations t, String f) => switch (f) {
        'enhance_hd' => t.psOwnerFeatEnhanceHd,
        'enhance_cloud' => t.psOwnerFeatEnhanceCloud,
        'prompt_edit' => t.psOwnerFeatPrompt,
        'generate' => t.psOwnerFeatGenerate,
        'entry' => t.psOwnerFeatEntry,
        'deblur' => t.d1psFeatDeblur,
        'colorize' => t.d1psFeatColorize,
        'old_restore' => t.d1psFeatOldRestore,
        _ => f,
      };

  List<Widget> _photoStudioRows(AppLocalizations t, ColorScheme scheme) {
    final ps = (_data['photo_studio'] as Map?)?.cast<String, dynamic>() ?? const {};
    final feats = (ps['features'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    if (feats.isEmpty) {
      return [
        Text(t.psOwnerEmpty, style: TextStyle(color: scheme.onSurfaceVariant)),
      ];
    }
    return [
      for (final f in feats)
        _marginRow(t, scheme, {
          'feature': _psFeature(t, '${f['feature'] ?? ''}'),
          'revenue': f['revenue'],
          'cost': f['cost'],
          'margin': f['margin'],
        }),
    ];
  }

  Widget _sectionTitle(String text, IconData icon, ColorScheme scheme) => Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(text,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ],
      );
}
