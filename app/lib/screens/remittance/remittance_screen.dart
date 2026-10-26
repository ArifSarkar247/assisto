import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/voice_input.dart';
import 'remit_entry_screen.dart';
import 'remit_parser.dart';
import 'remit_report_screen.dart';
import 'remit_sheets.dart';
import 'remit_source.dart';
import 'remit_widgets.dart';

/// BUDGET & REMITTANCE (flag `budget_remittance`, default OFF) — for a
/// family in Bangladesh that RECEIVES money from a relative abroad.
///
///  * Month: what came this month (typed, spoken — speech becomes text on the
///    phone — or the full form), the expected-money check, entries made
///    offline waiting to sync.
///  * Budget: the family plan per category (the EXISTING Budget rows) versus
///    the actual spending (the EXISTING Money expenses), the savings goal,
///    and bills paid from the money (monthly reminders in normal Reminders).
///  * Year: total received, by month / sender / channel, savings built.
///  * Report for the sender — shared ONLY when the user taps Share.
///
/// Privacy: on our server only, financial values encrypted at rest; export
/// (CSV / text) and delete-all from the menu. No ads on these screens.
class RemittanceScreen extends StatefulWidget {
  final RemitSource? source;
  final bool? guide;
  final int initialTab;
  final DateTime? now;
  const RemittanceScreen({super.key, this.source, this.guide, this.initialTab = 0, this.now});

  @override
  State<RemittanceScreen> createState() => _RemittanceScreenState();
}

const kRmGuideSeen = 'remit_guide_seen_v1';

class _RemittanceScreenState extends State<RemittanceScreen> with SingleTickerProviderStateMixin {
  late final RemitSource _src =
      widget.source ?? ApiRemitSource(context.read<AppState>().api, app: context.read<AppState>());
  late final RemitQueue _queue = RemitQueue(_src);
  late final DateTime _now = widget.now ?? DateTime.now();
  late final TabController _tabs = TabController(length: 3, vsync: this, initialIndex: widget.initialTab)
    ..addListener(_onTab);
  late String _month = rmMonthKey(_now);
  late int _year = _now.year;

  bool _loading = true;
  Object? _err;
  Map<String, dynamic> _card = const {};
  bool _showGuide = false;

  Map<String, dynamic>? _yearData;
  Object? _yearErr;
  bool _yearLoading = false;

  final _quick = TextEditingController();
  bool _quickEmpty = false;
  late final VoiceDictation _voice = VoiceDictation();
  List<Map<String, dynamic>>? _members;

  @override
  void initState() {
    super.initState();
    _start();
    if (widget.initialTab == 2) _loadYear();
  }

  void _onTab() {
    if (_tabs.index == 2 && _yearData == null && !_yearLoading && _yearErr == null) _loadYear();
  }

  Future<void> _start() async {
    await _queue.load();
    if (widget.guide != null) {
      _showGuide = widget.guide!;
    } else {
      try {
        _showGuide = (await _src.getPref(kRmGuideSeen)) != '1';
      } catch (_) {}
    }
    await _sync(quiet: true);
    await _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _quick.dispose();
    _voice.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ data
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _card = await _src.overview(_month);
      if (widget.guide == null && _card['guide_done'] == true) _showGuide = false;
      unawaited(_expectedCheck());
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadYear() async {
    setState(() {
      _yearLoading = true;
      _yearErr = null;
    });
    try {
      _yearData = await _src.year(_year);
    } catch (e) {
      _yearErr = e;
    }
    if (mounted) setState(() => _yearLoading = false);
  }

  Future<void> _sync({bool quiet = false}) async {
    if (_queue.items.isEmpty) return;
    final r = await _queue.flush();
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    if (r.sent > 0 && !quiet) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.rmtSynced(rmDigits(rmLang(context), r.sent)))));
    }
    if (r.refused.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.rmtSyncRefused(rmDigits(rmLang(context), r.refused.length)))));
    }
    if (r.sent > 0 && quiet == false) await _load();
    if (mounted) setState(() {});
  }

  /// The once-a-month "expected money has not arrived" reminder: a local
  /// notification for the day after the expected day while waiting, cancelled
  /// once money arrives; the server says when it is due now (once a month).
  Future<void> _expectedCheck() async {
    if (_month != rmMonthKey(_now)) return;
    final t = AppLocalizations.of(context);
    final exp = rmMap(_card['expected']);
    final status = '${exp['status'] ?? 'none'}';
    final key = 'remit-missing-$_month';
    final title = t.rmtMissingNoteTitle;
    final body = t.rmtMissingNoteBody(rmTaka(context, exp['taka']));
    try {
      if (status == 'waiting') {
        final due = DateTime.tryParse('${exp['due_date'] ?? ''}');
        if (due != null) {
          await _src.scheduleNote(key, title, body, DateTime(due.year, due.month, due.day + 1, 10));
          await _src.setPref('remit_alert_$_month', '1');
        }
      } else if (status == 'arrived' || status == 'partial' || status == 'none') {
        await _src.cancelNote(key);
      } else if (status == 'missing' && exp['alert_now'] == true) {
        if (await _src.getPref('remit_alert_$_month') != '1') {
          await _src.showNote(key, title, body);
          await _src.setPref('remit_alert_$_month', '1');
        }
      }
    } catch (_) {}
  }

  Future<void> _closeGuide() async {
    setState(() => _showGuide = false);
    try {
      await _src.setPref(kRmGuideSeen, '1');
      await _src.saveSettings({'guide_done': true});
    } catch (_) {}
  }

  void _shiftMonth(int delta) {
    final d = DateTime.parse('$_month-01');
    final n = DateTime(d.year, d.month + delta);
    if (n.isAfter(DateTime(_now.year, _now.month))) return;
    _month = rmMonthKey(n);
    _load();
  }

  // ------------------------------------------------------------ actions
  Future<List<Map<String, dynamic>>> _circle() async {
    if (_members != null) return _members!;
    try {
      _members = await _src.members();
    } catch (_) {
      return const [];
    }
    return _members!;
  }

  Future<void> _openEntry({Map<String, dynamic>? entry, RemitDraft? draft, String? said}) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final r = await Navigator.of(context).push<RemitSaved>(
      MaterialPageRoute(
        builder: (_) =>
            RemitEntryScreen(source: _src, queue: _queue, entry: entry, draft: draft, said: said, members: _members),
      ),
    );
    if (r == null) return;
    if (r == RemitSaved.queued) {
      messenger.showSnackBar(SnackBar(content: Text(t.rmtSavedOffline)));
      setState(() {});
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(r == RemitSaved.deleted ? t.rmtDeleted : t.rmtSaved)));
    _quick.clear();
    await _load();
  }

  Future<void> _understand() async {
    final text = _quick.text.trim();
    if (text.isEmpty) {
      setState(() => _quickEmpty = true);
      return;
    }
    if (_quickEmpty) setState(() => _quickEmpty = false);
    await _voice.stop();
    final members = await _circle();
    if (!mounted) return;
    final d = RemitParser.parse(text, members: members, now: _now);
    await _openEntry(draft: d, said: text);
  }

  Future<void> _run(Future<void> Function() call, {String? ok, Map<String, dynamic>? queueBody, String? kind}) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await call();
      if (ok != null) messenger.showSnackBar(SnackBar(content: Text(ok)));
      await _load();
    } catch (e) {
      if (rmOffline(e) && queueBody != null && kind != null) {
        await _queue.add(kind, queueBody);
        messenger.showSnackBar(SnackBar(content: Text(t.rmtSavedOffline)));
        if (mounted) setState(() {});
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(rmOffline(e) ? t.rmtNeedsInternet : (rmError(e) ?? t.rmtErrorBody))),
      );
    }
  }

  Future<void> _editPlan() async {
    final cur = <String, double>{
      for (final l in rmList(rmMap(_card['plan'])['lines'])) '${l['key']}': rmNum(l['plan']),
    };
    final r = await showPlanSheet(context, cur);
    if (r == null || !mounted) return;
    await _run(() => _src.savePlan(r), ok: AppLocalizations.of(context).rmtSaved);
  }

  Future<void> _addSpend([String category = 'food']) async {
    final r = await showSpendSheet(context, category: category);
    if (r == null || !mounted) return;
    final body = {...r, 'client_id': rmClientId(), 'date': rmIsoDay(DateTime.now())};
    await _run(() => _src.spend(body), ok: AppLocalizations.of(context).rmtSaved, queueBody: body, kind: 'spend');
  }

  Future<void> _setGoal() async {
    final r = await showGoalSheet(context, goal: _card['goal'] is Map ? rmMap(_card['goal']) : null);
    if (r == null || !mounted) return;
    await _run(() => _src.saveGoal(r['title'] ?? '', r['target'] ?? ''), ok: AppLocalizations.of(context).rmtSaved);
  }

  Future<void> _addToGoal() async {
    final t = AppLocalizations.of(context);
    final a = await showAmountSheet(context, title: t.rmtGoalAddTitle, body: t.rmtGoalAddBody);
    if (a == null || !mounted) return;
    final body = {'client_id': rmClientId(), 'amount': a};
    await _run(() => _src.addToGoal('${body['client_id']}', a), ok: t.rmtSaved, queueBody: body, kind: 'goal');
  }

  Future<void> _addBill() async {
    final r = await showBillSheet(context);
    if (r == null || !mounted) return;
    await _run(() => _src.addBill(r), ok: AppLocalizations.of(context).rmtSaved);
  }

  Future<void> _editBill(Map<String, dynamic> b) async {
    final r = await showBillSheet(context, bill: b);
    if (r == null || !mounted) return;
    await _run(() => _src.updateBill(int.parse('${b['id']}'), r), ok: AppLocalizations.of(context).rmtSaved);
  }

  Future<void> _deleteBill(Map<String, dynamic> b) async {
    final t = AppLocalizations.of(context);
    if (!await rmConfirm(context, t.rmtBillDeleteTitle, t.rmtBillDeleteBody, t.delete)) return;
    await _run(() async {
      final r = await _src.deleteBill(int.parse('${b['id']}'));
      final lid = '${r['reminder_local_id'] ?? b['reminder_local_id'] ?? ''}';
      if (lid.isNotEmpty) await _src.removeReminder(lid);
    }, ok: t.rmtDeleted);
  }

  Future<void> _billPaid(Map<String, dynamic> b) async {
    final body = {'id': b['id'], 'month': _month, 'client_id': rmClientId()};
    await _run(
      () => _src.billPaid(int.parse('${b['id']}'), _month, '${body['client_id']}'),
      ok: AppLocalizations.of(context).rmtBillPaidDone,
      queueBody: body,
      kind: 'bill_paid',
    );
  }

  Future<void> _billRemind(Map<String, dynamic> b) async {
    final t = AppLocalizations.of(context);
    final day = int.tryParse('${b['due_day'] ?? 1}') ?? 1;
    final now = DateTime.now();
    var first = DateTime(now.year, now.month, day, 10);
    if (first.month != now.month) first = DateTime(now.year, now.month + 1, 0, 10); // short month
    if (!first.isAfter(now)) first = DateTime(now.year, now.month + 1, day, 10);
    await _run(() async {
      final lid = await _src.addMonthlyReminder(t.rmtBillReminderTitle('${b['name'] ?? ''}'), first);
      if (lid != null) await _src.updateBill(int.parse('${b['id']}'), {'reminder_local_id': lid});
    }, ok: t.rmtBillReminderSet(rmDay(context, rmIsoDay(first))));
  }

  Future<void> _editExpected() async {
    final r = await showExpectedSheet(context, rmMap(_card['expected']));
    if (r == null || !mounted) return;
    await _run(() => _src.saveSettings(r), ok: AppLocalizations.of(context).rmtSaved);
  }

  Future<void> _report() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemitReportScreen(source: _src, month: _month, initialLang: rmLang(context)),
      ),
    );
  }

  Future<void> _export(String fmt) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final d = await _src.export(fmt);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${d['filename'] ?? 'assisto-remittance.$fmt'}');
      await f.writeAsString('${d['text'] ?? ''}');
      await Share.shareXFiles([XFile(f.path)], text: t.rmtExportCaption);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(rmOffline(e) ? t.rmtNeedsInternet : (rmError(e) ?? t.rmtErrorBody))),
      );
    }
  }

  Future<void> _deleteAll() async {
    final t = AppLocalizations.of(context);
    if (!await rmConfirm(context, t.rmtDeleteAllTitle, t.rmtDeleteAllBody, t.rmtDeleteAllYes)) return;
    await _run(() async {
      await _src.deleteAll();
      await _queue.clear();
      _yearData = null;
    }, ok: t.rmtDeleteAllDone);
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bigText = MediaQuery.textScalerOf(context).scale(10) > 11.5;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.rmtTitle),
        actions: [
          IconButton(
            key: const ValueKey('rmt_report_btn'),
            tooltip: t.rmtReportTitle,
            icon: const Icon(Icons.summarize_outlined),
            onPressed: _err != null && rmStatus(_err!) == 403 ? null : _report,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('rmt_menu'),
            tooltip: t.rmtMenu,
            onSelected: (v) {
              switch (v) {
                case 'expected':
                  _editExpected();
                case 'help':
                  setState(() => _showGuide = !_showGuide);
                case 'csv':
                  _export('csv');
                case 'txt':
                  _export('txt');
                case 'delete':
                  _deleteAll();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'expected', child: Text(t.rmtExpectedTitle)),
              PopupMenuItem(value: 'help', child: Text(t.rmtHelp)),
              PopupMenuItem(value: 'csv', child: Text(t.rmtExportCsv)),
              PopupMenuItem(value: 'txt', child: Text(t.rmtExportText)),
              PopupMenuItem(value: 'delete', child: Text(t.rmtDeleteAll)),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: bigText,
          tabAlignment: bigText ? TabAlignment.start : null,
          tabs: [
            Tab(text: t.rmtTabMonth),
            Tab(text: t.rmtTabBudget),
            Tab(text: t.rmtTabYear),
          ],
        ),
      ),
      floatingActionButton: _err != null && rmStatus(_err!) == 403
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('rmt_add'),
              onPressed: () => _openEntry(),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.rmtAddReceived),
            ),
      body: TabBarView(controller: _tabs, children: [_monthTab(t), _budgetTab(t), _yearTab(t)]),
    );
  }

  Widget _monthSwitcher(AppLocalizations t) {
    final atNow = _month == rmMonthKey(_now);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: t.rmtPrevMonth,
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => _shiftMonth(-1),
          ),
          Expanded(
            child: Text(
              rmMonthLabel(context, _month),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: t.rmtNextMonth,
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: atNow ? null : () => _shiftMonth(1),
          ),
        ],
      ),
    );
  }

  List<Widget> _pendingWidgets(AppLocalizations t) {
    final pend = _queue.items;
    if (pend.isEmpty) return const [];
    final tokens = AssistoTokens.of(context);
    return [
      Card(
        key: const ValueKey('rmt_pending'),
        color: tokens.infoContainer,
        margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.rmtPendingTitle(rmDigits(rmLang(context), pend.length)),
                style: TextStyle(color: tokens.onInfoContainer, fontWeight: FontWeight.w700),
              ),
              Text(t.rmtPendingBody, style: TextStyle(color: tokens.onInfoContainer)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: () => _sync(),
                  child: Text(t.rmtSyncNow),
                ),
              ),
            ],
          ),
        ),
      ),
      for (final e in _queue.pendingEntries)
        if ('${e['received_on'] ?? ''}'.startsWith(_month)) _entryTile(t, e, pending: true),
    ];
  }

  Widget _quickCard(AppLocalizations t) {
    return RmSection(
      title: t.rmtQuickTitle,
      children: [
        Text(t.rmtQuickBody),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('rmt_quick'),
          controller: _quick,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _understand(),
          decoration: InputDecoration(
            hintText: t.rmtQuickHint,
            errorText: _quickEmpty ? t.rmtQuickEmpty : null,
            errorMaxLines: 2,
            hintMaxLines: 2,
            suffixIcon: VoiceMicButton(voice: _voice, input: _quick),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            key: const ValueKey('rmt_quick_go'),
            style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
            onPressed: _understand,
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: Text(t.rmtQuickGo),
          ),
        ),
      ],
    );
  }

  Widget _expectedCard(AppLocalizations t) {
    final exp = rmMap(_card['expected']);
    final status = '${exp['status'] ?? 'none'}';
    final tokens = AssistoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final due = '${exp['due_date'] ?? ''}';
    final amount = rmTaka(context, exp['taka']);
    final (Color bg, Color fg, IconData icon, String text) = switch (status) {
      'missing' => (
        tokens.warningContainer,
        tokens.onWarningContainer,
        Icons.notification_important_outlined,
        t.rmtExpMissing(amount, rmDay(context, due)),
      ),
      'waiting' => (
        tokens.infoContainer,
        tokens.onInfoContainer,
        Icons.schedule_rounded,
        t.rmtExpWaiting(amount, rmDay(context, due)),
      ),
      'partial' => (
        tokens.infoContainer,
        tokens.onInfoContainer,
        Icons.timelapse_rounded,
        t.rmtExpPartial(rmTaka(context, _card['received']), amount),
      ),
      'arrived' => (
        tokens.successContainer,
        tokens.onSuccessContainer,
        Icons.check_circle_outline_rounded,
        t.rmtExpArrived(amount),
      ),
      'future' => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, Icons.event_rounded, t.rmtExpFuture),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, Icons.event_repeat_rounded, t.rmtExpNone),
    };
    return Card(
      key: ValueKey('rmt_expected_$status'),
      color: bg,
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: _editExpected,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              children: [
                Icon(icon, color: fg),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.edit_outlined, color: fg, size: 20, semanticLabel: t.rmtExpectedTitle),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entryTile(AppLocalizations t, Map<String, dynamic> e, {bool pending = false}) {
    final scheme = Theme.of(context).colorScheme;
    final cur = '${e['currency'] ?? 'BDT'}';
    final who = '${e['sender_name'] ?? ''}'.trim().isEmpty ? t.rmtNoSender : '${e['sender_name']}';
    final sub = <String>[
      rmChannel(t, '${e['channel'] ?? 'other'}'),
      rmDay(context, '${e['received_on'] ?? ''}'),
      if (cur != 'BDT') t.rmtForeignLine(rmNumText(context, e['amount']), cur, rmNumText(context, e['rate'])),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: pending ? null : () => _openEntry(entry: e),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(rmChannelIcon('${e['channel']}'), color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(who, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(sub.join(' · '), style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: Gap.xs),
                      Wrap(
                        spacing: Gap.sm,
                        runSpacing: Gap.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            rmTaka(context, e['taka'] ?? e['amount']),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular),
                          ),
                          if (pending)
                            RmChip(
                              t.rmtWaitingSync,
                              bg: AssistoTokens.of(context).infoContainer,
                              fg: AssistoTokens.of(context).onInfoContainer,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!pending) const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _monthTab(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final off = _err != null && rmStatus(_err!) == 403;
    if (off) return rmErrorView(context, _err!, _load);
    final entries = rmList(_card['entries']);
    return RefreshIndicator(
      onRefresh: () async {
        await _sync();
        await _load();
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          if (_showGuide) RemitGuideCard(onClose: _closeGuide),
          _monthSwitcher(t),
          if (_err != null)
            Card(
              key: const ValueKey('rmt_offline'),
              margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(rmOffline(_err!) ? Icons.wifi_off_rounded : Icons.cloud_off_rounded),
                    const SizedBox(width: Gap.md),
                    Expanded(
                      child: Text(rmOffline(_err!) ? t.rmtOfflineTitle : t.rmtErrorTitle,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: Gap.xs),
                  Text(rmOffline(_err!) ? t.rmtOfflineEntryBody : (rmError(_err!) ?? t.rmtErrorBody)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      onPressed: _load,
                      child: Text(t.rmtRetry),
                    ),
                  ),
                ]),
              ),
            ),
          ..._pendingWidgets(t),
          if (_err == null) _expectedCard(t),
          if (_err == null)
            RmSection(
              title: t.rmtReceivedTitle,
              children: [
                Wrap(
                  spacing: Gap.xl,
                  runSpacing: Gap.sm,
                  children: [
                    RmStat(t.rmtReceived, rmTaka(context, _card['received'])),
                    RmStat(t.rmtTimes, rmDigits(rmLang(context), _card['count'] ?? 0)),
                    RmStat(t.rmtLeft, rmTaka(context, rmMap(_card['plan'])['left'])),
                  ],
                ),
              ],
            ),
          if (_month == rmMonthKey(_now)) _quickCard(t),
          if (_err == null && entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.rmtEmptyMonth, textAlign: TextAlign.center),
            ),
          for (final e in entries) _entryTile(t, e),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ budget tab
  Widget _planLine(AppLocalizations t, Map<String, dynamic> l) {
    final tokens = AssistoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final key = '${l['key']}';
    final plan = rmNum(l['plan']);
    final actual = rmNum(l['actual']);
    final state = '${l['state']}';
    final color = switch (state) {
      'over' => scheme.error,
      'near' => tokens.warning,
      'ok' => tokens.success,
      _ => scheme.primary,
    };
    final pct = plan > 0 ? (actual / plan).clamp(0.0, 1.0) : 0.0;
    final status = switch (state) {
      'over' => t.rmtStateOver,
      'near' => t.rmtStateNear,
      'ok' => t.rmtStateOk,
      _ => t.rmtStateNoPlan,
    };
    return Semantics(
      label: '${rmCategory(t, key)}: ${t.rmtPlanLineA11y(rmTaka(context, actual), rmTaka(context, plan))}, $status',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => _addSpend(key),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(rmCategoryIcon(key), size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(rmCategory(t, key), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                children: [
                  Text(
                    plan > 0
                        ? t.rmtPlanLine(rmTaka(context, actual), rmTaka(context, plan))
                        : t.rmtSpentOnly(rmTaka(context, actual)),
                  ),
                  if (plan > 0)
                    Text(
                      status,
                      style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
              if (plan > 0) ...[
                const SizedBox(height: Gap.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 8,
                    color: color,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _goalCard(AppLocalizations t) {
    final g = _card['goal'] is Map ? rmMap(_card['goal']) : null;
    final tokens = AssistoTokens.of(context);
    if (g == null) {
      return RmSection(
        title: t.rmtGoalTitle,
        children: [
          Text(t.rmtGoalEmpty),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('rmt_goal_set'),
              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: _setGoal,
              icon: const Icon(Icons.flag_outlined),
              label: Text(t.rmtGoalSet),
            ),
          ),
        ],
      );
    }
    final pct = (int.tryParse('${g['pct'] ?? 0}') ?? 0).clamp(0, 100);
    return RmSection(
      title: t.rmtGoalTitle,
      trailing: IconButton(tooltip: t.rmtGoalEdit, icon: const Icon(Icons.edit_outlined), onPressed: _setGoal),
      children: [
        Text('${g['title'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(
          t.rmtGoalProgress(rmTaka(context, g['saved']), rmTaka(context, g['target']), rmDigits(rmLang(context), pct)),
        ),
        const SizedBox(height: Gap.sm),
        Semantics(
          label: t.rmtGoalProgress(
            rmTaka(context, g['saved']),
            rmTaka(context, g['target']),
            rmDigits(rmLang(context), pct),
          ),
          excludeSemantics: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 10,
              color: tokens.success,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const ValueKey('rmt_goal_add'),
            style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
            onPressed: _addToGoal,
            icon: const Icon(Icons.savings_outlined),
            label: Text(t.rmtGoalAdd),
          ),
        ),
      ],
    );
  }

  Widget _billsCard(AppLocalizations t) {
    final bills = rmList(_card['bills']);
    final tokens = AssistoTokens.of(context);
    return RmSection(
      title: t.rmtBillsTitle,
      trailing: TextButton.icon(
        key: const ValueKey('rmt_bill_add'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _addBill,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.rmtBillAdd),
      ),
      children: [
        if (bills.isEmpty) Text(t.rmtBillsEmpty),
        for (final b in bills)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${b['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            t.rmtBillLine(
                              rmTaka(context, b['amount']),
                              rmDigits(rmLang(context), b['due_day'] ?? 1),
                              rmCategory(t, '${b['category'] ?? 'other'}'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: t.rmtMenu,
                      onSelected: (v) {
                        if (v == 'edit') _editBill(b);
                        if (v == 'delete') _deleteBill(b);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(t.rmtBillEditTitle)),
                        PopupMenuItem(value: 'delete', child: Text(t.delete)),
                      ],
                    ),
                  ],
                ),
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (b['paid'] == true)
                      RmChip(t.rmtBillPaid, bg: tokens.successContainer, fg: tokens.onSuccessContainer)
                    else
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => _billPaid(b),
                        child: Text(t.rmtBillMarkPaid),
                      ),
                    if ('${b['reminder_local_id'] ?? ''}'.isEmpty)
                      TextButton.icon(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => _billRemind(b),
                        icon: const Icon(Icons.alarm_add_rounded),
                        label: Text(t.rmtBillRemind),
                      )
                    else
                      RmChip(
                        t.rmtBillReminderOn,
                        bg: Theme.of(context).colorScheme.secondaryContainer,
                        fg: Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                  ],
                ),
                const Divider(height: Gap.lg),
              ],
            ),
          ),
      ],
    );
  }

  Widget _budgetTab(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return rmErrorView(context, _err!, _load);
    final plan = rmMap(_card['plan']);
    final lines = rmList(plan['lines']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          _monthSwitcher(t),
          RmSection(
            title: t.rmtBudgetSummary,
            children: [
              Wrap(
                spacing: Gap.xl,
                runSpacing: Gap.sm,
                children: [
                  RmStat(t.rmtReceived, rmTaka(context, _card['received'])),
                  RmStat(t.rmtSpent, rmTaka(context, plan['spent'])),
                  RmStat(
                    t.rmtLeft,
                    rmTaka(context, plan['left']),
                    color: rmNum(plan['left']) < 0 ? Theme.of(context).colorScheme.error : null,
                  ),
                ],
              ),
              if (rmNum(plan['unplanned']) > 0) ...[
                const SizedBox(height: Gap.sm),
                Text(t.rmtUnplanned(rmTaka(context, plan['unplanned']))),
              ],
            ],
          ),
          RmSection(
            title: t.rmtPlanTitle,
            trailing: TextButton.icon(
              key: const ValueKey('rmt_plan_edit'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _editPlan,
              icon: const Icon(Icons.tune_rounded),
              label: Text(t.rmtPlanEdit),
            ),
            children: [
              if (lines.every((l) => rmNum(l['plan']) == 0)) Text(t.rmtPlanEmpty),
              for (final l in lines) _planLine(t, l),
              const SizedBox(height: Gap.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('rmt_spend_add'),
                  style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                  onPressed: () => _addSpend(),
                  icon: const Icon(Icons.add_shopping_cart_rounded),
                  label: Text(t.rmtSpendAdd),
                ),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.rmtPlanNote, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          _goalCard(t),
          _billsCard(t),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ year tab
  Widget _yearTab(AppLocalizations t) {
    if (_yearLoading || _yearData == null && _yearErr == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_yearErr != null) return rmErrorView(context, _yearErr!, _loadYear);
    final y = _yearData!;
    final months = (y['months'] as List? ?? const []).map(rmNum).toList();
    final maxM = months.isEmpty ? 0.0 : months.reduce((a, b) => a > b ? a : b);
    final scheme = Theme.of(context).colorScheme;
    final lang = rmLang(context);
    return RefreshIndicator(
      onRefresh: _loadYear,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: t.rmtPrevYear,
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: () {
                    _year--;
                    _loadYear();
                  },
                ),
                Expanded(
                  child: Text(
                    rmDigits(lang, _year),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: t.rmtNextYear,
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: _year >= _now.year
                      ? null
                      : () {
                          _year++;
                          _loadYear();
                        },
                ),
              ],
            ),
          ),
          RmSection(
            title: t.rmtYearTotal,
            children: [
              Wrap(
                spacing: Gap.xl,
                runSpacing: Gap.sm,
                children: [
                  RmStat(t.rmtReceived, rmTaka(context, y['total'])),
                  RmStat(t.rmtTimes, rmDigits(lang, y['count'] ?? 0)),
                  RmStat(t.rmtAvgMonth, rmTaka(context, y['avg_month'])),
                  RmStat(t.rmtSavingsBuilt, rmTaka(context, y['savings']), color: AssistoTokens.of(context).success),
                ],
              ),
            ],
          ),
          if ((y['count'] ?? 0) == 0)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.rmtYearEmpty, textAlign: TextAlign.center),
            )
          else ...[
            RmSection(
              title: t.rmtByMonth,
              children: [
                for (var i = 0; i < months.length; i++)
                  if (months[i] > 0)
                    Semantics(
                      label: '${rmShortMonth(context, i + 1)}: ${rmTaka(context, months[i])}',
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: Gap.sm,
                              children: [
                                Text(rmShortMonth(context, i + 1), style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(rmTaka(context, months[i])),
                              ],
                            ),
                            const SizedBox(height: Gap.xxs),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(Radii.pill),
                              child: LinearProgressIndicator(
                                value: maxM > 0 ? months[i] / maxM : 0,
                                minHeight: 8,
                                color: scheme.primary,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
            RmSection(
              title: t.rmtBySender,
              children: [
                for (final s in rmList(y['by_sender']))
                  _row(
                    s['name'] == '?' ? t.rmtNoSender : '${s['name']}',
                    rmTaka(context, s['total']),
                    t.rmtTimesN(rmDigits(lang, s['count'] ?? 0)),
                  ),
              ],
            ),
            RmSection(
              title: t.rmtByChannel,
              children: [
                for (final c in rmList(y['by_channel']))
                  _row(
                    rmChannel(t, '${c['key']}'),
                    rmTaka(context, c['total']),
                    t.rmtTimesN(rmDigits(lang, c['count'] ?? 0)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String a, String b, String c) => MergeSemantics(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Wrap(
        spacing: Gap.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(a, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(b),
          Text(c, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}
