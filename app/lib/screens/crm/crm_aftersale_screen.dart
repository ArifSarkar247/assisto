import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_aftersale_api.dart';
import '../../widgets/crm_aftersale_widgets.dart';
import 'crm_common.dart';
import '../../widgets/num_input.dart'; // savesweep

/// AFTER-SALE hub (CRM_SPEC §7): four tabs — Collections, AMC/Renewals,
/// Complaints, Upsell. All money is integer POISHA from the server (no float).
/// No amount is invented in the app; everything is rendered exactly as returned.
/// Poisha → "৳1,500.50" with Bangla digits in bn (the shared formatter is
/// Latin-only).
String _tk(BuildContext context, num? poisha) =>
    localDigits(bdtFromPoisha(poisha), Localizations.localeOf(context).languageCode);

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
          // scrollable tabs size to their label: nothing cut at any font size
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(child: Text(t.crmCollections, softWrap: false)),
              Tab(child: Text(t.crmAmcRenewals, softWrap: false)),
              Tab(child: Text(t.crmComplaints, softWrap: false)),
              Tab(child: Text(t.crmUpsell, softWrap: false)),
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
          scrollable: true, // insets: 200% text / keyboard
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
    final taka = parseNumInput(amtCtl.text.trim()) ?? 0;
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
        // what is still to collect = the soft hero (big number first)
        DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.crmOutstanding,
                  style: AType.titleSmall.copyWith(color: Theme.of(context).colorScheme.ds.muted)),
              DsNumber(_tk(context, outstanding),
                  color: overdue > 0 ? Theme.of(context).colorScheme.ds.dangerInk : null),
              const SizedBox(height: Gap.sm),
              CrmProgressBar(
                booked > 0 ? collected / booked : 0,
                t.crmCollectedOfBooked(
                    _tk(context, collected), _tk(context, booked)),
              ),
              const SizedBox(height: Gap.sm),
              if (overdue > 0)
                CrmMoneyRow(t.crmOverdue, _tk(context, overdue),
                    bold: true, valueColor: Theme.of(context).colorScheme.error),
            ]),
        ),
        const SizedBox(height: Gap.sm),
        CrmSectionHeader(t.crmInstallments, icon: Icons.receipt_long_rounded),
        for (final inst in _installments)
          Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: _instCard(t, inst)),
      ]),
    );
  }

  Widget _instCard(AppLocalizations t, Map<String, dynamic> inst) {
    final status = (inst['status'] ?? 'scheduled').toString();
    final due = (inst['amount_poisha'] as num?) ?? 0;
    final collected = (inst['collected_poisha'] as num?) ?? 0;
    final done = status == 'collected' || status == 'overpaid';
    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(localDigits('${t.crmInstallment} #${inst['seq']}',
                    Localizations.localeOf(context).languageCode),
                    style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w800))),
            CrmStatusPill(_statusLabel(t, status),
                tone: done
                    ? CrmStatusTone.success
                    : status == 'partial'
                        ? CrmStatusTone.warning
                        : CrmStatusTone.neutral),
          ]),
          CrmMoneyRow(t.crmBooked, _tk(context, due)),
          CrmMoneyRow(t.crmCollected, _tk(context, collected)),
          if (!done) ...[
            const SizedBox(height: Gap.xs),
            Align(
              alignment: Alignment.centerRight,
              child: DsButton.secondary(
                  onPressed: () => _collect(t, inst),
                  icon: Icons.add_card_rounded,
                  label: t.crmRecordCollection),
            ),
          ],
        ]),
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
        for (final amc in _amcs)
          Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: _amcCard(t, amc)),
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
    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text((amc['company'] ?? amc['title'] ?? '').toString(),
                    style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w800))),
            CrmStatusPill(_stateLabel(t, state), tone: tone),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            daysTo == null
                ? ''
                : (daysTo as num) >= 0
                    ? t.crmRenewalInDays(localDigits(daysTo.toString(), Localizations.localeOf(context).languageCode))
                    : t.crmRenewalOverdueDays(localDigits((-daysTo).toString(), Localizations.localeOf(context).languageCode)),
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.ds.muted),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            // renewing is the main action when one is due: it goes first
            if (state != 'active')
              DsButton.secondary(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .renewAmc((amc['id'] as num).toInt(), 365)),
                  icon: Icons.autorenew_rounded,
                  label: t.crmRenew),
            DsButton.secondary(
                onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                    .scheduleReminder((amc['id'] as num).toInt())),
                icon: Icons.notifications_active_rounded,
                label: t.crmScheduleReminder),
          ]),
        ]),
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
          scrollable: true, // insets: 200% text / keyboard
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
                          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                          children: [
                            for (final c in _complaints)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: Gap.sm),
                                  child: _complaintCard(t, c))
                          ]),
                    ),
    );
  }

  Widget _complaintCard(AppLocalizations t, Map<String, dynamic> c) {
    final state = (c['state'] ?? 'open').toString();
    final breached = c['sla_breached'] == true;
    final actions = _nextActions(state);
    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text((c['subject'] ?? '').toString(),
                    style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w800))),
            CrmStatusPill(_stateLabel(t, state), tone: _stateTone(state)),
          ]),
          if ((c['details'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(c['details'].toString(),
                style: AType.bodyMedium.copyWith(
                    color: Theme.of(context).colorScheme.ds.muted)),
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
        DsGroup(margin: EdgeInsets.zero, children: [
          for (final s in signals) _signalCard(t, Map<String, dynamic>.from(s)),
        ]),
        NeedsKeyBanner(t.crmUpsellNoPriceNote, icon: Icons.info_outline_rounded),
      ]),
    );
  }

  Widget _signalCard(AppLocalizations t, Map<String, dynamic> s) {
    final kind = (s['kind'] ?? '').toString();
    final isRenewal = kind == 'amc_renewal';
    final ds = Theme.of(context).colorScheme.ds;
    return DsListRow(
      leading: DsAvatar(
          size: 40,
          child: Icon(isRenewal ? Icons.autorenew_rounded : Icons.add_business_rounded,
              size: 20, color: ds.primaryInk)),
      title: isRenewal
          ? t.crmUpsellRenewal
          : t.crmUpsellModule((s['module'] ?? '').toString()),
      subtitle: isRenewal ? t.crmUpsellRenewalHint : t.crmUpsellModuleHint,
    );
  }
}
