import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import 'probashi_family_screen.dart';
import 'probashi_pool_screen.dart';
import 'probashi_reports_screen.dart';
import 'probashi_source.dart';
import 'probashi_widgets.dart';

/// PROBASHI FAMILY PLAN (flag `probashi_plan`, default OFF; route
/// 'probashi_plan'). One screen, role-aware:
///  * anyone: what the plan includes — the SERVER's `benefits` list only —
///    and Google Play's own price (never a number in the app);
///  * an invite to me: accept (choose what to share — all OFF by default) or
///    decline;
///  * a member: my seat, my monthly limit and use, the pool left, my sharing
///    choices, leave;
///  * the payer: seats (invite from My Circle, limit per member, remove,
///    move), the shared pool, the family dashboard and monthly reports.
/// Credits are AI credits — never money, never withdrawable.
class ProbashiPlanScreen extends StatefulWidget {
  final ProbashiSource? source;
  final ProbashiBuyer? buyer;
  const ProbashiPlanScreen({super.key, this.source, this.buyer});

  @override
  State<ProbashiPlanScreen> createState() => _ProbashiPlanScreenState();
}

class _ProbashiPlanScreenState extends State<ProbashiPlanScreen> {
  late final ProbashiSource _src = widget.source ?? ApiProbashiSource(context.read<AppState>().api);
  late final ProbashiBuyer _buyer = widget.buyer ?? PlayProbashiBuyer(context.read<AppState>().api);

  bool _loading = true;
  Object? _err;
  Map<String, dynamic> _d = const {};
  Map<String, String>? _prices; // null = still asking Google Play
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _d = await _src.overview();
      if (_d['is_payer'] != true && _prices == null) _loadPrices();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadPrices() async {
    final p = await _buyer.prices();
    if (mounted) setState(() => _prices = p);
  }

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
      if (ok != null && mounted) pbsSnack(context, ok);
      await _load();
    } catch (e) {
      if (mounted) pbsSnack(context, pbsMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _maps(Object? v) =>
      [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.pbsTitle)),
      body: (_loading || _err != null)
          ? PbsStateView(loading: _loading, error: _err, onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final invites = _maps(_d['invites']);
    final member = (_d['membership'] as Map?)?.cast<String, dynamic>();
    final payer = _d['is_payer'] == true;
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      for (final inv in invites) _inviteCard(t, inv),
      if (member != null) _memberCard(t, member),
      if (payer) ...[
        _poolCard(t),
        _seatsCard(t),
        _linksCard(t, family: true),
      ] else ...[
        if (member == null && invites.isEmpty) _intro(t),
        _planCard(t),
        if (member != null) _linksCard(t, family: false),
      ],
    ]);
  }

  // ---------------------------------------------------------------- plan
  Widget _intro(AppLocalizations t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(t.pbsIntro, style: Theme.of(context).textTheme.bodyLarge),
      );

  Widget _planCard(AppLocalizations t) {
    final benefits = [for (final b in (_d['benefits'] as List? ?? const [])) '$b'];
    return PbsCard(title: t.pbsIncludesTitle, icon: Icons.workspace_premium_rounded, children: [
      for (final b in benefits)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.check_circle_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(b)),
          ]),
        ),
      const SizedBox(height: 8),
      Text(t.pbsCreditsNotCash, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      if (_prices == null)
        Semantics(label: t.pbsLoading, child: const LinearProgressIndicator())
      else if (_prices!.isEmpty)
        Container(
          key: const ValueKey('pbs-not-on-play'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(t.pbsNotOnPlay),
        )
      else
        for (final p in kProbashiPlans)
          if (_prices![p] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: ValueKey('pbs-buy-$p'),
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: _busy ? null : () => _buy(p),
                  child: Text(
                    p == 'annual'
                        ? t.pbsBuyAnnual(pbsNum(context, _prices![p]!))
                        : t.pbsBuyMonthly(pbsNum(context, _prices![p]!)),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
    ]);
  }

  Future<void> _buy(String plan) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    final r = await _buyer.buy(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case ProbashiBuyStatus.done:
        pbsSnack(context, t.pbsBuyDone);
        await _load();
      case ProbashiBuyStatus.pending:
        pbsSnack(context, t.pbsBuyPending);
      case ProbashiBuyStatus.cancelled:
        pbsSnack(context, t.pbsBuyCancelled);
      case ProbashiBuyStatus.unavailable:
        pbsSnack(context, t.pbsNotOnPlay);
      case ProbashiBuyStatus.failed:
        pbsSnack(context, t.pbsErrorBody);
    }
  }

  // ---------------------------------------------------------------- invitee
  Widget _inviteCard(AppLocalizations t, Map<String, dynamic> inv) {
    final from = '${(inv['payer'] as Map?)?['name'] ?? ''}';
    return PbsCard(title: t.pbsInviteFrom(from), icon: Icons.mail_rounded, children: [
      Text(t.pbsInviteBody),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(
          key: ValueKey('pbs-accept-${inv['id']}'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: _busy ? null : () => _accept(inv),
          child: Text(t.pbsAccept),
        ),
        OutlinedButton(
          key: ValueKey('pbs-decline-${inv['id']}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: _busy
              ? null
              : () async {
                  if (await pbsConfirm(context, t.pbsDeclineTitle, t.pbsDeclineBody, t.pbsDecline)) {
                    await _run(() => _src.respond(inv['id'] as int, false, const {}));
                  }
                },
          child: Text(t.pbsDecline),
        ),
      ]),
    ]);
  }

  Future<void> _accept(Map<String, dynamic> inv) async {
    final t = AppLocalizations.of(context);
    final consent = await _consentSheet(t, PbsConsentPicker.clean(const {}), t.pbsJoin);
    if (consent == null) return;
    await _run(() => _src.respond(inv['id'] as int, true, consent), ok: t.pbsJoined);
  }

  Future<Map<String, bool>?> _consentSheet(AppLocalizations t, Map<String, bool> start, String action) {
    var cur = Map<String, bool>.from(start);
    return showModalBottomSheet<Map<String, bool>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.pbsConsentTitle, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(t.pbsConsentBody),
              PbsConsentPicker(value: cur, onChanged: (v) => set(() => cur = v)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('pbs-consent-save'),
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: () => Navigator.pop(ctx, cur),
                  child: Text(action),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- member
  Widget _memberCard(AppLocalizations t, Map<String, dynamic> m) {
    final live = m['live'] == true;
    final payer = '${(m['payer'] as Map?)?['name'] ?? ''}';
    final used = (m['used_this_month'] as num?)?.toInt() ?? 0;
    final cap = (m['monthly_cap'] as num?)?.toInt() ?? 0;
    return PbsCard(title: t.pbsMemberTitle(payer), icon: Icons.family_restroom_rounded, children: [
      if (!live)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(t.pbsPaused, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      Text(t.pbsUsedOfCap(pbsNum(context, used), pbsNum(context, cap))),
      if (live) Text(t.pbsPoolLeftShort(pbsNum(context, m['pool_left'] ?? 0))),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const ValueKey('pbs-my-consent'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
          icon: const Icon(Icons.visibility_rounded),
          label: Text(t.pbsChangeSharing),
          onPressed: _busy
              ? null
              : () async {
                  final c = await _consentSheet(t, PbsConsentPicker.clean(m['consent']), t.pbsSave);
                  if (c != null) await _run(() => _src.setConsent(m['id'] as int, c), ok: t.pbsSaved);
                },
        ),
        TextButton.icon(
          key: const ValueKey('pbs-leave'),
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          icon: const Icon(Icons.logout_rounded),
          label: Text(t.pbsLeave),
          onPressed: _busy
              ? null
              : () async {
                  if (await pbsConfirm(context, t.pbsLeaveTitle, t.pbsLeaveBody, t.pbsLeave)) {
                    await _run(() => _src.leave(m['id'] as int));
                  }
                },
        ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- payer
  Widget _poolCard(AppLocalizations t) {
    final pool = (_d['pool'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PbsCard(title: t.pbsPoolTitle, icon: Icons.savings_rounded, children: [
      Text(t.pbsPoolLeft(pbsNum(context, pool['left'] ?? 0), pbsNum(context, pool['total'] ?? 0)),
          style: Theme.of(context).textTheme.titleLarge),
      Text(t.pbsCreditsNotCash, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('pbs-open-pool'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
        icon: const Icon(Icons.receipt_long_rounded),
        label: Text(t.pbsWhoSpent),
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => ProbashiPoolScreen(source: _src))),
      ),
    ]);
  }

  Widget _seatsCard(AppLocalizations t) {
    final seats = _maps(_d['seats']);
    final max = (_d['seats_max'] as num?)?.toInt() ?? 0;
    final used = (_d['slots_used'] as num?)?.toInt() ?? 0;
    final full = used >= max;
    final freeAt = _d['slot_free_at'];
    return PbsCard(title: t.pbsSeatsTitle(pbsNum(context, used), pbsNum(context, max)), icon: Icons.groups_rounded, children: [
      if (seats.isEmpty) Text(t.pbsNoSeats),
      for (final s in seats) _seatTile(t, s),
      if (full && freeAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t.pbsSlotFreeAt(pbsDate(context, freeAt))),
        ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const ValueKey('pbs-invite'),
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(t.pbsInvite),
        onPressed: (_busy || full) ? null : () => _pickAndInvite(t),
      ),
    ]);
  }

  Widget _seatTile(AppLocalizations t, Map<String, dynamic> s) {
    final name = '${(s['member'] as Map?)?['name'] ?? ''}';
    final status = '${s['status']}';
    final active = status == 'active';
    final open = active || status == 'invited';
    final sub = <String>['${s['status_label'] ?? status}'];
    if (active) {
      sub.add(t.pbsUsedOfCap(pbsNum(context, s['used_this_month'] ?? 0), pbsNum(context, s['monthly_cap'] ?? 0)));
    }
    return ListTile(
      key: ValueKey('pbs-seat-${s['id']}'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 8,
      leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name.characters.first)),
      title: Text(name),
      subtitle: Text(sub.join(' · ')),
      trailing: open
          ? PopupMenuButton<String>(
              key: ValueKey('pbs-seat-menu-${s['id']}'),
              tooltip: t.pbsSeatActions,
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (a) => _seatAction(t, s, a),
              itemBuilder: (_) => [
                if (active) PopupMenuItem(value: 'cap', child: Text(t.pbsSetCap)),
                if (active) PopupMenuItem(value: 'transfer', child: Text(t.pbsTransfer)),
                PopupMenuItem(value: 'remove', child: Text(active ? t.pbsRemove : t.pbsCancelInvite)),
              ],
            )
          : null,
    );
  }

  Future<void> _seatAction(AppLocalizations t, Map<String, dynamic> s, String a) async {
    final id = s['id'] as int;
    final name = '${(s['member'] as Map?)?['name'] ?? ''}';
    if (a == 'cap') {
      final pool = ((_d['pool'] as Map?)?['total'] as num?)?.toInt() ?? 0;
      final n = await _capDialog(t, (s['monthly_cap'] as num?)?.toInt() ?? 0, pool);
      if (n != null) await _run(() => _src.setCap(id, n), ok: t.pbsSaved);
    } else if (a == 'transfer') {
      final to = await _pickCandidate(t);
      if (to == null || !mounted) return;
      if (await pbsConfirm(context, t.pbsTransferTitle, t.pbsTransferBody(name, '${to['name']}'), t.pbsTransfer)) {
        await _run(() => _src.transfer(id, to['id'] as int), ok: t.pbsInvited);
      }
    } else if (a == 'remove') {
      final active = s['status'] == 'active';
      final ok = await pbsConfirm(
          context,
          active ? t.pbsRemoveTitle : t.pbsCancelInvite,
          active ? t.pbsRemoveBody(name, pbsNum(context, _d['cooldown_days'] ?? 0)) : t.pbsCancelInviteBody,
          active ? t.pbsRemove : t.pbsCancelInvite);
      if (ok) await _run(() => _src.remove(id));
    }
  }

  Future<int?> _capDialog(AppLocalizations t, int start, int max) {
    var v = start.clamp(0, max);
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t.pbsSetCap),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.pbsCapHint),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                key: const ValueKey('pbs-cap-minus'),
                tooltip: t.pbsLess,
                iconSize: 32,
                onPressed: v <= 0 ? null : () => set(() => v = (v - 5).clamp(0, max)),
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(pbsNum(ctx, v), style: Theme.of(ctx).textTheme.headlineSmall),
                ),
              ),
              IconButton(
                key: const ValueKey('pbs-cap-plus'),
                tooltip: t.pbsMore,
                iconSize: 32,
                onPressed: v >= max ? null : () => set(() => v = (v + 5).clamp(0, max)),
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ]),
          ]),
          actions: [
            TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.pbsCancel)),
            FilledButton(
                key: const ValueKey('pbs-cap-save'),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => Navigator.pop(ctx, v),
                child: Text(t.pbsSave)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndInvite(AppLocalizations t) async {
    final c = await _pickCandidate(t);
    if (c != null) await _run(() => _src.invite(c['id'] as int), ok: t.pbsInvited);
  }

  Future<Map<String, dynamic>?> _pickCandidate(AppLocalizations t) async {
    List<Map<String, dynamic>> list;
    try {
      list = await _src.candidates();
    } catch (e) {
      if (mounted) pbsSnack(context, pbsMessage(context, e));
      return null;
    }
    if (!mounted) return null;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text(t.pbsPickTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(t.pbsPickBody),
          if (list.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(t.pbsPickEmpty)),
          for (final c in list)
            ListTile(
              key: ValueKey('pbs-cand-${c['id']}'),
              enabled: c['eligible'] == true,
              minVerticalPadding: 8,
              title: Text('${c['name']}'),
              subtitle: c['eligible'] == true ? null : Text('${c['reason_text']}'),
              trailing: c['eligible'] == true ? const Icon(Icons.chevron_right_rounded) : null,
              onTap: c['eligible'] == true ? () => Navigator.pop(ctx, c) : null,
            ),
        ]),
      ),
    );
  }

  Widget _linksCard(AppLocalizations t, {required bool family}) => PbsCard(
        title: t.pbsMoreTitle,
        icon: Icons.dashboard_rounded,
        children: [
          if (family)
            ListTile(
              key: const ValueKey('pbs-open-family'),
              contentPadding: EdgeInsets.zero,
              minVerticalPadding: 12,
              leading: const Icon(Icons.family_restroom_rounded),
              title: Text(t.pbsFamilyTitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ProbashiFamilyScreen(source: _src))),
            ),
          ListTile(
            key: const ValueKey('pbs-open-reports'),
            contentPadding: EdgeInsets.zero,
            minVerticalPadding: 12,
            leading: const Icon(Icons.summarize_rounded),
            title: Text(t.pbsReportsTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => ProbashiReportsScreen(source: _src))),
          ),
        ],
      );
}
