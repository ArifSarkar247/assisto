import 'package:flutter/material.dart';
import '../../ds/ds.dart';
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
        // Page rule: the invite code first (the one thing to share), as the
        // soft hero with the code big; then the team and the routing rules
        // as DS groups; the alerts note last.
        if (_inviteCode != null && _inviteCode!.isNotEmpty) ...[
          DsHeroCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                DsAvatar(child: Icon(Icons.vpn_key_rounded, size: 20, color: scheme.ds.primaryInk)),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Text(t.crmInviteCode,
                      style: AType.titleMedium.copyWith(
                          color: scheme.ds.text, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: Gap.md),
              SelectableText(_inviteCode!,
                  style: AType.headlineSmall.copyWith(
                      color: scheme.ds.text,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      fontFeatures: AFonts.tabular)),
              const SizedBox(height: Gap.xs),
              Text(t.crmInviteCodeHint,
                  style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
            ]),
          ),
        ],
        DsSectionHeader(t.crmTeam),
        if (_members.isEmpty)
          DsCard(child: Text(t.crmNoTeam, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)))
        else
          DsGroup(margin: EdgeInsets.zero, children: [
            for (final m in _members)
              DsListRow(
                leading: DsAvatar(name: '${m['user_name'] ?? ''}'),
                title: '${m['user_name'] ?? ''}',
                subtitle: _roleLabel(t, m['role']),
              ),
          ]),
        DsSectionHeader(t.crmRouting),
        if (_rules.isEmpty)
          DsCard(child: Text(t.crmNoRouting, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)))
        else
          DsGroup(margin: EdgeInsets.zero, children: [
            for (final r in _rules)
              DsListRow(
                leading: DsAvatar(
                    size: 40,
                    child: Icon(Icons.alt_route_rounded, size: 20, color: scheme.ds.primaryInk)),
                title: [
                  if ((r['match_industry'] ?? '').toString().isNotEmpty)
                    crmIndustryLabel(t, r['match_industry'].toString()),
                  if ((r['match_source'] ?? '').toString().isNotEmpty) r['match_source'],
                ].join(' · '),
                // show the member's NAME, not their internal id
                subtitle: '${t.crmAssignTo} ${_memberName(r['assign_to'])}',
              ),
          ]),
        const SizedBox(height: Gap.sm),
        NeedsKeyBanner(t.crmTeamAlertNote, icon: Icons.notifications_active_rounded),
      ]),
    );
  }

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
