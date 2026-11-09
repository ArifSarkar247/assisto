import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/circle_group_create_sheet.dart';
import 'circle_group_chat_screen.dart';

/// Connected Circle — GROUPS hub (M2 item 7). Lists the groups the user belongs
/// to and launches the create flow. Groups are CIRCLE-ONLY: every member is a
/// mutually-accepted relationship (enforced server-side in
/// core/logic/circle_groups.can_add_member). Messages are E2E — the server
/// relays ciphertext only, exactly like 1:1.
///
/// Backend seam (integrator wires these — see MIGRATION NOTE in the report):
///   GET  /circle/groups                 -> groups I'm an active member of
///   POST /circle/groups                 -> create group {name,description,photo}
/// Until live, the screen shows a friendly empty state (no crash).
class CircleGroupListScreen extends StatefulWidget {
  final IdentityKeyPair identity;

  /// Accepted circle members, passed from the circle hub so the create/add
  /// flows can offer only circle members (client-side mirror of the server
  /// circle-only rule; the server re-enforces it).
  final List<Map<String, dynamic>> circleMembers;

  const CircleGroupListScreen({
    super.key,
    required this.identity,
    this.circleMembers = const [],
  });

  @override
  State<CircleGroupListScreen> createState() => _CircleGroupListScreenState();
}

class _CircleGroupListScreenState extends State<CircleGroupListScreen> {
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/circle/groups');
      _groups = ((r['results'] ?? r['groups'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _groups = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final draft = await showCircleGroupCreateSheet(
      context,
      circleMembers: widget.circleMembers,
    );
    if (draft == null || !mounted) return;
    try {
      await _api.postJson('/circle/groups', {
        'name': draft.name,
        'description': draft.description,
        if (draft.photoRef != null) 'photo_ref': draft.photoRef,
        'member_ids': draft.memberIds,
      });
    } catch (_) {
      // seam audit: a failed create used to vanish silently.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
    }
    await _load();
  }

  void _open(Map<String, dynamic> group) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleGroupChatScreen(
        group: group,
        identity: widget.identity,
        circleMembers: widget.circleMembers,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.circleGroupsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.group_add_rounded),
        label: Text(_t.circleGroupCreate),
      ),
      body: _loading
          ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
              for (var i = 0; i < 3; i++)
                Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: DsSkeleton.card(lines: 2)),
            ])
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (_groups.isEmpty) _emptyState(scheme),
                  // designv2: groups in one grouped card
                  if (_groups.isNotEmpty)
                    DsGroup(children: [for (final g in _groups) _groupTile(g)]),
                ],
              ),
            ),
    );
  }

  Widget _emptyState(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: DsEmptyState(
          icon: Icons.groups_2_rounded,
          title: _t.circleGroupsEmptyTitle,
          benefit: _backendReady ? _t.circleGroupsEmptyBody : _t.circleBackendPending,
          actionLabel: _backendReady ? _t.circleGroupCreate : null,
          onAction: _backendReady ? _create : null,
        ),
      );

  Widget _groupTile(Map<String, dynamic> g) {
    final name = '${g['name'] ?? ''}';
    final count = (g['member_count'] ?? (g['member_ids'] as List?)?.length ?? 0);
    final announcementsOnly = g['announcements_only'] == true;
    final ds = DsTokens.of(context);
    return DsListRow(
      leading: DsAvatar(name: name),
      title: name,
      subtitle: _t.circleGroupMemberCount(notifLocalizeDigits(context, '$count')),
      trailing: announcementsOnly
          ? Tooltip(
              message: _t.circleGroupAnnouncementsOnly,
              child: Icon(Icons.campaign_rounded, color: ds.primaryInk),
            )
          : Icon(Icons.chevron_right_rounded, color: ds.muted),
      onTap: () => _open(g),
    );
  }
}
