import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/admin_filter_bar.dart';
import '../../widgets/admin_notes.dart';
import '../../widgets/msgr_mod_action_dialog.dart';
import '../../widgets/skeleton.dart';

/// ADMIN users directory (OWNER only) — SPEC v2.1 §21 #174, ADVANCED.
///
/// List / search users by the ALLOWED PUBLIC fields ONLY: name, phone, photo,
/// signup date, plan, last active, app version, report count, status. The
/// directory adds a reviewer-grade control surface: free-text search, status +
/// plan + report-count filters, a sort picker (recent / most-reported / name),
/// an honest result-count header, and client-side pagination ("show more") so
/// large result sets stay responsive. Per-user detail shows the public
/// projection plus the user's PUBLIC channels/communities, and the actions
/// suspend / unsuspend / reset-sessions / ban each demand a MANDATORY reason
/// with a confirm step; every action is audited.
///
/// HARD PRIVACY GUARANTEE (reflected in the UI): admins never see — and the API
/// never returns or requests — message contents or contact lists. A visible
/// [AdminPrivacyNote] states this. Original Assisto identity; all copy via
/// [AppLocalizations] (no Bangla in source). The entry point is gated on the
/// owner flag; the backend also enforces 403 (surfaced as the owner-only state).
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

enum _Status { loading, ok, error, adminsOnly }

const _pageSize = 20;

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  _Status _status = _Status.loading;
  List<Map<String, dynamic>> _users = const [];
  final _search = TextEditingController();
  String _statusFilter = 'all';
  String _plan = 'all';
  bool _reportedOnly = false;
  String _sort = 'recent';
  int _shown = _pageSize;

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
        _shown = _pageSize;
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

  // ---- derived view (client-side plan/reports filter + sort + paginate) ----

  List<Map<String, dynamic>> get _visible {
    var rows = _users.where((u) {
      if (_plan != 'all' && (u['plan'] ?? '').toString() != _plan) return false;
      if (_reportedOnly && ((u['report_count'] as num?)?.toInt() ?? 0) <= 0) {
        return false;
      }
      return true;
    }).toList();
    rows.sort((a, b) {
      switch (_sort) {
        case 'reports':
          return ((b['report_count'] as num?)?.toInt() ?? 0)
              .compareTo((a['report_count'] as num?)?.toInt() ?? 0);
        case 'name':
          return (a['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b['name'] ?? '').toString().toLowerCase());
        default: // recent — by last_active desc (string ISO sorts correctly)
          return (b['last_active'] ?? '')
              .toString()
              .compareTo((a['last_active'] ?? '').toString());
      }
    });
    return rows;
  }

  Set<String> get _plans {
    final s = <String>{};
    for (final u in _users) {
      final p = (u['plan'] ?? '').toString();
      if (p.isNotEmpty) s.add(p);
    }
    return s;
  }

  void _setStatusFilter(String f) {
    if (_statusFilter == f) return;
    setState(() => _statusFilter = f);
    _load(); // status is a server-side filter
  }

  Future<void> _openSort() async {
    final t = AppLocalizations.of(context);
    final v = await AdminSortSheet.show(
      context,
      title: t.msgrModSortTitle,
      selected: _sort,
      options: [
        AdminChoice('recent', t.msgrModSortRecent, icon: Icons.schedule_rounded),
        AdminChoice('reports', t.msgrModSortReports, icon: Icons.flag_rounded),
        AdminChoice('name', t.msgrModSortName, icon: Icons.sort_by_alpha_rounded),
      ],
    );
    if (v != null && v != _sort) setState(() => _sort = v);
  }

  Future<void> _openFilters() async {
    final t = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.msgrModFiltersTitle,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.md),
                Text(t.msgrModUserPlan('').trim(),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.sm, children: [
                  ChoiceChip(
                    label: Text(t.msgrModFilterAll),
                    selected: _plan == 'all',
                    onSelected: (_) => setSheet(() => _plan = 'all'),
                  ),
                  for (final p in _plans)
                    ChoiceChip(
                      label: Text(p),
                      selected: _plan == p,
                      onSelected: (_) => setSheet(() => _plan = p),
                    ),
                ]),
                const SizedBox(height: Gap.md),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _reportedOnly,
                  title: Text(t.msgrModFilterReportedOnly),
                  onChanged: (v) => setSheet(() => _reportedOnly = v),
                ),
                const SizedBox(height: Gap.sm),
                Row(children: [
                  TextButton(
                    onPressed: () => setSheet(() {
                      _plan = 'all';
                      _reportedOnly = false;
                    }),
                    child: Text(t.msgrModFiltersReset),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(t.msgrModFiltersApply),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
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

  String _sortLabel(AppLocalizations t) {
    switch (_sort) {
      case 'reports':
        return t.msgrModSortReports;
      case 'name':
        return t.msgrModSortName;
      default:
        return t.msgrModSortRecent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final List<Map<String, dynamic>> visible =
        _status == _Status.ok ? _visible : const [];
    final activeFilters =
        (_plan != 'all' ? 1 : 0) + (_reportedOnly ? 1 : 0);
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
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: t.msgrModUsersSearchHint,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_search.text.isNotEmpty)
                      IconButton(
                        tooltip: t.msgrModClear,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _search.clear();
                          _load();
                        },
                      ),
                    Badge(
                      isLabelVisible: activeFilters > 0,
                      label: Text('$activeFilters'),
                      child: IconButton(
                        tooltip: t.msgrModFiltersTitle,
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: _openFilters,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AdminFilterRail(
            selected: _statusFilter,
            onSelected: _setStatusFilter,
            choices: [
              AdminChoice('all', t.msgrModFilterAll),
              AdminChoice('active', t.msgrModUserStatusActive,
                  icon: Icons.check_circle_outline_rounded),
              AdminChoice('suspended', t.msgrModUserStatusSuspended,
                  icon: Icons.pause_circle_outline_rounded),
              AdminChoice('banned', t.msgrModUserStatusBanned,
                  icon: Icons.block_rounded),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: AdminPrivacyNote(text: t.msgrModUsersPrivacyNote),
          ),
          if (_status == _Status.ok)
            AdminListHeader(
              countLabel:
                  t.msgrModResultsCount(_digits(visible.length.toString(), t.localeName)),
              sortLabel: _sortLabel(t),
              onSort: _openSort,
            ),
          const Divider(height: 1),
          Expanded(
            child: switch (_status) {
              _Status.loading => const SkeletonList(count: 7),
              _Status.adminsOnly => StateMessage(
                  icon: Icons.admin_panel_settings_rounded,
                  title: t.msgrModOwnerOnlyTitle,
                  message: t.msgrModOwnerOnlyBody,
                  tint: scheme.tertiary,
                ),
              _Status.error => StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.msgrModErrorTitle,
                  message: t.msgrModErrorBody,
                  tint: Brand.danger,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.msgrModRetry)),
                ),
              _Status.ok => visible.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: StateMessage(
                            icon: Icons.person_search_rounded,
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
                        itemCount: (visible.length > _shown ? _shown : visible.length) +
                            (visible.length > _shown ? 1 : 0),
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) {
                          final limit = visible.length > _shown ? _shown : visible.length;
                          if (i >= limit) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.only(top: Gap.sm),
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      setState(() => _shown += _pageSize),
                                  icon: const Icon(Icons.expand_more_rounded),
                                  label: Text(t.msgrModShowMore),
                                ),
                              ),
                            );
                          }
                          return _UserCard(
                            user: visible[i],
                            onTap: () => _openUser(visible[i]),
                          );
                        },
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
  bool _publicError = false;
  List<Map<String, dynamic>> _channels = const [];
  List<Map<String, dynamic>> _communities = const [];

  @override
  void initState() {
    super.initState();
    _user = widget.summary;
    _loadPublic();
  }

  Future<void> _loadPublic() async {
    setState(() {
      _publicLoading = true;
      _publicError = false;
    });
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
      setState(() {
        _publicLoading = false;
        _publicError = true;
      });
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
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.msgrModActionDone(label))));
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
            const SizedBox(height: Gap.md),
            AdminPrivacyNote(text: t.msgrModUsersPrivacyNote),
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
                  _actionBtn(Icons.pause_circle_outline_rounded,
                      t.msgrModActionSuspend, Brand.warning, () {
                    _act('suspend', t.msgrModActionSuspend,
                        t.msgrModUserSuspendDesc,
                        destructive: true);
                  }),
                if (suspended)
                  _actionBtn(Icons.play_circle_outline_rounded,
                      t.msgrModActionUnsuspend, Brand.success, () {
                    _act('unsuspend', t.msgrModActionUnsuspend,
                        t.msgrModUserUnsuspendDesc);
                  }),
                _actionBtn(Icons.logout_rounded, t.msgrModActionResetSessions,
                    scheme.primary, () {
                  _act('reset_sessions', t.msgrModActionResetSessions,
                      t.msgrModUserResetSessionsDesc);
                }),
                if (!banned)
                  _actionBtn(Icons.block_rounded, t.msgrModActionBan, Brand.danger, () {
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
            else if (_publicError)
              Row(children: [
                Expanded(
                  child: Text(t.msgrModErrorBody,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                TextButton(
                    onPressed: _loadPublic, child: Text(t.msgrModRetry)),
              ])
            else if (_channels.isEmpty && _communities.isEmpty)
              Text(t.msgrModUserNoPublic,
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else ...[
              for (final c in _channels)
                _PublicRow(
                    icon: Icons.campaign_rounded,
                    name: (c['name'] ?? '').toString(),
                    status: (c['status'] ?? '').toString()),
              for (final c in _communities)
                _PublicRow(
                    icon: Icons.groups_rounded,
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
          icon: Icons.pause_circle_outline_rounded
        );
      case 'banned':
        return (
          label: t.msgrModUserStatusBanned,
          color: Brand.danger,
          icon: Icons.block_rounded
        );
      default:
        return (
          label: t.msgrModUserStatusActive,
          color: Brand.success,
          icon: Icons.check_circle_outline_rounded
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
        border: Border.all(
          color: reports > 0 && dense
              ? Brand.warning.withValues(alpha: 0.4)
              : scheme.outlineVariant,
        ),
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
                Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.md,
            runSpacing: 4,
            children: [
              if (plan.isNotEmpty)
                _meta(scheme, Icons.workspace_premium_rounded,
                    t.msgrModUserPlan(plan)),
              _meta(
                  scheme,
                  Icons.flag_rounded,
                  t.msgrModReportsCount(_digits(reports.toString(), loc))),
              if (signup.isNotEmpty)
                _meta(scheme, Icons.event_rounded,
                    t.msgrModUserSignup(_digits(signup, loc))),
              if (lastActive.isNotEmpty)
                _meta(scheme, Icons.schedule_rounded,
                    t.msgrModUserLastActive(_digits(lastActive, loc))),
              if (appVersion.isNotEmpty)
                _meta(scheme, Icons.phone_android_rounded,
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
