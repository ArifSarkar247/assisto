import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/finance_common.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// MESS & BACHELOR ACCOUNTING — ADVANCED (#182, SPEC v2.1 §20).
///
/// The classic Bangladeshi "mess manager": members living together, each
/// member's monthly meal count, the bazar/market expenses someone paid, and the
/// three numbers every mess argues about —
///   meal rate  = total bazar ÷ total meals
///   meal cost  = a member's meals × meal rate (distributed EXACTLY, no drift)
///   balance    = deposits − meal cost − other charges
/// plus a transparent monthly summary that reconciles to zero.
///
/// All MONEY is INTEGER POISHA. The on-screen math mirrors backend/core/logic/
/// mess_accounting.py VERBATIM (largest-remainder distribution) so the live
/// summary is deterministic and identical offline. The app HOLDS NO MONEY — it
/// computes and shows each member's number so the mess settles up itself.
///
/// Honest states: welcome (first use) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter; the ৳ sign is a currency glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('mess/members')  → [{id, name}]
///   listItems('mess/meals')    → [{id, member, meals}]          (this month)
///   listItems('mess/bazar')    → [{id, title, amount}]          (market buys)
///   listItems('mess/deposits') → [{id, member, amount}]         (fund deposits)
///   listItems('mess/charges')  → [{id, member|"common", title, amount}]
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent).
class MessAccountingScreen extends StatefulWidget {
  const MessAccountingScreen({super.key});
  @override
  State<MessAccountingScreen> createState() => _MessAccountingScreenState();
}

// ---- constants (mirror mess_accounting.py) --------------------------------
const String _memberPath = 'mess/members';
const String _mealsPath = 'mess/meals';
const String _bazarPath = 'mess/bazar';
const String _depositsPath = 'mess/deposits';
const String _chargesPath = 'mess/charges';

class _MessAccountingScreenState extends State<MessAccountingScreen> {
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _meals = [];
  List<Map<String, dynamic>> _bazar = [];
  List<Map<String, dynamic>> _deposits = [];
  List<Map<String, dynamic>> _charges = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      final res = await Future.wait([
        api.listItems(_memberPath),
        api.listItems(_mealsPath),
        api.listItems(_bazarPath),
        api.listItems(_depositsPath),
        api.listItems(_chargesPath),
      ]);
      _members = res[0];
      _meals = res[1];
      _bazar = res[2];
      _deposits = res[3];
      _charges = res[4];
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- name lookup ----------------------------------------------------------
  String _nameOf(dynamic id) {
    for (final m in _members) {
      if (m['id'] == id) return (m['name'] ?? '').toString();
    }
    return '';
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.messTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.messTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.messLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_members.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.messTitle)),
        body: StateMessage(
          icon: Icons.groups_2_rounded,
          title: tr.messWelcomeTitle,
          message: tr.messWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addMember,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(tr.messAddMember),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.messTitle),
          bottom: TabBar(tabs: [
            Tab(text: tr.messTabMembers),
            Tab(text: tr.messTabEntries),
            Tab(text: tr.messTabSummary),
          ]),
        ),
        body: TabBarView(children: [
          _MembersTab(
              members: _members,
              meals: _meals,
              onChanged: _load,
              onAdd: _addMember),
          _EntriesTab(
            members: _members,
            meals: _meals,
            bazar: _bazar,
            deposits: _deposits,
            charges: _charges,
            nameOf: _nameOf,
            onChanged: _load,
          ),
          _SummaryTab(
            members: _members,
            meals: _meals,
            bazar: _bazar,
            deposits: _deposits,
            charges: _charges,
          ),
        ]),
      ),
    );
  }

  Future<void> _addMember() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final name = await _promptName(context, tr.messAddMember);
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final dup = _members.any((m) =>
        (m['name'] ?? '').toString().toLowerCase() == trimmed.toLowerCase());
    if (dup) {
      _toast(tr.messDuplicateName);
      return;
    }
    try {
      await api.createItem(_memberPath, {'name': trimmed});
      await _load();
      if (mounted) _toast(tr.messSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= MEMBERS =======================
class _MembersTab extends StatelessWidget {
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> meals;
  final Future<void> Function() onChanged;
  final Future<void> Function() onAdd;
  const _MembersTab(
      {required this.members,
      required this.meals,
      required this.onChanged,
      required this.onAdd});

  double _mealsOf(dynamic id) {
    for (final m in meals) {
      if (m['member'] == id) {
        return double.tryParse('${m['meals'] ?? 0}') ?? 0;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onAdd,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(tr.messAddMember),
      ),
      body: RefreshIndicator(
        onRefresh: onChanged,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          itemCount: members.length,
          separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
          itemBuilder: (_, i) {
            final m = members[i];
            final meals = _mealsOf(m['id']);
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    _initial((m['name'] ?? '').toString()),
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                ),
                title: Text((m['name'] ?? '').toString(),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(tr.messMealsCount(_fmtMeals(meals))),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: tr.delete,
                  onPressed: () => _confirmDelete(context, m, onChanged),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _initial(String s) {
    final t = s.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }

  static Future<void> _confirmDelete(BuildContext context,
      Map<String, dynamic> m, Future<void> Function() onChanged) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.messDeleteMemberTitle),
        content: Text(tr.messDeleteMemberBody((m['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = m['id'];
    if (id is int) await api.deleteItem(_memberPath, id);
    await onChanged();
  }
}

// ======================= ENTRIES (meals + bazar + deposits + charges) ===
class _EntriesTab extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> meals;
  final List<Map<String, dynamic>> bazar;
  final List<Map<String, dynamic>> deposits;
  final List<Map<String, dynamic>> charges;
  final String Function(dynamic) nameOf;
  final Future<void> Function() onChanged;
  const _EntriesTab({
    required this.members,
    required this.meals,
    required this.bazar,
    required this.deposits,
    required this.charges,
    required this.nameOf,
    required this.onChanged,
  });

  @override
  State<_EntriesTab> createState() => _EntriesTabState();
}

class _EntriesTabState extends State<_EntriesTab> {
  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  // -- meals: edit each member's count this month --
  Future<void> _editMeals(Map<String, dynamic> member) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    Map<String, dynamic>? existing;
    for (final r in widget.meals) {
      if (r['member'] == member['id']) {
        existing = r;
        break;
      }
    }
    final current = parseNum('${existing?['meals'] ?? ''}');
    final raw = await _promptNumber(
      context,
      tr.messMealsFor((member['name'] ?? '').toString()),
      initial: current,
      allowDecimal: true,
      hint: tr.messMealsHint,
    );
    if (raw == null) return;
    // Users may type Bangla numerals per the on-screen hint, so
    // normalize to Latin before persisting — otherwise meals would store as 0.
    final val = normalizeDigits(raw);
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_mealsPath, existing['id'] as int,
            {'member': member['id'], 'meals': val});
      } else {
        await api
            .createItem(_mealsPath, {'member': member['id'], 'meals': val});
      }
      await widget.onChanged();
      if (mounted) _toast(tr.messSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return RefreshIndicator(
      onRefresh: widget.onChanged,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
        children: [
          _sectionHeader(context, Icons.restaurant_rounded,
              tr.messMealsSection, tr.messMealsSectionHint),
          for (final m in widget.members)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                title: Text((m['name'] ?? '').toString(),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(_fmtMeals(_mealsOf(m['id'])),
                    style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _editMeals(m),
              ),
            ),
          const SizedBox(height: Gap.lg),
          _ledgerSection(
            context,
            icon: Icons.shopping_basket_rounded,
            title: tr.messBazarSection,
            hint: tr.messBazarSectionHint,
            rows: widget.bazar,
            path: _bazarPath,
            labelFor: (r) => (r['title'] ?? tr.messBazarGeneric).toString(),
            withMember: false,
            onChanged: widget.onChanged,
          ),
          const SizedBox(height: Gap.lg),
          _ledgerSection(
            context,
            icon: Icons.savings_rounded,
            title: tr.messDepositsSection,
            hint: tr.messDepositsSectionHint,
            rows: widget.deposits,
            path: _depositsPath,
            labelFor: (r) => widget.nameOf(r['member']),
            withMember: true,
            onChanged: widget.onChanged,
          ),
          const SizedBox(height: Gap.lg),
          _ledgerSection(
            context,
            icon: Icons.receipt_long_rounded,
            title: tr.messChargesSection,
            hint: tr.messChargesSectionHint,
            rows: widget.charges,
            path: _chargesPath,
            labelFor: (r) {
              final mem = r['member'];
              if (mem == null || mem == 'common') return tr.messChargeCommon;
              return widget.nameOf(mem);
            },
            withMember: true,
            allowCommon: true,
            onChanged: widget.onChanged,
          ),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }

  double _mealsOf(dynamic id) {
    for (final r in widget.meals) {
      if (r['member'] == id) return double.tryParse('${r['meals'] ?? 0}') ?? 0;
    }
    return 0;
  }

  Widget _ledgerSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String hint,
    required List<Map<String, dynamic>> rows,
    required String path,
    required String Function(Map<String, dynamic>) labelFor,
    required bool withMember,
    bool allowCommon = false,
    required Future<void> Function() onChanged,
  }) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(context, icon, title, hint),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Text(tr.messNoEntriesYet,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            dense: true,
            title:
                Text(labelFor(r), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_fmtTk(r['amount']),
                  style: Theme.of(context).textTheme.titleSmall),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                tooltip: tr.delete,
                onPressed: () async {
                  final id = r['id'];
                  if (id is int) {
                    await context.read<AppState>().api.deleteItem(path, id);
                    await onChanged();
                  }
                },
              ),
            ]),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _addLedgerRow(
              context, path, withMember, allowCommon, title, onChanged),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.messAddEntry),
        ),
      ),
    ]);
  }

  Future<void> _addLedgerRow(
    BuildContext context,
    String path,
    bool withMember,
    bool allowCommon,
    String title,
    Future<void> Function() onChanged,
  ) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _LedgerForm(
        title: title,
        members: widget.members,
        withMember: withMember,
        allowCommon: allowCommon,
      ),
    );
    if (result == null) return;
    try {
      await api.createItem(path, result);
      await onChanged();
      if (mounted) _toast(tr.messSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= SUMMARY (the deterministic ledger) =============
class _SummaryTab extends StatelessWidget {
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> meals;
  final List<Map<String, dynamic>> bazar;
  final List<Map<String, dynamic>> deposits;
  final List<Map<String, dynamic>> charges;
  const _SummaryTab({
    required this.members,
    required this.meals,
    required this.bazar,
    required this.deposits,
    required this.charges,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _MessMath.summary(members, meals, bazar, deposits, charges);

    if (bazar.isEmpty && deposits.isEmpty) {
      return StateMessage(
        icon: Icons.calculate_rounded,
        title: tr.messSummaryEmptyTitle,
        message: tr.messSummaryEmptyBody,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
      children: [
        // top stat row: meal rate + totals
        Row(children: [
          Expanded(
            child: _statCard(
                context,
                tr.messMealRate,
                _MessMath.fmtPoisha(s.mealRate),
                scheme.primary,
                Icons.calculate_rounded),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _statCard(
                context,
                tr.messTotalBazar,
                _MessMath.fmtPoisha(s.bazarTotal.toDouble()),
                Brand.purple,
                Icons.shopping_basket_rounded),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Expanded(
            child: _statCard(
                context,
                tr.messTotalMeals,
                _fmtMeals(s.mealsTotal),
                scheme.secondary,
                Icons.restaurant_rounded),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _statCard(
                context,
                tr.messTotalDeposits,
                _MessMath.fmtPoisha(s.depositsTotal.toDouble()),
                Brand.success,
                Icons.savings_rounded),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        Text(tr.messPerMember, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        for (final r in s.rows) _memberRow(context, r),
        const SizedBox(height: Gap.lg),
        // transparency note + reconciliation
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(s.reconciles ? Icons.verified_rounded : Icons.info_outline_rounded,
                  size: 18,
                  color:
                      s.reconciles ? Brand.success : scheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.messNoMoneyNote,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _memberRow(BuildContext context, _MemberResult r) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color c = r.state == 'gets_back'
        ? Brand.success
        : (r.state == 'owes' ? scheme.error : scheme.onSurfaceVariant);
    final String badge = r.state == 'gets_back'
        ? tr.messGetsBack
        : (r.state == 'owes' ? tr.messOwes : tr.messClear);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(r.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text('$badge ${_MessMath.fmtPoisha(r.balance.toDouble())}',
                  style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          // transparent breakdown: meals × rate = cost; deposits; charges
          Wrap(spacing: Gap.md, runSpacing: Gap.xxs, children: [
            _kv(context, tr.messMeals, _fmtMeals(r.meals)),
            _kv(context, tr.messMealCost,
                _MessMath.fmtPoisha(r.mealCost.toDouble())),
            _kv(context, tr.messDeposits,
                _MessMath.fmtPoisha(r.deposits.toDouble())),
            if (r.otherCharges != 0)
              _kv(context, tr.messOtherCharges,
                  _MessMath.fmtPoisha(r.otherCharges.toDouble())),
          ]),
        ]),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
        children: [
          TextSpan(text: '$k '),
          TextSpan(
              text: v,
              style: TextStyle(
                  color: scheme.onSurface, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ======================= shared small helpers ==========================
Widget _statCard(BuildContext context, String label, String value, Color color,
    IconData icon) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(label,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(value,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    ),
  );
}

Widget _sectionHeader(
    BuildContext context, IconData icon, String title, String hint) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.xs),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(title,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(left: 26, top: Gap.xxs),
        child: Text(hint,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ),
    ]),
  );
}

String _fmtMeals(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

String _fmtTk(dynamic amount) =>
    _MessMath.fmtPoisha(_MessMath.toPoisha(amount).toDouble());

// ---- name prompt + number prompt bottom sheets ----
Future<String?> _promptName(BuildContext context, String title) async {
  final tr = AppLocalizations.of(context);
  final c = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final insets = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.messMemberName,
                border: const OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: Text(tr.save)),
          ),
        ]),
      );
    },
  );
}

Future<String?> _promptNumber(BuildContext context, String title,
    {double? initial, bool allowDecimal = false, String? hint}) async {
  final tr = AppLocalizations.of(context);
  final c =
      TextEditingController(text: initial == null ? '' : _fmtMeals(initial));
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final insets = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType:
                TextInputType.numberWithOptions(decimal: allowDecimal),
            decoration: InputDecoration(
                labelText: title,
                hintText: hint,
                border: const OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: Text(tr.save)),
          ),
        ]),
      );
    },
  );
}

/// Add-ledger-row form (amount + optional member/common selector + title).
class _LedgerForm extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> members;
  final bool withMember;
  final bool allowCommon;
  const _LedgerForm(
      {required this.title,
      required this.members,
      required this.withMember,
      required this.allowCommon});
  @override
  State<_LedgerForm> createState() => _LedgerFormState();
}

class _LedgerFormState extends State<_LedgerForm> {
  final _amount = TextEditingController();
  final _label = TextEditingController();
  dynamic _member; // member id, or 'common'

  @override
  void initState() {
    super.initState();
    if (widget.allowCommon) {
      _member = 'common';
    } else if (widget.members.isNotEmpty) {
      _member = widget.members.first['id'];
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final amountOk = (_MessMath.toPoisha(_amount.text)) > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              if (widget.withMember)
                DropdownButtonFormField<dynamic>(
                  initialValue: _member,
                  decoration: InputDecoration(
                      labelText: tr.messMember,
                      border: const OutlineInputBorder()),
                  items: [
                    if (widget.allowCommon)
                      DropdownMenuItem(
                          value: 'common', child: Text(tr.messChargeCommon)),
                    for (final m in widget.members)
                      DropdownMenuItem(
                          value: m['id'],
                          child: Text((m['name'] ?? '').toString())),
                  ],
                  onChanged: (v) => setState(() => _member = v),
                ),
              if (widget.withMember) const SizedBox(height: Gap.md),
              if (!widget.withMember)
                TextField(
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                      labelText: tr.messEntryTitle,
                      hintText: tr.messEntryTitleHint,
                      border: const OutlineInputBorder()),
                ),
              if (!widget.withMember) const SizedBox(height: Gap.md),
              TextField(
                controller: _amount,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.messAmount,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: amountOk
                        ? () => Navigator.pop(context, <String, dynamic>{
                              // Normalize Bangla numerals so the saved amount
                              // matches the Bangla-numeral value the user typed.
                              'amount': normalizeDigits(_amount.text.trim()),
                              if (widget.withMember) 'member': _member,
                              if (!widget.withMember &&
                                  _label.text.trim().isNotEmpty)
                                'title': _label.text.trim(),
                            })
                        : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }
}

// ===================================================================
// _MessMath — deterministic mirror of backend/core/logic/mess_accounting.py.
// All INTEGER POISHA. meal_cost_shares uses the largest-remainder method so
// per-member costs sum EXACTLY to the bazar total (zero drift).
// ===================================================================
class _MemberResult {
  final dynamic id;
  final String name;
  final double meals;
  final int mealCost;
  final int deposits;
  final int otherCharges;
  final int balance;
  final String state; // gets_back | owes | clear
  _MemberResult(this.id, this.name, this.meals, this.mealCost, this.deposits,
      this.otherCharges, this.balance, this.state);
}

class _MessSummary {
  final double mealsTotal;
  final int bazarTotal;
  final int depositsTotal;
  final double mealRate; // poisha per meal (display-only float)
  final List<_MemberResult> rows;
  final bool reconciles;
  _MessSummary(this.mealsTotal, this.bazarTotal, this.depositsTotal,
      this.mealRate, this.rows, this.reconciles);
}

class _MessMath {
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) v = v.toString();
    // Accept Bangla numerals (U+09E6..U+09EF) on input: the in-app hints tell
    // Bangla users to type Bangla numerals, so map them to Latin before parsing.
    var s = normalizeDigits(v.toString()).trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.sublist(1).join();
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = (frac + '00');
    frac = frac.substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtPoisha(double pf) {
    var p = pf.round();
    final neg = p < 0;
    p = p.abs();
    final taka = p ~/ 100;
    final paisa = p % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  static double _mealsOf(List<Map<String, dynamic>> meals, dynamic id) {
    for (final r in meals) {
      if (r['member'] == id) {
        final v = double.tryParse('${r['meals'] ?? 0}') ?? 0;
        return v < 0 ? 0 : (v * 1000).round() / 1000;
      }
    }
    return 0;
  }

  /// Largest-remainder distribution of [bazar] poisha across members by meals.
  static Map<dynamic, int> _mealCostShares(int bazar,
      List<Map<String, dynamic>> members, List<Map<String, dynamic>> meals) {
    final ids = members.map((m) => m['id']).toList();
    final weights =
        members.map((m) => (_mealsOf(meals, m['id']) * 1000).round()).toList();
    final out = {for (final id in ids) id: 0};
    final W = weights.fold<int>(0, (a, b) => a + b);
    if (W == 0 || bazar == 0) return out;
    final sign = bazar < 0 ? -1 : 1;
    final t = bazar.abs();
    final floors = <int>[];
    final rems = <int>[];
    for (final w in weights) {
      final num = t * w;
      floors.add(num ~/ W);
      rems.add(num % W);
    }
    var leftover = t - floors.fold<int>(0, (a, b) => a + b);
    final order = List<int>.generate(ids.length, (i) => i)
      ..sort((a, b) => rems[a] != rems[b] ? rems[b] - rems[a] : a - b);
    for (var k = 0; k < leftover; k++) {
      floors[order[k]] += 1;
    }
    for (var i = 0; i < ids.length; i++) {
      out[ids[i]] = sign * floors[i];
    }
    return out;
  }

  static _MessSummary summary(
    List<Map<String, dynamic>> members,
    List<Map<String, dynamic>> meals,
    List<Map<String, dynamic>> bazar,
    List<Map<String, dynamic>> deposits,
    List<Map<String, dynamic>> charges,
  ) {
    double mealsTotal = 0;
    for (final m in members) {
      mealsTotal += _mealsOf(meals, m['id']);
    }
    mealsTotal = (mealsTotal * 1000).round() / 1000;
    int bazarTotal = 0;
    for (final b in bazar) {
      bazarTotal += toPoisha(b['amount']);
    }
    final rate = mealsTotal <= 0 ? 0.0 : bazarTotal / mealsTotal;
    final mealCost = _mealCostShares(bazarTotal, members, meals);

    // deposits per member
    final dep = <dynamic, int>{};
    for (final d in deposits) {
      final mid = d['member'];
      dep[mid] = (dep[mid] ?? 0) + toPoisha(d['amount']);
    }
    int depositsTotal = dep.values.fold(0, (a, b) => a + b);

    // per-member charges + common charges split equally
    final perCharge = <dynamic, int>{};
    int commonTotal = 0;
    for (final c in charges) {
      final mem = c['member'];
      if (mem == null || mem == 'common' || mem == '' || mem == 'all') {
        commonTotal += toPoisha(c['amount']);
      } else {
        perCharge[mem] = (perCharge[mem] ?? 0) + toPoisha(c['amount']);
      }
    }
    final common = <dynamic, int>{for (final m in members) m['id']: 0};
    if (members.isNotEmpty && commonTotal != 0) {
      final n = members.length;
      final sign = commonTotal < 0 ? -1 : 1;
      final base = commonTotal.abs() ~/ n;
      final rem = commonTotal.abs() % n;
      for (var i = 0; i < n; i++) {
        common[members[i]['id']] = sign * (base + (i < rem ? 1 : 0));
      }
    }

    final rows = <_MemberResult>[];
    for (final m in members) {
      final id = m['id'];
      final mc = mealCost[id] ?? 0;
      final d = dep[id] ?? 0;
      final oc = (perCharge[id] ?? 0) + (common[id] ?? 0);
      final bal = d - mc - oc;
      final state = bal > 0 ? 'gets_back' : (bal < 0 ? 'owes' : 'clear');
      rows.add(_MemberResult(id, (m['name'] ?? '').toString(),
          _mealsOf(meals, id), mc, d, oc, bal, state));
    }

    final chargedOut = rows.fold<int>(0, (a, r) => a + r.mealCost) +
        perCharge.values.fold<int>(0, (a, b) => a + b) +
        common.values.fold<int>(0, (a, b) => a + b);
    final chargedIn = bazarTotal +
        perCharge.values.fold<int>(0, (a, b) => a + b) +
        commonTotal;
    final reconciles = chargedOut == chargedIn;

    return _MessSummary(
        mealsTotal, bazarTotal, depositsTotal, rate, rows, reconciles);
  }
}
