import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_mod_action_dialog.dart';
import '../../widgets/skeleton.dart';

/// ADMIN moderation review queue (operator / owner only).
///
/// Each queued item shows its reason(s), report count, severity and status.
/// One-tap Remove / Restore / Warn / Suspend / Ban — every action requires a
/// MANDATORY written reason (via [MsgrModActionDialog]) that the backend
/// audits. Resolved items can be reopened. Tapping an item opens its detail
/// with the full append-only audit trail.
///
/// This screen governs PUBLIC surfaces only. It never shows — and the API
/// never returns — message contents or contact lists. Honest states throughout
/// (loading / empty / error / admins-only). Original Assisto identity; all copy
/// via AppLocalizations (no Bangla in source). Gate the entry point on the
/// user's operator/owner flag; the backend also enforces 403.
class AdminModerationScreen extends StatefulWidget {
  const AdminModerationScreen({super.key});

  @override
  State<AdminModerationScreen> createState() => _AdminModerationScreenState();
}

enum _Status { loading, ok, error, adminsOnly }

const _filters = <String>['all', 'severe', 'legal', 'appeals'];

class _AdminModerationScreenState extends State<AdminModerationScreen> {
  _Status _status = _Status.loading;
  List<Map<String, dynamic>> _items = const [];
  String _filter = 'all';

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

  String _filterLabel(AppLocalizations t, String f) {
    switch (f) {
      case 'severe':
        return t.msgrModFilterSevere;
      case 'legal':
        return t.msgrModFilterLegal;
      case 'appeals':
        return t.msgrModFilterAppeals;
      default:
        return t.msgrModFilterAll;
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
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrModQueueTitle)),
      body: Column(
        children: [
          // Standing privacy guarantee — admins never see message contents.
          _PrivacyBanner(text: t.msgrModAdminPrivacyNote),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              children: [
                for (final f in _filters)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: ChoiceChip(
                      label: Text(_filterLabel(t, f)),
                      selected: _filter == f,
                      onSelected: (_) => _setFilter(f),
                    ),
                  ),
              ],
            ),
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
              _Status.ok => _items.isEmpty
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
                      child: ListView.separated(
                        padding: const EdgeInsets.all(Gap.lg),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Gap.md),
                        itemBuilder: (_, i) => _QueueCard(
                          item: _items[i],
                          onTap: () => _openItem(_items[i]),
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
    final resolved = (_item['queue_state'] ?? '') == 'resolved';

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
                  const SizedBox(height: Gap.lg),
                  _PrivacyBanner(text: t.msgrModAdminPrivacyNote),
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
                      if (resolved)
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
                  Text(t.msgrModAuditSection,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: Gap.sm),
                  if (_audit.isEmpty)
                    Text(t.msgrModAuditEmpty,
                        style: TextStyle(color: scheme.onSurfaceVariant))
                  else
                    for (final a in _audit) _AuditRow(entry: a),
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

class _AuditRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _AuditRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final action = (entry['action'] ?? '').toString();
    final reason = (entry['reason'] ?? '').toString();
    final at = (entry['at'] ?? entry['created_at'] ?? '').toString();
    final actor = (entry['actor'] ?? entry['actor_id'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(msgrModActionPastLabel(t, action),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (reason.isNotEmpty)
                  Text(reason,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, height: 1.35)),
                const SizedBox(height: 2),
                Text(
                  [
                    if (actor.isNotEmpty) t.msgrModAuditActor(actor),
                    if (at.isNotEmpty) at,
                  ].join(' · '),
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyBanner extends StatelessWidget {
  final String text;
  const _PrivacyBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
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
            text,
            style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontSize: 12.5,
                height: 1.35),
          ),
        ),
      ]),
    );
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
