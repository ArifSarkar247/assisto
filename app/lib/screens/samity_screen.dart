import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/samity_rent_common.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// SAMITY / COMMITTEE tracker (Samity, feature #184, SPEC v2.1 section 20, built
/// to the section 21 ADVANCED standard).
///
/// A rotating-savings (ROSCA) tracker: a fixed circle of MEMBERS each contribute
/// the same amount every CYCLE, and in each cycle the pot is handed to one member
/// whose turn it is — until everyone has received once. The decision math (who
/// has paid this cycle, collected vs. pending, whose turn is next) is a PURE
/// function computed client-side by samity_rent_common.dart (mirrors
/// backend/core/logic/samity.py), so it works OFFLINE and matches the server.
///
/// HONESTY (structural, not cosmetic):
///   • We NEVER hold money (kHoldsMoney=false) and NEVER charge (kChargesMoney).
///     The pot is handed over by the members themselves; the app only RECORDS it.
///   • Every per-cycle figure reconciles: expected == collected + pending. The
///     rotation is the members' own agreed order, never random.
///
/// PERSISTENCE: generic owned collections via the existing api helpers —
///   samity_groups        : the samity header (name/amount/period)
///   samity_members        : members, each {samity_id, name, payout_order, active}
///   samity_contributions  : {samity_id, member_id, cycle, paid/paid_poisha}
///   samity_payouts        : {samity_id, cycle, member_id, handed_over}
/// See .phaseB/up_samityrent_integration.md for exact row shapes + the viewsets
/// the integrator registers. Degrades gracefully before the endpoints land.
class SamityScreen extends StatefulWidget {
  const SamityScreen({super.key});
  @override
  State<SamityScreen> createState() => _SamityScreenState();
}

class _SamityScreenState extends State<SamityScreen> {
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _groups = await context.read<AppState>().api.listItems(kColSamity);
      _offline = false;
    } catch (e) {
      if (_groups.isEmpty) {
        _error = true;
        _failCause = e;
      } else {
        _offline = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addOrEditGroup([Map<String, dynamic>? g]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _SamityEditSheet(group: g),
    );
    if (result == null || !mounted) return;
    final api = context.read<AppState>().api;
    if (g != null && g['id'] != null) {
      await api.updateItem(kColSamity, g['id'] as int, result);
    } else {
      await api.createItem(kColSamity, result);
    }
    await _load();
  }

  Future<void> _deleteGroup(Map<String, dynamic> g) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.samityDeleteTitle),
        content: Text(t.samityDeleteBody('${g['name'] ?? ''}')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().api.deleteItem(kColSamity, g['id'] as int);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.samityTitle)),
      floatingActionButton: _groups.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEditGroup(),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.samityNew),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.samityLoadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.commonLoadFailedBody),
                  action: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(t.retry),
                  ),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_groups.isEmpty) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl),
        StateMessage(
          icon: Icons.groups_2_rounded,
          title: t.samityEmptyTitle,
          message: t.samityEmptyBody,
          action: FilledButton.icon(
            onPressed: () => _addOrEditGroup(),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.samityNew),
          ),
        ),
      ]);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        if (_offline) ...[
          _OfflineBar(text: t.commonOffline),
          const SizedBox(height: Gap.sm),
        ],
        NoMoneyBanner(text: t.samityNoMoneyBanner),
        const SizedBox(height: Gap.md),
        for (final g in _groups) ...[
          _SamityCard(
            group: g,
            onOpen: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SamityDetailScreen(group: g))),
            onEdit: () => _addOrEditGroup(g),
            onDelete: () => _deleteGroup(g),
          ),
          const SizedBox(height: Gap.md),
        ],
      ],
    );
  }
}

class _SamityCard extends StatelessWidget {
  final Map<String, dynamic> group;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _SamityCard(
      {required this.group,
      required this.onOpen,
      required this.onEdit,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final members = (group['members'] as List? ?? const []);
    final active = samityActiveMembers(members);
    final per = samityPerMember(group);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: Brand.blue.withValues(alpha: 0.15),
                child: const Icon(Icons.groups_2_rounded, color: Brand.blue),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text('${group['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(t.edit)),
                  PopupMenuItem(value: 'delete', child: Text(t.delete)),
                ],
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              _chip(context, Icons.payments_rounded,
                  t.samityPerMemberChip(taka(context, per))),
              _chip(context, Icons.people_outline_rounded,
                  t.samityMembersChip(fmtInt(context, active.length))),
              _chip(context, Icons.event_repeat_rounded, _periodLabel(t, group['period'])),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(text, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

String _periodLabel(AppLocalizations t, dynamic period) {
  switch (period) {
    case 'weekly':
      return t.samityPeriodWeekly;
    case 'biweekly':
      return t.samityPeriodBiweekly;
    default:
      return t.samityPeriodMonthly;
  }
}

// ============================================================ detail screen

/// One samity's full surface: rotation + per-cycle collected/pending, mark-paid,
/// record hand-over. Members/contributions/payouts load from sibling collections
/// scoped by `samity_id`.
class SamityDetailScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  const SamityDetailScreen({super.key, required this.group});
  @override
  State<SamityDetailScreen> createState() => _SamityDetailScreenState();
}

class _SamityDetailScreenState extends State<SamityDetailScreen> {
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _contribs = [];
  List<Map<String, dynamic>> _payouts = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  int _cycle = 1;

  int get _samityId => widget.group['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final all = await Future.wait([
        api.listItems('$kColSamityMember?samity_id=$_samityId'),
        api.listItems('$kColSamityContribution?samity_id=$_samityId'),
        api.listItems('$kColSamityPayout?samity_id=$_samityId'),
      ]);
      _members = all[0];
      _contribs = all[1];
      _payouts = all[2];
    } catch (_) {
      _error = _members.isEmpty;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addMember() async {
    final t = AppLocalizations.of(context);
    final nameCtl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.samityAddMember),
        content: TextField(
          controller: nameCtl,
          autofocus: true,
          decoration: InputDecoration(labelText: t.samityMemberName),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, nameCtl.text.trim()),
              child: Text(t.save)),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final order = samityActiveMembers(_members).length + 1;
    await context.read<AppState>().api.createItem(kColSamityMember, {
      'samity_id': _samityId,
      'name': name,
      'payout_order': order,
      'active': true,
    });
    await _load();
  }

  Future<void> _removeMember(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.samityRemoveMemberTitle),
        content: Text(t.samityRemoveMemberBody('${m['name'] ?? ''}')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().api.deleteItem(kColSamityMember, m['id'] as int);
    await _load();
  }

  Map<String, dynamic>? _contribFor(dynamic memberId, int cycle) {
    for (final c in _contribs) {
      if (c['member_id'] == memberId && c['cycle'] == cycle) return c;
    }
    return null;
  }

  Future<void> _togglePaid(Map<String, dynamic> member) async {
    final existing = _contribFor(member['id'], _cycle);
    final api = context.read<AppState>().api;
    if (existing == null) {
      await api.createItem(kColSamityContribution, {
        'samity_id': _samityId,
        'member_id': member['id'],
        'cycle': _cycle,
        'paid': true,
      });
    } else {
      final nowPaid = !(existing['paid'] == true);
      await api.updateItem(
          kColSamityContribution, existing['id'] as int, {'paid': nowPaid});
    }
    await _load();
  }

  Future<void> _recordPayout(Map<String, dynamic> recipient) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.volunteer_activism_rounded),
        title: Text(t.samityRecordPayoutTitle),
        // (cycle, name): generated signature order
        content: Text(t.samityRecordPayoutBody(
            fmtInt(context, _cycle), '${recipient['name'] ?? ''}')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.samityConfirmHandover)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Map<String, dynamic>? existing;
    for (final p in _payouts) {
      if (p['cycle'] == _cycle) existing = p;
    }
    final api = context.read<AppState>().api;
    if (existing == null) {
      await api.createItem(kColSamityPayout, {
        'samity_id': _samityId,
        'cycle': _cycle,
        'member_id': recipient['id'],
        'handed_over': true,
      });
    } else {
      await api.updateItem(kColSamityPayout, existing['id'] as int,
          {'member_id': recipient['id'], 'handed_over': true});
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.group['name'] ?? t.samityTitle}')),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.samityLoadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.commonLoadFailedBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final active = samityActiveMembers(_members);
    if (active.length < 2) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl),
        StateMessage(
          icon: Icons.person_add_alt_1_rounded,
          title: t.samityNeedMembersTitle,
          message: t.samityNeedMembersBody,
          action: FilledButton.icon(
            onPressed: _addMember,
            icon: const Icon(Icons.add_rounded),
            label: Text(t.samityAddMember),
          ),
        ),
      ]);
    }

    final total = active.length;
    if (_cycle > total) _cycle = total;
    if (_cycle < 1) _cycle = 1;

    final cs = samityCycleStatus(widget.group, _members, _contribs, _cycle);
    final recipient = samityRecipientForCycle(_members, _cycle);
    final payoutDone = samityPayoutDone(_payouts, _cycle);
    final nextTurn = samityNextTurn(_members, _payouts);

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        NoMoneyBanner(text: t.samityNoMoneyBanner),
        const SizedBox(height: Gap.md),

        // Cycle picker.
        _CyclePicker(
          cycle: _cycle,
          total: total,
          onPrev: _cycle > 1 ? () => setState(() => _cycle--) : null,
          onNext: _cycle < total ? () => setState(() => _cycle++) : null,
        ),
        const SizedBox(height: Gap.md),

        // Honest collected / pending hero.
        _CollectedHero(status: cs),
        const SizedBox(height: Gap.md),

        // Whose turn / payout record.
        _PayoutCard(
          recipient: recipient,
          done: payoutDone,
          fullyCollected: cs['pending_poisha'] == 0 && cs['expected_poisha'] > 0,
          onRecord: recipient == null
              ? null
              : () => _recordPayout(recipient),
        ),
        if (nextTurn != null) ...[
          const SizedBox(height: Gap.sm),
          Text(t.samityNextTurn('${nextTurn['name'] ?? ''}'),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ] else ...[
          const SizedBox(height: Gap.sm),
          Text(t.samityRoundComplete,
              style: const TextStyle(
                  color: Brand.success, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: Gap.lg),

        // Per-member paid/unpaid for this cycle.
        Row(children: [
          Expanded(
            child: Text(t.samityWhoPaidThisCycle,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          TextButton.icon(
            onPressed: _addMember,
            icon: const Icon(Icons.person_add_alt_rounded, size: 18),
            label: Text(t.samityAddMember),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        for (final row in (cs['members'] as List).cast<Map<String, dynamic>>())
          _MemberRow(
            row: row,
            recipientId: recipient?['id'],
            onToggle: () {
              final m = active.firstWhere((e) => e['id'] == row['member_id'],
                  orElse: () => {});
              if (m.isNotEmpty) _togglePaid(m);
            },
            onRemove: () {
              final m = active.firstWhere((e) => e['id'] == row['member_id'],
                  orElse: () => {});
              if (m.isNotEmpty) _removeMember(m);
            },
          ),

        const SizedBox(height: Gap.lg),
        // Full rotation order.
        Text(t.samityRotationOrder,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        _RotationList(members: _members, payouts: _payouts),
      ],
    );
  }
}

class _CyclePicker extends StatelessWidget {
  final int cycle;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _CyclePicker(
      {required this.cycle,
      required this.total,
      this.onPrev,
      this.onNext});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        IconButton(tooltip: MaterialLocalizations.of(context).previousPageTooltip, onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
          child: Text(
            t.samityCycleOf(fmtInt(context, cycle), fmtInt(context, total)),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(tooltip: MaterialLocalizations.of(context).nextPageTooltip, onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded)),
      ]),
    );
  }
}

class _CollectedHero extends StatelessWidget {
  final Map<String, dynamic> status;
  const _CollectedHero({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final expected = status['expected_poisha'] as int;
    final collected = status['collected_poisha'] as int;
    final pending = status['pending_poisha'] as int;
    final pct = expected > 0 ? collected / expected : 0.0;
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.samityCollectedThisCycle,
            style: AType.bodyMedium.copyWith(color: Colors.white70)),
        const SizedBox(height: Gap.xs),
        Text(taka(context, collected),
            style: AType.displaySmall.copyWith(fontFeatures: AFonts.tabular, color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(t.samityExpectedLabel(taka(context, expected)),
              style: AType.bodySmall.copyWith(color: Colors.white70)),
          Text(t.samityPendingLabel(taka(context, pending)),
              style: AType.bodySmall.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: Gap.xxs),
        Text(
          t.samityPaidCount(
              fmtInt(context, status['paid_count'] as int),
              fmtInt(context, status['member_count'] as int)),
          style: AType.bodySmall.copyWith(color: Colors.white70),
        ),
      ]),
    );
  }
}

class _PayoutCard extends StatelessWidget {
  final Map<String, dynamic>? recipient;
  final bool done;
  final bool fullyCollected;
  final VoidCallback? onRecord;
  const _PayoutCard(
      {required this.recipient,
      required this.done,
      required this.fullyCollected,
      this.onRecord});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.redeem_rounded,
            color: done ? Brand.success : scheme.secondary, size: 28),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.samityTurnLabel,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xxs),
            Text('${recipient?['name'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(width: Gap.sm),
        if (done)
          StatusPill(
              text: t.samityHandedOver,
              color: Brand.success,
              icon: Icons.check_circle_rounded)
        else
          FilledButton.tonal(
            onPressed: onRecord,
            child: Text(t.samityRecordPayout),
          ),
      ]),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final dynamic recipientId;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  const _MemberRow(
      {required this.row,
      required this.recipientId,
      required this.onToggle,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final paid = row['paid'] == true;
    final isRecipient = recipientId != null && recipientId == row['member_id'];
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Checkbox(value: paid, onChanged: (_) => onToggle()),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('${row['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (isRecipient) ...[
                const SizedBox(width: 6),
                Icon(Icons.star_rounded, size: 14, color: scheme.secondary),
              ],
            ]),
            Text(
              paid
                  ? t.samityPaidFull(taka(context, row['paid_poisha'] as int))
                  : t.samityDueAmount(taka(context, row['due_poisha'] as int)),
              style: AType.bodySmall.copyWith(color: paid ? Brand.success : scheme.onSurfaceVariant),
            ),
          ]),
        ),
        IconButton(
          onPressed: onRemove,
          icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
          tooltip: t.delete,
        ),
      ]),
    );
  }
}

class _RotationList extends StatelessWidget {
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> payouts;
  const _RotationList({required this.members, required this.payouts});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = samityActiveMembers(members);
    return Column(
      children: [
        for (var i = 0; i < active.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: scheme.surfaceContainerHighest,
                child: Text(fmtInt(context, i + 1),
                    style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text('${active[i]['name'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (samityPayoutDone(payouts, i + 1))
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_rounded,
                      size: 15, color: Brand.success),
                  const SizedBox(width: Gap.xs),
                  Text(t.samityReceived,
                      style: AType.bodySmall.copyWith(color: Brand.success, fontWeight: FontWeight.w600)),
                ]),
            ]),
          ),
      ],
    );
  }
}

// ============================================================ edit sheet

class _SamityEditSheet extends StatefulWidget {
  final Map<String, dynamic>? group;
  const _SamityEditSheet({this.group});
  @override
  State<_SamityEditSheet> createState() => _SamityEditSheetState();
}

class _SamityEditSheetState extends State<_SamityEditSheet> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.group?['name'] ?? ''}');
  late final TextEditingController _amount = TextEditingController(
      text: widget.group?['amount_poisha'] != null
          ? ((widget.group!['amount_poisha'] as int) / 100)
              .toStringAsFixed(2)
          : '');
  String _period = 'monthly';

  @override
  void initState() {
    super.initState();
    final p = widget.group?['period'];
    if (p is String && kPeriods.contains(p)) _period = p;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final per = takaToPoisha(_amount.text);
    final valid = _name.text.trim().isNotEmpty && per > 0;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.group == null ? t.samityNew : t.samityEdit,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: t.samityFieldName),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: t.samityFieldAmount,
            helperText: t.samityFieldAmountHint,
            prefixText: '৳ ',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Gap.md),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(t.samityFieldPeriod,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: [
          for (final p in kPeriods)
            ChoiceChip(
              label: Text(_periodLabel(t, p)),
              selected: _period == p,
              onSelected: (_) => setState(() => _period = p),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: valid
                ? () => Navigator.pop(context, {
                      'name': _name.text.trim(),
                      'amount_poisha': per,
                      'period': _period,
                    })
                : null,
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  final String text;
  const _OfflineBar({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        const Icon(Icons.wifi_off_rounded, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodySmall.copyWith(color: scheme.onSurface))),
      ]),
    );
  }
}
