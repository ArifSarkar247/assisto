import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'probashi_source.dart';
import 'probashi_widgets.dart';

/// probashi-plan: the payer's family dashboard. Per member ONLY what that
/// member agreed to share (the server leaves the rest out): location sharing
/// on/off (their real My Circle setting), last journeys, safety alerts / SOS,
/// money received vs budget vs spent this month, reminders done. Anything not
/// shared says so plainly — never a guess, never sample data.
class ProbashiFamilyScreen extends StatefulWidget {
  final ProbashiSource source;
  const ProbashiFamilyScreen({super.key, required this.source});

  @override
  State<ProbashiFamilyScreen> createState() => _ProbashiFamilyScreenState();
}

class _ProbashiFamilyScreenState extends State<ProbashiFamilyScreen> {
  bool _loading = true;
  Object? _err;
  Map<String, dynamic> _d = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _d = await widget.source.family();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final members = [for (final x in (_d['members'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    return Scaffold(
      appBar: AppBar(title: Text(t.pbsFamilyTitle)),
      body: (_loading || _err != null)
          ? PbsStateView(loading: _loading, error: _err, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                if (members.isEmpty)
                  Padding(
                    key: const ValueKey('pbs-family-empty'),
                    padding: const EdgeInsets.all(24),
                    child: Text(t.pbsFamilyEmpty, textAlign: TextAlign.center),
                  ),
                for (final m in members) _member(t, m),
              ]),
            ),
    );
  }

  Widget _line(IconData icon, String text, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      );

  Widget _notShared(AppLocalizations t, String what, String name) =>
      _line(Icons.visibility_off_rounded, t.pbsNotShared(what, name));

  Widget _member(AppLocalizations t, Map<String, dynamic> m) {
    final name = '${(m['member'] as Map?)?['name'] ?? ''}';
    final shared = {for (final s in (m['shared'] as List? ?? const [])) '$s'};
    final journeys = [for (final x in (m['journeys'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    final safety = [for (final x in (m['safety'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    final money = (m['money'] as Map?)?.cast<String, dynamic>();
    return PbsCard(title: name, icon: Icons.person_rounded, children: [
      _line(m['location_sharing'] == true ? Icons.location_on_rounded : Icons.location_off_rounded,
          m['location_sharing'] == true ? t.pbsLocationOn : t.pbsLocationOff),
      // journeys
      if (shared.contains('journeys')) ...[
        _line(Icons.navigation_rounded, t.pbsJourneysMonth(pbsNum(context, m['journeys_month'] ?? 0))),
        for (final j in journeys.take(3))
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text('${pbsDate(context, j['at'])} · ${_journeyStatus(t, '${j['status']}')}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ] else
        _notShared(t, t.pbsConsentJourneys, name),
      // safety
      if (shared.contains('sos')) ...[
        _line(Icons.emergency_rounded, t.pbsSafetyMonth(pbsNum(context, m['safety_month'] ?? 0))),
        for (final a in safety.take(5))
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text('${pbsDate(context, a['at'])} · ${a['title']}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ] else
        _notShared(t, t.pbsConsentSos, name),
      // money
      if (shared.contains('budget'))
        money == null
            ? _line(Icons.error_outline_rounded, t.pbsMoneyUnavailable)
            : _line(
                Icons.account_balance_wallet_rounded,
                t.pbsMoneyLine(pbsTaka(context, money['received_poisha']), pbsTaka(context, money['budget_poisha']),
                    pbsTaka(context, money['spent_poisha'])),
                key: ValueKey('pbs-money-$name'))
      else
        _notShared(t, t.pbsConsentBudget, name),
      // reminders
      if (shared.contains('reminders'))
        _line(Icons.alarm_on_rounded, t.pbsRemindersDone(pbsNum(context, m['reminders_done_month'] ?? 0)))
      else
        _notShared(t, t.pbsConsentReminders, name),
    ]);
  }

  String _journeyStatus(AppLocalizations t, String s) => switch (s) {
        'arrived' => t.pbsJourneyArrived,
        'active' => t.pbsJourneyActive,
        _ => t.pbsJourneyEnded,
      };
}
