import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../messenger_community_api.dart';
import '../../messenger_group_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_community_card.dart';
import '../../widgets/msgr_mod_report_sheet.dart';
import '../../widgets/space_invite_sheet.dart'; // channels
import '../../messaging/chat_opener.dart'; // channels: open a group chat
import 'package:assisto/widgets/app_sheet.dart';
import 'community_members_screen.dart';
import 'community_message_requests_screen.dart';
import 'community_settings_screen.dart';
import '../../ads/sponsor_widgets.dart' show SponsoredPostSlot; // p2-money
import '../../feature_gates.dart' show kCommunityAlertsBuilt; // f6

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
  bool _loadError = false;
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
  // channels: the server's answer wins over the map we were opened with.
  String? _role;
  bool get _isAdmin => (_role ?? widget.community['viewer_role']) == 'admin';
  final _busy = <String>{};

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final r = await _api.communityGroups(_cid);
      final joined =
          ((r['joined'] ?? const []) as List).cast<Map<String, dynamic>>();
      final joinable =
          ((r['joinable'] ?? const []) as List).cast<Map<String, dynamic>>();
      final requested =
          ((r['requested'] ?? const []) as List).cast<Map<String, dynamic>>();
      // channels: remember my state per group (open chat / join / waiting).
      for (final g in joined) {
        g['_state'] = 'joined';
      }
      for (final g in joinable) {
        g['_state'] = 'joinable';
      }
      for (final g in requested) {
        g['_state'] = 'requested';
      }
      if (r['viewer_role'] != null) _role = '${r['viewer_role']}';
      final all = [...joined, ...requested, ...joinable];
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
      _loadError = false;
    } on ApiException {
      // A real request reached the server but failed — honest, retryable error.
      _backendReady = true;
      _loadError = true;
      _announcements = null;
      _topics = [];
      _joinRequests = [];
    } catch (_) {
      // No backend yet (offline / not wired) — friendly pending state.
      _backendReady = false;
      _loadError = false;
      _announcements = null;
      _topics = [];
      _joinRequests = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _approve(Map<String, dynamic> req) async {
    final name = '${req['requester_name'] ?? ''}';
    final ok = await _confirm(
      title: _t.communityApprove,
      message: _t.communityApproveConfirm(name),
      confirmLabel: _t.communityApprove,
    );
    if (ok != true) return;
    try {
      await _api.joinRequestApprove('${req['id']}');
    } catch (_) {
      _toast(_t.communityActionFailed);
    }
    await _load();
  }

  Future<void> _reject(Map<String, dynamic> req) async {
    final name = '${req['requester_name'] ?? ''}';
    final ok = await _confirm(
      title: _t.communityReject,
      message: _t.communityRejectConfirm(name),
      confirmLabel: _t.communityReject,
      destructive: true,
    );
    if (ok != true) return;
    try {
      await _api.joinRequestReject('${req['id']}');
    } catch (_) {
      _toast(_t.communityActionFailed);
    }
    await _load();
  }

  /// Shared confirm gate for destructive / consequential actions (§21).
  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
            style: destructive
                ? Brand.dangerButton()
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _editRules(Map<String, dynamic> group) async {
    final controller = TextEditingController(text: '${group['rules'] ?? ''}');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
    }
    await _load();
  }

  Future<void> _editSizeLimit(Map<String, dynamic> group) async {
    final current = '${group['size_limit'] ?? ''}';
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
    }
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

  // -------------------------------------------------------------------------
  // COMMUNITY detail ⋮ — only the actions that apply to this viewer.
  // -------------------------------------------------------------------------
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showInfo() {
    final desc = '${widget.community['description'] ?? ''}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text('${widget.community['name'] ?? _t.communityTitle}'),
        content: Text(desc.isEmpty ? _t.communityNoTopics : desc),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const CommunitySettingsScreen()));
  }

  void _openApprovals() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CommunityMessageRequestsScreen(identity: widget.identity)));
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(_t.communityLeave),
        content: Text(_t.communityLeaveConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.communityLeave)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _api.communityLeave(_cid);
      // LAST-ADMIN protection (can_leave_community): the last admin must hand
      // over first — surface the refusal and stay.
      if (r['left'] == false || r['allowed'] == false) {
        _toast(_t.communityLeaveLastAdmin);
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast(e is ApiException && e.message.isNotEmpty
          ? e.message
          : _t.communityActionFailed);
    }
  }

  /// channels: admins share the invite link + QR (joining asks an admin).
  Future<void> _invite() async {
    final t = _t;
    try {
      final j = await _api.communityInvite(_cid);
      final url = '${j['url'] ?? ''}';
      if (url.isEmpty || !mounted) return;
      await showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetCtx) => SpaceInviteSheet(
          url: url,
          title: t.chxInviteCommunityTitle,
          note: t.chxInviteCommunityNote,
          extra: TextButton.icon(
            onPressed: () async {
              Navigator.of(sheetCtx).pop();
              try {
                await _api.communityInviteReset(_cid);
                _toast(t.chxNewLinkToast);
              } catch (_) {
                _toast(t.communityActionFailed);
              }
            },
            icon: const Icon(Icons.autorenew_rounded),
            label: Text(t.chxNewLink),
          ),
        ),
      );
    } catch (_) {
      _toast(t.communityActionFailed);
    }
  }

  /// channels: admins add a topic group (open join or ask-first).
  Future<void> _addGroup() async {
    final t = _t;
    final name = TextEditingController();
    bool open = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(t.chxAddGroup),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('chx-group-name'),
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: t.chxGroupName),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: open,
              onChanged: (v) => setD(() => open = v),
              title: Text(t.chxGroupOpenJoin),
              subtitle: Text(open ? t.chxGroupOpenSub : t.chxGroupAskSub),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.chxCreate)),
          ],
        ),
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (ok != true || n.isEmpty) return;
    try {
      await _api.communityGroupCreate(_cid,
          name: n, joinMode: open ? 'open' : 'request');
      await _load();
    } catch (_) {
      _toast(t.communityActionFailed);
    }
  }

  Future<void> _joinGroup(Map<String, dynamic> g) async {
    final t = _t;
    final gid = '${g['id']}';
    setState(() => _busy.add(gid));
    try {
      final r = await _api.communityGroupJoin(gid);
      _toast('${r['action']}' == 'joined'
          ? t.communityJoinedNow
          : t.communityRequestSent);
      await _load();
    } on ApiException catch (e) {
      _toast(e.status == 429 ? t.chxRateLimited : t.communityActionFailed);
    } catch (_) {
      _toast(t.communityActionFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(gid));
    }
  }

  /// A joined group opens its real (end-to-end encrypted) group chat.
  Future<void> _openGroupChat(Map<String, dynamic> g) async {
    final cg = (g['circle_group_id'] as num?)?.toInt();
    if (cg == null) {
      _toast(_t.communityActionFailed);
      return;
    }
    await ChatOpener.open(Navigator.of(context), _api, 'group', cg);
  }

  Future<void> _report() async {
    await MsgrReportSheet.show(
      context,
      targetKind: ModTargets.community,
      targetId: _cid,
    );
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
            icon: const Icon(Icons.people_outline_rounded),
            onPressed: _openMembers,
          ),
          PopupMenuButton<String>(
            tooltip: _t.grpMenuMore,
            onSelected: (v) {
              switch (v) {
                case 'info':
                  _showInfo();
                case 'members':
                  _openMembers();
                case 'settings':
                  _openSettings();
                case 'approve':
                  _openApprovals();
                case 'leave':
                  _leave();
                case 'report':
                  _report();
                case 'invite':
                  _invite();
                case 'add_group':
                  _addGroup();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'info', child: Text(_t.communityInfo)),
              if (_isAdmin)
                PopupMenuItem(value: 'invite', child: Text(_t.chxInviteLink)),
              if (_isAdmin)
                PopupMenuItem(value: 'add_group', child: Text(_t.chxAddGroup)),
              PopupMenuItem(
                  value: 'members', child: Text(_t.communityMembersTitle)),
              // The server does not deliver or push community posts yet, so
              // an alert switch would change nothing. f6: hidden, not shown
              // disabled with "not yet".
              if (kCommunityAlertsBuilt)
              PopupMenuItem(
                enabled: false,
                value: 'notifications',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: false,
                  title: Text(_t.communityMuteNotifications),
                  subtitle: Text(_t.msgCommunityAlertsNotYet),
                ),
              ),
              // Admin-only actions appear only for an admin viewer.
              if (_isAdmin)
                PopupMenuItem(value: 'settings', child: Text(_t.communityEdit)),
              if (_isAdmin)
                PopupMenuItem(
                    value: 'approve', child: Text(_t.communityApproveRequests)),
              PopupMenuItem(value: 'leave', child: Text(_t.communityLeave)),
              PopupMenuItem(value: 'report', child: Text(_t.communityReport)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError
              ? _errorRetry(scheme)
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
                  // p2-money: "Sponsored" post at the end of a LARGE
                  // community (server-gated; nothing for admins / Premium).
                  if (!_isAdmin && int.tryParse(_cid) != null)
                    SponsoredPostSlot(
                        ctxKind: 'community', ctxId: int.parse(_cid)),
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
      leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1_rounded)),
      title: Text('${req['requester_name'] ?? ''}'),
      subtitle: Text(_t.communityWantsToJoin('${req['group_name'] ?? ''}')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _t.communityApprove,
            icon: const Icon(Icons.check_circle_outline_rounded),
            color: Brand.success,
            onPressed: () => _approve(req),
          ),
          IconButton(
            tooltip: _t.communityReject,
            icon: const Icon(Icons.cancel_rounded),
            color: Brand.danger,
            onPressed: () => _reject(req),
          ),
        ],
      ),
    );
  }

  Widget _groupCard(Map<String, dynamic> g, {bool announcements = false}) {
    final state = '${g['_state'] ?? 'joined'}';
    if (state != 'joined') {
      final openJoin = '${g['join_mode'] ?? 'request'}' == 'open';
      return MsgrCommunityCard(
        name: '${g['name'] ?? ''}',
        description: '${g['description'] ?? ''}',
        photoRef: g['photo_ref']?.toString(),
        countLabel: _t.communityMemberCount('${g['member_count'] ?? 0}'),
        trailing: state == 'requested'
            ? MsgrActionChip(
                label: _t.communityRequested,
                icon: Icons.hourglass_empty_rounded,
                muted: true)
            : MsgrActionChip(
                label: openJoin ? _t.communityJoin : _t.communityRequestToJoin,
                icon: openJoin ? Icons.add_rounded : Icons.outgoing_mail,
                onPressed: _busy.contains('${g['id']}')
                    ? null
                    : () => _joinGroup(g),
              ),
      );
    }
    final count = g['member_count'] ?? 0;
    final announcementsOnly =
        announcements || g['announcements_only'] == true;
    return MsgrCommunityCard(
      onTap: () => _openGroupChat(g),
      name: '${g['name'] ?? ''}',
      description: '${g['description'] ?? ''}',
      photoRef: g['photo_ref']?.toString(),
      countLabel: _t.communityMemberCount('$count'),
      badge: announcementsOnly
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.campaign_rounded,
                    size: 13, color: Theme.of(context).colorScheme.tertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(_t.communityAdminsPostOnly,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            )
          : null,
      trailing: PopupMenuButton<String>(
        tooltip:
            _isAdmin ? _t.communityAdminControls : _t.communityViewRules,
        onSelected: (v) {
          if (v == 'view_rules') _viewRules(g);
          if (v == 'rules') _editRules(g);
          if (v == 'size') _editSizeLimit(g);
        },
        itemBuilder: (_) => [
          // Every member can READ the rules.
          PopupMenuItem(
              value: 'view_rules', child: Text(_t.communityViewRules)),
          // Admin-only edit controls.
          if (_isAdmin)
            PopupMenuItem(value: 'rules', child: Text(_t.communitySetRules)),
          if (_isAdmin)
            PopupMenuItem(
                value: 'size', child: Text(_t.communitySetSizeLimit)),
        ],
      ),
    );
  }

  Widget _pending(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Text(_t.communityBackendPending,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );

  /// Honest, retryable error state (§21): a real request failed — never hide it
  /// behind an empty list.
  Widget _errorRetry(ColorScheme scheme) => ListView(
        children: [
          const SizedBox(height: Gap.xxl * 2),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: Gap.md),
                  Text(_t.communityLoadError,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(_t.retry),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  /// Read-only rules viewer — every member (not only admins) can READ the
  /// group's rules; admins additionally get the edit control elsewhere.
  void _viewRules(Map<String, dynamic> group) {
    final rules = '${group['rules'] ?? ''}'.trim();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.communityRulesTitle),
        content: SingleChildScrollView(
          child: Text(
            rules.isEmpty ? _t.communityRulesEmpty : rules,
            style: rules.isEmpty
                ? TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)
                : null,
          ),
        ),
        actions: [
          if (_isAdmin)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _editRules(group);
              },
              child: Text(_t.communitySetRules),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }
}
