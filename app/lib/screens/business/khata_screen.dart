import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import '../../services/action_feedback.dart'; // db1
import '../../services/error_report.dart'; // db1
import '../../services/error_kind.dart' show honestFailText; // qa2

/// Digital Khata (plan §2): two-sided dues — customer receivables +
/// supplier payables. The supplier tab is hidden for staff (they must
/// not see cost). Party list shows a running balance; tap a party for the full
/// statement + add-entry / payment. A net-position header summarises both
/// books, and a tagada (reminder) flow fans out WhatsApp/SMS messages the
/// server pre-wrote — single, bulk and scheduled.
class KhataScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  const KhataScreen({super.key, required this.business});
  @override
  State<KhataScreen> createState() => _KhataScreenState();
}

class _KhataScreenState extends State<KhataScreen> {
  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  bool get _isStaff => (widget.business['role'] ?? 'owner') == 'staff';

  // Owner sees two tabs; staff sees only the customer book.
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_isStaff) {
      return Scaffold(
        appBar: AppBar(title: Text(t.khataTitle)),
        body: _BookTab(
            businessId: _bizId,
            business: widget.business,
            book: 'customer',
            isStaff: true),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.khataTitle),
          bottom: TabBar(
              // large font: scroll instead of cutting "Customers (Dues)"
              isScrollable: MediaQuery.textScalerOf(context).scale(10) > 11.5,
              tabAlignment: MediaQuery.textScalerOf(context).scale(10) > 11.5
                  ? TabAlignment.start
                  : null,
              tabs: [
            Tab(child: Text(t.khataCustomers, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.khataSuppliers, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: TabBarView(children: [
          _BookTab(
              businessId: _bizId,
              business: widget.business,
              book: 'customer',
              isStaff: false),
          _BookTab(
              businessId: _bizId,
              business: widget.business,
              book: 'supplier',
              isStaff: false),
        ]),
      ),
    );
  }
}

/// One book (customer or supplier): net header + party list + bulk tagada +
/// add-party FAB.
class _BookTab extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic> business;
  final String book;
  final bool isStaff;
  const _BookTab(
      {required this.businessId,
      required this.business,
      required this.book,
      required this.isStaff});
  @override
  State<_BookTab> createState() => _BookTabState();
}

class _BookTabState extends State<_BookTab> {
  List<Map<String, dynamic>> _parties = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _selecting = false; // bulk-tagada selection mode
  final Set<int> _picked = {};

  bool get _isCustomer => widget.book == 'customer';

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
      final r = await context
          .read<AppState>()
          .api
          .khataParties(widget.businessId, widget.book);
      _parties = ((r['parties'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addParty() async {
    final t = AppLocalizations.of(context);
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddPartySheet(
          businessId: widget.businessId, book: widget.book),
    );
    if (created == true) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.khataPartyAdded)));
      }
    }
  }

  Future<void> _openParty(Map<String, dynamic> party) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PartyStatementScreen(
        business: widget.business,
        party: party,
        book: widget.book,
      ),
    ));
    if (mounted) _load();
  }

  Future<void> _bulkTagada() async {
    if (_picked.isEmpty) return;
    final t = AppLocalizations.of(context);
    final preset = await _pickTone(context);
    if (preset == null) return;
    try {
      final r = await context.read<AppState>().api.tagadaBulk(
            businessId: widget.businessId,
            partyIds: _picked.toList(),
            preset: preset,
          );
      final reminders =
          ((r['reminders'] ?? []) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      // Fan out: hand the owner one combined share sheet of all messages.
      final lines = reminders
          .map((x) => pair(context, x['message']))
          .where((s) => s.isNotEmpty)
          .toList();
      if (lines.isNotEmpty) await Share.share(lines.join('\n\n'));
      setState(() {
        _selecting = false;
        _picked.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.tagadaSentCount(reminders.length))));
    } catch (e) {
      showActionFailed(context, 'khata.bulkTagada', e); // db1
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.khataTitle,
        message: honestFailText(t, _failCause, otherwise: t.businessLoadFailed),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    return Scaffold(
      floatingActionButton: _selecting
          ? FloatingActionButton.extended(
              onPressed: _bulkTagada,
              icon: const Icon(Icons.campaign_rounded),
              label: Text(t.tagadaSendAll),
            )
          : FloatingActionButton(
              tooltip: _isCustomer ? t.khataAddCustomer : t.khataAddSupplier,
              onPressed: _addParty,
              child: const Icon(Icons.person_add_alt_1_rounded)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _parties.isEmpty
            ? ListView(children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.6,
                  child: StateMessage(
                    icon: _isCustomer
                        ? Icons.people_outline_rounded
                        : Icons.local_shipping_rounded,
                    title: _isCustomer
                        ? t.khataNoCustomers
                        : t.khataNoSuppliers,
                    message: t.khataAddPartyHint,
                    action: FilledButton.icon(
                      onPressed: _addParty,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(_isCustomer
                          ? t.khataAddCustomer
                          : t.khataAddSupplier),
                    ),
                  ),
                ),
              ])
            // perf2gb: header stays mounted (SliverToBoxAdapter), the party
            // rows are lazy — 500 customers no longer build 500 tiles at once.
            : CustomScrollView(
                // RefreshIndicator needs the list to be scrollable when short
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _NetHeader(
                              businessId: widget.businessId,
                              isCustomer: _isCustomer,
                              isStaff: widget.isStaff),
                          const SizedBox(height: Gap.md),
                          // Wrap: on a large font the "remind everyone" button moves
                          // to its own line instead of squeezing the title.
                          Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                            Text(
                              _isCustomer ? t.khataCustomers : t.khataSuppliers,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (_isCustomer)
                              TextButton.icon(
                                icon: Icon(
                                    _selecting ? Icons.close_rounded : Icons.campaign_rounded,
                                    size: 18),
                                label: Text(_selecting
                                    ? t.cancel
                                    : t.tagadaSendAll),
                                onPressed: () => setState(() {
                                  _selecting = !_selecting;
                                  _picked.clear();
                                }),
                              ),
                          ]),
                          const SizedBox(height: Gap.sm),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 96),
                    sliver: SliverList.builder(
                      itemCount: _parties.length,
                      itemBuilder: (context, i) {
                        final p = _parties[i];
                        return _PartyTile(
                          party: p,
                          book: widget.book,
                          selecting: _selecting && _isCustomer,
                          picked: _picked.contains((p['id'] as num?)?.toInt()),
                          onTogglePick: () {
                            final id = (p['id'] as num?)?.toInt();
                            if (id == null) return;
                            setState(() {
                              if (_picked.contains(id)) {
                                _picked.remove(id);
                              } else {
                                _picked.add(id);
                              }
                            });
                          },
                          onTap: () => _openParty(p),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Net-position summary strip for the active book.
class _NetHeader extends StatefulWidget {
  final int businessId;
  final bool isCustomer;
  final bool isStaff;
  const _NetHeader(
      {required this.businessId,
      required this.isCustomer,
      required this.isStaff});
  @override
  State<_NetHeader> createState() => _NetHeaderState();
}

class _NetHeaderState extends State<_NetHeader> {
  Map<String, dynamic>? _np;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _np = await context
          .read<AppState>()
          .api
          .khataNetPosition(widget.businessId);
    } catch (e) {
      // db1: automatic load (not a tap). On failure the card is HIDDEN —
      // never a fake ৳0 net position.
      reportNonFatal('khata.netPosition', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(Gap.lg),
              child: Skeleton(width: 160, height: 16)));
    }
    if (_np == null) return const SizedBox.shrink(); // db1: load failed
    final np = _np ?? const {};
    final label = widget.isCustomer ? t.netReceivable : t.netPayable;
    final value = widget.isCustomer
        ? pair(context, np['receivable_display'], fallback: '৳0')
        : pair(context, np['payable_display'], fallback: '৳0');
    final color = widget.isCustomer ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error;
    return BrandBand(
      padding: const EdgeInsets.all(Gap.lg),
      child: Row(children: [
        Icon(widget.isCustomer
            ? Icons.call_received_rounded
            : Icons.call_made_rounded),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AType.bodyMedium),
            const SizedBox(height: Gap.xxs),
            Text(value,
                style: AType.headlineSmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
          ]),
        ),
        Icon(Icons.circle_rounded, size: 10, color: color.withValues(alpha: 0.9)),
      ]),
    );
  }
}

String _initial(String name) =>
    name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

class _PartyTile extends StatelessWidget {
  final Map<String, dynamic> party;
  final String book;
  final bool selecting;
  final bool picked;
  final VoidCallback onTogglePick;
  final VoidCallback onTap;
  const _PartyTile({
    required this.party,
    required this.book,
    required this.selecting,
    required this.picked,
    required this.onTogglePick,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vip = party['vip'] == true;
    final balanceDisplay = pair(context, party['balance_display']);
    final balanceStatus = pair(context, party['balance_status']);
    final poisha = (party['balance_poisha'] as num?)?.toInt() ?? 0;
    // Owner-POV colouring: positive receivable/payable -> brand tint; settled
    // -> neutral. We colour purely by sign for a quick read.
    final color = poisha == 0
        ? scheme.onSurfaceVariant
        : (book == 'customer' ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: ListTile(
        onTap: selecting ? onTogglePick : onTap,
        leading: selecting
            ? Checkbox(value: picked, onChanged: (_) => onTogglePick())
            : CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Text(
                  _initial((party['name'] ?? '').toString()),
                  style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700),
                ),
              ),
        title: Row(children: [
          Flexible(
            child: Text((party['name'] ?? '').toString(),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (vip) ...[
            const SizedBox(width: Gap.xs),
            Icon(Icons.star_rounded, size: 14, color: AssistoTokens.of(context).warning),
          ],
        ]),
        subtitle: balanceStatus.isEmpty ? null : Text(balanceStatus),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(balanceDisplay,
                style: TextStyle(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}

// ========================= add party sheet ===============================

class _AddPartySheet extends StatefulWidget {
  final int businessId;
  final String book;
  const _AddPartySheet({required this.businessId, required this.book});
  @override
  State<_AddPartySheet> createState() => _AddPartySheetState();
}

class _AddPartySheetState extends State<_AddPartySheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _area = TextEditingController();
  bool _vip = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _area.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.khataCreateParty(
            businessId: widget.businessId,
            book: widget.book,
            name: name,
            phone: _phone.text.trim(),
            area: _area.text.trim(),
            vip: _vip,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final isCustomer = widget.book == 'customer';
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(isCustomer ? t.khataAddCustomer : t.khataAddSupplier,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.name, prefixIcon: const Icon(Icons.person_outline_rounded))),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: t.phone, prefixIcon: const Icon(Icons.call_rounded))),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _area,
            decoration: InputDecoration(
                labelText: t.khataPartyArea,
                prefixIcon: const Icon(Icons.location_on_rounded))),
        const SizedBox(height: Gap.sm),
        if (isCustomer)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _vip,
            title: Text(t.khataPartyVip),
            onChanged: (v) => setState(() => _vip = v),
          ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

// ===================== party statement screen ============================

class _PartyStatementScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  final Map<String, dynamic> party;
  final String book;
  const _PartyStatementScreen(
      {required this.business, required this.party, required this.book});
  @override
  State<_PartyStatementScreen> createState() => _PartyStatementScreenState();
}

class _PartyStatementScreenState extends State<_PartyStatementScreen> {
  Map<String, dynamic>? _stmt;
  bool _loading = true;

  int get _partyId => (widget.party['id'] as num?)?.toInt() ?? 0;
  bool get _isCustomer => widget.book == 'customer';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _stmt = await context.read<AppState>().api.khataStatement(_partyId);
    } catch (e) {
      showActionFailed(context, 'khata.statement', e); // db1
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addEntry({required bool isDue}) async {
    // isDue=true -> a credit/due (owner 'gave' goods to customer / 'got' goods
    // from supplier). The direction mapping is owner-POV; we let the sheet pick
    // the right verb per book.
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EntrySheet(
        business: widget.business,
        partyId: _partyId,
        book: widget.book,
        isDue: isDue,
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _tagada() async {
    final t = AppLocalizations.of(context);
    final preset = await _pickTone(context);
    if (preset == null) return;
    try {
      final r = await context
          .read<AppState>()
          .api
          .tagadaSingle(partyId: _partyId, preset: preset);
      if (!mounted) return;
      await _showTagadaShare(context, widget.party, r);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.businessLoadFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = (widget.party['name'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          if (_isCustomer)
            IconButton(
              tooltip: t.tagadaSendReminder,
              icon: const Icon(Icons.campaign_rounded),
              onPressed: _tagada,
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: Text(t.entryAddCredit),
                onPressed: () => _addEntry(isDue: true),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.payments_rounded),
                label: Text(_isCustomer
                    ? t.entryReceivePayment
                    : t.entryMakePayment),
                onPressed: () => _addEntry(isDue: false),
              ),
            ),
          ]),
        ),
      ),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: _StatementBody(
                  stmt: _stmt ?? const {},
                  party: widget.party,
                  book: widget.book),
            ),
    );
  }
}

class _StatementBody extends StatelessWidget {
  final Map<String, dynamic> stmt;
  final Map<String, dynamic> party;
  final String book;
  const _StatementBody(
      {required this.stmt, required this.party, required this.book});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lines = ((stmt['lines'] ?? []) as List).cast<Map<String, dynamic>>();
    final balanceDisplay = pair(context, party['balance_display']);
    final balanceStatus = pair(context, party['balance_status']);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl),
      children: [
        BrandBand(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(balanceStatus.isEmpty ? t.khataDueLabel : balanceStatus,
                style: AType.bodyMedium),
            const SizedBox(height: Gap.xxs),
            Text(balanceDisplay,
                style: AType.headlineMedium.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: Gap.lg),
        if ((party['phone'] ?? '').toString().isNotEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.call_rounded),
              title: Text((party['phone'] ?? '').toString()),
              trailing: Icon(Icons.call_rounded, color: AssistoTokens.of(context).success),
              onTap: () => launchUrl(Uri.parse('tel:${party['phone']}')),
            ),
          ),
        const SizedBox(height: Gap.lg),
        Row(children: [
          const Icon(Icons.history_rounded, size: 18),
          const SizedBox(width: Gap.sm),
          Text(t.stmtParticulars,
              style: Theme.of(context).textTheme.titleMedium),
        ]),
        const SizedBox(height: Gap.sm),
        if (lines.isEmpty)
          Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Center(
                child: Text(t.khataNoDues,
                    style: TextStyle(color: scheme.onSurfaceVariant))),
          )
        else
          for (final line in lines) _StatementRow(line: line),
      ],
    );
  }
}

class _StatementRow extends StatelessWidget {
  final Map<String, dynamic> line;
  const _StatementRow({required this.line});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final debit = pair(context, line['debit_display']);
    final credit = pair(context, line['credit_display']);
    final isDebit = debit.isNotEmpty && debit != '৳0';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(isDebit ? Icons.north_east_rounded : Icons.south_west_rounded,
              size: 18, color: isDebit ? Theme.of(context).colorScheme.error : AssistoTokens.of(context).success),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      pair(context, line['particulars'],
                          fallback: isDebit ? t.stmtDebit : t.stmtCredit),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: Gap.xxs),
                  Text(pair(context, line['at_display'],
                      fallback: (line['at'] ?? '').toString()),
                      style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
                ]),
          ),
          const SizedBox(width: Gap.sm),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(isDebit ? debit : credit,
                style: TextStyle(fontFeatures: AFonts.tabular,
                    fontWeight: FontWeight.w700,
                    color: isDebit ? Theme.of(context).colorScheme.error : AssistoTokens.of(context).success)),
            Text(pair(context, line['balance_display']),
                style:
                    AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
          ]),
        ]),
      ),
    );
  }
}

// ========================= add-entry sheet ===============================

class _EntrySheet extends StatefulWidget {
  final Map<String, dynamic> business;
  final int partyId;
  final String book;
  final bool isDue; // true -> add due/credit; false -> payment
  const _EntrySheet(
      {required this.business,
      required this.partyId,
      required this.book,
      required this.isDue});
  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _at = DateTime.now();
  bool _notifyCustomer = false;
  bool _saving = false;

  bool get _isCustomer => widget.book == 'customer';

  // Owner-POV direction mapping:
  //  customer + due      -> 'gave' (I gave goods on credit)
  //  customer + payment  -> 'got'  (I received payment)
  //  supplier + due      -> 'got'  (I received goods on credit)
  //  supplier + payment  -> 'gave' (I paid the supplier)
  String get _direction {
    if (_isCustomer) return widget.isDue ? 'gave' : 'got';
    return widget.isDue ? 'got' : 'gave';
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final poisha = takaToPoisha(_amount.text);
    if (poisha == null || poisha <= 0) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    setState(() => _saving = true);
    try {
      final api = context.read<AppState>().api;
      Map<String, dynamic> r;
      if (widget.isDue) {
        r = await api.khataAddEntry(
          partyId: widget.partyId,
          direction: _direction,
          amountPoisha: poisha,
          note: _note.text.trim(),
          atIso: _at.toIso8601String(),
          notifyCustomer: _isCustomer && _notifyCustomer,
        );
      } else {
        r = await api.khataPayment(
          partyId: widget.partyId,
          amountPoisha: poisha,
          note: _note.text.trim(),
          atIso: _at.toIso8601String(),
        );
      }
      if (!mounted) return;
      // If the server returned an "entry added" message to notify the
      // customer, offer to share it.
      final msg = r['entry_added_message'];
      if (msg != null) {
        final text = pair(context, msg);
        if (text.isNotEmpty) await Share.share(text);
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final title = widget.isDue
        ? t.entryAddCredit
        : (_isCustomer ? t.entryReceivePayment : t.entryMakePayment);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: t.entryAmount, prefixText: '৳ '),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _note,
          decoration: InputDecoration(
              labelText: t.entryNote,
              prefixIcon: const Icon(Icons.notes_rounded)),
        ),
        const SizedBox(height: Gap.sm),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_rounded),
          title: Text(t.entryDate),
          // qa1: localized date (was ISO "2026-10-22" in both languages)
          trailing: Text(DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
              .format(_at)),
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _at,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 1)),
            );
            if (picked != null) setState(() => _at = picked);
          },
        ),
        if (widget.isDue && _isCustomer)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _notifyCustomer,
            title: Text(t.tagadaNotifyCustomerOnDue),
            onChanged: (v) => setState(() => _notifyCustomer = v),
          ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

// ========================= tagada helpers ================================

/// Pick a tagada tone/preset. Returns the preset key the API expects.
Future<String?> _pickTone(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(t.tagadaPickTone,
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
        ),
        _toneTile(ctx, 'polite', Icons.volunteer_activism_rounded,
            t.tagadaTonePolite),
        _toneTile(ctx, 'reminder', Icons.notifications_rounded,
            t.tagadaToneReminder),
        _toneTile(ctx, 'firm', Icons.gavel_rounded, t.tagadaToneFirm),
        _toneTile(
            ctx, 'thanks', Icons.favorite_outline_rounded, t.tagadaToneThanks),
        const SizedBox(height: Gap.sm),
      ]),
    ),
  );
}

Widget _toneTile(
        BuildContext ctx, String key, IconData icon, String label) =>
    ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () => Navigator.pop(ctx, key),
    );

/// Show the WhatsApp / SMS share options the server built for a single tagada.
Future<void> _showTagadaShare(BuildContext context, Map<String, dynamic> party,
    Map<String, dynamic> result) {
  final t = AppLocalizations.of(context);
  final message = pair(context, result['message']);
  final share = (result['share'] ?? const {}) as Map;
  final wa = (share['whatsapp'] ?? const {}) as Map;
  final sms = (share['sms'] ?? const {}) as Map;
  final smsAvailable = sms['available'] == true;
  final phone = (party['phone'] ?? '').toString();

  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child:
                Text(t.tagadaTitle, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          const SizedBox(height: Gap.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Text(message),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.chat_rounded),
              label: Text(t.tagadaShareWhatsApp),
              onPressed: () {
                Navigator.pop(ctx);
                final url = (wa['url'] ?? '').toString();
                if (url.isNotEmpty) {
                  launchUrl(Uri.parse(url),
                      mode: LaunchMode.externalApplication);
                } else {
                  // Fallback: build a wa.me link from the party phone.
                  final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
                  final waUrl = digits.isEmpty
                      ? 'https://wa.me/?text=${Uri.encodeComponent(message)}'
                      : 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
                  launchUrl(Uri.parse(waUrl),
                      mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.sms_rounded),
              label: Text(smsAvailable
                  ? t.tagadaShareSms
                  : t.tagadaSmsUnavailable),
              onPressed: smsAvailable
                  ? () {
                      Navigator.pop(ctx);
                      final uri = Uri(
                          scheme: 'sms',
                          path: phone,
                          queryParameters: {'body': message});
                      launchUrl(uri);
                    }
                  : null,
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextButton.icon(
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(t.stmtShareStatement),
            onPressed: () {
              Navigator.pop(ctx);
              Share.share(message);
            },
          ),
        ]),
      ),
    ),
  );
}

/// Gallery/preview access to the private entry sheet (screenshot harness).
@visibleForTesting
Widget khataEntrySheetPreview(Map<String, dynamic> business,
        {int partyId = 1, String book = 'customer', bool isDue = true}) =>
    _EntrySheet(business: business, partyId: partyId, book: book, isDue: isDue);
