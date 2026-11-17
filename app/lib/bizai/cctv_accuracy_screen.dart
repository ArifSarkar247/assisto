import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText;
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/business_ui.dart';
import '../widgets/skeleton.dart';
import '../widgets/subs_common.dart' show fmtInt;

/// bizai pillar 4 — server seam (backend/core/views_bizai.py Cctv*View).
abstract class CctvAccuracySource {
  Future<Map<String, dynamic>> accuracy(int? siteId);
  Future<Map<String, dynamic>> startTest(int siteId);
  Future<Map<String, dynamic>> mark(int testId, String kind);
  Future<Map<String, dynamic>> stop(int testId);
  Future<void> missed(int siteId, String kind);
}

class ApiCctvAccuracySource implements CctvAccuracySource {
  final ApiClient api;
  ApiCctvAccuracySource(this.api);
  @override
  Future<Map<String, dynamic>> accuracy(int? siteId) =>
      api.getJson('/bizai/cctv/accuracy${siteId == null ? '' : '?site=$siteId'}');
  @override
  Future<Map<String, dynamic>> startTest(int siteId) =>
      api.postJson('/bizai/cctv/test', {'site': siteId});
  @override
  Future<Map<String, dynamic>> mark(int testId, String kind) =>
      api.postJson('/bizai/cctv/test/$testId/mark', {'kind': kind});
  @override
  Future<Map<String, dynamic>> stop(int testId) => api.postJson('/bizai/cctv/test/$testId/stop');
  @override
  Future<void> missed(int siteId, String kind) =>
      api.postJson('/bizai/cctv/missed', {'site': siteId, 'kind': kind});
}

/// bizai — "How accurate is my CCTV?": measured precision ("when it rings,
/// is it right?") and recall ("when it happens, does it ring?") per kind,
/// from your Correct/Wrong reviews, "it happened but no alert" reports and
/// live tests in front of the real camera. Below 20 events it says "not
/// enough yet" — never a made-up percentage.
class CctvAccuracyScreen extends StatefulWidget {
  final int? siteId;
  final CctvAccuracySource? source;
  const CctvAccuracyScreen({super.key, this.siteId, this.source});
  @override
  State<CctvAccuracyScreen> createState() => _CctvAccuracyScreenState();
}

class _CctvAccuracyScreenState extends State<CctvAccuracyScreen> {
  late final CctvAccuracySource _src =
      widget.source ?? ApiCctvAccuracySource(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  Object? _error;
  int? _testId;
  int _marks = 0;
  bool _busy = false;

  static const _kinds = ['person', 'line', 'zone', 'loiter', 'cash', 'camera'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _src.accuracy(widget.siteId);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _kind(AppLocalizations t, String k) => switch (k) {
        'person' => t.bizaiCamPerson,
        'line' => t.bizaiCamLine,
        'zone' => t.bizaiCamZone,
        'loiter' => t.bizaiCamLoiter,
        'cash' => t.bizaiCamCash,
        _ => t.bizaiCamHealth,
      };

  String _pct(BuildContext c, Object? v) =>
      v is num ? '${fmtInt(c, (v * 100).round())}%' : '—';

  Future<void> _do(Future<void> Function() f) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.bizaiCamTitle)), body: _body(t));
  }

  Widget _table(AppLocalizations t, Map per) {
    if (per.isEmpty) return Text(t.bizaiCamNoData);
    return Column(children: [
      for (final e in per.entries)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_kind(t, '${e.key}')),
          subtitle: Text(t.bizaiCamLine2(
              _pct(context, (e.value as Map)['precision']),
              _pct(context, (e.value as Map)['recall']),
              fmtInt(context, ((e.value as Map)['events'] as num?)?.toInt() ?? 0))),
          trailing: (e.value as Map)['meets_target'] == true
              ? Icon(Icons.verified_rounded,
                  color: AssistoTokens.of(context).success, semanticLabel: t.bizaiCamMeets)
              : Text((e.value as Map)['enough'] == true ? t.bizaiCamBelow : t.bizaiCamNotEnough),
        ),
    ]);
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final d = _d;
    if (d == null) return const SkeletonList();
    final rev = (d['reviews'] as Map?) ?? const {};
    final live = (d['live_tests'] as Map?) ?? const {};
    final site = widget.siteId;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        // page rule: the live test (the action) is the soft hero first;
        // the reviews card next; the how-it-works note last
        DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              DsAvatar(child: Icon(Icons.science_rounded, size: 22, color: DsTokens.of(context).primaryInk)),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(t.bizaiCamLiveTitle,
                      style: AType.titleMedium.copyWith(
                          color: DsTokens.of(context).text, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.bizaiCamLiveHow, style: AType.bodyMedium.copyWith(color: DsTokens.of(context).text)),
            const SizedBox(height: Gap.sm),
            if (site == null) ...[
              Text(t.bizaiCamPickSite),
              // qbiz: no dead end — the shop is added on the Shop Box screen
              const SizedBox(height: Gap.sm),
              DsButton(
                buttonKey: const ValueKey('qbiz-cam-back'),
                expand: true,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icons.storefront_rounded,
                label: t.qbizCamAddShop,
              ),
            ]
            else if (_testId == null)
              DsButton(
                buttonKey: const ValueKey('bizai-cam-start'),
                expand: true,
                onPressed: _busy
                    ? null
                    : () => _do(() async {
                          final r = await _src.startTest(site);
                          setState(() {
                            _testId = (r['id'] as num).toInt();
                            _marks = 0;
                          });
                        }),
                icon: Icons.play_arrow_rounded,
                label: t.bizaiCamStart,
              )
            else ...[
              Text(t.bizaiCamMarks(fmtInt(context, _marks))),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final k in _kinds)
                  DsButton.secondary(
                    buttonKey: ValueKey('bizai-cam-mark-$k'),
                    onPressed: _busy
                        ? null
                        : () => _do(() async {
                              await _src.mark(_testId!, k);
                              setState(() => _marks++);
                            }),
                    label: _kind(t, k),
                  ),
              ]),
              const SizedBox(height: Gap.sm),
              DsButton(
                buttonKey: const ValueKey('bizai-cam-stop'),
                expand: true,
                onPressed: _busy
                    ? null
                    : () => _do(() async {
                          await _src.stop(_testId!);
                          setState(() => _testId = null);
                          await _load();
                        }),
                icon: Icons.stop_rounded,
                label: t.bizaiCamStop,
              ),
            ],
            const SizedBox(height: Gap.sm),
            Text(t.bizaiCamSessions(fmtInt(context, (live['sessions'] as num?)?.toInt() ?? 0)),
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
            _table(t, (live['per_type'] as Map?) ?? const {}),
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.bizaiCamReviewsTitle,
          icon: Icons.fact_check_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _table(t, (rev['per_type'] as Map?) ?? const {}),
            if (((rev['unreviewed'] as num?) ?? 0) > 0)
              Text(t.bizaiCamUnreviewed(fmtInt(context, (rev['unreviewed'] as num).toInt()))),
            if (site != null) ...[
              const SizedBox(height: Gap.sm),
              DsButton.secondary(
                buttonKey: const ValueKey('bizai-cam-missed'),
                expand: true,
                onPressed: _busy
                    ? null
                    : () => _do(() async {
                          await _src.missed(site, 'person');
                          await _load();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(t.bizaiCamMissedDone)));
                          }
                        }),
                icon: Icons.report_rounded,
                label: t.bizaiCamMissed,
              ),
            ],
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizNote(text: t.bizaiCamExplain, icon: Icons.info_outline_rounded),
      ]),
    );
  }
}
