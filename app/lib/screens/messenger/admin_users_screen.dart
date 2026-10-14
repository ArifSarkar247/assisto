import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_mod_action_dialog.dart';
import '../../widgets/skeleton.dart';

/// ADMIN users directory (OWNER only).
///
/// List / search users by the ALLOWED PUBLIC fields ONLY: name, phone, photo,
/// signup date, plan, last active, app version, report count, status. Actions:
/// suspend / unsuspend / reset-sessions / ban, each with a MANDATORY reason.
/// A user detail also lists their PUBLIC channels/communities.
///
/// HARD PRIVACY GUARANTEE (reflected in the UI): admins never see — and the API
/// never returns or requests — message contents or contact lists. A visible
/// note states this. Original Assisto identity; all copy via AppLocalizations
/// (no Bangla in source). Gate the entry point on the owner flag; the backend
/// also enforces 403.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

enum _Status { loading, ok, error, adminsOnly }

const _statusFilters = <String>['all', 'active', 'suspended', 'banned'];

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  _Status _status = _Status.loading;
  List<Map<String, dynamic>> _users = const [];
  final _search = TextEditingController();
  String _statusFilter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final r = await context.read<AppState>().api.adminUsers(
            query: _search.text,
            status: _statusFilter == 'all' ? null : _statusFilter,
          );
      if (!mounted) return;
      setState(() {
        _users =
            ((r['users'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _status = _Status.ok;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
          () => _status = e.status == 403 ? _Status.adminsOnly : _Status.error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _Status.error);
    }
  }

  void _setStatusFilter(String f) {
    if (_statusFilter == f) return;
    setState(() => _statusFilter = f);
    _load();
  }

  String _statusFilterLabel(AppLocalizations t, String f) {
    switch (f) {
      case 'active':
        return t.msgrModUserStatusActive;
      case 'suspended':
        return t.msgrModUserStatusSuspended;
      case 'banned':
        return t.msgrModUserStatusBanned;
      default:
        return t.msgrModFilterAll;
    }
  }

  Future<void> _openUser(Map<String, dynamic> u) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            AdminUserDetailScreen(userId: u['id'].toString(), summary: u),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrModUsersTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.msgrModUsersSearchHint,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.tune),
                  onPressed: _load,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              children: [
                for (final f in _statusFilters)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: ChoiceChip(
                      label: Text(_statusFilterLabel(t, f)),
                      selected: _statusFilter == f,
                      onSelected: (_) => _setStatusFilter(f),
                    ),
                  ),
              ],
            ),
          ),
          // Visible, standing guarantee that admins never see private data.
          Container(
            margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(children: [
              Icon(Icons.lock_outline, size: 18, color: scheme.secondary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.msgrModUsersPrivacyNote,
                  style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 12.5,
                      height: 1.35),
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (_status) {
              _Status.loading => const SkeletonList(count: 7),
              _Status.adminsOnly => StateMessage(
                  icon: Icons.admin_panel_settings_outlined,
                  title: t.msgrModOwnerOnlyTitle,
                  message: t.msgrModOwnerOnlyBody,
                  tint: scheme.tertiary,
                ),
              _Status.error => StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.msgrModErrorTitle,
                  message: t.msgrModErrorBody,
                  tint: Brand.danger,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.msgrModRetry)),
                ),
              _Status.ok => _users.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: StateMessage(
                            icon: Icons.person_search_outlined,
                            title: t.msgrModUsersEmptyTitle,
                            message: t.msgrModUsersEmptyBody,
                          ),
                        ),
                      ]),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(Gap.lg),
                        itemCount: _users.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) => _UserCard(
                          user: _users[i],
                          onTap: () => _openUser(_users[i]),
                        ),
                      ),
                    ),
            },
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// User detail: public fields + actions + public channels/communities
// ===========================================================================

class AdminUserDetailScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> summary;
  const AdminUserDetailScreen({
    super.key,
    required this.userId,
    required this.summary,
  });

  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  late Map<String, dynamic> _user;
  bool _busy = false;
  bool _changed = false;
  bool _publicLoading = true;
  List<Map<String, dynamic>> _channels = const [];
  List<Map<String, dynamic>> _communities = const [];

  @override
  void initState() {
    super.initState();
    _user = widget.summary;
    _loadPublic();
  }

  Future<void> _loadPublic() async {
    try {
      final r =
          await context.read<AppState>().api.adminUserPublic(widget.userId);
      if (!mounted) return;
      setState(() {
        _channels =
            ((r['channels'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _communities = ((r['communities'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        _publicLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _publicLoading = false);
    }
  }

  Future<void> _act(String action, String label, String description,
      {bool destructive = false}) async {
    final reason = await MsgrModActionDialog.show(
      context,
      actionLabel: label,
      description: description,
      destructive: destructive,
    );
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      final r = await context
          .read<AppState>()
          .api
          .adminUserAction(widget.userId, action, reason);
      if (!mounted) return;
      _changed = true;
      setState(() {
        if (r['status'] != null) {
          _user = {..._user, 'status': r['status']};
        }
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = (_user['status'] ?? 'active').toString();
    final suspended = status == 'suspended';
    final banned = status == 'banned';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(t.msgrModUserDetailTitle)),
        body: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            _UserCard(user: _user, dense: false),
            const SizedBox(height: Gap.lg),

            Text(t.msgrModActionsSection,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                if (!suspended && !banned)
                  _actionBtn(Icons.pause_circle_outline,
                      t.msgrModActionSuspend, Brand.warning, () {
                    _act('suspend', t.msgrModActionSuspend,
                        t.msgrModUserSuspendDesc,
                        destructive: true);
                  }),
                if (suspended)
                  _actionBtn(Icons.play_circle_outline,
                      t.msgrModActionUnsuspend, Brand.success, () {
                    _act('unsuspend', t.msgrModActionUnsuspend,
                        t.msgrModUserUnsuspendDesc);
                  }),
                _actionBtn(Icons.logout, t.msgrModActionResetSessions,
                    scheme.primary, () {
                  _act('reset_sessions', t.msgrModActionResetSessions,
                      t.msgrModUserResetSessionsDesc);
                }),
                if (!banned)
                  _actionBtn(Icons.block, t.msgrModActionBan, Brand.danger, () {
                    _act('ban', t.msgrModActionBan, t.msgrModUserBanDesc,
                        destructive: true);
                  }),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: Gap.md),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: Gap.xl),

            Text(t.msgrModUserPublicSection,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(t.msgrModUserPublicHint,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: Gap.sm),
            if (_publicLoading)
              const SkeletonList(count: 3)
            else if (_channels.isEmpty && _communities.isEmpty)
              Text(t.msgrModUserNoPublic,
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else ...[
              for (final c in _channels)
                _PublicRow(
                    icon: Icons.campaign_outlined,
                    name: (c['name'] ?? '').toString(),
                    status: (c['status'] ?? '').toString()),
              for (final c in _communities)
                _PublicRow(
                    icon: Icons.groups_outlined,
                    name: (c['name'] ?? '').toString(),
                    status: (c['status'] ?? '').toString()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
    );
  }
}

// ===========================================================================
// Shared rows
// ===========================================================================

class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback? onTap;
  final bool dense;
  const _UserCard({required this.user, this.onTap, this.dense = true});

  ({String label, Color color, IconData icon}) _statusPill(
      AppLocalizations t, String s, ColorScheme scheme) {
    switch (s) {
      case 'suspended':
        return (
          label: t.msgrModUserStatusSuspended,
          color: Brand.warning,
          icon: Icons.pause_circle_outline
        );
      case 'banned':
        return (
          label: t.msgrModUserStatusBanned,
          color: Brand.danger,
          icon: Icons.block
        );
      default:
        return (
          label: t.msgrModUserStatusActive,
          color: Brand.success,
          icon: Icons.check_circle_outline
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final loc = t.localeName;
    final name = (user['name'] ?? '').toString();
    final phone = (user['phone'] ?? '').toString();
    final photo = (user['photo_url'] ?? '').toString();
    final plan = (user['plan'] ?? '').toString();
    final status = (user['status'] ?? 'active').toString();
    final reports = (user['report_count'] as num?)?.toInt() ?? 0;
    final signup = (user['signup_date'] ?? '').toString();
    final lastActive = (user['last_active'] ?? '').toString();
    final appVersion = (user['app_version'] ?? '').toString();
    final pill = _statusPill(t, status, scheme);

    final card = Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.primaryContainer,
                backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
                child: photo.isEmpty
                    ? Text(
                        name.isNotEmpty ? name.characters.first : '?',
                        style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w800),
                      )
                    : null,
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? t.msgrModUserNoName : name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (phone.isNotEmpty)
                      Text(_digits(phone, loc),
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              MsgrModStatusPill(
                  label: pill.label, color: pill.color, icon: pill.icon),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.md,
            runSpacing: 4,
            children: [
              if (plan.isNotEmpty)
                _meta(scheme, Icons.workspace_premium_outlined,
                    t.msgrModUserPlan(plan)),
              _meta(
                  scheme,
                  Icons.flag_outlined,
                  t.msgrModReportsCount(_digits(reports.toString(), loc))),
              if (signup.isNotEmpty)
                _meta(scheme, Icons.event_outlined,
                    t.msgrModUserSignup(_digits(signup, loc))),
              if (lastActive.isNotEmpty)
                _meta(scheme, Icons.schedule_outlined,
                    t.msgrModUserLastActive(_digits(lastActive, loc))),
              if (appVersion.isNotEmpty)
                _meta(scheme, Icons.phone_android_outlined,
                    t.msgrModUserAppVersion(_digits(appVersion, loc))),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: card,
      ),
    );
  }

  Widget _meta(ColorScheme scheme, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
      ],
    );
  }
}

class _PublicRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final String status;
  const _PublicRow(
      {required this.icon, required this.name, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        if (status.isNotEmpty && status != 'visible')
          MsgrModStatusPill(
            label: status,
            color: status == 'removed' ? Brand.danger : Brand.warning,
          ),
      ]),
    );
  }
}

/// Bangla-Bengali digits via code points (zero == U+09E6) — no Bangla literal
/// in source. Latin for every other locale.
String _digits(String latin, String localeName) {
  if (!localeName.startsWith('bn')) return latin;
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final ch in latin.runes) {
    b.writeCharCode((ch >= 0x30 && ch <= 0x39) ? bnZero + (ch - 0x30) : ch);
  }
  return b.toString();
}
