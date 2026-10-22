import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
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
        icon: const Icon(Icons.group_add_outlined),
        label: Text(_t.circleGroupCreate),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (_groups.isEmpty) _emptyState(scheme),
                  for (final g in _groups) _groupTile(g),
                ],
              ),
            ),
    );
  }

  Widget _emptyState(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          children: [
            Icon(Icons.groups_2_outlined,
                size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(_t.circleGroupsEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              _backendReady ? _t.circleGroupsEmptyBody : _t.circleBackendPending,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      );

  Widget _groupTile(Map<String, dynamic> g) {
    final name = '${g['name'] ?? ''}';
    final count = (g['member_count'] ?? (g['member_ids'] as List?)?.length ?? 0);
    final announcementsOnly = g['announcements_only'] == true;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            Theme.of(context).colorScheme.primaryContainer,
        child: const Icon(Icons.groups_outlined),
      ),
      title: Text(name),
      subtitle: Text(_t.circleGroupMemberCount(notifLocalizeDigits(context, '$count'))),
      trailing: announcementsOnly
          ? Tooltip(
              message: _t.circleGroupAnnouncementsOnly,
              child: const Icon(Icons.campaign_outlined),
            )
          : null,
      onTap: () => _open(g),
    );
  }
}
