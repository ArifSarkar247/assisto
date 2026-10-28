import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/circle_group_member_tile.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// Group info / settings (M2 item 7). Shows group name/photo/description, the
/// member roster with roles, and admin controls: add members (circle-only),
/// remove, promote/demote, edit info, announcements-only toggle, configurable
/// size limit, invite link (circle-gated redeem), plus leave + report for all.
///
/// All permission rules mirror core/logic/circle_groups (the server is the
/// authority and re-enforces every action; the UI merely hides what the role
/// can't do). Backend seam (integrator wires — see MIGRATION NOTE):
///   POST /circle/groups/<id>                 -> edit {name,description,photo_ref}
///   POST /circle/groups/<id>/members         -> add {member_id}
///   POST /circle/groups/<id>/members/<m>     -> {event: remove|promote|demote}
///   POST /circle/groups/<id>/announcements   -> {on: bool}
///   POST /circle/groups/<id>/size-limit      -> {size_limit: int}
///   GET  /circle/groups/<id>/invite          -> {token, link}
///   POST /circle/groups/<id>/leave
///   POST /circle/groups/<id>/report
class CircleGroupInfoScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> circleMembers;
  const CircleGroupInfoScreen({
    super.key,
    required this.group,
    required this.identity,
    this.circleMembers = const [],
  });

  @override
  State<CircleGroupInfoScreen> createState() => _CircleGroupInfoScreenState();
}

class _CircleGroupInfoScreenState extends State<CircleGroupInfoScreen> {
  bool _loading = true;
  bool _loadFailed = false; // §21: honest error+retry on the roster fetch
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _busy = false; // a destructive/edit action is in-flight (blocks taps)
  List<Map<String, dynamic>> _members = [];
  late Map<String, dynamic> _group;

  @override
  void initState() {
    super.initState();
    _group = Map<String, dynamic>.from(widget.group);
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  String get _groupId => '${_group['id']}';
  String get _myRole => '${_group['my_role'] ?? 'member'}';
  bool get _isAdmin => _myRole == 'admin';

  int get _adminCount =>
      _members.where((m) => '${m['role']}' == 'admin').length;

  Future<void> _load() async {
    if (mounted) setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final r = await _api.getJson('/circle/groups/$_groupId/members');
      _members = ((r['results'] ?? r['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final g = await _api.getJson('/circle/groups/$_groupId');
      if (g.isNotEmpty) _group = {..._group, ...g};
      _loadFailed = false;
    } catch (e) {
      _loadFailed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Run a mutating action with an honest busy gate + failure toast. Returns
  /// true on success so callers can decide whether to reload.
  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    var ok = true;
    try {
      await action();
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _busy = false);
    if (!ok) _toast(_t.grpActionFailed);
    return ok;
  }

  Future<void> _editInfo() async {
    if (!_isAdmin) return;
    final nameC = TextEditingController(text: '${_group['name'] ?? ''}');
    final descC =
        TextEditingController(text: '${_group['description'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(_t.circleGroupEditInfo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              maxLength: 100,
              decoration: InputDecoration(labelText: _t.circleGroupName),
            ),
            TextField(
              controller: descC,
              maxLength: 1000,
              maxLines: 3,
              minLines: 1,
              decoration:
                  InputDecoration(labelText: _t.circleGroupDescription),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.save)),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _run(() async {
      await _api.postJson('/circle/groups/$_groupId', {
        'name': nameC.text.trim(),
        'description': descC.text.trim(),
      });
    });
    if (done) {
      _toast(_t.grpGroupSaved);
      await _load();
    }
  }

  Future<void> _toggleAnnouncements(bool on) async {
    if (!_isAdmin) return;
    final prev = _group['announcements_only'] == true;
    setState(() => _group['announcements_only'] = on);
    final done = await _run(() async {
      await _api
          .postJson('/circle/groups/$_groupId/announcements', {'on': on});
    });
    // Revert the optimistic toggle on failure so the UI stays honest.
    if (!done && mounted) setState(() => _group['announcements_only'] = prev);
  }

  Future<void> _editSizeLimit() async {
    if (!_isAdmin) return;
    final current = '${_group['size_limit'] ?? 256}';
    final c = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(_t.circleGroupSizeLimit),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: _t.circleGroupSizeLimit),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.save)),
        ],
      ),
    );
    if (ok != true) return;
    final v = int.tryParse(c.text.trim());
    if (v == null || v < 1) return;
    final done = await _run(() async {
      await _api
          .postJson('/circle/groups/$_groupId/size-limit', {'size_limit': v});
    });
    if (done) await _load();
  }

  Future<void> _addMembers() async {
    if (!_isAdmin) return;
    // Offer only circle members not already in the group (client mirror of the
    // server circle-only rule, which is re-enforced in can_add_member).
    final existing = _members.map((m) => '${_idOf(m)}').toSet();
    final candidates = widget.circleMembers
        .where((m) => !existing.contains('${_idOf(m)}'))
        .toList();
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.circleGroupNoCircleMembers)));
      }
      return;
    }
    final picked = await showAppSheet<List<int>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _AddMembersSheet(candidates: candidates),
    );
    if (picked == null || picked.isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    var added = 0;
    var failed = 0;
    for (final id in picked) {
      try {
        await _api
            .postJson('/circle/groups/$_groupId/members', {'member_id': id});
        added++;
      } catch (_) {
        failed++;
      }
    }
    if (mounted) setState(() => _busy = false);
    // §21: honest result — never pretend every add succeeded.
    _toast(_t.grpAddMembersResult('$added', '$failed'));
    await _load();
  }

  /// Member management. REMOVE and DEMOTE are destructive → confirm first
  /// (§21 confirm gate). PROMOTE is additive and needs no gate.
  Future<void> _memberAction(Map<String, dynamic> m, String event) async {
    if (event == 'remove' || event == 'demote') {
      final name = '${m['name'] ?? ''}';
      final confirmed = await _confirmDestructive(
        title:
            event == 'remove' ? _t.grpConfirmRemoveTitle : _t.grpConfirmDemoteTitle,
        body: event == 'remove'
            ? _t.grpConfirmRemoveBody(name)
            : _t.grpConfirmDemoteBody(name),
        confirmLabel:
            event == 'remove' ? _t.grpConfirmRemove : _t.grpConfirmDemote,
      );
      if (confirmed != true) return;
    }
    final done = await _run(() async {
      await _api.postJson(
          '/circle/groups/$_groupId/members/${_idOf(m)}', {'event': event});
    });
    if (done) await _load();
  }

  /// Shared destructive-action confirm dialog (mirrors
  /// core/logic/circle_groups.confirm_copy so copy stays consistent with the
  /// server-side gate).
  Future<bool?> _confirmDestructive({
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel)),
        ],
      ),
    );
  }

  Future<void> _inviteLink() async {
    try {
      final r = await _api.getJson('/circle/groups/$_groupId/invite');
      final link = r['link'] as String? ?? r['token'] as String?;
      if (link != null) {
        await Clipboard.setData(ClipboardData(text: link));
        _toast(_t.circleLinkCopied);
      } else {
        _toast(_t.circleBackendPending);
      }
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(_t.circleGroupLeave),
        content: Text(_t.circleGroupLeaveConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.circleGroupLeave)),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _run(() async {
      final r = await _api.postJson('/circle/groups/$_groupId/leave', {});
      // LAST-ADMIN protection: server refuses when I'm the last admin.
      if (r['allowed'] == false || r['left'] == false) {
        throw StateError('last_admin');
      }
    });
    if (done && mounted) Navigator.of(context).pop();
  }

  Future<void> _report() async {
    final reason = await showAppSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in const [
              'spam',
              'harassment',
              'scam',
              'impersonation',
              'other'
            ])
              ListTile(
                leading: const Icon(Icons.flag_rounded),
                title: Text(_reportLabel(r)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (reason == null) return;
    final done = await _run(() async {
      await _api
          .postJson('/circle/groups/$_groupId/report', {'reason': reason});
    });
    if (done) _toast(_t.circleReported);
  }

  String _reportLabel(String r) {
    switch (r) {
      case 'spam':
        return _t.circleReportSpam;
      case 'harassment':
        return _t.circleReportHarassment;
      case 'scam':
        return _t.circleReportScam;
      case 'impersonation':
        return _t.circleReportImpersonation;
      default:
        return _t.circleReportOther;
    }
  }

  int _idOf(Map<String, dynamic> m) {
    final raw = m['id'] ?? m['member_id'] ?? 0;
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t.circleGroupInfo),
        actions: [
          if (_isAdmin)
            IconButton(
              tooltip: _t.circleGroupEditInfo,
              icon: const Icon(Icons.edit_rounded),
              onPressed: _editInfo,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? _errorRetry(scheme)
              : Stack(
                  children: [
                    _content(scheme),
                    if (_busy)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color(0x33000000),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ],
                ),
    );
  }

  /// §21 error state: an honest message + a Retry that re-runs the fetch.
  Widget _errorRetry(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded,
                  size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: Gap.md),
              Text(honestFailText(_t, _failCause, otherwise: _t.grpInfoLoadError),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              FilledButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load,
                label: Text(_t.grpRetry),
              ),
            ],
          ),
        ),
      );

  Widget _content(ColorScheme scheme) => ListView(
              children: [
                _header(scheme),
                const Divider(),
                if (_isAdmin) ...[
                  SwitchListTile(
                    secondary: const Icon(Icons.campaign_rounded),
                    title: Text(_t.circleGroupAnnouncementsOnly),
                    subtitle: Text(_t.circleGroupAnnouncementsHint),
                    value: _group['announcements_only'] == true,
                    onChanged: _toggleAnnouncements,
                  ),
                  ListTile(
                    leading: const Icon(Icons.people_outline_rounded),
                    title: Text(_t.circleGroupSizeLimit),
                    trailing: Text(notifLocalizeDigits(context, '${_group['size_limit'] ?? 256}')),
                    onTap: _editSizeLimit,
                  ),
                  const Divider(),
                ],
                ListTile(
                  leading: const Icon(Icons.link_rounded),
                  title: Text(_t.circleGroupInviteLink),
                  subtitle: Text(_t.circleGroupInviteLinkHint),
                  onTap: _inviteLink,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Gap.lg, Gap.lg, Gap.lg, Gap.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _t.circleGroupMemberCount(notifLocalizeDigits(context, '${_members.length}')),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: scheme.primary),
                        ),
                      ),
                      if (_isAdmin)
                        TextButton.icon(
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: Text(_t.circleGroupAddMembers),
                          onPressed: _addMembers,
                        ),
                    ],
                  ),
                ),
                if (_members.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Gap.lg, vertical: Gap.xl),
                    child: Text(_t.grpRosterEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                else
                  for (final m in _members)
                    CircleGroupMemberTile(
                      member: m,
                      viewerIsAdmin: _isAdmin,
                      adminCount: _adminCount,
                      onPromote: () => _memberAction(m, 'promote'),
                      onDemote: () => _memberAction(m, 'demote'),
                      onRemove: () => _memberAction(m, 'remove'),
                    ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.flag_rounded, color: Brand.warning),
                  title: Text(_t.circleGroupReport),
                  onTap: _report,
                ),
                ListTile(
                  leading: Icon(Icons.logout_rounded, color: Brand.danger),
                  title: Text(_t.circleGroupLeave,
                      style: const TextStyle(color: Brand.danger)),
                  onTap: _leave,
                ),
                const SizedBox(height: Gap.xl),
              ],
            );

  Widget _header(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: scheme.primaryContainer,
              child: const Icon(Icons.groups_rounded, size: 40),
            ),
            const SizedBox(height: Gap.md),
            Text('${_group['name'] ?? ''}',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center),
            if ('${_group['description'] ?? ''}'.trim().isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text('${_group['description']}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      );
}

/// Bottom sheet to pick circle members to add. Returns selected member ids.
class _AddMembersSheet extends StatefulWidget {
  final List<Map<String, dynamic>> candidates;
  const _AddMembersSheet({required this.candidates});
  @override
  State<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends State<_AddMembersSheet> {
  final Set<int> _sel = {};

  int _idOf(Map<String, dynamic> m) {
    final raw = m['id'] ?? m['member_id'] ?? 0;
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final m in widget.candidates)
                  CheckboxListTile(
                    title: Text('${m['name'] ?? ''}'),
                    value: _sel.contains(_idOf(m)),
                    onChanged: (v) => setState(() {
                      final id = _idOf(m);
                      if (v == true) {
                        _sel.add(id);
                      } else {
                        _sel.remove(id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sel.isEmpty
                    ? null
                    : () => Navigator.pop(context, _sel.toList()),
                child: Text(t.circleGroupAddMembers),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
