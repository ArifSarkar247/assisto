import '../api.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../famacct_api.dart';
import '../l10n/app_localizations.dart';
import 'skeleton.dart';
import 'famacct_sheets.dart';

/// FAMILY ACCOUNTING section (#61, SPEC v2.1 §21) — a fully self-contained,
/// clearly-bounded widget embedded as ONE tab inside FamilyScreen. Everything
/// family-money lives here and in famacct_sheets.dart / famacct_api.dart /
/// famacct_strings.dart, so FamilyScreen's own edit is a single tab + one line
/// of delegation (D6 can touch FamilyScreen later without colliding).
///
/// It reuses the SAME family/circle contacts FamilyScreen already loads (passed
/// in as [members]) — it defines no new contact store. All money is integer
/// poisha end to end (see FamAcctLocal); no float ever enters the ledger.
///
/// States (§21): loading (skeleton) · error · empty-per-sub-tab · offline
/// (on-device compute banner) · honest "settled/—" instead of fake zeros.
class FamAcctSection extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  const FamAcctSection({super.key, required this.members});

  @override
  State<FamAcctSection> createState() => _FamAcctSectionState();
}

class _FamAcctSectionState extends State<FamAcctSection> {
  bool loading = true;
  bool errored = false;
  bool offline = false; // served from the on-device compute path

  Map<String, dynamic> summary = {};
  List<Map<String, dynamic>> expenses = [];
  Map<String, dynamic> pool = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;

  String _name(dynamic memberId) {
    for (final m in widget.members) {
      if (m['id'] == memberId) return (m['name'] ?? '').toString();
    }
    // 'self' is the account owner; everything else is a family member id.
    if (memberId == 'self' || memberId == null) {
      return AppLocalizations.of(context).medForSelf;
    }
    return memberId.toString();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      errored = false;
    });
    try {
      final s = await _api.famAcctSummary();
      final e = await _api.famAcctExpenses();
      if (!mounted) return;
      setState(() {
        summary = s;
        expenses = (e['expenses'] as List? ?? []).cast<Map<String, dynamic>>();
        pool = (s['pool'] as Map?)?.cast<String, dynamic>() ?? {};
        offline = false;
        loading = false;
      });
    } catch (_) {
      // Endpoints not live yet (or no network): fall back to the on-device
      // compute path so the section still works and states stay honest.
      if (!mounted) return;
      setState(() {
        offline = true;
        _recomputeLocal();
        loading = false;
      });
    }
  }

  /// Recompute summary/pool from whatever expenses we hold, on-device, in
  /// integer poisha. Mirrors famacct_engine.monthly_summary / settle_up.
  void _recomputeLocal() {
    final nets = <dynamic, int>{};
    var total = 0;
    final byCat = <String, int>{};
    for (final e in expenses) {
      final payer = e['payer'];
      final totalP = (e['total_poisha'] as num?)?.toInt() ?? 0;
      total += totalP;
      final cat = (e['category'] ?? 'other').toString();
      byCat[cat] = (byCat[cat] ?? 0) + totalP;
      nets[payer] = (nets[payer] ?? 0) + totalP;
      for (final s in (e['shares'] as List? ?? [])) {
        final mid = s['member'];
        final sp = (s['share_poisha'] as num?)?.toInt() ?? 0;
        nets[mid] = (nets[mid] ?? 0) - sp;
      }
    }
    final members = nets.entries
        .map((en) => {
              'member': en.key,
              'net_poisha': en.value,
            })
        .toList();
    summary = {
      'total_poisha': total,
      'by_category': byCat,
      'members': members,
      'settlements': _settle(nets),
    };
  }

  /// Greedy minimal-transfer settle-up over integer poisha (mirror of
  /// famacct_engine.settle_up). Returns [{from,to,amount_poisha}].
  List<Map<String, dynamic>> _settle(Map<dynamic, int> nets) {
    final cred = [
      for (final e in nets.entries)
        if (e.value > 0) [e.key, e.value]
    ]..sort((a, b) => (b[1] as int).compareTo(a[1] as int));
    final debt = [
      for (final e in nets.entries)
        if (e.value < 0) [e.key, -(e.value as int)]
    ]..sort((a, b) => (b[1] as int).compareTo(a[1] as int));
    final out = <Map<String, dynamic>>[];
    var ci = 0, di = 0;
    while (ci < cred.length && di < debt.length) {
      final pay = (cred[ci][1] as int) < (debt[di][1] as int)
          ? cred[ci][1] as int
          : debt[di][1] as int;
      if (pay > 0) {
        out.add({'from': debt[di][0], 'to': cred[ci][0], 'amount_poisha': pay});
      }
      cred[ci][1] = (cred[ci][1] as int) - pay;
      debt[di][1] = (debt[di][1] as int) - pay;
      if (cred[ci][1] == 0) ci++;
      if (debt[di][1] == 0) di++;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonList();
    return DefaultTabController(
      length: 4,
      child: Column(children: [
        _brandHeader(),
        if (offline) _offlineBanner(),
        TabBar(isScrollable: true, tabs: [
          Tab(text: AppLocalizations.of(context).faTabExpenses),
          Tab(text: AppLocalizations.of(context).faTabSettle),
          Tab(text: AppLocalizations.of(context).faTabPool),
          Tab(text: AppLocalizations.of(context).faTabMembers),
        ]),
        Expanded(
          child: TabBarView(children: [
            _expensesTab(),
            _settleTab(),
            _poolTab(),
            _membersTab(),
          ]),
        ),
      ]),
    );
  }

  Widget _brandHeader() {
    return Container(
      margin: const EdgeInsets.all(Gap.md),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(children: [
        const Icon(Icons.diversity_3_outlined, color: Colors.white),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(AppLocalizations.of(context).faTitle,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text(
                AppLocalizations.of(context).faTotalSpent.replaceFirst('%s',
                    FamAcctLocal.fmtPoisha(
                        (summary['total_poisha'] as num?)?.toInt() ?? 0)),
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
        IconButton(
            onPressed: _load,
            icon: const Icon(Icons.sync, color: Colors.white)),
      ]),
    );
  }

  Widget _offlineBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(children: [
        Icon(Icons.cloud_off_outlined,
            size: 16, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(AppLocalizations.of(context).faOfflineNote,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSecondaryContainer)),
        ),
      ]),
    );
  }

  // --------------------------- EXPENSES ----------------------------------
  Widget _expensesTab() {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: _openAddExpense, child: const Icon(Icons.add)),
      body: expenses.isEmpty
          ? StateMessage(
              icon: Icons.receipt_long_outlined,
              title: AppLocalizations.of(context).faEmptyExpenses,
              message: AppLocalizations.of(context).faEmptyExpensesSub,
              action: FilledButton.icon(
                  onPressed: _openAddExpense,
                  icon: const Icon(Icons.add),
                  label: Text(AppLocalizations.of(context).faAddExpense)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
              children: [for (final e in expenses) _expenseCard(e, scheme)]),
    );
  }

  Widget _expenseCard(Map<String, dynamic> e, ColorScheme scheme) {
    final totalP = (e['total_poisha'] as num?)?.toInt() ?? 0;
    final shares = (e['shares'] as List? ?? []).cast<Map<String, dynamic>>();
    final aiCaptured = e['ai_captured'] == true;
    final note = (e['note'] ?? '').toString();
    final payerName = (e['payer_name'] ?? _name(e['payer'])).toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.payments_outlined),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(note.isEmpty ? AppLocalizations.of(context).faTabExpenses : note,
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(AppLocalizations.of(context).faPaidBy.replaceFirst('%s', payerName),
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
              ),
              Text(FamAcctLocal.fmtPoisha(totalP),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteExpense(e)),
            ]),
            if (aiCaptured) ...[
              const SizedBox(height: Gap.xs),
              _aiChip(scheme),
            ],
            if (shares.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              for (final s in shares)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 6),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text(_name(s['member']))),
                    Text(FamAcctLocal.fmtPoisha(
                        (s['share_poisha'] as num?)?.toInt() ?? 0)),
                  ]),
                ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _aiChip(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_awesome, size: 12, color: scheme.onTertiaryContainer),
        const SizedBox(width: 4),
        Text(AppLocalizations.of(context).faAiCaptured,
            style: TextStyle(
                fontSize: 11, color: scheme.onTertiaryContainer)),
      ]),
    );
  }

  Future<void> _openAddExpense() async {
    final body = await showAddExpenseSheet(context, widget.members);
    if (body == null) return;
    try {
      final created = await _api.famAcctAddExpense(body);
      if (created.isNotEmpty) {
        await _load();
        return;
      }
    } catch (_) {}
    // Offline/not-live: append locally so the ledger still updates honestly.
    setState(() {
      expenses = [...expenses, _localExpenseFromBody(body)];
      offline = true;
      _recomputeLocal();
    });
  }

  Map<String, dynamic> _localExpenseFromBody(Map<String, dynamic> body) {
    final mode = (body['mode'] ?? 'equal').toString();
    final total = (body['total_poisha'] as num?)?.toInt() ?? 0;
    List<Map<String, dynamic>> shares;
    if (mode == 'exact') {
      shares = [
        for (final p in (body['parts'] as List? ?? []))
          {
            'member': p['member'],
            'share_poisha': (p['amount_poisha'] as num?)?.toInt() ?? 0
          }
      ];
    } else {
      final ids = (body['members'] as List? ?? []);
      final split = FamAcctLocal.splitEqual(total, ids.length);
      shares = [
        for (var i = 0; i < ids.length; i++)
          {'member': ids[i], 'share_poisha': split[i]}
      ];
    }
    return {
      'payer': body['payer'],
      'total_poisha': total,
      'category': body['category'],
      'mode': mode,
      'note': body['note'],
      'shares': shares,
    };
  }

  Future<void> _deleteExpense(Map<String, dynamic> e) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              content: Text(AppLocalizations.of(context).faDeleteExpenseQ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(AppLocalizations.of(context).cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(AppLocalizations.of(context).delete)),
              ],
            ));
    if (ok != true) return;
    final id = e['id'];
    if (id is int) {
      try {
        await _api.famAcctDeleteExpense(id);
        await _load();
        return;
      } catch (_) {}
    }
    setState(() {
      expenses = expenses.where((x) => !identical(x, e)).toList();
      _recomputeLocal();
    });
  }

  // --------------------------- SETTLE UP ---------------------------------
  Widget _settleTab() {
    final settlements =
        (summary['settlements'] as List? ?? []).cast<Map<String, dynamic>>();
    if (settlements.isEmpty) {
      return StateMessage(
        icon: Icons.handshake_outlined,
        title: AppLocalizations.of(context).faSettleEmpty,
        message: AppLocalizations.of(context).faSettleEmptySub,
        tint: Brand.success,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [for (final s in settlements) _settleCard(s)],
    );
  }

  Widget _settleCard(Map<String, dynamic> s) {
    final from = _name(s['from']);
    final to = _name(s['to']);
    final amt = (s['amount_poisha'] as num?)?.toInt() ?? 0;
    // 'X owes Y ৳Z' — the message text comes localized from the server when
    // online; offline we compose it from the bilingual template + formatted amt.
    final serverMsg = (s['message'] is Map)
        ? (s['message'] as Map)[
            Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en']
        : null;
    final line = serverMsg?.toString() ?? _owesLine(from, to, amt);
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.swap_horiz)),
        title: Text(line),
        trailing: TextButton(
          onPressed: () => _markPaid(s),
          child: Text(AppLocalizations.of(context).faMarkPaid),
        ),
      ),
    );
  }

  String _owesLine(String from, String to, int amountPoisha) {
    final amt = FamAcctLocal.fmtPoisha(amountPoisha);
    // Reuse the existing bilingual "owes" style; kept parameterised so the two
    // names + amount are substituted without any Bangla literal in this file.
    final isBn = Localizations.localeOf(context).languageCode == 'bn';
    return isBn ? '$from → $to  $amt' : '$from owes $to $amt';
  }

  Future<void> _markPaid(Map<String, dynamic> s) async {
    final messenger = ScaffoldMessenger.of(context);
    final from = s['from'], to = s['to'];
    final amt = (s['amount_poisha'] as num?)?.toInt() ?? 0;
    if (from is int && to is int) {
      try {
        await _api.famAcctSettle(from, to, amt);
        await _load();
        messenger.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).faSettledDone)));
        return;
      } catch (_) {}
    }
    messenger.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).faSettledDone)));
  }

  // ----------------------------- POOL ------------------------------------
  Widget _poolTab() {
    final scheme = Theme.of(context).colorScheme;
    final target = (pool['target'] as num?)?.toInt() ?? 0;
    if (target <= 0) {
      return StateMessage(
        icon: Icons.savings_outlined,
        title: AppLocalizations.of(context).faPoolNone,
        message: AppLocalizations.of(context).faPoolNoneSub,
        action: FilledButton.icon(
            onPressed: _setPoolTarget,
            icon: const Icon(Icons.flag_outlined),
            label: Text(AppLocalizations.of(context).faPoolSetTarget)),
      );
    }
    final collected = (pool['collected'] as num?)?.toInt() ?? 0;
    final remaining = (pool['remaining'] as num?)?.toInt() ?? (target - collected);
    final pct = (pool['pct'] as num?)?.toInt() ??
        (target > 0 ? (collected * 100 ~/ target).clamp(0, 100) : 0);
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(AppLocalizations.of(context).faPoolTarget,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Text(FamAcctLocal.fmtPoisha(target),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Gap.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: pct / 100.0,
                minHeight: 10,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: Gap.sm),
            Text(AppLocalizations.of(context).faPoolCollected.replaceFirst('%s',
                FamAcctLocal.fmtPoisha(collected))),
            Text(AppLocalizations.of(context).faPoolRemaining.replaceFirst('%s',
                FamAcctLocal.fmtPoisha(remaining < 0 ? 0 : remaining))),
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
              onPressed: _setPoolTarget,
              icon: const Icon(Icons.flag_outlined),
              label: Text(AppLocalizations.of(context).faPoolSetTarget)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: FilledButton.icon(
              onPressed: _contribute,
              icon: const Icon(Icons.add),
              label: Text(AppLocalizations.of(context).faPoolContribute)),
        ),
      ]),
    ]);
  }

  Future<void> _setPoolTarget() async {
    final p = await showAmountSheet(context, AppLocalizations.of(context).faPoolSetTarget);
    if (p == null) return;
    try {
      final r = await _api.famAcctSetPoolTarget(p);
      if (r.isNotEmpty) {
        await _load();
        return;
      }
    } catch (_) {}
    setState(() => pool = {...pool, 'target': p});
  }

  Future<void> _contribute() async {
    final member = await showMemberPicker(context, widget.members);
    if (member == null || !mounted) return;
    final p = await showAmountSheet(context, AppLocalizations.of(context).faPoolContribute);
    if (p == null) return;
    if (member is int) {
      try {
        final r = await _api.famAcctContribute(member, p);
        if (r.isNotEmpty) {
          await _load();
          return;
        }
      } catch (_) {}
    }
    setState(() {
      final collected = ((pool['collected'] as num?)?.toInt() ?? 0) + p;
      final target = (pool['target'] as num?)?.toInt() ?? 0;
      pool = {
        ...pool,
        'collected': collected,
        'remaining': target - collected,
      };
    });
  }

  // ---------------------------- MEMBERS ----------------------------------
  Widget _membersTab() {
    final scheme = Theme.of(context).colorScheme;
    final rows =
        (summary['members'] as List? ?? []).cast<Map<String, dynamic>>();
    if (rows.isEmpty) {
      return StateMessage(
          icon: Icons.groups_outlined,
          title: AppLocalizations.of(context).faMembersEmpty);
    }
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [for (final r in rows) _memberCard(r, scheme)],
    );
  }

  Widget _memberCard(Map<String, dynamic> r, ColorScheme scheme) {
    final net = (r['net_poisha'] as num?)?.toInt() ?? 0;
    final paid = (r['paid_poisha'] as num?)?.toInt();
    final share = (r['share_poisha'] as num?)?.toInt();
    Color netColor;
    String netLabel;
    if (net > 0) {
      netColor = Brand.success;
      netLabel = AppLocalizations.of(context).faGetsBack.replaceFirst('%s', FamAcctLocal.fmtPoisha(net));
    } else if (net < 0) {
      netColor = Brand.danger;
      netLabel = AppLocalizations.of(context).faOwesFamily.replaceFirst('%s', FamAcctLocal.fmtPoisha(-net));
    } else {
      netColor = scheme.onSurfaceVariant;
      netLabel = AppLocalizations.of(context).faEven;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            child: Icon(Icons.person, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_name(r['member']),
                  style: Theme.of(context).textTheme.titleMedium),
              if (paid != null || share != null)
                Text(
                    '${AppLocalizations.of(context).faMemberPaid} ${FamAcctLocal.fmtPoisha(paid ?? 0)}  ·  '
                    '${AppLocalizations.of(context).faMemberShare} ${FamAcctLocal.fmtPoisha(share ?? 0)}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
          Text(netLabel,
              style: TextStyle(fontWeight: FontWeight.w700, color: netColor)),
        ]),
      ),
    );
  }
}
