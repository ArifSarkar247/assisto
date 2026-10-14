import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// DOMESTIC STAFF / DRIVER tracker — ADVANCED (#186, SPEC v2.1 §20).
///
/// A respectful household-staff ledger: for each person (maid/bua, driver, cook,
/// guard, gardener, nanny, tutor) keep a profile — name, role, agreed MONTHLY
/// salary, join date — then, month by month, track attendance/leave, salary
/// paid vs due, advances/loans, and the one honest number a fair employer
/// settles on: NET DUES = unpaid wages − advance still held.
///
/// All MONEY is INTEGER POISHA. The on-screen math mirrors backend/core/logic/
/// domestic_staff.py VERBATIM (floor pro-rate, full month always pays the full
/// salary exactly) so the live summary is deterministic and identical offline.
/// The app HOLDS NO MONEY — it shows each person's number so you settle fairly.
///
/// Dignity: copy treats staff as employees owed a fair wage, never an expense to
/// minimise. Honest states: welcome (first use) · loading · error. ZERO Bangla
/// literals — every string is an AppLocalizations getter; ৳ is a currency glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('staff/people')   → [{id, name, role, salary, join_date}]
///   listItems('staff/payments') → [{id, person, month, kind, amount,
///                                    present_days, leave_days, month_days}]
///     kind ∈ {salary, advance, repay}; month 'YYYY-MM'.
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent).
class DomesticStaffScreen extends StatefulWidget {
  const DomesticStaffScreen({super.key});
  @override
  State<DomesticStaffScreen> createState() => _DomesticStaffScreenState();
}

const String _peoplePath = 'staff/people';
const String _paymentsPath = 'staff/payments';

// stable role keys (labels come from AppLocalizations)
const List<String> _roleKeys = [
  'maid',
  'driver',
  'cook',
  'guard',
  'gardener',
  'nanny',
  'tutor',
  'other',
];

String _roleLabel(AppLocalizations tr, String? key) {
  switch (key) {
    case 'maid':
      return tr.staffRoleMaid;
    case 'driver':
      return tr.staffRoleDriver;
    case 'cook':
      return tr.staffRoleCook;
    case 'guard':
      return tr.staffRoleGuard;
    case 'gardener':
      return tr.staffRoleGardener;
    case 'nanny':
      return tr.staffRoleNanny;
    case 'tutor':
      return tr.staffRoleTutor;
    default:
      return tr.staffRoleOther;
  }
}

/// Current month as 'YYYY-MM' (the only "now" the screen reads; passed into the
/// deterministic math exactly as the backend expects).
String _nowMonth() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
}

class _DomesticStaffScreenState extends State<DomesticStaffScreen> {
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true, _error = false;

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
        api.listItems(_peoplePath),
        api.listItems(_paymentsPath),
      ]);
      _people = res[0];
      _payments = res[1];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.staffTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.staffTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.staffLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_people.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.staffTitle)),
        body: StateMessage(
          icon: Icons.diversity_3_outlined,
          title: tr.staffWelcomeTitle,
          message: tr.staffWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addPerson,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(tr.staffAddPerson),
          ),
        ),
      );
    }

    final house = _StaffMath.household(_people, _payments, _nowMonth());
    return Scaffold(
      appBar: AppBar(title: Text(tr.staffTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPerson,
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(tr.staffAddPerson),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            // household roll-up
            Row(children: [
              Expanded(
                child: _statCard(
                    context,
                    tr.staffMonthlyPayroll,
                    _StaffMath.fmtPoisha(house.totalMonthlySalary.toDouble()),
                    scheme.primary,
                    Icons.payments_outlined),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: _statCard(
                    context,
                    tr.staffTotalDues,
                    _StaffMath.fmtPoisha(house.totalNetDues.toDouble()),
                    house.totalNetDues > 0 ? Brand.purple : Brand.success,
                    Icons.account_balance_wallet_outlined),
              ),
            ]),
            const SizedBox(height: Gap.lg),
            Text(tr.staffYourStaff,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            for (final s in house.people) _personCard(context, s),
            const SizedBox(height: Gap.lg),
            _noMoneyNote(context, tr.staffNoMoneyNote),
          ],
        ),
      ),
    );
  }

  Widget _personCard(BuildContext context, _PersonSummary s) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color c = s.state == 'owed'
        ? Brand.purple
        : (s.state == 'advance_due' ? scheme.error : Brand.success);
    final String badge = s.state == 'owed'
        ? tr.staffStateOwed
        : (s.state == 'advance_due' ? tr.staffStateAdvanceDue : tr.staffStateSettled);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _openPerson(s.id),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Text(_initial(s.name),
                    style: TextStyle(color: scheme.onPrimaryContainer)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.name,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text(
                          '${_roleLabel(tr, s.role)} · ${_StaffMath.fmtPoisha(s.salary.toDouble())}${tr.staffPerMonthSuffix}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ]),
              ),
              const SizedBox(width: Gap.sm),
              const Icon(Icons.chevron_right),
            ]),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                    '$badge ${_StaffMath.fmtPoisha(s.netDues.abs().toDouble())}',
                    style: TextStyle(
                        color: c, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              if (s.advanceBalance != 0)
                Text(
                    tr.staffAdvanceHeld(
                        _StaffMath.fmtPoisha(s.advanceBalance.toDouble())),
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _openPerson(dynamic id) async {
    final person = _people.firstWhere((p) => p['id'] == id,
        orElse: () => <String, dynamic>{});
    if (person.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PersonDetailScreen(
        person: person,
        allPayments: _payments,
      ),
    ));
    await _load();
  }

  Future<void> _addPerson() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PersonForm(),
    );
    if (result == null) return;
    final name = (result['name'] ?? '').toString().trim();
    final dup = _people.any(
        (p) => (p['name'] ?? '').toString().toLowerCase() == name.toLowerCase());
    if (dup) {
      _toast(tr.staffDuplicateName);
      return;
    }
    try {
      await api.createItem(_peoplePath, result);
      await _load();
      if (mounted) _toast(tr.staffSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  static String _initial(String s) {
    final t = s.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }
}

// ======================= PERSON DETAIL (month ledger) =======================
class _PersonDetailScreen extends StatefulWidget {
  final Map<String, dynamic> person;
  final List<Map<String, dynamic>> allPayments;
  const _PersonDetailScreen(
      {required this.person, required this.allPayments});
  @override
  State<_PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<_PersonDetailScreen> {
  late List<Map<String, dynamic>> _payments;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _payments = widget.allPayments
        .where((p) => p['person'] == widget.person['id'])
        .toList();
  }

  Future<void> _reload() async {
    final api = context.read<AppState>().api;
    final all = await api.listItems(_paymentsPath);
    setState(() => _payments =
        all.where((p) => p['person'] == widget.person['id']).toList());
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _StaffMath.personSummary(widget.person, _payments, _nowMonth());
    final Color c = s.state == 'owed'
        ? Brand.purple
        : (s.state == 'advance_due' ? scheme.error : Brand.success);
    final String stateLabel = s.state == 'owed'
        ? tr.staffStateOwed
        : (s.state == 'advance_due'
            ? tr.staffStateAdvanceDue
            : tr.staffStateSettled);
    return Scaffold(
      appBar: AppBar(
        title: Text((widget.person['name'] ?? '').toString()),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr.edit,
            onPressed: _editProfile,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr.delete,
            onPressed: _confirmDeletePerson,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addPayment,
        icon: const Icon(Icons.add),
        label: Text(tr.staffLogEntry),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          // headline net-dues card
          Card(
            color: c.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(stateLabel,
                        style: TextStyle(
                            color: c, fontWeight: FontWeight.w700)),
                    const SizedBox(height: Gap.xs),
                    Text(_StaffMath.fmtPoisha(s.netDues.abs().toDouble()),
                        style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: scheme.onSurface)),
                    const SizedBox(height: Gap.xs),
                    Text(
                        '${_roleLabel(tr, (widget.person['role'] ?? '').toString())} · ${_StaffMath.fmtPoisha(s.salary.toDouble())}${tr.staffPerMonthSuffix}',
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ]),
            ),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
                child: _statCard(
                    context,
                    tr.staffWagesOutstanding,
                    _StaffMath.fmtPoisha(s.wagesOutstanding.toDouble()),
                    s.wagesOutstanding > 0 ? Brand.purple : Brand.success,
                    Icons.receipt_long_outlined)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: _statCard(
                    context,
                    tr.staffAdvanceBalance,
                    _StaffMath.fmtPoisha(s.advanceBalance.toDouble()),
                    scheme.secondary,
                    Icons.account_balance_wallet_outlined)),
          ]),
          const SizedBox(height: Gap.lg),
          Text(tr.staffMonthByMonth,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          if (s.months.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Text(tr.staffNoMonthsYet,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final m in s.months) _monthCard(context, m),
          const SizedBox(height: Gap.lg),
          _noMoneyNote(context, tr.staffNoMoneyNote),
        ],
      ),
    );
  }

  Widget _monthCard(BuildContext context, _MonthResult m) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color c = m.state == 'owed'
        ? Brand.purple
        : (m.state == 'overpaid' ? scheme.secondary : Brand.success);
    final String badge = m.state == 'owed'
        ? tr.staffMonthOwed
        : (m.state == 'overpaid' ? tr.staffMonthOverpaid : tr.staffMonthSettled);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(m.month,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(
                  '$badge ${_StaffMath.fmtPoisha(m.outstanding.abs().toDouble())}',
                  style: TextStyle(
                      color: c, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.md, runSpacing: 2, children: [
            _kv(context, tr.staffDue,
                _StaffMath.fmtPoisha(m.due.toDouble())),
            _kv(context, tr.staffPaid,
                _StaffMath.fmtPoisha(m.paid.toDouble())),
            if (m.advance != 0)
              _kv(context, tr.staffAdvance,
                  _StaffMath.fmtPoisha(m.advance.toDouble())),
            if (m.repay != 0)
              _kv(context, tr.staffRepay,
                  _StaffMath.fmtPoisha(m.repay.toDouble())),
            if (m.presentDays != null)
              _kv(context, tr.staffAttendance,
                  tr.staffDaysPresent(m.presentDays!, m.monthDays ?? 30)),
          ]),
        ]),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
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

  Future<void> _addPayment() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PaymentForm(defaultMonth: _nowMonth()),
    );
    if (result == null) return;
    result['person'] = widget.person['id'];
    setState(() => _busy = true);
    try {
      await api.createItem(_paymentsPath, result);
      await _reload();
      if (mounted) _toast(tr.staffSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editProfile() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PersonForm(initial: widget.person),
    );
    if (result == null) return;
    final id = widget.person['id'];
    if (id is! int) return;
    try {
      await api.updateItem(_peoplePath, id, result);
      widget.person.addAll(result);
      setState(() {});
      if (mounted) _toast(tr.staffSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _confirmDeletePerson() async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.staffDeleteTitle),
        content:
            Text(tr.staffDeleteBody((widget.person['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = widget.person['id'];
    if (id is int) await api.deleteItem(_peoplePath, id);
    if (mounted) Navigator.of(context).pop();
  }
}

// ======================= forms =======================
class _PersonForm extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _PersonForm({this.initial});
  @override
  State<_PersonForm> createState() => _PersonFormState();
}

class _PersonFormState extends State<_PersonForm> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?['name']?.toString() ?? '');
  late final TextEditingController _salary = TextEditingController(
      text: _StaffMath.takaText(widget.initial?['salary']));
  late String _role =
      (widget.initial?['role']?.toString().isNotEmpty ?? false)
          ? widget.initial!['role'].toString()
          : 'maid';
  late final TextEditingController _joinDate = TextEditingController(
      text: widget.initial?['join_date']?.toString() ?? _nowMonth());

  @override
  void dispose() {
    _name.dispose();
    _salary.dispose();
    _joinDate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final nameOk = _name.text.trim().isNotEmpty;
    final salaryOk = _StaffMath.toPoisha(_salary.text) > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  widget.initial == null
                      ? tr.staffAddPerson
                      : tr.staffEditPerson,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _name,
                autofocus: widget.initial == null,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.staffName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: InputDecoration(
                    labelText: tr.staffRole,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _roleKeys)
                    DropdownMenuItem(value: k, child: Text(_roleLabel(tr, k))),
                ],
                onChanged: (v) => setState(() => _role = v ?? 'maid'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _salary,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.staffMonthlySalary,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _joinDate,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.staffJoinDate,
                    hintText: tr.staffMonthHint,
                    helperText: tr.staffMonthHelper,
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
                    onPressed: (nameOk && salaryOk)
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'name': _name.text.trim(),
                              'role': _role,
                              'salary': _salary.text.trim(),
                              'join_date': _joinDate.text.trim(),
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

class _PaymentForm extends StatefulWidget {
  final String defaultMonth;
  const _PaymentForm({required this.defaultMonth});
  @override
  State<_PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<_PaymentForm> {
  String _kind = 'salary'; // salary | advance | repay
  final _amount = TextEditingController();
  final _present = TextEditingController();
  final _monthDays = TextEditingController(text: '30');
  late final _month = TextEditingController(text: widget.defaultMonth);

  @override
  void dispose() {
    _amount.dispose();
    _present.dispose();
    _monthDays.dispose();
    _month.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final amountOk = _StaffMath.toPoisha(_amount.text) > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.staffLogEntry,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'salary', label: Text(tr.staffKindSalary)),
                  ButtonSegment(
                      value: 'advance', label: Text(tr.staffKindAdvance)),
                  ButtonSegment(value: 'repay', label: Text(tr.staffKindRepay)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _amount,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.staffAmount,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _month,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.staffMonth,
                    hintText: tr.staffMonthHint,
                    border: const OutlineInputBorder()),
              ),
              if (_kind == 'salary') ...[
                const SizedBox(height: Gap.md),
                Text(tr.staffAttendanceOptional,
                    style: TextStyle(
                        fontSize: 12.5,
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _present,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: tr.staffPresentDays,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: TextField(
                      controller: _monthDays,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: tr.staffMonthDays,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                ]),
              ],
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
                        ? () {
                            final out = <String, dynamic>{
                              'kind': _kind,
                              'amount': _amount.text.trim(),
                              'month': _month.text.trim(),
                            };
                            if (_kind == 'salary') {
                              final pd = _present.text.trim();
                              final md = _monthDays.text.trim();
                              if (pd.isNotEmpty) out['present_days'] = pd;
                              if (md.isNotEmpty) out['month_days'] = md;
                            }
                            Navigator.pop(context, out);
                          }
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

// ======================= shared small helpers =======================
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
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(value,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    ),
  );
}

Widget _noMoneyNote(BuildContext context, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.shield_outlined, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}

// ===================================================================
// _StaffMath — deterministic mirror of backend/core/logic/domestic_staff.py.
// All INTEGER POISHA. Full month always pays the full salary EXACTLY; a partial
// month is a floor; net dues = unpaid wages − advance still held.
// ===================================================================
class _MonthResult {
  final String month;
  final int due;
  final int paid;
  final int advance;
  final int repay;
  final int outstanding;
  final int? presentDays;
  final int? monthDays;
  final String state; // owed | settled | overpaid
  _MonthResult(this.month, this.due, this.paid, this.advance, this.repay,
      this.outstanding, this.presentDays, this.monthDays, this.state);
}

class _PersonSummary {
  final dynamic id;
  final String name;
  final String role;
  final int salary;
  final int totalDue;
  final int totalPaid;
  final int wagesOutstanding;
  final int advanceBalance;
  final int netDues;
  final List<_MonthResult> months;
  final String state; // owed | advance_due | settled
  _PersonSummary(
      this.id,
      this.name,
      this.role,
      this.salary,
      this.totalDue,
      this.totalPaid,
      this.wagesOutstanding,
      this.advanceBalance,
      this.netDues,
      this.months,
      this.state);
}

class _HouseholdSummary {
  final int count;
  final int totalMonthlySalary;
  final int totalNetDues;
  final List<_PersonSummary> people;
  _HouseholdSummary(
      this.count, this.totalMonthlySalary, this.totalNetDues, this.people);
}

class _StaffMath {
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) v = v.toString();
    var s = v.toString().trim().replaceAll(',', '');
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
    frac = '${frac}00'.substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  /// Pre-fill a taka field from a stored poisha-or-taka value.
  static String takaText(dynamic v) {
    final p = toPoisha(v);
    if (p == 0) return '';
    final taka = p ~/ 100;
    final paisa = p % 100;
    return paisa == 0 ? taka.toString() : '$taka.${paisa.toString().padLeft(2, '0')}';
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

  // ---- month helpers ----
  static List<int>? _ym(dynamic s) {
    if (s == null || s.toString().trim().isEmpty) return null;
    final parts = s.toString().trim().split('-');
    if (parts.length < 2) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null || m < 1 || m > 12) return null;
    return [y, m];
  }

  static String _monthKey(dynamic s) {
    final ym = _ym(s);
    return ym == null
        ? ''
        : '${ym[0].toString().padLeft(4, '0')}-${ym[1].toString().padLeft(2, '0')}';
  }

  static int _cmpMonth(String a, String b) {
    final ya = _ym(a) ?? [0, 0];
    final yb = _ym(b) ?? [0, 0];
    if (ya[0] != yb[0]) return ya[0].compareTo(yb[0]);
    return ya[1].compareTo(yb[1]);
  }

  static int monthDue(int salary, int? present, int? monthDays) {
    if (salary <= 0) return 0;
    if (present == null) return salary;
    var md = (monthDays == null || monthDays <= 0) ? 30 : monthDays;
    if (present < 0) return salary; // bad entry never deducts
    if (present >= md) return salary;
    return (salary * present) ~/ md;
  }

  static _MonthResult _personMonth(
      Map<String, dynamic> person,
      List<Map<String, dynamic>> payments,
      String month) {
    final mk = _monthKey(month);
    final sal = toPoisha(person['salary']);
    final mine = payments
        .where((p) =>
            p['person'] == person['id'] && _monthKey(p['month']) == mk)
        .toList();
    int? present, monthDays;
    for (final p in mine) {
      if ((p['kind'] ?? 'salary') == 'salary') {
        if (p['present_days'] != null && '${p['present_days']}'.isNotEmpty) {
          present = int.tryParse('${p['present_days']}'.split('.').first);
        }
        if (p['month_days'] != null && '${p['month_days']}'.isNotEmpty) {
          monthDays = int.tryParse('${p['month_days']}'.split('.').first);
        }
      }
    }
    final due = monthDue(sal, present, monthDays);
    int sumKind(String k) => mine
        .where((p) => (p['kind'] ?? 'salary') == k)
        .fold<int>(0, (a, p) => a + toPoisha(p['amount']));
    final paid = sumKind('salary');
    final advance = sumKind('advance');
    final repay = sumKind('repay');
    final outstanding = due - paid;
    final state =
        outstanding > 0 ? 'owed' : (outstanding < 0 ? 'overpaid' : 'settled');
    return _MonthResult(mk, due, paid, advance, repay, outstanding, present,
        monthDays, state);
  }

  static _PersonSummary personSummary(Map<String, dynamic> person,
      List<Map<String, dynamic>> payments, String now) {
    final sal = toPoisha(person['salary']);
    final nowk = _monthKey(now);
    final joink = _monthKey(person['join_date']);
    final mine =
        payments.where((p) => p['person'] == person['id']).toList();

    final months = <String>{};
    final jym = _ym(joink);
    final nym = _ym(nowk);
    if (jym != null && nym != null && _cmpMonth(joink, nowk) <= 0) {
      var y = jym[0], m = jym[1];
      while (y < nym[0] || (y == nym[0] && m <= nym[1])) {
        months.add(
            '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}');
        m++;
        if (m > 12) {
          m = 1;
          y++;
        }
      }
    }
    for (final p in mine) {
      final mk = _monthKey(p['month']);
      if (mk.isNotEmpty) months.add(mk);
    }
    final ordered = months.toList()..sort((a, b) => _cmpMonth(b, a)); // newest

    final rows = [for (final mk in ordered) _personMonth(person, mine, mk)];
    final totalDue = rows.fold<int>(0, (a, r) => a + r.due);
    final totalPaid = rows.fold<int>(0, (a, r) => a + r.paid);
    final wagesOutstanding = rows
        .where((r) => r.outstanding > 0)
        .fold<int>(0, (a, r) => a + r.outstanding);
    int sumKind(String k) => mine
        .where((p) => (p['kind'] ?? 'salary') == k)
        .fold<int>(0, (a, p) => a + toPoisha(p['amount']));
    final advanceBalance = sumKind('advance') - sumKind('repay');
    final netDues = wagesOutstanding - advanceBalance;
    final state = netDues > 0
        ? 'owed'
        : (advanceBalance > wagesOutstanding ? 'advance_due' : 'settled');
    return _PersonSummary(
        person['id'],
        (person['name'] ?? '').toString(),
        (person['role'] ?? '').toString(),
        sal,
        totalDue,
        totalPaid,
        wagesOutstanding,
        advanceBalance,
        netDues,
        rows,
        state);
  }

  static _HouseholdSummary household(List<Map<String, dynamic>> people,
      List<Map<String, dynamic>> payments, String now) {
    final summaries = [
      for (final p in people) personSummary(p, payments, now)
    ]..sort((a, b) {
        if (a.netDues != b.netDues) return b.netDues.compareTo(a.netDues);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final totalSalary =
        people.fold<int>(0, (a, p) => a + toPoisha(p['salary']));
    final totalNet = summaries.fold<int>(0, (a, s) => a + s.netDues);
    return _HouseholdSummary(people.length, totalSalary, totalNet, summaries);
  }
}
