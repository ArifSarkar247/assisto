import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_aftersale_api.dart';
import '../../widgets/crm_aftersale_widgets.dart';
import 'crm_common.dart';

/// AFTER-SALE hub (CRM_SPEC §7): four tabs — Collections, AMC/Renewals,
/// Complaints, Upsell. All money is integer POISHA from the server (no float).
/// No amount is invented in the app; everything is rendered exactly as returned.
class CrmAfterSaleScreen extends StatelessWidget {
  final int org;
  const CrmAfterSaleScreen({super.key, required this.org});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.crmAfterSale),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(child: Text(t.crmCollections, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
              Tab(child: Text(t.crmAmcRenewals, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
              Tab(child: Text(t.crmComplaints, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
              Tab(child: Text(t.crmUpsell, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
        body: TabBarView(children: [
          CrmCollectionsTab(org: org),
          CrmAmcTab(org: org),
          CrmComplaintsTab(org: org),
          CrmUpsellTab(org: org),
        ]),
      ),
    );
  }
}

// =====================================================================
// COLLECTIONS — installment / collection tracking (cash/cheque/bank)
// =====================================================================
class CrmCollectionsTab extends StatefulWidget {
  final int org;
  const CrmCollectionsTab({super.key, required this.org});
  @override
  State<CrmCollectionsTab> createState() => _CrmCollectionsTabState();
}

class _CrmCollectionsTabState extends State<CrmCollectionsTab> {
  List<Map<String, dynamic>> _installments = [];
  Map<String, dynamic> _summary = {};
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmAfterSaleApi.of(context);
      _installments = await api.installments(widget.org);
      _summary = await api.collectionSummary(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _collect(AppLocalizations t, Map<String, dynamic> inst) async {
    final due = (inst['amount_poisha'] as num?)?.toInt() ?? 0;
    final collected = (inst['collected_poisha'] as num?)?.toInt() ?? 0;
    final remaining = (due - collected).clamp(0, due);
    final amtCtl =
        TextEditingController(text: (remaining / 100).toStringAsFixed(2));
    String method = 'cash';
    final refCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t.crmRecordCollection),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amtCtl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t.crmAmountBdt, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.sm),
            DropdownButtonFormField<String>(
              initialValue: method,
              decoration: InputDecoration(
                  labelText: t.crmPaymentMethod,
                  border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: 'cash', child: Text(t.crmMethodCash)),
                DropdownMenuItem(value: 'cheque', child: Text(t.crmMethodCheque)),
                DropdownMenuItem(value: 'bank', child: Text(t.crmMethodBank)),
              ],
              onChanged: (v) => setD(() => method = v ?? 'cash'),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: refCtl,
              decoration: InputDecoration(
                  labelText: t.crmPaymentReference,
                  border: const OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final taka = double.tryParse(amtCtl.text.trim()) ?? 0;
    final poisha = (taka * 100).round();
    try {
      await CrmAfterSaleApi.of(context).recordCollection(
          (inst['id'] as num).toInt(), poisha, method,
          reference: refCtl.text.trim());
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_installments.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.payments_rounded,
          title: t.crmNoCollections,
          message: t.crmNoCollectionsHint);
    }
    final booked = (_summary['booked_poisha'] as num?)?.toDouble() ?? 0;
    final collected = (_summary['collected_poisha'] as num?)?.toDouble() ?? 0;
    final outstanding = (_summary['outstanding_poisha'] as num?) ?? 0;
    final overdue = (_summary['overdue_poisha'] as num?) ?? 0;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(children: [
              CrmProgressBar(
                booked > 0 ? collected / booked : 0,
                t.crmCollectedOfBooked(
                    bdtFromPoisha(collected), bdtFromPoisha(booked)),
              ),
              const SizedBox(height: Gap.sm),
              CrmMoneyRow(t.crmOutstanding, bdtFromPoisha(outstanding),
                  valueColor: outstanding > 0 ? AssistoTokens.of(context).warning : null),
              if (overdue > 0)
                CrmMoneyRow(t.crmOverdue, bdtFromPoisha(overdue),
                    bold: true, valueColor: Theme.of(context).colorScheme.error),
            ]),
          ),
        ),
        const SizedBox(height: Gap.sm),
        CrmSectionHeader(t.crmInstallments, icon: Icons.receipt_long_rounded),
        for (final inst in _installments) _instCard(t, inst),
      ]),
    );
  }

  Widget _instCard(AppLocalizations t, Map<String, dynamic> inst) {
    final status = (inst['status'] ?? 'scheduled').toString();
    final due = (inst['amount_poisha'] as num?) ?? 0;
    final collected = (inst['collected_poisha'] as num?) ?? 0;
    final done = status == 'collected' || status == 'overpaid';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${t.crmInstallment} #${inst['seq']}',
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            CrmStatusPill(_statusLabel(t, status),
                tone: done
                    ? CrmStatusTone.success
                    : status == 'partial'
                        ? CrmStatusTone.warning
                        : CrmStatusTone.neutral),
          ]),
          CrmMoneyRow(t.crmBooked, bdtFromPoisha(due)),
          CrmMoneyRow(t.crmCollected, bdtFromPoisha(collected)),
          if (!done) ...[
            const SizedBox(height: Gap.xs),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                  onPressed: () => _collect(t, inst),
                  icon: const Icon(Icons.add_card_rounded, size: 18),
                  label: Text(t.crmRecordCollection)),
            ),
          ],
        ]),
      ),
    );
  }

  String _statusLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'collected':
        return t.crmCollected;
      case 'overpaid':
        return t.crmOverpaid;
      case 'partial':
        return t.crmPartial;
      default:
        return t.crmScheduled;
    }
  }
}

// =====================================================================
// AMC / RENEWALS
// =====================================================================
class CrmAmcTab extends StatefulWidget {
  final int org;
  const CrmAmcTab({super.key, required this.org});
  @override
  State<CrmAmcTab> createState() => _CrmAmcTabState();
}

class _CrmAmcTabState extends State<CrmAmcTab> {
  List<Map<String, dynamic>> _amcs = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _amcs = await CrmAfterSaleApi.of(context).amcs(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_amcs.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.event_repeat_rounded,
          title: t.crmNoAmc,
          message: t.crmNoAmcHint);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        for (final amc in _amcs) _amcCard(t, amc),
      ]),
    );
  }

  Widget _amcCard(AppLocalizations t, Map<String, dynamic> amc) {
    final state = (amc['state'] ?? 'active').toString();
    final daysTo = amc['days_to_renewal'];
    final tone = state == 'overdue'
        ? CrmStatusTone.danger
        : (state == 'due_soon' || state == 'due_today')
            ? CrmStatusTone.warning
            : CrmStatusTone.success;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text((amc['company'] ?? amc['title'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            CrmStatusPill(_stateLabel(t, state), tone: tone),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            daysTo == null
                ? ''
                : (daysTo as num) >= 0
                    ? t.crmRenewalInDays(daysTo.toString())
                    : t.crmRenewalOverdueDays((-daysTo).toString()),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.xs, children: [
            OutlinedButton.icon(
                onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                    .scheduleReminder((amc['id'] as num).toInt())),
                icon: const Icon(Icons.notifications_active_rounded, size: 18),
                label: Text(t.crmScheduleReminder)),
            if (state != 'active')
              FilledButton.tonalIcon(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .renewAmc((amc['id'] as num).toInt(), 365)),
                  icon: const Icon(Icons.autorenew_rounded, size: 18),
                  label: Text(t.crmRenew)),
          ]),
        ]),
      ),
    );
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() op) async {
    try {
      await op();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).crmDone)));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  String _stateLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'overdue':
        return t.crmRenewalOverdue;
      case 'due_today':
        return t.crmRenewalDueToday;
      case 'due_soon':
        return t.crmRenewalDueSoon;
      default:
        return t.crmRenewalActive;
    }
  }
}

// =====================================================================
// COMPLAINTS
// =====================================================================
class CrmComplaintsTab extends StatefulWidget {
  final int org;
  const CrmComplaintsTab({super.key, required this.org});
  @override
  State<CrmComplaintsTab> createState() => _CrmComplaintsTabState();
}

class _CrmComplaintsTabState extends State<CrmComplaintsTab> {
  List<Map<String, dynamic>> _complaints = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _complaints = await CrmAfterSaleApi.of(context).complaints(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _newComplaint(AppLocalizations t) async {
    final subjectCtl = TextEditingController();
    final bodyCtl = TextEditingController();
    String priority = 'normal';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t.crmNewComplaint),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: subjectCtl,
                decoration: InputDecoration(
                    labelText: t.crmComplaintSubject,
                    border: const OutlineInputBorder())),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: bodyCtl,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: t.crmComplaintDetails,
                    border: const OutlineInputBorder())),
            const SizedBox(height: Gap.sm),
            DropdownButtonFormField<String>(
              initialValue: priority,
              decoration: InputDecoration(
                  labelText: t.crmPriority, border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: 'urgent', child: Text(t.crmPriorityUrgent)),
                DropdownMenuItem(value: 'high', child: Text(t.crmPriorityHigh)),
                DropdownMenuItem(value: 'normal', child: Text(t.crmPriorityNormal)),
                DropdownMenuItem(value: 'low', child: Text(t.crmPriorityLow)),
              ],
              onChanged: (v) => setD(() => priority = v ?? 'normal'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await CrmAfterSaleApi.of(context).createComplaint({
        'org': widget.org,
        'subject': subjectCtl.text.trim(),
        'details': bodyCtl.text.trim(),
        'priority': priority,
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newComplaint(t),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.crmNewComplaint),
      ),
      body: _loading
          ? const CrmStateView.loading()
          : _error != null
              ? CrmStateView.error(
                  error: _error!, title: t.loadFailed, onRetry: _load)
              : _complaints.isEmpty
                  ? CrmStateView.empty(
                      icon: Icons.support_agent_rounded,
                      title: t.crmNoComplaints,
                      message: t.crmNoComplaintsHint)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                          padding: const EdgeInsets.all(Gap.md),
                          children: [
                            for (final c in _complaints) _complaintCard(t, c)
                          ]),
                    ),
    );
  }

  Widget _complaintCard(AppLocalizations t, Map<String, dynamic> c) {
    final state = (c['state'] ?? 'open').toString();
    final breached = c['sla_breached'] == true;
    final actions = _nextActions(state);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text((c['subject'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            CrmStatusPill(_stateLabel(t, state), tone: _stateTone(state)),
          ]),
          if ((c['details'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(c['details'].toString(),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          if (breached)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(children: [
                Icon(Icons.timer_off_rounded,
                    size: 16, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: Gap.xs),
                Text(t.crmSlaBreached,
                    style: AType.labelMedium.copyWith(color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.xs, children: [
              for (final act in actions)
                OutlinedButton(
                    onPressed: () => _transition(t, c, act),
                    child: Text(_actionLabel(t, act))),
            ]),
          ],
        ]),
      ),
    );
  }

  List<String> _nextActions(String state) {
    switch (state) {
      case 'open':
        return ['acknowledge', 'resolve', 'cancel'];
      case 'acknowledged':
        return ['start', 'resolve', 'cancel'];
      case 'in_progress':
        return ['resolve', 'cancel'];
      case 'resolved':
        return ['close', 'reopen'];
      default:
        return [];
    }
  }

  Future<void> _transition(
      AppLocalizations t, Map<String, dynamic> c, String action) async {
    try {
      await CrmAfterSaleApi.of(context)
          .complaintTransition((c['id'] as num).toInt(), action);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  String _actionLabel(AppLocalizations t, String a) {
    switch (a) {
      case 'acknowledge':
        return t.crmActAcknowledge;
      case 'start':
        return t.crmActStart;
      case 'resolve':
        return t.crmActResolve;
      case 'close':
        return t.crmActClose;
      case 'reopen':
        return t.crmActReopen;
      case 'cancel':
        return t.crmActCancel;
      default:
        return a;
    }
  }

  String _stateLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'acknowledged':
        return t.crmComplaintAck;
      case 'in_progress':
        return t.crmComplaintInProgress;
      case 'resolved':
        return t.crmComplaintResolved;
      case 'closed':
        return t.crmComplaintClosed;
      case 'cancelled':
        return t.crmComplaintCancelled;
      default:
        return t.crmComplaintOpen;
    }
  }

  CrmStatusTone _stateTone(String s) {
    switch (s) {
      case 'resolved':
      case 'closed':
        return CrmStatusTone.success;
      case 'in_progress':
      case 'acknowledged':
        return CrmStatusTone.info;
      case 'cancelled':
        return CrmStatusTone.neutral;
      default:
        return CrmStatusTone.warning;
    }
  }
}

// =====================================================================
// UPSELL
// =====================================================================
class CrmUpsellTab extends StatefulWidget {
  final int org;
  const CrmUpsellTab({super.key, required this.org});
  @override
  State<CrmUpsellTab> createState() => _CrmUpsellTabState();
}

class _CrmUpsellTabState extends State<CrmUpsellTab> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await CrmAfterSaleApi.of(context).upsell(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final signals = (_data['signals'] as List?) ?? [];
    final suppressed = _data['suppressed'] == true;
    if (suppressed) {
      return CrmStateView.empty(
          icon: Icons.pause_circle_outline_rounded,
          title: t.crmUpsellSuppressed,
          message: t.crmUpsellSuppressedHint);
    }
    if (signals.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.trending_up_rounded,
          title: t.crmNoUpsell,
          message: t.crmNoUpsellHint);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        // Honest note: upsell signals only — the owner sets any price elsewhere.
        NeedsKeyBanner(t.crmUpsellNoPriceNote, icon: Icons.info_outline_rounded),
        for (final s in signals) _signalCard(t, Map<String, dynamic>.from(s)),
      ]),
    );
  }

  Widget _signalCard(AppLocalizations t, Map<String, dynamic> s) {
    final kind = (s['kind'] ?? '').toString();
    final isRenewal = kind == 'amc_renewal';
    return Card(
      child: ListTile(
        leading: Icon(
            isRenewal ? Icons.autorenew_rounded : Icons.add_business_rounded,
            color: Theme.of(context).colorScheme.primary),
        title: Text(isRenewal
            ? t.crmUpsellRenewal
            : t.crmUpsellModule((s['module'] ?? '').toString())),
        subtitle: Text(isRenewal ? t.crmUpsellRenewalHint : t.crmUpsellModuleHint),
      ),
    );
  }
}
