import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../owner_analytics_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Owner Analytics dashboard (launch gap P15).
///
/// Privacy-friendly product analytics computed entirely on OUR OWN backend
/// (no third-party trackers / SDKs): D1/D7/D30 cohort retention, invite funnel,
/// free -> paid conversion funnel and feature usage. Everything shown here is
/// PII-free aggregate counts — no names, phones or emails are ever displayed.
///
/// Owner-only: the backend returns 403 for non-staff users; we catch that and
/// show a dedicated "owner only" state instead of a generic error.
///
/// Chat-first design tokens: brand-gradient header band, metric cards on
/// Gap/Radii spacing, SkeletonList while loading, StateMessage for
/// empty/error/owner-only. All strings come from AppLocalizations.
class OwnerAnalyticsScreen extends StatefulWidget {
  const OwnerAnalyticsScreen({super.key});

  @override
  State<OwnerAnalyticsScreen> createState() => _OwnerAnalyticsScreenState();
}

enum _Status { loading, ok, error, ownerOnly }

class _OwnerAnalyticsScreenState extends State<OwnerAnalyticsScreen> {
  _Status _status = _Status.loading;
  Map<String, dynamic> _data = const {};

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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.analyticsTitle)),
      body: switch (_status) {
        _Status.loading => const SkeletonList(count: 7),
        _Status.ownerOnly => StateMessage(
            icon: Icons.lock_outline,
            title: t.analyticsOwnerOnlyTitle,
            message: t.analyticsOwnerOnlyBody,
            tint: Theme.of(context).colorScheme.tertiary,
          ),
        _Status.error => StateMessage(
            icon: Icons.cloud_off_outlined,
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
    final retention = (_data['retention'] as Map?) ?? const {};
    final invites = (_data['invites'] as Map?) ?? const {};
    final funnel = (_data['paid_funnel'] as Map?) ?? const {};
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
                icon: Icons.insights_outlined,
                title: t.analyticsEmptyTitle,
                message: t.analyticsEmptyBody,
              ),
            ),
          ],
        ),
      );
    }

    Map<String, dynamic> m(dynamic v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
    final d1 = m(retention['d1']);
    final d7 = m(retention['d7']);
    final d30 = m(retention['d30']);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        children: [
          _Header(title: t.analyticsTitle, subtitle: t.analyticsSubtitle),
          const SizedBox(height: Gap.lg),

          // ---- Retention ----
          _SectionTitle(t.analyticsRetentionSection, hint: t.analyticsRetentionHint),
          const SizedBox(height: Gap.sm),
          _MetricGrid(cards: [
            _Metric(
              label: t.analyticsRetentionD1,
              value: _pct(d1['pct'] as num?, loc),
              icon: Icons.looks_one_outlined,
            ),
            _Metric(
              label: t.analyticsRetentionD7,
              value: _pct(d7['pct'] as num?, loc),
              icon: Icons.looks_two_outlined,
            ),
            _Metric(
              label: t.analyticsRetentionD30,
              value: _pct(d30['pct'] as num?, loc),
              icon: Icons.calendar_month_outlined,
            ),
            _Metric(
              label: t.analyticsNewUsers,
              value: _int(retention['new_users'] as num?, loc),
              icon: Icons.person_add_alt_1_outlined,
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
              icon: Icons.send_outlined,
            ),
            _Metric(
              label: t.analyticsInvitesAccepted,
              value: _int(invites['accepted'] as num?, loc),
              icon: Icons.how_to_reg_outlined,
            ),
            _Metric(
              label: t.analyticsInvitesRate,
              value: _pct(invites['accept_rate_pct'] as num?, loc),
              icon: Icons.percent_outlined,
            ),
          ]),
          const SizedBox(height: Gap.xl),

          // ---- Free -> paid funnel ----
          _SectionTitle(t.analyticsFunnelSection, hint: t.analyticsFunnelHint),
          const SizedBox(height: Gap.sm),
          _MetricGrid(cards: [
            _Metric(
              label: t.analyticsFunnelViewed,
              value: _int(funnel['viewed'] as num?, loc),
              icon: Icons.visibility_outlined,
            ),
            _Metric(
              label: t.analyticsFunnelStarted,
              value: _int(funnel['started'] as num?, loc),
              icon: Icons.upgrade_outlined,
            ),
            _Metric(
              label: t.analyticsFunnelCompleted,
              value: _int(funnel['completed'] as num?, loc),
              icon: Icons.workspace_premium_outlined,
            ),
            _Metric(
              label: t.analyticsViewToPaid,
              value: _pct(funnel['view_to_paid_pct'] as num?, loc),
              icon: Icons.trending_up_outlined,
            ),
          ]),
          const SizedBox(height: Gap.xl),

          // ---- Top features (privacy-safe popularity, no PII) ----
          if (features.isNotEmpty) ...[
            _SectionTitle(t.analyticsFeaturesSection, hint: t.analyticsFeaturesHint),
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
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
            const Icon(Icons.insights, color: Colors.white),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
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
          const SizedBox(height: 2),
          Text(
            hint!,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
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
      childAspectRatio: 1.55,
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
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.2,
            ),
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
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
