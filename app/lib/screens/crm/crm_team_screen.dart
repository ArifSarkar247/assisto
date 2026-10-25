import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
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
  String? _inviteCode; // owner/manager only; null if not permitted/available
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
      final api = CrmApi.of(context);
      _members = await api.members(widget.org);
      _rules = await api.routingRules(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    // Invite code is owner/manager-only (403 for sales). Best-effort: a failure
    // here just hides the share card — it must not block the team screen.
    try {
      final r = await CrmApi.of(context).inviteCode(widget.org);
      _inviteCode = (r['invite_code'] ?? '').toString();
    } catch (_) {
      _inviteCode = null;
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
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        NeedsKeyBanner(t.crmTeamAlertNote, icon: Icons.notifications_active_rounded),
        // Invite code (owner/manager): share so teammates can "Join a team".
        if (_inviteCode != null && _inviteCode!.isNotEmpty) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.vpn_key_rounded),
              title: Text(t.crmInviteCode),
              subtitle: Text(t.crmInviteCodeHint),
              trailing: SelectableText(_inviteCode!,
                  style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
            ),
          ),
          const SizedBox(height: Gap.sm),
        ],
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
                leading: const Icon(Icons.alt_route_rounded),
                title: Text([
                  if ((r['match_industry'] ?? '').toString().isNotEmpty)
                    crmIndustryLabel(t, r['match_industry'].toString()),
                  if ((r['match_source'] ?? '').toString().isNotEmpty) r['match_source'],
                ].join(' · ')),
                // show the member's NAME, not their internal id
                subtitle: Text('${t.crmAssignTo} ${_memberName(r['assign_to'])}'),
              ),
            ),
      ]),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs, top: Gap.sm),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  String _memberName(Object? id) {
    for (final m in _members) {
      if (m['id'] == id || m['user'] == id) {
        final n = (m['user_name'] ?? '').toString();
        if (n.isNotEmpty) return n;
      }
    }
    return id == null ? '—' : '#$id';
  }
}
