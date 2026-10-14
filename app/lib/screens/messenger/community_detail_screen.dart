import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_community_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_community_card.dart';
import 'community_members_screen.dart';

/// Assisto Messenger — COMMUNITY detail (Step 3, item 2).
///
/// Shows the Announcements group (admins post only) first, then the topic
/// groups. Admin controls — approve / reject join requests, set group rules,
/// set a size limit — are rendered ONLY when the viewer is an admin. The
/// server re-enforces every control (can_approve_join, set_group_rules,
/// set_group_size_limit, can_remove_community_member): a non-admin client that
/// renders a control anyway still cannot act, because the backend refuses.
///
/// Backend: GET /community/<id>/groups,
///          POST /community/join-request/<id>/approve|reject,
///          PATCH /community/group/<id> (rules/size/join_mode/announcements).
class CommunityDetailScreen extends StatefulWidget {
  final Map<String, dynamic> community;
  final IdentityKeyPair identity;

  const CommunityDetailScreen({
    super.key,
    required this.community,
    required this.identity,
  });

  @override
  State<CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<CommunityDetailScreen> {
  bool _loading = true;
  bool _backendReady = true;
  Map<String, dynamic>? _announcements;
  List<Map<String, dynamic>> _topics = [];

  /// Pending join requests across the community's groups (admins only).
  List<Map<String, dynamic>> _joinRequests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  String get _cid => '${widget.community['id']}';
  bool get _isAdmin => widget.community['viewer_role'] == 'admin';

  Future<void> _load() async {
    try {
      final r = await _api.communityGroups(_cid);
      final joined =
          ((r['joined'] ?? const []) as List).cast<Map<String, dynamic>>();
      final joinable =
          ((r['joinable'] ?? const []) as List).cast<Map<String, dynamic>>();
      final all = [...joined, ...joinable];
      _announcements = all.firstWhere(
        (g) => '${g['kind'] ?? ''}' == 'announcements',
        orElse: () => <String, dynamic>{},
      );
      if (_announcements!.isEmpty) _announcements = null;
      _topics =
          all.where((g) => '${g['kind'] ?? ''}' != 'announcements').toList();
      _joinRequests =
          ((r['join_requests'] ?? const []) as List).cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _announcements = null;
      _topics = [];
      _joinRequests = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _approve(Map<String, dynamic> req) async {
    try {
      await _api.joinRequestApprove('${req['id']}');
    } catch (_) {}
    await _load();
  }

  Future<void> _reject(Map<String, dynamic> req) async {
    try {
      await _api.joinRequestReject('${req['id']}');
    } catch (_) {}
    await _load();
  }

  Future<void> _editRules(Map<String, dynamic> group) async {
    final controller = TextEditingController(text: '${group['rules'] ?? ''}');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.communitySetRules),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(hintText: _t.communityRulesHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(_t.save)),
        ],
      ),
    );
    if (result == null) return;
    try {
      await _api.communityGroupUpdate('${group['id']}', rules: result.trim());
    } catch (_) {}
    await _load();
  }

  Future<void> _editSizeLimit(Map<String, dynamic> group) async {
    final current = '${group['size_limit'] ?? ''}';
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.communitySetSizeLimit),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: _t.communitySizeLimitHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(_t.save)),
        ],
      ),
    );
    final n = int.tryParse('${result ?? ''}'.trim());
    if (n == null) return;
    try {
      await _api.communityGroupUpdate('${group['id']}', sizeLimit: n);
    } catch (_) {}
    await _load();
  }

  void _openMembers() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommunityMembersScreen(
        community: widget.community,
        identity: widget.identity,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.community['name'] ?? _t.communityTitle}'),
        actions: [
          IconButton(
            tooltip: _t.communityMembersTitle,
            icon: const Icon(Icons.people_outline),
            onPressed: _openMembers,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: Gap.xxl),
                children: [
                  if ('${widget.community['description'] ?? ''}'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Gap.lg, Gap.md, Gap.lg, 0),
                      child: Text('${widget.community['description']}',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  if (!_backendReady) _pending(scheme),
                  if (_isAdmin && _joinRequests.isNotEmpty) ...[
                    _header(_t.communityPendingRequests, scheme),
                    for (final req in _joinRequests) _requestRow(req),
                  ],
                  if (_announcements != null) ...[
                    _header(_t.communityAnnouncementsGroup, scheme),
                    _groupCard(_announcements!, announcements: true),
                  ],
                  _header(_t.communityTopicGroups, scheme),
                  if (_topics.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(_t.communityNoTopics,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  for (final g in _topics) _groupCard(g),
                ],
              ),
            ),
    );
  }

  Widget _header(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: scheme.primary)),
      );

  Widget _requestRow(Map<String, dynamic> req) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1_outlined)),
      title: Text('${req['requester_name'] ?? ''}'),
      subtitle: Text(_t.communityWantsToJoin('${req['group_name'] ?? ''}')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _t.communityApprove,
            icon: const Icon(Icons.check_circle_outline),
            color: Brand.success,
            onPressed: () => _approve(req),
          ),
          IconButton(
            tooltip: _t.communityReject,
            icon: const Icon(Icons.cancel_outlined),
            color: Brand.danger,
            onPressed: () => _reject(req),
          ),
        ],
      ),
    );
  }

  Widget _groupCard(Map<String, dynamic> g, {bool announcements = false}) {
    final count = g['member_count'] ?? 0;
    final announcementsOnly =
        announcements || g['announcements_only'] == true;
    return MsgrCommunityCard(
      name: '${g['name'] ?? ''}',
      description: '${g['description'] ?? ''}',
      photoRef: g['photo_ref']?.toString(),
      countLabel: _t.communityMemberCount('$count'),
      badge: announcementsOnly
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.campaign_outlined,
                    size: 13, color: Theme.of(context).colorScheme.tertiary),
                const SizedBox(width: 4),
                Text(_t.communityAdminsPostOnly,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ],
            )
          : null,
      trailing: _isAdmin
          ? PopupMenuButton<String>(
              tooltip: _t.communityAdminControls,
              onSelected: (v) {
                if (v == 'rules') _editRules(g);
                if (v == 'size') _editSizeLimit(g);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rules', child: Text(_t.communitySetRules)),
                PopupMenuItem(
                    value: 'size', child: Text(_t.communitySetSizeLimit)),
              ],
            )
          : null,
    );
  }

  Widget _pending(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Text(_t.communityBackendPending,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
}
