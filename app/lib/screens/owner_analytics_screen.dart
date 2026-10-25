import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../owner_analytics_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/analytics_charts.dart';
import '../widgets/skeleton.dart';

/// Owner Analytics dashboard — ADVANCED (SPEC v2.1 §21, launch gap P15).
///
/// Privacy-friendly product analytics computed entirely on OUR OWN backend
/// (no third-party trackers / SDKs): DAU/WAU/MAU with a trend sparkline,
/// D1/D7/D30 cohort retention, new-user signups trend, invite funnel, the
/// free -> paid conversion funnel drawn as proportional bars, a revenue / plan
/// breakdown, and feature popularity. Everything shown is PII-free aggregate
/// counts — no names, phones or emails are ever displayed, and nothing is
/// fabricated: every number comes straight from the backend payload, with
/// honest "no data yet" and "estimate / unknown" states where the backend
/// cannot give a real figure.
///
/// Date range: the picker filters the backend's OWN dense daily series
/// client-side to a trailing window (All / 7d / 30d / 90d). Cohort/funnel
/// totals are whole-dataset aggregates the backend already computed; the chips
/// scope only the time-series charts, which is stated in the hint so the owner
/// is never misled.
///
/// Export: shares a plain CSV built from the exact numbers on screen (via the
/// system share sheet, Clipboard fallback) — no file I/O, no network, no PII.
///
/// Owner-only: the backend returns 403 for non-staff users; we catch that and
/// show a dedicated "owner only" state instead of a generic error.
class OwnerAnalyticsScreen extends StatefulWidget {
  const OwnerAnalyticsScreen({super.key});

  @override
  State<OwnerAnalyticsScreen> createState() => _OwnerAnalyticsScreenState();
}

enum _Status { loading, ok, error, ownerOnly }

class _OwnerAnalyticsScreenState extends State<OwnerAnalyticsScreen> {
  _Status _status = _Status.loading;
  Map<String, dynamic> _data = const {};

  /// Trailing-window options (days); 0 == "All". Labels come from ARB.
  static const List<int> _rangeDays = [0, 7, 30, 90];
  int _rangeIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final d = await context.read<AppState>().api.ownerAnalyticsDashboard();
      if (!mounted) return;
      setState(() {
        _data = d;
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

  // ---- locale-aware digit helpers (no Bangla literal in source) ----

  /// Bangla-Bengali digits occupy the contiguous block U+09E6 (zero) .. U+09EF
  /// (nine). We build Bangla numerals from code points so no Bangla literal
  /// lives in this .dart (keeps the language gate strict). Latin otherwise.
  String _digits(String latin, String localeName) {
    if (!localeName.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      if (ch >= 0x30 && ch <= 0x39) {
        b.writeCharCode(bnZero + (ch - 0x30));
      } else {
        b.writeCharCode(ch);
      }
    }
    return b.toString();
  }

  String _int(num? v, String localeName) =>
      _digits((v ?? 0).round().toString(), localeName);

  /// A percentage like `42.5%` with locale digits. The `%` sign reads the same
  /// in both languages so it stays as-is.
  String _pct(num? v, String localeName) {
    final n = (v ?? 0).toDouble();
    final s = n == n.roundToDouble()
        ? n.round().toString()
        : n.toStringAsFixed(1);
    return '${_digits(s, localeName)}%';
  }

  Map<String, dynamic> _m(dynamic v) =>
      (v as Map?)?.cast<String, dynamic>() ?? const {};

  /// Apply the selected trailing window to a backend daily series. `days == 0`
  /// means "all". We only ever take a suffix of what the backend sent — never
  /// pad or invent points.
  List<Map<String, dynamic>> _window(List raw) {
    final list = raw.cast<Map<String, dynamic>>();
    final days = _rangeDays[_rangeIndex];
    if (days <= 0 || list.length <= days) return list;
    return list.sublist(list.length - days);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.analyticsTitle),
        actions: [
          if (_status == _Status.ok)
            IconButton(
              tooltip: t.analyticsExport,
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => _export(t),
            ),
        ],
      ),
      body: switch (_status) {
        _Status.loading => const SkeletonList(count: 7),
        _Status.ownerOnly => StateMessage(
            icon: Icons.lock_outline_rounded,
            title: t.analyticsOwnerOnlyTitle,
            message: t.analyticsOwnerOnlyBody,
            tint: Theme.of(context).colorScheme.tertiary,
          ),
        _Status.error => StateMessage(
            icon: Icons.cloud_off_rounded,
            title: t.analyticsErrorTitle,
            message: t.analyticsErrorBody,
            tint: Brand.danger,
            action: FilledButton.tonal(
              onPressed: _load,
              child: Text(t.analyticsRetry),
            ),
          ),
        _Status.ok => _body(context, t),
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final loc = t.localeName;
    final retention = _m(_data['retention']);
    final invites = _m(_data['invites']);
    final funnel = _m(_data['paid_funnel']);
    final active = _m(_data['active']);
    final revenue = _m(_data['revenue']);
    final range = _m(_data['range']);
    final features = ((_data['top_features'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final totalEvents = (_data['total_events'] as num?) ?? 0;

    // Honest empty state: nothing has been recorded yet.
    if (totalEvents == 0 && ((retention['new_users'] as num?) ?? 0) == 0) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: StateMessage(
                icon: Icons.insights_rounded,
                title: t.analyticsEmptyTitle,
                message: t.analyticsEmptyBody,
              ),
            ),
          ],
        ),
      );
    }

    final d1 = _m(retention['d1']);
    final d7 = _m(retention['d7']);
    final d30 = _m(retention['d30']);

    // Backend daily series -> trailing-window TrendPoints for sparklines.
    final activeWin = _window((active['series'] as List?) ?? const []);
    final signupsWin = _window((_data['signups_series'] as List?) ?? const []);
    final activePoints = [
      for (final p in activeWin)
        TrendPoint((p['day'] ?? '').toString(), (p['users'] as num?)?.toInt() ?? 0)
    ];
    final signupPoints = [
      for (final p in signupsWin)
        TrendPoint((p['day'] ?? '').toString(), (p['count'] as num?)?.toInt() ?? 0)
    ];

    final rangeStart = (range['start'] ?? '').toString();
    final rangeEnd = (range['end'] ?? '').toString();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        children: [
          _Header(title: t.analyticsTitle, subtitle: t.analyticsSubtitle),
          const SizedBox(height: Gap.md),

          // Actual data window (honest) + privacy reassurance.
          if (rangeStart.isNotEmpty && rangeEnd.isNotEmpty)
            Text(
              '${t.analyticsDataRange}: '
              '${_digits(rangeStart, loc)} - ${_digits(rangeEnd, loc)}',
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: Gap.md),

          // ---- Date-range picker (scopes the trend charts only) ----
          RangeChips(
            labels: [
              t.analyticsRangeAll,
              t.analyticsRange7d,
              t.analyticsRange30d,
              t.analyticsRange90d,
            ],
            selectedIndex: _rangeIndex,
            onSelected: (i) => setState(() => _rangeIndex = i),
          ),
          const SizedBox(height: Gap.lg),

          // ---- Active users (DAU/WAU/MAU) + trend ----
          _SectionTitle(t.analyticsActiveSection, hint: t.analyticsActiveHint),
          const SizedBox(height: Gap.sm),
          _MetricGrid(cards: [
            _Metric(
              label: t.analyticsDau,
              value: _int(active['dau'] as num?, loc),
              icon: Icons.today_rounded,
            ),
            _Metric(
              label: t.analyticsWau,
              value: _int(active['wau'] as num?, loc),
              icon: Icons.date_range_rounded,
            ),
            _Metric(
              label: t.analyticsMau,
              value: _int(active['mau'] as num?, loc),
              icon: Icons.calendar_month_rounded,
            ),
            _Metric(
              label: t.analyticsNewUsers,
              value: _int(retention['new_users'] as num?, loc),
              icon: Icons.person_add_alt_1_rounded,
            ),
          ]),
          const SizedBox(height: Gap.md),
          _ChartCard(
            title: t.analyticsActiveTrend,
            child: activePoints.where((p) => p.value > 0).isEmpty
                ? _NoChartData(t.analyticsNoTrend)
                : Sparkline(
                    points: activePoints,
                    semanticLabel: t.analyticsActiveTrend,
                  ),
          ),
          const SizedBox(height: Gap.xl),

          // ---- New users / signups trend ----
          _SectionTitle(t.analyticsSignupsSection,
              hint: t.analyticsSignupsHint),
          const SizedBox(height: Gap.sm),
          _ChartCard(
            title: t.analyticsSignupsTrend,
            child: signupPoints.where((p) => p.value > 0).isEmpty
                ? _NoChartData(t.analyticsNoTrend)
                : Sparkline(
                    points: signupPoints,
                    color: Brand.purple,
                    semanticLabel: t.analyticsSignupsTrend,
                  ),
          ),
          const SizedBox(height: Gap.xl),

          // ---- Retention ----
          _SectionTitle(t.analyticsRetentionSection,
              hint: t.analyticsRetentionHint),
          const SizedBox(height: Gap.sm),
          _MetricGrid(cards: [
            _Metric(
              label: t.analyticsRetentionD1,
              value: _pct(d1['pct'] as num?, loc),
              icon: Icons.looks_one_rounded,
            ),
            _Metric(
              label: t.analyticsRetentionD7,
              value: _pct(d7['pct'] as num?, loc),
              icon: Icons.looks_two_rounded,
            ),
            _Metric(
              label: t.analyticsRetentionD30,
              value: _pct(d30['pct'] as num?, loc),
              icon: Icons.filter_3_rounded,
            ),
            _Metric(
              label: t.analyticsRetentionD1Base,
              value: _int(d1['eligible'] as num?, loc),
              icon: Icons.groups_rounded,
            ),
          ]),
          const SizedBox(height: Gap.xl),

          // ---- Invites ----
          _SectionTitle(t.analyticsInvitesSection),
          const SizedBox(height: Gap.sm),
          _MetricGrid(cards: [
            _Metric(
              label: t.analyticsInvitesSent,
              value: _int(invites['sent'] as num?, loc),
              icon: Icons.send_rounded,
            ),
            _Metric(
              label: t.analyticsInvitesAccepted,
              value: _int(invites['accepted'] as num?, loc),
              icon: Icons.how_to_reg_rounded,
            ),
            _Metric(
              label: t.analyticsInvitesRate,
              value: _pct(invites['accept_rate_pct'] as num?, loc),
              icon: Icons.percent_rounded,
            ),
          ]),
          const SizedBox(height: Gap.xl),

          // ---- Free -> paid funnel (bars) ----
          _SectionTitle(t.analyticsFunnelSection, hint: t.analyticsFunnelHint),
          const SizedBox(height: Gap.md),
          _ChartCard(
            child: FunnelBars(
              stages: [
                FunnelStage(
                  t.analyticsFunnelViewed,
                  (funnel['viewed'] as num?)?.toInt() ?? 0,
                  _int(funnel['viewed'] as num?, loc),
                ),
                FunnelStage(
                  t.analyticsFunnelStarted,
                  (funnel['started'] as num?)?.toInt() ?? 0,
                  _int(funnel['started'] as num?, loc),
                ),
                FunnelStage(
                  t.analyticsFunnelCompleted,
                  (funnel['completed'] as num?)?.toInt() ?? 0,
                  _int(funnel['completed'] as num?, loc),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(
            '${t.analyticsViewToPaid}: '
            '${_pct(funnel['view_to_paid_pct'] as num?, loc)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: Gap.xl),

          // ---- Revenue / plan breakdown (honest: estimate when unknown) ----
          _SectionTitle(t.analyticsRevenueSection,
              hint: t.analyticsRevenueHint),
          const SizedBox(height: Gap.sm),
          _revenueBlock(context, t, loc, revenue),
          const SizedBox(height: Gap.xl),

          // ---- Top features (privacy-safe popularity, no PII) ----
          if (features.isNotEmpty) ...[
            _SectionTitle(t.analyticsFeaturesSection,
                hint: t.analyticsFeaturesHint),
            const SizedBox(height: Gap.sm),
            for (final f in features)
              _FeatureRow(
                feature: (f['feature'] ?? '').toString(),
                trailing:
                    '${_int(f['users'] as num?, loc)} ${t.analyticsFeatureUsers}',
              ),
            const SizedBox(height: Gap.xl),
          ],

          // ---- Footer: total events + privacy note ----
          Center(
            child: Text(
              '${t.analyticsTotalEvents}: ${_int(totalEvents, loc)}',
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _revenueBlock(BuildContext context, AppLocalizations t, String loc,
      Map<String, dynamic> revenue) {
    final plans = ((revenue['plans'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final totalPaid = (revenue['total_paid_users'] as num?) ?? 0;
    final known = (revenue['revenue_known'] as bool?) ?? false;
    final totalRevenue = revenue['total_revenue'] as num?;

    if (plans.isEmpty || totalPaid == 0) {
      return _ChartCard(child: _NoChartData(t.analyticsNoRevenue));
    }

    return _ChartCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Total paid users is always a real count.
          Row(
            children: [
              Icon(Icons.workspace_premium_rounded,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Gap.sm),
              Text(
                '${t.analyticsPaidUsers}: ${_int(totalPaid, loc)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          // Revenue: only shown as a figure when the backend has real prices;
          // otherwise an honest "estimate unavailable" note (never fabricated).
          if (known && totalRevenue != null)
            Text(
              '${t.analyticsRevenueTotal}: ${_int(totalRevenue, loc)}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular),
            )
          else
            _EstimateBadge(text: t.analyticsRevenueUnknown),
          const SizedBox(height: Gap.md),
          PlanBreakdownBar(
            slices: [
              for (final p in plans)
                PlanSlice(
                  (p['plan'] ?? '').toString(),
                  (p['paid_users'] as num?)?.toInt() ?? 0,
                  _int(p['paid_users'] as num?, loc),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- CSV export (plain text via share sheet; Clipboard fallback) ----

  Future<void> _export(AppLocalizations t) async {
    final loc = t.localeName; // export numerals match the UI locale
    final retention = _m(_data['retention']);
    final invites = _m(_data['invites']);
    final funnel = _m(_data['paid_funnel']);
    final active = _m(_data['active']);
    final revenue = _m(_data['revenue']);
    final features = ((_data['top_features'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    String n(num? v) => _int(v, loc);
    String p(num? v) => _pct(v, loc);

    final rows = <List<String>>[
      [t.analyticsCsvMetric, t.analyticsCsvValue],
      [t.analyticsDau, n(active['dau'] as num?)],
      [t.analyticsWau, n(active['wau'] as num?)],
      [t.analyticsMau, n(active['mau'] as num?)],
      [t.analyticsNewUsers, n(retention['new_users'] as num?)],
      [t.analyticsRetentionD1, p(_m(retention['d1'])['pct'] as num?)],
      [t.analyticsRetentionD7, p(_m(retention['d7'])['pct'] as num?)],
      [t.analyticsRetentionD30, p(_m(retention['d30'])['pct'] as num?)],
      [t.analyticsInvitesSent, n(invites['sent'] as num?)],
      [t.analyticsInvitesAccepted, n(invites['accepted'] as num?)],
      [t.analyticsInvitesRate, p(invites['accept_rate_pct'] as num?)],
      [t.analyticsFunnelViewed, n(funnel['viewed'] as num?)],
      [t.analyticsFunnelStarted, n(funnel['started'] as num?)],
      [t.analyticsFunnelCompleted, n(funnel['completed'] as num?)],
      [t.analyticsViewToPaid, p(funnel['view_to_paid_pct'] as num?)],
      [t.analyticsPaidUsers, n(revenue['total_paid_users'] as num?)],
      [
        t.analyticsRevenueTotal,
        ((revenue['revenue_known'] as bool?) ?? false)
            ? n(revenue['total_revenue'] as num?)
            : t.analyticsRevenueUnknown,
      ],
      for (final f in features)
        ['${t.analyticsFeaturesSection}: ${(f['feature'] ?? '')}',
         n(f['users'] as num?)],
    ];

    String esc(String s) =>
        s.contains(',') || s.contains('"') || s.contains('\n')
            ? '"${s.replaceAll('"', '""')}"'
            : s;
    final csv =
        rows.map((r) => r.map(esc).join(',')).join('\n');

    try {
      await Share.share(csv, subject: t.analyticsTitle);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.analyticsExportCopied)),
      );
    }
  }
}

/// A card wrapper for charts, with an optional title row.
class _ChartCard extends StatelessWidget {
  final String? title;
  final Widget child;
  const _ChartCard({this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
          ],
          child,
        ],
      ),
    );
  }
}

/// Honest "no trend data in this window" placeholder.
class _NoChartData extends StatelessWidget {
  final String text;
  const _NoChartData(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: Gap.xxxl,
      child: Row(
        children: [
          Icon(Icons.timeline_rounded,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(text,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// Small "estimate / unknown" badge so an unpriced revenue never looks like a
/// real figure.
class _EstimateBadge extends StatelessWidget {
  final String text;
  const _EstimateBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline_rounded, size: 14, color: Brand.warning),
          const SizedBox(width: Gap.xs),
          Flexible(
            child: Text(text,
                style: AType.bodySmall.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Brand-gradient header band (chat-first hero surface), matching the hub
/// screens. Uses onPrimary-ish text on the gradient for WCAG contrast.
class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  const _Header({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.lg),
      decoration: const BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(Radii.lg)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.insights_rounded, color: Colors.white),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                title,
                style: AType.titleLarge.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
              ),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? hint;
  const _SectionTitle(this.title, {this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (hint != null) ...[
          const SizedBox(height: Gap.xxs),
          Text(
            hint!,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Responsive grid of metric cards (two columns on phones, more on wide).
class _MetricGrid extends StatelessWidget {
  final List<_Metric> cards;
  const _MetricGrid({required this.cards});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cols = w >= 720 ? 4 : 2;
    return GridView.count(
      crossAxisCount: cols,
      mainAxisSpacing: Gap.md,
      crossAxisSpacing: Gap.md,
      // qa1: taller tiles at large font (fixed ratio overflowed at 2.0x)
      childAspectRatio:
          1.55 / MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.9),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cards,
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: Gap.xxs),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.2),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String feature;
  final String trailing;
  const _FeatureRow({required this.feature, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(
              feature,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            trailing,
            style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
