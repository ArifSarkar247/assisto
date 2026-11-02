import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../books_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../messaging/date_separators.dart' show fmtDate;
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/skeleton.dart';
import '../business_common.dart' show pair;
import 'acct_common.dart';

/// acctui — MONTH CLOSE. Pick a finished month, see its profit and that the
/// books balance, tick "I understand" and close: nothing can be entered on
/// or before that day any more (a late change from the shop lands on the
/// next open day — the closed month never moves). Reopening needs a written
/// reason, which goes in the audit trail. Server: business/acct/lock.
class AcctCloseScreen extends StatefulWidget {
  final int? businessId;
  const AcctCloseScreen({super.key, this.businessId});

  @override
  State<AcctCloseScreen> createState() => _AcctCloseScreenState();
}

class _AcctCloseScreenState extends State<AcctCloseScreen> {
  Map<String, dynamic>? _book;
  Object? _error;
  bool _busy = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.acctHints(widget.businessId);
      if (mounted) setState(() => _book = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  DateTime? get _lock => DateTime.tryParse('${_book?['lock_date'] ?? ''}');
  DateTime? get _start => DateTime.tryParse('${_book?['start_date'] ?? ''}');

  /// Finished months after the current lock (newest first, at most 12).
  List<DateTime> _closable() {
    final now = DateTime.now();
    final out = <DateTime>[];
    for (var i = 1; i <= 12; i++) {
      final end = DateTime(now.year, now.month - i + 1, 0); // last day of month -i
      if (_lock != null && !end.isAfter(_lock!)) break;
      if (_start != null && end.isBefore(_start!)) break;
      out.add(end);
    }
    return out;
  }

  Future<void> _close(DateTime end) async {
    final t = AppLocalizations.of(context);
    final lang = acctLang(context);
    setState(() => _busy = true);
    Map<String, dynamic>? pl, tb;
    try {
      pl = await _api.booksProfitLoss(widget.businessId,
          from: acctIso(DateTime(end.year, end.month, 1)), to: acctIso(end));
      tb = await _api.acctTrialBalanceAsOf(widget.businessId, acctIso(end));
    } catch (_) {
      // the summary is a help, not a gate: close still works without it
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final month = fmtMonth(end, lang);
    var understood = false;
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.acuCloseConfirmTitle(month), style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            if (pl != null)
              Text(t.acuCloseMonthProfit(acctMoney(ctx, pl['net_profit'])),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            if (tb != null)
              Text(tb['balanced'] == true ? t.acuBalanced : t.acuNotBalanced,
                  style: TextStyle(
                      color: tb['balanced'] == true
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).colorScheme.error,
                      fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.md),
            Text(t.acuCloseExplain(acctDay(ctx, acctIso(end))), style: const TextStyle(height: 1.5)),
            const SizedBox(height: Gap.sm),
            CheckboxListTile(
              key: const ValueKey('acct-close-understood'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: understood,
              title: Text(t.acuCloseUnderstood),
              onChanged: (v) => setSheet(() => understood = v ?? false),
            ),
            const SizedBox(height: Gap.sm),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('acct-close-confirm'),
                onPressed: understood ? () => Navigator.pop(ctx, true) : null,
                icon: const Icon(Icons.lock_rounded),
                label: Text(t.acuCloseConfirm(month)),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.acuCancel)),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _send(acctIso(end), '', t.acuClosedDone(month));
  }

  Future<void> _reopen() async {
    final t = AppLocalizations.of(context);
    final lock = _lock;
    if (lock == null) return;
    final reason = TextEditingController();
    final prev = DateTime(lock.year, lock.month, 0);
    final to = _start != null && prev.isBefore(_start!) ? null : prev;
    final month = fmtMonth(lock, acctLang(context));
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.acuReopenTitle(month), style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(t.acuReopenExplain, style: const TextStyle(height: 1.5)),
              const SizedBox(height: Gap.md),
              TextField(
                key: const ValueKey('acct-reopen-reason'),
                controller: reason,
                maxLength: 200,
                decoration: InputDecoration(
                    labelText: t.acuReopenReason, border: const OutlineInputBorder()),
                onChanged: (_) => setSheet(() {}),
              ),
              SizedBox(
                height: 52,
                child: FilledButton.tonal(
                  key: const ValueKey('acct-reopen-confirm'),
                  onPressed: reason.text.trim().length >= 5 ? () => Navigator.pop(ctx, true) : null,
                  child: Text(t.acuReopenButton),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    final why = reason.text.trim();
    if (ok != true || !mounted) return;
    await _send(to == null ? null : acctIso(to), why, t.acuReopenedDone(month));
  }

  Future<void> _send(String? day, String reason, String done) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await _api.acctLock(widget.businessId, day, reason: reason);
      final ok = (r['_status'] as int? ?? 0) == 200;
      messenger.showSnackBar(SnackBar(
          content: Text(ok ? done : pair(context, r['detail'], fallback: t.acuSaveFailed))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.acuClose)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    final e = _error;
    if (e != null) {
      return StateMessage(
        icon: e is ApiException && e.status == 403 ? Icons.lock_rounded : Icons.cloud_off_rounded,
        title: t.acuClose,
        message: e is ApiException && e.status == 403 ? e.message : honestFailText(t, e),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_book == null) return const SkeletonList();
    final scheme = Theme.of(context).colorScheme;
    final lock = _lock;
    final months = _closable();
    final lang = acctLang(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        Card(
          color: lock == null ? scheme.surfaceContainerHighest : scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(lock == null ? Icons.lock_open_rounded : Icons.lock_rounded,
                    color: lock == null ? scheme.onSurfaceVariant : scheme.onPrimaryContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                      lock == null
                          ? t.acuCloseNone
                          : t.acuClosedUpTo(acctDay(context, acctIso(lock))),
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: lock == null ? null : scheme.onPrimaryContainer)),
                ),
              ]),
              if (lock != null) ...[
                const SizedBox(height: Gap.sm),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: const ValueKey('acct-reopen'),
                    onPressed: _busy ? null : _reopen,
                    icon: const Icon(Icons.lock_open_rounded),
                    label: Text(t.acuReopenButton),
                  ),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.acuCloseWhy, style: const TextStyle(height: 1.5)),
        const SizedBox(height: Gap.lg),
        if (months.isEmpty)
          Text(t.acuCloseNothing, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))
        else ...[
          Semantics(
            header: true,
            child: Text(t.acuClosePick,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: Gap.sm),
          for (final m in months.reversed)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                key: ValueKey('acct-close-${acctIso(m)}'),
                minVerticalPadding: Gap.sm,
                leading: const Icon(Icons.calendar_month_rounded),
                title: Text(fmtMonth(m, lang), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(t.acuCloseUpTo(acctDay(context, acctIso(m)))),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: !_busy,
                onTap: () => _close(m),
              ),
            ),
        ],
      ],
    );
  }
}

String fmtMonth(DateTime d, String lang) => fmtDate('MMMM yyyy', d, lang);
