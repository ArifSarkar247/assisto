import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/skeleton.dart';
import '../business_common.dart' show pair, rememberedBusinessId;
import 'acct_audit_screen.dart';
import 'acct_close_screen.dart';
import 'acct_common.dart';
import 'acct_entry_screen.dart';
import 'acct_opening_screen.dart';
import 'acct_reports_screen.dart';

/// acctui — the accounting home (route 'acct', flag `accounting_v2`, owner
/// only). Big plain-word buttons for what happened today, entries waiting
/// offline, the recent entries (cancel = reversal, never a delete), and the
/// way to reports, month close, audit trail, opening balances and the
/// accountant export.
class AcctHomeScreen extends StatefulWidget {
  final int? businessId;
  const AcctHomeScreen({super.key, this.businessId});

  @override
  State<AcctHomeScreen> createState() => _AcctHomeScreenState();
}

class _AcctHomeScreenState extends State<AcctHomeScreen> with WidgetsBindingObserver {
  int? _biz;
  bool _loading = true;
  Object? _error;
  List<Map<String, dynamic>> _entries = const [];
  List<Map<String, dynamic>> _queue = const [];
  bool _openingSet = true;
  bool _sending = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _flushThenLoad();
  }

  Future<void> _init() async {
    _biz = widget.businessId ?? await rememberedBusinessId();
    await _flushThenLoad();
  }

  Future<void> _flushThenLoad() async {
    if (!mounted) return;
    await AcctQueue.flush(_api);
    await _load();
  }

  Future<void> _load() async {
    final q = await AcctQueue.load();
    if (!mounted) return;
    setState(() {
      _queue = q;
      _loading = _entries.isEmpty;
      _error = null;
    });
    try {
      final r = await _api.acctEntries(_biz);
      final op = await _api.acctOpening(_biz);
      if (!mounted) return;
      setState(() {
        _entries = ((r['entries'] as List?) ?? const [])
            .cast<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        _openingSet = op['set'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _sendNow() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    final n = await AcctQueue.flush(_api);
    if (!mounted) return;
    setState(() => _sending = false);
    messenger.showSnackBar(SnackBar(
        content: Text(n > 0 ? t.acuQueueSent(acctDigits(context, n)) : t.acuQueueStillOffline)));
    await _load();
  }

  Future<void> _open(Widget screen) async {
    final changed = await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted && changed == true) await _load();
  }

  Future<void> _newEntry(String kind) =>
      _open(AcctEntryScreen(businessId: _biz, kind: kind));

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.acuTitle),
        actions: [
          IconButton(
            tooltip: t.acuReports,
            icon: const Icon(Icons.insights_rounded),
            onPressed: () => _open(AcctReportsScreen(businessId: _biz)),
          ),
        ],
      ),
      floatingActionButton: _entries.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('acct-fab'),
              onPressed: () => _newEntry('sale'),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.acuNewEntry),
            ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    final e = _error;
    if (e != null && _entries.isEmpty) {
      final staff = e is ApiException && e.status == 403;
      return StateMessage(
        icon: staff ? Icons.lock_rounded : Icons.cloud_off_rounded,
        title: t.acuTitle,
        message: e is ApiException && staff ? e.message : honestFailText(t, e),
        action: staff
            ? null
            : Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
                FilledButton(onPressed: _load, child: Text(t.retry)),
                // offline: the entry screen still works (it queues)
                OutlinedButton(onPressed: () => _newEntry('sale'), child: Text(t.acuNewEntry)),
              ]),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _flushThenLoad,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 96)),
        children: [
          if (_queue.isNotEmpty) _queueCard(t, scheme),
          if (!_openingSet) _openingCard(t, scheme),
          Semantics(
            header: true,
            child: Text(t.acuWhatHappenedToday,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: Gap.md),
          _kindGrid(t, scheme),
          const SizedBox(height: Gap.xl),
          _toolsSection(t, scheme),
          const SizedBox(height: Gap.xl),
          Semantics(
            header: true,
            child: Text(t.acuRecent,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: Gap.sm),
          if (_entries.isEmpty) _empty(t, scheme) else ..._entries.map((e) => _entryTile(t, scheme, e)),
        ],
      ),
    );
  }

  Widget _kindGrid(AppLocalizations t, ColorScheme scheme) {
    const kinds = ['sale', 'purchase', 'expense', 'due', 'money_in', 'money_out'];
    return LayoutBuilder(builder: (context, c) {
      // two columns on a phone; one when the text is huge (200% font)
      final big = MediaQuery.textScalerOf(context).scale(14) > 22;
      final cols = big || c.maxWidth < 300 ? 1 : 2;
      final w = (c.maxWidth - Gap.sm * (cols - 1)) / cols;
      return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final k in kinds)
          SizedBox(
            width: w,
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.lg),
              child: InkWell(
                key: ValueKey('acct-home-$k'),
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: () => _newEntry(k),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 72),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Row(children: [
                      Icon(acctKindIcon(k), color: scheme.primary, size: 28),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(acctKindLabel(t, k),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        SizedBox(
          width: c.maxWidth,
          child: TextButton.icon(
            key: const ValueKey('acct-home-transfer'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _newEntry('transfer'),
            icon: Icon(acctKindIcon('transfer')),
            label: Text(t.acuKindTransferLong),
          ),
        ),
      ]);
    });
  }

  Widget _toolsSection(AppLocalizations t, ColorScheme scheme) {
    Widget tile(IconData icon, String title, String sub, VoidCallback on, String key) => Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            key: ValueKey(key),
            minVerticalPadding: Gap.sm,
            leading: Icon(icon, color: scheme.primary),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: on,
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        header: true,
        child: Text(t.acuToolsHeading,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      ),
      const SizedBox(height: Gap.sm),
      tile(Icons.insights_rounded, t.acuReports, t.acuReportsSub,
          () => _open(AcctReportsScreen(businessId: _biz)), 'acct-tool-reports'),
      tile(Icons.ios_share_rounded, t.acuExport, t.acuExportSub,
          () => _open(AcctReportsScreen(businessId: _biz, openExport: true)), 'acct-tool-export'),
      tile(Icons.lock_clock_rounded, t.acuClose, t.acuCloseSub,
          () => _open(AcctCloseScreen(businessId: _biz)), 'acct-tool-close'),
      tile(Icons.fact_check_rounded, t.acuAudit, t.acuAuditSub,
          () => _open(AcctAuditScreen(businessId: _biz)), 'acct-tool-audit'),
      tile(Icons.flag_rounded, t.acuOpening, t.acuOpeningSub,
          () => _open(AcctOpeningScreen(businessId: _biz)), 'acct-tool-opening'),
    ]);
  }

  Widget _queueCard(AppLocalizations t, ColorScheme scheme) {
    final failed = _queue.where((r) => r['failed'] != null).toList();
    final waiting = _queue.length - failed.length;
    return Card(
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: Gap.lg),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.cloud_upload_rounded, color: scheme.onTertiaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.acuQueueWaiting(acctDigits(context, waiting)),
                  style: TextStyle(
                      color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700)),
            ),
          ]),
          if (waiting > 0) ...[
            const SizedBox(height: Gap.sm),
            FilledButton.tonal(
              onPressed: _sending ? null : _sendNow,
              child: Text(t.acuQueueSendNow),
            ),
          ],
          for (final f in failed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  '${acctKindLabel(t, '${(f['entry'] as Map)['kind']}')} · '
                  '${acctMoney(context, (f['entry'] as Map)['amount'])}',
                  style: TextStyle(color: scheme.onTertiaryContainer)),
              subtitle: Text(pair(context, f['failed']),
                  style: TextStyle(color: scheme.onTertiaryContainer)),
              trailing: TextButton(
                onPressed: () async {
                  await AcctQueue.remove('${(f['entry'] as Map)['client_id']}');
                  await _load();
                },
                child: Text(t.acuQueueDiscard),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _openingCard(AppLocalizations t, ColorScheme scheme) => Card(
        margin: const EdgeInsets.only(bottom: Gap.lg),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.acuOpeningCardTitle,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: Gap.xs),
            Text(t.acuOpeningCardBody, style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.sm),
            FilledButton(
              key: const ValueKey('acct-opening-start'),
              onPressed: () => _open(AcctOpeningScreen(businessId: _biz)),
              child: Text(t.acuOpeningStart),
            ),
          ]),
        ),
      );

  /// Empty state: benefit + big button + how-to.
  Widget _empty(AppLocalizations t, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(Icons.auto_stories_rounded, size: 48, color: scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(t.acuEmptyTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.acuEmptyBody,
              textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const ValueKey('acct-empty-cta'),
              onPressed: () => _newEntry('sale'),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.acuEmptyCta),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(t.acuEmptyHowTo, style: TextStyle(height: 1.5, color: scheme.onSurfaceVariant)),
        ]),
      );

  String _entryTitle(AppLocalizations t, Map<String, dynamic> e) {
    final k = '${e['kind']}';
    final extra = k == 'expense'
        ? acctExpenseLabel(t, '${e['category']}')
        : (k == 'money_in' || k == 'money_out')
            ? acctPurposeLabel(t, k, '${e['purpose']}')
            : '';
    final who = '${e['party_name'] ?? ''}';
    return [acctKindLabel(t, k), if (extra.isNotEmpty) extra, if (who.isNotEmpty) who].join(' · ');
  }

  String _entryAccount(AppLocalizations t, Map<String, dynamic> e) {
    if (e['kind'] == 'transfer') {
      return '${acctAccountLabel(t, '${e['account']}')} → ${acctAccountLabel(t, '${e['to_account']}')}';
    }
    if (e['account'] != null) return acctAccountLabel(t, '${e['account']}');
    return t.acuAccDue;
  }

  Widget _entryTile(AppLocalizations t, ColorScheme scheme, Map<String, dynamic> e) {
    final voided = e['void'] != null;
    final style = TextStyle(
        decoration: voided ? TextDecoration.lineThrough : null,
        color: voided ? scheme.onSurfaceVariant : null);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: Gap.sm,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(acctKindIcon('${e['kind']}'), color: scheme.onPrimaryContainer, size: 20),
      ),
      title: Text(_entryTitle(t, e), style: style.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(
          [
            acctDay(context, e['date']),
            _entryAccount(t, e),
            if (voided) t.acuVoided,
          ].join(' · '),
          style: style),
      trailing: Text(acctMoney(context, e['amount']),
          style: style.copyWith(fontWeight: FontWeight.w700)),
      onTap: () => _details(t, e),
    );
  }

  Future<void> _details(AppLocalizations t, Map<String, dynamic> e) async {
    final voided = e['void'] != null;
    final reason = TextEditingController();
    final go = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_entryTitle(t, e), style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(acctMoney(ctx, e['amount']),
                style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Text('${acctDay(ctx, e['date'])} · ${_entryAccount(t, e)}'),
            if ('${e['note'] ?? ''}'.isNotEmpty) Text('${e['note']}'),
            if ('${e['by_name'] ?? ''}'.isNotEmpty) Text(t.acuEnteredBy('${e['by_name']}')),
            if ((e['vat'] as num? ?? 0) > 0) Text(t.acuVatLine(acctMoney(ctx, e['vat']))),
            const SizedBox(height: Gap.lg),
            if (voided)
              Text(t.acuVoidedNote, style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant))
            else ...[
              Text(t.acuVoidExplain, style: const TextStyle(height: 1.4)),
              const SizedBox(height: Gap.sm),
              TextField(
                controller: reason,
                maxLength: 160,
                decoration: InputDecoration(
                    labelText: t.acuVoidReason, border: const OutlineInputBorder()),
              ),
              SizedBox(
                height: 52,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('acct-void-confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.undo_rounded),
                  label: Text(t.acuVoidButton),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
    // not disposed here: the sheet may still be animating out with it
    final why = reason.text.trim();
    if (go != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _api.acctVoidEntry(_biz, '${e['client_id']}', why);
      final ok = (r['_status'] as int? ?? 0) == 200;
      messenger.showSnackBar(SnackBar(
          content: Text(ok ? t.acuVoidDone : pair(context, r['detail'], fallback: t.acuSaveFailed))));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(honestFailText(t, err))));
    }
    await _load();
  }
}
