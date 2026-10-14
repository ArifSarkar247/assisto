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

/// ADMIN moderation review queue (operator / owner only) — SPEC v2.1 §21 #175,
/// ADVANCED.
///
/// A reviewer-grade queue: items are grouped by severity so severe /
/// auto-hidden content surfaces FIRST, each card shows its reports / reasons /
/// count / legal flag, and one tap opens the full item with an append-only
/// audit timeline. One-tap Remove / Restore / Warn / Suspend / Ban — every
/// action requires a MANDATORY written reason (via [MsgrModActionDialog]) that
/// the backend audits; resolved items can be reopened and appeals reviewed.
/// Filters (all / severe / legal / appeals), a sort picker, an honest result
/// count, and a standing "records kept for legally-required reporting" note
/// complete the surface.
///
/// This screen governs PUBLIC surfaces only. It never shows — and the API
/// never returns — message contents or contact lists ([AdminPrivacyNote]).
/// Honest states throughout (loading / empty / error / admins-only). Original
/// Assisto identity; all copy via [AppLocalizations] (no Bangla in source).
/// The entry point is gated on the user's operator/owner flag; the backend
/// also enforces 403 (surfaced as the admins-only state).
class AdminModerationScreen extends StatefulWidget {
  const AdminModerationScreen({super.key});

  @override
  State<AdminModerationScreen> createState() => _AdminModerationScreenState();
}

enum _Status { loading, ok, error, adminsOnly }

class _AdminModerationScreenState extends State<AdminModerationScreen> {
  _Status _status = _Status.loading;
  List<Map<String, dynamic>> _items = const [];
  String _filter = 'all';
  String _sort = 'severity';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final r = await context.read<AppState>().api.adminModerationQueue(
          filter: _filter == 'all' ? null : _filter);
      if (!mounted) return;
      setState(() {
        _items =
            ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
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

  void _setFilter(String f) {
    if (_filter == f) return;
    setState(() => _filter = f);
    _load();
  }

  // Order within the queue. "severity" keeps severe/auto-hidden on top (the
  // owner-required reviewer order); the others are plain stable sorts.
  List<Map<String, dynamic>> get _sorted {
    final rows = List<Map<String, dynamic>>.from(_items);
    int reports(Map<String, dynamic> m) =>
        (m['report_count'] as num?)?.toInt() ?? 0;
    bool severe(Map<String, dynamic> m) => m['severe'] == true;
    bool hidden(Map<String, dynamic> m) =>
        (m['content_status'] ?? '') == 'hidden';
    int rank(Map<String, dynamic> m) =>
        severe(m) ? 0 : (hidden(m) ? 1 : 2);
    rows.sort((a, b) {
      switch (_sort) {
        case 'reports':
          return reports(b).compareTo(reports(a));
        case 'recent':
          return (b['opened_at'] ?? '')
              .toString()
              .compareTo((a['opened_at'] ?? '').toString());
        default: // severity: severe -> auto-hidden -> rest, then by reports.
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : reports(b).compareTo(reports(a));
      }
    });
    return rows;
  }

  Future<void> _openSort() async {
    final t = AppLocalizations.of(context);
    final v = await AdminSortSheet.show(
      context,
      title: t.msgrModSortTitle,
      selected: _sort,
      options: [
        AdminChoice('severity', t.msgrModSortSeverity,
            icon: Icons.priority_high),
        AdminChoice('reports', t.msgrModSortReports, icon: Icons.flag_outlined),
        AdminChoice('recent', t.msgrModSortRecent, icon: Icons.schedule),
      ],
    );
    if (v != null && v != _sort) setState(() => _sort = v);
  }

  String _sortLabel(AppLocalizations t) {
    switch (_sort) {
      case 'reports':
        return t.msgrModSortReports;
      case 'recent':
        return t.msgrModSortRecent;
      default:
        return t.msgrModSortSeverity;
    }
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AdminModerationItemScreen(
          itemId: item['id'].toString(),
          summary: item,
        ),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final List<Map<String, dynamic>> rows =
        _status == _Status.ok ? _sorted : const [];
    // Split so a visible "severe first" subheader can anchor the queue.
    final severe = rows.where((m) => m['severe'] == true).toList();
    final rest = rows.where((m) => m['severe'] != true).toList();

    return Scaffold(
      appBar: AppBar(title: Text(t.msgrModQueueTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
            child: AdminPrivacyNote(text: t.msgrModAdminPrivacyNote),
          ),
          const SizedBox(height: Gap.sm),
          AdminFilterRail(
            selected: _filter,
            onSelected: _setFilter,
            choices: [
              AdminChoice('all', t.msgrModFilterAll),
              AdminChoice('severe', t.msgrModFilterSevere,
                  icon: Icons.priority_high),
              AdminChoice('legal', t.msgrModFilterLegal,
                  icon: Icons.account_balance_outlined),
              AdminChoice('appeals', t.msgrModFilterAppeals,
                  icon: Icons.gavel_outlined),
            ],
          ),
          if (_status == _Status.ok)
            AdminListHeader(
              countLabel: t.msgrModResultsCount(
                  _digits(rows.length.toString(), t.localeName)),
              sortLabel: _sortLabel(t),
              onSort: _openSort,
            ),
          const Divider(height: 1),
          Expanded(
            child: switch (_status) {
              _Status.loading => const SkeletonList(count: 6),
              _Status.adminsOnly => StateMessage(
                  icon: Icons.admin_panel_settings_outlined,
                  title: t.msgrModAdminsOnlyTitle,
                  message: t.msgrModAdminsOnlyBody,
                  tint: Theme.of(context).colorScheme.tertiary,
                ),
              _Status.error => StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.msgrModErrorTitle,
                  message: t.msgrModErrorBody,
                  tint: Brand.danger,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.msgrModRetry)),
                ),
              _Status.ok => rows.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.55,
                          child: StateMessage(
                            icon: Icons.inbox_outlined,
                            title: t.msgrModQueueEmptyTitle,
                            message: t.msgrModQueueEmptyBody,
                          ),
                        ),
                      ]),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(Gap.lg),
                        children: [
                          if (_sort == 'severity' && severe.isNotEmpty) ...[
                            _GroupHeader(
                              icon: Icons.gpp_maybe,
                              color: Brand.danger,
                              label: t.msgrModGroupSevere,
                            ),
                            const SizedBox(height: Gap.sm),
                            for (final it in severe) ...[
                              _QueueCard(item: it, onTap: () => _openItem(it)),
                              const SizedBox(height: Gap.md),
                            ],
                            if (rest.isNotEmpty) ...[
                              _GroupHeader(
                                icon: Icons.flag_outlined,
                                color:
                                    Theme.of(context).colorScheme.onSurfaceVariant,
                                label: t.msgrModGroupOther,
                              ),
                              const SizedBox(height: Gap.sm),
                            ],
                            for (final it in rest) ...[
                              _QueueCard(item: it, onTap: () => _openItem(it)),
                              const SizedBox(height: Gap.md),
                            ],
                          ] else
                            for (final it in rows) ...[
                              _QueueCard(item: it, onTap: () => _openItem(it)),
                              const SizedBox(height: Gap.md),
                            ],
                        ],
                      ),
                    ),
            },
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _GroupHeader(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 13)),
    ]);
  }
}

// ===========================================================================
// Item detail + actions + audit trail
// ===========================================================================

class AdminModerationItemScreen extends StatefulWidget {
  final String itemId;
  final Map<String, dynamic> summary;
  const AdminModerationItemScreen({
    super.key,
    required this.itemId,
    required this.summary,
  });

  @override
  State<AdminModerationItemScreen> createState() =>
      _AdminModerationItemScreenState();
}

class _AdminModerationItemScreenState extends State<AdminModerationItemScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;
  String? _error;
  Map<String, dynamic> _item = const {};
  List<Map<String, dynamic>> _audit = const [];

  @override
  void initState() {
    super.initState();
    _item = widget.summary;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r =
          await context.read<AppState>().api.adminModerationItem(widget.itemId);
      if (!mounted) return;
      setState(() {
        _item = ((r['item'] as Map?)?.cast<String, dynamic>()) ?? _item;
        _audit =
            ((r['audit'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
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
          .adminModerationAction(widget.itemId, action, reason);
      if (!mounted) return;
      _changed = true;
      setState(() {
        if (r['content_status'] != null) {
          _item = {..._item, 'content_status': r['content_status']};
        }
        if (r['decision'] != null) {
          _item = {..._item, 'decision': r['decision']};
        }
        _busy = false;
      });
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.msgrModActionDone(label))));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _reopen() async {
    final t = AppLocalizations.of(context);
    final reason = await MsgrModActionDialog.show(
      context,
      actionLabel: t.msgrModReopen,
      description: t.msgrModReopenDesc,
    );
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      await context
          .read<AppState>()
          .api
          .adminModerationReopen(widget.itemId, reason);
      if (!mounted) return;
      _changed = true;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.msgrModActionDone(t.msgrModReopen))));
      _load();
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
    final queueState = (_item['queue_state'] ?? '').toString();
    final resolved = queueState == 'resolved';
    final underAppeal = queueState == 'under_appeal';
    final legal = _item['legal_retention'] == true;

    return Scaffold(
      appBar: AppBar(title: Text(t.msgrModItemTitle)),
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(context).pop(_changed);
        },
        child: _loading
            ? const SkeletonList(count: 5)
            : ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  _QueueCard(item: _item, dense: false),
                  const SizedBox(height: Gap.md),
                  if (underAppeal) ...[
                    _AppealBanner(t: t),
                    const SizedBox(height: Gap.md),
                  ],
                  AdminPrivacyNote(text: t.msgrModAdminPrivacyNote),
                  if (legal) ...[
                    const SizedBox(height: Gap.sm),
                    AdminLegalNote(text: t.msgrModLegalRetentionNote),
                  ],
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
                      _actionBtn(Icons.visibility_off_outlined,
                          t.msgrModActionRemove, Brand.danger, () {
                        _act('remove', t.msgrModActionRemove,
                            t.msgrModActionRemoveDesc,
                            destructive: true);
                      }),
                      _actionBtn(Icons.restore_outlined,
                          t.msgrModActionRestore, Brand.success, () {
                        _act('restore', t.msgrModActionRestore,
                            t.msgrModActionRestoreDesc);
                      }),
                      _actionBtn(Icons.warning_amber_outlined,
                          t.msgrModActionWarn, Brand.warning, () {
                        _act('warn', t.msgrModActionWarn,
                            t.msgrModActionWarnDesc);
                      }),
                      _actionBtn(Icons.pause_circle_outline,
                          t.msgrModActionSuspend, Brand.warning, () {
                        _act('suspend', t.msgrModActionSuspend,
                            t.msgrModActionSuspendDesc,
                            destructive: true);
                      }),
                      _actionBtn(Icons.block, t.msgrModActionBan, Brand.danger,
                          () {
                        _act('ban', t.msgrModActionBan, t.msgrModActionBanDesc,
                            destructive: true);
                      }),
                      if (resolved || underAppeal)
                        _actionBtn(Icons.refresh, t.msgrModReopen,
                            scheme.primary, _reopen),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: Gap.md),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: Gap.md),
                    Text(_error!, style: const TextStyle(color: Brand.danger)),
                  ],
                  const SizedBox(height: Gap.xl),
                  Row(children: [
                    Text(t.msgrModAuditSection,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(width: Gap.sm),
                    Icon(Icons.lock_clock_outlined,
                        size: 16, color: scheme.onSurfaceVariant),
                  ]),
                  const SizedBox(height: Gap.xs),
                  Text(t.msgrModAuditAppendOnlyNote,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: Gap.sm),
                  if (_audit.isEmpty)
                    Text(t.msgrModAuditEmpty,
                        style: TextStyle(color: scheme.onSurfaceVariant))
                  else
                    for (int i = 0; i < _audit.length; i++)
                      _AuditTimeline(
                        entry: _audit[i],
                        isFirst: i == 0,
                        isLast: i == _audit.length - 1,
                      ),
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

/// Shown at the top of an item that a user has appealed — prompts the reviewer
/// to re-decide (the "appeals review + reopen" half of §175).
class _AppealBanner extends StatelessWidget {
  final AppLocalizations t;
  const _AppealBanner({required this.t});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(Icons.gavel_outlined, size: 18, color: scheme.tertiary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.msgrModAppealOpenTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(t.msgrModAppealOpenBody,
                  style: TextStyle(
                      color: scheme.onSurface, fontSize: 12.5, height: 1.35)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Shared pieces
// ===========================================================================

/// One queue item. In the list it's a tappable card; in the detail it's the
/// non-tappable header (dense:false).
class _QueueCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback? onTap;
  final bool dense;
  const _QueueCard({required this.item, this.onTap, this.dense = true});

  String _kindLabel(AppLocalizations t, String kind) {
    switch (kind) {
      case 'channel':
        return t.msgrModTargetChannel;
      case 'post':
        return t.msgrModTargetPost;
      case 'community':
        return t.msgrModTargetCommunity;
      case 'group':
        return t.msgrModTargetGroup;
      case 'person':
        return t.msgrModTargetPerson;
      default:
        return t.msgrModTargetContent;
    }
  }

  String _reasonLabel(AppLocalizations t, String code) =>
      msgrModReasonLabel(t, code);

  ({String label, Color color, IconData icon}) _statusPill(
      AppLocalizations t, String s, ColorScheme scheme) {
    switch (s) {
      case 'hidden':
        return (
          label: t.msgrModStatusHidden,
          color: Brand.warning,
          icon: Icons.visibility_off_outlined
        );
      case 'removed':
        return (
          label: t.msgrModStatusRemoved,
          color: Brand.danger,
          icon: Icons.delete_outline
        );
      case 'restored':
        return (
          label: t.msgrModStatusRestored,
          color: Brand.success,
          icon: Icons.restore_outlined
        );
      default:
        return (
          label: t.msgrModStatusVisible,
          color: scheme.primary,
          icon: Icons.visibility_outlined
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final kind = (item['target_kind'] ?? '').toString();
    final categories =
        ((item['categories'] as List?) ?? const []).map((e) => e.toString());
    final severe = item['severe'] == true;
    final reports = (item['report_count'] as num?)?.toInt() ?? 0;
    final contentStatus = (item['content_status'] ?? 'visible').toString();
    final legal = item['legal_retention'] == true;
    final pill = _statusPill(t, contentStatus, scheme);
    final loc = t.localeName;

    final card = Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: severe
              ? Brand.danger.withValues(alpha: 0.5)
              : scheme.outlineVariant,
          width: severe ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                severe ? Icons.gpp_maybe : Icons.flag_outlined,
                color: severe ? Brand.danger : scheme.primary,
                size: 20,
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.msgrModQueueItemHeader(
                      _kindLabel(t, kind), item['target_id'].toString()),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                  maxLines: dense ? 1 : 3,
                  overflow: dense ? TextOverflow.ellipsis : TextOverflow.visible,
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.sm,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              MsgrModStatusPill(
                  label: pill.label, color: pill.color, icon: pill.icon),
              if (severe)
                MsgrModStatusPill(
                    label: t.msgrModSevereBadge,
                    color: Brand.danger,
                    icon: Icons.priority_high),
              if (legal)
                MsgrModStatusPill(
                    label: t.msgrModLegalBadge,
                    color: Brand.purple,
                    icon: Icons.account_balance_outlined),
              MsgrModStatusPill(
                label: t.msgrModReportsCount(_digits(reports.toString(), loc)),
                color: scheme.onSurfaceVariant,
                icon: Icons.flag_outlined,
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Text(
            categories.isEmpty
                ? t.msgrModNoReason
                : categories.map((c) => _reasonLabel(t, c)).join('  •  '),
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            maxLines: dense ? 2 : 10,
            overflow: dense ? TextOverflow.ellipsis : TextOverflow.visible,
          ),
          if (!dense && (item['decision'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(
              t.msgrModLastDecision(item['decision'].toString()),
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  fontSize: 13),
            ),
          ],
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
}

/// Audit row rendered on the shared [AdminTimelineEntry] rail, with a
/// per-action icon/colour so a reviewer can scan the history at a glance.
class _AuditTimeline extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool isFirst;
  final bool isLast;
  const _AuditTimeline(
      {required this.entry, required this.isFirst, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final action = (entry['action'] ?? '').toString();
    final reason = (entry['reason'] ?? '').toString();
    final at = (entry['at'] ?? entry['created_at'] ?? '').toString();
    final actor = (entry['actor'] ?? entry['actor_id'] ?? '').toString();
    final visual = _visual(action, scheme);
    return AdminTimelineEntry(
      icon: visual.icon,
      color: visual.color,
      title: msgrModActionPastLabel(t, action),
      reason: reason,
      meta: [
        if (actor.isNotEmpty) t.msgrModAuditActor(actor),
        if (at.isNotEmpty) at,
      ].join(' · '),
      isFirst: isFirst,
      isLast: isLast,
    );
  }

  ({IconData icon, Color color}) _visual(String action, ColorScheme scheme) {
    switch (action) {
      case 'remove':
      case 'ban':
        return (icon: Icons.block, color: Brand.danger);
      case 'restore':
        return (icon: Icons.restore_outlined, color: Brand.success);
      case 'warn':
      case 'suspend':
        return (icon: Icons.warning_amber_outlined, color: Brand.warning);
      case 'appeal':
        return (icon: Icons.gavel_outlined, color: scheme.tertiary);
      case 'reopen':
        return (icon: Icons.refresh, color: scheme.primary);
      case 'report':
        return (icon: Icons.flag_outlined, color: scheme.onSurfaceVariant);
      default:
        return (icon: Icons.circle, color: scheme.primary);
    }
  }
}

// ---- shared label + digit helpers (reused by users screen too) ----

/// Localized label for a normalized moderation reason code. Kept as a
/// top-level function so both admin screens and the report sheet logic agree.
String msgrModReasonLabel(AppLocalizations t, String code) {
  switch (code) {
    case 'child_safety':
      return t.msgrModReasonChildSafety;
    case 'violent_threat':
      return t.msgrModReasonViolentThreat;
    case 'terrorism':
      return t.msgrModReasonTerrorism;
    case 'scam_fraud':
      return t.msgrModReasonScamFraud;
    case 'harassment':
      return t.msgrModReasonHarassment;
    case 'hate_speech':
      return t.msgrModReasonHateSpeech;
    case 'self_harm':
      return t.msgrModReasonSelfHarm;
    case 'nudity':
      return t.msgrModReasonNudity;
    case 'impersonation':
      return t.msgrModReasonImpersonation;
    case 'misinformation':
      return t.msgrModReasonMisinformation;
    case 'spam':
      return t.msgrModReasonSpam;
    default:
      return t.msgrModReasonOther;
  }
}

/// Past-tense label for an audited admin action.
String msgrModActionPastLabel(AppLocalizations t, String action) {
  switch (action) {
    case 'remove':
      return t.msgrModAuditRemoved;
    case 'restore':
      return t.msgrModAuditRestored;
    case 'warn':
      return t.msgrModAuditWarned;
    case 'suspend':
      return t.msgrModAuditSuspended;
    case 'ban':
      return t.msgrModAuditBanned;
    case 'unsuspend':
      return t.msgrModAuditUnsuspended;
    case 'reset_sessions':
      return t.msgrModAuditResetSessions;
    case 'reopen':
      return t.msgrModAuditReopened;
    case 'appeal':
      return t.msgrModAuditAppealed;
    case 'report':
      return t.msgrModAuditReported;
    default:
      return action;
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
