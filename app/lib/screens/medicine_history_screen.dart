import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/ladder_common.dart' show fmtInt;

/// Adherence history: overall % + per-medicine weekly bars and streaks.
/// Opened from the caregiver overview; scoped to one person by [member].
class MedicineHistoryScreen extends StatefulWidget {
  final String? member;
  final String? personName;
  const MedicineHistoryScreen({super.key, this.member, this.personName});
  @override
  State<MedicineHistoryScreen> createState() => _MedicineHistoryScreenState();
}

class _MedicineHistoryScreenState extends State<MedicineHistoryScreen> {
  Map<String, dynamic>? data;
  bool loading = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      data = await context.read<AppState>().api.medicineHistory(member: widget.member);
    } catch (_) {
      failed = true;
    }
    if (mounted) setState(() => loading = false);
  }

  Color _pctColor(int pct) {
    if (pct >= 85) return Brand.success;
    if (pct >= 60) return Brand.warning;
    return Brand.danger;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.personName ?? t.medHistoryTitle),
      ),
      body: loading
          ? const SkeletonList(count: 4)
          : failed
              ? StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.medHistoryTitle,
                  message: t.medHistoryEmpty,
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : _body(context, t, scheme),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final meds = (data?['medicines'] as List? ?? []);
    if (meds.isEmpty) {
      return StateMessage(
        icon: Icons.insights_outlined,
        title: t.medHistoryTitle,
        message: t.medHistoryEmpty,
      );
    }
    final overall = (data?['overall'] as num?)?.toInt() ?? 0;
    final taken = (data?['taken'] as num?)?.toInt() ?? 0;
    final scheduled = (data?['scheduled'] as num?)?.toInt() ?? 0;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              _ring(overall),
              const SizedBox(width: Gap.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.medOverallAdherence,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  Text(t.medTakenScheduled(fmtInt(context, taken), fmtInt(context, scheduled)),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        for (final m in meds.cast<Map<String, dynamic>>()) _medCard(context, t, scheme, m),
      ],
    );
  }

  Widget _ring(int pct) {
    final pctStr = fmtInt(context, pct);
    return SizedBox(
      height: 64,
      width: 64,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          height: 64,
          width: 64,
          child: CircularProgressIndicator(
            value: pct / 100.0,
            strokeWidth: 6,
            backgroundColor: _pctColor(pct).withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation(_pctColor(pct)),
          ),
        ),
        Text('$pctStr%', style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _medCard(BuildContext context, AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> m) {
    final pct = (m['adherence_30d'] as num?)?.toInt() ?? 0;
    final streak = (m['streak'] as num?)?.toInt() ?? 0;
    final prn = m['prn'] == true;
    final weeks = (m['weeks'] as List? ?? []).cast<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(m['name'] ?? '',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (prn)
                Chip(label: Text(t.medAsNeededShort), visualDensity: VisualDensity.compact)
              else
                Text('${fmtInt(context, pct)}%',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: _pctColor(pct), fontFeatures: AFonts.tabular)),
            ]),
            if (streak > 0) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                const Icon(Icons.local_fire_department_outlined, size: 16),
                const SizedBox(width: Gap.xs),
                Text(t.medStreakValue(fmtInt(context, streak)),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ],
            if (!prn) ...[
              const SizedBox(height: Gap.md),
              Text(t.medWeeklyHeading,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (int i = 0; i < weeks.length; i++)
                    Expanded(child: _weekBar(context, t, i + 1, weeks[i])),
                ],
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _weekBar(BuildContext context, AppLocalizations t, int n, Map<String, dynamic> w) {
    final pct = (w['pct'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
      child: Column(children: [
        Text('${fmtInt(context, pct)}%', style: AType.labelSmall.copyWith(fontFeatures: AFonts.tabular)),
        const SizedBox(height: Gap.xs),
        Container(
          height: 60,
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: (pct / 100.0).clamp(0.04, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: _pctColor(pct),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
            ),
          ),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.medWeekLabel(fmtInt(context, n)),
            style: AType.labelSmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
