import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import 'crm_common.dart';

/// Team screen (CRM_SPEC): roles (owner / manager / salesperson), assignment,
/// routing rules by industry, and a note that instant in-app alerts for 90+
/// leads fire through the app's existing foreground alert channel.
class CrmTeamScreen extends StatefulWidget {
  final int org;
  const CrmTeamScreen({super.key, required this.org});
  @override
  State<CrmTeamScreen> createState() => _CrmTeamScreenState();
}

class _CrmTeamScreenState extends State<CrmTeamScreen> {
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final api = CrmApi.of(context);
      _members = await api.members(widget.org);
      _rules = await api.routingRules(widget.org);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  String _roleLabel(AppLocalizations t, String? role) {
    switch (role) {
      case 'owner':
        return t.crmRoleOwner;
      case 'manager':
        return t.crmRoleManager;
      default:
        return t.crmRoleSales;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: t.loadFailed,
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        NeedsKeyBanner(t.crmTeamAlertNote, icon: Icons.notifications_active_outlined),
        _sectionTitle(t.crmTeam),
        if (_members.isEmpty)
          Padding(padding: const EdgeInsets.all(Gap.md), child: Text(t.crmNoTeam))
        else
          for (final m in _members)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(((m['user_name'] ?? '?').toString().isNotEmpty ? m['user_name'][0] : '?').toUpperCase(),
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                ),
                title: Text(m['user_name'] ?? ''),
                subtitle: Text(_roleLabel(t, m['role'])),
              ),
            ),
        const SizedBox(height: Gap.md),
        _sectionTitle(t.crmRouting),
        if (_rules.isEmpty)
          Padding(padding: const EdgeInsets.all(Gap.md), child: Text(t.crmNoRouting))
        else
          for (final r in _rules)
            Card(
              child: ListTile(
                leading: const Icon(Icons.alt_route_outlined),
                title: Text([
                  if ((r['match_industry'] ?? '').toString().isNotEmpty) r['match_industry'],
                  if ((r['match_source'] ?? '').toString().isNotEmpty) r['match_source'],
                ].join(' · ')),
                subtitle: Text('${t.crmAssignTo} #${r['assign_to'] ?? '—'}'),
              ),
            ),
      ]),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs, top: Gap.sm),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );
}
