import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/business_ui.dart';
import '../widgets/skeleton.dart';
import '../widgets/subs_common.dart' show fmtInt;
import 'outcome_card.dart' show bizaiTaka;

/// bizai pillar 5 — "Weekly report": the week in plain words (sales, AI
/// orders, customers back, best post, best seller), next week's plan
/// (festival, what to post, when), and which tracked posts brought chats and
/// orders. Server: GET bizai/prochar.
class WeeklyReportScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? load;
  final int? businessId;
  const WeeklyReportScreen({super.key, this.load, this.businessId});
  @override
  State<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends State<WeeklyReportScreen> {
  Map<String, dynamic>? _d;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _get();
  }

  Future<void> _get() async {
    setState(() => _error = null);
    try {
      final f = widget.load ??
          () => context.read<AppState>().api.getJson(
              '/bizai/prochar${widget.businessId == null ? '' : '?business=${widget.businessId}'}');
      final d = await f();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.bizaiWeeklyTitle)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _get, child: Text(t.bizRetry)),
      );
    }
    final d = _d;
    if (d == null) return const SkeletonList();
    final w = (d['weekly'] as Map?) ?? const {};
    final posts = [
      for (final x in (((d['attribution'] as Map?)?['posts'] as List?) ?? const []))
        (x as Map).cast<String, dynamic>()
    ];
    return RefreshIndicator(
      onRefresh: _get,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        BizCard(
          title: t.bizaiWeekTitle,
          icon: Icons.insights_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in (w['lines'] as List? ?? const []))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Text(bd(context, l)),
              ),
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.bizaiNextWeekTitle,
          icon: Icons.event_note_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in (w['plan'] as List? ?? const []))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.check_rounded, size: 18),
                  const SizedBox(width: Gap.xs),
                  Expanded(child: Text(bd(context, l))),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.bizaiPostsSoldTitle,
          icon: Icons.campaign_rounded,
          child: posts.isEmpty
              ? Text(t.bizaiPostsSoldEmpty)
              : Column(children: [
                  for (final p in posts)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(bd(context, p['title'] == '' ? p['ref'] : p['title'])),
                      subtitle: Text(t.bizaiPostLine(
                          fmtInt(context, (p['chats'] as num?)?.toInt() ?? 0),
                          fmtInt(context, (p['orders'] as num?)?.toInt() ?? 0))),
                      trailing: Text(bizaiTaka(context, p['bdt']),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ]),
        ),
      ]),
    );
  }
}
