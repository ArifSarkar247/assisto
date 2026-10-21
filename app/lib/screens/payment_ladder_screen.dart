import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../widgets/skeleton.dart';
import '../widgets/ladder_common.dart';
import '../widgets/ladder_cards.dart';
import '../widgets/ladder_builder_sheet.dart';

/// PAYMENT / AUTO-PAY LADDER (SPEC v2.1 §21, advanced).
///
/// An auto-escalating ladder of payment ACTIONS for two mirror cases:
///   • Owed to me (receivable) — chase a khata/tagada due step-by-step.
///   • I owe (payable) — remind me to pay a bill/EMI before + on + after due.
///
/// The escalation decision is a pure function of (debt + ladder + now), computed
/// client-side by ladder_common.dart (mirrors backend/core/logic/payment_ladder.py)
/// so it works OFFLINE. Money is integer poisha throughout.
///
/// HONESTY (structural, not cosmetic):
///   • We NEVER hold money (kHoldsMoney=false) and NEVER auto-charge
///     (kChargesMoney=false). Every step is a reminder / share / notify.
///   • Actually paying a bill is KEY-GATED: `pay_key` only runs with the owner's
///     own licensed bKash/Nagad/partner key; otherwise it degrades to opening the
///     owner's own wallet (`pay_manual`). See resolvePayAction().
///
/// The screen reads two generic owned collections ("ladder-receivable" /
/// "ladder-payable" — each row carries its debt fields + a nested `ladder`).
/// Fields beyond the current backend persist only once the integrator wires the
/// endpoints — see .phaseB/payment_ladder_integration.md. Degrades gracefully.
class PaymentLadderScreen extends StatefulWidget {
  const PaymentLadderScreen({super.key});
  @override
  State<PaymentLadderScreen> createState() => _PaymentLadderScreenState();
}

class _PaymentLadderScreenState extends State<PaymentLadderScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  bool _offline = false; // loaded from cache after a failed refresh

  // Collection paths (generic owned endpoints — see integration md).
  String get _path =>
      _tabs.index == 0 ? 'ladder-receivable' : 'ladder-payable';
  String get _kind => _tabs.index == 0 ? kKindReceivable : kKindPayable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _rows = await context.read<AppState>().api.listItems(_path);
      _offline = false;
    } catch (_) {
      // Keep any previously loaded rows visible (offline-first); only show the
      // hard error state when we have nothing cached to render.
      if (_rows.isEmpty) {
        _error = true;
      } else {
        _offline = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Split a row into (debt, ladder). The ladder nests under `ladder`; if absent
  /// (older rows) we synthesise the default for this kind so the UI still works.
  (Map<String, dynamic>, Map<String, dynamic>) _split(Map<String, dynamic> row) {
    final ladder = (row['ladder'] is Map)
        ? Map<String, dynamic>.from(row['ladder'] as Map)
        : defaultLadder(_kind);
    ladder['kind'] = _kind;
    return (row, ladder);
  }

  Future<void> _addOrEdit([Map<String, dynamic>? row]) async {
    final (debt, ladder) = row != null ? _split(row) : (<String, dynamic>{}, <String, dynamic>{});
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => LadderBuilderSheet(
        kind: _kind,
        debt: row != null ? debt : null,
        ladder: row != null ? ladder : null,
      ),
    );
    if (result == null || !mounted) return;
    final body = {
      ...Map<String, dynamic>.from(result['debt'] as Map),
      'ladder': result['ladder'],
    };
    final api = context.read<AppState>().api;
    final debtBody = Map<String, dynamic>.from(result['debt'] as Map);
    if (row != null && row['id'] != null) {
      await api.updateItem(_path, row['id'] as int, body);
      // Re-schedule against the edited due date (stable id ⇒ replaces, no dupes).
      _scheduleDueReminder(
          row['id'], debtBody['party'] ?? row['party'], debtBody['due_date']);
    } else {
      final created = await api.createItem(_path, body);
      // Honour "we'll remind you to pay on time": schedule a local reminder for
      // the new due (guarded, never blocks the add).
      _scheduleDueReminder(created['id'], created['party'] ?? debtBody['party'],
          created['due_date'] ?? debtBody['due_date']);
    }
    await _load();
  }

  /// Schedule a local "due today" reminder for a ladder row, fired at 09:00 local
  /// on its due date (the ladder itself is anchored on `due_date`, with a
  /// `due_today` rung). Past/missing dates are skipped. The notification id is
  /// derived from the tab-kind + backend id ("ladder-<kind>-<id>") so
  /// re-scheduling on edit / mark-paid REPLACES the old alert rather than
  /// duplicating it, and receivable/payable rows never collide. Fully guarded —
  /// notifications are best-effort and never block the UX.
  void _scheduleDueReminder(dynamic id, dynamic party, dynamic dueDate) {
    try {
      if (id == null) return;
      final t = AppLocalizations.of(context);
      final due = parseDate(dueDate);
      if (due == null) return;
      final title = (party ?? '').toString().trim();
      if (title.isEmpty) return;
      final when = DateTime(due.year, due.month, due.day, 9);
      if (!when.isAfter(DateTime.now())) return; // already due/overdue
      Notifications.schedule('ladder-$_kind-$id', title, t.plDueToday, when);
    } catch (_) {
      // best-effort only
    }
  }

  Future<void> _doStep(Map<String, dynamic> row, Map<String, dynamic> ladder,
      Map<String, dynamic> due) async {
    final t = AppLocalizations.of(context);
    final action = '${due['action']}';
    final channel = '${due['channel']}';
    // We NEVER send on the user's behalf: in-app steps just acknowledge; share
    // steps open the user's own WhatsApp/SMS prefilled (they press Send). A pay
    // step is key-gated — with no key it is already resolved to pay_manual.
    if (channel == 'whatsapp_share' || channel == 'sms') {
      final party = '${row['party'] ?? ''}';
      final amount = taka(context, outstandingPoisha(row));
      final msg = _kind == kKindReceivable
          // (amount, party): generated signature order
          ? t.plMsgReceivable(amount, party)
          : t.plMsgPayable(amount, party);
      await showModalBottomSheet<void>(
        context: context,
        builder: (_) => _SharePreview(
          channel: channel,
          message: msg,
        ),
      );
    } else if (action == 'pay_key' || action == 'pay_manual') {
      // Honest key-gate disclosure before any wallet hand-off.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(actionLabel(t, action)),
          content: Text(t.plKeyGatedBanner),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.plCancel)),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actionLabel(t, action))),
      );
    }
  }

  Future<void> _markPaid(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final party = '${row['party'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.plMarkPaid),
        content: Text(t.plMarkPaidBody(party, taka(context, outstandingPoisha(row)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.plCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.plMarkPaid)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final settled = markPaid(row, now: DateTime.now());
    final rolled = settled['due_date'] != row['due_date'];
    await context.read<AppState>().api.updateItem(_path, row['id'] as int, {
      'paid_poisha': settled['paid_poisha'],
      if (rolled) 'due_date': settled['due_date'],
    });
    // A recurring bill rolled forward to a new due_date → schedule its reminder
    // (same stable id ⇒ replaces the fired one). A one-off that is now fully
    // settled keeps its date; _scheduleDueReminder skips it if it is not future.
    _scheduleDueReminder(
        row['id'], party, rolled ? settled['due_date'] : row['due_date']);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.plMarkedPaid(party))));
    await _load();
  }

  Future<void> _togglePause(Map<String, dynamic> row) async {
    final paused = row['paused'] == true;
    await context
        .read<AppState>()
        .api
        .updateItem(_path, row['id'] as int, {'paused': !paused});
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.plDeleteTitle),
        content: Text(t.plDeleteBody('${row['party'] ?? ''}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.plCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.plDelete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().api.deleteItem(_path, row['id'] as int);
    // Drop any pending due reminder for this row.
    try {
      if (row['id'] != null) Notifications.cancel('ladder-$_kind-${row['id']}');
    } catch (_) {}
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.plTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [Tab(text: t.plTabReceivable), Tab(text: t.plTabPayable)],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: Text(_kind == kKindReceivable ? t.plAddReceivable : t.plAddPayable),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.plLoadFailed,
                  message: t.plLoadFailedBody,
                  action: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: Text(t.plRetry),
                  ),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final now = DateTime.now();
    final receivable = _kind == kKindReceivable;

    if (_rows.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: Gap.xxl),
          StateMessage(
            icon: receivable ? Icons.volunteer_activism : Icons.receipt_long,
            title: receivable ? t.plEmptyReceivableTitle : t.plEmptyPayableTitle,
            message: receivable ? t.plEmptyReceivableBody : t.plEmptyPayablebody,
            action: FilledButton.icon(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add),
              label: Text(receivable ? t.plAddReceivable : t.plAddPayable),
            ),
          ),
        ],
      );
    }

    // Derived: total outstanding + which rows have a due step now.
    var totalOut = 0;
    final dueRows = <Map<String, dynamic>>[];
    for (final row in _rows) {
      totalOut += outstandingPoisha(row);
      final (debt, ladder) = _split(row);
      if (dueStep(debt, ladder, now) != null) dueRows.add(row);
    }

    return ListView(
      // Bottom inset clears the extended FAB (height ~56 + 16 margin) PLUS the
      // trailing footer hint, so neither the last ladder card nor the
      // "Payments go through your own bKash/Nagad…" footer is hidden behind the
      // floating "Add a due" button when scrolled to the end.
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        if (_offline) ...[
          _OfflineBar(text: t.plOffline),
          const SizedBox(height: Gap.sm),
        ],
        LadderHero(
          kind: _kind,
          outstandingPoisha: totalOut,
          actionCount: dueRows.length,
        ),
        const SizedBox(height: Gap.md),
        const LadderNoMoneyBanner(),

        if (dueRows.isNotEmpty) ...[
          LadderSection(
              icon: Icons.bolt, title: t.plSectionDueNow, tint: Brand.danger),
          for (final row in dueRows) _card(row, now),
        ],

        LadderSection(icon: Icons.list_alt, title: t.plSectionAll),
        for (final row in _rows)
          if (!dueRows.contains(row)) _card(row, now),

        const SizedBox(height: Gap.lg),
        Text(t.plFooterHint,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline)),
      ],
    );
  }

  Widget _card(Map<String, dynamic> row, DateTime now) {
    final (debt, ladder) = _split(row);
    final due = dueStep(debt, ladder, now);
    final up = nextStep(debt, ladder, now);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Dismissible(
        key: ValueKey('ladder-${_kind}-${row['id']}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: Gap.lg),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Icon(Icons.delete_outline,
              color: Theme.of(context).colorScheme.onErrorContainer),
        ),
        confirmDismiss: (_) async {
          await _delete(row);
          return false;
        },
        child: LadderDebtCard(
          debt: debt,
          ladder: ladder,
          due: due,
          upcoming: up,
          onTap: () => _showTimeline(row, ladder, now),
          onDoStep: () => due == null ? null : _doStep(row, ladder, due),
          onMarkPaid: () => _markPaid(row),
          onTogglePause: () => _togglePause(row),
        ),
      ),
    );
  }

  void _showTimeline(
      Map<String, dynamic> row, Map<String, dynamic> ladder, DateTime now) {
    final t = AppLocalizations.of(context);
    final steps = scheduleOf(row, ladder, now: now);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xxl),
        children: [
          Text('${row['party'] ?? ''}',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(dueRelative(context, t, row['due_date']),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          for (final s in steps) LadderStepRow(step: s),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _addOrEdit(row);
                },
                icon: const Icon(Icons.edit_outlined),
                label: Text(t.plEditLadder),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.plKeyGatedBanner,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  final String text;
  const _OfflineBar({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.cloud_off, size: 18, color: cs.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(color: cs.onTertiaryContainer, fontSize: 13)),
        ),
      ]),
    );
  }
}

/// A preview of the prefilled share message — the user taps to open their OWN
/// WhatsApp / SMS app (we never send for them).
class _SharePreview extends StatelessWidget {
  final String channel;
  final String message;
  const _SharePreview({required this.channel, required this.message});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final whatsapp = channel == 'whatsapp_share';
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Text(message, style: const TextStyle(height: 1.4)),
        ),
        const SizedBox(height: Gap.md),
        Text(t.plShareHint,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          // NOTE: the actual url_launcher hand-off (wa.me / sms:) is wired by the
          // integrator against the app's existing share helper — see the
          // integration md. We never auto-send; the user presses Send themselves.
          onPressed: () => Navigator.pop(context),
          icon: Icon(whatsapp ? Icons.chat_bubble_outline : Icons.sms_outlined),
          label: Text(whatsapp ? t.plShareWhatsapp : t.plShareSms),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ]),
    );
  }
}
